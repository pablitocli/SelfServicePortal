#Requires -Version 7.2
<#
.SYNOPSIS
    Offline tests - group "Network and placement": dpg-create, drs-rule, vm-vmotion, host-maintenance.
#>
. (Join-Path $PSScriptRoot '_TestHelpers.ps1')
Start-TestGroup 'Network and placement'

#region Fake inventory ---------------------------------------------------------------------------------------
function global:Reset-NetInventory {
    $mk = { param($n, $cl, $mem, $used, $state = 'Connected') [pscustomobject]@{ Kind = 'Host'; Name = $n; Cluster = $cl; ConnectionState = $state; MemoryTotalGB = $mem; MemoryUsageGB = $used; NumCpu = 32 } }
    $global:NI = [ordered]@{
        Clusters = @(
            [pscustomobject]@{ Kind = 'Cluster'; Name = 'CL-APP-01'; EVCMode = 'intel-broadwell'; DrsEnabled = $true; DrsAutomationLevel = 'FullyAutomated'; HAEnabled = $true; HAAdmissionControlEnabled = $true; HAFailoverLevel = 1; VsanEnabled = $false }
            [pscustomobject]@{ Kind = 'Cluster'; Name = 'CL-DB-01';  EVCMode = 'intel-broadwell'; DrsEnabled = $true; DrsAutomationLevel = 'FullyAutomated'; HAEnabled = $true; HAAdmissionControlEnabled = $true; HAFailoverLevel = 1; VsanEnabled = $false }
        )
        Hosts = @(
            (& $mk 'esx01.test.local' 'CL-APP-01' 512 300), (& $mk 'esx02.test.local' 'CL-APP-01' 512 200), (& $mk 'esx03.test.local' 'CL-APP-01' 512 100)
            (& $mk 'esx11.test.local' 'CL-DB-01' 1024 600), (& $mk 'esx12.test.local' 'CL-DB-01' 1024 200)
        )
        VMs = [System.Collections.Generic.List[object]]::new()
        HostPortGroups = @{ 'esx11.test.local' = @('PG-APP-100', 'PG-MGMT-10'); 'esx12.test.local' = @('PG-APP-100', 'PG-MGMT-10') }
        Datastores = @(
            [pscustomobject]@{ Name = 'DS-APP-01'; CapacityGB = 4096; FreeSpaceGB = 2000; Hosts = @('esx01.test.local', 'esx02.test.local', 'esx03.test.local') }
            [pscustomobject]@{ Name = 'DS-DB-01';  CapacityGB = 4096; FreeSpaceGB = 2000; Hosts = @('esx11.test.local', 'esx12.test.local') }
            [pscustomobject]@{ Name = 'DS-DB-SMALL'; CapacityGB = 1000; FreeSpaceGB = 200; Hosts = @('esx11.test.local', 'esx12.test.local') }
        )
        Switches   = @([pscustomobject]@{ Name = 'VDS-DC1-01' }, [pscustomobject]@{ Name = 'VDS-DC1-02' })
        PortGroups = [System.Collections.Generic.List[object]]::new()
        DrsRules   = [System.Collections.Generic.List[object]]::new()
        HostRules  = [System.Collections.Generic.List[object]]::new()
        DrsGroups  = [System.Collections.Generic.List[object]]::new()
        Calls      = [System.Collections.Generic.List[string]]::new()
        FailSecurity = $false
    }
    $i = 0
    foreach ($v in @(
            @('APPWEB01', 'esx01.test.local', 'PoweredOn', 64), @('APPWEB02', 'esx02.test.local', 'PoweredOn', 64),
            @('APPWEB03', 'esx03.test.local', 'PoweredOn', 64), @('APPOLD01', 'esx01.test.local', 'PoweredOff', 16),
            @('DBSQL01', 'esx11.test.local', 'PoweredOn', 256))) {
        $h = $global:NI.Hosts | Where-Object Name -eq $v[1]
        $global:NI.VMs.Add([pscustomobject]@{ Name = $v[0]; Id = "VirtualMachine-vm-$((++$i))"; HostName = $v[1]; Cluster = $h.Cluster; VMHost = $h
                                              PowerState = $v[2]; MemoryGB = $v[3]; NumCpu = 4; ProvisionedSpaceGB = 300; UsedSpaceGB = 120
                                              Nets = @('PG-APP-100'); Datastores = @($(if ($h.Cluster -eq 'CL-APP-01') { 'DS-APP-01' } else { 'DS-DB-01' })) })
    }
    foreach ($p in @(@('PG-APP-100', 'VDS-DC1-01', 100), @('PG-MGMT-10', 'VDS-DC1-01', 10), @('PG-BKP-300', 'VDS-DC1-02', 300))) {
        $global:NI.PortGroups.Add([pscustomobject]@{ Name = $p[0]; VDSwitch = [pscustomobject]@{ Name = $p[1] }; IsUplink = $false
                                                     VlanConfiguration = [pscustomobject]@{ VlanType = 'Vlan'; VlanId = $p[2] } })
    }
    $global:NI.PortGroups.Add([pscustomobject]@{ Name = 'VDS-DC1-01-Uplinks'; VDSwitch = [pscustomobject]@{ Name = 'VDS-DC1-01' }; IsUplink = $true; VlanConfiguration = $null })
}
#endregion

