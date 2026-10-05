#Requires -Version 7.2
<#
.SYNOPSIS
    Offline tests - group "Backup, cloud, storage and blueprint":
    Set-PortalBackupPolicy, Get-CloudCostReport, Invoke-CloudPowerAction, New-VsphereDatastore, New-VsphereThreeTierApp.
#>
. (Join-Path $PSScriptRoot '_TestHelpers.ps1')
Start-TestGroup 'Backup, cloud, storage and blueprint (Platform)'

$stubNames = [System.Collections.Generic.List[string]]::new()
function New-Stub {
    <# Defines a global stub function (CmdletBinding + ShouldProcess so -ErrorAction / -Confirm are accepted). #>
    param([string] $Name, [string] $Body)
    Set-Item -Path "function:global:$Name" -Value ([scriptblock]::Create("[CmdletBinding(SupportsShouldProcess)] $Body"))
    if (-not $stubNames.Contains($Name)) { $stubNames.Add($Name) }
}
function Test-Has { param($List, [string] $Pattern) [bool](@($List) | Where-Object { $_ -match $Pattern }) }

#region ===== Backup policy ======================================================================================
$global:BkVMs = @{}
$global:BkCategories = @{}
$global:BkTags = @{}
$global:BkAssign = [System.Collections.Generic.List[object]]::new()
$global:BkCalls = [System.Collections.Generic.List[string]]::new()
function Reset-Backup {
    $global:BkVMs = @{ APP01 = [pscustomobject]@{ Name = 'APP01' }; APP02 = [pscustomobject]@{ Name = 'APP02' }; APP03 = [pscustomobject]@{ Name = 'APP03' } }
    $global:BkCategories = @{}; $global:BkTags = @{}; $global:BkAssign.Clear(); $global:BkCalls.Clear()
}
New-Stub Get-VM 'param($Name, $Server, $Id, $Location, [Parameter(ValueFromRemainingArguments)] $Rest) if ($global:BkVMs.ContainsKey([string]$Name)) { $global:BkVMs[[string]$Name] }'
New-Stub Get-TagCategory 'param($Name, $Server) if ($global:BkCategories.ContainsKey($Name)) { $global:BkCategories[$Name] }'
New-Stub New-TagCategory 'param($Name, $Cardinality, $EntityType, $Description, $Server) $global:BkCalls.Add("New-TagCategory:${Name}:${Cardinality}:$EntityType"); $c = [pscustomobject]@{ Name = $Name; Cardinality = $Cardinality }; $global:BkCategories[$Name] = $c; $c'
New-Stub Get-Tag 'param($Name, $Category, $Server) $k = "$($Category.Name)/$Name"; if ($global:BkTags.ContainsKey($k)) { $global:BkTags[$k] }'
New-Stub New-Tag 'param($Name, $Category, $Description, $Server) $global:BkCalls.Add("New-Tag:$Name"); $t = [pscustomobject]@{ Name = $Name; Category = $Category }; $global:BkTags["$($Category.Name)/$Name"] = $t; $t'
New-Stub Get-TagAssignment 'param($Entity, $Category, $Server) @($global:BkAssign | Where-Object { $_.Entity.Name -eq $Entity.Name -and $_.Tag.Category.Name -eq $Category.Name })'
New-Stub Remove-TagAssignment 'param($TagAssignment) $global:BkCalls.Add("Remove-TagAssignment:$($TagAssignment.Entity.Name):$($TagAssignment.Tag.Name)"); $null = $global:BkAssign.Remove($TagAssignment)'
New-Stub New-TagAssignment 'param($Tag, $Entity, $Server) $global:BkCalls.Add("New-TagAssignment:$($Entity.Name):$($Tag.Name)"); $a = [pscustomobject]@{ Tag = $Tag; Entity = $Entity }; $global:BkAssign.Add($a); $a'
function Set-BkAssignment { param([string] $Vm, [string] $Policy)
    $cat = $global:BkCategories['Backup-Policy']; if (-not $cat) { $cat = [pscustomobject]@{ Name = 'Backup-Policy'; Cardinality = 'Single' }; $global:BkCategories['Backup-Policy'] = $cat }
    $t = $global:BkTags["Backup-Policy/$Policy"]; if (-not $t) { $t = [pscustomobject]@{ Name = $Policy; Category = $cat }; $global:BkTags["Backup-Policy/$Policy"] = $t }
    $global:BkAssign.Add([pscustomobject]@{ Tag = $t; Entity = $global:BkVMs[$Vm] })
}

Reset-Backup
$ctx = New-TestContext -ItemId 'backup-policy'
$r = Invoke-TestHandler -Handler 'Set-PortalBackupPolicy.ps1' -Parameters @{ Site = 'DC1'; VMName = 'APP01'; Policy = 'Gold'; ChangeTicket = 'CHG1'; Context = $ctx }
Assert-Test -Name 'Backup: new VM gets Gold' -Condition ($null -eq $r.Error -and $r.Result.NewPolicy -eq 'Gold' -and $r.Result.Connector -eq 'vsphereTag' -and $r.Result.Changed -eq 1) -Detail $r.Error
Assert-Test -Name 'Backup: category created Single / VirtualMachine' -Condition (Test-Has $global:BkCalls '^New-TagCategory:Backup-Policy:Single:VirtualMachine$')
Assert-Test -Name 'Backup: tag created + assigned' -Condition ((Test-Has $global:BkCalls '^New-Tag:Gold$') -and (Test-Has $global:BkCalls '^New-TagAssignment:APP01:Gold$'))
Assert-Test -Name 'Backup: NextSteps name the tag' -Condition ((@($r.Result.NextSteps) -join ' ') -match 'Backup products select VMs by the tag Backup-Policy/Gold')

Reset-Backup; Set-BkAssignment -Vm APP01 -Policy Silver
$r = Invoke-TestHandler -Handler 'Set-PortalBackupPolicy.ps1' -Parameters @{ Site = 'DC1'; VMName = 'APP01'; Policy = 'Gold'; Context = $ctx }
Assert-Test -Name 'Backup: Silver replaced by Gold' -Condition ($null -eq $r.Error -and (@($r.Result.PreviousPolicy) -contains 'APP01=Silver') -and (Test-Has $global:BkCalls 'Remove-TagAssignment:APP01:Silver') -and @($global:BkAssign).Count -eq 1 -and $global:BkAssign[0].Tag.Name -eq 'Gold') -Detail $r.Error
Assert-Test -Name 'Backup: existing category not recreated' -Condition (-not (Test-Has $global:BkCalls '^New-TagCategory'))

$global:BkCalls.Clear()
$r = Invoke-TestHandler -Handler 'Set-PortalBackupPolicy.ps1' -Parameters @{ Site = 'DC1'; VMName = 'APP01'; Policy = 'Gold'; Context = $ctx }
Assert-Test -Name 'Backup: idempotent re-run changes nothing' -Condition ($null -eq $r.Error -and $r.Result.Changed -eq 0 -and -not (Test-Has $global:BkCalls 'Assignment')) -Detail $r.Error

$r = Invoke-TestHandler -Handler 'Set-PortalBackupPolicy.ps1' -Parameters @{ Site = 'DC1'; VMName = "APP01`nAPP02, APP03"; Policy = 'None'; Context = $ctx }
Assert-Test -Name 'Backup: None removes the policy (list of VMs)' -Condition ($null -eq $r.Error -and $r.Result.NewPolicy -eq 'None' -and @($r.Result.VMs).Count -eq 3 -and @($global:BkAssign).Count -eq 0 -and $r.Result.Changed -eq 1) -Detail $r.Error

