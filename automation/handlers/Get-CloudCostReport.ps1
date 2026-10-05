#Requires -Version 7.2
<#
.SYNOPSIS
    Cloud Ops handler - reports billable idle resources ("waste") in AWS or Azure.
.DESCRIPTION
    Used by catalog items cloud-cost-report-aws and cloud-cost-report-azure (the runner connects one cloud per item;
    the handler branches on $Context.Cloud.Provider). Read-only: nothing is changed.

    AWS  : unattached EBS volumes, Elastic IPs without association, instances stopped longer than the threshold
           (their EBS volumes are still billed), own snapshots older than 180 days.
    Azure: unattached managed disks, public IPs without IP configuration, VMs 'stopped' but NOT deallocated
           (compute is still billed), VMs deallocated longer than the threshold (disks still billed), snapshots
           older than 180 days.
    Both : resources with / without the power schedule tag (operations.powerSchedules.tagKey).

    Monthly amounts are LIST-PRICE ESTIMATES (USD, us-east-1 / East US public prices, no discounts, no reservations)
    from the tables below. They show the order of magnitude, not the invoice.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 365)] [int] $StoppedDaysThreshold = 7,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) { function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" } }

#region List-price estimate tables (USD per GB-month unless stated) ------------------------------------------
$AwsEbsPricePerGB   = @{ gp2 = 0.10; gp3 = 0.08; io1 = 0.125; io2 = 0.125; st1 = 0.045; sc1 = 0.015; standard = 0.05 }
$AwsSnapshotPerGB   = 0.05          # standard tier; snapshots are incremental, so this is an upper bound
$AwsEipPerMonth     = 3.65          # 0.005 USD/h x 730 h (idle public IPv4)
$AzDiskPricePerGB   = @{ Standard_LRS = 0.045; StandardSSD_LRS = 0.075; StandardSSD_ZRS = 0.094; Premium_LRS = 0.15; Premium_ZRS = 0.19; PremiumV2_LRS = 0.08; UltraSSD_LRS = 0.12 }
$AzSnapshotPerGB    = 0.05
$AzPublicIpPerMonth = 3.65
$SnapshotMaxAgeDays = 180
#endregion

$cloud = $Context.Cloud
if (-not $cloud) { throw 'This item needs a cloud connection (execution.cloud).' }
$provider = [string]$cloud.Provider
$tagKey = 'PowerSchedule'
$ops = $Context.Operations
if ($ops -and $ops['powerSchedules'] -and $ops['powerSchedules']['tagKey']) { $tagKey = [string]$ops['powerSchedules']['tagKey'] }
$now = (Get-Date).ToUniversalTime()
$sections = [System.Collections.Generic.List[object]]::new()
$totals = [ordered]@{}
$waste = 0.0

function Get-AgeDays { param($Date) if (-not $Date) { return $null } [int][math]::Floor(($now - ([datetime]$Date).ToUniversalTime()).TotalDays) }
function Get-Money { param([double] $Value) [math]::Round($Value, 2) }

if ($provider -eq 'aws') {
    $common = @{ Region = $cloud.Region }
    if ($cloud.Credential) { $common['Credential'] = $cloud.Credential }
    Write-JobLog -Level STEP "Collecting AWS resources in $($cloud.Region)"

    function Get-AwsTag { param($Tags, [string] $Key) (@($Tags) | Where-Object { $_.Key -eq $Key } | Select-Object -First 1).Value }

    $volumes = @(Get-EC2Volume @common)
    $volById = @{}; foreach ($v in $volumes) { $volById[[string]$v.VolumeId] = $v }

    # 1. Unattached EBS volumes
    $rows = foreach ($v in @($volumes | Where-Object { [string]$_.State -eq 'available' })) {
        $type = [string]$v.VolumeType
        $price = if ($AwsEbsPricePerGB.ContainsKey($type)) { $AwsEbsPricePerGB[$type] } else { 0.10 }
        $cost = Get-Money ([double]$v.Size * $price)
        $waste += $cost
        [ordered]@{ VolumeId = [string]$v.VolumeId; Name = Get-AwsTag $v.Tags 'Name'; SizeGB = [int]$v.Size; Type = $type
                    Created = ([datetime]$v.CreateTime).ToString('yyyy-MM-dd'); AgeDays = Get-AgeDays $v.CreateTime; MonthlyUSD = $cost; Status = 'WARN' }
    }
    $rows = @($rows)
    $totals['Unattached volumes'] = $rows.Count
    $sections.Add((New-PortalReportSection -Title 'Unattached EBS volumes' -Rows $rows -Columns VolumeId, Name, SizeGB, Type, Created, AgeDays, MonthlyUSD, Status -Note 'State available = not attached to any instance, billed per provisioned GB. List-price estimate.'))

    # 2. Elastic IPs without association
    $rows = @(Get-EC2Address @common | Where-Object { -not $_.AssociationId } | ForEach-Object {
        $waste += $AwsEipPerMonth
        [ordered]@{ PublicIp = [string]$_.PublicIp; AllocationId = [string]$_.AllocationId; Name = Get-AwsTag $_.Tags 'Name'; MonthlyUSD = $AwsEipPerMonth; Status = 'WARN' }
    })
    $totals['Unused Elastic IPs'] = $rows.Count
    $sections.Add((New-PortalReportSection -Title 'Unused Elastic IPs' -Rows $rows -Columns PublicIp, AllocationId, Name, MonthlyUSD, Status -Note 'Elastic IPs without association are billed hourly. List-price estimate.'))

    # 3. Instances stopped longer than the threshold (EBS still billed)
    $instances = @((Get-EC2Instance @common) | ForEach-Object { $_.Instances } | Where-Object { $_ -and [string]$_.State.Name -ne 'terminated' })
    $rows = foreach ($i in @($instances | Where-Object { [string]$_.State.Name -eq 'stopped' })) {
        $stoppedAt = $null
        if ([string]$i.StateTransitionReason -match '\((\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) GMT\)') {
            $stoppedAt = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]'AssumeUniversal,AdjustToUniversal')
        }
        $days = if ($stoppedAt) { Get-AgeDays $stoppedAt } else { $null }
        if ($null -ne $days -and $days -lt $StoppedDaysThreshold) { continue }
        $gb = 0; $cost = 0.0
        foreach ($m in @($i.BlockDeviceMappings)) {
            $v = $volById[[string]$m.Ebs.VolumeId]
            if ($v) { $gb += [int]$v.Size; $cost += [double]$v.Size * $(if ($AwsEbsPricePerGB.ContainsKey([string]$v.VolumeType)) { $AwsEbsPricePerGB[[string]$v.VolumeType] } else { 0.10 }) }
        }
        $cost = Get-Money $cost; $waste += $cost
        [ordered]@{ InstanceId = [string]$i.InstanceId; Name = Get-AwsTag $i.Tags 'Name'; Type = [string]$i.InstanceType
                    StoppedSince = $(if ($stoppedAt) { $stoppedAt.ToString('yyyy-MM-dd') } else { 'unknown' }); StoppedDays = $(if ($null -ne $days) { $days } else { 'unknown' })
                    EbsGB = $gb; MonthlyUSD = $cost; Status = 'WARN' }
    }
    $rows = @($rows)
    $totals['Long-stopped instances'] = $rows.Count
    $sections.Add((New-PortalReportSection -Title "Instances stopped more than $StoppedDaysThreshold days" -Rows $rows -Columns InstanceId, Name, Type, StoppedSince, StoppedDays, EbsGB, MonthlyUSD, Status -Note 'Compute is not billed while stopped, but the attached EBS volumes are. Consider an AMI + termination. List-price estimate.'))

    # 4. Old snapshots
    $rows = @(Get-EC2Snapshot -OwnerId self @common | Where-Object { (Get-AgeDays $_.StartTime) -gt $SnapshotMaxAgeDays } | ForEach-Object {
        $cost = Get-Money ([double]$_.VolumeSize * $AwsSnapshotPerGB); $waste += $cost
        [ordered]@{ SnapshotId = [string]$_.SnapshotId; VolumeId = [string]$_.VolumeId; SizeGB = [int]$_.VolumeSize; Created = ([datetime]$_.StartTime).ToString('yyyy-MM-dd')
                    AgeDays = Get-AgeDays $_.StartTime; Description = [string]$_.Description; MonthlyUSD = $cost; Status = 'WARN' }
    })
    $totals['Old snapshots'] = $rows.Count
    $sections.Add((New-PortalReportSection -Title "Snapshots older than $SnapshotMaxAgeDays days" -Rows $rows -Columns SnapshotId, VolumeId, SizeGB, Created, AgeDays, Description, MonthlyUSD, Status -Note 'Upper-bound estimate (snapshots are incremental). Check AMI dependencies before deleting.'))

    # 5. Power schedules
    $psRows = @($instances | ForEach-Object {
        $val = Get-AwsTag $_.Tags $tagKey
        [ordered]@{ Resource = [string]$_.InstanceId; Name = Get-AwsTag $_.Tags 'Name'; State = [string]$_.State.Name; Schedule = $(if ($val) { $val } else { '' }); Status = $(if ($val) { 'OK' } else { 'NOT SET' }) }
    } | Sort-Object { $_.Status }, { $_.Name })
}
elseif ($provider -eq 'azure') {
    Write-JobLog -Level STEP "Collecting Azure resources in subscription $($cloud.SubscriptionId)"
    function Get-AzTagValue { param($Tags, [string] $Key) if ($Tags -is [System.Collections.IDictionary]) { foreach ($k in $Tags.Keys) { if ($k -ieq $Key) { return [string]$Tags[$k] } } } return $null }

    # 1. Unattached managed disks
    $rows = @(Get-AzDisk | Where-Object { [string]$_.DiskState -eq 'Unattached' } | ForEach-Object {
        $sku = [string]$_.Sku.Name
        $price = if ($AzDiskPricePerGB.ContainsKey($sku)) { $AzDiskPricePerGB[$sku] } else { 0.075 }
        $cost = Get-Money ([double]$_.DiskSizeGB * $price); $waste += $cost
        [ordered]@{ Disk = [string]$_.Name; ResourceGroup = [string]$_.ResourceGroupName; SizeGB = [int]$_.DiskSizeGB; Sku = $sku
                    Created = $(if ($_.TimeCreated) { ([datetime]$_.TimeCreated).ToString('yyyy-MM-dd') } else { '' }); MonthlyUSD = $cost; Status = 'WARN' }
    })
    $totals['Unattached disks'] = $rows.Count
    $sections.Add((New-PortalReportSection -Title 'Unattached managed disks' -Rows $rows -Columns Disk, ResourceGroup, SizeGB, Sku, Created, MonthlyUSD, Status -Note 'DiskState Unattached, billed per provisioned size. List-price estimate (disks are billed by tier; per-GB approximation).'))

    # 2. Public IPs not associated
    $rows = @(Get-AzPublicIpAddress | Where-Object { -not $_.IpConfiguration } | ForEach-Object {
        $waste += $AzPublicIpPerMonth
        [ordered]@{ PublicIp = [string]$_.Name; ResourceGroup = [string]$_.ResourceGroupName; Address = [string]$_.IpAddress; Sku = [string]$_.Sku.Name; MonthlyUSD = $AzPublicIpPerMonth; Status = 'WARN' }
    })
    $totals['Unused public IPs'] = $rows.Count
    $sections.Add((New-PortalReportSection -Title 'Unused public IP addresses' -Rows $rows -Columns PublicIp, ResourceGroup, Address, Sku, MonthlyUSD, Status -Note 'No IP configuration attached. Static / Standard SKU addresses are billed while idle. List-price estimate.'))

    # 3. VMs stopped but not deallocated (compute still billed) and long-deallocated VMs
    $vms = @(Get-AzVM -Status)
    $rows = @($vms | Where-Object { [string]$_.PowerState -eq 'VM stopped' } | ForEach-Object {
        [ordered]@{ VM = [string]$_.Name; ResourceGroup = [string]$_.ResourceGroupName; Size = [string]$_.HardwareProfile.VmSize; PowerState = [string]$_.PowerState
                    Action = 'Deallocate (Stop-AzVM) - compute is still billed'; Status = 'CRITICAL' }
    })
    $totals['Stopped, not deallocated'] = $rows.Count
    $sections.Add((New-PortalReportSection -Title 'VMs stopped but NOT deallocated' -Rows $rows -Columns VM, ResourceGroup, Size, PowerState, Action, Status -Note "PowerState 'VM stopped' (shut down from the guest OS) keeps the compute reservation: the VM size is billed as if running. Not included in the estimate (size price depends on region and licensing)."))

    $rows = foreach ($v in @($vms | Where-Object { [string]$_.PowerState -eq 'VM deallocated' })) {
        $since = $null
        $detail = Get-AzVM -ResourceGroupName $v.ResourceGroupName -Name $v.Name -Status -ErrorAction SilentlyContinue
        $st = @($detail.Statuses) | Where-Object { [string]$_.Code -like 'PowerState/deallocated' -and $_.Time } | Select-Object -First 1
        if (-not $st) { $st = @($detail.Statuses) | Where-Object { [string]$_.Code -like 'ProvisioningState/*' -and $_.Time } | Select-Object -First 1 }
        if ($st) { $since = ([datetime]$st.Time).ToUniversalTime() }
        $days = if ($since) { Get-AgeDays $since } else { $null }
        if ($null -ne $days -and $days -lt $StoppedDaysThreshold) { continue }
        [ordered]@{ VM = [string]$v.Name; ResourceGroup = [string]$v.ResourceGroupName; Size = [string]$v.HardwareProfile.VmSize
                    DeallocatedSince = $(if ($since) { $since.ToString('yyyy-MM-dd') } else { 'unknown' }); Days = $(if ($null -ne $days) { $days } else { 'unknown' }); Status = 'WARN' }
    }
    $rows = @($rows)
    $totals['Long-deallocated VMs'] = $rows.Count
    $sections.Add((New-PortalReportSection -Title "VMs deallocated more than $StoppedDaysThreshold days" -Rows $rows -Columns VM, ResourceGroup, Size, DeallocatedSince, Days, Status -Note 'No compute charge, but OS and data disks are still billed. Date = last provisioning operation when the power-state time is not reported.'))

    # 4. Old snapshots
    $rows = @(Get-AzSnapshot | Where-Object { $_.TimeCreated -and (Get-AgeDays $_.TimeCreated) -gt $SnapshotMaxAgeDays } | ForEach-Object {
        $cost = Get-Money ([double]$_.DiskSizeGB * $AzSnapshotPerGB); $waste += $cost
        [ordered]@{ Snapshot = [string]$_.Name; ResourceGroup = [string]$_.ResourceGroupName; SizeGB = [int]$_.DiskSizeGB; Created = ([datetime]$_.TimeCreated).ToString('yyyy-MM-dd')
                    AgeDays = Get-AgeDays $_.TimeCreated; MonthlyUSD = $cost; Status = 'WARN' }
    })
    $totals['Old snapshots'] = $rows.Count
    $sections.Add((New-PortalReportSection -Title "Snapshots older than $SnapshotMaxAgeDays days" -Rows $rows -Columns Snapshot, ResourceGroup, SizeGB, Created, AgeDays, MonthlyUSD, Status -Note 'Estimate on the full disk size (incremental snapshots cost less).'))

    # 5. Power schedules
    $psRows = @($vms | ForEach-Object {
        $val = Get-AzTagValue $_.Tags $tagKey
        [ordered]@{ Resource = [string]$_.ResourceGroupName; Name = [string]$_.Name; State = [string]$_.PowerState; Schedule = $(if ($val) { $val } else { '' }); Status = $(if ($val) { 'OK' } else { 'NOT SET' }) }
    } | Sort-Object { $_.Status }, { $_.Name })
}
else { throw "Unsupported cloud provider '$provider'." }

