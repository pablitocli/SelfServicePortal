#Requires -Version 7.2
<#
.SYNOPSIS
    Day-2 handler - power operations on one or more existing VMs (start, guest shutdown, guest restart, hard reset).
.DESCRIPTION
    VMName is the main VM; AdditionalVMs (optional) adds more (comma / new line, max 50). Each VM is processed in
    turn and a failure does not stop the others; the job fails only when every VM failed.
    Restart = guest restart through VMware Tools; with ResetIfToolsDown a VM whose Tools are not running is power
    cycled (hard reset) instead of failing. Shutdown waits up to 10 minutes per VM for the guest to power off.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] [string] $VMName,
    [string] $AdditionalVMs,
    [Parameter(Mandatory)] [ValidateSet('Start', 'Shutdown', 'Restart', 'Reset')] [string] $Action,
    [bool] $ResetIfToolsDown = $false,
    [string] $ChangeTicket,
    [Parameter(Mandatory)] $Context
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) { function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" } }
$vi = $Context.VIServer
$names = @(@($VMName) + @(if ($AdditionalVMs) { $AdditionalVMs -split '[,;\s]+' }) | Where-Object { $_ } | Select-Object -Unique)
if ($names.Count -gt 50) { throw "At most 50 VMs per request ($($names.Count) given)." }
$waitSeconds = if ($Context.PSObject.Properties['PowerWaitSeconds'] -and $Context.PowerWaitSeconds) { [int]$Context.PowerWaitSeconds } else { 10 }

$rows = [System.Collections.Generic.List[object]]::new()
foreach ($n in $names) {
    $before = ''
    try {
        $vm = @(Get-VM -Name $n -Server $vi -ErrorAction SilentlyContinue)
        if ($vm.Count -ne 1) { throw $(if ($vm.Count) { 'more than one VM has this name' } else { 'not found' }) }
        $vm = $vm[0]
        $before = [string]$vm.PowerState
        Write-JobLog -Level STEP "$Action on $n (current state: $before)"
        $tools = [string]$vm.ExtensionData.Guest.ToolsRunningStatus -eq 'guestToolsRunning'
        $note = ''
        switch ($Action) {
            'Start' {
                if ($before -eq 'PoweredOn') { $note = 'already powered on'; break }
                $null = Start-VM -VM $vm -Server $vi -Confirm:$false
            }
            'Shutdown' {
                if ($before -ne 'PoweredOn') { $note = 'not powered on'; break }
                if (-not $tools) { throw 'VMware Tools not running - graceful shutdown impossible (use a hard power off in vCenter if required).' }
                $null = Stop-VMGuest -VM $vm -Server $vi -Confirm:$false
                $deadline = (Get-Date).AddMinutes(10)
                do { Start-Sleep -Seconds $waitSeconds; $vm = Get-VM -Id $vm.Id -Server $vi } until ([string]$vm.PowerState -eq 'PoweredOff' -or (Get-Date) -gt $deadline)
                if ([string]$vm.PowerState -ne 'PoweredOff') { throw 'guest did not shut down within 10 minutes' }
            }
            'Restart' {
                if ($before -ne 'PoweredOn') { throw 'VM is not powered on' }
                if ($tools) {
                    try { $null = Restart-VMGuest -VM $vm -Server $vi -Confirm:$false }
                    catch { if (-not $ResetIfToolsDown) { throw }; $null = Restart-VM -VM $vm -Server $vi -Confirm:$false; $note = "guest restart failed ($($_.Exception.Message)), power cycled" }
                }
                elseif ($ResetIfToolsDown) { $null = Restart-VM -VM $vm -Server $vi -Confirm:$false; $note = 'Tools not running, power cycled' }
                else { throw 'VMware Tools not running - guest restart impossible (enable "Hard reset if Tools are not running").' }
            }
            'Reset' { $null = Restart-VM -VM $vm -Server $vi -Confirm:$false }
        }
        Start-Sleep -Seconds ([math]::Min(5, $waitSeconds))
        $vm = Get-VM -Id $vm.Id -Server $vi
        $rows.Add([ordered]@{ VM = $n; Before = $before; After = [string]$vm.PowerState; Status = 'OK'; Note = $note })
        Write-JobLog -Level OK "${n}: $before -> $($vm.PowerState)$(if ($note) { " ($note)" })"
    }
    catch {
        $rows.Add([ordered]@{ VM = $n; Before = $before; After = ''; Status = 'ERROR'; Note = $_.Exception.Message })
        Write-JobLog -Level WARN "${n}: $($_.Exception.Message)"
    }
}
$failed = @($rows | Where-Object Status -eq 'ERROR')
if ($failed.Count -eq $rows.Count) { throw "$Action failed: $(@($failed | ForEach-Object { "$($_.VM): $($_.Note)" }) -join '; ')" }
if ($names.Count -eq 1) {
    return [ordered]@{ VMName = $VMName; Action = $Action; PowerStateBefore = $rows[0].Before; PowerStateAfter = $rows[0].After; ChangeTicket = $ChangeTicket }
}
return [ordered]@{
    Action = $Action; VMs = $names.Count; Succeeded = $rows.Count - $failed.Count; Failed = $failed.Count; ChangeTicket = $ChangeTicket
    Details = @($rows | ForEach-Object { "$($_.VM): $($_.Status) $($_.Before) -> $($_.After)$(if ($_.Note) { " ($($_.Note))" })" })
}