function global:Join-NetParams { param([hashtable] $Base, [hashtable] $Override) $h = $Base.Clone(); foreach ($k in $Override.Keys) { $h[$k] = $Override[$k] }; $h }

#region PowerCLI stubs -----------------------------------------------------------------------------------------
function global:Get-VDSwitch { param($Name, $Server) $global:NI.Switches | Where-Object { -not $Name -or $_.Name -eq $Name } }
function global:Get-VDPortgroup {
    param($Name, $VDSwitch, $Server)
    $global:NI.PortGroups | Where-Object { (-not $Name -or $_.Name -eq $Name) -and (-not $VDSwitch -or $_.VDSwitch.Name -eq $VDSwitch.Name) }
}
function global:New-VDPortgroup {
    param($VDSwitch, $Name, $VlanId, $NumPorts, $PortBinding, $Notes, $Server)
    $global:NI.Calls.Add("New-VDPortgroup $Name vlan=$VlanId ports=$NumPorts binding=$PortBinding")
    $pg = [pscustomobject]@{ Name = $Name; VDSwitch = $VDSwitch; IsUplink = $false; VlanConfiguration = [pscustomobject]@{ VlanType = 'Vlan'; VlanId = $VlanId }
                             Notes = $Notes; ExtensionData = [pscustomobject]@{ Config = [pscustomobject]@{ AutoExpand = $true } } }
    $global:NI.PortGroups.Add($pg); $pg
}
function global:Remove-VDPortgroup { param($VDPortgroup) $global:NI.Calls.Add("Remove-VDPortgroup $($VDPortgroup.Name)"); $null = $global:NI.PortGroups.Remove($VDPortgroup) }
function global:Get-VDUplinkTeamingPolicy { param($VDPortgroup, $Server) [pscustomobject]@{ PortGroup = $VDPortgroup.Name } }
function global:Set-VDUplinkTeamingPolicy { param($Policy, $LoadBalancingPolicy) $global:NI.Calls.Add("Set-VDUplinkTeamingPolicy $($Policy.PortGroup) $LoadBalancingPolicy") }
function global:Get-VDSecurityPolicy { param($VDPortgroup, $Server) [pscustomobject]@{ PortGroup = $VDPortgroup.Name } }
function global:Set-VDSecurityPolicy {
    param($Policy, $AllowPromiscuous, $MacChanges, $ForgedTransmits)
    if ($global:NI.FailSecurity) { throw 'Simulated vCenter fault on security policy' }
    $global:NI.Calls.Add("Set-VDSecurityPolicy $($Policy.PortGroup) promiscuous=$AllowPromiscuous mac=$MacChanges forged=$ForgedTransmits")
}

