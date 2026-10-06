#Requires -Version 7.2
<#
.SYNOPSIS
    Cloud Ops handler - starts or stops the AWS instances / Azure VMs that carry a given power schedule tag value.
.DESCRIPTION
    Used by catalog items cloud-power-action-aws and cloud-power-action-azure (the runner connects one cloud per item;
    the handler branches on $Context.Cloud.Provider).

    Selection: tag <operations.powerSchedules.tagKey> (default 'PowerSchedule') equal to TagValue, for example
    'office-hours'. Resources without that exact tag value are never touched (checked twice: provider-side filter and
    an explicit check on the returned tags).
    AWS  : Start-EC2Instance / Stop-EC2Instance.
    Azure: Start-AzVM / Stop-AzVM -Force (deallocates: 'VM stopped' VMs are deallocated too, since they are still billed).
    DryRun (default) lists what would change and changes nothing.

    Future work: a portal scheduler that submits this item automatically (for example 07:00 Start / 20:00 Stop for
    'office-hours' in operations.powerSchedules.timeZone). Today the item is run on demand.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Start', 'Stop')] [string] $Action,
    [Parameter(Mandatory)] [string] $TagValue,
    [bool] $DryRun = $true,
    [string] $ChangeTicket,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) { function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" } }

$cloud = $Context.Cloud
if (-not $cloud) { throw 'This item needs a cloud connection (execution.cloud).' }
$provider = [string]$cloud.Provider
if ($TagValue -notmatch '^[A-Za-z0-9][A-Za-z0-9 ._:/=+@-]{0,63}$') { throw "Tag value '$TagValue' is not valid (1-64 characters: letters, digits, space, . _ : / = + @ -)." }
$tagKey = 'PowerSchedule'
$ops = $Context.Operations
if ($ops -and $ops['powerSchedules'] -and $ops['powerSchedules']['tagKey']) { $tagKey = [string]$ops['powerSchedules']['tagKey'] }

Write-JobLog -Level STEP "$Action resources tagged $tagKey=$TagValue in $($provider.ToUpper())$(if ($DryRun) { ' (DRY RUN - no change)' })"
$rows = [System.Collections.Generic.List[object]]::new()

if ($provider -eq 'aws') {
    $common = @{ Region = $cloud.Region }
    if ($cloud.Credential) { $common['Credential'] = $cloud.Credential }
    $filter = @(@{ Name = "tag:$tagKey"; Values = @($TagValue) }, @{ Name = 'instance-state-name'; Values = @('pending', 'running', 'stopping', 'stopped') })
    $instances = @((Get-EC2Instance -Filter $filter @common) | ForEach-Object { $_.Instances } | Where-Object { $_ })
    foreach ($i in $instances) {
        $tv = (@($i.Tags) | Where-Object { $_.Key -eq $tagKey } | Select-Object -First 1).Value
        if ($tv -cne $TagValue) { Write-JobLog -Level WARN "Skipping $($i.InstanceId): tag $tagKey is '$tv'."; continue }
        $state = [string]$i.State.Name
        $name = (@($i.Tags) | Where-Object { $_.Key -eq 'Name' } | Select-Object -First 1).Value
        $row = [ordered]@{ Resource = [string]$i.InstanceId; Name = $name; StateBefore = $state; Result = ''; Detail = '' }
        $needed = if ($Action -eq 'Start') { $state -eq 'stopped' } else { $state -eq 'running' }
        if (-not $needed) { $row.Result = 'SKIPPED'; $row.Detail = "Already $state" }
        elseif ($DryRun) { $row.Result = 'DRY RUN'; $row.Detail = "Would $($Action.ToLower())" }
        else {
            try {
                if ($Action -eq 'Start') { $null = Start-EC2Instance -InstanceId $i.InstanceId @common }
                else { $null = Stop-EC2Instance -InstanceId $i.InstanceId @common }
                $row.Result = 'OK'; $row.Detail = "$Action requested"
                Write-JobLog -Level OK "$($i.InstanceId) ($name): $Action requested."
            }
            catch { $row.Result = 'FAIL'; $row.Detail = $_.Exception.Message; Write-JobLog -Level ERROR "$($i.InstanceId): $($_.Exception.Message)" }
        }
        $rows.Add($row)
    }
}
elseif ($provider -eq 'azure') {
    $vms = @(Get-AzVM -Status | Where-Object {
        $t = $_.Tags; $v = $null
        if ($t -is [System.Collections.IDictionary]) { foreach ($k in $t.Keys) { if ($k -ieq $tagKey) { $v = [string]$t[$k] } } }
        $v -ceq $TagValue
    })
    foreach ($vm in $vms) {
        $state = [string]$vm.PowerState
        $row = [ordered]@{ Resource = "$($vm.ResourceGroupName)/$($vm.Name)"; Name = [string]$vm.Name; StateBefore = $state; Result = ''; Detail = '' }
        $needed = if ($Action -eq 'Start') { $state -in 'VM deallocated', 'VM stopped' } else { $state -in 'VM running', 'VM stopped' }
        if (-not $needed) { $row.Result = 'SKIPPED'; $row.Detail = "Already $state" }
        elseif ($DryRun) { $row.Result = 'DRY RUN'; $row.Detail = $(if ($Action -eq 'Stop') { 'Would deallocate' } else { 'Would start' }) }
        else {
            try {
                if ($Action -eq 'Start') { $null = Start-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -NoWait }
                else { $null = Stop-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Force -NoWait }
                $row.Result = 'OK'; $row.Detail = $(if ($Action -eq 'Stop') { 'Deallocate requested' } else { 'Start requested' })
                Write-JobLog -Level OK "$($vm.Name): $($row.Detail)."
            }
            catch { $row.Result = 'FAIL'; $row.Detail = $_.Exception.Message; Write-JobLog -Level ERROR "$($vm.Name): $($_.Exception.Message)" }
        }
        $rows.Add($row)
    }
}
else { throw "Unsupported cloud provider '$provider'." }

$matched = $rows.Count
$changed = @($rows | Where-Object { $_.Result -eq 'OK' }).Count
$planned = @($rows | Where-Object { $_.Result -eq 'DRY RUN' }).Count
$skipped = @($rows | Where-Object { $_.Result -eq 'SKIPPED' }).Count
$failed  = @($rows | Where-Object { $_.Result -eq 'FAIL' }).Count
if (-not $matched) { Write-JobLog -Level WARN "No resource carries $tagKey=$TagValue." }

$files = New-PortalReport -Title "Cloud power action - $Action" -Subtitle "$($provider.ToUpper()) - tag $tagKey=$TagValue$(if ($DryRun) { ' - DRY RUN' })" -Context $Context `
    -Sections @(New-PortalReportSection -Title 'Affected resources' -Rows $rows.ToArray() -Columns Resource, Name, StateBefore, Result, Detail -Note 'Only resources with the exact tag value are listed. Nothing else is touched.') `
    -Summary ([ordered]@{ Matched = $matched; Changed = $changed; 'Would change (dry run)' = $planned; Skipped = $skipped; Failed = $failed }) -FileName "cloud-power-$($Action.ToLower())"

if ($failed) { throw "$failed of $matched $($Action.ToLower()) action(s) failed - see the report $($files[0].name)." }

$next = if ($DryRun) { @('Dry run: nothing was changed. Submit again with Dry run = false to apply.') }
        else { @('Power operations run asynchronously in the cloud; check the console in a few minutes.') }
$next += 'Automatic scheduling of this action (portal scheduler) is future work.'
return [ordered]@{
    Provider = $provider
    Action   = $Action
    Tag      = "$tagKey=$TagValue"
    DryRun   = $DryRun
    Matched  = $matched
    Changed  = $changed
    WouldChange = $planned
    Skipped  = $skipped
    Failed   = $failed
    Resources = @($rows | ForEach-Object { "$($_.Resource): $($_.Result)" })
    Report   = $files[0].name
    ChangeTicket = $ChangeTicket
    NextSteps = $next
}
