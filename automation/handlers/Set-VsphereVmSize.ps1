#Requires -Version 7.2
<#
.SYNOPSIS
    Day-2 handler - changes vCPU / memory of an existing VM.
.DESCRIPTION
    Uses CPU/memory hot-add when enabled on the VM (increase only). Otherwise, if AllowPowerCycle is set,
    the guest is shut down gracefully, resized and powered on again; if not, the job fails without changes.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] [string] $VMName,
    [Parameter(Mandatory)] [int] $CpuCount,
    [Parameter(Mandatory)] [int] $MemoryGB,
    [bool] $AllowPowerCycle = $false,
    [string] $ChangeTicket,
    [Parameter(Mandatory)] $Context
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) { function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" } }
$vi = $Context.VIServer
$vm = Get-VM -Name $VMName -Server $vi
$cur = "$($vm.NumCpu) vCPU / $($vm.MemoryGB) GB"
Write-JobLog -Level STEP "Resize $VMName from $cur to $CpuCount vCPU / $MemoryGB GB"
if ($vm.NumCpu -eq $CpuCount -and $vm.MemoryGB -eq $MemoryGB) { Write-JobLog -Level WARN 'No change requested.'; return [ordered]@{ VMName = $VMName; Result = 'No change' } }

$cfg = $vm.ExtensionData.Config
$hotOk = $vm.PowerState -ne 'PoweredOn' -or (
    ($CpuCount -eq $vm.NumCpu -or ($cfg.CpuHotAddEnabled -and $CpuCount -gt $vm.NumCpu)) -and
    ($MemoryGB -eq $vm.MemoryGB -or ($cfg.MemoryHotAddEnabled -and $MemoryGB -gt $vm.MemoryGB)))
$cycled = $false
if (-not $hotOk) {
    if (-not $AllowPowerCycle) { throw 'Hot-add is not possible for this change (disabled on the VM or a decrease). Re-submit with "Allow power cycle" to shut down, resize and start the VM.' }
    Write-JobLog -Level WARN 'Hot-add not possible: shutting down the guest.'
    if ($vm.ExtensionData.Guest.ToolsRunningStatus -ne 'guestToolsRunning') { throw 'VMware Tools not running - graceful shutdown impossible.' }
    $null = Stop-VMGuest -VM $vm -Confirm:$false
    $deadline = (Get-Date).AddMinutes(10)
    do { Start-Sleep 10; $vm = Get-VM -Id $vm.Id -Server $vi } until ($vm.PowerState -eq 'PoweredOff' -or (Get-Date) -gt $deadline)
    if ($vm.PowerState -ne 'PoweredOff') { throw 'Guest did not shut down within 10 minutes; no change made.' }
    $cycled = $true
}
$vm = Set-VM -VM $vm -NumCpu $CpuCount -MemoryGB $MemoryGB -Confirm:$false
if ($cycled) { $vm = Start-VM -VM $vm -Confirm:$false; Write-JobLog 'VM powered on again.' }
Write-JobLog -Level OK "Resized to $($vm.NumCpu) vCPU / $($vm.MemoryGB) GB."
return [ordered]@{ VMName = $VMName; Before = $cur; After = "$($vm.NumCpu) vCPU / $($vm.MemoryGB) GB"; PowerCycled = $cycled; ChangeTicket = $ChangeTicket }
