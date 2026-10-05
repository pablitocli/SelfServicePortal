#Requires -Version 7.2
<#
.SYNOPSIS
    Collects a lightweight vCenter inventory snapshot for one site into data/inventory/<SITE>.json.
.DESCRIPTION
    Feeds the dynamic drop-downs of the request forms (clusters, datastores, port groups, templates,
    folders, VMs) without querying vCenter on every page load. Started by the portal timer every
    inventory.refreshIntervalMinutes, or on demand from the Admin page. Uses Get-View with selected
    properties only, so a full collection takes seconds even on large vCenters.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string] $Site
)

$ErrorActionPreference = 'Stop'
$root = if ($env:SSP_PORTAL_ROOT) { $env:SSP_PORTAL_ROOT } else { Split-Path -Parent $PSScriptRoot }
$env:SSP_PORTAL_ROOT = $root
Import-Module (Join-Path $root 'modules/Portal.Core.psm1') -Force
Import-Module (Join-Path $root 'automation/lib/Portal.Vsphere.psm1') -Force

$Site       = $Site.ToUpper()
$folder     = Get-PortalPath -Name Inventory
$statusPath = Join-Path $folder "$Site.status.json"
$started    = Get-PortalTimestamp
$vi = $null

try {
    $vi = Connect-PortalVIServer -SiteCode $Site

    # Hosts -> cluster map
    $clusterViews = Get-View -Server $vi -ViewType ClusterComputeResource -Property Name, Host, Summary
    $clusterByMoRef = @{}
    foreach ($c in $clusterViews) { $clusterByMoRef[$c.MoRef.ToString()] = $c.Name }
    $hostViews = Get-View -Server $vi -ViewType HostSystem -Property Name, Parent, Runtime.ConnectionState
    $clusterOfHost = @{}
    foreach ($h in $hostViews) { $clusterOfHost[$h.MoRef.ToString()] = $clusterByMoRef[$h.Parent.ToString()] }

    $clusters = foreach ($c in $clusterViews) {
        [ordered]@{
            name        = $c.Name
            hosts       = @($c.Host).Count
            cpuGHz      = [math]::Round($c.Summary.EffectiveCpu / 1000, 1)
            memoryGB    = [math]::Round($c.Summary.EffectiveMemory / 1024, 0)
        }
    }

    $datastores = foreach ($d in (Get-View -Server $vi -ViewType Datastore -Property Name, Summary, Host)) {
        [ordered]@{
            name        = $d.Name
            type        = $d.Summary.Type
            capacityGB  = [math]::Round($d.Summary.Capacity / 1GB, 0)
            freeGB      = [math]::Round($d.Summary.FreeSpace / 1GB, 0)
            accessible  = [bool]$d.Summary.Accessible
            maintenance = ($d.Summary.MaintenanceMode -and $d.Summary.MaintenanceMode -ne 'normal')
            clusters    = @($d.Host | ForEach-Object { $clusterOfHost[$_.Key.ToString()] } | Where-Object { $_ } | Sort-Object -Unique)
        }
    }

    $datastoreClusters = foreach ($p in (Get-View -Server $vi -ViewType StoragePod -Property Name, Summary)) {
        [ordered]@{ name = $p.Name; capacityGB = [math]::Round($p.Summary.Capacity / 1GB, 0); freeGB = [math]::Round($p.Summary.FreeSpace / 1GB, 0) }
    }

    $portgroups = [System.Collections.Generic.List[object]]::new()
    foreach ($pg in (Get-View -Server $vi -ViewType DistributedVirtualPortgroup -Property Name, Config)) {
        if ($pg.Config.Uplink) { continue }
        $vlan = $pg.Config.DefaultPortConfig.Vlan
        $vlanId = if ($vlan -and $vlan.PSObject.Properties['VlanId'] -and $vlan.VlanId -is [int]) { $vlan.VlanId } else { $null }
        $portgroups.Add([ordered]@{ name = $pg.Name; vlanId = $vlanId; kind = 'Distributed' })
    }
    foreach ($spg in (Get-VirtualPortGroup -Server $vi -Standard -ErrorAction SilentlyContinue | Sort-Object Name -Unique)) {
        if ($portgroups.name -notcontains $spg.Name) { $portgroups.Add([ordered]@{ name = $spg.Name; vlanId = $spg.VLanId; kind = 'Standard' }) }
    }

    $vmViews = Get-View -Server $vi -ViewType VirtualMachine -Property Name, Config.Template, Config.GuestFullName, Runtime.Host, Runtime.PowerState
    $templates = foreach ($v in $vmViews | Where-Object { $_.Config -and $_.Config.Template }) {
        [ordered]@{ name = $v.Name; guestOS = $v.Config.GuestFullName }
    }
    $vms = foreach ($v in $vmViews | Where-Object { $_.Config -and -not $_.Config.Template }) {
        [ordered]@{
            name       = $v.Name
            cluster    = if ($v.Runtime.Host) { $clusterOfHost[$v.Runtime.Host.ToString()] } else { $null }
            powerState = [string]$v.Runtime.PowerState
        }
    }

    # VM folder paths: "Datacenter/Folder/SubFolder" (the hidden 'vm' root folder is omitted).
    $dcViews = Get-View -Server $vi -ViewType Datacenter -Property Name, VmFolder
    $folderViews = Get-View -Server $vi -ViewType Folder -Property Name, Parent, ChildType
    $folderByMoRef = @{}; foreach ($f in $folderViews) { $folderByMoRef[$f.MoRef.ToString()] = $f }
    $dcByVmRoot = @{}; foreach ($dc in $dcViews) { $dcByVmRoot[$dc.VmFolder.ToString()] = $dc.Name }

    $folders = [System.Collections.Generic.List[object]]::new()
    foreach ($dc in $dcViews) { $folders.Add([ordered]@{ name = $dc.Name; path = $dc.Name }) }
    foreach ($f in $folderViews | Where-Object { $_.ChildType -contains 'VirtualMachine' }) {
        if ($dcByVmRoot.ContainsKey($f.MoRef.ToString())) { continue }      # root 'vm' folder
        $segments = [System.Collections.Generic.List[string]]::new()
        $segments.Add($f.Name)
        $parent = $f.Parent.ToString()
        $guard = 0
        while (-not $dcByVmRoot.ContainsKey($parent) -and $folderByMoRef.ContainsKey($parent) -and $guard++ -lt 32) {
            $segments.Insert(0, $folderByMoRef[$parent].Name)
            $parent = $folderByMoRef[$parent].Parent.ToString()
        }
        if ($dcByVmRoot.ContainsKey($parent)) {
            $segments.Insert(0, $dcByVmRoot[$parent])
            $folders.Add([ordered]@{ name = $f.Name; path = ($segments -join '/') })
        }
    }

    $inventory = [ordered]@{
        site              = $Site
        vcenter           = $vi.Name
        vcenterVersion    = "$($vi.Version) build $($vi.Build)"
        collectedAt       = Get-PortalTimestamp
        clusters          = @($clusters | Sort-Object { $_.name })
        datastores        = @($datastores | Sort-Object { $_.name })
        datastoreClusters = @($datastoreClusters | Sort-Object { $_.name })
        portgroups        = @($portgroups | Sort-Object { $_.name })
        templates         = @($templates | Sort-Object { $_.name })
        folders           = @($folders | Sort-Object { $_.path })
        vms               = @($vms | Sort-Object { $_.name })
    }
    Write-PortalJson -Path (Join-Path $folder "$Site.json") -Value $inventory
    Write-PortalJson -Path $statusPath -Value ([ordered]@{ state = 'Succeeded'; pid = $PID; startedAt = $started; finishedAt = (Get-PortalTimestamp); error = $null })
    Write-PortalLog -Message "Inventory $Site refreshed: $(@($clusters).Count) clusters, $(@($datastores).Count) datastores, $(@($vms).Count) VMs."
}
catch {
    $msg = Get-PortalErrorDetail -ErrorRecord $_
    Write-PortalJson -Path $statusPath -Value ([ordered]@{ state = 'Failed'; pid = $PID; startedAt = $started; finishedAt = (Get-PortalTimestamp); error = $msg })
    Write-PortalLog -Level ERROR -Message "Inventory $Site failed: $msg"
    exit 1
}
finally {
    Disconnect-PortalVIServer -Server $vi
}
