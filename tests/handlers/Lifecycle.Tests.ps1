#Requires -Version 7.2
<#
.SYNOPSIS
    Offline tests for the "VM lifecycle" group: vm-decommission, vm-decommission-purge, snapshot-cleanup,
    vm-test-clone, vm-rightsizing. PowerCLI cmdlets are global stubs over an in-memory inventory; every change
    is recorded in $global:LcCalls so dry runs can be asserted to change nothing.
#>
. (Join-Path $PSScriptRoot '_TestHelpers.ps1')
Start-TestGroup 'VM lifecycle'

# ---- Fake inventory -----------------------------------------------------------------------------
function global:New-LcVm {
    param([string] $Name, [string] $PowerState = 'PoweredOn', [string] $Folder = 'Apps', [string] $Cluster = 'CL-APP-01',
          [int] $NumCpu = 4, [double] $MemoryGB = 16, [bool] $Template = $false, [string] $Tools = 'guestToolsRunning', [hashtable] $Annotations = @{})
    [pscustomobject]@{
        Name = $Name; Id = "VirtualMachine-vm-$([guid]::NewGuid().ToString('N').Substring(0, 8))"; PowerState = $PowerState
        Folder = [pscustomobject]@{ Name = $Folder }; Cluster = $Cluster; NumCpu = $NumCpu; MemoryGB = $MemoryGB
        UsedSpaceGB = 40; ProvisionedSpaceGB = 60; Annotations = $Annotations.Clone()
        ExtensionData = [pscustomobject]@{ Config = [pscustomobject]@{ Template = $Template }; Guest = [pscustomobject]@{ ToolsRunningStatus = $Tools }
                                           Runtime = [pscustomobject]@{ ConsolidationNeeded = $false } }
    }
}
function global:Reset-Lc {
    param([object[]] $Vms = @())
    $global:LcVms = [System.Collections.Generic.List[object]]::new(); foreach ($v in $Vms) { $global:LcVms.Add($v) }
    $global:LcCalls = [System.Collections.Generic.List[string]]::new()
    $global:LcNics = @{}; $global:LcSnaps = @(); $global:LcTags = @(); $global:LcStats = @{}
    $global:LcAttrs = [System.Collections.Generic.List[string]]::new()
    $global:LcFolders = [System.Collections.Generic.List[string]]::new(); $global:LcFolders.Add('Apps')
    $global:LcFailOn = ''; $global:LcGuestHangs = $false
}
function global:Get-LcVm { param([string] $Name) $global:LcVms | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1 }
function global:Test-LcCall { param([string] $Pattern) [bool]@($global:LcCalls | Where-Object { $_ -match $Pattern }).Count }
function global:Test-LcFail { param([string] $Cmd) if ($global:LcFailOn -eq $Cmd) { throw "Simulated failure in $Cmd" } }

