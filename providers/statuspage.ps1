# Atlassian Statuspage sites (cloudflarestatus.com, smtp2gostatus.com, githubstatus.com ...).
# Recognizable by https://<site>/api/v2/summary.json answering with JSON.

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
        } else { @($i.components.name) }
        foreach ($u in $i.incident_updates) {
            [pscustomobject]@{
                id         = $u.id
                time       = $u.created_at
                kind       = $i.kind
                title      = $i.name
                url        = $i.shortlink
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
        overall    = @{ indicator = $summary.status.indicator; description = $summary.status.description }
        updates    = $updates
        components = $components
    }
}
