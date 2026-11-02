# Oracle Cloud Infrastructure status (https://ocistatus.oraclecloud.com).
# The page reads /api/v2/status.json (overall status), /api/v2/incident-summary/<yyyyMM>.json
# (one file per month that had incidents, 404 otherwise) and /api/v2/incidents/<id>.json
# (an incident with all its posts). To keep requests down, an incident is only re-read when
# its last post time changes; the post ids of the others are kept from the previous run.

function Get-StatusFeed($Config, [switch]$IncludeMaintenance, $Saved) {
    $base = 'https://ocistatus.oraclecloud.com/api/v2'
    $status = Get-Json "$base/status.json"

    $summaries = foreach ($month in (Get-Date).ToUniversalTime(), (Get-Date).ToUniversalTime().AddMonths(-1)) {
        try { (Get-Json "$base/incident-summary/$($month.ToString('yyyyMM')).json").incidentSummaries }
        catch { if ($_.Exception.Response.StatusCode -ne 404 -and $_.Exception.Response.StatusCode -ne 'NotFound') { throw } }
    }
    $summaries = @($summaries | Where-Object { $_ } | Sort-Object { [datetime]$_.lastIncidentPostTime } -Descending)

    # impactStatus: NormalPerformance, ServiceDisruption (and possibly a degraded state)
    function Get-Impact($s) {
        switch -Wildcard ($s) { 'Normal*' { 'none' } '*Disruption*' { 'major' } '*Outage*' { 'critical' } default { 'minor' } }
    }
    $impactRank = @{ none = 0; minor = 1; major = 2; critical = 3 }
    $statusColor = @{ investigating = 'red'; identified = 'orange'; monitoring = 'yellow'; resolved = 'green' }

    $known = @{}   # incidentId -> @{ last; ids }
    if ($Saved) { $Saved.PSObject.Properties | ForEach-Object { $known[$_.Name] = $_.Value } }
    $extra = @{}
    $keepIds = @()

    $first = $true
    $updates = foreach ($s in $summaries) {
        $last = ([datetime]$s.lastIncidentPostTime).ToUniversalTime().ToString('o')
        $k = $known[$s.incidentId]
        # the newest incident is always read, so -TestPost has something to show
        if (-not $first -and $k -and $k.last -eq $last) {
            $extra[$s.incidentId] = $k
            $keepIds += @($k.ids)
            continue
        }
        $first = $false
        $inc = Get-Json "$base/incidents/$($s.incidentId).json"
        $posts = @($inc.incidentPosts)
        $extra[$s.incidentId] = @{ last = $last; ids = @($posts.incidentPostId) }

        # worst impact over the whole incident, so a "resolved" post keeps the incident's impact
        $worst = 'none'; $worstText = ''
        foreach ($p in $posts) { foreach ($i in $p.incidentImpacts) {
            $v = Get-Impact $i.impactStatus
            if ($impactRank[$v] -gt $impactRank[$worst]) { $worst = $v; $worstText = $i.impactStatus -creplace '([a-z])([A-Z])', '$1 $2' }
        } }
        $impacts = @($posts.incidentImpacts)
        $services = @($impacts.serviceName | Select-Object -Unique)
        $regions = @($impacts.regionName | Select-Object -Unique)

        foreach ($p in $posts) {
            $body = $p.message
            if ($p.customerImpact) { $body += "`n`n*Customer impact:* $($p.customerImpact)" }
            if ($p.rootCause)      { $body += "`n`n*Root cause:* $($p.rootCause)" }
            [pscustomobject]@{
                id          = $p.incidentPostId
                time        = $p.postedTime
                kind        = 'Incident'
                title       = $inc.title
                url         = "https://ocistatus.oraclecloud.com/#/incidents/$($inc.incidentId)"
                status      = $p.status
                color       = $statusColor[([string]$p.status).ToLower()]
                impact      = $worst
                impactText  = $worstText
                # filter on service, region or service category
                affects     = @($services) + @($regions) + @($impacts.serviceCategory | Select-Object -Unique)
                showAffects = @($services) + @($regions)
                body        = $body
            }
        }
    }

    @{
        overall = @{ indicator = $status.status.indicator; description = $status.status.description }
        updates = $updates
        extra   = $extra
        keepIds = $keepIds
    }
}