# ---- PowerCLI stubs -----------------------------------------------------------------------------
function global:Get-VM {
    [CmdletBinding()] param($Name, $Id, $Location, $Server)
    $r = @($global:LcVms)
    if ($Id)       { $r = @($r | Where-Object { $_.Id -eq $Id }) }
    if ($Name)     { $r = @($r | Where-Object { $_.Name -ieq [string]$Name }) }
    if ($Location) { $r = @($r | Where-Object { $_.Folder.Name -eq $Location.Name -or $_.Cluster -eq $Location.Name }) }
    if ($Name -and -not $r) { Write-Error "VM with name '$Name' was not found using the specified filter(s)." }
    $r
}
function global:Shutdown-VMGuest { [CmdletBinding(SupportsShouldProcess)] param($VM, $Server) $global:LcCalls.Add("Shutdown-VMGuest:$($VM.Name)"); if (-not $global:LcGuestHangs) { $VM.PowerState = 'PoweredOff' }; [pscustomobject]@{ VM = $VM } }
function global:Stop-VM  { [CmdletBinding(SupportsShouldProcess)] param($VM, $Server) $global:LcCalls.Add("Stop-VM:$($VM.Name)"); $VM.PowerState = 'PoweredOff'; $VM }
function global:Start-VM { [CmdletBinding(SupportsShouldProcess)] param($VM, $Server) $global:LcCalls.Add("Start-VM:$($VM.Name)"); $VM.PowerState = 'PoweredOn'; $VM }
function global:Set-VM   { [CmdletBinding(SupportsShouldProcess)] param($VM, $Name, $Server) Test-LcFail 'Set-VM'; $global:LcCalls.Add("Set-VM:$($VM.Name)->$Name"); $VM.Name = $Name; $VM }
function global:Remove-VM { [CmdletBinding(SupportsShouldProcess)] param($VM, [switch] $DeletePermanently, $Server) $global:LcCalls.Add("Remove-VM:$($VM.Name):perm=$([bool]$DeletePermanently)"); $null = $global:LcVms.Remove($VM) }
function global:New-VM {
    [CmdletBinding(SupportsShouldProcess)] param($VM, $Name, $VMHost, $Datastore, $Location, $Server)
    $global:LcCalls.Add("New-VM:$($VM.Name)->$Name host=$($VMHost.Name) ds=$($Datastore.Name) folder=$($Location.Name)")
    $c = New-LcVm -Name $Name -PowerState 'PoweredOff' -Folder $Location.Name -Cluster $VM.Cluster
    $global:LcVms.Add($c); $c
}
function global:Move-VM { [CmdletBinding(SupportsShouldProcess)] param($VM, $InventoryLocation, $Server) Test-LcFail 'Move-VM'; $global:LcCalls.Add("Move-VM:$($VM.Name)->$($InventoryLocation.Name)"); $VM.Folder = $InventoryLocation; $VM }
function global:Get-NetworkAdapter {
    [CmdletBinding()] param($VM, $Server)
    if (-not $global:LcNics.ContainsKey($VM.Id)) {
        $global:LcNics[$VM.Id] = @([pscustomobject]@{ Name = 'Network adapter 1'; NetworkName = 'PG-APP-100'; MacAddress = '00:50:56:aa:bb:01'; StartConnected = $true },
                                   [pscustomobject]@{ Name = 'Network adapter 2'; NetworkName = 'PG-BKP-200'; MacAddress = '00:50:56:aa:bb:02'; StartConnected = $true })
    }
    $global:LcNics[$VM.Id]
}
function global:Set-NetworkAdapter {
    [CmdletBinding(SupportsShouldProcess)] param($NetworkAdapter, $MacAddress, $NetworkName, $Portgroup, $StartConnected, $Connected, $Server)
    $n = $NetworkAdapter
    if ($PSBoundParameters.ContainsKey('StartConnected')) { $n.StartConnected = [bool]$StartConnected }
    if ($MacAddress)  { $n.MacAddress = $MacAddress }
    if ($NetworkName) { $n.NetworkName = $NetworkName }
    if ($Portgroup)   { $n.NetworkName = $Portgroup.Name }
    $global:LcCalls.Add(("Set-NetworkAdapter:{0}:start={1}:mac={2}:net={3}:pg={4}" -f $n.Name, $n.StartConnected, $MacAddress, $NetworkName, $Portgroup.Name))
    $n
}
function global:Get-Datacenter { [CmdletBinding()] param($VM, $Server) [pscustomobject]@{ Name = 'DC1-Datacenter' } }
function global:Get-Folder {
    [CmdletBinding()] param($Name, $Location, $Type, [switch] $NoRecursion, $Server)
    if ($Name -eq 'vm') { return [pscustomobject]@{ Name = 'vm' } }
    if ($global:LcFolders -contains $Name) { return [pscustomobject]@{ Name = $Name } }
    Write-Error "Folder with name '$Name' was not found."
}
function global:New-Folder { [CmdletBinding()] param($Name, $Location, $Server) $global:LcCalls.Add("New-Folder:$Name in $($Location.Name)"); $global:LcFolders.Add($Name); [pscustomobject]@{ Name = $Name } }
function global:Get-TagAssignment { [CmdletBinding()] param($Entity, $Category, $Server) @($global:LcTags | Where-Object { $_.EntityId -eq $Entity.Id -and $_.Tag.Category.Name -eq $Category }) }
function global:Remove-TagAssignment { [CmdletBinding(SupportsShouldProcess)] param($TagAssignment) $global:LcCalls.Add("Remove-TagAssignment:$($TagAssignment.Tag.Category.Name)/$($TagAssignment.Tag.Name)") }
function global:Get-CustomAttribute { [CmdletBinding()] param($Name, $TargetType, $Server) if ($global:LcAttrs -contains $Name) { [pscustomobject]@{ Name = $Name } } else { Write-Error "Custom attribute '$Name' not found." } }
function global:New-CustomAttribute { [CmdletBinding()] param($Name, $TargetType, $Server) $global:LcCalls.Add("New-CustomAttribute:$Name"); $global:LcAttrs.Add($Name); [pscustomobject]@{ Name = $Name } }
function global:Set-Annotation { [CmdletBinding()] param($Entity, $CustomAttribute, $Value, $Server) Test-LcFail 'Set-Annotation'; $global:LcCalls.Add("Set-Annotation:$($Entity.Name):$CustomAttribute=$Value"); $Entity.Annotations[$CustomAttribute] = $Value; [pscustomobject]@{ Name = $CustomAttribute; Value = $Value } }
function global:Get-Annotation { [CmdletBinding()] param($Entity, $CustomAttribute, $Server) [pscustomobject]@{ Name = $CustomAttribute; Value = $Entity.Annotations[$CustomAttribute] } }
function global:Get-Snapshot { [CmdletBinding()] param($VM, $Server) @($global:LcSnaps | Where-Object { $_.VMId -eq $VM.Id }) }
function global:Remove-Snapshot {
    [CmdletBinding(SupportsShouldProcess)] param($Snapshot, $RemoveChildren, $Server)
    $global:LcCalls.Add("Remove-Snapshot:$($Snapshot.VMName)/$($Snapshot.Name):children=$RemoveChildren")
    $global:LcSnaps = @($global:LcSnaps | Where-Object { $_ -ne $Snapshot })
}
function global:Get-View {
    [CmdletBinding()] param($Id, $Property, $Server)
    $vm = $global:LcVms | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    $v = [pscustomobject]@{ Name = $vm.Name; Runtime = $vm.ExtensionData.Runtime }
    $v | Add-Member -MemberType ScriptMethod -Name ConsolidateVMDisks_Task -Value { $global:LcCalls.Add("ConsolidateVMDisks:$($this.Name)"); 'Task-task-1' }
    $v
}
function global:Get-VirtualPortGroup {
    [CmdletBinding()] param($Name, $Server)
    switch ($Name) {
        'PG-ISOLATED' { [pscustomobject]@{ Name = 'PG-ISOLATED'; Key = 'dvportgroup-77'; VDSwitch = 'DVS-01' } }
        'PG-STD-ISO'  { [pscustomobject]@{ Name = 'PG-STD-ISO'; Key = 'key-vim.host.PortGroup-PG-STD-ISO' } }
        'PG-APP-100'  { [pscustomobject]@{ Name = 'PG-APP-100'; Key = 'dvportgroup-10'; VDSwitch = 'DVS-01' } }
        default       { Write-Error "Port group '$Name' not found." }
    }
}
function global:Get-Datastore {
    [CmdletBinding()] param($Name, $Server)
    switch ($Name) { 'DS01' { [pscustomobject]@{ Name = 'DS01'; FreeSpaceGB = 500 } } 'DS-SMALL' { [pscustomobject]@{ Name = 'DS-SMALL'; FreeSpaceGB = 5 } } default { Write-Error "Datastore '$Name' not found." } }
}
function global:Get-VMHost  { [CmdletBinding()] param($VM, $Server) [pscustomobject]@{ Name = 'esx01.test.local' } }
function global:Get-Cluster {
    [CmdletBinding()] param($Name, $Server)
    if (@('CL-APP-01', 'CL-DB-01', 'CL-OTHER') -contains $Name) { [pscustomobject]@{ Name = $Name } } else { Write-Error "Cluster '$Name' not found." }
}
function global:Get-Stat {
    [CmdletBinding()] param($Entity, $Stat, $Start, $Finish, $IntervalMins, $IntervalSecs, $Server)
    $global:LcCalls.Add("Get-Stat:n=$(@($Entity).Count):interval=$IntervalMins")
    foreach ($e in @($Entity)) {
        $p = $global:LcStats[$e.Name]; if (-not $p) { continue }
        foreach ($m in @($Stat)) {
            $vals = if ($m -eq 'cpu.usage.average') { $p.cpu } else { $p.mem }
            $i = 0
            foreach ($v in $vals) {
                $i++
                [pscustomobject]@{ Entity = $e; EntityId = $e.Id; MetricId = $m; Value = $v; Timestamp = (Get-Date).AddHours(-2 * $i); Instance = '' }
                # Per-core instance rows must be ignored by the handler.
                [pscustomobject]@{ Entity = $e; EntityId = $e.Id; MetricId = $m; Value = 100; Timestamp = (Get-Date).AddHours(-2 * $i); Instance = '0' }
            }
        }
    }
}
function global:Start-Sleep { param($Seconds, $Milliseconds) }