function global:Get-Cluster {
    param($Name, $VM, $Server)
    if ($VM) { return $global:NI.Clusters | Where-Object Name -eq $VM.Cluster }
    $c = $global:NI.Clusters | Where-Object { -not $Name -or $_.Name -eq $Name }
    if ($Name -and -not $c) { throw "Cluster '$Name' was not found." }
    $c
}
function global:Get-VMHost {
    param($Name, $Location, $Server)
    $global:NI.Hosts | Where-Object { (-not $Name -or $_.Name -eq $Name) -and (-not $Location -or $_.Cluster -eq $Location.Name) }
}
function global:Get-VM {
    param($Name, $Location, $Server)
    $r = $global:NI.VMs | Where-Object { -not $Name -or $_.Name -eq $Name }
    if ($Location.Kind -eq 'Cluster') { $r = $r | Where-Object Cluster -eq $Location.Name }
    if ($Location.Kind -eq 'Host') { $r = $r | Where-Object HostName -eq $Location.Name }
    $r
}
function global:Get-DrsRule { param($Cluster, $Server) $global:NI.DrsRules | Where-Object Cluster -eq $Cluster.Name }
function global:Get-DrsVMHostRule { param($Cluster, $Server) $global:NI.HostRules | Where-Object Cluster -eq $Cluster.Name }
function global:New-DrsRule {
    param($Cluster, $Name, $KeepTogether, $VM, $Enabled, $Server)
    $global:NI.Calls.Add("New-DrsRule $Name keep=$KeepTogether vms=$(@($VM.Name) -join ',')")
    $r = [pscustomobject]@{ Name = $Name; Cluster = $Cluster.Name; KeepTogether = $KeepTogether; Enabled = $Enabled; VMIds = @($VM.Id) }
    $global:NI.DrsRules.Add($r); $r
}
function global:Get-DrsClusterGroup { param($Cluster, $Name, $Server) $global:NI.DrsGroups | Where-Object { $_.Cluster -eq $Cluster.Name -and $_.Name -eq $Name } }
function global:New-DrsClusterGroup {
    param($Cluster, $Name, $VM, $VMHost, $Server)
    $global:NI.Calls.Add("New-DrsClusterGroup $Name")
    $g = [pscustomobject]@{ Name = $Name; Cluster = $Cluster.Name; Member = [System.Collections.Generic.List[object]]@(@($VM) + @($VMHost) | Where-Object { $_ }) }
    $global:NI.DrsGroups.Add($g); $g
}
function global:Set-DrsClusterGroup {
    param($DrsClusterGroup, $VM, $VMHost, [switch] $Add, $Server)
    $global:NI.Calls.Add("Set-DrsClusterGroup $($DrsClusterGroup.Name) add=$(@(@($VM) + @($VMHost) | Where-Object { $_ } | ForEach-Object Name) -join ',')")
    foreach ($m in @(@($VM) + @($VMHost) | Where-Object { $_ })) { $DrsClusterGroup.Member.Add($m) }
    $DrsClusterGroup
}
function global:Remove-DrsClusterGroup { param($DrsClusterGroup) $global:NI.Calls.Add("Remove-DrsClusterGroup $($DrsClusterGroup.Name)"); $null = $global:NI.DrsGroups.Remove($DrsClusterGroup) }
function global:New-DrsVMHostRule {
    param($Cluster, $Name, $VMGroup, $VMHostGroup, $Type, $Enabled, $Server)
    if ($global:NI.FailHostRule) { throw 'Simulated fault creating VM-Host rule' }
    $global:NI.Calls.Add("New-DrsVMHostRule $Name $Type $($VMGroup.Name) $($VMHostGroup.Name)")
    $r = [pscustomobject]@{ Name = $Name; Cluster = $Cluster.Name; Type = $Type; Enabled = $Enabled }
    $global:NI.HostRules.Add($r); $r
}

