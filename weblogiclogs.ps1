# CMiC's WebLogic log index (nginx directory listing, one folder per server). It's only reachable
# on CMiC's network, so this provider runs on a machine inside it (see weblogic-logs\README.md),
# not in GitHub Actions. Its address comes from the WEBLOGIC_LOGS_URL environment variable, set
# by the runner, so it isn't in this public repository.
#
# The repository and status page are public, so server names go to Slack only (one post when a
# server's logs stop, one when they come back). The page shows just a count, "3 of 47 servers'
# logs not updating (6%)", and the tile's level follows the share of servers affected:
# up to 5% minor, up to 15% major, above that critical. The count can't be acknowledged with a
# Slack reaction, so a growing outage can't hide behind an earlier acknowledgement.
#
# A server's logs count as "not updating" when a watched file (by default the server's
# <server>_*_adminServer.out, which WebLogic writes to every minute or so) is 0 bytes and hasn't
# been touched for "zeroMinutes". It stays open until the file has data again, so the hourly
# rotation touching an empty file doesn't close and reopen it. One incident per server.
#
# Settings, under "logs" in services\<id>.json (all optional):
#   files               wildcards of the files to watch; {server} is the folder name
#   zeroMinutes         how long a file may sit at 0 bytes (default 5)
#   notUpdatedMinutes   also flag a file with data that hasn't changed for this long (0 = off)
#   ignoreOlderThanDays files untouched for longer are treated as a retired server (default 14)
#   ignoreServers       folder names (wildcards) to skip, e.g. servers being rebuilt
#   minorUpToPercent    share of servers not updating that's still "minor" (default 5)
#   majorUpToPercent    up to this share it's "major"; above it "critical" (default 15)
#   timeZone            time zone of the listing's dates (default Eastern)