$today = (Get-Date).Date
function global:New-OpsCopy { (Get-PortalConfig).operations | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable }

# ================================================================================================
# 5. vm-decommission
# ================================================================================================
Reset-Lc -Vms @((New-LcVm -Name 'APP01'), (New-LcVm -Name 'vCLS-1234'), (New-LcVm -Name 'TPL-W2025' -Template $true -PowerState PoweredOff), (New-LcVm -Name 'DECOM-OLD' -PowerState PoweredOff))
$app = Get-LcVm 'APP01'
$global:LcTags = @([pscustomobject]@{ EntityId = $app.Id; Tag = [pscustomobject]@{ Name = 'Gold'; Category = [pscustomobject]@{ Name = 'Backup-Policy' } } },
                   [pscustomobject]@{ EntityId = $app.Id; Tag = [pscustomobject]@{ Name = 'Prod'; Category = [pscustomobject]@{ Name = 'Environment' } } })
$ctx = New-TestContext -ItemId 'vm-decommission'
$p = @{ Site = 'DC1'; VMName = 'APP01'; Reason = 'Application retired'; ChangeTicket = 'CHG0001'; ConfirmName = 'app01'; Context = $ctx }
$r = Invoke-TestHandler -Handler 'Start-VsphereDecommission.ps1' -Parameters $p
$purge = $today.AddDays(14).ToString('yyyy-MM-dd')
Assert-Test -Name 'Decommission: completes (confirm name case-insensitive)' -Condition ($null -eq $r.Error -and $r.Result.NewName -eq 'DECOM-APP01') -Detail $r.Error
Assert-Test -Name 'Decommission: purge date = today + quarantineDays' -Condition ($r.Result.PurgeAfter -eq $purge) -Detail $r.Result.PurgeAfter
Assert-Test -Name 'Decommission: graceful shutdown, no hard stop' -Condition ((Test-LcCall '^Shutdown-VMGuest:APP01$') -and -not (Test-LcCall '^Stop-VM')) -Detail ($global:LcCalls -join ' | ')
Assert-Test -Name 'Decommission: renamed + both NICs not connected at power-on' -Condition ((Test-LcCall '^Set-VM:APP01->DECOM-APP01$') -and @($global:LcCalls | Where-Object { $_ -match '^Set-NetworkAdapter:.*start=False' }).Count -eq 2)
Assert-Test -Name 'Decommission: quarantine folder created and VM moved' -Condition ((Test-LcCall '^New-Folder:Portal-Quarantine in vm$') -and (Test-LcCall '^Move-VM:DECOM-APP01->Portal-Quarantine$'))
Assert-Test -Name 'Decommission: only the backup tag removed' -Condition ((Test-LcCall '^Remove-TagAssignment:Backup-Policy/Gold$') -and -not (Test-LcCall 'Environment/Prod') -and @($r.Result.BackupTagsRemoved) -contains 'Gold')
Assert-Test -Name 'Decommission: annotation requestId;requester;purgeAfter' -Condition ((Test-LcCall '^New-CustomAttribute:Portal\.Decommission$') -and $app.Annotations['Portal.Decommission'] -eq "$($ctx.RequestId);jdoe;purgeAfter=$purge") -Detail $app.Annotations['Portal.Decommission']
Assert-Test -Name 'Decommission: nothing deleted' -Condition (-not (Test-LcCall '^Remove-VM'))

