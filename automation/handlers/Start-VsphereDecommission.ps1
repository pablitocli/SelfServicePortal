#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - decommissions a VM into quarantine (nothing is deleted).
.DESCRIPTION
    Pre-checks: the typed confirmation matches the VM name (case-insensitive), the VM is not protected
    (operations.decommission.protectedNamePattern), not a template and not already decommissioned (rename prefix).
    Steps:
      1. Graceful guest shutdown (Shutdown-VMGuest, up to 5 minutes), then hard power-off (Stop-VM) if still running.
      2. Rename to <renamePrefix><name> (default "DECOM-").
      3. Network adapters set to not connect at power-on (the VM is off, so they are already disconnected).
      4. Move to the quarantine folder (operations.decommission.quarantineFolder, created under the VM's datacenter).
      5. Remove the backup policy tag assignment (category = backup data file tagCategory, default "Backup-Policy").
      6. Custom attribute "Portal.Decommission" = "<requestId>;<requester>;purgeAfter=<yyyy-MM-dd>"
         (purge date = today + operations.decommission.quarantineDays).
    Restore: rename back, set the adapters to connect at power-on, move out of quarantine, re-apply the backup tag.
    Permanent deletion is done by the 'vm-decommission-purge' item after the purge date.
    On failure with RollbackOnFailure, the rename, adapter and folder changes are reverted (the VM stays powered off).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] [string] $VMName,
    [Parameter(Mandatory)] [string] $Reason,
    [Parameter(Mandatory)] [string] $ChangeTicket,
    [Parameter(Mandatory)] [string] $ConfirmName,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}
function Get-OpSetting {
    param($Section, [string] $Key, $Default)
    if ($null -eq $Section) { return $Default }
    $v = if ($Section -is [System.Collections.IDictionary]) { if ($Section.Contains($Key)) { $Section[$Key] } } else { $Section.PSObject.Properties[$Key].Value }
    if ($null -eq $v -or ($v -is [string] -and $v -eq '')) { return $Default }
    return $v
}

$vi        = $Context.VIServer
$ops       = $Context.Operations.decommission
$prefix    = [string](Get-OpSetting $ops 'renamePrefix' 'DECOM-')
$qFolder   = [string](Get-OpSetting $ops 'quarantineFolder' 'Portal-Quarantine')
$qDays     = [int](Get-OpSetting $ops 'quarantineDays' 14)
$protected = [string](Get-OpSetting $ops 'protectedNamePattern' '')
$attrName  = 'Portal.Decommission'

# ---- Pre-checks ---------------------------------------------------------------------------------
if ($ConfirmName.Trim() -ine $VMName.Trim()) {
    throw "Confirmation name '$ConfirmName' does not match the VM name '$VMName'. Nothing was changed."
}
if ($protected -and $VMName -match $protected) { throw "VM '$VMName' matches the protected name pattern '$protected' and cannot be decommissioned." }
if ($VMName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "VM '$VMName' already carries the decommission prefix '$prefix'." }

$vm = Get-VM -Name $VMName -Server $vi -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $vm) { throw "VM '$VMName' was not found in $Site." }
if ($vm.ExtensionData.Config.Template) { throw "'$VMName' is a template; templates are not decommissioned with this item." }

$newName = "$prefix$VMName"
if ($newName.Length -gt 80) { throw "New name '$newName' exceeds the vSphere limit of 80 characters." }
if (Get-VM -Name $newName -Server $vi -ErrorAction SilentlyContinue) { throw "A VM named '$newName' already exists." }

$purgeAfter = (Get-Date).Date.AddDays($qDays).ToString('yyyy-MM-dd')
$requester  = [string]$Context.Requester.username
Write-JobLog -Level STEP "Decommission $VMName (change $ChangeTicket) requested by $requester. Quarantine until $purgeAfter."
Write-JobLog "Reason: $Reason"

