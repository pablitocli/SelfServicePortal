#Requires -Version 7.2
<#
.SYNOPSIS
    Day-2 handler - adds a thin-provisioned virtual disk to an existing VM (hot-add supported by vSphere).
.DESCRIPTION
    The disk is created on the VM's datastore unless there is not enough room above the site free-space floor.
    The guest OS still needs to bring the disk online / create the filesystem.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] [string] $VMName,
    [Parameter(Mandatory)] [ValidateRange(1, 4096)] [int] $SizeGB,
    [ValidateSet('Thin', 'Thick')] [string] $Format = 'Thin',
    [string] $ChangeTicket,
    [Parameter(Mandatory)] $Context
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) { function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" } }
$vi = $Context.VIServer
$defaults = $Context.Site.defaults
$vm = Get-VM -Name $VMName -Server $vi
if (@(Get-Snapshot -VM $vm -ErrorAction SilentlyContinue).Count) { throw "$VMName has snapshots; consolidate/remove them before adding disks." }
$ds = Get-Datastore -Id ($vm.ExtensionData.Datastore | Select-Object -First 1) -Server $vi
$floor = if ($defaults.minDatastoreFreePercent) { [double]$defaults.minDatastoreFreePercent } else { 10 }
$pctAfter = 100 * ($ds.FreeSpaceGB - $SizeGB) / $ds.CapacityGB
Write-JobLog ("Datastore {0}: {1:N0} GB free, {2:N1}% free after adding {3} GB (floor {4}%)." -f $ds.Name, $ds.FreeSpaceGB, $pctAfter, $SizeGB, $floor)
if ($pctAfter -lt $floor) { throw "Datastore $($ds.Name) would drop below the $floor% free-space floor." }
Write-JobLog -Level STEP "Adding $SizeGB GB ($Format) disk to $VMName"
$disk = New-HardDisk -VM $vm -CapacityGB $SizeGB -StorageFormat $Format -Datastore $ds -Confirm:$false
Write-JobLog -Level OK "Disk added: $($disk.Name) - $($disk.Filename)"
return [ordered]@{ VMName = $VMName; Disk = $disk.Name; SizeGB = $SizeGB; Datastore = $ds.Name; File = $disk.Filename; ChangeTicket = $ChangeTicket
                   NextSteps = @('Bring the disk online in the guest OS (Disk Management / lsblk + mkfs) and update monitoring if needed.') }
