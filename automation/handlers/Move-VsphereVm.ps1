#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - migrates a VM (vMotion) to another cluster of the same vCenter, optionally to another datastore.
.DESCRIPTION
    Used by catalog item vm-vmotion. Runs inside automation/Invoke-CatalogJob.ps1 with an open vCenter session.

    Pre-checks: target cluster allowed and different from the current one; target cluster has a connected host that
    is not in maintenance; EVC compatibility (both clusters with EVC and different modes -> fail for a powered-on VM);
    every port group of the VM's NICs exists on the target host(s); datastore free space (worst case = provisioned
    space) keeps the site's minDatastoreFreePercent floor, or the current datastores are visible on the target host;
    memory headroom of the target cluster (warning above 90 %).
    Change: Move-VM -Destination <connected target host with the lowest memory usage> [-Datastore].
    Move-VM is atomic: on failure the VM stays where it was, so there is nothing to roll back.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] [string] $VMName,
    [Parameter(Mandatory)] [string] $Cluster,            # target cluster (input named Cluster so the datastore lookup can filter on it)
    [string] $TargetDatastore,                           # empty = keep the current datastore(s)
    [bool] $KeepPortGroups = $true,
    [string] $ChangeTicket,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}

$vi       = $Context.VIServer
$defaults = $Context.Site.defaults

#region 1. Pre-checks ---------------------------------------------------------------------------------------
Write-JobLog -Level STEP "Pre-checks: move $VMName to cluster $Cluster"

$allowed = @($defaults.allowedClusters | Where-Object { $_ })
if ($allowed.Count -and -not ($allowed | Where-Object { $_ -ieq $Cluster })) { throw "Cluster $Cluster is not in the allowed clusters of site $Site ($($allowed -join ', '))." }

$vm = Get-VM -Name $VMName -Server $vi -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $vm) { throw "VM '$VMName' not found in $($vi.Name)." }
$src = Get-Cluster -VM $vm -Server $vi -ErrorAction SilentlyContinue | Select-Object -First 1
$srcName = if ($src) { $src.Name } else { '(standalone host)' }
if ($src -and $src.Name -ieq $Cluster) { throw "$VMName already runs on cluster $Cluster." }
$tgt = Get-Cluster -Name $Cluster -Server $vi
$poweredOn = [string]$vm.PowerState -eq 'PoweredOn'
Write-JobLog "$VMName ($($vm.PowerState), $($vm.NumCpu) vCPU, $($vm.MemoryGB) GB) on $srcName / $($vm.VMHost.Name)"

# Target hosts: connected (PowerCLI reports maintenance as ConnectionState 'Maintenance').
$tgtHosts = @(Get-VMHost -Location $tgt -Server $vi | Where-Object { [string]$_.ConnectionState -eq 'Connected' })
if (-not $tgtHosts) { throw "Cluster $Cluster has no connected host outside maintenance mode." }

# EVC.
$srcEvc = if ($src) { [string]$src.EVCMode } else { '' }
$tgtEvc = [string]$tgt.EVCMode
if ($srcEvc -and $tgtEvc -and $srcEvc -ne $tgtEvc) {
    if ($poweredOn) { throw "EVC mismatch: $srcName runs EVC mode '$srcEvc' and $Cluster runs '$tgtEvc'. A powered-on VM cannot move between different EVC baselines safely; power it off or use a cluster with the same EVC mode." }
    Write-JobLog -Level WARN "EVC modes differ ($srcEvc -> $tgtEvc); allowed because the VM is powered off."
}
elseif ($srcEvc -ne $tgtEvc) { Write-JobLog -Level WARN "EVC: source '$srcEvc', target '$tgtEvc' (one side without EVC). vCenter validates CPU compatibility during the migration." }
else { Write-JobLog "EVC: '$srcEvc' on both clusters." }

# Destination host = lowest memory usage ratio.
$dest = $tgtHosts | Sort-Object { if ($_.MemoryTotalGB) { $_.MemoryUsageGB / $_.MemoryTotalGB } else { 1 } } | Select-Object -First 1
Write-JobLog "Destination host: $($dest.Name) ($([math]::Round($dest.MemoryUsageGB, 0))/$([math]::Round($dest.MemoryTotalGB, 0)) GB memory used)"

# Networks. KeepPortGroups = true checks every connected target host (DRS can move the VM later); false checks the destination host only.
$nets = @(Get-NetworkAdapter -VM $vm -Server $vi | ForEach-Object NetworkName | Where-Object { $_ } | Select-Object -Unique)
$checkHosts = if ($KeepPortGroups) { $tgtHosts } else { @($dest) }
$gaps = @()
foreach ($h in $checkHosts) {
    $hostPgs = @(Get-VirtualPortGroup -VMHost $h -Server $vi | ForEach-Object Name)
    foreach ($n in $nets) { if ($hostPgs -notcontains $n) { $gaps += "$n on $($h.Name)" } }
}
if ($gaps) { throw "Port group(s) of $VMName not available on the target: $($gaps -join '; '). Extend the network to $Cluster first." }
Write-JobLog "Networks available on target: $($nets -join ', ')"