$withTag = @($psRows | Where-Object { $_.Status -eq 'OK' }).Count
$sections.Add((New-PortalReportSection -Title 'Power schedules' -Rows $psRows -Columns Resource, Name, State, Schedule, Status -Note "Tag '$tagKey' marks resources started / stopped by the 'Cloud power action' items (for example office-hours). Untagged resources are never touched."))

$waste = Get-Money $waste
$summary = [ordered]@{}
foreach ($k in $totals.Keys) { $summary[$k] = $totals[$k] }
$summary['Estimated monthly waste (USD, list price)'] = ('{0:N2}' -f $waste)
$summary["With '$tagKey' tag"] = "$withTag / $(@($psRows).Count)"

$label = if ($provider -eq 'aws') { "AWS $($cloud.Region)" } else { "Azure subscription $($cloud.SubscriptionId)" }
$files = New-PortalReport -Title "Cloud cost report - $($provider.ToUpper())" -Subtitle "$label - idle billable resources (list-price estimates)" -Context $Context -Sections $sections.ToArray() -Summary $summary -FileName "cloud-cost-$provider"
$findings = 0; foreach ($k in $totals.Keys) { $findings += [int]$totals[$k] }
Write-JobLog -Level OK "$findings finding(s), estimated waste $waste USD/month (list price)."

$result = [ordered]@{ Provider = $provider; Scope = $label }
foreach ($k in $totals.Keys) { $result[($k -replace '[^A-Za-z0-9]', '')] = $totals[$k] }
$result['EstimatedMonthlyWasteUSD'] = $waste
$result['PowerScheduleTagged'] = $withTag
$result['Report'] = $files[0].name
$result['NextSteps'] = @(
    'Review the report with the resource owners before deleting anything (snapshots may back AMIs / images).',
    "Tag resources that can follow office hours with '$tagKey' and use the Cloud power action item."
)
return $result
