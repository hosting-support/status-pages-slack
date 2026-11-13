# Salesforce Trust status (https://status.salesforce.com), via https://api.status.salesforce.com/v1.
# Salesforce reports per instance (the server cluster an org lives on), so the settings file
# names the org's My Domain ("domain": "cmicglobal") and the instance is looked up each run
# (https://api.status.salesforce.com/v1/instanceAliases/<my-domain-name>).
# Incidents have events (updates) but no "resolved" event, so a resolved incident gets one
# extra update of its own.

function Get-StatusFeed($Config, [switch]$IncludeMaintenance, $Saved) {
    $api = 'https://api.status.salesforce.com/v1'
    # "domain" (the My Domain name, cmicglobal for cmicglobal.my.salesforce.com) is looked up
    # on every run, so a move to another instance is picked up by itself. "instance" is the
    # fallback if the lookup fails.
    $instance = $Config.instance
    if ($Config.domain) {
        try {
            $found = (Get-Json "$api/instanceAliases/$($Config.domain)").instanceKey
            if ($found) {
                if ($instance -and $found -ne $instance) { Write-Host "::notice::$($Config.domain) is now on $found (settings file says $instance)" }
                $instance = $found
            }
        } catch { Write-Host "Couldn't look up the instance for $($Config.domain) ($($_.Exception.Message)); using $instance" }
    }
    if (-not $instance) { throw 'services/salesforce.json needs "domain" (e.g. "cmicglobal") or "instance" (e.g. "CAN36")' }

    $inst = Get-Json "$api/instances/$instance/status?childProducts=false"
    # no @(): Windows PowerShell returns a JSON list as one object, and @() would nest it
    $incidents = Get-Json "$api/incidents?instance=$instance"
    $maintenances = if ($IncludeMaintenance) { Get-Json "$api/maintenances?instance=$instance" } else { @() }

    # Service keys are what the API uses; a few common ones get a readable name for the post.
    # The categories filter matches either form.
    $serviceNames = @{
        coreService = 'Core service'; Communities = 'Experience Cloud'; liveAgent = 'Chat'
        search = 'Search'; analytics = 'CRM Analytics'; ServiceCloudVoice = 'Service Cloud Voice'
        ServiceCloudMessagingChannels = 'Messaging'; EinsteinBots = 'Einstein Bots'
        Customer360Audiences = 'Data Cloud'; MCGrowth = 'Marketing Cloud Growth'; Agentforce = 'Agentforce'
    }
    function Get-ServiceName($key) { if ($serviceNames[$key]) { $serviceNames[$key] } else { $key } }
    function Format-Type($t) { (Get-Culture).TextInfo.ToTitleCase(($t -creplace '([a-z])([A-Z])', '$1 $2').ToLower()) }
    $eventLabel = @{
        investigatingCauseOfIssue = 'Investigating'; update = 'Update'
        impactRadiusIncrease = 'Scope widened'; startTimeRevision = 'Start time revised'
    }
    function Format-Utc($t) { if ($t) { ([datetime]$t).ToUniversalTime().ToString('MMM d HH:mm') } }

    $updates = foreach ($i in $incidents) {
        $sev = @($i.IncidentImpacts.severity)
        $impact = if ($i.type -eq 'Disruption' -or $sev -contains 'major') { 'major' } else { 'minor' }
        $title = "$($i.type): $((@($i.serviceKeys) | ForEach-Object { Get-ServiceName $_ }) -join ', ') on $instance"
        $common = @{
            kind        = 'Incident'
            title       = $title
            url         = "https://status.salesforce.com/incidents/$($i.id)"
            impact      = $impact
            impactText  = "$($i.type) ($impact)"
            # filter on service key (coreService), its readable name (Core service) or instance
            affects     = @($i.serviceKeys) + @($i.serviceKeys | ForEach-Object { Get-ServiceName $_ }) + @($i.instanceKeys)
            showAffects = @($i.serviceKeys | ForEach-Object { Get-ServiceName $_ })
        }
        foreach ($e in $i.IncidentEvents) {
            [pscustomobject]($common + @{
                id     = "incident-event-$($e.id)"
                time   = $e.createdAt
                status = $(if ($eventLabel[$e.type]) { $eventLabel[$e.type] } else { Format-Type $e.type })
                color  = $(if ($impact -eq 'major') { 'red' } else { 'orange' })
                body   = $e.message
            })
        }
        if ($i.status -eq 'Resolved') {
            $start = ($i.IncidentImpacts.startTime | Sort-Object | Select-Object -First 1)
            $end = ($i.IncidentImpacts.endTime | Where-Object { $_ } | Sort-Object | Select-Object -Last 1)
            [pscustomobject]($common + @{
                id     = "incident-$($i.id)-resolved"
                time   = $i.updatedAt
                status = 'Resolved'
                color  = 'green'
                body   = $(if ($start -and $end) { "Impact window: $(Format-Utc $start) - $(Format-Utc $end) UTC" })
            })
        }
    }

    $updates = @($updates) + @(foreach ($m in $maintenances) {
        foreach ($e in $m.MaintenanceEvents) {
            [pscustomobject]@{
                id          = "maintenance-event-$($e.id)"
                time        = $e.createdAt
                kind        = 'Maintenance'
                title       = "$($m.name) ($(Format-Utc $m.plannedStartTime) UTC)"
                url         = "https://status.salesforce.com/maintenances/$($m.id)"
                status      = Format-Type $e.type
                color       = 'blue'
                impact      = 'none'
                impactText  = ''
                affects     = @($m.serviceKeys) + @($m.serviceKeys | ForEach-Object { Get-ServiceName $_ }) + @($m.instanceKeys)
                showAffects = @($m.serviceKeys | ForEach-Object { Get-ServiceName $_ })
                body        = $e.message
            }
        }
    })

    # Instance status: OK, or MAJOR_/MINOR_INCIDENT_, MAINTENANCE_, INFORMATIONAL_ + CORE/NONCORE.
    # Non-core issues (add-on products) don't change the overall indicator; their incidents
    # still come through the categories filter.
    $s = [string]$inst.status
    $overall = switch -Wildcard ($s) {
        'OK'                   { @{ indicator = 'none';        description = "$instance operational" }; break }
        '*_NONCORE'            { @{ indicator = 'none';        description = "$instance operational (add-on product issue)" }; break }
        'MAJOR_INCIDENT_*'     { @{ indicator = 'major';       description = "$instance major incident" }; break }
        'MINOR_INCIDENT_*'     { @{ indicator = 'minor';       description = "$instance minor incident" }; break }
        'MAINTENANCE_*'        { @{ indicator = 'maintenance'; description = "$instance under maintenance" }; break }
        default                { @{ indicator = 'none';        description = "$instance $(Format-Type $s.ToLower())" }; break }
    }

    # vars: fills {instance} in the settings file's url and label
    # rebaseline: after a move to another instance, that instance's earlier incidents are
    # marked as seen instead of all being posted as new
    $moved = [string]$Saved.instance -ne $instance
    if ($moved) { Write-Host "Instance is $instance (was '$($Saved.instance)'): taking a fresh baseline, nothing posted this run" }
    @{ overall = $overall; updates = $updates; vars = @{ instance = $instance }; extra = @{ instance = $instance }; rebaseline = $moved }
}
