# CMiC's public cloud REST APIs on PROD (the "Public Cloud APIs" section of the status page),
# checked WITHOUT a login. Each service (services\api-<name>.json) is one API, checked on every
# host it lists (ATLAS PROD and NOVA PROD) with one plain GET per run:
#
#   ws-ping   <api>/ws-ping must answer 200 {"ping":"pong"}. The app's own no-login health check:
#             proves the web tier, WebLogic and that app are up (not the database). On PROD today
#             only ECM and Field have it.
#   login     <api>/jersey/v1/api-info, which needs a login, must answer WebLogic's
#             "401--Unauthorized" page. Proves the web tier and WebLogic answer and the app is
#             deployed at that address. Weaker: it doesn't show the app started cleanly. Used
#             for the APIs whose PROD build has no ws-ping yet.
#
# No credentials are sent or stored. A 404 (app missing), 5xx, timeout, redirect to a login page,
# Cloudflare error page or an answer without the expected text counts as a problem. (A version
# check that also proves the database needs a login: see parked\api-login-check.)
#
# Settings, under "api" in services\api-<name>.json:
#   path            the path after each host, e.g. "ecm-rest-api/ws-ping"
#   hosts           { "ATLAS PROD": "https://atlas-api.cmiccloud.com/cmicprod", ... }
#   expectStatus    the HTTP status a healthy app gives (200 for ws-ping, 401 for login)
#   expectText      text the answer must contain ("pong", "401--Unauthorized")
#   checkName       how the check is described on the tile ("ws-ping", "login page")
#   slowSeconds     slower than this counts as a problem (default 20)
#   timeoutSeconds  give up after this long (default 30)
#   failAfter       problems in a row before it's reported (default 2, so one blip doesn't count)

