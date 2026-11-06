# status.io pages (e.g. https://dynatrace.status.io), via https://api.status.io/1.0/status/<page id>.
# The settings file names the page: "pageId": "546d8cb6af8407b6730000cb" (shown in the page's
# source as statuspage_id).
#
# The API lists incidents only while they're active, and a resolved incident simply drops
# out. So open incidents are remembered between runs, and one that disappears gets a
# "Resolved" update of its own.
#
# Incidents name the "containers" they affect (on Dynatrace: Process/Retain/Analyze/Automate
# per cloud and region, e.g. Analyze-AWS-americas, plus global services such as "Dynatrace
# Support Portal"). The categories filter matches container names.

function Get-StatusFeed($Config, [switch]$IncludeMaintenance, $Saved) {
    $pageId = $Config.pageId
    if (-not $pageId) { throw "services/<id>.json needs ""pageId"" for a status.io page" }
    $base = $Config.url.TrimEnd('/')
    $r = (Get-Json "https://api.status.io/1.0/status/$pageId").result

    # status.io codes: 100 operational, 200 planned maintenance, 300 degraded performance,
    # 400 partial service disruption, 500 service disruption, 600 security event
    $impact = @{ 300 = 'minor'; 400 = 'major'; 500 = 'critical'; 600 = 'critical' }
    $statusText = @{ 100 = 'Operational'; 200 = 'Planned maintenance'; 300 = 'Degraded performance'
                     400 = 'Partial service disruption'; 500 = 'Service disruption'; 600 = 'Security event' }
    # message state: 100 investigating, 200 identified, 300 monitoring
    $stateText = @{ 100 = 'Investigating'; 200 = 'Identified'; 300 = 'Monitoring' }
    $stateColor = @{ 100 = 'red'; 200 = 'orange'; 300 = 'yellow' }

    # what an incident affects: its containers, or its components if it lists no containers
    function Get-Affects($item) {
        $names = @($item.containers_affected.name | Where-Object { $_ })
        if (-not $names.Count) { $names = @($item.components_affected.name | Where-Object { $_ }) }
        $names
    }
    function Get-Worst($codes) { [int](@($codes) + 0 | Measure-Object -Maximum).Maximum }

    $known = @{}   # incidents open at the previous run: id -> what's needed to post its resolution
    if ($Saved) { $Saved.PSObject.Properties | ForEach-Object { $known[$_.Name] = $_.Value } }
    $open = @{}

    $updates = foreach ($i in $r.incidents) {
        $msgs = @($i.messages | Sort-Object { [datetime]$_.datetime })
        $worst = Get-Worst ($msgs | ForEach-Object { [int]$_.status })
        $common = @{
            kind       = 'Incident'
            title      = $i.name
            url        = "$base/pages/incident/$pageId/$($i._id)"
            impact     = $(if ($impact[$worst]) { $impact[$worst] } else { 'none' })
            impactText = $statusText[$worst]
            affects    = @(Get-Affects $i)
        }
        $open[$i._id] = $common
        foreach ($m in $msgs) {
            [pscustomobject]($common + @{
                id     = "$($i._id)|$($m._id)|$($m.datetime)"
                time   = $m.datetime
                status = $(if ($stateText[[int]$m.state]) { $stateText[[int]$m.state] } else { 'Update' })
                color  = $(if ($stateColor[[int]$m.state]) { $stateColor[[int]$m.state] } else { 'orange' })
                body   = $m.details
            })
        }
    }

    # incidents that were open last time and are gone now: resolved
    foreach ($id in @($known.Keys)) {
        if ($open.ContainsKey($id)) { continue }
        $k = $known[$id]
        $updates = @($updates) + [pscustomobject]@{
            id = "$id|resolved"; time = (Get-Date).ToUniversalTime().ToString('o')
            kind = 'Incident'; title = $k.title; url = $k.url; status = 'Resolved'; color = 'green'
            impact = $k.impact; impactText = $k.impactText; affects = @($k.affects)
            body = 'No longer listed as active on the status page.'
        }
    }

    if ($IncludeMaintenance) {
        $maint = @(@($r.maintenance.active | ForEach-Object { $_ | Add-Member -NotePropertyName phase -NotePropertyValue 'In progress' -PassThru }) +
                   @($r.maintenance.upcoming | ForEach-Object { $_ | Add-Member -NotePropertyName phase -NotePropertyValue 'Scheduled' -PassThru }))
        foreach ($mt in $maint | Where-Object { $_ }) {
            $start = ([datetime]$mt.datetime_planned_start).ToUniversalTime().ToString('MMM d HH:mm')
            foreach ($m in @($mt.messages | Sort-Object { [datetime]$_.datetime })) {
                $updates = @($updates) + [pscustomobject]@{
                    id = "$($mt._id)|$($m.datetime)"; time = $m.datetime
                    kind = 'Maintenance'; title = "$($mt.name) ($start UTC)"
                    url = "$base/pages/maintenance/$pageId/$($mt._id)"
                    status = $mt.phase; color = 'blue'; impact = 'none'; impactText = ''
                    affects = @(Get-Affects $mt); body = $m.details
                }
            }
        }
    }

    # Overall: the worst container status among the ones the categories filter keeps (set by
    # the main script), so an issue in a region you filtered out doesn't change it.
    $containers = @($r.status | ForEach-Object { $_.containers })
    $watched = @($containers | Where-Object { $c = $_; -not $Categories.Count -or ($Categories | Where-Object { $c.name -like $_ }) })
    $worst = Get-Worst ($watched | ForEach-Object { [int]$_.status_code })
    $bad = @($watched | Where-Object { [int]$_.status_code -gt 100 })
    $overall = @{
        indicator   = $(if ($worst -eq 200) { 'maintenance' } elseif ($impact[$worst]) { $impact[$worst] } else { 'none' })
        description = $(if (-not $bad.Count) { "All $($watched.Count) watched components operational" }
                        else { "$($statusText[$worst]): $(($bad.name | Select-Object -First 3) -join ', ')$(if ($bad.Count -gt 3) { " +$($bad.Count - 3) more" })" })
    }

    @{ overall = $overall; updates = @($updates); extra = $open }
}