$global:LcCalls.Clear()
$r = Invoke-TestHandler -Handler 'Start-VsphereDecommission.ps1' -Parameters @{ Site = 'DC1'; VMName = 'DECOM-APP01'; Reason = 'x'; ChangeTicket = 'CHG1'; ConfirmName = 'DECOM-APP0'; Context = $ctx }
Assert-Test -Name 'Decommission: ConfirmName mismatch fails without changes' -Condition ($r.Error -match 'does not match' -and $global:LcCalls.Count -eq 0) -Detail $r.Error
$r = Invoke-TestHandler -Handler 'Start-VsphereDecommission.ps1' -Parameters @{ Site = 'DC1'; VMName = 'vCLS-1234'; Reason = 'x'; ChangeTicket = 'CHG1'; ConfirmName = 'vCLS-1234'; Context = $ctx }
Assert-Test -Name 'Decommission: protected name rejected' -Condition ($r.Error -match 'protected name pattern') -Detail $r.Error
$r = Invoke-TestHandler -Handler 'Start-VsphereDecommission.ps1' -Parameters @{ Site = 'DC1'; VMName = 'TPL-W2025'; Reason = 'x'; ChangeTicket = 'CHG1'; ConfirmName = 'TPL-W2025'; Context = $ctx }
Assert-Test -Name 'Decommission: template rejected' -Condition ($r.Error -match 'template') -Detail $r.Error
$r = Invoke-TestHandler -Handler 'Start-VsphereDecommission.ps1' -Parameters @{ Site = 'DC1'; VMName = 'DECOM-OLD'; Reason = 'x'; ChangeTicket = 'CHG1'; ConfirmName = 'DECOM-OLD'; Context = $ctx }
Assert-Test -Name 'Decommission: already prefixed rejected' -Condition ($r.Error -match 'already carries') -Detail $r.Error
Assert-Test -Name 'Decommission: failed pre-checks changed nothing' -Condition ($global:LcCalls.Count -eq 0) -Detail ($global:LcCalls -join ' | ')

# Guest does not shut down -> hard power-off; Move-VM fails -> rollback of rename and adapters.
Reset-Lc -Vms @(New-LcVm -Name 'APP03')
$global:LcFolders.Add('Portal-Quarantine'); $global:LcAttrs.Add('Portal.Decommission')
$global:LcGuestHangs = $true; $global:LcFailOn = 'Move-VM'
$ctx = New-TestContext -ItemId 'vm-decommission'
$r = Invoke-TestHandler -Handler 'Start-VsphereDecommission.ps1' -Parameters @{ Site = 'DC1'; VMName = 'APP03'; Reason = 'x'; ChangeTicket = 'CHG3'; ConfirmName = 'APP03'; Context = $ctx }
Assert-Test -Name 'Decommission: guest hang -> Stop-VM after the wait' -Condition ((Test-LcCall '^Shutdown-VMGuest:APP03$') -and (Test-LcCall '^Stop-VM:APP03$')) -Detail ($global:LcCalls -join ' | ')
Assert-Test -Name 'Decommission: failure rolls back rename and adapters' -Condition ($r.Error -match 'Simulated failure in Move-VM' -and (Get-LcVm 'APP03') -and (Test-LcCall '^Set-VM:DECOM-APP03->APP03$') -and @($global:LcCalls | Where-Object { $_ -match '^Set-NetworkAdapter:.*start=True' }).Count -eq 2) -Detail "$($r.Error) | $($global:LcCalls -join ' | ')"

# ================================================================================================
# 5b. vm-decommission-purge
# ================================================================================================
$past = $today.AddDays(-1).ToString('yyyy-MM-dd'); $future = $today.AddDays(5).ToString('yyyy-MM-dd')
function global:Reset-Quarantine {
    Reset-Lc -Vms @(
        (New-LcVm -Name 'DECOM-OLD1'  -PowerState PoweredOff -Folder 'Portal-Quarantine' -Annotations @{ 'Portal.Decommission' = "REQ-1;jdoe;purgeAfter=$past" }),
        (New-LcVm -Name 'DECOM-TODAY' -PowerState PoweredOff -Folder 'Portal-Quarantine' -Annotations @{ 'Portal.Decommission' = "REQ-2;jdoe;purgeAfter=$($today.ToString('yyyy-MM-dd'))" }),
        (New-LcVm -Name 'DECOM-NEW1'  -PowerState PoweredOff -Folder 'Portal-Quarantine' -Annotations @{ 'Portal.Decommission' = "REQ-3;jdoe;purgeAfter=$future" }),
        (New-LcVm -Name 'DECOM-ON1'   -PowerState PoweredOn  -Folder 'Portal-Quarantine' -Annotations @{ 'Portal.Decommission' = "REQ-4;jdoe;purgeAfter=$past" }),
        (New-LcVm -Name 'DECOM-NOANN' -PowerState PoweredOff -Folder 'Portal-Quarantine'),
        (New-LcVm -Name 'APP-IN-Q'    -PowerState PoweredOff -Folder 'Portal-Quarantine' -Annotations @{ 'Portal.Decommission' = "REQ-5;jdoe;purgeAfter=$past" }),
        (New-LcVm -Name 'DECOM-ELSEWHERE' -PowerState PoweredOff -Folder 'Apps' -Annotations @{ 'Portal.Decommission' = "REQ-6;jdoe;purgeAfter=$past" }))
    $global:LcFolders.Add('Portal-Quarantine')
}
Reset-Quarantine
$ctx = New-TestContext -ItemId 'vm-decommission-purge'
$r = Invoke-TestHandler -Handler 'Remove-VsphereDecommissioned.ps1' -Parameters @{ Site = 'DC1'; Context = $ctx }
Assert-Test -Name 'Purge dry run: completes' -Condition ($null -eq $r.Error -and $r.Result.DryRun -eq $true) -Detail $r.Error
Assert-Test -Name 'Purge dry run: counts (5 prefixed VMs in quarantine; 2 due, 1 not due, 2 skipped)' -Condition ($r.Result.Candidates -eq 5 -and $r.Result.WouldPurge -eq 2 -and $r.Result.NotDue -eq 1 -and $r.Result.Skipped -eq 2 -and $r.Result.Purged -eq 0) -Detail ($r.Result | ConvertTo-Json -Compress)
Assert-Test -Name 'Purge dry run: no Remove-VM' -Condition (-not (Test-LcCall '^Remove-VM'))
$files = Get-TestReportFiles -Context $ctx
Assert-Test -Name 'Purge dry run: HTML + CSV report' -Condition ($files -contains $r.Result.Report -and @($files | Where-Object { $_ -like '*.csv' }).Count -ge 1) -Detail ($files -join ', ')
$csv = Import-Csv (Join-Path $ctx.ReportDir ($files | Where-Object { $_ -like '*.csv' } | Select-Object -First 1))
Assert-Test -Name 'Purge dry run: report statuses' -Condition (($csv | Where-Object VM -eq 'DECOM-OLD1').Status -eq 'WOULD PURGE' -and ($csv | Where-Object VM -eq 'DECOM-NEW1').Status -eq 'NOT DUE' -and ($csv | Where-Object VM -eq 'DECOM-ON1').Status -match '^SKIPPED')

