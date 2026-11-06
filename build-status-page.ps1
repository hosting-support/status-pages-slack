<#
.SYNOPSIS
  Builds the status page site: site\index.html plus a status.json combining every service's
  snapshot (status\<id>.json, written by status-to-slack.ps1).

.DESCRIPTION
  A run may not have a fresh snapshot for every service (a manual run for one service, or a
  status page that didn't answer). Those keep their entry from the previous status.json
  (-PreviousFile or -PreviousUrl), and the page shows them as "No recent data" once they're old.

.EXAMPLE
  .\build-status-page.ps1 -SnapshotDir status -OutDir _site
#>
param(
    [string] $SnapshotDir = (Join-Path $PSScriptRoot 'status'),
    [string] $OutDir      = (Join-Path $PSScriptRoot '_site'),
    [string] $PreviousUrl,                    # the published status.json, e.g. https://<user>.github.io/<repo>/status.json
    [string] $PreviousFile,                   # or the previous status.json as a local file
    # What started this run, for the page's update health line: 'workflow_dispatch' (the
    # Cloudflare scheduler, or the Run workflow button) or 'schedule' (GitHub's hourly backup)
    [string] $Trigger = 'manual',
    [string] $RunUrl                          # link to this run on GitHub
)

$ErrorActionPreference = 'Stop'
function Format-Utc($t) { ([datetime]$t).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
$now = Format-Utc (Get-Date)

$services = [ordered]@{}
$previousRun = $null
if ($PreviousFile -or $PreviousUrl) {
    try {
        $previous = if ($PreviousFile) { Get-Content $PreviousFile -Raw | ConvertFrom-Json }
                    else { Invoke-RestMethod -Uri $PreviousUrl -TimeoutSec 20 }
        foreach ($s in $previous.services) { $services[$s.id] = $s }
        $previousRun = $previous.run
        Write-Host "Previous status.json: $($services.Count) services"
    } catch { Write-Host "No previous status.json ($($_.Exception.Message)); starting fresh" }
}

# The scheduler's last run is carried over from the previous page when GitHub's backup
# schedule started this one, so the page can tell "backup ran" apart from "scheduler ran".
$lastScheduler = if ($Trigger -eq 'workflow_dispatch') { $now }
                 elseif ($previousRun.lastSchedulerAt) { Format-Utc $previousRun.lastSchedulerAt }
                 else { $null }
foreach ($f in Get-ChildItem -Path $SnapshotDir -Filter *.json -File -ErrorAction SilentlyContinue) {
    $s = Get-Content $f.FullName -Raw | ConvertFrom-Json
    $services[$s.id] = $s
    Write-Host "Fresh snapshot: $($s.id) ($($s.level))"
}

# drop services whose settings file was removed
$known = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'services') -Filter *.json | ForEach-Object BaseName)
$list = @($services.Values | Where-Object { $_.id -in $known } | Sort-Object name)

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'site\*') $OutDir -Recurse -Force
New-Item -ItemType File -Force -Path (Join-Path $OutDir '.nojekyll') | Out-Null   # serve files as they are
$json = [ordered]@{
    generatedAt = $now
    run         = [ordered]@{
        trigger         = $Trigger
        url             = $RunUrl
        lastSchedulerAt = $lastScheduler
    }
    services    = $list
} | ConvertTo-Json -Depth 8
# UTF-8 without a byte-order mark, which Windows PowerShell's -Encoding UTF8 would add
[IO.File]::WriteAllText((Join-Path (Resolve-Path $OutDir) 'status.json'), $json, (New-Object Text.UTF8Encoding $false))
Write-Host "Wrote $OutDir with $($list.Count) services"