$r = Invoke-TestHandler -Handler 'Set-PortalBackupPolicy.ps1' -Parameters @{ Site = 'DC1'; VMName = 'APP01'; Policy = 'Platinum'; Context = $ctx }
Assert-Test -Name 'Backup: unknown policy fails' -Condition ($r.Error -match "Backup policy 'Platinum' is not defined") -Detail $r.Error

$r = Invoke-TestHandler -Handler 'Set-PortalBackupPolicy.ps1' -Parameters @{ Site = 'DC1'; VMName = 'NOPE01'; Policy = 'Gold'; Context = $ctx }
Assert-Test -Name 'Backup: missing VM fails' -Condition ($r.Error -match "VM 'NOPE01' was not found") -Detail $r.Error

$bkPath = Join-Path $global:SspHandlerTestRoot 'config/backup.json'
$bkOrig = Get-Content -LiteralPath $bkPath -Raw
try {
    $j = $bkOrig | ConvertFrom-Json -AsHashtable; $j.connector = 'veeam'
    $j | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $bkPath -Encoding utf8NoBOM
    $global:BkCalls.Clear()
    $r = Invoke-TestHandler -Handler 'Set-PortalBackupPolicy.ps1' -Parameters @{ Site = 'DC1'; VMName = 'APP01'; Policy = 'Gold'; Context = $ctx }
    Assert-Test -Name 'Backup: inactive connector fails' -Condition ($r.Error -match "connector 'veeam' is not active" -and -not $global:BkCalls.Count) -Detail $r.Error
}
finally { Set-Content -LiteralPath $bkPath -Value $bkOrig -NoNewline -Encoding utf8NoBOM }
#endregion

#region ===== Cloud cost report ==================================================================================
$now = Get-Date
$awsCloud = [pscustomobject]@{ Provider = 'aws'; Region = 'us-east-1'; Credential = $null; Settings = @{} }
function New-AwsTag { param([string] $K, [string] $V) [pscustomobject]@{ Key = $K; Value = $V } }
$global:AwsInstances = @(
    [pscustomobject]@{ InstanceId = 'i-stopped-old'; InstanceType = 't3.large'; State = [pscustomobject]@{ Name = 'stopped' }
                       StateTransitionReason = ('User initiated ({0:yyyy-MM-dd HH:mm:ss} GMT)' -f $now.ToUniversalTime().AddDays(-30))
                       BlockDeviceMappings = @([pscustomobject]@{ Ebs = [pscustomobject]@{ VolumeId = 'vol-root1' } }); Tags = @((New-AwsTag Name 'old-box')) }
    [pscustomobject]@{ InstanceId = 'i-stopped-new'; InstanceType = 't3.large'; State = [pscustomobject]@{ Name = 'stopped' }
                       StateTransitionReason = ('User initiated ({0:yyyy-MM-dd HH:mm:ss} GMT)' -f $now.ToUniversalTime().AddDays(-2))
                       BlockDeviceMappings = @(); Tags = @((New-AwsTag Name 'recent'), (New-AwsTag PowerSchedule 'office-hours')) }
    [pscustomobject]@{ InstanceId = 'i-running'; InstanceType = 'm5.xlarge'; State = [pscustomobject]@{ Name = 'running' }; StateTransitionReason = ''
                       BlockDeviceMappings = @(); Tags = @((New-AwsTag Name 'web'), (New-AwsTag PowerSchedule 'office-hours')) }
    [pscustomobject]@{ InstanceId = 'i-other-tag'; InstanceType = 'm5.xlarge'; State = [pscustomobject]@{ Name = 'running' }; StateTransitionReason = ''
                       BlockDeviceMappings = @(); Tags = @((New-AwsTag Name 'prod-db'), (New-AwsTag PowerSchedule '24x7')) }
)
New-Stub Get-EC2Volume 'param($Region, $Credential, $Filter) @(
    [pscustomobject]@{ VolumeId = "vol-free1"; Size = 100; VolumeType = "gp3"; State = "available"; CreateTime = (Get-Date).AddDays(-40); Tags = @() }
    [pscustomobject]@{ VolumeId = "vol-root1"; Size = 50;  VolumeType = "gp2"; State = "in-use";    CreateTime = (Get-Date).AddDays(-400); Tags = @() })'
New-Stub Get-EC2Address 'param($Region, $Credential) @(
    [pscustomobject]@{ PublicIp = "3.3.3.3"; AllocationId = "eipalloc-1"; AssociationId = $null; Tags = @() }
    [pscustomobject]@{ PublicIp = "4.4.4.4"; AllocationId = "eipalloc-2"; AssociationId = "eipassoc-2"; Tags = @() })'
New-Stub Get-EC2Instance 'param($Region, $Credential, $Filter, $InstanceId) $global:Ec2Filter = $Filter; [pscustomobject]@{ Instances = $global:AwsInstances }'
New-Stub Get-EC2Snapshot 'param($OwnerId, $Region, $Credential) if ($OwnerId -ne "self") { throw "OwnerId self expected" }; @(
    [pscustomobject]@{ SnapshotId = "snap-old"; VolumeId = "vol-x"; VolumeSize = 200; StartTime = (Get-Date).AddDays(-400); Description = "old" }
    [pscustomobject]@{ SnapshotId = "snap-new"; VolumeId = "vol-y"; VolumeSize = 200; StartTime = (Get-Date).AddDays(-10); Description = "new" })'

$ctx = New-TestContext -ItemId 'cloud-cost-report-aws' -Cloud $awsCloud -NoVCenter
$r = Invoke-TestHandler -Handler 'Get-CloudCostReport.ps1' -Parameters @{ StoppedDaysThreshold = 7; Context = $ctx }
# 100 GB gp3 (8.00) + 1 EIP (3.65) + 50 GB gp2 of the long-stopped instance (5.00) + 200 GB old snapshot (10.00) = 26.65
Assert-Test -Name 'Cost AWS: findings counted' -Condition ($null -eq $r.Error -and $r.Result.Unattachedvolumes -eq 1 -and $r.Result.UnusedElasticIPs -eq 1 -and $r.Result.Longstoppedinstances -eq 1 -and $r.Result.Oldsnapshots -eq 1) -Detail ($r.Error + ($r.Result | ConvertTo-Json -Compress))
Assert-Test -Name 'Cost AWS: monthly estimate' -Condition ([math]::Abs([double]$r.Result.EstimatedMonthlyWasteUSD - 26.65) -lt 0.01) -Detail "$($r.Result.EstimatedMonthlyWasteUSD)"
Assert-Test -Name 'Cost AWS: power schedule tagged count' -Condition ($r.Result.PowerScheduleTagged -eq 3) -Detail "$($r.Result.PowerScheduleTagged)"
$files = Get-TestReportFiles -Context $ctx
Assert-Test -Name 'Cost AWS: HTML + CSV report' -Condition (($files -contains 'cloud-cost-aws.html') -and @($files | Where-Object { $_ -like '*.csv' }).Count -ge 5) -Detail ($files -join ', ')
$html = Get-Content -Raw (Join-Path $ctx.ReportDir 'cloud-cost-aws.html')
Assert-Test -Name 'Cost AWS: Power schedules section present' -Condition ($html -match 'Power schedules' -and $html -match 'list price')