function Get-StatusFeed($Config, [switch]$IncludeMaintenance, $Saved) {
    $o = $Config.logs
    $url          = $(if ($env:WEBLOGIC_LOGS_URL) { $env:WEBLOGIC_LOGS_URL } else { [string]$Config.url })
    if (-not $url) { throw 'No log index address: set WEBLOGIC_LOGS_URL (run-weblogic-logs.ps1 -SaveSecrets)' }
    $base         = $url.TrimEnd('/') + '/'
    $patterns     = @($(if ($o.files) { $o.files } else { '{server}_*_adminServer.out' }))
    $zeroMin      = $(if ($null -ne $o.zeroMinutes) { [double]$o.zeroMinutes } else { 5 })
    $quietMin     = $(if ($null -ne $o.notUpdatedMinutes) { [double]$o.notUpdatedMinutes } else { 0 })
    $retiredDays  = $(if ($null -ne $o.ignoreOlderThanDays) { [double]$o.ignoreOlderThanDays } else { 14 })
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

    $previous = @{}
    foreach ($p in @($Saved.open)) {
        if ($p) { $p.since = (ConvertTo-Utc $p.since).ToString('o'); $previous[[string]$p.server] = $p }
    }

    $open = @{}; $checked = 0; $retired = 0; $failed = @()
    foreach ($folder in $root.rows | Where-Object { $_.size -eq '-' -and $_.name.EndsWith('/') -and $_.name -ne '../' }) {
        $server = $folder.name.TrimEnd('/')
        if ($ignore | Where-Object { $server -like $_ }) { continue }
        try { $files = (Get-Listing "$base$($folder.name)").rows }
        catch {
            # can't tell either way, so an open incident stays as it was
            $failed += $server
            if ($previous[$server]) { $open[$server] = $previous[$server] }
            continue
        }
        $watched = @($files | Where-Object { $f = $_; $patterns | Where-Object { $f.name -like $_.Replace('{server}', $server) } })
        $live = @($watched | Where-Object { ($now - $_.time).TotalDays -le $retiredDays })
        if (-not $live) { if ($watched) { $retired++ }; continue }
        $checked++

        $bad = foreach ($f in $live) {
            $age = $now - $f.time
            if ($f.size -eq '0' -and ($age.TotalMinutes -ge $zeroMin -or $previous[$server])) {
                [pscustomobject]@{ file = $f.name; since = $f.time; why = 'empty' }
            } elseif ($quietMin -gt 0 -and $f.size -ne '0' -and $age.TotalMinutes -ge $quietMin) {
                [pscustomobject]@{ file = $f.name; since = $f.time; why = 'quiet' }
            }
        }
        $bad = @($bad)
        if (-not $bad) { continue }
        # keep the original start time while it stays open (rotation re-touches empty files)
        $since = if ($previous[$server]) { ConvertTo-Utc $previous[$server].since }
                 else { ($bad | Sort-Object since | Select-Object -First 1).since }
        $open[$server] = [pscustomobject]@{
            server = $server
            since  = $since.ToUniversalTime().ToString('o')
            # the time in the link makes each occurrence its own incident for Slack acknowledgements
            url    = "$base$server/#since-$($since.ToUniversalTime().ToString('yyyyMMddTHHmm'))"
            files  = @($bad | ForEach-Object { $_.file })
            detail = (@($bad | ForEach-Object {
                $what = if ($_.why -eq 'empty') { 'is 0 bytes' } else { 'has not changed' }
                "$($_.file) $what since $(Format-Local $_.since)"
            }) -join "`n")
        }
    }

    # level from the share of servers not updating, rounded to a whole percent
    $pct = if ($checked) { [Math]::Round(100 * $open.Count / $checked) } else { 0 }
    $impact = if (-not $open.Count) { 'none' } elseif ($pct -le $minorUpTo) { 'minor' } elseif ($pct -le $majorUpTo) { 'major' } else { 'critical' }
    $color  = @{ none = 'green'; minor = 'yellow'; major = 'orange'; critical = 'red' }[$impact]

    # Slack: one post per server when its logs stop, colored by the overall level at the time
    $updates = @()
    foreach ($s in $open.Values) {
        $since = ConvertTo-Utc $s.since
        $updates += [pscustomobject]@{
            id         = "stale|$($s.server)|$($s.since)"
            time       = $since.ToString('o')
            kind       = 'Incident'
            title      = "Logs not updating: $($s.server)"
            url        = $s.url
            status     = 'Detected'
            color      = $color
            impact     = $impact
            impactText = "$($open.Count) of $checked servers ($pct%)"
            affects    = @($s.files)
            body       = "$($s.detail)`nFor $(Format-Age ($now - $since))."
        }
    }
    # ... and one when they come back (only in this run's feed, so it's never posted twice)
    foreach ($p in $previous.Values) {
        if ($open.ContainsKey([string]$p.server)) { continue }
        $since = ConvertTo-Utc $p.since
        $updates += [pscustomobject]@{
            id         = "ok|$($p.server)|$($p.since)"
            time       = $now.ToString('o')
            kind       = 'Incident'
            title      = "Logs not updating: $($p.server)"
            url        = $p.url
            status     = 'Resolved'
            color      = 'green'
            impact     = 'none'
            impactText = "$($open.Count) of $checked servers still not updating"
            affects    = @($p.files)
            body       = "Logs are being written again. They stopped for $(Format-Age ($now - $since))."
        }
    }

    if ($failed) { Write-Host "Couldn't read $($failed.Count) folder(s): $($failed -join ', ')" }
    Write-Host "Checked $checked servers ($retired retired, skipped): $($open.Count) not updating ($pct%, $impact)"
    if (-not $checked -and -not $failed) { throw "No server folders with watched files found at $base" }

    # The page: one entry with the count, no server names. Its "since" is the oldest open one.
    $incidents = @()
    if ($open.Count) {
        $oldest = ($open.Values | ForEach-Object { ConvertTo-Utc $_.since } | Sort-Object | Select-Object -First 1)
        $incidents += [pscustomobject]@{
            key = 'weblogic-count'; open = $true; url = ''; affects = @()
            title      = "$($open.Count) of $checked servers' logs not updating ($pct%)"
            kind       = 'Incident'
            status     = 'Detected'
            color      = $color
            impact     = $impact
            impactText = ''
            time       = $oldest.ToString('o')
        }
    }

    @{
        overall   = $null      # the count above says it; the tile has no vendor headline
        updates   = $updates
        incidents = $incidents
        extra     = @{ open = @($open.Values) }
    }
}
