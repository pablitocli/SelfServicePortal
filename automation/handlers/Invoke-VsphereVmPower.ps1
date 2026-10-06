#Requires -Version 7.2
<#
.SYNOPSIS
    Day-2 handler - power operations on an existing VM (start, guest shutdown, guest restart, hard reset).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] [string] $VMName,
    [Parameter(Mandatory)] [ValidateSet('Start', 'Shutdown', 'Restart', 'Reset')] [string] $Action,
    [string] $ChangeTicket,
    [Parameter(Mandatory)] $Context
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) { function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" } }
$vi = $Context.VIServer
$vm = Get-VM -Name $VMName -Server $vi
$before = [string]$vm.PowerState
Write-JobLog -Level STEP "$Action on $VMName (current state: $before)"

switch ($Action) {
    'Start' {
        if ($before -eq 'PoweredOn') { Write-JobLog -Level WARN 'VM is already powered on.'; break }
        $null = Start-VM -VM $vm -Confirm:$false
    }
    'Shutdown' {
        if ($before -ne 'PoweredOn') { Write-JobLog -Level WARN 'VM is not powered on.'; break }
        if ($vm.ExtensionData.Guest.ToolsRunningStatus -ne 'guestToolsRunning') { throw 'VMware Tools not running - graceful shutdown impossible. Use a hard power off in vCenter if required.' }
        $null = Stop-VMGuest -VM $vm -Confirm:$false
        $deadline = (Get-Date).AddMinutes(10)
        do { Start-Sleep 10; $vm = Get-VM -Id $vm.Id -Server $vi } until ($vm.PowerState -eq 'PoweredOff' -or (Get-Date) -gt $deadline)
        if ($vm.PowerState -ne 'PoweredOff') { throw 'Guest did not shut down within 10 minutes.' }
    }
    'Restart' {
        if ($vm.ExtensionData.Guest.ToolsRunningStatus -ne 'guestToolsRunning') { throw 'VMware Tools not running - guest restart impossible.' }
        $null = Restart-VMGuest -VM $vm -Confirm:$false
    }
    'Reset' { $null = Restart-VM -VM $vm -Confirm:$false }
}
Start-Sleep -Seconds 5
$vm = Get-VM -Id $vm.Id -Server $vi
Write-JobLog -Level OK "Done. Power state: $($vm.PowerState)"
return [ordered]@{ VMName = $VMName; Action = $Action; PowerStateBefore = $before; PowerStateAfter = [string]$vm.PowerState; ChangeTicket = $ChangeTicket }
