<#
.SYNOPSIS
  Builds the status page site: site\index.html plus a status.json combining every service's
  snapshot (status\<id>.json, written by status-to-slack.ps1).

.DESCRIPTION
  A run may not have a fresh snapshot for every service (a manual run for one service, or a
  status page that didn't answer). Those keep their entry from the previous status.json
  (-PreviousFile or -PreviousUrl), and the page shows them as "No recent data" once they're old.

.EXAMPLE
  .\build-status-page.ps1 -SnapshotDir status -OutDir _site
#>
param(
    [string] $SnapshotDir = (Join-Path $PSScriptRoot 'status'),
    [string] $OutDir      = (Join-Path $PSScriptRoot '_site'),
    [string] $PreviousUrl,                    # the published status.json, e.g. https://<user>.github.io/<repo>/status.json
    [string] $PreviousFile,                   # or the previous status.json as a local file
    # What started this run, for the page's update health line: 'workflow_dispatch' (the
    # Cloudflare scheduler, or the Run workflow button) or 'schedule' (GitHub's hourly backup)
    [string] $Trigger = 'manual',
    [string] $RunUrl,                         # link to this run on GitHub
    # Acknowledgements: a Slack bot token (channels:history, groups:history, channels:read,
    # groups:read, users:read) whose app is in the channels the posts go to. A check-mark
    # reaction on a post about an open incident marks it acknowledged, and it no longer turns
    # the service's tile red/amber on the page. Without a token, nothing is acknowledged.
    [string] $SlackToken = $env:SLACK_BOT_TOKEN,
    [string[]] $AckEmoji = @($(if ($env:ACK_EMOJI) { $env:ACK_EMOJI -split '[,;\s]+' | Where-Object { $_ } }
                               else { 'white_check_mark', 'heavy_check_mark', 'ballot_box_with_check' }))
)

$ErrorActionPreference = 'Stop'
function Format-Utc($t) { ([datetime]$t).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
$now = Format-Utc (Get-Date)

$services = [ordered]@{}
$previousRun = $null
if ($PreviousFile -or $PreviousUrl) {
    try {
        $previous = if ($PreviousFile) { Get-Content $PreviousFile -Raw | ConvertFrom-Json }
                    else { Invoke-RestMethod -Uri $PreviousUrl -TimeoutSec 20 }
        foreach ($s in $previous.services) { $services[$s.id] = $s }
        $previousRun = $previous.run
        Write-Host "Previous status.json: $($services.Count) services"
    } catch { Write-Host "No previous status.json ($($_.Exception.Message)); starting fresh" }
}

# The scheduler's last run is carried over from the previous page when GitHub's backup
# schedule started this one, so the page can tell "backup ran" apart from "scheduler ran".
$lastScheduler = if ($Trigger -eq 'workflow_dispatch') { $now }
                 elseif ($previousRun.lastSchedulerAt) { Format-Utc $previousRun.lastSchedulerAt }
                 else { $null }
foreach ($f in Get-ChildItem -Path $SnapshotDir -Filter *.json -File -ErrorAction SilentlyContinue) {
    $s = Get-Content $f.FullName -Raw | ConvertFrom-Json
    $services[$s.id] = $s
    Write-Host "Fresh snapshot: $($s.id) ($($s.level))"
}

# drop services whose settings file was removed
$known = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'services') -Filter *.json | ForEach-Object BaseName)
$list = @($services.Values | Where-Object { $_.id -in $known } | Sort-Object name)
# the page section each service goes in ("group" in its settings file, e.g. Core / Other)
foreach ($s in $list) {
    $group = (Get-Content (Join-Path $PSScriptRoot "services\$($s.id).json") -Raw | ConvertFrom-Json).group
    $s | Add-Member -NotePropertyName group -NotePropertyValue $(if ($group) { [string]$group } else { 'Other' }) -Force
}

