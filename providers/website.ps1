# A direct check of one public web page, added to a service with "website" in its settings
# file, next to whatever its status page says. For example services/onehub.json watches
# Onehub's status page AND opens portal.cmicshare.com (CMiC's File Share, hosted by Onehub)
# itself, so a problem with CMiC's own portal shows even when Onehub reports all clear.
#
# It only loads the page anyone sees before signing in: no account, no credentials. It can
# tell the portal is up and serving its sign-in page, not that signing in or downloading works.
#
# Settings, under "website" in services\<id>.json:
#   url             the page to open (required)
#   name            what to call it in posts and on the page (default: the host name)
#   expect          text the page must contain, so an error or parking page doesn't count as up
#   slowSeconds     slower than this counts as a problem (default 15)
#   timeoutSeconds  give up after this long (default 30)
#   failAfter       checks in a row that must fail before it's reported, so one blip doesn't
#                   post (default 2, which is 5-10 minutes with a check every 5 minutes)
#   certWarnDays    report the security certificate this many days before it expires (default 14)
#
# Each problem is one incident (a "down" post, then a "back up" post) that can be acknowledged
# with a check-mark reaction like any other. Each gets its own link (the page plus "#down-<time>"),
# so an acknowledgement of one outage doesn't carry over to the next. The state (failures in a
# row, the open problem, the last few closed ones for the page's history) is kept in the
# service's state file under "website".