function global:Get-NetworkAdapter { param($VM, $Server) $VM.Nets | ForEach-Object { [pscustomobject]@{ Name = 'Network adapter 1'; NetworkName = $_ } } }
function global:Get-VirtualPortGroup {
    param($VMHost, $Server)
    $names = if ($global:NI.HostPortGroups.ContainsKey($VMHost.Name)) { $global:NI.HostPortGroups[$VMHost.Name] } else { @($global:NI.PortGroups.Name) }
    $names | ForEach-Object { [pscustomobject]@{ Name = $_ } }
}
function global:Get-Datastore {
    param($Name, $VMHost, $RelatedObject, $Server)
    if ($RelatedObject) { return $global:NI.Datastores | Where-Object { $RelatedObject.Datastores -contains $_.Name } }
    if ($VMHost) { return $global:NI.Datastores | Where-Object { $_.Hosts -contains $VMHost.Name } }
    $d = $global:NI.Datastores | Where-Object Name -eq $Name
    if (-not $d) { throw "Datastore '$Name' was not found." }
    $d
}
function global:Move-VM {
    param($VM, $Destination, $Datastore, $Server)
    $global:NI.Calls.Add("Move-VM $($VM.Name) -> $($Destination.Name) ds=$($Datastore.Name)")
    $VM.HostName = $Destination.Name; $VM.Cluster = $Destination.Cluster; $VM.VMHost = $Destination
    if ($Datastore) { $VM.Datastores = @($Datastore.Name) }
    $VM
}
function global:Set-VMHost {
    param($VMHost, $State, $Evacuate, $VsanDataMigrationMode, $Server)
    $global:NI.Calls.Add("Set-VMHost $($VMHost.Name) state=$State evacuate=$Evacuate vsan=$VsanDataMigrationMode")
    $VMHost.ConnectionState = $State
    if ($State -eq 'Maintenance') {
        $target = $global:NI.Hosts | Where-Object { $_.Cluster -eq $VMHost.Cluster -and $_.Name -ne $VMHost.Name -and $_.ConnectionState -eq 'Connected' } | Select-Object -First 1
        foreach ($v in @($global:NI.VMs | Where-Object { $_.HostName -eq $VMHost.Name -and ($_.PowerState -eq 'PoweredOn' -or $Evacuate) })) { $v.HostName = $target.Name; $v.VMHost = $target }
    }
    $VMHost
}
#endregion

#region dpg-create ---------------------------------------------------------------------------------------------
Reset-NetInventory
$base = @{ Site = 'DC1'; VDSwitch = 'VDS-DC1-01'; VlanId = 120; Name = 'PG-DC1-120-APP'; Purpose = 'App tier'; NumPorts = 8; LoadBalancing = 'LoadBalanceLoadBased'; ChangeTicket = 'CHG0001' }
$ctx = New-TestContext -ItemId 'dpg-create'
$r = Invoke-TestHandler -Handler 'New-VsphereDistributedPortgroup.ps1' -Parameters (Join-NetParams $base @{ Context = $ctx })
Assert-Test -Name 'DPG: created' -Condition ($null -eq $r.Error -and $r.Result.PortGroup -eq 'PG-DC1-120-APP' -and $r.Result.VlanId -eq 120) -Detail $r.Error
Assert-Test -Name 'DPG: static binding, teaming and security applied' -Condition (
    ($global:NI.Calls -match 'New-VDPortgroup PG-DC1-120-APP vlan=120 ports=8 binding=Static') -and
    ($global:NI.Calls -match 'Set-VDUplinkTeamingPolicy PG-DC1-120-APP LoadBalanceLoadBased') -and
    ($global:NI.Calls -match 'promiscuous=False mac=False forged=False')) -Detail ($global:NI.Calls -join ' | ')

Reset-NetInventory
$r = Invoke-TestHandler -Handler 'New-VsphereDistributedPortgroup.ps1' -Parameters (Join-NetParams $base @{ VlanId = 100; Context = (New-TestContext -ItemId 'dpg-create') })
Assert-Test -Name 'DPG: VLAN conflict names the port group' -Condition ($r.Error -match 'VLAN 100 is already used' -and $r.Error -match 'PG-APP-100' -and -not ($global:NI.Calls -match 'New-VDPortgroup')) -Detail $r.Error

Reset-NetInventory
$r = Invoke-TestHandler -Handler 'New-VsphereDistributedPortgroup.ps1' -Parameters (Join-NetParams $base @{ VlanId = 300; Context = (New-TestContext -ItemId 'dpg-create') })
Assert-Test -Name 'DPG: same VLAN on another switch is allowed' -Condition ($null -eq $r.Error) -Detail $r.Error

Reset-NetInventory
$r = Invoke-TestHandler -Handler 'New-VsphereDistributedPortgroup.ps1' -Parameters (Join-NetParams $base @{ Name = 'pg-bkp-300'; Context = (New-TestContext -ItemId 'dpg-create') })
Assert-Test -Name 'DPG: duplicate name on another switch rejected' -Condition ($r.Error -match "already exists on VDS-DC1-02") -Detail $r.Error

