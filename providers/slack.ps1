# Slack's own status page (https://slack-status.com), API documented at
# https://slack-status.com/api. Incidents carry a type (incident / outage / notice /
# maintenance) instead of an impact, and notes have no ids, so a note is identified by its
# incident + time.

function Get-StatusFeed($Config, [switch]$IncludeMaintenance, $Saved) {
    $current = Get-Json 'https://slack-status.com/api/v2.0.0/current'
    $history = Get-Json 'https://slack-status.com/api/v2.0.0/history'

    # active incidents first, so they win over their copy in the history
    $incidents = @{}
    foreach ($i in @($current.active_incidents) + @($history)) {
        if ($i -and -not $incidents.ContainsKey([string]$i.id)) { $incidents[[string]$i.id] = $i }
    }

    $impact = @{ outage = 'major'; incident = 'minor'; notice = 'none' }
    $impactText = @{ outage = 'Outage'; incident = 'Incident'; notice = 'Notice'; maintenance = 'Maintenance' }
    $activeColor = @{ outage = 'red'; incident = 'orange'; notice = 'yellow'; maintenance = 'blue' }

    $updates = foreach ($i in $incidents.Values) {
        $isMaintenance = $i.type -eq 'maintenance'
        if ($isMaintenance -and -not $IncludeMaintenance) { continue }
        $notes = @($i.notes | Sort-Object { [datetime]$_.date_created })
        for ($n = 0; $n -lt $notes.Count; $n++) {
            # a note doesn't say whether it resolved the incident; only the newest one can have
            $resolved = $n -eq $notes.Count - 1 -and $i.status -ne 'active'
            [pscustomobject]@{
                id         = "$($i.id)|$($notes[$n].date_created)"
                time       = ([datetimeoffset]$notes[$n].date_created).UtcDateTime.ToString('o')
                kind       = $(if ($isMaintenance) { 'Maintenance' } else { 'Incident' })
                title      = $i.title
                url        = $i.url
                status     = $(if ($resolved) { (Get-Culture).TextInfo.ToTitleCase([string]$i.status) } elseif ($n -eq 0) { 'New' } else { 'Update' })
                color      = $(if ($resolved) { 'green' } else { $activeColor[[string]$i.type] })
                impact     = $impact[[string]$i.type]
                impactText = $impactText[[string]$i.type]
                affects    = @($i.services)
                body       = ConvertFrom-Html $notes[$n].body
            }
        }
    }

    # current.status: ok, active (incident) or broken (outage)
    $overall = switch ($current.status) {
        'ok'     { @{ indicator = 'none';  description = 'All systems operational' } }
        'active' { @{ indicator = 'minor'; description = 'Active incident' } }
        'broken' { @{ indicator = 'major'; description = 'Outage' } }
        default  { @{ indicator = [string]$current.status; description = [string]$current.status } }
    }

    @{ overall = $overall; updates = $updates }
}
