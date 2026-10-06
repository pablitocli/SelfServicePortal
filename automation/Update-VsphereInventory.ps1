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

function Add-PortalInventoryHistory {
    <# Appends one capacity sample per site and day to data/inventory/history/<SITE>.jsonl (kept 400 days). #>
    param([string] $Site, $Inventory)
    $dir = Join-Path (Get-PortalPath -Name Inventory) 'history'
    $null = New-Item -ItemType Directory -Path $dir -Force
    $path = Join-Path $dir "$Site.jsonl"
    $today = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
    $lines = @(if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path | Where-Object { $_ } })
    if ($lines.Count -and $lines[-1] -match ('"date":\s*"' + $today + '"')) { return }
    $vmsByCluster = @{}; foreach ($v in @($Inventory.vms)) { if ($v.cluster) { $vmsByCluster[$v.cluster] = 1 + [int]$vmsByCluster[$v.cluster] } }
    $sample = [ordered]@{
        date       = $today
        clusters   = @($Inventory.clusters | ForEach-Object {
            $n = $_.name
            $cv = @($Inventory.vms | Where-Object { $_.cluster -eq $n -and $_.powerState -eq 'PoweredOn' })
            [ordered]@{ name = $n; hosts = $_.hosts; cpuGHz = $_.cpuGHz; memoryGB = $_.memoryGB; vms = [int]$vmsByCluster[$n]
                        vcpu = [int](($cv | Measure-Object -Property numCpu -Sum).Sum); vmMemoryGB = [math]::Round([double](($cv | Measure-Object -Property memoryGB -Sum).Sum), 0) }
        })
        datastores = @($Inventory.datastores | ForEach-Object { [ordered]@{ name = $_.name; capacityGB = $_.capacityGB; freeGB = $_.freeGB } })
    }
    $lines = @($lines | Select-Object -Last 399) + ($sample | ConvertTo-Json -Depth 6 -Compress)
    Set-Content -LiteralPath $path -Value $lines -Encoding utf8
}

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
    $hostViews = Get-View -Server $vi -ViewType HostSystem -Property Name, Parent, Runtime.ConnectionState, Runtime.InMaintenanceMode,
        Config.Product.Version, Config.Product.Build, Summary.Hardware.NumCpuCores, Summary.Hardware.MemorySize, Summary.Hardware.Model
    $clusterOfHost = @{}
    foreach ($h in $hostViews) { $clusterOfHost[$h.MoRef.ToString()] = $clusterByMoRef[$h.Parent.ToString()] }
    $hosts = foreach ($h in $hostViews) {
        [ordered]@{
            name            = $h.Name
            cluster         = $clusterOfHost[$h.MoRef.ToString()]
            connectionState = [string]$h.Runtime.ConnectionState
            maintenance     = [bool]$h.Runtime.InMaintenanceMode
            version         = $(if ($h.Config) { [string]$h.Config.Product.Version } else { $null })
            build           = $(if ($h.Config) { [int]$h.Config.Product.Build } else { $null })
            cpuCores        = [int]$h.Summary.Hardware.NumCpuCores
            memoryGB        = [math]::Round($h.Summary.Hardware.MemorySize / 1GB, 0)
            model           = [string]$h.Summary.Hardware.Model
        }
    }

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

    # Distributed switches (VDS) and their port groups.
    $vdsViews = @(Get-View -Server $vi -ViewType VmwareDistributedVirtualSwitch -Property Name, Summary -ErrorAction SilentlyContinue)
    $vdsByMoRef = @{}; foreach ($d in $vdsViews) { $vdsByMoRef[$d.MoRef.ToString()] = $d.Name }
    $vdSwitches = foreach ($d in $vdsViews) {
        [ordered]@{ name = $d.Name; version = [string]$d.Summary.ProductInfo.Version; hosts = @($d.Summary.HostMember).Count }
    }
    $portgroups = [System.Collections.Generic.List[object]]::new()
    foreach ($pg in (Get-View -Server $vi -ViewType DistributedVirtualPortgroup -Property Name, Config)) {
        if ($pg.Config.Uplink) { continue }
        $vlan = $pg.Config.DefaultPortConfig.Vlan
        $vlanId = if ($vlan -and $vlan.PSObject.Properties['VlanId'] -and $vlan.VlanId -is [int]) { $vlan.VlanId } else { $null }
        $sw = if ($pg.Config.DistributedVirtualSwitch) { $vdsByMoRef[$pg.Config.DistributedVirtualSwitch.ToString()] } else { $null }
        $portgroups.Add([ordered]@{ name = $pg.Name; vlanId = $vlanId; kind = 'Distributed'; switch = $sw })
    }
    foreach ($spg in (Get-VirtualPortGroup -Server $vi -Standard -ErrorAction SilentlyContinue | Sort-Object Name -Unique)) {
        if ($portgroups.name -notcontains $spg.Name) { $portgroups.Add([ordered]@{ name = $spg.Name; vlanId = $spg.VLanId; kind = 'Standard' }) }
    }

    $vmViews = Get-View -Server $vi -ViewType VirtualMachine -Property Name, Config.Template, Config.GuestFullName, Runtime.Host, Runtime.PowerState,
        Config.Hardware.NumCPU, Config.Hardware.MemoryMB
    $templates = foreach ($v in $vmViews | Where-Object { $_.Config -and $_.Config.Template }) {
        [ordered]@{ name = $v.Name; guestOS = $v.Config.GuestFullName }
    }
    $vms = foreach ($v in $vmViews | Where-Object { $_.Config -and -not $_.Config.Template }) {
        [ordered]@{
            name       = $v.Name
            cluster    = if ($v.Runtime.Host) { $clusterOfHost[$v.Runtime.Host.ToString()] } else { $null }
            powerState = [string]$v.Runtime.PowerState
            numCpu     = [int]$v.Config.Hardware.NumCPU
            memoryGB   = [math]::Round($v.Config.Hardware.MemoryMB / 1024, 1)
            guestOS    = [string]$v.Config.GuestFullName
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
        hosts             = @($hosts | Sort-Object { $_.name })
        vdSwitches        = @($vdSwitches | Sort-Object { $_.name })
        datastores        = @($datastores | Sort-Object { $_.name })
        datastoreClusters = @($datastoreClusters | Sort-Object { $_.name })
        portgroups        = @($portgroups | Sort-Object { $_.name })
        templates         = @($templates | Sort-Object { $_.name })
        folders           = @($folders | Sort-Object { $_.path })
        vms               = @($vms | Sort-Object { $_.name })
    }
    Write-PortalJson -Path (Join-Path $folder "$Site.json") -Value $inventory
    Add-PortalInventoryHistory -Site $Site -Inventory $inventory      # one line per day (capacity forecast)
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
