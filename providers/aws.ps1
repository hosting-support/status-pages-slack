# AWS Health Dashboard, public events (https://health.aws.amazon.com/health/status).
# The page reads https://health.aws.amazon.com/public/currentevents: a JSON list of recent
# events, served as UTF-16. AWS has no overall status and no update ids, so an update is
# identified by its event + timestamp.

function Get-StatusFeed($Config, [switch]$IncludeMaintenance, $Saved) {
    $resp = Invoke-WebRequest -Uri 'https://health.aws.amazon.com/public/currentevents' -TimeoutSec 30 -UseBasicParsing
    $bytes = $resp.RawContentStream.ToArray()
    $enc = if ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { [Text.Encoding]::BigEndianUnicode }
           elseif ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { [Text.Encoding]::Unicode }
           else { [Text.Encoding]::UTF8 }
    $events = $enc.GetString($bytes).TrimStart([char]0xFEFF) | ConvertFrom-Json

    # AWS severity: 0 resolved, 1 informational, 2 degraded, 3 disruption
    $impact = @{ 1 = 'minor'; 2 = 'major'; 3 = 'critical' }
    $impactText = @{ 1 = 'Informational'; 2 = 'Degraded performance'; 3 = 'Service disruption' }
    $label = @{ 1 = 'Informational'; 2 = 'Degraded'; 3 = 'Disruption' }
    $color = @{ 1 = 'yellow'; 2 = 'orange'; 3 = 'red' }

    $updates = foreach ($e in $events) {
        $worst = [int]($e.event_log.status | Measure-Object -Maximum).Maximum
        $region = ($e.arn -split ':')[3]                      # e.g. us-east-1
        $summary = $e.summary -replace '^\[\w+\]\s*', ''     # drop "[RESOLVED]", the status says it
        $title = "$($e.service_name) ($($e.region_name)): $summary"
        $log = @($e.event_log | Sort-Object { [long]$_.timestamp })
        for ($n = 0; $n -lt $log.Count; $n++) {
            $u = $log[$n]
            $s = [int]$u.status
            $resolved = $n -eq $log.Count - 1 -and [int]$e.status -eq 0
            [pscustomobject]@{
                id          = "$($e.arn)|$($u.timestamp)"
                time        = [DateTimeOffset]::FromUnixTimeSeconds([long]$u.timestamp).UtcDateTime.ToString('o')
                kind        = 'Event'
                title       = $title
                url         = 'https://health.aws.amazon.com/health/status'
                status      = $(if ($resolved) { 'Resolved' } else { $label[$s] })
                color       = $(if ($resolved) { 'green' } else { $color[$s] })
                impact      = $impact[$worst]
                impactText  = $impactText[$worst]
                # filter on service name, region name, service code (ec2-us-east-1) or region code
                affects     = @($e.service_name, $e.region_name, $e.service, $region)
                showAffects = @("$($e.service_name), $($e.region_name) ($region)")
                body        = $(if ($u.summary -and $u.summary -ne $summary) { "*$($u.summary)*`n" }) + $u.message
            }
        }
    }

    @{ overall = $null; updates = $updates }
}