# ---- acknowledgements from Slack reactions ----
# An open incident is matched to Slack posts by its link, or by its title when the link is just
# the vendor's status page (AWS). Removing the reaction un-acknowledges it on the next run, and
# a resolved incident drops off the open list, so nothing needs cleaning up.
function Get-IncidentKey($s, $i) {
    if ($i.url -and $i.url.TrimEnd('/') -ne ([string]$s.statusPage).TrimEnd('/')) { "url:$($i.url)" } else { "title:$($s.id):$($i.title)" }
}
# acknowledgements already on the previous page, to keep their "since" time (Slack doesn't
# say when a reaction was added), and to reuse if Slack can't be reached this time
$previousAcks = @{}
foreach ($s in $previous.services) { foreach ($i in $s.open) { if ($i.ack) { $previousAcks[(Get-IncidentKey $s $i)] = $i.ack } } }

# every string in a Slack message (text, attachments, blocks, shared-message copies)
function Get-Strings($o) {
    if ($null -eq $o) { return }
    if ($o -is [string]) { return $o }
    if ($o -is [System.Collections.IEnumerable]) { foreach ($x in $o) { Get-Strings $x }; return }
    if ($o -is [psobject]) { foreach ($p in $o.PSObject.Properties) { if ($p.Name -ne 'reactions') { Get-Strings $p.Value } } }
}
function Invoke-Slack($method, $query) {
    $r = Invoke-RestMethod -Uri "https://slack.com/api/$method`?$query" -Headers @{ Authorization = "Bearer $SlackToken" } -TimeoutSec 30
    if (-not $r.ok) { throw "Slack $method failed: $($r.error)$(if ($r.needed) { " (needs scope $($r.needed))" })" }
    $r
}
function Get-SlackAcks {
    # posts with a check-mark reaction, from the last 30 days of every channel the app is in
    $oldest = [DateTimeOffset]::UtcNow.AddDays(-30).ToUnixTimeSeconds()
    $channels = @((Invoke-Slack 'users.conversations' 'types=public_channel,private_channel&exclude_archived=true&limit=200').channels)
    Write-Host "Slack: checking $($channels.Count) channels for $($AckEmoji -join '/') reactions"
    $posts = @()
    foreach ($c in $channels) {
        $cursor = ''
        for ($page = 0; $page -lt 5; $page++) {
            $r = Invoke-Slack 'conversations.history' "channel=$($c.id)&oldest=$oldest&limit=200&cursor=$([uri]::EscapeDataString($cursor))"
            foreach ($m in $r.messages) {
                $users = @($m.reactions | Where-Object { $_.name -in $AckEmoji } | ForEach-Object { $_.users })
                if ($users) {
                    $text = (@(Get-Strings $m) -join "`n") -replace '&(apos|#39);', "'" -replace '&quot;', '"' -replace '&lt;', '<' -replace '&gt;', '>' -replace '&amp;', '&'
                    $posts += [pscustomobject]@{ text = $text; users = $users; channel = $c.id; ts = $m.ts; replies = [int]$m.reply_count }
                }
            }
            $cursor = $r.response_metadata.next_cursor
            if (-not $cursor) { break }
        }
    }
    $posts
}