function Get-WebsiteCheck($Website, $Saved) {
    $url       = [string]$Website.url
    $uri       = [uri]$url
    $name      = $(if ($Website.name) { [string]$Website.name } else { $uri.Host })
    $expect    = [string]$Website.expect
    $slow      = $(if ($Website.slowSeconds) { [double]$Website.slowSeconds } else { 15 })
    $timeout   = $(if ($Website.timeoutSeconds) { [int]$Website.timeoutSeconds } else { 30 })
    $failAfter = $(if ($Website.failAfter) { [int]$Website.failAfter } else { 2 })
    $certDays  = $(if ($Website.certWarnDays) { [int]$Website.certWarnDays } else { 14 })
    $now = (Get-Date).ToUniversalTime()
    # Times are kept as 'yyyyMMdd-HHmmss' (UTC) in the state file: PowerShell 7 would turn an ISO
    # date string into a date object when it reads the file back, changing the post ids built from it.
    $nowKey = $now.ToString('yyyyMMdd-HHmmss')
    $nowText = $now.ToString('o')
    $toKey = { param($v) if ($v -is [datetime]) { $v.ToUniversalTime().ToString('yyyyMMdd-HHmmss') } else { [string]$v } }
    $toTime = { param($k) [datetime]::ParseExact((& $toKey $k), 'yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal').ToString('o') }

    # ---- load the page ----
    $problem = $null; $seconds = $null; $code = $null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $timeout -MaximumRedirection 5 `
                 -Headers @{ 'User-Agent' = 'status-to-slack (uptime check)' }
        $seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
        $code = [int]$r.StatusCode
        if ($code -lt 200 -or $code -ge 300) { $problem = "returned HTTP $code" }
        elseif ($expect -and -not ([string]$r.Content).Contains($expect)) { $problem = "loaded, but without its usual page (no ""$expect"" on it)" }
        elseif ($seconds -gt $slow) { $problem = "very slow: took $seconds s to load" }
    } catch {
        $seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
        $resp = $_.Exception.Response
        $problem = if ($resp -and $resp.StatusCode) { "returned HTTP $([int]$resp.StatusCode) $($resp.StatusCode)" }
                   elseif ($seconds -ge $timeout - 1) { "didn't answer within $timeout s" }
                   else { $msg = $_.Exception.Message -replace '\s+', ' '
                          "couldn't be reached ($(if ($msg.Length -gt 100) { $msg.Substring(0, 100) + '...' } else { $msg }))" }
    }

    # ---- certificate expiry (only while the page itself answers) ----
    $certEnd = $null
    if ($uri.Scheme -eq 'https' -and -not $problem) {
        try {
            $tcp = New-Object Net.Sockets.TcpClient
            $tcp.ReceiveTimeout = 10000; $tcp.SendTimeout = 10000
            $tcp.Connect($uri.Host, $(if ($uri.Port -gt 0) { $uri.Port } else { 443 }))
            $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, { $true })
            $ssl.AuthenticateAsClient($uri.Host)
            $certEnd = ([datetime](New-Object Security.Cryptography.X509Certificates.X509Certificate2 $ssl.RemoteCertificate).NotAfter).ToUniversalTime()
            $ssl.Dispose(); $tcp.Dispose()
        } catch { Write-Host "Couldn't read $($uri.Host)'s certificate: $($_.Exception.Message)" }
    }

    # ---- turn the result into incidents ----
    $state = @{ fails = 0; down = $null; cert = $null; past = @() }
    if ($Saved) {
        $state.fails = [int]$Saved.fails
        if ($Saved.down) { $state.down = $Saved.down }
        if ($Saved.cert) { $state.cert = $Saved.cert }
        $state.past = @($Saved.past | Where-Object { $_ } | ForEach-Object { $_.since = & $toKey $_.since; $_.end = & $toKey $_.end; $_ })
        if ($state.down) { $state.down.since = & $toKey $state.down.since }
        if ($state.cert) { $state.cert.since = & $toKey $state.cert.since }
    }
    $updates = @()
    function New-Update($id, $title, $status, $color, $impact, $body, $time, $anchor) {
        [pscustomobject]@{
            id = $id; time = $time; kind = 'Incident'; title = $title; url = "$url#$anchor"
            status = $status; color = $color; impact = $impact; impactText = $impact
            affects = @($name); body = $body
        }
    }
    $stamp = { param($k) (& $toKey $k).Substring(0, 13) }
    # closed problems, re-listed every run (already posted, so not posted again) for the history
    foreach ($p in $state.past) {
        $a = "$($p.kind)-$(& $stamp $p.since)"
        $updates += New-Update "$($p.kind)|$($p.since)|open" $p.title $p.openStatus $p.openColor $p.impact $p.openBody (& $toTime $p.since) $a
        $updates += New-Update "$($p.kind)|$($p.since)|closed" $p.title $p.closeStatus 'green' $p.impact $p.closeBody (& $toTime $p.end) $a
    }
    function Close-Problem($kind, $p, $openStatus, $openColor, $impact, $openBody, $closeStatus, $closeBody) {
        $script:websitePast = @([pscustomobject]@{
            kind = $kind; since = $p.since; end = $nowKey; title = $p.title; impact = $impact
            openStatus = $openStatus; openColor = $openColor; openBody = $openBody
            closeStatus = $closeStatus; closeBody = $closeBody
        }) + @($script:websitePast) | Select-Object -First 5
    }
    $script:websitePast = $state.past

    # down / back up
    if ($problem) { $state.fails++ } else { $state.fails = 0 }
    if ($problem -and -not $state.down -and $state.fails -ge $failAfter) {
        $state.down = @{ since = $nowKey; title = "$name is down"; reason = $problem }
    }
    if ($state.down) {
        $d = $state.down
        $a = "down-$(& $stamp $d.since)"
        $openBody = "$name $($d.reason). $(if ($failAfter -gt 1) { "Failed $failAfter checks in a row" } else { 'Failed the check' }) from GitHub's servers."
        $updates += New-Update "down|$($d.since)|open" $d.title 'Down' 'red' 'major' $openBody (& $toTime $d.since) $a
        if (-not $problem) {
            # DateTimeOffset, so the saved UTC time isn't read back as local time
            $mins = [Math]::Round(([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse((& $toTime $d.since))).TotalMinutes)
            $closeBody = "$name is answering again ($seconds s). Down for about $mins min."
            $updates += New-Update "down|$($d.since)|closed" $d.title 'Back up' 'green' 'major' $closeBody $nowText $a
            Close-Problem 'down' $d 'Down' 'red' 'major' $openBody 'Back up' $closeBody
            $state.down = $null
        }
    }

    # certificate about to expire
    if ($certEnd) {
        $daysLeft = [Math]::Floor(($certEnd - $now).TotalDays)
        $endText = $certEnd.ToString('MMM d, yyyy')
        if ($daysLeft -le $certDays -and -not $state.cert) {
            $state.cert = @{ since = $nowKey; title = "$name's security certificate expires $endText"; endText = $endText }
        }
        if ($state.cert) {
            $c = $state.cert
            $a = "cert-$(& $stamp $c.since)"
            $openBody = "The certificate for $($uri.Host) expires on $($c.endText) ($daysLeft days left when first seen). After that, browsers will refuse to open it."
            $updates += New-Update "cert|$($c.since)|open" $c.title 'Expiring' 'yellow' 'minor' $openBody (& $toTime $c.since) $a
            if ($daysLeft -gt $certDays) {
                $closeBody = "The certificate was renewed; it now runs until $endText."
                $updates += New-Update "cert|$($c.since)|closed" $c.title 'Renewed' 'green' 'minor' $closeBody $nowText $a
                Close-Problem 'cert' $c 'Expiring' 'yellow' 'minor' $openBody 'Renewed' $closeBody
                $state.cert = $null
            }
        }
    }

    $state.past = @($script:websitePast)
    $summary = if ($problem) { "$name $problem" } else { "$name up ($seconds s)" }
    Write-Host "Website check: $summary$(if ($certEnd) { "; certificate until $($certEnd.ToString('yyyy-MM-dd'))" })"
    @{ updates = $updates; state = $state; summary = $summary; up = -not $problem }
}
