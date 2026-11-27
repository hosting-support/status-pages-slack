# CMiC's WebLogic log index (nginx directory listing, one folder per server). It's only reachable
# on CMiC's network, so this provider runs on a machine inside it (see weblogic-logs\README.md),
# not in GitHub Actions. Its address comes from the WEBLOGIC_LOGS_URL environment variable, set
# by the runner, so it isn't in this public repository.
#
# What counts as "not updating": nothing in a server's folder has changed for "staleMinutes"
# (default 30). That's what it looks like when the copy to the logs page stops for a server.
# (An earlier version watched for an empty adminServer.out, but on most servers that file sits
# empty for hours after each hourly rotation while the other logs keep arriving, so it alerted
# all day long.)
#
# A server silent for more than "silentAfterHours" (default 24) is left out of the count: it was
# posted when it stopped, and it's most likely stopped or retired. The tile notes how many there
# are, and Slack says so when one comes back.
#
# The repository and status page are public, so server names go to Slack only. The page shows a
# count, "3 of 34 servers' logs not updating (9%)", and the level follows the share of servers:
# up to 5% minor, up to 15% major, above that critical.
#
# Slack gets one post per check, only when something changed: which servers stopped, which came
# back, and which went silent for over a day. If the copy stops everywhere at once, that's one
# post, not one per server.
#
# Settings, under "logs" in services\<id>.json (all optional):
#   staleMinutes        how long a folder may go without a new or changed file (default 30)
#   silentAfterHours    after this long, a server is left out of the count (default 24)
#   ignoreOlderThanDays folders with nothing newer than this are skipped altogether (default 14)
#   ignoreServers       folder names (wildcards) to skip, e.g. retired servers
#   minorUpToPercent    share of servers not updating that's still "minor" (default 5)
#   majorUpToPercent    up to this share it's "major"; above it "critical" (default 15)
#   timeZone            time zone of the listing's dates (default Eastern)