$open = @(foreach ($s in $list) { foreach ($i in $s.open) { [pscustomobject]@{ s = $s; i = $i; key = (Get-IncidentKey $s $i) } } })
$acks = $null
if ($open -and $SlackToken) {
    try {
        $posts = Get-SlackAcks
        $names = @{}
        $acks = @{}
        foreach ($o in $open) {
            $needle = if ($o.key -like 'url:*') { $o.i.url } else { $o.i.title }
            $matched = @($posts | Where-Object { $_.text.Contains($needle) })
            $users = @($matched | ForEach-Object { $_.users } | Select-Object -Unique)
            if (-not $users) { continue }
            # the comment: the newest thread reply on an acknowledged post, e.g. "not impacting us"
            $comment = $null
            foreach ($p in $matched | Where-Object replies | Sort-Object { [double]$_.ts } -Descending) {
                $reply = @((Invoke-Slack 'conversations.replies' "channel=$($p.channel)&ts=$($p.ts)&limit=200").messages |
                           Where-Object { $_.ts -ne $p.ts -and $_.text }) | Select-Object -Last 1
                if ($reply) {
                    $comment = $reply.text -replace '<(https?://[^|>]+)\|([^>]+)>', '$2' -replace '<(https?://[^>]+)>', '$1' -replace '<[@#!][^>|]*\|?([^>]*)>', '$1' -replace '&(apos|#39);', "'" -replace '&quot;', '"' -replace '&lt;', '<' -replace '&gt;', '>' -replace '&amp;', '&'
                    if ($comment.Length -gt 300) { $comment = $comment.Substring(0, 300) + '…' }
                    break
                }
            }
            $by = foreach ($u in $users) {
                if (-not $names.ContainsKey($u)) {
                    $names[$u] = try { $p = (Invoke-Slack 'users.info' "user=$u").user
                                       @($p.profile.display_name, $p.real_name, $p.name, $u) | Where-Object { $_ } | Select-Object -First 1 }
                                 catch { Write-Host "Couldn't look up Slack user $u ($($_.Exception.Message))"; $u }
                }
                $names[$u]
            }
            $since = if ($previousAcks[$o.key]) { $previousAcks[$o.key].since } else { $now }
            $acks[$o.key] = [ordered]@{ by = @($by); since = $since; comment = $(if ($comment) { $comment } else { 'Not impacting us' }) }
        }
    } catch {
        Write-Host "::warning::Couldn't read acknowledgements from Slack, keeping the previous ones: $($_.Exception.Message)"
        $acks = $previousAcks
    }
} elseif ($open) {
    Write-Host 'No SLACK_BOT_TOKEN, so no acknowledgements'
    $acks = @{}
}

# level: worst open incident that isn't acknowledged (same rule as status-to-slack.ps1)
$impactRank = @{ none = 0; minor = 1; major = 2; critical = 3 }
foreach ($s in $list) {
    if ($null -eq $acks) { break }
    $level = 'none'
    foreach ($i in $s.open) {
        $ack = $acks[(Get-IncidentKey $s $i)]
        if ($ack) { $i | Add-Member -NotePropertyName ack -NotePropertyValue $ack -Force; Write-Host "$($s.name): '$($i.title)' acknowledged by $($ack.by -join ', ')" }
        else { $i.PSObject.Properties.Remove('ack') }
    }
    $live = @($s.open | Where-Object { -not $_.ack })
    foreach ($i in $live | Where-Object { $_.kind -ne 'Maintenance' }) {
        $r = [Math]::Max(1, [int]$impactRank[[string]$i.impact])
        if ($r -gt $impactRank[$level]) { $level = @('none', 'minor', 'major', 'critical')[$r] }
    }
    if ($level -eq 'none' -and ($live | Where-Object { $_.kind -eq 'Maintenance' })) { $level = 'maintenance' }
    $s.level = $level
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'site\*') $OutDir -Recurse -Force
New-Item -ItemType File -Force -Path (Join-Path $OutDir '.nojekyll') | Out-Null   # serve files as they are
$json = [ordered]@{
    generatedAt = $now
    run         = [ordered]@{
        trigger         = $Trigger
        url             = $RunUrl
        lastSchedulerAt = $lastScheduler
    }
    services    = $list
} | ConvertTo-Json -Depth 8
# UTF-8 without a byte-order mark, which Windows PowerShell's -Encoding UTF8 would add
[IO.File]::WriteAllText((Join-Path (Resolve-Path $OutDir) 'status.json'), $json, (New-Object Text.UTF8Encoding $false))
Write-Host "Wrote $OutDir with $($list.Count) services"
