<#
.SYNOPSIS
  Checks the WebLogic log index for servers whose logs stopped updating, posts changes to Slack,
  and hands the result to the status page. Runs on a machine inside CMiC's network (the log
  index is VPN-only, so GitHub Actions can't reach it).

.DESCRIPTION
  1. Reads #hostingsupport for "pause logs-monitoring ..." / "resume logs-monitoring" commands (see below).
  2. Runs ..\status-to-slack.ps1 -Service weblogic-logs (posts to Slack, keeps its state in
     ..\state\weblogic-logs.json on this machine). While paused it posts nothing.
  3. Saves ..\status\weblogic-logs.json to the "weblogic-logs-data" branch of the GitHub repo,
     as a single commit replaced each time (like status-data). The workflow's publish job
     copies it onto the status page. If this machine stops running, the tile turns grey
     ("No recent data") after 20 minutes.

  Pausing the alerts, for anyone in #hostingsupport (a new message, not a thread reply):
    pause logs-monitoring 4h DBAS confirmed a copy delay     (hours or minutes: 4h, 90m; default 4h, at most 72h)
    resume logs-monitoring                                   (ends a pause early)
  The newest command in the channel wins. A pause ends by itself. While paused the check keeps
  running and the page keeps its count; changes are recorded but not posted, so nothing floods
  in afterwards. A note in the channel confirms each pause and resume. This needs the bot token
  of the "Status Acknowledgements" Slack app (the one the status page uses for check-mark
  reactions); without it, pausing is off and alerts post as usual.

  Secrets (only this Windows user on this machine can read the saved file):
    Log index      the address of the WebLogic log index, kept out of the public repository
    Slack webhook  for the WebLogic Logs Slack app (posts to #hostingsupport)
    GitHub token   fine-grained, resource owner hosting-support, only the status-pages-slack
                   repository, permission "Contents: Read and write"
    Slack bot token  of the Status Acknowledgements app, to read pause commands (xoxb-...)
  Either environment variables WEBLOGIC_LOGS_URL / WEBLOGIC_SLACK_WEBHOOK / WEBLOGIC_GITHUB_TOKEN /
  WEBLOGIC_SLACK_BOT_TOKEN, or saved with -SaveSecrets (all four) or -SaveSlackToken (just the bot token).

.EXAMPLE
  .\run-weblogic-logs.ps1 -SaveSecrets      # once: asks for the address, webhook and tokens
.EXAMPLE
  .\run-weblogic-logs.ps1 -SaveSlackToken   # add or replace only the Slack bot token
.EXAMPLE
  .\run-weblogic-logs.ps1 -DryRun           # check now, print what would be posted, push nothing
.EXAMPLE
  .\run-weblogic-logs.ps1 -Install          # once: run every 5 minutes from Task Scheduler
#>
param(
    [switch] $SaveSecrets,
    [switch] $SaveSlackToken,
    [switch] $Install,
    [int]    $EveryMinutes = 5,
    [switch] $DryRun,
    [string] $Repo   = 'hosting-support/status-pages-slack',
    [string] $Branch = 'weblogic-logs-data'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root        = Split-Path $PSScriptRoot
$secretsFile = Join-Path $PSScriptRoot 'secrets.xml'
$logFile     = Join-Path $PSScriptRoot 'run.log'
$pauseFile   = Join-Path $PSScriptRoot 'pause.json'      # the last pause seen in Slack, and what was announced
$snapshot    = Join-Path $root 'status\weblogic-logs.json'
$config      = Get-Content (Join-Path $root 'services\weblogic-logs.json') -Raw | ConvertFrom-Json
$eastern     = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
$culture     = [Globalization.CultureInfo]::InvariantCulture

function Write-Log($msg) {
    $line = "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) $msg"
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

if ($SaveSecrets -or $SaveSlackToken) {
    $saved = if (Test-Path $secretsFile) { Import-Clixml $secretsFile } else { @{} }
    if ($SaveSecrets) {
        $saved.logsUrl = Read-Host 'Address of the WebLogic log index (https://.../weblogic/)'
        $saved.webhook = Read-Host 'Slack webhook URL for the WebLogic Logs app' -AsSecureString
        $saved.token   = Read-Host 'GitHub fine-grained token (Contents: Read and write)' -AsSecureString
    }
    $saved.slackToken  = Read-Host 'Slack bot token of the Status Acknowledgements app (xoxb-..., Enter to skip)' -AsSecureString
    $saved | Export-Clixml -Path $secretsFile
    Write-Host "Saved to $secretsFile (readable only by $env:USERNAME on $env:COMPUTERNAME)"
    return
}

if ($Install) {
    # No window popping up every run: Windows 11's conhost.exe --headless starts PowerShell with no
    # console at all. Older Windows falls back to -WindowStyle Hidden, which still flashes briefly.
    $ps = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $headless = [Environment]::OSVersion.Version.Build -ge 22000
    $action  = if ($headless) {
                   New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe $ps" -WorkingDirectory $PSScriptRoot
               } else {
                   New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-WindowStyle Hidden $ps" -WorkingDirectory $PSScriptRoot
               }
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
               -RepetitionInterval (New-TimeSpan -Minutes $EveryMinutes)   # no duration = repeats indefinitely
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
               -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName 'WebLogic log check' -Action $action -Trigger $trigger -Settings $settings `
        -Description 'Checks the WebLogic log index for logs that stopped updating; see weblogic-logs\README.md' -Force | Out-Null
    Write-Host "Scheduled task 'WebLogic log check' runs every $EveryMinutes minutes as $env:USERNAME."
    return
}

# keep the log file short
if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 1MB) {
    Get-Content $logFile -Tail 2000 | Set-Content $logFile
}

function Get-Secret($envName, $key) {
    $v = [Environment]::GetEnvironmentVariable($envName)
    if ($v) { return $v }
    if (Test-Path $secretsFile) {
        $s = (Import-Clixml $secretsFile)[$key]
        if ($s -is [string]) { return $s }
        if ($s) { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)) }
    }
    $null
}
$webhook    = Get-Secret 'WEBLOGIC_SLACK_WEBHOOK' 'webhook'
$token      = Get-Secret 'WEBLOGIC_GITHUB_TOKEN' 'token'
$slackToken = Get-Secret 'WEBLOGIC_SLACK_BOT_TOKEN' 'slackToken'
# the log index address stays on this machine, not in the public repository
$env:WEBLOGIC_LOGS_URL = Get-Secret 'WEBLOGIC_LOGS_URL' 'logsUrl'
if (-not $env:WEBLOGIC_LOGS_URL) { Write-Log 'No log index address saved (run -SaveSecrets)'; exit 1 }

# ---- 1. pause commands from Slack ----
$pauseCfg     = $config.pause
$pauseChannel = $(if ($pauseCfg.channel) { [string]$pauseCfg.channel } else { 'hostingsupport' })
$defaultHours = $(if ($pauseCfg.defaultHours) { [double]$pauseCfg.defaultHours } else { 4 })
$maxHours     = $(if ($pauseCfg.maxHours) { [double]$pauseCfg.maxHours } else { 72 })
$slackApi     = $(if ($env:SLACK_API_BASE) { $env:SLACK_API_BASE.TrimEnd('/') } else { 'https://slack.com/api' })   # tests only

function Format-Eastern($utc) { [TimeZoneInfo]::ConvertTimeFromUtc($utc, $eastern).ToString('ddd MMM d HH:mm', $culture) + ' ET' }
function ConvertFrom-UnixTime($s) { [DateTimeOffset]::FromUnixTimeMilliseconds([long]([double]$s * 1000)).UtcDateTime }

# "pause logs-monitoring 4h reason", "pause logs-monitoring for 90m: reason", "pause logs-monitoring reason", "resume logs-monitoring"
function ConvertFrom-PauseCommand([string]$text) {
    $t = [Net.WebUtility]::HtmlDecode($text).Trim()
    # "logs-monitoring"; also accepts "logs monitoring" and "logs_monitoring"
    if ($t -match '(?i)^(resume|unpause|unmute)\s+logs[-_ ]?monitoring\b') { return @{ kind = 'resume' } }
    if ($t -notmatch '(?i)^(pause|mute)\s+logs[-_ ]?monitoring\b[\s:,-]*(.*)$') { return $null }
    $rest = $Matches[2] -replace '(?i)^for\s+', ''
    $hours = $defaultHours
    if ($rest -match '(?i)^(\d+(?:\.\d+)?)\s*(h|hrs?|hours?|m|mins?|minutes?)?(?![a-z])[\s:,-]*(.*)$') {
        $n = [double]$Matches[1]; $unit = [string]$Matches[2]; $rest = $Matches[3]
        $hours = if ($unit -like 'm*') { $n / 60 } else { $n }
    }
    @{ kind = 'pause'; hours = [Math]::Min($hours, $maxHours); reason = ($rest -replace '(?i)^(because|reason)[\s:,-]*', '').Trim() }
}

function Invoke-Slack($method, $query) {
    $r = Invoke-RestMethod -Uri "$slackApi/$method`?$query" -Headers @{ Authorization = "Bearer $slackToken" } -TimeoutSec 30
    if (-not $r.ok) { throw "Slack $method failed: $($r.error)$(if ($r.needed) { " (needs scope $($r.needed))" })" }
    $r
}

# the newest pause/resume command from a person in the channel, within the longest possible pause
function Get-LatestCommand {
    $ch = @((Invoke-Slack 'users.conversations' 'types=public_channel,private_channel&exclude_archived=true&limit=200').channels) |
          Where-Object { $_.name -eq $pauseChannel } | Select-Object -First 1
    if (-not $ch) { throw "The Status Acknowledgements Slack app isn't in #$pauseChannel" }
    $oldest = [DateTimeOffset]::UtcNow.AddHours(-$maxHours).ToUnixTimeSeconds()
    $messages = @(); $cursor = ''
    do {
        $r = Invoke-Slack 'conversations.history' "channel=$($ch.id)&oldest=$oldest&limit=200&cursor=$([uri]::EscapeDataString($cursor))"
        $messages += @($r.messages)
        $cursor = [string]$r.response_metadata.next_cursor
    } while ($cursor)
    $messages | Where-Object { $_.user -and -not $_.bot_id -and -not $_.subtype } |
        ForEach-Object {
            $c = ConvertFrom-PauseCommand $_.text
            if ($c) { $c.ts = [string]$_.ts; $c.user = [string]$_.user; [pscustomobject]$c }
        } |
        Sort-Object { [double]$_.ts } -Descending | Select-Object -First 1
}

# what the page shows right now, from the last check
function Get-CurrentCount {
    try {
        $s = Get-Content $snapshot -Raw | ConvertFrom-Json
        if (@($s.open).Count) { $s.open[0].title } else { "all servers' logs are updating" }
    } catch { 'unknown (no recent check)' }
}
# a plain note in #hostingsupport, in the same style as the alerts
function Send-Note($text, $hex) {
    if ($DryRun) { Write-Log "  would post: $($text -replace "`n", ' / ')"; return }
    if (-not $webhook) { return }
    $json = @{
        unfurl_links = $false
        attachments  = @(@{
            color    = $hex
            fallback = ($text -replace '[*>]', '')
            blocks   = @(
                @{ type = 'context'; elements = @(@{ type = 'mrkdwn'; text = [string]$config.label }) },
                @{ type = 'section'; text = @{ type = 'mrkdwn'; text = $text } }
            )
        })
    } | ConvertTo-Json -Depth 8 -Compress
    Invoke-RestMethod -Uri $webhook -Method Post -ContentType 'application/json; charset=utf-8' `
        -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 30 | Out-Null
}
function ConvertTo-SlackText($t) { $t -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' }

# pause.json: { ts, kind, until (unix s), user, reason, announced = "<ts>|paused|ended|resumed" }
$known = $null
if (Test-Path $pauseFile) { try { $known = Get-Content $pauseFile -Raw | ConvertFrom-Json } catch { } }
$cmd = $null; $slackOk = $false
if ($slackToken) {
    try { $cmd = Get-LatestCommand; $slackOk = $true }
    catch { Write-Log "Couldn't read pause commands from Slack, keeping the last known pause: $($_.Exception.Message)" }
}
$now = [datetime]::UtcNow
$state = if ($slackOk) {
    if ($cmd) {
        [pscustomobject]@{
            ts = $cmd.ts; kind = $cmd.kind; user = $cmd.user; reason = [string]$cmd.reason
            until = $(if ($cmd.kind -eq 'pause') { [long]([double]$cmd.ts + $cmd.hours * 3600) } else { 0 })
            announced = $(if ($known) { [string]$known.announced } else { '' })
        }
    } else { $null }
} else { $known }

$muted = $false
$env:WEBLOGIC_ALERTS_PAUSED = $null
if ($state) {
    $until  = ConvertFrom-UnixTime $state.until
    $active = $state.kind -eq 'pause' -and $now -lt $until
    $event  = "$($state.ts)|$(if ($active) { 'paused' } elseif ($state.kind -eq 'pause') { 'ended' } else { 'resumed' })"
    if ($active) {
        $muted = $true
        $env:WEBLOGIC_ALERTS_PAUSED = "Slack alerts paused until $(Format-Eastern $until)"
        Write-Log "Alerts paused until $(Format-Eastern $until) by $($state.user)$(if ($state.reason) { " ($($state.reason))" })"
    }
    # announce each change once: a new pause; its end; a resume that ended a pause
    $lastWasPause = ([string]$state.announced) -match '\|paused$'
    if ($slackOk -and $state.announced -ne $event) {
        try {
            if ($active) {
                Send-Note (":double_vertical_bar: *Alerts paused* until $(Format-Eastern $until), by <@$($state.user)>." +
                           $(if ($state.reason) { "`nReason: $(ConvertTo-SlackText $state.reason)" }) +
                           "`nThe check keeps running and the status page keeps the count. Right now: $(Get-CurrentCount)." +
                           "`nTo turn alerts back on early, post ``resume logs-monitoring`` here.") '#A0A0A0'
            } elseif ($lastWasPause -and $state.kind -eq 'pause') {
                Send-Note (":arrow_forward: *Alerts resumed*: the pause ended. Right now: $(Get-CurrentCount).`n" +
                           "Changes during the pause weren't posted. New ones will be.") '#2EB67D'
            } elseif ($lastWasPause) {
                Send-Note (":arrow_forward: *Alerts resumed* by <@$($state.user)>. Right now: $(Get-CurrentCount).`n" +
                           "Changes during the pause weren't posted. New ones will be.") '#2EB67D'
            }
            $state.announced = $event
            Write-Log "Pause: $event"
        } catch { Write-Log "Couldn't post the pause note: $($_.Exception.Message)" }
    }
    if (-not $DryRun) { $state | ConvertTo-Json | Set-Content -Path $pauseFile -Encoding UTF8 }
} elseif ($slackOk -and $known -and -not $DryRun) {
    Remove-Item $pauseFile    # no commands left in the channel's recent history
}

# ---- 2. check and post ----
try {
    $out = if ($DryRun -or -not $webhook) {
        if (-not $DryRun) { Write-Log 'No Slack webhook saved, so nothing is posted (run -SaveSecrets)' }
        & (Join-Path $root 'status-to-slack.ps1') -Service weblogic-logs -DryRun *>&1
    } else {
        & (Join-Path $root 'status-to-slack.ps1') -Service weblogic-logs -WebhookUrl $webhook -Mute:$muted *>&1
    }
    $out | ForEach-Object { Write-Log "  $_" }
} catch {
    # e.g. off the VPN: no snapshot is pushed, so the page shows "No recent data" after a while
    Write-Log "Check failed: $($_.Exception.Message)"
    exit 1
}

# ---- 3. hand the result to the status page ----
if ($DryRun) { Write-Log "Dry run: not pushing $snapshot"; return }
if (-not $token) { Write-Log 'No GitHub token saved, so the status page is not updated (run -SaveSecrets)'; exit 1 }

# One commit with no parent, then point the branch at it: three API calls, no git needed, and
# the branch never builds up history.
$api = "https://api.github.com/repos/$Repo/git"
$headers = @{
    Authorization          = "Bearer $token"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'weblogic-log-check'
}
function Invoke-GitHub($method, $url, $body) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 5 -Compress))
    Invoke-RestMethod -Method $method -Uri $url -Headers $headers -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 30
}
try {
    $content = [IO.File]::ReadAllText($snapshot)
    $tree    = Invoke-GitHub Post "$api/trees" @{ tree = @(@{ path = 'weblogic-logs.json'; mode = '100644'; type = 'blob'; content = $content }) }
    $commit  = Invoke-GitHub Post "$api/commits" @{ message = "WebLogic logs at $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"; tree = $tree.sha; parents = @() }
    try   { Invoke-GitHub Patch "$api/refs/heads/$Branch" @{ sha = $commit.sha; force = $true } | Out-Null }
    catch { Invoke-GitHub Post "$api/refs" @{ ref = "refs/heads/$Branch"; sha = $commit.sha } | Out-Null }   # first time
    Write-Log "Pushed to $Repo@$Branch"
} catch {
    # 401 = token expired or wrong; 403/404 = token lacks Contents: Read and write on the repo
    Write-Log "Push to GitHub failed: $($_.Exception.Message)"
    exit 1
}
