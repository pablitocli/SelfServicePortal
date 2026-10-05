#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - permanently deletes decommissioned VMs whose quarantine period has ended.
.DESCRIPTION
    Candidates: VMs in the quarantine folder (operations.decommission.quarantineFolder) whose name starts with the
    decommission prefix (operations.decommission.renamePrefix). A candidate is purged only when it is powered off
    and its "Portal.Decommission" annotation has purgeAfter=<yyyy-MM-dd> on or before today.
    DryRun (default) only reports. Otherwise Remove-VM -DeletePermanently. Report Status:
    PURGED / WOULD PURGE / NOT DUE / SKIPPED (powered on, no or invalid annotation, protected name) / FAIL.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [bool] $DryRun = $true,
    [string] $ChangeTicket,
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
$protected = [string](Get-OpSetting $ops 'protectedNamePattern' '')
$attrName  = 'Portal.Decommission'
$today     = (Get-Date).Date

# ---- Pre-checks ---------------------------------------------------------------------------------
if ($prefix.Trim().Length -lt 3) { throw "Unsafe decommission prefix '$prefix' (operations.decommission.renamePrefix must have at least 3 characters)." }
if (-not $DryRun -and -not $ChangeTicket) { throw 'A change ticket is required when Dry run is off.' }

Write-JobLog -Level STEP "Purge scan in $Site (folder '$qFolder', prefix '$prefix', dry run = $DryRun)."
$folders = @(Get-Folder -Name $qFolder -Type VM -Server $vi -ErrorAction SilentlyContinue)
if (-not $folders) { Write-JobLog -Level WARN "Quarantine folder '$qFolder' not found - nothing to purge." }

$vms = @(foreach ($f in $folders) { Get-VM -Location $f -Server $vi -ErrorAction SilentlyContinue }) |
    Where-Object { $_.Name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } | Sort-Object Name -Unique

$rows = [System.Collections.Generic.List[object]]::new()
$purgedGB = 0.0
foreach ($vm in $vms) {
    $ann = $null
    try { $ann = Get-Annotation -Entity $vm -CustomAttribute $attrName -Server $vi -ErrorAction SilentlyContinue } catch { }
    $value = [string]$ann.Value
    $purgeAfter = $null; $reqId = ''
    if ($value -match 'purgeAfter=(\d{4}-\d{2}-\d{2})') { $purgeAfter = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', [cultureinfo]::InvariantCulture) }
    if ($value) { $reqId = ($value -split ';')[0] }
    $original = $vm.Name.Substring($prefix.Length)

    $status = if ($protected -and $original -match $protected) { 'SKIPPED - protected name' }
              elseif (-not $purgeAfter) { 'SKIPPED - no purge date' }
              elseif ($vm.PowerState -ne 'PoweredOff') { 'SKIPPED - not powered off' }
              elseif ($purgeAfter -gt $today) { 'NOT DUE' }
              elseif ($DryRun) { 'WOULD PURGE' }
              else { 'PURGE' }

    if ($status -eq 'PURGE') {
        try {
            Remove-VM -VM $vm -DeletePermanently -Server $vi -Confirm:$false
            $status = 'PURGED'; $purgedGB += [double]$vm.ProvisionedSpaceGB
            Write-JobLog -Level OK "Purged $($vm.Name)."
        }
        catch { $status = "FAIL - $($_.Exception.Message)"; Write-JobLog -Level ERROR "Could not purge $($vm.Name): $($_.Exception.Message)" }
    }
    else { Write-JobLog "$($vm.Name): $status" }

    $rows.Add([ordered]@{
        VM              = $vm.Name
        OriginalName    = $original
        PowerState      = [string]$vm.PowerState
        ProvisionedGB   = [math]::Round([double]$vm.ProvisionedSpaceGB, 1)
        DecommissionReq = $reqId
        PurgeAfter      = $(if ($purgeAfter) { $purgeAfter.ToString('yyyy-MM-dd') } else { '' })
        Status          = $status
    })
}

$count = { param($rx) @($rows | Where-Object { $_.Status -match $rx }).Count }
$purged = & $count '^PURGED$'; $would = & $count '^WOULD PURGE$'; $notDue = & $count '^NOT DUE$'
$skipped = & $count '^SKIPPED'; $failed = & $count '^FAIL'
$summary = [ordered]@{
    'Quarantined VMs'                                  = $rows.Count
    $(if ($DryRun) { 'Would purge' } else { 'Purged' }) = $(if ($DryRun) { $would } else { $purged })
    'Not due'                                          = $notDue
    'Skipped'                                          = $skipped
    'Failed'                                           = $failed
}
$files = New-PortalReport -Title 'Decommissioned VM purge' -Subtitle "$Site - $(if ($DryRun) { 'dry run' } else { "change $ChangeTicket" })" -Context $Context -Summary $summary -Sections @(
    New-PortalReportSection -Title 'Quarantined VMs' -Rows $rows -Columns VM, OriginalName, PowerState, ProvisionedGB, DecommissionReq, PurgeAfter, Status `
        -Note "Folder '$qFolder', prefix '$prefix'. Purge requires: powered off and purgeAfter on or before $($today.ToString('yyyy-MM-dd'))."
)
Write-JobLog -Level OK "Candidates: $($rows.Count); purged $purged, would purge $would, not due $notDue, skipped $skipped, failed $failed."
if ($failed) { Write-JobLog -Level WARN "$failed VM(s) could not be purged - see the report." }

return [ordered]@{
    Site        = $Site
    DryRun      = $DryRun
    Candidates  = $rows.Count
    Purged      = $purged
    WouldPurge  = $would
    NotDue      = $notDue
    Skipped     = $skipped
    Failed      = $failed
    ReclaimedGB = [math]::Round($purgedGB, 1)
    Report      = $files[0].name
    NextSteps   = @($(if ($DryRun -and $would) { 'Review the report, then re-submit with Dry run off to delete the VMs listed as WOULD PURGE.' } else { 'No further action.' }))
}
