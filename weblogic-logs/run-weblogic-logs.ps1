<#
.SYNOPSIS
  Checks the WebLogic log index for servers whose logs stopped updating, posts changes to Slack,
  and hands the result to the status page. Runs on a machine inside CMiC's network (the log
  index is VPN-only, so GitHub Actions can't reach it).

.DESCRIPTION
  1. Runs ..\status-to-slack.ps1 -Service weblogic-logs (posts to Slack, keeps its state in
     ..\state\weblogic-logs.json on this machine).
  2. Saves ..\status\weblogic-logs.json to the "weblogic-logs-data" branch of the GitHub repo,
     as a single commit replaced each time (like status-data). The workflow's publish job
     copies it onto the status page. If this machine stops running, the tile turns grey
     ("No recent data") after 20 minutes.

  Secrets (only this Windows user on this machine can read the saved file):
    Log index      the address of the WebLogic log index, kept out of the public repository
    Slack webhook  for the WebLogic Logs Slack app (posts to #hostingsupport)
    GitHub token   fine-grained, resource owner hosting-support, only the status-pages-slack
                   repository, permission "Contents: Read and write"
  Either environment variables WEBLOGIC_LOGS_URL / WEBLOGIC_SLACK_WEBHOOK / WEBLOGIC_GITHUB_TOKEN, or saved once with
  -SaveSecrets.

.EXAMPLE
  .\run-weblogic-logs.ps1 -SaveSecrets      # once: asks for the webhook and token
.EXAMPLE
  .\run-weblogic-logs.ps1 -DryRun           # check now, print what would be posted, push nothing
.EXAMPLE
  .\run-weblogic-logs.ps1 -Install          # once: run every 2 minutes from Task Scheduler
#>
param(
    [switch] $SaveSecrets,
    [switch] $Install,
    [int]    $EveryMinutes = 2,
    [switch] $DryRun,
    [string] $Repo   = 'hosting-support/status-pages-slack',
    [string] $Branch = 'weblogic-logs-data'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root        = Split-Path $PSScriptRoot
$secretsFile = Join-Path $PSScriptRoot 'secrets.xml'
$logFile     = Join-Path $PSScriptRoot 'run.log'
$snapshot    = Join-Path $root 'status\weblogic-logs.json'

function Write-Log($msg) {
    $line = "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) $msg"
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

if ($SaveSecrets) {
    $logsUrl = Read-Host 'Address of the WebLogic log index (https://.../weblogic/)'
    $webhook = Read-Host 'Slack webhook URL for the WebLogic Logs app' -AsSecureString
    $token   = Read-Host 'GitHub fine-grained token (Contents: Read and write)' -AsSecureString
    @{ logsUrl = $logsUrl; webhook = $webhook; token = $token } | Export-Clixml -Path $secretsFile
    Write-Host "Saved to $secretsFile (readable only by $env:USERNAME on $env:COMPUTERNAME)"
    return
}

if ($Install) {
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
               -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -WorkingDirectory $PSScriptRoot
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
$webhook = Get-Secret 'WEBLOGIC_SLACK_WEBHOOK' 'webhook'
$token   = Get-Secret 'WEBLOGIC_GITHUB_TOKEN' 'token'
# the log index address stays on this machine, not in the public repository
$env:WEBLOGIC_LOGS_URL = Get-Secret 'WEBLOGIC_LOGS_URL' 'logsUrl'
if (-not $env:WEBLOGIC_LOGS_URL) { Write-Log 'No log index address saved (run -SaveSecrets)'; exit 1 }

# ---- 1. check and post ----
try {
    $out = if ($DryRun -or -not $webhook) {
        if (-not $DryRun) { Write-Log 'No Slack webhook saved, so nothing is posted (run -SaveSecrets)' }
        & (Join-Path $root 'status-to-slack.ps1') -Service weblogic-logs -DryRun *>&1
    } else {
        & (Join-Path $root 'status-to-slack.ps1') -Service weblogic-logs -WebhookUrl $webhook *>&1
    }
    $out | ForEach-Object { Write-Log "  $_" }
} catch {
    # e.g. off the VPN: no snapshot is pushed, so the page shows "No recent data" after a while
    Write-Log "Check failed: $($_.Exception.Message)"
    exit 1
}

# ---- 2. hand the result to the status page ----
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
