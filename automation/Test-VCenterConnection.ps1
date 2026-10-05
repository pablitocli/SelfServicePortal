#Requires -Version 7.2
<#
.SYNOPSIS
    Tests the vCenter connection of a site with the stored credential and writes data/inventory/<SITE>.conn.json.
.DESCRIPTION
    Started by the Admin page ("Test connection"). Runs out-of-process with the portal service identity,
    exactly like the job runners, so a green result guarantees jobs can authenticate too.
#>
[CmdletBinding()]
param([Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9_-]+$')] [string] $Site)

$ErrorActionPreference = 'Stop'
$root = if ($env:SSP_PORTAL_ROOT) { $env:SSP_PORTAL_ROOT } else { Split-Path -Parent $PSScriptRoot }
$env:SSP_PORTAL_ROOT = $root
Import-Module (Join-Path $root 'modules/Portal.Core.psm1') -Force
Import-Module (Join-Path $root 'automation/lib/Portal.Vsphere.psm1') -Force

$Site = $Site.ToUpper()
$out  = Join-Path (Get-PortalPath -Name Inventory) "$Site.conn.json"
Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue
$vi = $null
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $siteCfg = Get-PortalSite -Code $Site
    $vi = Connect-PortalVIServer -SiteCode $Site
    $clusters = @(Get-Cluster -Server $vi | Select-Object -ExpandProperty Name | Sort-Object)
    $dcs      = @(Get-Datacenter -Server $vi | Select-Object -ExpandProperty Name | Sort-Object)
    $checks = [ordered]@{}
    if ($siteCfg.Contains('defaults') -and $siteCfg.defaults.Contains('workloadClusters')) {
        foreach ($k in $siteCfg.defaults.workloadClusters.Keys) {
            $c = $siteCfg.defaults.workloadClusters[$k]
            $checks[$k] = [ordered]@{ cluster = $c; found = [bool]($c -and $clusters -contains $c) }
        }
    }
    Write-PortalJson -Path $out -Value ([ordered]@{
        ok               = $true
        testedAt         = Get-PortalTimestamp
        durationMs       = $sw.ElapsedMilliseconds
        vcenter          = $vi.Name
        version          = "$($vi.Version) build $($vi.Build)"
        user             = $vi.User
        datacenters      = $dcs
        clusters         = $clusters
        workloadClusters = $checks
        error            = $null
    })
}
catch {
    Write-PortalJson -Path $out -Value ([ordered]@{ ok = $false; testedAt = (Get-PortalTimestamp); durationMs = $sw.ElapsedMilliseconds; error = (Get-PortalErrorDetail -ErrorRecord $_) })
    exit 1
}
finally {
    Disconnect-PortalVIServer -Server $vi
}