$originalFolder = $vm.Folder
$renamed = $false; $nicsChanged = @(); $moved = $false
try {
    # ---- 1. Power off ---------------------------------------------------------------------------
    if ($vm.PowerState -eq 'PoweredOn') {
        if ($vm.ExtensionData.Guest.ToolsRunningStatus -eq 'guestToolsRunning') {
            Write-JobLog -Level STEP 'Graceful guest shutdown (up to 5 minutes).'
            $null = Shutdown-VMGuest -VM $vm -Server $vi -Confirm:$false
            for ($i = 0; $i -lt 30; $i++) {          # 30 x 10 s = 5 minutes
                $vm = Get-VM -Id $vm.Id -Server $vi
                if ($vm.PowerState -eq 'PoweredOff') { break }
                Start-Sleep -Seconds 10
            }
        }
        else { Write-JobLog -Level WARN 'VMware Tools not running - graceful shutdown not possible.' }
        if ($vm.PowerState -ne 'PoweredOff') {
            Write-JobLog -Level WARN 'Guest still running: powering off (Stop-VM).'
            $vm = Stop-VM -VM $vm -Server $vi -Confirm:$false
        }
        Write-JobLog -Level OK 'VM powered off.'
    }
    else { Write-JobLog "VM already $($vm.PowerState)." }

    # ---- 2. Rename ------------------------------------------------------------------------------
    $vm = Set-VM -VM $vm -Name $newName -Server $vi -Confirm:$false
    $renamed = $true
    Write-JobLog -Level OK "Renamed to $newName."

    # ---- 3. Network adapters --------------------------------------------------------------------
    foreach ($nic in @(Get-NetworkAdapter -VM $vm -Server $vi)) {
        # -Connected can only be changed on a powered-on VM; the VM is off, so only StartConnected is cleared.
        $null = Set-NetworkAdapter -NetworkAdapter $nic -StartConnected:$false -Server $vi -Confirm:$false
        $nicsChanged += $nic
        Write-JobLog "Adapter '$($nic.Name)' ($($nic.NetworkName), $($nic.MacAddress)) set to not connect at power-on."
    }

    # ---- 4. Quarantine folder -------------------------------------------------------------------
    $dc = Get-Datacenter -VM $vm -Server $vi
    $folder = Get-Folder -Name $qFolder -Location $dc -Type VM -Server $vi -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $folder) {
        $root = Get-Folder -Name 'vm' -Location $dc -Type VM -NoRecursion -Server $vi | Select-Object -First 1
        $folder = New-Folder -Name $qFolder -Location $root -Server $vi
        Write-JobLog "Created quarantine folder '$qFolder' in $($dc.Name)."
    }
    $vm = Move-VM -VM $vm -InventoryLocation $folder -Server $vi -Confirm:$false
    $moved = $true
    Write-JobLog -Level OK "Moved to folder '$qFolder'."

    # ---- 5. Backup tag --------------------------------------------------------------------------
    $tagCategory = 'Backup-Policy'
    if (Get-Command Get-PortalDataFile -ErrorAction SilentlyContinue) {
        $b = Get-PortalDataFile -Name backup
        if ($b -and $b.tagCategory) { $tagCategory = [string]$b.tagCategory }
    }
    $removedTags = @()
    $assigned = @(try { Get-TagAssignment -Entity $vm -Category $tagCategory -Server $vi -ErrorAction SilentlyContinue } catch { })
    foreach ($a in $assigned) {
        Remove-TagAssignment -TagAssignment $a -Confirm:$false
        $removedTags += [string]$a.Tag.Name
    }
    if ($removedTags) { Write-JobLog -Level OK "Removed backup tag(s) [$tagCategory]: $($removedTags -join ', ')." }
    else { Write-JobLog "No '$tagCategory' tag assigned." }

    # ---- 6. Annotation --------------------------------------------------------------------------
    $attr = @(try { Get-CustomAttribute -Name $attrName -TargetType VirtualMachine -Server $vi -ErrorAction SilentlyContinue } catch { })
    if (-not $attr) { $null = New-CustomAttribute -Name $attrName -TargetType VirtualMachine -Server $vi; Write-JobLog "Created custom attribute '$attrName'." }
    $value = "$($Context.RequestId);$requester;purgeAfter=$purgeAfter"
    $null = Set-Annotation -Entity $vm -CustomAttribute $attrName -Value $value -Server $vi
    Write-JobLog -Level OK "Annotation $attrName = $value"
}
catch {
    $msg = $_.Exception.Message
    Write-JobLog -Level ERROR "Decommission failed: $msg"
    if ($Context.RollbackOnFailure) {
        Write-JobLog -Level WARN 'Rolling back (VM stays powered off).'
        try { if ($moved -and $originalFolder) { $vm = Move-VM -VM $vm -InventoryLocation $originalFolder -Server $vi -Confirm:$false } } catch { Write-JobLog -Level WARN "Folder rollback failed: $($_.Exception.Message)" }
        foreach ($n in $nicsChanged) { try { $null = Set-NetworkAdapter -NetworkAdapter $n -StartConnected:$true -Server $vi -Confirm:$false } catch { Write-JobLog -Level WARN "Adapter rollback failed: $($_.Exception.Message)" } }
        try { if ($renamed) { $vm = Set-VM -VM $vm -Name $VMName -Server $vi -Confirm:$false } } catch { Write-JobLog -Level WARN "Rename rollback failed: $($_.Exception.Message)" }
    }
    throw "Decommission of $VMName failed: $msg"
}

return [ordered]@{
    VMName            = $VMName
    NewName           = $newName
    QuarantineFolder  = $qFolder
    PurgeAfter        = $purgeAfter
    BackupTagsRemoved = @($removedTags)
    ChangeTicket      = $ChangeTicket
    NextSteps         = @(
        "The VM is quarantined until $purgeAfter; after that date it is deleted by the 'Purge decommissioned VMs' item (vm-decommission-purge)."
        "To restore: rename $newName back to $VMName, set its network adapters to connect at power-on, move it out of '$qFolder' and re-apply the backup policy."
    )
}