# Storage.
$floorPct = if ($defaults.minDatastoreFreePercent) { [double]$defaults.minDatastoreFreePercent } else { 10 }
$ds = $null
$curDs = @(Get-Datastore -RelatedObject $vm -Server $vi -ErrorAction SilentlyContinue)
$destDs = @(Get-Datastore -VMHost $dest -Server $vi | ForEach-Object Name)
if ($TargetDatastore -and -not ($curDs.Count -eq 1 -and $curDs[0].Name -ieq $TargetDatastore)) {
    $ds = Get-Datastore -Name $TargetDatastore -Server $vi
    if ($destDs -notcontains $ds.Name) { throw "Datastore $TargetDatastore is not mounted on destination host $($dest.Name)." }
    $needGB   = [math]::Ceiling([double]$vm.ProvisionedSpaceGB)
    $pctAfter = 100 * ($ds.FreeSpaceGB - $needGB) / $ds.CapacityGB
    Write-JobLog ("Datastore {0}: {1:N0} GB free, VM provisioned {2:N0} GB (used {3:N0} GB), {4:N1}% free after the move (floor {5}%)." -f $ds.Name, $ds.FreeSpaceGB, $needGB, $vm.UsedSpaceGB, $pctAfter, $floorPct)
    if ($pctAfter -lt $floorPct) { throw "Datastore $TargetDatastore would drop below the $floorPct% free-space floor (needs $needGB GB, $([math]::Round($ds.FreeSpaceGB, 0)) GB free)." }
}
else {
    $notShared = @($curDs | Where-Object { $destDs -notcontains $_.Name } | ForEach-Object Name)
    if ($notShared) { throw "Current datastore(s) $($notShared -join ', ') are not visible from $Cluster; select a target datastore." }
    Write-JobLog "Storage stays on $(@($curDs.Name) -join ', ') (shared with $Cluster)."
}

# Memory / CPU headroom (informational).
$clVms   = @(Get-VM -Location $tgt -Server $vi | Where-Object { [string]$_.PowerState -eq 'PoweredOn' })
$vmMemGB = ($clVms | Measure-Object -Property MemoryGB -Sum).Sum + $(if ($poweredOn) { $vm.MemoryGB } else { 0 })
$hostGB  = ($tgtHosts | Measure-Object -Property MemoryTotalGB -Sum).Sum
$memPct  = if ($hostGB) { 100 * $vmMemGB / $hostGB } else { 100 }
$vcpu    = ($clVms | Measure-Object -Property NumCpu -Sum).Sum + $(if ($poweredOn) { $vm.NumCpu } else { 0 })
$pcpu    = ($tgtHosts | Measure-Object -Property NumCpu -Sum).Sum
Write-JobLog ("Target headroom: {0:N0} GB powered-on VM memory / {1:N0} GB host memory ({2:N0}%); vCPU:pCPU {3}:{4}." -f $vmMemGB, $hostGB, $memPct, $vcpu, $pcpu)
if ($memPct -gt 90) { Write-JobLog -Level WARN "Cluster $Cluster would be at $([math]::Round($memPct, 0))% memory allocation after the move (> 90%)." }
#endregion

#region 2. Move ---------------------------------------------------------------------------------------------
$moveArgs = @{ VM = $vm; Destination = $dest; Server = $vi; Confirm = $false }
if ($ds) { $moveArgs.Datastore = $ds }
Write-JobLog -Level STEP "Move-VM $VMName -> $($dest.Name)$(if ($ds) { " / $($ds.Name)" }) (change $ChangeTicket)"
$moved = Move-VM @moveArgs
$after = Get-VM -Name $VMName -Server $vi | Select-Object -First 1
$finalHost = if ($after.VMHost) { $after.VMHost.Name } elseif ($moved.VMHost) { $moved.VMHost.Name } else { $dest.Name }
Write-JobLog -Level OK "$VMName now runs on $finalHost ($Cluster)."
#endregion

return [ordered]@{
    VMName          = $VMName
    SourceCluster   = $srcName
    TargetCluster   = $Cluster
    DestinationHost = $finalHost
    Datastore       = $(if ($ds) { $ds.Name } else { (@($curDs.Name) -join ', ') })
    PowerState      = [string]$vm.PowerState
    ChangeTicket    = $ChangeTicket
    NextSteps       = @("Review DRS rules / groups of $srcName that referenced $VMName; they do not follow the VM to $Cluster.")
}