$r = Invoke-TestHandler -Handler 'Remove-VsphereDecommissioned.ps1' -Parameters @{ Site = 'DC1'; DryRun = $false; Context = (New-TestContext -ItemId 'vm-decommission-purge') }
Assert-Test -Name 'Purge: real run without change ticket rejected' -Condition ($r.Error -match 'change ticket is required' -and -not (Test-LcCall '^Remove-VM')) -Detail $r.Error

$ctx = New-TestContext -ItemId 'vm-decommission-purge'
$r = Invoke-TestHandler -Handler 'Remove-VsphereDecommissioned.ps1' -Parameters @{ Site = 'DC1'; DryRun = $false; ChangeTicket = 'CHG0042'; Context = $ctx }
$removed = @($global:LcCalls | Where-Object { $_ -like 'Remove-VM:*' })
Assert-Test -Name 'Purge: deletes only due, powered-off, prefixed VMs in quarantine' -Condition ($null -eq $r.Error -and $r.Result.Purged -eq 2 -and $removed.Count -eq 2 -and ($removed -join ',') -match 'DECOM-OLD1:perm=True' -and ($removed -join ',') -match 'DECOM-TODAY:perm=True') -Detail ($removed -join ', ')
Assert-Test -Name 'Purge: report written' -Condition ((Get-TestReportFiles -Context $ctx) -contains $r.Result.Report)

$ctx = New-TestContext -ItemId 'vm-decommission-purge'
$ctx.Operations = New-OpsCopy; $ctx.Operations.decommission.renamePrefix = 'D'
$r = Invoke-TestHandler -Handler 'Remove-VsphereDecommissioned.ps1' -Parameters @{ Site = 'DC1'; Context = $ctx }
Assert-Test -Name 'Purge: unsafe short prefix rejected' -Condition ($r.Error -match 'Unsafe decommission prefix') -Detail $r.Error

# ================================================================================================
# 6. snapshot-cleanup
# ================================================================================================
function global:New-LcSnap { param($Vm, $Name, $Description, $AgeDays, $SizeGB) [pscustomobject]@{ VMId = $Vm.Id; VMName = $Vm.Name; Name = $Name; Description = $Description; Created = (Get-Date).AddDays(-$AgeDays).AddMinutes(-5); SizeGB = $SizeGB } }
function global:Reset-Snapshots {
    Reset-Lc -Vms @((New-LcVm -Name 'VM-A'), (New-LcVm -Name 'VM-B'), (New-LcVm -Name 'VM-C'))
    $a = Get-LcVm 'VM-A'; $b = Get-LcVm 'VM-B'
    $a.ExtensionData.Runtime.ConsolidationNeeded = $true
    $past = (Get-Date).Date.AddDays(-1).ToString('yyyy-MM-dd'); $fut = (Get-Date).Date.AddDays(2).ToString('yyyy-MM-dd')
    $global:LcSnaps = @(
        (New-LcSnap $a 'PORTAL-CHG1-20261001' "Portal request REQ-1 by jdoe. Change: CHG1. Expires: $past" 4 5.5),
        (New-LcSnap $a 'PORTAL-CHG2-20261004' "Portal request REQ-2 by jdoe. Change: CHG2. Expires: $fut" 1 2),
        (New-LcSnap $a 'Manual-old' 'before upgrade' 30 10),
        (New-LcSnap $a 'PORTAL-CHG9' "Do not delete - audit. Expires: $past" 9 3),
        (New-LcSnap $b 'VEEAM BACKUP TEMPORARY SNAPSHOT' 'Please do not delete this snapshot. It is being used by Veeam Backup.' 10 20),
        (New-LcSnap $b 'Small-old' '' 20 0.1))
}
Reset-Snapshots
$ctx = New-TestContext -ItemId 'snapshot-cleanup'
$r = Invoke-TestHandler -Handler 'Invoke-VsphereSnapshotCleanup.ps1' -Parameters @{ Site = 'DC1'; Context = $ctx }
Assert-Test -Name 'Snapshots dry run (PortalOnly): completes' -Condition ($null -eq $r.Error -and $r.Result.DryRun -eq $true) -Detail $r.Error
Assert-Test -Name 'Snapshots dry run: only the expired portal snapshot is a candidate' -Condition ($r.Result.WouldRemove -eq 1 -and $r.Result.Protected -eq 1 -and $r.Result.Kept -eq 1 -and $r.Result.ReclaimGB -eq 5.5) -Detail ($r.Result | ConvertTo-Json -Compress)
Assert-Test -Name 'Snapshots dry run: no Remove-Snapshot / consolidation' -Condition (-not (Test-LcCall '^Remove-Snapshot') -and -not (Test-LcCall '^ConsolidateVMDisks'))
$files = Get-TestReportFiles -Context $ctx
Assert-Test -Name 'Snapshots dry run: HTML + CSV report' -Condition ($files -contains 'snapshot-cleanup.html' -and @($files | Where-Object { $_ -like 'snapshot-cleanup-*.csv' }).Count -eq 1) -Detail ($files -join ', ')
$csv = Import-Csv (Join-Path $ctx.ReportDir ($files | Where-Object { $_ -like '*.csv' } | Select-Object -First 1))
Assert-Test -Name 'Snapshots dry run: protected snapshot SKIPPED-protected' -Condition (($csv | Where-Object Snapshot -eq 'PORTAL-CHG9').Status -eq 'SKIPPED-protected' -and ($csv | Where-Object Snapshot -eq 'PORTAL-CHG1-20261001').Status -eq 'WOULD REMOVE')

