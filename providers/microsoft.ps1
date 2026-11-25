# Microsoft cloud status (https://status.cloud.microsoft), the public page Microsoft uses when an
# issue is big enough that admins may not reach the Service health page in their admin center.
# It has one current post per area, from https://status.cloud.microsoft/api/posts/<area>:
#   mac   = Microsoft 365 (Exchange, Teams, SharePoint, Entra sign-in ...)
#   azure = Azure
#   ppac  = Power Platform / Dynamics 365
#   copilot = Microsoft Copilot, the free consumer version (copilot.microsoft.com), from the
#           consumer list at /api/posts/m365Consumer. Not the same product as Microsoft 365
#           Copilot (work accounts), whose day-to-day incidents are only in each company's
#           admin center (Service health), but it shares much of the same infrastructure, so a
#           big Copilot problem often shows here too.
# A post has Title, Message (HTML), Status ("Available", "Service degradation", "Service
# restored", ...) and is rewritten as the issue goes on. Each new text is one update. When a
# post goes back to "Available" without a "Service restored" first, the issue gets a "Resolved"
# update of its own, as with status.io. The categories filter matches the area names above
# ("Microsoft 365", "Azure", "Power Platform", "Copilot (consumer)").

function Get-StatusFeed($Config, [switch]$IncludeMaintenance, $Saved) {
    $base = 'https://status.cloud.microsoft'
    $areas = [ordered]@{ mac = 'Microsoft 365'; azure = 'Azure'; ppac = 'Power Platform'; copilot = 'Copilot (consumer)' }

    $known = @{}   # issues open at the previous run: area -> title, impact ...
    if ($Saved) { $Saved.PSObject.Properties | ForEach-Object { $known[$_.Name] = $_.Value } }
    $open = @{}
    $sha = [Security.Cryptography.SHA1]::Create()
    function Get-Hash($s) { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$s))) -replace '-', '').Substring(0, 12) }
    $wanted = { param($name) -not $Categories.Count -or ($Categories | Where-Object { $name -like $_ }) }

    $updates = @()
    $states = [ordered]@{}   # area name -> status text, for the overall line
    foreach ($area in $areas.Keys) {
        $name = $areas[$area]
        try {
            $p = if ($area -eq 'copilot') {
                # one entry per consumer service; no @(): Windows PowerShell would nest the list
                $list = Get-Json "$base/api/posts/m365Consumer"
                $list | Where-Object { $_.ServiceWorkloadName -eq 'CopilotConsumer' } | Select-Object -First 1
            } else { Get-Json "$base/api/posts/$area" }
            if (-not $p) { throw "no entry for $name" }
        }
        catch { Write-Host "Couldn't read $name ($($_.Exception.Message))"; if ($known[$area]) { $open[$area] = $known[$area] }; continue }
        $status = [string]$p.Status
        $states[$name] = $status
        $quiet = $status -in @('', 'Available', 'Operational', 'Unknown')
        $restored = $status -eq 'Service restored'

        # consumer entries may have no Id while an issue is posted; the area stands in for it
        $postId = if ($p.Id) { [string]$p.Id } else { $area }
        if (-not $quiet) {
            # keep the first title until the area is quiet again, so the issue's updates stay
            # together (Microsoft gives every rewrite of the post a new Id)
            $prev = $known[$area]
            $title = if ($prev -and $prev.title) { $prev.title }
                     elseif ($p.Title) { $p.Title } else { "$name issue" }
            $common = @{
                kind       = 'Incident'
                title      = $title
                url        = "$base/"
                impact     = $(if ($status -eq 'Service degradation') { 'major' } else { 'minor' })
                impactText = $status
                affects    = @($name)
            }
            $updates += [pscustomobject]($common + @{
                id     = "$area|$postId|$(Get-Hash "$status|$($p.Title)|$($p.Message)")"
                time   = $(if ($p.LastUpdatedTime) { $p.LastUpdatedTime } else { (Get-Date).ToUniversalTime().ToString('o') })
                status = $(if ($restored) { 'Resolved' } else { $status })
                color  = $(if ($restored) { 'green' } elseif ($common.impact -eq 'major') { 'orange' } else { 'yellow' })
                body   = $(if ($p.Title -and $p.Title -ne $title) { "$($p.Title)`n" }) + (ConvertFrom-Html $p.Message)
            })
            if (-not $restored) { $open[$area] = $common + @{ postId = $postId } }
        }
    }

    # issues that were open last time and are quiet now: resolved
    foreach ($area in @($known.Keys)) {
        if ($open.ContainsKey($area) -or ($states[$areas[$area]] -eq 'Service restored')) { continue }
        $k = $known[$area]
        $updates += [pscustomobject]@{
            id = "$area|$($k.postId)|resolved"; time = (Get-Date).ToUniversalTime().ToString('o')
            kind = 'Incident'; title = $k.title; url = $k.url; status = 'Resolved'; color = 'green'
            impact = $k.impact; impactText = $k.impactText; affects = @($k.affects)
            body = 'Microsoft no longer lists this issue on the status page.'
        }
    }

    # overall: the areas the categories filter keeps
    $watched = @($states.Keys | Where-Object { & $wanted $_ })
    $bad = @($watched | Where-Object { $states[$_] -notin @('', 'Available', 'Operational', 'Unknown', 'Service restored') })
    $overall = @{
        indicator   = $(if ($bad | Where-Object { $states[$_] -eq 'Service degradation' }) { 'major' } elseif ($bad) { 'minor' } else { 'none' })
        description = $(if ($bad) { ($bad | ForEach-Object { "${_}: $($states[$_])" }) -join '; ' }
                        elseif ($watched.Count -gt 1) { "$(($watched | Select-Object -SkipLast 1) -join ', ') and $($watched[-1]) available" }
                        else { "$watched available" })
    }

    @{ overall = $overall; updates = @($updates); extra = $open }
}