Reset-NetInventory
$r = Invoke-TestHandler -Handler 'New-VsphereDistributedPortgroup.ps1' -Parameters (Join-NetParams $base @{ VDSwitch = 'VDS-NOPE'; Context = (New-TestContext -ItemId 'dpg-create') })
Assert-Test -Name 'DPG: unknown switch rejected' -Condition ($r.Error -match "Distributed switch 'VDS-NOPE' not found") -Detail $r.Error

Reset-NetInventory
$global:NI.FailSecurity = $true
$r = Invoke-TestHandler -Handler 'New-VsphereDistributedPortgroup.ps1' -Parameters (Join-NetParams $base @{ Context = (New-TestContext -ItemId 'dpg-create') })
Assert-Test -Name 'DPG: rollback removes the port group on failure' -Condition ($r.Error -match 'Simulated' -and ($global:NI.Calls -match 'Remove-VDPortgroup PG-DC1-120-APP') -and -not ($global:NI.PortGroups.Name -contains 'PG-DC1-120-APP')) -Detail "$($r.Error) | $($global:NI.Calls -join ' | ')"
#endregion

#region drs-rule -----------------------------------------------------------------------------------------------
Reset-NetInventory
$drs = @{ Site = 'DC1'; Cluster = 'CL-APP-01'; RuleType = 'VmAntiAffinity'; RuleName = 'AA-APPWEB'; VMNames = "APPWEB01, APPWEB02`nAPPWEB03"; ChangeTicket = 'CHG0002' }
$r = Invoke-TestHandler -Handler 'New-VsphereDrsRule.ps1' -Parameters (Join-NetParams $drs @{ Context = (New-TestContext -ItemId 'drs-rule') })
Assert-Test -Name 'DRS: anti-affinity rule created' -Condition ($null -eq $r.Error -and $r.Result.RuleName -eq 'AA-APPWEB' -and $r.Result.VMs.Count -eq 3 -and ($global:NI.Calls -match 'New-DrsRule AA-APPWEB keep=False')) -Detail $r.Error

# Conflict: affinity rule on 2 VMs already kept apart by the rule above.
$r = Invoke-TestHandler -Handler 'New-VsphereDrsRule.ps1' -Parameters (Join-NetParams $drs @{ RuleType = 'VmAffinity'; RuleName = 'AF-WEB12'; VMNames = 'APPWEB01,APPWEB02'; Context = (New-TestContext -ItemId 'drs-rule') })
Assert-Test -Name 'DRS: conflict with opposite rule names the rule' -Condition ($r.Error -match "Conflict" -and $r.Error -match "AA-APPWEB" -and -not ($global:NI.Calls -match 'New-DrsRule AF-WEB12')) -Detail $r.Error

# Disabled opposite rule does not conflict.
$global:NI.DrsRules[0].Enabled = $false
$r = Invoke-TestHandler -Handler 'New-VsphereDrsRule.ps1' -Parameters (Join-NetParams $drs @{ RuleType = 'VmAffinity'; RuleName = 'AF-WEB12'; VMNames = 'APPWEB01,APPWEB02'; Context = (New-TestContext -ItemId 'drs-rule') })
Assert-Test -Name 'DRS: disabled opposite rule is not a conflict' -Condition ($null -eq $r.Error) -Detail $r.Error

$r = Invoke-TestHandler -Handler 'New-VsphereDrsRule.ps1' -Parameters (Join-NetParams $drs @{ RuleName = 'AA-APPWEB'; Context = (New-TestContext -ItemId 'drs-rule') })
Assert-Test -Name 'DRS: duplicate rule name rejected' -Condition ($r.Error -match "already exists") -Detail $r.Error

$r = Invoke-TestHandler -Handler 'New-VsphereDrsRule.ps1' -Parameters (Join-NetParams $drs @{ RuleName = 'AA-ONE'; VMNames = 'APPWEB01'; Context = (New-TestContext -ItemId 'drs-rule') })
Assert-Test -Name 'DRS: VM-VM rule needs 2 VMs' -Condition ($r.Error -match 'at least 2 VMs') -Detail $r.Error

$r = Invoke-TestHandler -Handler 'New-VsphereDrsRule.ps1' -Parameters (Join-NetParams $drs @{ RuleName = 'AA-MIX'; VMNames = 'APPWEB01,DBSQL01'; Context = (New-TestContext -ItemId 'drs-rule') })
Assert-Test -Name 'DRS: VM outside the cluster rejected' -Condition ($r.Error -match 'not running in cluster CL-APP-01: DBSQL01') -Detail $r.Error

