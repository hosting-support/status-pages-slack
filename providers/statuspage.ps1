# Atlassian Statuspage sites (cloudflarestatus.com, smtp2gostatus.com, githubstatus.com ...), and
# other status pages that offer the same API (calendlystatus.com).
# Recognizable by https://<site>/api/v2/summary.json answering with JSON.
#
# Some of those (Calendly) leave out an incident's link and components, and give imported old
# updates the import date as created_at, so the time shown on the page (display_at) is used
# when there is one, and the link falls back to <site>/incidents/<id>.

function Get-StatusFeed($Config, [switch]$IncludeMaintenance, $Saved) {
    $base = $Config.url.TrimEnd('/')
    $summary = Get-Json "$base/api/v2/summary.json"
    $items = @((Get-Json "$base/api/v2/incidents.json").incidents | ForEach-Object { $_ | Add-Member -NotePropertyName kind -NotePropertyValue 'Incident' -PassThru })
    if ($IncludeMaintenance) {
        $items += @((Get-Json "$base/api/v2/scheduled-maintenances.json").scheduled_maintenances |
            ForEach-Object { $_ | Add-Member -NotePropertyName kind -NotePropertyValue 'Maintenance' -PassThru })
    }

    $groupNames = @{}
    $summary.components | Where-Object group | ForEach-Object { $groupNames[$_.id] = $_.name }

    # incidentio: true for pages hosted on incident.io (status.openai.com). Their Statuspage-style
    # API leaves out which components an incident affects, so the categories filter has nothing
    # to match. incident.io's own page data (<site>/proxy/<host>) lists them for ongoing incidents
    # only, so the names are remembered (in the saved state) for when the incident is resolved.
    $tags = @{}
    $apiStatus = $null
    if ($Config.incidentio) {
        if ($Saved) { $Saved.PSObject.Properties | ForEach-Object { $tags[$_.Name] = @($_.Value) } }
        try {
            $proxy = (Get-Json "$base/proxy/$(([uri]$base).Host)").summary
            $compName = @{}
            foreach ($c in $proxy.components) { $compName[[string]$c.id] = [string]$c.name }
            foreach ($oi in $proxy.ongoing_incidents) {
                $names = @(@($oi.component_impacts) + @($oi.affected_components) | ForEach-Object { $compName[[string]$_.component_id] } |
                           Where-Object { $_ } | Select-Object -Unique)
                if ($names) { $tags[[string]$oi.id] = @(@($tags[[string]$oi.id]) + $names | Where-Object { $_ } | Select-Object -Unique) }
            }
            # the page's headline covers everything (ChatGPT, Codex ...); this one covers only the
            # components the categories filter keeps
            $watchedNow = @($proxy.affected_components | Where-Object { $n = $compName[[string]$_.component_id]
                            $n -and (-not $Categories.Count -or ($Categories | Where-Object { $n -like $_ })) })
            $apiStatus = if (-not $watchedNow) { @{ indicator = 'none'; description = "$(@($Categories) -join ', ') operational" } }
                         else { @{ indicator = $(if ($watchedNow | Where-Object { $_.status -match 'full_outage|major' }) { 'major' } else { 'minor' })
                                   description = "Affected: $(@($watchedNow | ForEach-Object { $compName[[string]$_.component_id] }) -join ', ')" } }
        } catch { Write-Host "Couldn't read the incident.io page data ($($_.Exception.Message)); using the saved component names" }
        # forget incidents that are no longer listed
        $listed = @{}; foreach ($i in $items) { $listed[[string]$i.id] = $true }
        foreach ($k in @($tags.Keys)) { if (-not $listed[$k]) { $tags.Remove($k) } }
        foreach ($i in $items) {
            if (-not @($i.components | Where-Object { $_ }).Count -and $tags[[string]$i.id]) {
                $i | Add-Member -NotePropertyName components -NotePropertyValue @($tags[[string]$i.id] | ForEach-Object { [pscustomobject]@{ name = $_; group_id = $null } }) -Force
            }
        }
    }

    # Color follows the update's status, so a thread reads red -> orange -> yellow -> green
    $statusColor = @{
        investigating = 'red'; identified = 'orange'; monitoring = 'yellow'; resolved = 'green'; postmortem = 'green'
        scheduled = 'blue'; in_progress = 'blue'; verifying = 'blue'; completed = 'green'
    }
    $componentColor = @{
        operational = 'green'; degraded_performance = 'yellow'; partial_outage = 'orange'; major_outage = 'red'; under_maintenance = 'blue'
    }

    $updates = foreach ($i in $items) {
        # an incident is matched by its components, the groups they belong to (e.g. regions),
        # and "Group / Component" for one component in one group (e.g. a product in one region)
        $affects = @($i.components | ForEach-Object {
            $_.name
            if ($_.group_id -and $groupNames[$_.group_id]) { $groupNames[$_.group_id]; "$($groupNames[$_.group_id]) / $($_.name)" }
        } | Where-Object { $_ } | Select-Object -Unique)
        # showGroups: print "Group / Component" where the component name alone is ambiguous
        $shown = if ($Config.showGroups) {
            @($i.components | ForEach-Object { if ($_.group_id -and $groupNames[$_.group_id]) { "$($groupNames[$_.group_id]) / $($_.name)" } else { $_.name } })
        } else { @($i.components.name | Select-Object -Unique) }   # a name can repeat across groups (1Password regions)
        foreach ($u in $i.incident_updates) {
            [pscustomobject]@{
                id         = $u.id
                time       = $(if ($u.display_at) { $u.display_at } else { $u.created_at })
                kind       = $i.kind
                title      = $i.name
                url        = $(if ($i.shortlink) { $i.shortlink } else { "$base/incidents/$($i.id)" })
                status     = (Get-Culture).TextInfo.ToTitleCase(($u.status -replace '_', ' '))
                color      = $statusColor[[string]$u.status]
                impact     = [string]$i.impact
                impactText = [string]$i.impact
                # posts list the components only, not the region groups (too long otherwise)
                affects    = $affects
                showAffects = $shown
                body       = $u.body
            }
        }
    }

    $components = @{}
    $summary.components | Where-Object { -not $_.group } | ForEach-Object {
        $components[$_.id] = @{ name = $_.name; status = $_.status; color = $componentColor[[string]$_.status] }
    }

    @{
        overall    = $(if ($apiStatus) { $apiStatus } else { @{ indicator = $summary.status.indicator; description = $summary.status.description } })
        updates    = $updates
        components = $components
        extra      = $(if ($Config.incidentio) { $tags } else { $null })
    }
}