$r = Invoke-TestHandler -Handler 'Invoke-VsphereSnapshotCleanup.ps1' -Parameters @{ Site = 'DC1'; DryRun = $false; Context = (New-TestContext -ItemId 'snapshot-cleanup') }
Assert-Test -Name 'Snapshots: real run without change ticket rejected' -Condition ($r.Error -match 'change ticket is required' -and -not (Test-LcCall '^Remove-Snapshot')) -Detail $r.Error

$r = Invoke-TestHandler -Handler 'Invoke-VsphereSnapshotCleanup.ps1' -Parameters @{ Site = 'DC1'; ExpiredOnly = $false; OlderThanDays = 1; Context = (New-TestContext -ItemId 'snapshot-cleanup') }
Assert-Test -Name 'Snapshots: ExpiredOnly off also takes stamped snapshots by age' -Condition ($r.Result.WouldRemove -eq 2 -and -not (Test-LcCall '^Remove-Snapshot')) -Detail ($r.Result | ConvertTo-Json -Compress)

$ctx = New-TestContext -ItemId 'snapshot-cleanup'
$r = Invoke-TestHandler -Handler 'Invoke-VsphereSnapshotCleanup.ps1' -Parameters @{ Site = 'DC1'; Scope = 'All'; MinSizeGB = 1; DryRun = $false; ChangeTicket = 'CHG0100'; Context = $ctx }
$rm = @($global:LcCalls | Where-Object { $_ -like 'Remove-Snapshot:*' })
Assert-Test -Name 'Snapshots (All): removes expired + old unstamped, children kept' -Condition ($null -eq $r.Error -and $r.Result.Removed -eq 2 -and $rm.Count -eq 2 -and ($rm -join ',') -match 'VM-A/PORTAL-CHG1-20261001:children=False' -and ($rm -join ',') -match 'VM-A/Manual-old:children=False') -Detail "$($r.Error) $($rm -join ', ')"
Assert-Test -Name 'Snapshots (All): protected (Veeam / do not delete) and small snapshots untouched' -Condition (-not (Test-LcCall 'VEEAM|PORTAL-CHG9|Small-old') -and $r.Result.Protected -eq 2) -Detail ($r.Result | ConvertTo-Json -Compress)
Assert-Test -Name 'Snapshots (All): consolidation when needed' -Condition ((Test-LcCall '^ConsolidateVMDisks:VM-A$') -and @($r.Result.Consolidated) -contains 'VM-A' -and $r.Result.ReclaimGB -eq 15.5)
Assert-Test -Name 'Snapshots (All): report written' -Condition ((Get-TestReportFiles -Context $ctx) -contains $r.Result.Report)

# ================================================================================================
# 7. vm-test-clone
# ================================================================================================
function global:Reset-Clone { Reset-Lc -Vms @((New-LcVm -Name 'APP01'), (New-LcVm -Name 'TST-EXISTS' -PowerState PoweredOff)) }
Reset-Clone
$ctx = New-TestContext -ItemId 'vm-test-clone'
$r = Invoke-TestHandler -Handler 'New-VsphereTestClone.ps1' -Parameters @{ Site = 'DC1'; VMName = 'APP01'; CloneName = ''; IsolatedPortGroup = 'PG-ISOLATED'; Datastore = 'DS01'; DaysToKeep = 3; PowerOn = $true; ChangeTicket = 'CHG7'; Context = $ctx }
$clone = Get-LcVm 'TST-APP01'
$exp = $today.AddDays(3).ToString('yyyy-MM-dd')
Assert-Test -Name 'Test clone: created with default name on source host' -Condition ($null -eq $r.Error -and $r.Result.CloneName -eq 'TST-APP01' -and $clone -and (Test-LcCall '^New-VM:APP01->TST-APP01 host=esx01\.test\.local ds=DS01 folder=Portal-TestClones$')) -Detail "$($r.Error) $($global:LcCalls -join ' | ')"
Assert-Test -Name 'Test clone: folder created when missing' -Condition (Test-LcCall '^New-Folder:Portal-TestClones in vm$')
$nics = @($global:LcNics[$clone.Id])
$macRx = '^00:50:56:[0-3][0-9A-F]:[0-9A-F]{2}:[0-9A-F]{2}$'
Assert-Test -Name 'Test clone: every NIC on the isolated port group with a new manual MAC' -Condition ($nics.Count -eq 2 -and @($nics | Where-Object { $_.NetworkName -eq 'PG-ISOLATED' -and $_.MacAddress -match $macRx -and $_.StartConnected }).Count -eq 2 -and $nics[0].MacAddress -ne $nics[1].MacAddress) -Detail (($nics | ForEach-Object { "$($_.NetworkName)/$($_.MacAddress)" }) -join ', ')
Assert-Test -Name 'Test clone: distributed port group set via -Portgroup' -Condition (@($global:LcCalls | Where-Object { $_ -match '^Set-NetworkAdapter:.*pg=PG-ISOLATED$' }).Count -eq 2)
Assert-Test -Name 'Test clone: expiry annotation + power-on + result' -Condition ($clone.Annotations['Portal.TestClone'] -eq "$($ctx.RequestId);expires=$exp" -and (Test-LcCall '^Start-VM:TST-APP01$') -and $r.Result.Expires -eq $exp -and @($r.Result.Nics).Count -eq 2) -Detail $clone.Annotations['Portal.TestClone']
Assert-Test -Name 'Test clone: source untouched' -Condition (@($global:LcNics[(Get-LcVm 'APP01').Id] | Where-Object { $_.NetworkName -eq 'PG-APP-100' }).Count -eq 1 -and -not (Test-LcCall 'Set-VM|Stop-VM|Remove-VM'))

