#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - finds and removes expired / old VM snapshots in a datacenter.
.DESCRIPTION
    Scope PortalOnly: snapshots named "PORTAL-*" or whose description contains "Expires:". Scope All: every snapshot.
    Candidate rules (MinSizeGB always applies):
      - Stamped snapshot ("Expires: yyyy-MM-dd" in the description):
          ExpiredOnly = true  -> candidate when the expiry date is before today.
          ExpiredOnly = false -> candidate when expired OR older than OlderThanDays.
      - Unstamped snapshot -> candidate when older than OlderThanDays (ExpiredOnly does not apply).
    Snapshots whose description matches operations.snapshots.protectedDescriptionPattern are never removed.
    Removal: Remove-Snapshot -RemoveChildren:$false; afterwards, when vSphere flags the VM with
    Runtime.ConsolidationNeeded, disks are consolidated (ConsolidateVMDisks_Task).
    Report Status: REMOVED / WOULD REMOVE / SKIPPED-protected / KEPT / FAIL.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [ValidateSet('PortalOnly', 'All')] [string] $Scope = 'PortalOnly',
    [ValidateRange(1, 365)] [int] $OlderThanDays = 7,
    [ValidateRange(0, 100000)] [int] $MinSizeGB = 0,
    [bool] $ExpiredOnly = $true,
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
$protected = [string](Get-OpSetting $Context.Operations.snapshots 'protectedDescriptionPattern' '(?i)keep|do not delete|backup')
$now       = Get-Date
$today     = $now.Date

# ---- Pre-checks ---------------------------------------------------------------------------------
if (-not $DryRun -and -not $ChangeTicket) { throw 'A change ticket is required when Dry run is off.' }
try { $null = [regex]::new($protected) } catch { throw "operations.snapshots.protectedDescriptionPattern is not a valid regular expression: $protected" }

Write-JobLog -Level STEP "Snapshot scan in $Site (scope $Scope, older than $OlderThanDays d, min $MinSizeGB GB, expired only $ExpiredOnly, dry run $DryRun)."
$vms = @(Get-VM -Server $vi | Sort-Object Name)

$rows = [System.Collections.Generic.List[object]]::new()
$scanned = 0; $reclaimGB = 0.0; $consolidated = @()
foreach ($vm in $vms) {
    $snaps = @(try { Get-Snapshot -VM $vm -Server $vi -ErrorAction SilentlyContinue } catch { })
    if (-not $snaps) { continue }
    $removedHere = 0
    # Newest first: removing children before parents keeps each removal small.
    foreach ($s in ($snaps | Sort-Object Created -Descending)) {
        $scanned++
        $desc = [string]$s.Description
        $isPortal = $s.Name -like 'PORTAL-*' -or $desc -match 'Expires:'
        if ($Scope -eq 'PortalOnly' -and -not $isPortal) { continue }

        $expires = $null
        if ($desc -match 'Expires:\s*(\d{4}-\d{2}-\d{2})') { $expires = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', [cultureinfo]::InvariantCulture) }
        $age    = [int][math]::Floor(($now - [datetime]$s.Created).TotalDays)
        $sizeGB = [math]::Round([double]$s.SizeGB, 2)
        $old    = $age -ge $OlderThanDays
        $expired = $expires -and $expires -lt $today
        $candidate = if ($expires) { if ($ExpiredOnly) { $expired } else { $expired -or $old } } else { $old }
        if ($sizeGB -lt $MinSizeGB) { $candidate = $false }

        $status = if ($protected -and $desc -match $protected) { 'SKIPPED-protected' }
                  elseif (-not $candidate) { 'KEPT' }
                  elseif ($DryRun) { 'WOULD REMOVE' }
                  else { 'REMOVE' }
        if ($status -eq 'WOULD REMOVE') { $reclaimGB += $sizeGB }
        if ($status -eq 'REMOVE') {
            try {
                $null = Remove-Snapshot -Snapshot $s -RemoveChildren:$false -Server $vi -Confirm:$false
                $status = 'REMOVED'; $reclaimGB += $sizeGB; $removedHere++
                Write-JobLog -Level OK "Removed '$($s.Name)' on $($vm.Name) ($sizeGB GB)."
            }
            catch { $status = 'FAIL'; Write-JobLog -Level ERROR "Could not remove '$($s.Name)' on $($vm.Name): $($_.Exception.Message)" }
        }
        $rows.Add([ordered]@{
            VM = $vm.Name; Snapshot = $s.Name; Created = ([datetime]$s.Created).ToString('yyyy-MM-dd HH:mm'); AgeDays = $age; SizeGB = $sizeGB
            Expires = $(if ($expires) { $expires.ToString('yyyy-MM-dd') } else { '' }); Status = $status
        })
    }
    if ($removedHere) {
        try {
            $view = Get-View -Id $vm.Id -Property Runtime -Server $vi
            if ($view.Runtime.ConsolidationNeeded) {
                Write-JobLog -Level STEP "$($vm.Name): disk consolidation needed - starting ConsolidateVMDisks."
                $null = $view.ConsolidateVMDisks_Task()
                $consolidated += $vm.Name
            }
        }
        catch { Write-JobLog -Level WARN "$($vm.Name): consolidation check failed: $($_.Exception.Message)" }
    }
}

$cnt = { param($s) @($rows | Where-Object { $_.Status -eq $s }).Count }
$removed = & $cnt 'REMOVED'; $would = & $cnt 'WOULD REMOVE'; $prot = & $cnt 'SKIPPED-protected'; $kept = & $cnt 'KEPT'; $failed = & $cnt 'FAIL'
$candidates = $removed + $would + $failed
$reclaimGB = [math]::Round($reclaimGB, 2)
$summary = [ordered]@{
    'VMs scanned'       = $vms.Count
    'Snapshots in scope' = $rows.Count
    'Candidates'        = $candidates
    $(if ($DryRun) { 'GB reclaimable' } else { 'GB reclaimed' }) = $reclaimGB
    'Protected'         = $prot
    'Failed'            = $failed
}
$rule = "Stamped snapshots: $(if ($ExpiredOnly) { 'removed only after the Expires date' } else { 'removed when expired or older than ' + $OlderThanDays + ' days' }). Unstamped: older than $OlderThanDays days. Minimum size $MinSizeGB GB. Protected pattern: $protected."
$sections = @(New-PortalReportSection -Title 'Snapshots' -Rows $rows -Columns VM, Snapshot, Created, AgeDays, SizeGB, Expires, Status -Note $rule)
if ($consolidated) { $sections += New-PortalReportSection -Title 'Disk consolidation started' -Rows @($consolidated | ForEach-Object { [ordered]@{ VM = $_ } }) -Columns VM }
$files = New-PortalReport -Title 'Snapshot cleanup' -Subtitle "$Site - scope $Scope - $(if ($DryRun) { 'dry run' } else { "change $ChangeTicket" })" -Context $Context -Summary $summary -Sections $sections
Write-JobLog -Level OK "Scanned $scanned snapshot(s); candidates $candidates, removed $removed, would remove $would, protected $prot, kept $kept, failed $failed."

return [ordered]@{
    Site         = $Site
    DryRun       = $DryRun
    Candidates   = $candidates
    Removed      = $removed
    WouldRemove  = $would
    Protected    = $prot
    Kept         = $kept
    Failed       = $failed
    ReclaimGB    = $reclaimGB
    Consolidated = @($consolidated)
    Report       = $files[0].name
    NextSteps    = @($(if ($DryRun -and $would) { 'Review the report, then re-submit with Dry run off to remove the snapshots listed as WOULD REMOVE.' } else { 'No further action.' }))
}
