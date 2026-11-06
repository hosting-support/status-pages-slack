<#
.SYNOPSIS
  Builds the status page site: site\index.html plus a status.json combining every service's
  snapshot (status\<id>.json, written by status-to-slack.ps1).

.DESCRIPTION
  A run may not have a fresh snapshot for every service (a manual run for one service, or a
  status page that didn't answer). Those keep their entry from the currently published
  status.json (-PreviousUrl), and the page shows them as "No recent data" once they're old.

.EXAMPLE
  .\build-status-page.ps1 -SnapshotDir status -OutDir _site
#>
param(
    [string] $SnapshotDir = (Join-Path $PSScriptRoot 'status'),
    [string] $OutDir      = (Join-Path $PSScriptRoot '_site'),
    [string] $PreviousUrl                     # the published status.json, e.g. https://<user>.github.io/<repo>/status.json
)

$ErrorActionPreference = 'Stop'

$services = [ordered]@{}
if ($PreviousUrl) {
    try {
        foreach ($s in (Invoke-RestMethod -Uri $PreviousUrl -TimeoutSec 20).services) { $services[$s.id] = $s }
        Write-Host "Previous status.json: $($services.Count) services"
    } catch { Write-Host "No previous status.json ($($_.Exception.Message)); starting fresh" }
}
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
    generatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    services    = $list
} | ConvertTo-Json -Depth 8
# UTF-8 without a byte-order mark, which Windows PowerShell's -Encoding UTF8 would add
[IO.File]::WriteAllText((Join-Path (Resolve-Path $OutDir) 'status.json'), $json, (New-Object Text.UTF8Encoding $false))
Write-Host "Wrote $OutDir with $($list.Count) services"