function Get-StatusFeed($Config, [switch]$IncludeMaintenance, $Saved) {
    $o          = $Config.api
    $wantStatus = $(if ($o.expectStatus) { [int]$o.expectStatus } else { 200 })
    $wantText   = [string]$o.expectText
    $checkName  = $(if ($o.checkName) { [string]$o.checkName } else { "HTTP $wantStatus" })
    $slow       = $(if ($o.slowSeconds) { [double]$o.slowSeconds } else { 20 })
    $timeout    = $(if ($o.timeoutSeconds) { [int]$o.timeoutSeconds } else { 30 })
    $failAfter  = $(if ($o.failAfter) { [int]$o.failAfter } else { 2 })
    $apiName    = [string]$Config.name

    # times are kept as 'yyyyMMdd-HHmmss' (UTC), see providers\website.ps1 for why
    $now = (Get-Date).ToUniversalTime()
    $nowKey = $now.ToString('yyyyMMdd-HHmmss')
    $toKey  = { param($v) if ($v -is [datetime]) { $v.ToUniversalTime().ToString('yyyyMMdd-HHmmss') } else { [string]$v } }
    $toDate = { param($k) [datetime]::ParseExact((& $toKey $k), 'yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal') }
    $toTime = { param($k) (& $toDate $k).ToString('o') }
    $stamp  = { param($k) (& $toKey $k).Substring(0, 13) }

    # one GET, never throwing: status code, body and time, or the error
    function Invoke-Check($url) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $req = @{ Uri = $url; UseBasicParsing = $true; TimeoutSec = $timeout; MaximumRedirection = 0
                  Headers = @{ 'User-Agent' = 'cmic-hosting-status-check' } }
        if ($PSVersionTable.PSVersion.Major -ge 7) { $req.SkipHttpErrorCheck = $true }   # 401 etc. come back as answers
        try {
            $r = Invoke-WebRequest @req
            # an answer with no Content-Type (Field's ws-ping) comes back as bytes, not text
            $body = if ($r.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($r.Content) } else { [string]$r.Content }
            @{ code = [int]$r.StatusCode; body = $body; secs = [Math]::Round($sw.Elapsed.TotalSeconds, 1) }
        } catch {
            $secs = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
            $resp = $_.Exception.Response
            if ($resp -and $resp.StatusCode) {
                # Windows PowerShell: an error status arrives as an exception carrying the response
                $body = ''; try { $body = (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd() } catch {}
                @{ code = [int]$resp.StatusCode; body = $body; secs = $secs }
            } else {
                $msg = $_.Exception.Message -replace '\s+', ' '
                if ($msg.Length -gt 100) { $msg = $msg.Substring(0, 100) + '...' }
                @{ code = 0; body = ''; secs = $secs; error = $(if ($secs -ge $timeout - 1) { "didn't answer within $timeout s" } else { "couldn't be reached ($msg)" }) }
            }
        }
    }

    # ---- saved state: per host (problems in a row, open problem) + closed history ----
    $hosts = [ordered]@{}
    foreach ($p in $o.hosts.PSObject.Properties) { $hosts[$p.Name] = [string]$p.Value }
    $state = @{ hosts = @{}; past = @() }
    foreach ($h in $hosts.Keys) {
        $s = if ($Saved -and $Saved.hosts) { $Saved.hosts.$h } else { $null }
        $state.hosts[$h] = @{
            fails = $(if ($s) { [int]$s.fails } else { 0 })
            down  = $(if ($s -and $s.down) { @{ since = (& $toKey $s.down.since); reason = [string]$s.down.reason } } else { $null })
        }
    }
    if ($Saved -and $Saved.past) { $state.past = @($Saved.past | Where-Object { $_ }) }

    $updates = @()
    $base = 'https://status.cmiccloud.com'   # not opened; gives each incident its own link
    function New-Update($id, $title, $status, $color, $body, $time, $anchor, $affects) {
        [pscustomobject]@{ id = $id; time = $time; kind = 'Incident'; title = $title; url = "$base/#$anchor"
                           status = $status; color = $color; impact = 'major'; impactText = 'major'
                           affects = @($affects); body = $body }
    }
    # closed problems, re-listed every run (already handled) for the tile's history
    foreach ($p in $state.past) {
        $updates += New-Update "$($p.id)|open" $p.title 'Down' 'red' $p.openBody (& $toTime $p.since) $p.anchor $p.hostName
        $updates += New-Update "$($p.id)|closed" $p.title 'Back up' 'green' $p.closeBody (& $toTime $p.end) $p.anchor $p.hostName
    }

    $summary = @()
    foreach ($h in $hosts.Keys) {
        $url = "$($hosts[$h].TrimEnd('/'))/$($o.path.TrimStart('/'))"
        $r = Invoke-Check $url
        $problem = if ($r.error) { $r.error }
                   elseif ($r.code -ne $wantStatus) { "returned HTTP $($r.code) (expected $wantStatus)" }
                   elseif ($wantText -and -not $r.body.Contains($wantText)) { "answered HTTP $($r.code) without its usual page" }
                   elseif ($r.secs -gt $slow) { "very slow: $($r.secs) s" }
                   else { $null }
        $st = $state.hosts[$h]
        if ($problem) {
            $st.fails++
            if (-not $st.down -and $st.fails -ge $failAfter) { $st.down = @{ since = $nowKey; reason = $problem } }
            $summary += "${h}: $problem"
        } else {
            $st.fails = 0
            if ($st.down) {
                $d = $st.down
                $mins = [Math]::Round(($now - (& $toDate $d.since)).TotalMinutes)
                $entry = [pscustomobject]@{ id = "down|$h|$($d.since)"; anchor = ("$h-$(& $stamp $d.since)" -replace '\s', '-'); hostName = $h
                    title = "${h}: $apiName API not responding"; since = $d.since; end = $nowKey
                    openBody = "$apiName on $h $($d.reason)."; closeBody = "$apiName on $h is answering again ($($r.secs) s). Down for about $mins min." }
                $state.past = @(@($entry) + @($state.past) | Select-Object -First 5)
                $updates += New-Update "$($entry.id)|open" $entry.title 'Down' 'red' $entry.openBody (& $toTime $entry.since) $entry.anchor $h
                $updates += New-Update "$($entry.id)|closed" $entry.title 'Back up' 'green' $entry.closeBody (& $toTime $entry.end) $entry.anchor $h
                $st.down = $null
            }
            $summary += "${h} up ($($r.secs) s)"
        }
    }
    # open problems: listed as open (their "Down" update), so the tile shows them
    foreach ($h in $hosts.Keys) {
        $d = $state.hosts[$h].down
        if ($d) {
            $updates += New-Update "down|$h|$($d.since)|open" "${h}: $apiName API not responding" 'Down' 'red' `
                "$apiName on $h $($d.reason). Failed $failAfter checks in a row." (& $toTime $d.since) ("$h-$(& $stamp $d.since)" -replace '\s', '-') $h
        }
    }

    $bad = @($hosts.Keys | Where-Object { $state.hosts[$_].down })
    @{
        overall = @{ indicator = $(if ($bad) { 'major' } else { 'none' })
                     description = "$($summary -join " $([char]0xB7) ") $([char]0xB7) $checkName" }
        updates = @($updates)
        extra   = $state
    }
}
