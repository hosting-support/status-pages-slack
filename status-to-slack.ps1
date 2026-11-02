<#
.SYNOPSIS
  Polls a vendor status page and posts changes to Slack.

.DESCRIPTION
  One script for every service. Each service has a settings file in services\ (which status
  page, Slack label, default filters) and each kind of status page has an adapter in
  providers\ that turns that page's data into a common shape:

    overall    @{ indicator = none|minor|major|critical|maintenance; description }   (or $null)
    updates    one per incident/event update, each with
               id, time, title, url, kind, status, color, impact, impactText, affects, body
               (impact is none|minor|major|critical for the minImpact filter; affects are the
               names the categories filter matches; optional showAffects is what gets printed)
    components @{ <id> = @{ name; status; color } }   (only for -Components watching)
    extra      anything the provider wants saved for its next run (optional)
    keepIds    seen update ids to keep although not in this run's updates (optional)

  This script does the rest, the same way for every service: compares with the state saved by
  the previous run, applies the filters, posts to Slack and saves the new state.

  Posts are sent when:
    - the overall status changes (if the page has one)
    - an incident gets a new update (investigating / identified / monitoring / resolved ...)
    - optionally, scheduled maintenance gets a new update (includeMaintenance)
    - optionally, a watched component changes status (components)

  The first run only records the current state and posts nothing, so you don't get flooded
  with old incidents.

  Settings come from services\<name>.json; each can be overridden by an environment variable
  (CATEGORIES, MIN_IMPACT, SKIP_UNTAGGED, SKIP_OVERALL_STATUS, SLACK_LABEL), which is how the
  GitHub workflow passes the repo's Actions variables.

.EXAMPLE
  .\status-to-slack.ps1 -Service smtp2go -DryRun

.EXAMPLE
  $env:SLACK_WEBHOOK_URL = 'https://hooks.slack.com/services/XXX/YYY/ZZZ'
  .\status-to-slack.ps1 -Service aws