Reset-Clone; $global:LcFolders.Add('Portal-TestClones')
$r = Invoke-TestHandler -Handler 'New-VsphereTestClone.ps1' -Parameters @{ Site = 'DC1'; VMName = 'APP01'; CloneName = 'PROD-COPY'; IsolatedPortGroup = 'PG-STD-ISO'; Datastore = 'DS01'; DaysToKeep = 2; Context = (New-TestContext -ItemId 'vm-test-clone') }
Assert-Test -Name 'Test clone: standard port group set via -NetworkName, not powered on' -Condition ($null -eq $r.Error -and @($global:LcCalls | Where-Object { $_ -match '^Set-NetworkAdapter:.*net=PG-STD-ISO:pg=$' }).Count -eq 2 -and -not (Test-LcCall '^Start-VM')) -Detail $r.Error

Reset-Clone
$r = Invoke-TestHandler -Handler 'New-VsphereTestClone.ps1' -Parameters @{ Site = 'DC1'; VMName = 'APP01'; CloneName = 'TST-EXISTS'; IsolatedPortGroup = 'PG-ISOLATED'; Datastore = 'DS01'; Context = (New-TestContext -ItemId 'vm-test-clone') }
Assert-Test -Name 'Test clone: existing clone name rejected' -Condition ($r.Error -match 'already exists' -and -not (Test-LcCall '^New-VM')) -Detail $r.Error
$r = Invoke-TestHandler -Handler 'New-VsphereTestClone.ps1' -Parameters @{ Site = 'DC1'; VMName = 'APP01'; IsolatedPortGroup = 'PG-APP-100'; Datastore = 'DS01'; Context = (New-TestContext -ItemId 'vm-test-clone') }
Assert-Test -Name 'Test clone: source production network rejected' -Condition ($r.Error -match 'used by the source VM') -Detail $r.Error
$r = Invoke-TestHandler -Handler 'New-VsphereTestClone.ps1' -Parameters @{ Site = 'DC1'; VMName = 'APP01'; IsolatedPortGroup = 'PG-ISOLATED'; Datastore = 'DS01'; DaysToKeep = 30; Context = (New-TestContext -ItemId 'vm-test-clone') }
Assert-Test -Name 'Test clone: DaysToKeep above maxDays rejected' -Condition ($r.Error -match 'between 1 and 7') -Detail $r.Error
$r = Invoke-TestHandler -Handler 'New-VsphereTestClone.ps1' -Parameters @{ Site = 'DC1'; VMName = 'APP01'; IsolatedPortGroup = 'PG-ISOLATED'; Datastore = 'DS-SMALL'; Context = (New-TestContext -ItemId 'vm-test-clone') }
Assert-Test -Name 'Test clone: datastore without room rejected' -Condition ($r.Error -match 'GB free') -Detail $r.Error
$ctx = New-TestContext -ItemId 'vm-test-clone'; $ctx.Operations = New-OpsCopy; $ctx.Operations.testClones.isolatedPortgroup = '^PG-ISOLATED$'
$r = Invoke-TestHandler -Handler 'New-VsphereTestClone.ps1' -Parameters @{ Site = 'DC1'; VMName = 'APP01'; IsolatedPortGroup = 'PG-STD-ISO'; Datastore = 'DS01'; Context = $ctx }
Assert-Test -Name 'Test clone: port group outside operations.testClones.isolatedPortgroup rejected' -Condition ($r.Error -match 'not the approved isolated network' -and -not (Test-LcCall '^New-VM')) -Detail $r.Error

Reset-Clone; $global:LcFailOn = 'Set-Annotation'
$r = Invoke-TestHandler -Handler 'New-VsphereTestClone.ps1' -Parameters @{ Site = 'DC1'; VMName = 'APP01'; IsolatedPortGroup = 'PG-ISOLATED'; Datastore = 'DS01'; Context = (New-TestContext -ItemId 'vm-test-clone') }
Assert-Test -Name 'Test clone: failure after clone -> clone deleted (rollback)' -Condition ($r.Error -match 'Simulated failure' -and (Test-LcCall '^Remove-VM:TST-APP01:perm=True$') -and -not (Get-LcVm 'TST-APP01')) -Detail $r.Error

# ================================================================================================
# 8. vm-rightsizing
# ================================================================================================
Reset-Lc -Vms @(
    (New-LcVm -Name 'BIG'  -NumCpu 8 -MemoryGB 32),
    (New-LcVm -Name 'HOT'  -NumCpu 2 -MemoryGB 4),
    (New-LcVm -Name 'FINE' -NumCpu 4 -MemoryGB 8),
    (New-LcVm -Name 'NEW'  -NumCpu 2 -MemoryGB 4),
    (New-LcVm -Name 'OFF'  -PowerState PoweredOff),
    (New-LcVm -Name 'DBVM' -Cluster 'CL-DB-01'))
