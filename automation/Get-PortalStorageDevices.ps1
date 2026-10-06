#Requires -Version 7.2
<#
.SYNOPSIS
    Lists the storage devices (LUNs) that can hold a new VMFS datastore on a cluster; optionally rescans first.
.DESCRIPTION
    Started by the portal (Portal.Storage\Start-PortalStorageRescan) after the user re-authenticated:
        pwsh -File automation/Get-PortalStorageDevices.ps1 -Site DC1 -Cluster CL-APP-01 [-Rescan]
    -Rescan runs "Rescan all HBAs" + "Rescan VMFS" on every connected host of the cluster that is not in maintenance mode.
    A device is listed when it is not used by VMFS on the first host (QueryAvailableDisksForVmfs) and
    'allHosts' tells whether every connected host of the cluster sees it (only those are offered in the form).
    The result is written by Complete-PortalStorageScan into data/inventory/storage/<SITE>__<cluster>.json.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9_-]+$')] [string] $Site,
    [Parameter(Mandatory)] [string] $Cluster,
    [switch] $Rescan
)

$ErrorActionPreference = 'Stop'
$root = if ($env:SSP_PORTAL_ROOT) { $env:SSP_PORTAL_ROOT } else { Split-Path -Parent $PSScriptRoot }
$env:SSP_PORTAL_ROOT = $root
Import-Module (Join-Path $root 'modules/Portal.Core.psm1') -Force
Import-Module (Join-Path $root 'modules/Portal.Storage.psm1') -Force
Import-Module (Join-Path $root 'automation/lib/Portal.Vsphere.psm1') -Force

$vi = $null
try {
    $vi = Connect-PortalVIServer -SiteCode $Site
    $cl = Get-Cluster -Server $vi -Name $Cluster
    $hosts = @(Get-VMHost -Location $cl | Where-Object { $_.ConnectionState -in 'Connected', 'Maintenance' })
    $active = @($hosts | Where-Object { $_.ConnectionState -eq 'Connected' })
    if (-not $active.Count) { throw "Cluster $Cluster has no connected host." }

    if ($Rescan) {
        foreach ($h in $active) {
            Write-PortalLog -Message "Storage rescan $Site/$Cluster on $($h.Name)"
            $null = Get-VMHostStorage -VMHost $h -RescanAllHba -RescanVmfs
        }
    }

    # Unused devices according to the first host; then check visibility on every connected host.
    $first = $active[0]
    $ds = Get-View -Server $vi -Id $first.ExtensionData.ConfigManager.DatastoreSystem
    $free = @($ds.QueryAvailableDisksForVmfs($null))
    $seen = @{}
    foreach ($h in $active) {
        foreach ($l in @(Get-ScsiLun -VMHost $h -LunType disk -ErrorAction SilentlyContinue)) { $seen[$l.CanonicalName] = 1 + [int]$seen[$l.CanonicalName] }
    }
    $devices = foreach ($d in $free) {
        $sizeGB = [math]::Round(([double]$d.Capacity.BlockSize * [double]$d.Capacity.Block) / 1GB, 1)
        [ordered]@{
            canonicalName = [string]$d.CanonicalName
            sizeGB        = $sizeGB
            vendor        = ([string]$d.Vendor).Trim()
            model         = ([string]$d.Model).Trim()
            ssd           = [bool]$d.Ssd
            devicePath    = [string]$d.DevicePath
            hostsSeeing   = [int]$seen[[string]$d.CanonicalName]
            hostsTotal    = $active.Count
            allHosts      = ([int]$seen[[string]$d.CanonicalName] -ge $active.Count)
        }
    }
    Complete-PortalStorageScan -Site $Site -Cluster $Cluster -Devices @($devices) -Hosts @($active | ForEach-Object { $_.Name })
    Write-PortalLog -Message "Storage scan $Site/$Cluster done: $(@($devices).Count) free device(s)$(if ($Rescan) { ' (after rescan)' })."
}
catch {
    $msg = Get-PortalErrorDetail -ErrorRecord $_
    Complete-PortalStorageScan -Site $Site -Cluster $Cluster -ErrorMessage $msg
    Write-PortalLog -Level ERROR -Message "Storage scan $Site/$Cluster failed: $msg"
    exit 1
}
finally {
    if ($vi) { Disconnect-PortalVIServer -Server $vi }
}