$r = Invoke-TestHandler -Handler 'New-VsphereDrsRule.ps1' -Parameters (Join-NetParams $drs @{ RuleName = 'AA-GHOST'; VMNames = 'APPWEB01,GHOST99'; Context = (New-TestContext -ItemId 'drs-rule') })
Assert-Test -Name 'DRS: unknown VM rejected' -Condition ($r.Error -match 'not found: GHOST99') -Detail $r.Error

Reset-NetInventory
$global:NI.DrsGroups.Add([pscustomobject]@{ Name = 'VH-OLD-vms'; Cluster = 'CL-APP-01'; Member = [System.Collections.Generic.List[object]]@($global:NI.VMs[0]) })
$r = Invoke-TestHandler -Handler 'New-VsphereDrsRule.ps1' -Parameters (Join-NetParams $drs @{ RuleType = 'VmHostShould'; RuleName = 'VH-OLD'; VMNames = 'APPWEB01,APPOLD01'; HostNames = "esx01`nesx02.test.local"; Context = (New-TestContext -ItemId 'drs-rule') })
Assert-Test -Name 'DRS: VM-Host rule reuses VM group, creates host group' -Condition (
    $null -eq $r.Error -and $r.Result.VMGroup -eq 'VH-OLD-vms' -and $r.Result.HostGroup -eq 'VH-OLD-hosts' -and
    ($global:NI.Calls -match 'Set-DrsClusterGroup VH-OLD-vms add=APPOLD01') -and ($global:NI.Calls -match 'New-DrsClusterGroup VH-OLD-hosts') -and
    ($global:NI.Calls -match 'New-DrsVMHostRule VH-OLD ShouldRunOn') -and $r.Result.Hosts -contains 'esx01.test.local') -Detail "$($r.Error) | $($global:NI.Calls -join ' | ')"

$r = Invoke-TestHandler -Handler 'New-VsphereDrsRule.ps1' -Parameters (Join-NetParams $drs @{ RuleType = 'VmHostMust'; RuleName = 'VH-BAD'; VMNames = 'APPWEB01'; HostNames = 'esx11.test.local'; Context = (New-TestContext -ItemId 'drs-rule') })
Assert-Test -Name 'DRS: host outside the cluster rejected' -Condition ($r.Error -match 'not in cluster CL-APP-01: esx11.test.local') -Detail $r.Error

Reset-NetInventory
$global:NI.FailHostRule = $true
$r = Invoke-TestHandler -Handler 'New-VsphereDrsRule.ps1' -Parameters (Join-NetParams $drs @{ RuleType = 'VmHostMustNot'; RuleName = 'VH-RB'; VMNames = 'APPWEB01'; HostNames = 'esx03'; Context = (New-TestContext -ItemId 'drs-rule') })
Assert-Test -Name 'DRS: rollback removes groups created by the run' -Condition ($r.Error -match 'Simulated' -and $global:NI.DrsGroups.Count -eq 0 -and ($global:NI.Calls -match 'Remove-DrsClusterGroup VH-RB-hosts')) -Detail "$($r.Error) | $($global:NI.Calls -join ' | ')"
#endregion

#region vm-vmotion ---------------------------------------------------------------------------------------------
Reset-NetInventory
$mv = @{ Site = 'DC1'; VMName = 'APPWEB01'; Cluster = 'CL-DB-01'; TargetDatastore = 'DS-DB-01'; KeepPortGroups = $true; ChangeTicket = 'CHG0003' }
$r = Invoke-TestHandler -Handler 'Move-VsphereVm.ps1' -Parameters (Join-NetParams $mv @{ Context = (New-TestContext -ItemId 'vm-vmotion') })
Assert-Test -Name 'vMotion: moved to least-used host with datastore' -Condition (
    $null -eq $r.Error -and $r.Result.DestinationHost -eq 'esx12.test.local' -and $r.Result.SourceCluster -eq 'CL-APP-01' -and
    ($global:NI.Calls -match 'Move-VM APPWEB01 -> esx12.test.local ds=DS-DB-01')) -Detail "$($r.Error) | $($global:NI.Calls -join ' | ')"