function Get-StatusFeed($Config, [switch]$IncludeMaintenance, $Saved) {
    $o = $Config.logs
    $url          = $(if ($env:WEBLOGIC_LOGS_URL) { $env:WEBLOGIC_LOGS_URL } else { [string]$Config.url })
    if (-not $url) { throw 'No log index address: set WEBLOGIC_LOGS_URL (run-weblogic-logs.ps1 -SaveSecrets)' }
    $base         = $url.TrimEnd('/') + '/'
    $staleMin     = $(if ($null -ne $o.staleMinutes) { [double]$o.staleMinutes } else { 30 })
    $silentHours  = $(if ($null -ne $o.silentAfterHours) { [double]$o.silentAfterHours } else { 24 })
    $skipDays     = $(if ($null -ne $o.ignoreOlderThanDays) { [double]$o.ignoreOlderThanDays } else { 14 })
    $ignore       = @($o.ignoreServers | Where-Object { $_ })
    $minorUpTo    = $(if ($null -ne $o.minorUpToPercent) { [double]$o.minorUpToPercent } else { 5 })
    $majorUpTo    = $(if ($null -ne $o.majorUpToPercent) { [double]$o.majorUpToPercent } else { 15 })

    # the listing shows the server's local time; Windows PowerShell only knows Windows zone names
    $tz = $null
    foreach ($id in @($o.timeZone, 'America/New_York', 'Eastern Standard Time') | Where-Object { $_ }) {
        try { $tz = [TimeZoneInfo]::FindSystemTimeZoneById($id); break } catch { }
    }
    if (-not $tz) { throw 'No time zone found for the log listing' }
    $culture = [Globalization.CultureInfo]::InvariantCulture

    function Get-Listing($url) {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -Headers @{ 'User-Agent' = 'status-to-slack' }
        $rows = foreach ($m in [regex]::Matches($r.Content, '<a href="([^"?]+)">[^<]*</a>\s+(\d{2}-[A-Za-z]{3}-\d{4} \d{2}:\d{2})\s+(\S+)')) {
            $local = [datetime]::ParseExact($m.Groups[2].Value, 'dd-MMM-yyyy HH:mm', $culture)
            [pscustomobject]@{
                name = [uri]::UnescapeDataString($m.Groups[1].Value)
                time = [TimeZoneInfo]::ConvertTimeToUtc($local, $tz)
                size = $m.Groups[3].Value          # '-' for folders, '0', '3733', '45K', '12M'
            }
        }
        @{ rows = @($rows); date = $r.Headers['Date'] }
    }
    function Format-Age($span) {
        if ($span.TotalHours -ge 24) { '{0}d {1}h' -f [int][Math]::Floor($span.TotalDays), $span.Hours }
        elseif ($span.TotalMinutes -ge 60) { '{0}h {1}m' -f [int][Math]::Floor($span.TotalHours), $span.Minutes }
        else { '{0}m' -f [int][Math]::Floor($span.TotalMinutes) }
    }
    # saved times come back as strings (Windows PowerShell) or dates (PowerShell 7); both are UTC
    function ConvertTo-Utc($v) {
        if ($v -is [datetime]) { if ($v.Kind -eq 'Local') { $v.ToUniversalTime() } else { [datetime]::SpecifyKind($v, 'Utc') } }
        else { [datetimeoffset]::Parse([string]$v, $culture, [Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime }
    }
    function Format-Local($utc) { [TimeZoneInfo]::ConvertTimeFromUtc($utc, $tz).ToString('MMM d HH:mm', $culture) + ' ET' }

    $root = Get-Listing $base
    # "now" from the log server's own clock, so a wrong clock on this machine doesn't matter
    $now = try { ([datetimeoffset]::Parse([string]$root.date, $culture)).UtcDateTime } catch { [datetime]::UtcNow }

    # what the last run saw. State from before this version (v2) is just a baseline: nothing is
    # posted for the switch-over.
    $first = -not ($Saved -and $Saved.v -eq 2)
    $prevOpen = @{}; $prevSilent = @{}
    if (-not $first) {
        foreach ($p in @($Saved.open))   { if ($p) { $prevOpen[[string]$p.server]   = ConvertTo-Utc $p.since } }
        foreach ($p in @($Saved.silent)) { if ($p) { $prevSilent[[string]$p.server] = ConvertTo-Utc $p.since } }
    }

    $open = @{}; $silent = @{}; $checked = 0; $failed = @()
    foreach ($folder in $root.rows | Where-Object { $_.size -eq '-' -and $_.name.EndsWith('/') -and $_.name -ne '../' }) {
        $server = $folder.name.TrimEnd('/')
        if ($ignore | Where-Object { $server -like $_ }) { continue }
        try { $files = @((Get-Listing "$base$($folder.name)").rows | Where-Object { $_.size -ne '-' }) }
        catch {
            # can't tell either way, so the server keeps its last state
            $failed += $server
            if ($prevOpen.ContainsKey($server))   { $open[$server]   = $prevOpen[$server];   $checked++ }
            if ($prevSilent.ContainsKey($server)) { $silent[$server] = $prevSilent[$server] }
            continue
        }
        if (-not $files) { continue }
        $last = ($files | Measure-Object time -Maximum).Maximum      # newest file in the folder
        $age  = $now - $last
        if ($age.TotalDays -gt $skipDays) { continue }                # long gone: not mentioned at all
        if ($age.TotalHours -ge $silentHours) { $silent[$server] = $last; continue }
        $checked++
        if ($age.TotalMinutes -ge $staleMin) { $open[$server] = $last }
    }

    # level from the share of (counted) servers not updating, rounded to a whole percent
    $pct = if ($checked) { [Math]::Round(100 * $open.Count / $checked) } else { 0 }
    $impact = if (-not $open.Count) { 'none' } elseif ($pct -le $minorUpTo) { 'minor' } elseif ($pct -le $majorUpTo) { 'major' } else { 'critical' }
    $color  = @{ none = 'green'; minor = 'yellow'; major = 'orange'; critical = 'red' }[$impact]

    if ($failed) { Write-Host "Couldn't read $($failed.Count) folder(s): $($failed -join ', ')" }
    Write-Host "Checked $checked servers, $($silent.Count) silent for over $silentHours h (not counted): $($open.Count) not updating ($pct%, $impact)"
    if (-not $checked -and -not $silent.Count -and -not $failed) { throw "No server folders with files found at $base" }

    # ---- Slack: one post per check, only when something changed ----
    $stopped  = @($open.Keys   | Where-Object { -not $prevOpen.ContainsKey($_) -and -not $prevSilent.ContainsKey($_) } | Sort-Object)
    $back     = @($prevOpen.Keys + $prevSilent.Keys | Select-Object -Unique |
                  Where-Object { -not $open.ContainsKey($_) -and -not $silent.ContainsKey($_) -and -not ($failed -contains $_) } | Sort-Object)
    $wentQuiet = @($silent.Keys | Where-Object { -not $prevSilent.ContainsKey($_) } | Sort-Object)
    # silent ones that come back to merely "not updating" count as stopped again
    $stopped += @($open.Keys | Where-Object { $prevSilent.ContainsKey($_) } | Sort-Object)

    # at most 10 names per list, so a post stays readable (and under Slack's length limit)
    function Limit-List($names, [scriptblock]$line) {
        @($names | Select-Object -First 10 | ForEach-Object $line) +
        @($(if ($names.Count -gt 10) { "- and $($names.Count - 10) more" }))
    }
    $updates = @()
    if (-not $first -and ($stopped -or $back -or $wentQuiet)) {
        $lines = @()
        if ($stopped) {
            $lines += "Stopped updating (nothing new for $staleMin+ min):"
            $lines += Limit-List $stopped { "- $_ - last file $(Format-Local $open[$_])" }
        }
        if ($back) {
            $lines += 'Updating again:'
            $lines += Limit-List $back {
                $since = if ($prevOpen.ContainsKey($_)) { $prevOpen[$_] } else { $prevSilent[$_] }
                "- $_ - was quiet for $(Format-Age ($now - $since))"
            }
        }
        if ($wentQuiet) {
            $lines += "Silent for over $silentHours h, now left out of the count:"
            $lines += Limit-List $wentQuiet { "- $_ - last file $(Format-Local $silent[$_])" }
        }
        $what = @(
            $(if ($stopped) { "$($stopped.Count) stopped" }),
            $(if ($back) { "$($back.Count) back" }),
            $(if ($wentQuiet) { "$($wentQuiet.Count) silent for a day" })
        ) | Where-Object { $_ }
        $updates += [pscustomobject]@{
            # unique per check, so it posts once and is never repeated
            id         = "change|$($now.ToString('o'))|$(($stopped + $back + $wentQuiet) -join ',')"
            time       = $now.ToString('o')
            kind       = 'Incident'
            title      = "Server logs: $($what -join ', ')"
            url        = $base
            status     = $(if ($stopped) { 'Detected' } elseif ($open.Count) { 'Update' } else { 'Resolved' })
            color      = $(if ($stopped -or $open.Count) { $color } else { 'green' })
            impact     = $impact
            impactText = "$($open.Count) of $checked servers not updating ($pct%)"
            affects    = @()
            body       = $lines -join "`n"
        }
    }

    # ---- the page: one entry with the count, no server names ----
    $incidents = @()
    if ($open.Count) {
        $oldest = $open.Values | Sort-Object | Select-Object -First 1
        $incidents += [pscustomobject]@{
            key = 'weblogic-count'; open = $true; url = ''; affects = @()
            title      = "$($open.Count) of $checked servers' logs not updating ($pct%)"
            kind       = 'Incident'
            # the runner sets this while Slack alerts are paused, e.g. "Slack alerts paused until Nov 17 15:00 ET"
            status     = $(if ($env:WEBLOGIC_ALERTS_PAUSED) { $env:WEBLOGIC_ALERTS_PAUSED } else { 'Detected' })
            color      = $color
            impact     = $impact
            impactText = ''
            time       = $oldest.ToString('o')
        }
    }
    $note = if ($silent.Count) { "$($silent.Count) server$(if ($silent.Count -ne 1) { 's' }) silent for over $silentHours h, not counted" }

    @{
        # no Slack post for this (skipOverallStatus); the page shows the description on the tile
        overall    = $(if ($note) { @{ indicator = 'none'; description = $note } } else { $null })
        updates    = $updates
        incidents  = $incidents
        rebaseline = $first
        extra      = @{
            v      = 2
            open   = @($open.Keys   | ForEach-Object { @{ server = $_; since = $open[$_].ToString('o') } })
            silent = @($silent.Keys | ForEach-Object { @{ server = $_; since = $silent[$_].ToString('o') } })
        }
    }
}