#>
param(
    [Parameter(Mandatory)]
    [string] $Service,                       # name of a file in services\, e.g. 'cloudflare'
    [string] $WebhookUrl = $env:SLACK_WEBHOOK_URL,
    [string] $StateFile  = (Join-Path $PSScriptRoot "state\$Service.json"),
    [switch] $DryRun,                        # print messages instead of posting
    [switch] $TestPost                       # also post the newest update, to preview the format
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---- settings: services\<name>.json, then env var overrides ----
$configPath = Join-Path $PSScriptRoot "services\$Service.json"
if (-not (Test-Path $configPath)) { throw "No settings file $configPath" }
$Config = Get-Content $configPath -Raw | ConvertFrom-Json

function Get-Setting($name, $envName, $default) {
    $v = [Environment]::GetEnvironmentVariable($envName)
    if ($v) { return $v }
    if ($null -ne $Config.$name) { return $Config.$name }
    $default
}
function Split-List($v) { @($v -split '[;\r\n]' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

$Name              = Get-Setting 'name' '-' $Service
$Label             = Get-Setting 'label' 'SLACK_LABEL' "*$Name Status*"
$MinImpact         = Get-Setting 'minImpact' 'MIN_IMPACT' 'none'
$SkipUntagged      = [string](Get-Setting 'skipUntagged' 'SKIP_UNTAGGED' $false) -eq 'true'
$SkipOverallStatus = [string](Get-Setting 'skipOverallStatus' 'SKIP_OVERALL_STATUS' $false) -eq 'true'
$IncludeMaintenance = [string](Get-Setting 'includeMaintenance' '-' $false) -eq 'true'
# Wildcard names; an update is posted if it affects any of them. Empty = everything.
# Arrays in the JSON file, or ';' / new-line separated in the env var (names contain commas).
$Categories = $(if ($env:CATEGORIES) { Split-List $env:CATEGORIES } else { @($Config.categories | Where-Object { $_ }) })
$Components = @($Config.components | Where-Object { $_ })   # wildcard component names to watch

$impactRank = @{ none = 0; minor = 1; major = 2; critical = 3 }
if (-not $impactRank.ContainsKey($MinImpact)) { throw "minImpact must be none, minor, major or critical (got '$MinImpact')" }
if (-not $DryRun -and -not $WebhookUrl) {
    throw 'No Slack webhook. Pass -WebhookUrl or set SLACK_WEBHOOK_URL (or use -DryRun).'
}

# ---- helpers shared with the providers ----
function Get-Json($url) { Invoke-RestMethod -Uri $url -TimeoutSec 30 -Headers @{ 'User-Agent' = 'status-to-slack' } }

function ConvertFrom-Html($html) {
    $t = $html -replace '(?i)<br\s*/?>|</p>|</li>|</div>', "`n" -replace '(?i)<li[^>]*>', '- ' -replace '<[^>]+>', ''
    [Net.WebUtility]::HtmlDecode($t)
}

# Colors are shared names so every provider can pick one; the provider decides which fits.
$colors = @{
    green  = @{ hex = '#2EB67D'; emoji = ':large_green_circle:' }
    yellow = @{ hex = '#ECB22E'; emoji = ':large_yellow_circle:' }
    orange = @{ hex = '#F38020'; emoji = ':large_orange_circle:' }
    red    = @{ hex = '#E01E5A'; emoji = ':red_circle:' }
    blue   = @{ hex = '#1D9BD1'; emoji = ':wrench:' }
    grey   = @{ hex = '#A0A0A0'; emoji = ':white_circle:' }
}
function Get-Color($name) { if ($name -and $colors[$name]) { $colors[$name] } else { $colors.grey } }
$indicatorColor = @{ none = 'green'; minor = 'yellow'; major = 'orange'; critical = 'red'; maintenance = 'blue' }

# Posts as an attachment: colored bar on the left, label header, then the message
function Send-Slack($text, $color) {
    $c = Get-Color $color
    if ($DryRun) { Write-Host "---- would post ($($c.hex)) ----`n$Label`n$text`n"; return }
    $json = @{
        unfurl_links = $false
        attachments  = @(@{
            color    = $c.hex
            fallback = ($text -replace '[*>]', '')
            blocks   = @(
                @{ type = 'context'; elements = @(@{ type = 'mrkdwn'; text = $Label }) },
                @{ type = 'section'; text = @{ type = 'mrkdwn'; text = $text } }
            )
        })
    } | ConvertTo-Json -Depth 8 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)   # PS 5.1 otherwise mangles non-ASCII
    Invoke-RestMethod -Uri $WebhookUrl -Method Post -ContentType 'application/json; charset=utf-8' -Body $bytes | Out-Null
}

function Format-Body($body) {
    $t = ([string]$body -replace '\r', '' -replace '[ \t]+\n', "`n" -replace '\n{3,}', "`n`n").Trim()
    if ($t.Length -gt 1500) { $t = $t.Substring(0, 1500) + '...' }
    # Slack mrkdwn needs &, <, > escaped
    $t -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
}

# ---- load previous state ----
$firstRun = -not (Test-Path $StateFile)
$state = @{ indicator = $null; seen = @(); components = @{}; extra = $null }
if (-not $firstRun) {
    $saved = Get-Content $StateFile -Raw | ConvertFrom-Json
    $state.indicator = $saved.indicator
    $state.seen      = @($saved.seen)
    $state.extra     = $saved.extra
    if ($saved.components) { $saved.components.PSObject.Properties | ForEach-Object { $state.components[$_.Name] = $_.Value } }
}
$seen = New-Object 'System.Collections.Generic.HashSet[string]'
$state.seen | ForEach-Object { [void]$seen.Add($_) }

# ---- fetch, via the provider adapter ----
$providerPath = Join-Path $PSScriptRoot "providers\$($Config.provider).ps1"
if (-not (Test-Path $providerPath)) { throw "Unknown provider '$($Config.provider)' (no $providerPath)" }
. $providerPath
# Providers get the settings and their own saved data (e.g. what they fetched last time)
$feed = Get-StatusFeed -Config $Config -IncludeMaintenance:$IncludeMaintenance -Saved $state.extra

function Test-Wanted($u) {
    if ($u.kind -ne 'Maintenance' -and [int]$impactRank[[string]$u.impact] -lt $impactRank[$MinImpact]) { return $false }
    if (-not $Categories.Count) { return $true }
    if (-not $u.affects) { return -not $SkipUntagged }
    foreach ($name in $u.affects) {
        if ($name -and ($Categories | Where-Object { $name -like $_ })) { return $true }
    }
    $false
}

$messages = New-Object System.Collections.Generic.List[object]   # @{ text; color }

# ---- overall status ----
$indicator = $feed.overall.indicator
if (-not $firstRun -and -not $SkipOverallStatus -and $indicator -and $state.indicator -and $indicator -ne $state.indicator) {
    $color = $indicatorColor[$indicator]
    $messages.Add(@{ color = $color; text = "$((Get-Color $color).emoji) *$Name status: $($feed.overall.description)*  (<$($Config.url)|status page>)" })
}

# ---- incident / maintenance updates (oldest first so Slack reads in order) ----
$updates = @($feed.updates | Where-Object { $_ })
$newUpdates = @($updates | Where-Object { -not $seen.Contains($_.id) })
if ($TestPost) {
    $latest = $updates | Where-Object { $_.kind -ne 'Maintenance' } | Sort-Object { [datetime]$_.time } -Descending | Select-Object -First 1
    if ($latest) { $newUpdates = @($latest | Select-Object *, @{ n = 'test'; e = { $true } }) + $newUpdates }
}
foreach ($u in ($newUpdates | Sort-Object { [datetime]$_.time })) {
    [void]$seen.Add($u.id)
    # filtered-out updates still count as seen, so changing the filter later doesn't replay them
    if (-not $u.test -and ($firstRun -or -not (Test-Wanted $u))) { continue }
    # showAffects: what to print, when it differs from the names used for filtering
    $affects = @($(if ($null -ne $u.showAffects) { $u.showAffects } else { $u.affects }) | Where-Object { $_ })
    $affectsText = if ($affects.Count -gt 5) { ($affects[0..4] -join ', ') + " +$($affects.Count - 5) more" } else { $affects -join ', ' }
    $title = if ($u.url) { "<$($u.url)|$(Format-Body $u.title)>" } else { Format-Body $u.title }
    $details = @(
        $(if ($u.impactText) { "Impact: $($u.impactText)" }),
        $(if ($affectsText) { "Affects: $(Format-Body $affectsText)" })
    ) | Where-Object { $_ }
    $body = Format-Body $u.body
    $messages.Add(@{ color = $u.color; text =
        "$((Get-Color $u.color).emoji) *$($u.kind) $($u.status):* $title" +
        $(if ($details) { "`n" + ($details -join '  |  ') }) +
        $(if ($body) { "`n> " + ($body -replace "`n", "`n> ") }) })
}

# ---- watched components ----
$watched = @{}
if ($Components.Count -and $feed.components) {
    foreach ($id in $feed.components.Keys) {
        $c = $feed.components[$id]
        if (-not ($Components | Where-Object { $c.name -like $_ })) { continue }
        $watched[$id] = $c.status
        $old = $state.components[$id]
        if (-not $firstRun -and $old -and $old -ne $c.status) {
            $messages.Add(@{ color = $c.color; text = "$((Get-Color $c.color).emoji) *Component $($c.name):* $($old -replace '_',' ') -> $($c.status -replace '_',' ')" })
        }
    }
}

# ---- send + save ----
foreach ($m in $messages) { Send-Slack $m.text $m.color }

# keep only ids still present in the feed so the state file doesn't grow forever
# (keepIds: updates the provider knows about but skipped fetching this time)
$liveIds = @($updates.id) + @($feed.keepIds)
New-Item -ItemType Directory -Force -Path (Split-Path $StateFile) | Out-Null
@{
    indicator  = $indicator
    seen       = @($liveIds | Where-Object { $seen.Contains($_) })
    components = $watched
    extra      = $feed.extra
} | ConvertTo-Json -Depth 6 | Set-Content -Path $StateFile -Encoding UTF8

$statusText = if ($feed.overall) { $feed.overall.description } else { "$($updates.Count) updates in feed" }
if ($firstRun) { Write-Host "First run: saved baseline ($statusText, $($seen.Count) updates). Nothing posted." }
else           { Write-Host "Posted $($messages.Count) message(s). Status: $statusText" }