$r = Invoke-TestHandler -Handler 'Move-VsphereVm.ps1' -Parameters (Join-NetParams $mv @{ Context = (New-TestContext -ItemId 'vm-vmotion') })
Assert-Test -Name 'vMotion: VM already on target cluster rejected' -Condition ($r.Error -match 'already runs on cluster CL-DB-01') -Detail $r.Error

Reset-NetInventory
$global:NI.Clusters[1].EVCMode = 'intel-sapphirerapids'
$r = Invoke-TestHandler -Handler 'Move-VsphereVm.ps1' -Parameters (Join-NetParams $mv @{ Context = (New-TestContext -ItemId 'vm-vmotion') })
Assert-Test -Name 'vMotion: EVC mismatch rejected for powered-on VM' -Condition ($r.Error -match 'EVC mismatch' -and -not ($global:NI.Calls -match 'Move-VM')) -Detail $r.Error

Reset-NetInventory
($global:NI.VMs | Where-Object Name -eq 'APPWEB01').Nets = @('PG-APP-100', 'PG-WEB-200')
$r = Invoke-TestHandler -Handler 'Move-VsphereVm.ps1' -Parameters (Join-NetParams $mv @{ Context = (New-TestContext -ItemId 'vm-vmotion') })
Assert-Test -Name 'vMotion: missing port group on target rejected' -Condition ($r.Error -match 'PG-WEB-200 on esx11.test.local') -Detail $r.Error

Reset-NetInventory
$r = Invoke-TestHandler -Handler 'Move-VsphereVm.ps1' -Parameters (Join-NetParams $mv @{ TargetDatastore = 'DS-DB-SMALL'; Context = (New-TestContext -ItemId 'vm-vmotion') })
Assert-Test -Name 'vMotion: datastore free-space floor enforced' -Condition ($r.Error -match 'free-space floor') -Detail $r.Error

Reset-NetInventory
$r = Invoke-TestHandler -Handler 'Move-VsphereVm.ps1' -Parameters (Join-NetParams $mv @{ TargetDatastore = ''; Context = (New-TestContext -ItemId 'vm-vmotion') })
Assert-Test -Name 'vMotion: non-shared current datastore requires a target datastore' -Condition ($r.Error -match 'not visible from CL-DB-01') -Detail $r.Error

Reset-NetInventory
$global:NI.Hosts | Where-Object Cluster -eq 'CL-DB-01' | ForEach-Object { $_.ConnectionState = 'Maintenance' }
$r = Invoke-TestHandler -Handler 'Move-VsphereVm.ps1' -Parameters (Join-NetParams $mv @{ Context = (New-TestContext -ItemId 'vm-vmotion') })
Assert-Test -Name 'vMotion: target without connected host rejected' -Condition ($r.Error -match 'no connected host') -Detail $r.Error

Reset-NetInventory
$global:NI.Hosts | Where-Object Cluster -eq 'CL-DB-01' | ForEach-Object { $_.MemoryTotalGB = 160 }
$r = Invoke-TestHandler -Handler 'Move-VsphereVm.ps1' -Parameters (Join-NetParams $mv @{ Context = (New-TestContext -ItemId 'vm-vmotion') })
Assert-Test -Name 'vMotion: memory headroom > 90% is a warning' -Condition ($null -eq $r.Error -and ($r.Log -match '\[WARN\].*memory allocation')) -Detail $r.Error
#endregion

#region host-maintenance ---------------------------------------------------------------------------------------
Reset-NetInventory
$hm = @{ Site = 'DC1'; Cluster = 'CL-APP-01'; HostName = 'esx01.test.local'; Action = 'Enter'; EvacuatePoweredOff = $true; Reason = 'Firmware upgrade'; ChangeTicket = 'CHG0004' }
$ctx = New-TestContext -ItemId 'host-maintenance'
$auditPath = Join-Path $global:SspHandlerTestRoot 'logs/audit.jsonl'
$r = Invoke-TestHandler -Handler 'Set-VsphereHostMaintenance.ps1' -Parameters (Join-NetParams $hm @{ Context = $ctx })
$audit = @(if (Test-Path $auditPath) { Get-Content $auditPath | Where-Object { $_ -match '"host.maintenance"' -and $_ -match $ctx.RequestId } })
Assert-Test -Name 'Maintenance: enter with evacuation' -Condition (
    $null -eq $r.Error -and ($global:NI.Calls -match 'Set-VMHost esx01.test.local state=Maintenance evacuate=True') -and
    $r.Result.VMsBefore -contains 'APPWEB01 (PoweredOn)' -and $r.Result.AuthorizedBy -eq 'jdoe' -and $r.Result.AuthorizedFrom -eq '10.1.1.10') -Detail "$($r.Error) | $($global:NI.Calls -join ' | ')"
