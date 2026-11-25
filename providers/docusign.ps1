# DocuSign's status center (https://health.docusign.com/status). The old docusign.statuspage.io
# page is abandoned (nothing since 2021), so this reads the data files the new page loads:
#   <base>/incidents.json   incidents, maintenances and releases, each with its events
#   <base>/components.json  products (eSignature, CLM ...) and their sites (NA1 ... CA, EU ...)
# An incident names the sites it affects ("NA1", "CA" ...), so the categories filter matches
# site names, e.g. ["NA1", "NA2", "NA3", "NA4", "CA"] for the production eSignature sites CMiC's
# customers use. ("DEMO" is the developer sandbox.)

function Get-StatusFeed($Config, [switch]$IncludeMaintenance, $Saved) {
    $base = 'https://health.docusign.com/production/1ds/ssg/apps/health/dynamic'
    $page = 'https://health.docusign.com/status'
    $data = Get-Json "$base/incidents.json"
    $comps = Get-Json "$base/components.json"

    $impactOf = @{ service_disruption = 'major'; performance_degradation = 'minor'; available = 'none'; maintenance = 'none' }
    $impactText = @{ service_disruption = 'Service disruption'; performance_degradation = 'Performance degradation'; available = 'Informational' }
    $statusColor = @{
        investigating = 'red'; identified = 'orange'; monitoring = 'yellow'; resolved = 'green'
        scheduled = 'blue'; in_progress = 'blue'; completed = 'green'; canceled = 'green'
    }
    function Format-Status($s) { (Get-Culture).TextInfo.ToTitleCase(([string]$s -replace '_', ' ')) }

    $updates = foreach ($i in @($data.incidents)) {
        if (-not $i) { continue }
        $planned = $i.isPlanned -or ([string]$i.type -ne 'incident')
        if ($planned -and -not $IncludeMaintenance) { continue }
        $sites = @($i.components | ForEach-Object { [string]$_.name } | Where-Object { $_ } | Select-Object -Unique)
        foreach ($e in @($i.events)) {
            if (-not $e) { continue }
            [pscustomobject]@{
                id          = "$($i.id)|$($e.id)"
                time        = $(if ($e.displayAt) { $e.displayAt } else { $e.createdAt })
                kind        = $(if ($planned) { 'Maintenance' } else { 'Incident' })
                title       = [string]$i.title
                url         = $page
                status      = Format-Status $e.status
                color       = $(if ($statusColor[[string]$e.status]) { $statusColor[[string]$e.status] } else { 'orange' })
                impact      = $(if ($planned) { 'none' } elseif ($impactOf[[string]$i.impact]) { $impactOf[[string]$i.impact] } else { 'minor' })
                impactText  = $(if ($impactText[[string]$i.impact]) { $impactText[[string]$i.impact] } else { Format-Status $i.impact })
                affects     = $sites
                body        = [string]$e.body
            }
        }
    }

    # overall: the sites the categories filter keeps (or all), worst current status first
    $rank = @{ available = 0; maintenance = 1; performance_degradation = 2; service_disruption = 3 }
    $sitesNow = @($comps.components | Where-Object { $_.type -eq 'site' } |
                  Where-Object { $n = $_.name; -not $Categories.Count -or ($Categories | Where-Object { $n -like $_ }) })
    $bad = @($sitesNow | Where-Object { [string]$_.status -ne 'available' } | Sort-Object { -[int]$rank[[string]$_.status] })
    $worst = if ($bad) { [string]$bad[0].status } else { 'available' }
    $overall = @{
        indicator   = $(switch ($worst) { 'service_disruption' { 'major' } 'performance_degradation' { 'minor' } 'maintenance' { 'maintenance' } default { 'none' } })
        description = $(if (-not $bad) { "$(@($sitesNow.name | Select-Object -Unique) -join ', ') available" }
                        else { "$(Format-Status $worst): $(@($bad.name | Select-Object -Unique) -join ', ')" })
    }

    @{ overall = $overall; updates = @($updates) }
}