$azCloud = [pscustomobject]@{ Provider = 'azure'; Location = 'eastus'; SubscriptionId = 'sub-1'; Settings = @{} }
$global:AzVms = @(
    [pscustomobject]@{ Name = 'vm-run'; ResourceGroupName = 'rg1'; PowerState = 'VM running'; HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D2s_v5' }; Tags = @{ PowerSchedule = 'office-hours' } }
    [pscustomobject]@{ Name = 'vm-stopped'; ResourceGroupName = 'rg1'; PowerState = 'VM stopped'; HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D4s_v5' }; Tags = @{ PowerSchedule = 'office-hours' } }
    [pscustomobject]@{ Name = 'vm-dealloc-old'; ResourceGroupName = 'rg2'; PowerState = 'VM deallocated'; HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D2s_v5' }; Tags = @{ PowerSchedule = 'office-hours' } }
    [pscustomobject]@{ Name = 'vm-dealloc-new'; ResourceGroupName = 'rg2'; PowerState = 'VM deallocated'; HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D2s_v5' }; Tags = @{} }
    [pscustomobject]@{ Name = 'vm-prod'; ResourceGroupName = 'rg3'; PowerState = 'VM running'; HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_E8s_v5' }; Tags = $null }
)
New-Stub Get-AzDisk 'param($ResourceGroupName) @(
    [pscustomobject]@{ Name = "disk-free"; ResourceGroupName = "rg1"; DiskState = "Unattached"; DiskSizeGB = 128; Sku = [pscustomobject]@{ Name = "Premium_LRS" }; TimeCreated = (Get-Date).AddDays(-60) }
    [pscustomobject]@{ Name = "disk-used"; ResourceGroupName = "rg1"; DiskState = "Attached"; DiskSizeGB = 128; Sku = [pscustomobject]@{ Name = "Premium_LRS" }; TimeCreated = (Get-Date).AddDays(-60) })'
New-Stub Get-AzPublicIpAddress 'param($ResourceGroupName) @(
    [pscustomobject]@{ Name = "pip-free"; ResourceGroupName = "rg1"; IpAddress = "20.1.1.1"; Sku = [pscustomobject]@{ Name = "Standard" }; IpConfiguration = $null }
    [pscustomobject]@{ Name = "pip-used"; ResourceGroupName = "rg1"; IpAddress = "20.1.1.2"; Sku = [pscustomobject]@{ Name = "Standard" }; IpConfiguration = [pscustomobject]@{ Id = "x" } })'
New-Stub Get-AzVM 'param($ResourceGroupName, $Name, [switch] $Status)
    if ($Name) {
        $days = if ($Name -eq "vm-dealloc-old") { 30 } else { 1 }
        return [pscustomobject]@{ Name = $Name; Statuses = @([pscustomobject]@{ Code = "ProvisioningState/succeeded"; Time = (Get-Date).AddDays(-$days) }, [pscustomobject]@{ Code = "PowerState/deallocated"; Time = $null }) }
    }
    $global:AzVms'
New-Stub Get-AzSnapshot 'param($ResourceGroupName) @(
    [pscustomobject]@{ Name = "snap-old"; ResourceGroupName = "rg1"; DiskSizeGB = 100; TimeCreated = (Get-Date).AddDays(-200) })'

$ctx = New-TestContext -ItemId 'cloud-cost-report-azure' -Cloud $azCloud -NoVCenter
$r = Invoke-TestHandler -Handler 'Get-CloudCostReport.ps1' -Parameters @{ StoppedDaysThreshold = 7; Context = $ctx }
# 128 GB Premium_LRS (19.20) + public IP (3.65) + 100 GB snapshot (5.00) = 27.85
Assert-Test -Name 'Cost Azure: findings counted' -Condition ($null -eq $r.Error -and $r.Result.Unattacheddisks -eq 1 -and $r.Result.UnusedpublicIPs -eq 1 -and $r.Result.Stoppednotdeallocated -eq 1) -Detail $r.Error
Assert-Test -Name 'Cost Azure: long-deallocated uses threshold' -Condition ($r.Result.LongdeallocatedVMs -eq 1 -and $r.Result.Oldsnapshots -eq 1) -Detail ($r.Result | ConvertTo-Json -Compress)
Assert-Test -Name 'Cost Azure: monthly estimate' -Condition ([math]::Abs([double]$r.Result.EstimatedMonthlyWasteUSD - 27.85) -lt 0.01) -Detail "$($r.Result.EstimatedMonthlyWasteUSD)"
$html = Get-Content -Raw (Join-Path $ctx.ReportDir 'cloud-cost-azure.html')
Assert-Test -Name 'Cost Azure: stopped-not-deallocated flagged CRITICAL' -Condition ($html -match 'vm-stopped' -and $html -match 's-fail">CRITICAL')

$r = Invoke-TestHandler -Handler 'Get-CloudCostReport.ps1' -Parameters @{ StoppedDaysThreshold = 7; Context = (New-TestContext -ItemId 'cloud-cost-report-aws' -NoVCenter) }
Assert-Test -Name 'Cost: no cloud connection fails' -Condition ($r.Error -match 'needs a cloud connection') -Detail $r.Error
#endregion

#region ===== Cloud power action ==================================================================================
$global:PowerCalls = [System.Collections.Generic.List[string]]::new()
New-Stub Start-EC2Instance 'param($InstanceId, $Region, $Credential) $global:PowerCalls.Add("start:$InstanceId")'
New-Stub Stop-EC2Instance 'param($InstanceId, $Region, $Credential) $global:PowerCalls.Add("stop:$InstanceId")'
New-Stub Start-AzVM 'param($ResourceGroupName, $Name, [switch] $NoWait) $global:PowerCalls.Add("start:$Name")'
New-Stub Stop-AzVM 'param($ResourceGroupName, $Name, [switch] $Force, [switch] $NoWait, [switch] $StayProvisioned) if (-not $Force) { throw "Force expected" }; if ($StayProvisioned) { throw "must deallocate" }; $global:PowerCalls.Add("stop:$Name")'

$ctx = New-TestContext -ItemId 'cloud-power-action-aws' -Cloud $awsCloud -NoVCenter
$global:PowerCalls.Clear()
$r = Invoke-TestHandler -Handler 'Invoke-CloudPowerAction.ps1' -Parameters @{ Action = 'Stop'; TagValue = 'office-hours'; DryRun = $true; Context = $ctx }
Assert-Test -Name 'Power AWS: dry run changes nothing' -Condition ($null -eq $r.Error -and $global:PowerCalls.Count -eq 0 -and $r.Result.WouldChange -eq 1 -and $r.Result.DryRun -eq $true) -Detail ($r.Error + ($r.Result | ConvertTo-Json -Compress))
Assert-Test -Name 'Power AWS: provider filter on the tag' -Condition ((@($global:Ec2Filter | Where-Object { $_.Name -eq 'tag:PowerSchedule' }).Values -contains 'office-hours'))
Assert-Test -Name 'Power AWS: report written' -Condition ((Get-TestReportFiles -Context $ctx) -contains 'cloud-power-stop.html')

$r = Invoke-TestHandler -Handler 'Invoke-CloudPowerAction.ps1' -Parameters @{ Action = 'Stop'; TagValue = 'office-hours'; DryRun = $false; ChangeTicket = 'CHG9'; Context = $ctx }
Assert-Test -Name 'Power AWS: stops only running tagged instances' -Condition ($null -eq $r.Error -and ($global:PowerCalls -join ',') -eq 'stop:i-running' -and $r.Result.Changed -eq 1 -and $r.Result.Skipped -eq 1) -Detail ($r.Error + ' ' + ($global:PowerCalls -join ','))
Assert-Test -Name 'Power AWS: never touches other tag values' -Condition (-not (Test-Has $global:PowerCalls 'i-other-tag|i-stopped-old'))

$global:PowerCalls.Clear()
$r = Invoke-TestHandler -Handler 'Invoke-CloudPowerAction.ps1' -Parameters @{ Action = 'Start'; TagValue = 'office-hours'; DryRun = $false; Context = $ctx }
Assert-Test -Name 'Power AWS: start stopped tagged instance' -Condition ($null -eq $r.Error -and ($global:PowerCalls -join ',') -eq 'start:i-stopped-new') -Detail ($global:PowerCalls -join ',')

$r = Invoke-TestHandler -Handler 'Invoke-CloudPowerAction.ps1' -Parameters @{ Action = 'Stop'; TagValue = 'bad;value'; Context = $ctx }
Assert-Test -Name 'Power: invalid tag value fails' -Condition ($r.Error -match 'is not valid') -Detail $r.Error

$ctx = New-TestContext -ItemId 'cloud-power-action-azure' -Cloud $azCloud -NoVCenter
$global:PowerCalls.Clear()
$r = Invoke-TestHandler -Handler 'Invoke-CloudPowerAction.ps1' -Parameters @{ Action = 'Stop'; TagValue = 'office-hours'; Context = $ctx }
Assert-Test -Name 'Power Azure: default is dry run' -Condition ($null -eq $r.Error -and $global:PowerCalls.Count -eq 0 -and $r.Result.WouldChange -eq 2) -Detail ($r.Error + ($r.Result | ConvertTo-Json -Compress))
$r = Invoke-TestHandler -Handler 'Invoke-CloudPowerAction.ps1' -Parameters @{ Action = 'Stop'; TagValue = 'office-hours'; DryRun = $false; Context = $ctx }
Assert-Test -Name "Power Azure: deallocates running and 'VM stopped' only" -Condition ($null -eq $r.Error -and (($global:PowerCalls | Sort-Object) -join ',') -eq 'stop:vm-run,stop:vm-stopped') -Detail ($r.Error + ' ' + ($global:PowerCalls -join ','))
Assert-Test -Name 'Power Azure: untagged VMs untouched' -Condition (-not (Test-Has $global:PowerCalls 'vm-prod|vm-dealloc-new'))

New-Stub Stop-AzVM 'param($ResourceGroupName, $Name, [switch] $Force, [switch] $NoWait) throw "AuthorizationFailed"'
$r = Invoke-TestHandler -Handler 'Invoke-CloudPowerAction.ps1' -Parameters @{ Action = 'Stop'; TagValue = 'office-hours'; DryRun = $false; Context = $ctx }
Assert-Test -Name 'Power Azure: failures reported' -Condition ($r.Error -match '2 of 3 stop action\(s\) failed') -Detail $r.Error
#endregion

#region ===== Datastore create ===================================================================================
$global:DsHosts = @()
$global:DsMounts = @{}
$global:DsExisting = @()
$global:DsCalls = [System.Collections.Generic.List[string]]::new()
$global:DsLunHidden = @()
$global:DsPods = @{}
$global:DsMountFailOn = $null
$global:NfsReachable = $true
function Reset-Ds {
    $global:DsHosts = @('esx01', 'esx02', 'esx03') | ForEach-Object {
        [pscustomobject]@{ Name = $_; ConnectionState = 'Connected'; ExtensionData = [pscustomobject]@{ ConfigManager = [pscustomobject]@{ DatastoreSystem = "dss-$_" } } }
    }
    $global:DsMounts = @{ esx01 = @(); esx02 = @(); esx03 = @() }
    $global:DsExisting = @([pscustomobject]@{ Name = 'DS-OLD-01'; Type = 'VMFS'; CapacityGB = 1000 })
    $global:DsCalls.Clear(); $global:DsLunHidden = @(); $global:DsMountFailOn = $null; $global:NfsReachable = $true
    $global:DsPods = @{ 'POD-NFS' = @([pscustomobject]@{ Name = 'NFS-A'; Type = 'NFS' }); 'POD-VMFS' = @([pscustomobject]@{ Name = 'VMFS-A'; Type = 'VMFS' }) }
}
New-Stub Get-Cluster 'param($Name, $Server) [pscustomobject]@{ Name = $Name }'
New-Stub Get-VMHost 'param($Location, $Server) $global:DsHosts'
New-Stub Get-Datastore 'param($Name, $VMHost, $Location, $Server)
    if ($VMHost) { return @($global:DsMounts[$VMHost.Name] | ForEach-Object { [pscustomobject]@{ Name = $_; Accessible = $true } }) }
    if ($Location) { return @($global:DsPods[$Location.Name]) }
    @($global:DsExisting | Where-Object { $_.Name -eq $Name })'
New-Stub Get-ScsiLun 'param($VmHost, $CanonicalName, $Server, $LunType) if ($global:DsLunHidden -notcontains $VmHost.Name) { [pscustomobject]@{ CanonicalName = $CanonicalName } }'
New-Stub Get-View 'param($Id, $Server)
    $o = [pscustomobject]@{ Id = $Id }
    $o | Add-Member -MemberType ScriptMethod -Name QueryAvailableDisksForVmfs -Value { param($x) @([pscustomobject]@{ CanonicalName = "naa.600a0001"; Capacity = [pscustomobject]@{ BlockSize = 512; Block = 2147483648 } }) }
    $o'
New-Stub Get-VMHostStorage 'param($VMHost, [switch] $RescanAllHba, [switch] $RescanVmfs, $Server)
    $global:DsCalls.Add("rescan:$($VMHost.Name):hba=$([bool]$RescanAllHba)")
    if ($global:DsCreatedVmfs -and $global:DsMountFailOn -ne $VMHost.Name -and $global:DsMounts[$VMHost.Name] -notcontains $global:DsCreatedVmfs) { $global:DsMounts[$VMHost.Name] += $global:DsCreatedVmfs }'
New-Stub New-Datastore 'param([switch] $Vmfs, [switch] $Nfs, $VMHost, $Name, $Path, $NfsHost, $FileSystemVersion, $Server)
    $kind = if ($Vmfs) { "vmfs" } else { "nfs" }
    $global:DsCalls.Add("new:${kind}:$($VMHost.Name):${Name}:${Path}:${NfsHost}:$FileSystemVersion")
    if ($global:DsMountFailOn -ne $VMHost.Name) { $global:DsMounts[$VMHost.Name] += $Name }
    if ($Vmfs) { $global:DsCreatedVmfs = $Name }
    $d = [pscustomobject]@{ Name = $Name; Type = $(if ($Vmfs) { "VMFS" } else { "NFS" }); CapacityGB = 1024 }
    if (-not ($global:DsExisting | Where-Object { $_.Name -eq $Name })) { $global:DsExisting += $d }; $d'
New-Stub Get-DatastoreCluster 'param($Name, $Server) if ($global:DsPods.ContainsKey($Name)) { [pscustomobject]@{ Name = $Name } }'
New-Stub New-DatastoreCluster 'param($Name, $Location, $Server) $global:DsCalls.Add("newpod:${Name}:$($Location.Name)"); $global:DsPods[$Name] = @(); [pscustomobject]@{ Name = $Name }'
New-Stub Set-DatastoreCluster 'param($DatastoreCluster, $SdrsAutomationLevel) $global:DsCalls.Add("setpod:$($DatastoreCluster.Name):$SdrsAutomationLevel"); $DatastoreCluster'
New-Stub Move-Datastore 'param($Datastore, $Destination) $global:DsCalls.Add("move:$($Datastore.Name):$($Destination.Name)")'
New-Stub Get-Datacenter 'param($Cluster, $Server, $Name) [pscustomobject]@{ Name = "DC1-Datacenter" }'
New-Stub Get-Tag 'param($Name, $Category, $Server) $null'
New-Stub Remove-Datastore 'param($Datastore, $VMHost, $Server) $global:DsCalls.Add("remove:${Datastore}:$($VMHost.Name)")'
New-Stub Remove-DatastoreCluster 'param($DatastoreCluster, $Server) $global:DsCalls.Add("removepod:$($DatastoreCluster.Name)")'
New-Stub Test-PortalTcpPort 'param($ComputerName, $Port, $TimeoutMs) $global:DsCalls.Add("probe:${ComputerName}:$Port"); $global:NfsReachable'

function Get-DsLock { $s = Get-PortalStorageState -Site DC1 -Cluster CL-APP-01; [pscustomobject]@{ Active = (Test-PortalStorageLockActive -State $s); By = $(if ($s.Contains('lock') -and $s.lock) { $s.lock.by }); LastRescanBy = $(if ($s.Contains('lastRescanBy')) { $s.lastRescanBy }) } }
$vmfsParams = { param($c) @{ Site = 'DC1'; Cluster = 'CL-APP-01'; DatastoreType = 'VMFS'; Lun = 'naa.600a0001'; DatastoreName = 'DS-APP-02'; ChangeTicket = 'CHG7'; Context = $c } }

Reset-Ds; $global:DsCreatedVmfs = $null
$ctx = New-TestContext -ItemId 'datastore-create'
$r = Invoke-TestHandler -Handler 'New-VsphereDatastore.ps1' -Parameters (& $vmfsParams $ctx)
Assert-Test -Name 'Datastore VMFS: created' -Condition ($null -eq $r.Error -and $r.Result.Datastore -eq 'DS-APP-02' -and $r.Result.Type -eq 'VMFS 6' -and $r.Result.Hosts -eq 3) -Detail ($r.Error + ' ' + ($r.Log -join ' | '))
Assert-Test -Name 'Datastore VMFS: one New-Datastore on first host, VMFS 6' -Condition (@($global:DsCalls | Where-Object { $_ -like 'new:*' }).Count -eq 1 -and (Test-Has $global:DsCalls '^new:vmfs:esx01:DS-APP-02:naa.600a0001::6$')) -Detail ($global:DsCalls -join ', ')
Assert-Test -Name 'Datastore VMFS: HBA rescan on all hosts + VMFS rescan on the others' -Condition (@($global:DsCalls | Where-Object { $_ -like 'rescan:*hba=True' }).Count -eq 3 -and @($global:DsCalls | Where-Object { $_ -like 'rescan:*hba=False' }).Count -eq 2)
Assert-Test -Name 'Datastore VMFS: authorization evidence' -Condition ($r.Result.AuthorizedBy -eq 'jdoe' -and $r.Result.AuthorizedFrom -eq '10.1.1.10' -and $r.Result.AuthorizedAt -and $r.Result.ApprovedBy -eq 'approver1')
$lk = Get-DsLock
Assert-Test -Name 'Datastore: lock released after success (rescan recorded)' -Condition (-not $lk.Active -and $lk.LastRescanBy -match '^jdoe \(REQ-') -Detail "$($lk | ConvertTo-Json -Compress)"

Reset-Ds; $global:DsCreatedVmfs = $null; $global:DsLunHidden = @('esx03')
$r = Invoke-TestHandler -Handler 'New-VsphereDatastore.ps1' -Parameters (& $vmfsParams $ctx)
Assert-Test -Name 'Datastore VMFS: LUN not visible on all hosts fails' -Condition ($r.Error -match 'not visible on every host' -and $r.Error -match 'esx03' -and -not (Test-Has $global:DsCalls '^(new|rescan):')) -Detail $r.Error
Assert-Test -Name 'Datastore: lock released after failure' -Condition (-not (Get-DsLock).Active)

Reset-Ds; $global:DsCreatedVmfs = $null
$p = & $vmfsParams $ctx; $p.DatastoreName = 'ds app!'
$r = Invoke-TestHandler -Handler 'New-VsphereDatastore.ps1' -Parameters $p
Assert-Test -Name 'Datastore: name pattern enforced' -Condition ($r.Error -match 'does not match the naming rule' -and -not (Test-Has $global:DsCalls '^new:')) -Detail $r.Error

$p = & $vmfsParams $ctx; $p.DatastoreName = 'DS-OLD-01'
$r = Invoke-TestHandler -Handler 'New-VsphereDatastore.ps1' -Parameters $p
Assert-Test -Name 'Datastore: existing name refused' -Condition ($r.Error -match "already exists") -Detail $r.Error

$p = & $vmfsParams $ctx; $p.Cluster = 'CL-OTHER'
$r = Invoke-TestHandler -Handler 'New-VsphereDatastore.ps1' -Parameters $p
Assert-Test -Name 'Datastore: cluster not allowed' -Condition ($r.Error -match 'not in the allowed clusters') -Detail $r.Error

$p = & $vmfsParams $ctx; $p.DatastoreCluster = 'POD-VMFS'; $p.NewDatastoreCluster = 'POD-NEW'
$r = Invoke-TestHandler -Handler 'New-VsphereDatastore.ps1' -Parameters $p
Assert-Test -Name 'Datastore: existing + new datastore cluster are exclusive' -Condition ($r.Error -match 'either an existing datastore cluster or a new one') -Detail $r.Error

$p = & $vmfsParams $ctx; $p.DatastoreCluster = 'POD-NFS'
$r = Invoke-TestHandler -Handler 'New-VsphereDatastore.ps1' -Parameters $p
Assert-Test -Name 'Datastore: VMFS refused in an NFS datastore cluster' -Condition ($r.Error -match 'holds NFS datastores' -and -not (Test-Has $global:DsCalls '^new:')) -Detail $r.Error

Reset-Ds; $global:DsCreatedVmfs = $null
$p = & $vmfsParams $ctx; $p.DatastoreCluster = 'POD-VMFS'
$r = Invoke-TestHandler -Handler 'New-VsphereDatastore.ps1' -Parameters $p
Assert-Test -Name 'Datastore VMFS: added to existing VMFS datastore cluster' -Condition ($null -eq $r.Error -and (Test-Has $global:DsCalls '^move:DS-APP-02:POD-VMFS$') -and $r.Result.DatastoreCluster -eq 'POD-VMFS') -Detail $r.Error

Enter-PortalStorageLock -Site DC1 -Cluster CL-APP-01 -By 'other-user (REQ-OTHER)' -Reason 'rescan'
Reset-Ds; $global:DsCreatedVmfs = $null
$r = Invoke-TestHandler -Handler 'New-VsphereDatastore.ps1' -Parameters (& $vmfsParams $ctx)
$lk = Get-DsLock
Assert-Test -Name 'Datastore: storage lock already held fails' -Condition ($r.Error -match 'already running on cluster CL-APP-01' -and -not $global:DsCalls.Count) -Detail $r.Error
Assert-Test -Name "Datastore: other job's lock is not released" -Condition ($lk.Active -and $lk.By -eq 'other-user (REQ-OTHER)') -Detail "$($lk | ConvertTo-Json -Compress)"
Exit-PortalStorageLock -Site DC1 -Cluster CL-APP-01

$nfsParams = { param($c) @{ Site = 'DC1'; Cluster = 'CL-APP-01'; DatastoreType = 'NFS'; NfsServer = 'nas01.test.local'; NfsPath = '/vol/ds_app_03'; NfsVersion = '4.1'
                            DatastoreName = 'NFS-APP-03'; NewDatastoreCluster = 'POD-NFS-NEW'; ChangeTicket = 'CHG8'; Context = $c } }
Reset-Ds; $global:DsCreatedVmfs = $null
$r = Invoke-TestHandler -Handler 'New-VsphereDatastore.ps1' -Parameters (& $nfsParams $ctx)
Assert-Test -Name 'Datastore NFS: mounted on every host (4.1)' -Condition ($null -eq $r.Error -and @($global:DsCalls | Where-Object { $_ -match '^new:nfs:esx0\d:NFS-APP-03:/vol/ds_app_03:nas01.test.local:4.1$' }).Count -eq 3 -and $r.Result.Type -eq 'NFS 4.1') -Detail ($r.Error + ' ' + ($global:DsCalls -join ', '))
Assert-Test -Name 'Datastore NFS: port 2049 probed' -Condition (Test-Has $global:DsCalls '^probe:nas01.test.local:2049$')
Assert-Test -Name 'Datastore NFS: new datastore cluster (SDRS Manual) + move' -Condition ((Test-Has $global:DsCalls '^newpod:POD-NFS-NEW:DC1-Datacenter$') -and (Test-Has $global:DsCalls '^setpod:POD-NFS-NEW:Manual$') -and (Test-Has $global:DsCalls '^move:NFS-APP-03:POD-NFS-NEW$')) -Detail ($global:DsCalls -join ', ')

Reset-Ds; $global:DsCreatedVmfs = $null; $global:NfsReachable = $false
$r = Invoke-TestHandler -Handler 'New-VsphereDatastore.ps1' -Parameters (& $nfsParams $ctx)
Assert-Test -Name 'Datastore NFS: unreachable port fails' -Condition ($r.Error -match 'does not answer on TCP 2049' -and -not (Test-Has $global:DsCalls '^new')) -Detail $r.Error

$p = & $nfsParams $ctx; $p.NfsPath = 'vol/x'
Reset-Ds; $global:DsCreatedVmfs = $null
$r = Invoke-TestHandler -Handler 'New-VsphereDatastore.ps1' -Parameters $p
Assert-Test -Name "Datastore NFS: path must start with '/'" -Condition ($r.Error -match "must start with '/'") -Detail $r.Error

Reset-Ds; $global:DsCreatedVmfs = $null; $global:DsMountFailOn = 'esx02'
$r = Invoke-TestHandler -Handler 'New-VsphereDatastore.ps1' -Parameters (& $nfsParams $ctx)
Assert-Test -Name 'Datastore NFS: verification failure rolls back' -Condition ($r.Error -match 'not accessible on: esx02' -and @($global:DsCalls | Where-Object { $_ -like 'remove:NFS-APP-03:*' }).Count -eq 3 -and (Test-Has $global:DsCalls '^removepod:POD-NFS-NEW$')) -Detail ($r.Error + ' ' + ($global:DsCalls -join ', '))
Assert-Test -Name 'Datastore: lock released after rollback' -Condition (-not (Get-DsLock).Active)

Reset-Ds; $global:DsCreatedVmfs = $null; $global:DsMountFailOn = 'esx03'
$r = Invoke-TestHandler -Handler 'New-VsphereDatastore.ps1' -Parameters (& $vmfsParams $ctx)
Assert-Test -Name 'Datastore VMFS: rollback removes the datastore once (first host)' -Condition ($r.Error -match 'not accessible on: esx03' -and ($global:DsCalls | Where-Object { $_ -like 'remove:*' }) -eq 'remove:DS-APP-02:esx01') -Detail ($r.Error + ' ' + ($global:DsCalls -join ', '))
$global:DsCreatedVmfs = $null
#endregion

#region ===== Three-tier blueprint ================================================================================
$bpRoot = Join-Path $global:SspHandlerTestRoot ('bp-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$bpDir = Join-Path $bpRoot 'automation/handlers'
$null = New-Item -ItemType Directory -Path $bpDir -Force
@{
    'New-VsphereVM.ps1' = @'
[CmdletBinding()] param([Parameter(Mandatory)] [string] $Site, [Parameter(Mandatory)] [string] $VMName, [string] $Description, [Parameter(Mandatory)] [string] $Template,
    [string] $Workload, [string] $Cluster, [Parameter(Mandatory)] [string] $Datastore, [Parameter(Mandatory)] [string] $Folder, [Parameter(Mandatory)] [int] $CpuCount,
    [Parameter(Mandatory)] [int] $MemoryGB, [int] $AdditionalDiskGB = 0, [Parameter(Mandatory)] [string] $PortGroup, [string] $IpMode, [string] $IPAddress, [string] $SubnetMask,
    [string] $Gateway, [string] $DnsServers, [string] $Owner, [string] $CostCenter, [string] $ChangeTicket, [bool] $PowerOn = $true,
    [Parameter(Mandatory)] [string] $GuestFamily, [Parameter(Mandatory)] [string] $CustomizationSpec, [System.Collections.IDictionary] $VmNotes, [Parameter(Mandatory)] $Context)
if ($global:BpFailVm -eq $VMName) { throw "clone failed for $VMName" }
$global:BpCalls.Add("vm:${VMName}:${Cluster}:${CpuCount}:${MemoryGB}:${AdditionalDiskGB}:${IPAddress}")
$global:BpVMs[$VMName] = [pscustomobject]@{ Name = $VMName; PowerState = 'PoweredOn' }
[ordered]@{ VMName = $VMName; Cluster = $Cluster }
'@
    'New-VsphereDrsRule.ps1' = @'
[CmdletBinding()] param([Parameter(Mandatory)] [string] $Site, [Parameter(Mandatory)] [string] $Cluster, [Parameter(Mandatory)] [string] $RuleType,
    [Parameter(Mandatory)] [string] $RuleName, [Parameter(Mandatory)] [string] $VMNames, [string] $HostNames, [string] $ChangeTicket, [Parameter(Mandatory)] $Context)
$global:BpCalls.Add("drs:${Cluster}:${RuleType}:${RuleName}:${VMNames}")
[ordered]@{ RuleName = $RuleName }
'@
    'Install-GuestAgentBaseline.ps1' = @'
[CmdletBinding()] param([Parameter(Mandatory)] [string] $Site, [Parameter(Mandatory)] [string] $VMName, [Parameter(Mandatory)] [string] $BaselineSet,
    [Parameter(Mandatory)] [pscredential] $GuestCredential, [Parameter(Mandatory)] $Context)
if ($global:BpFailBaselineOn -eq $VMName) { throw "baseline install failed on $VMName" }
$global:BpCalls.Add("baseline:${VMName}:${BaselineSet}:$($GuestCredential.UserName)")
[ordered]@{ VMName = $VMName; NextSteps = @('Baseline installed.') }
'@
    'Set-PortalBackupPolicy.ps1' = @'
[CmdletBinding()] param([Parameter(Mandatory)] [string] $Site, [Parameter(Mandatory)] [string] $VMName, [Parameter(Mandatory)] [string] $Policy, [string] $ChangeTicket, [Parameter(Mandatory)] $Context)
$global:BpCalls.Add("backup:${VMName}:${Policy}")
[ordered]@{ NewPolicy = $Policy }
'@
    # Deliberately a reduced signature (no Collation / MaxDop / InstanceName): the blueprint must pass only declared parameters.
    'Install-GuestSqlServer.ps1' = @'
[CmdletBinding()] param([Parameter(Mandatory)] [string] $Site, [Parameter(Mandatory)] [string] $VMName, [Parameter(Mandatory)] [pscredential] $GuestCredential,
    [Parameter(Mandatory)] [string] $SysAdminGroup, [bool] $PrepareDisks = $true, [Parameter(Mandatory)] [string] $InstallerPath, [Parameter(Mandatory)] $Context)
$global:BpCalls.Add("sql:${VMName}:${SysAdminGroup}:${InstallerPath}:${PrepareDisks}:" + (($PSBoundParameters.Keys | Sort-Object) -join '+'))
[ordered]@{ Instance = 'MSSQLSERVER' }
'@
}.GetEnumerator() | ForEach-Object { Set-Content -LiteralPath (Join-Path $bpDir $_.Key) -Value $_.Value -Encoding utf8NoBOM }

$global:BpCalls = [System.Collections.Generic.List[string]]::new()
$global:BpVMs = @{}
$global:BpFailBaselineOn = $null
$global:BpFailVm = $null
$global:BpDbDatastores = @('DS-SHARED')
New-Stub Get-VM 'param($Name, $Server, $Id) if ($global:BpVMs.ContainsKey([string]$Name)) { $global:BpVMs[[string]$Name] }'
New-Stub Get-Cluster 'param($Name, $Server) [pscustomobject]@{ Name = $Name }'
New-Stub Get-VMHost 'param($Location, $Server) if ($Location.Name -eq "CL-DB-01") { @([pscustomobject]@{ Name = "esx-db1"; ConnectionState = "Connected"; Cluster = "CL-DB-01" }) } else { @("esx-app1", "esx-app2") | ForEach-Object { [pscustomobject]@{ Name = $_; ConnectionState = "Connected"; Cluster = "CL-APP-01" } } }'
New-Stub Get-Datastore 'param($VMHost, $Server, $Name) $names = if ($VMHost.Cluster -eq "CL-DB-01") { $global:BpDbDatastores } else { @("DS-SHARED", "DS-APPONLY") }; @($names | ForEach-Object { [pscustomobject]@{ Name = $_ } })'
New-Stub New-HardDisk 'param($VM, $CapacityGB, $StorageFormat) $global:BpCalls.Add("disk:$($VM.Name):${CapacityGB}:$StorageFormat")'
New-Stub Get-DrsRule 'param($Cluster, $Name, $Server) [pscustomobject]@{ Name = $Name; Cluster = $Cluster.Name }'
New-Stub Remove-DrsRule 'param($Rule) $global:BpCalls.Add("remove-drs:$($Rule.Cluster):$($Rule.Name)")'
New-Stub Stop-VM 'param($VM, [switch] $Kill) $global:BpCalls.Add("stop:$($VM.Name)")'
New-Stub Remove-VM 'param($VM, [switch] $DeletePermanently) if (-not $DeletePermanently) { throw "DeletePermanently expected" }; $global:BpCalls.Add("remove-vm:$($VM.Name)"); $global:BpVMs.Remove($VM.Name)'

$guestCred = [pscredential]::new('CORP\svc-build', (ConvertTo-SecureString 'P@ssw0rd-test' -AsPlainText -Force))
function New-BpParams { param($Ctx)
    @{ AppCode = 'crm'; Site = 'DC1'; Workload = 'App'; Datastore = 'DS-SHARED'; Folder = 'DC1/Apps'; PortGroup = 'PG-APP-100'
       IpWeb = '10.10.0.11'; IpApp = '10.10.0.12'; IpDb = '10.10.0.13'; SubnetMask = '255.255.255.0'; Gateway = '10.10.0.1'; DnsServers = ''
       Size = 'Medium'; GuestCredential = $guestCred; BaselineSet = 'windows-base'; BackupPolicy = 'Gold'; InstallSql = $true; SysAdminGroup = 'CORP\SQL-Admins'
       ChangeTicket = 'CHG42'; Owner = 'app@test.local'; CostCenter = 'CC100'; Template = 'TPL-WIN2025'; CustomizationSpec = 'WIN2025-BASE'
       SqlInstallerPath = '\\fs\media\SQL2022'; SqlDiskSizesGB = '100,50,100,50'; Context = $Ctx }
}
function New-BpContext { $c = New-TestContext -ItemId 'blueprint-three-tier'; $c.PortalRoot = $bpRoot; $c }

$ctx = New-BpContext
$r = Invoke-TestHandler -Handler 'New-VsphereThreeTierApp.ps1' -Parameters (New-BpParams $ctx)
Assert-Test -Name 'Blueprint: three VMs created' -Condition ($null -eq $r.Error -and (@($r.Result.VMs) -join ',') -eq 'CRMWEB01,CRMAPP01,CRMDB01' -and @($r.Result.IPs) -contains 'CRMDB01=10.10.0.13') -Detail ($r.Error + ' ' + ($r.Log -join ' | '))
Assert-Test -Name 'Blueprint: WEB/APP on APP cluster, DB on DB cluster with double memory' -Condition ((Test-Has $global:BpCalls '^vm:CRMWEB01:CL-APP-01:4:8:0:10.10.0.11$') -and (Test-Has $global:BpCalls '^vm:CRMAPP01:CL-APP-01:4:8:0:') -and (Test-Has $global:BpCalls '^vm:CRMDB01:CL-DB-01:4:16:100:10.10.0.13$')) -Detail ($global:BpCalls -join ', ')
Assert-Test -Name 'Blueprint: SQL disks added (logs, backup, tempdb)' -Condition (@($global:BpCalls | Where-Object { $_ -like 'disk:CRMDB01:*:Thin' }).Count -eq 3)
Assert-Test -Name 'Blueprint: WEB/APP anti-affinity rule' -Condition (Test-Has $global:BpCalls '^drs:CL-APP-01:VmAntiAffinity:CRM-WEB-APP-separate:CRMWEB01,CRMAPP01$')
Assert-Test -Name 'Blueprint: baseline on the three VMs' -Condition (@($global:BpCalls | Where-Object { $_ -like 'baseline:*:windows-base:CORP\svc-build' }).Count -eq 3)
Assert-Test -Name 'Blueprint: backup policy for the three VMs' -Condition (Test-Has $global:BpCalls '^backup:CRMWEB01,CRMAPP01,CRMDB01:Gold$')
Assert-Test -Name 'Blueprint: SQL gets only declared parameters' -Condition (Test-Has $global:BpCalls '^sql:CRMDB01:CORP\\SQL-Admins:\\\\fs\\media\\SQL2022:True:Context\+GuestCredential\+InstallerPath\+PrepareDisks\+Site\+SysAdminGroup\+VMName$') -Detail (($global:BpCalls | Where-Object { $_ -like 'sql:*' }) -join ', ')
Assert-Test -Name 'Blueprint: steps recorded + report' -Condition (@($r.Result.Steps | Where-Object { $_ -match ': OK$' }).Count -eq 11 -and ((Get-TestReportFiles -Context $ctx) -contains 'blueprint-crm.html')) -Detail ((@($r.Result.Steps) -join ' / ') + ' ' + ((Get-TestReportFiles -Context $ctx) -join ','))

$global:BpCalls.Clear(); $global:BpVMs = @{}
$p = New-BpParams $ctx; $p.InstallSql = $false; $p.SysAdminGroup = ''; $p.Workload = 'DB'; $p.SqlInstallerPath = 'TBD-\\fs\media'
$r = Invoke-TestHandler -Handler 'New-VsphereThreeTierApp.ps1' -Parameters $p
Assert-Test -Name 'Blueprint: InstallSql false skips SQL + disks; all on DB cluster' -Condition ($null -eq $r.Error -and -not (Test-Has $global:BpCalls '^(sql|disk):') -and (Test-Has $global:BpCalls '^vm:CRMWEB01:CL-DB-01:') -and (Test-Has $global:BpCalls '^drs:CL-DB-01:')) -Detail ($r.Error + ' ' + ($global:BpCalls -join ', '))

$global:BpCalls.Clear(); $global:BpVMs = @{}
$p = New-BpParams $ctx; $p.Datastore = 'DS-APPONLY'
$r = Invoke-TestHandler -Handler 'New-VsphereThreeTierApp.ps1' -Parameters $p
Assert-Test -Name 'Blueprint: datastore not on DB cluster fails pre-check' -Condition ($r.Error -match 'not visible on the DB cluster CL-DB-01' -and -not $global:BpCalls.Count) -Detail $r.Error

$p = New-BpParams $ctx; $p.AppCode = 'TOOLONG99'
$r = Invoke-TestHandler -Handler 'New-VsphereThreeTierApp.ps1' -Parameters $p
Assert-Test -Name 'Blueprint: AppCode validated' -Condition ($r.Error -match 'must be 2-8 uppercase letters or digits') -Detail $r.Error

$p = New-BpParams $ctx; $p.Template = 'TBD-DC1-TPL-WIN2025'
$r = Invoke-TestHandler -Handler 'New-VsphereThreeTierApp.ps1' -Parameters $p
Assert-Test -Name 'Blueprint: TBD fixed parameter refused' -Condition ($r.Error -match 'Fixed parameter Template is not configured') -Detail $r.Error

$global:BpVMs = @{ CRMAPP01 = [pscustomobject]@{ Name = 'CRMAPP01'; PowerState = 'PoweredOn' } }
$r = Invoke-TestHandler -Handler 'New-VsphereThreeTierApp.ps1' -Parameters (New-BpParams $ctx)
Assert-Test -Name 'Blueprint: existing VM name refused' -Condition ($r.Error -match "A VM named 'CRMAPP01' already exists" -and -not $global:BpCalls.Count) -Detail $r.Error

$global:BpVMs = @{}
Move-Item (Join-Path $bpDir 'Install-GuestAgentBaseline.ps1') (Join-Path $bpRoot 'baseline.bak')
$r = Invoke-TestHandler -Handler 'New-VsphereThreeTierApp.ps1' -Parameters (New-BpParams $ctx)
Assert-Test -Name 'Blueprint: missing sub-handler fails pre-check' -Condition ($r.Error -match 'sub-handler\(s\) missing' -and $r.Error -match 'Install-GuestAgentBaseline.ps1' -and -not $global:BpCalls.Count) -Detail $r.Error
Move-Item (Join-Path $bpRoot 'baseline.bak') (Join-Path $bpDir 'Install-GuestAgentBaseline.ps1')

Set-Content -LiteralPath (Join-Path $bpDir 'Set-PortalBackupPolicy.ps1') -Encoding utf8NoBOM -Value @'
[CmdletBinding()] param([Parameter(Mandatory)] [string] $Site, [Parameter(Mandatory)] [string] $VMName, [Parameter(Mandatory)] [string] $Policy, [Parameter(Mandatory)] [string] $Vendor, [Parameter(Mandatory)] $Context)
'@
$r = Invoke-TestHandler -Handler 'New-VsphereThreeTierApp.ps1' -Parameters (New-BpParams $ctx)
Assert-Test -Name 'Blueprint: unsupplied mandatory sub-handler parameter fails pre-check' -Condition ($r.Error -match 'Set-PortalBackupPolicy.ps1 needs parameter\(s\).*Vendor' -and -not $global:BpCalls.Count) -Detail $r.Error
Set-Content -LiteralPath (Join-Path $bpDir 'Set-PortalBackupPolicy.ps1') -Encoding utf8NoBOM -Value @'
[CmdletBinding()] param([Parameter(Mandatory)] [string] $Site, [Parameter(Mandatory)] [string] $VMName, [Parameter(Mandatory)] [string] $Policy, [string] $ChangeTicket, [Parameter(Mandatory)] $Context)
$global:BpCalls.Add("backup:${VMName}:${Policy}")
'@

$global:BpCalls.Clear(); $global:BpVMs = @{}; $global:BpFailBaselineOn = 'CRMAPP01'
$ctx = New-BpContext
$r = Invoke-TestHandler -Handler 'New-VsphereThreeTierApp.ps1' -Parameters (New-BpParams $ctx)
$removed = @($global:BpCalls | Where-Object { $_ -like 'remove-*' })
Assert-Test -Name 'Blueprint: failing step reported' -Condition ($r.Error -match "Step 'Software baseline APP' \(CRMAPP01\) failed: baseline install failed") -Detail $r.Error
Assert-Test -Name 'Blueprint: rollback removes DRS rule then VMs in reverse order' -Condition (($removed -join ',') -eq 'remove-drs:CL-APP-01:CRM-WEB-APP-separate,remove-vm:CRMDB01,remove-vm:CRMAPP01,remove-vm:CRMWEB01' -and $global:BpVMs.Count -eq 0) -Detail ($removed -join ',')
Assert-Test -Name 'Blueprint: later steps not run after failure' -Condition (-not (Test-Has $global:BpCalls '^(backup|sql):'))
Assert-Test -Name 'Blueprint: failure report written' -Condition ((Get-TestReportFiles -Context $ctx) -contains 'blueprint-crm.html')

$global:BpCalls.Clear(); $global:BpVMs = @{}; $global:BpFailBaselineOn = $null; $global:BpFailVm = 'CRMDB01'
$r = Invoke-TestHandler -Handler 'New-VsphereThreeTierApp.ps1' -Parameters (New-BpParams (New-BpContext))
Assert-Test -Name 'Blueprint: DB clone failure removes WEB and APP' -Condition ($r.Error -match "Create DB VM" -and ((@($global:BpCalls | Where-Object { $_ -like 'remove-vm:*' })) -join ',') -eq 'remove-vm:CRMAPP01,remove-vm:CRMWEB01') -Detail ($r.Error + ' ' + ($global:BpCalls -join ','))

$global:BpCalls.Clear(); $global:BpVMs = @{}; $global:BpFailVm = $null; $global:BpFailBaselineOn = 'CRMWEB01'
$c = New-BpContext; $c.RollbackOnFailure = $false
$r = Invoke-TestHandler -Handler 'New-VsphereThreeTierApp.ps1' -Parameters (New-BpParams $c)
Assert-Test -Name 'Blueprint: no rollback when RollbackOnFailure is false' -Condition ($r.Error -and -not (Test-Has $global:BpCalls '^remove-') -and $global:BpVMs.Count -eq 3) -Detail ($global:BpCalls -join ',')
$global:BpFailBaselineOn = $null
#endregion

# Clean up the stubs so other groups start clean.
foreach ($n in $stubNames) { Remove-Item "function:global:$n" -ErrorAction SilentlyContinue }
Remove-Variable -Scope Global -Name Bk*, AwsInstances, Ec2Filter, AzVms, PowerCalls, Ds*, NfsReachable, Bp* -ErrorAction SilentlyContinue