$global:LcStats = @{
    BIG  = @{ cpu = @(5..12 + 5..12 + 5..12 | ForEach-Object { [double]$_ }); mem = @(1..24 | ForEach-Object { 10.0 }) }    # p95 cpu 12, mem 10
    HOT  = @{ cpu = @(1..24 | ForEach-Object { 95.0 }); mem = @(1..24 | ForEach-Object { 50.0 }) }
    FINE = @{ cpu = @(1..24 | ForEach-Object { 50.0 }); mem = @(1..24 | ForEach-Object { 50.0 }) }
    NEW  = @{ cpu = @(30.0, 30.0); mem = @(30.0, 30.0) }
}
$ctx = New-TestContext -ItemId 'vm-rightsizing'
$r = Invoke-TestHandler -Handler 'Get-VsphereRightSizing.ps1' -Parameters @{ Site = 'DC1'; Cluster = 'CL-APP-01'; Context = $ctx }
Assert-Test -Name 'Right-sizing: cluster analysed (powered-on only)' -Condition ($null -eq $r.Error -and $r.Result.VMsAnalysed -eq 4 -and $r.Result.Ok -eq 1 -and $r.Result.Oversized -eq 1 -and $r.Result.Undersized -eq 1 -and $r.Result.NoData -eq 1) -Detail "$($r.Error) $($r.Result | ConvertTo-Json -Compress)"
Assert-Test -Name 'Right-sizing: 2-hour samples for 30 days' -Condition (Test-LcCall '^Get-Stat:n=4:interval=120$')
$files = Get-TestReportFiles -Context $ctx
Assert-Test -Name 'Right-sizing: HTML + CSV report' -Condition ($files -contains 'vm-right-sizing.html' -and $r.Result.Report -eq 'vm-right-sizing.html' -and @($files | Where-Object { $_ -like '*.csv' }).Count -eq 1) -Detail ($files -join ', ')
$csv = Import-Csv (Join-Path $ctx.ReportDir ($files | Where-Object { $_ -like '*.csv' } | Select-Object -First 1))
$big = $csv | Where-Object VM -eq 'BIG'; $hot = $csv | Where-Object VM -eq 'HOT'
Assert-Test -Name 'Right-sizing: oversized BIG -> 2 vCPU / 6 GB (WARN)' -Condition ($big.Status -eq 'WARN' -and $big.RecVcpu -eq '2' -and $big.RecMemoryGB -eq '6' -and $big.CpuP95 -eq '12') -Detail ($big | ConvertTo-Json -Compress)
Assert-Test -Name 'Right-sizing: undersized HOT -> 4 vCPU (FAIL), memory unchanged' -Condition ($hot.Status -eq 'FAIL' -and $hot.RecVcpu -eq '4' -and $hot.RecMemoryGB -eq '4') -Detail ($hot | ConvertTo-Json -Compress)
Assert-Test -Name 'Right-sizing: advisory only (no change cmdlets)' -Condition (-not (Test-LcCall '^(Set-VM|Stop-VM|Start-VM|Remove-VM)') -and @($r.Result.NextSteps)[0] -match 'vm-resize')

$r = Invoke-TestHandler -Handler 'Get-VsphereRightSizing.ps1' -Parameters @{ Site = 'DC1'; Cluster = 'CL-APP-01'; VMName = 'HOT'; LookbackDays = 60; Context = (New-TestContext -ItemId 'vm-rightsizing') }
Assert-Test -Name 'Right-sizing: single VM, daily samples beyond 30 days' -Condition ($null -eq $r.Error -and $r.Result.VMsAnalysed -eq 1 -and $r.Result.Undersized -eq 1 -and (Test-LcCall '^Get-Stat:n=1:interval=1440$')) -Detail $r.Error
$r = Invoke-TestHandler -Handler 'Get-VsphereRightSizing.ps1' -Parameters @{ Site = 'DC1'; Cluster = 'CL-OTHER'; Context = (New-TestContext -ItemId 'vm-rightsizing') }
Assert-Test -Name 'Right-sizing: cluster outside allowedClusters rejected' -Condition ($r.Error -match 'not allowed') -Detail $r.Error
$r = Invoke-TestHandler -Handler 'Get-VsphereRightSizing.ps1' -Parameters @{ Site = 'DC1'; Cluster = 'CL-APP-01'; VMName = 'DBVM'; Context = (New-TestContext -ItemId 'vm-rightsizing') }
Assert-Test -Name 'Right-sizing: VM from another cluster rejected' -Condition ($r.Error -match "not found in cluster 'CL-APP-01'") -Detail $r.Error
$r = Invoke-TestHandler -Handler 'Get-VsphereRightSizing.ps1' -Parameters @{ Site = 'DC1'; Cluster = 'CL-APP-01'; VMName = 'OFF'; Context = (New-TestContext -ItemId 'vm-rightsizing') }
Assert-Test -Name 'Right-sizing: powered-off VM rejected' -Condition ($r.Error -match 'PoweredOff') -Detail $r.Error

# ---- Clean up stubs so other groups start clean ---------------------------------------------------
'Get-VM', 'Shutdown-VMGuest', 'Stop-VM', 'Start-VM', 'Set-VM', 'Remove-VM', 'New-VM', 'Move-VM', 'Get-NetworkAdapter', 'Set-NetworkAdapter',
'Get-Datacenter', 'Get-Folder', 'New-Folder', 'Get-TagAssignment', 'Remove-TagAssignment', 'Get-CustomAttribute', 'New-CustomAttribute',
'Set-Annotation', 'Get-Annotation', 'Get-Snapshot', 'Remove-Snapshot', 'Get-View', 'Get-VirtualPortGroup', 'Get-Datastore', 'Get-VMHost',
'Get-Cluster', 'Get-Stat', 'Start-Sleep', 'New-LcVm', 'Reset-Lc', 'Get-LcVm', 'Test-LcCall', 'Test-LcFail', 'New-OpsCopy', 'Reset-Quarantine',
'New-LcSnap', 'Reset-Snapshots', 'Reset-Clone' | ForEach-Object { Remove-Item "function:global:$_" -ErrorAction SilentlyContinue }
'LcVms', 'LcCalls', 'LcNics', 'LcSnaps', 'LcTags', 'LcStats', 'LcAttrs', 'LcFolders', 'LcFailOn', 'LcGuestHangs' | ForEach-Object { Remove-Variable -Name $_ -Scope Global -ErrorAction SilentlyContinue }