Assert-Test -Name 'Maintenance: audit entry written with reason' -Condition ($audit.Count -eq 1 -and $audit[0] -match 'Firmware upgrade') -Detail "audit lines: $($audit.Count)"

$r = Invoke-TestHandler -Handler 'Set-VsphereHostMaintenance.ps1' -Parameters (Join-NetParams $hm @{ Action = 'Exit'; Context = (New-TestContext -ItemId 'host-maintenance') })
Assert-Test -Name 'Maintenance: exit' -Condition ($null -eq $r.Error -and ($global:NI.Calls -match 'Set-VMHost esx01.test.local state=Connected')) -Detail $r.Error

Reset-NetInventory
$global:NI.Hosts | Where-Object Cluster -eq 'CL-APP-01' | ForEach-Object { $_.MemoryTotalGB = 100 }
$r = Invoke-TestHandler -Handler 'Set-VsphereHostMaintenance.ps1' -Parameters (Join-NetParams $hm @{ Context = (New-TestContext -ItemId 'host-maintenance') })
Assert-Test -Name 'Maintenance: N+1 failure blocks the change' -Condition ($r.Error -match 'N\+1 check failed' -and -not ($global:NI.Calls -match 'Set-VMHost')) -Detail $r.Error

Reset-NetInventory
$global:NI.Clusters[0].DrsAutomationLevel = 'PartiallyAutomated'
$r = Invoke-TestHandler -Handler 'Set-VsphereHostMaintenance.ps1' -Parameters (Join-NetParams $hm @{ Context = (New-TestContext -ItemId 'host-maintenance') })
Assert-Test -Name 'Maintenance: DRS must be fully automated' -Condition ($r.Error -match 'DRS must be fully automated to evacuate') -Detail $r.Error

Reset-NetInventory
$global:NI.Hosts | Where-Object { $_.Cluster -eq 'CL-APP-01' -and $_.Name -ne 'esx01.test.local' } | ForEach-Object { $_.ConnectionState = 'Maintenance' }
$r = Invoke-TestHandler -Handler 'Set-VsphereHostMaintenance.ps1' -Parameters (Join-NetParams $hm @{ Context = (New-TestContext -ItemId 'host-maintenance') })
Assert-Test -Name 'Maintenance: last connected host cannot enter' -Condition ($r.Error -match 'no other connected host') -Detail $r.Error

Reset-NetInventory
$r = Invoke-TestHandler -Handler 'Set-VsphereHostMaintenance.ps1' -Parameters (Join-NetParams $hm @{ HostName = 'esx11.test.local'; Context = (New-TestContext -ItemId 'host-maintenance') })
Assert-Test -Name 'Maintenance: host outside the cluster rejected' -Condition ($r.Error -match 'not a member of cluster CL-APP-01') -Detail $r.Error
#endregion

# Remove the stubs at the end so other groups start clean.
'Reset-NetInventory', 'Join-NetParams', 'Get-VDSwitch', 'Get-VDPortgroup', 'New-VDPortgroup', 'Remove-VDPortgroup', 'Get-VDUplinkTeamingPolicy', 'Set-VDUplinkTeamingPolicy',
'Get-VDSecurityPolicy', 'Set-VDSecurityPolicy', 'Get-Cluster', 'Get-VMHost', 'Get-VM', 'Get-DrsRule', 'Get-DrsVMHostRule', 'New-DrsRule',
'Get-DrsClusterGroup', 'New-DrsClusterGroup', 'Set-DrsClusterGroup', 'Remove-DrsClusterGroup', 'New-DrsVMHostRule', 'Get-NetworkAdapter',
'Get-VirtualPortGroup', 'Get-Datastore', 'Move-VM', 'Set-VMHost' | ForEach-Object { Remove-Item "function:global:$_" -ErrorAction SilentlyContinue }
Remove-Variable -Name NI -Scope Global -ErrorAction SilentlyContinue
