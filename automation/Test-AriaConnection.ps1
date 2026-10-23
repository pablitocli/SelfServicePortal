#Requires -Version 7.2
<#
.SYNOPSIS
    Tests the Aria Operations connection of a site and reads its report definitions; writes data/inventory/<SITE>.aria.json.
.DESCRIPTION
    Started by Admin > vCenter connections > Aria Operations > "Test and sync reports". Runs out-of-process with the
    portal service identity, like the job runners. The token is released at the end. Nothing is changed in Aria.
#>
[CmdletBinding()]
param([Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9_-]+$')] [string] $Site)

$ErrorActionPreference = 'Stop'
$root = if ($env:SSP_PORTAL_ROOT) { $env:SSP_PORTAL_ROOT } else { Split-Path -Parent $PSScriptRoot }
$env:SSP_PORTAL_ROOT = $root
Import-Module (Join-Path $root 'modules/Portal.Core.psm1') -Force
Import-Module (Join-Path $root 'modules/Portal.Vault.psm1') -Force
Import-Module (Join-Path $root 'automation/lib/Portal.AriaOps.psm1') -Force

$Site = $Site.ToUpper()
$out  = Join-Path (Get-PortalPath -Name Inventory) "$Site.aria.json"
Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue
$aria = $null
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $siteCfg = Get-PortalSite -Code $Site
    if (-not $siteCfg) { throw "Site $Site not found." }
    $aria = Connect-PortalAria -Site $siteCfg
    $defs = @(Get-PortalAriaReportDefinitions -Aria $aria)
    $vmCount = $null
    try {
        $r = Invoke-PortalAriaRequest -Aria $aria -Path '/resources?resourceKind=VirtualMachine&adapterKind=VMWARE&pageSize=1'
        $vmCount = [int]$r.pageInfo.totalCount
    } catch { $vmCount = $null }
    Write-PortalJson -Path $out -Value ([ordered]@{
        ok                = $true
        testedAt          = Get-PortalTimestamp
        durationMs        = $sw.ElapsedMilliseconds
        endpoint          = $aria.Endpoint
        version           = $aria.Version
        user              = $(if ($siteCfg.aria.credential.id) { (Get-PortalVaultEntry -Id ([string]$siteCfg.aria.credential.id)).username } else { '' })
        virtualMachines   = $vmCount
        reportDefinitions = $defs
        error             = $null
    })
}
catch {
    Write-PortalJson -Path $out -Value ([ordered]@{ ok = $false; testedAt = (Get-PortalTimestamp); durationMs = $sw.ElapsedMilliseconds; reportDefinitions = @(); error = (Get-PortalErrorDetail -ErrorRecord $_) })
    exit 1
}
finally {
    Disconnect-PortalAria -Aria $aria
}
