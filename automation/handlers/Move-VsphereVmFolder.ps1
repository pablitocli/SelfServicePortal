#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - moves one or more VMs into a vCenter VM folder (inventory only; no vMotion, no downtime).
.DESCRIPTION
    The folder is chosen from the site inventory ("Datacenter/Folder/Sub"). VMs already in the folder are skipped.
    VMs are moved one by one; a failure is reported and the others still move.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] [string] $VMNames,
    [Parameter(Mandatory)] [string] $Folder,
    [string] $ChangeTicket,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}
$vi = $Context.VIServer
$vmList = @($VMNames -split '[,;\s]+' | Where-Object { $_ } | Select-Object -Unique)
if (-not $vmList.Count) { throw 'List at least one VM.' }
if ($vmList.Count -gt 200) { throw "At most 200 VMs per request ($($vmList.Count) given)." }

$parts = @($Folder -split '/' | Where-Object { $_ })
if ($parts.Count -lt 2) { throw "Choose a VM folder, not the datacenter root ('$Folder')." }
$dc = Get-Datacenter -Name $parts[0] -Server $vi -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $dc) { throw "Datacenter '$($parts[0])' was not found in $Site." }
$target = Get-Folder -Name 'vm' -Location $dc -Type VM -NoRecursion -Server $vi
foreach ($p in ($parts | Select-Object -Skip 1)) {
    $target = Get-Folder -Name $p -Location $target -Type VM -NoRecursion -Server $vi -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $target) { throw "Folder '$Folder' was not found (missing '$p'). Refresh the inventory." }
}
Write-JobLog -Level STEP "Moving $($vmList.Count) VM(s) to $Folder"

$rows = [System.Collections.Generic.List[object]]::new()
foreach ($n in $vmList) {
    $vm = @(Get-VM -Name $n -Server $vi -ErrorAction SilentlyContinue)
    if ($vm.Count -ne 1) { $rows.Add([ordered]@{ VM = $n; From = ''; Status = $(if ($vm.Count) { 'ERROR more than one VM with this name' } else { 'ERROR not found' }) }); continue }
    $vm = $vm[0]
    $from = [string]$vm.Folder.Name
    if ([string]$vm.FolderId -eq [string]$target.Id) { $rows.Add([ordered]@{ VM = $n; From = $from; Status = 'OK already there' }); continue }
    $vmDc = Get-Datacenter -VM $vm -Server $vi -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($vmDc -and $vmDc.Name -ne $dc.Name) { $rows.Add([ordered]@{ VM = $n; From = $from; Status = "ERROR VM is in datacenter $($vmDc.Name)" }); continue }
    try {
        $null = Move-VM -VM $vm -InventoryLocation $target -Server $vi -Confirm:$false -ErrorAction Stop
        $rows.Add([ordered]@{ VM = $n; From = $from; Status = 'OK moved' })
        Write-JobLog -Level OK "$n -> $Folder"
    }
    catch { $rows.Add([ordered]@{ VM = $n; From = $from; Status = "ERROR $($_.Exception.Message)" }); Write-JobLog -Level WARN "${n}: $($_.Exception.Message)" }
}
$moved = @($rows | Where-Object Status -eq 'OK moved').Count
$errs = @($rows | Where-Object { $_.Status -like 'ERROR*' })
if ($errs.Count -eq $rows.Count) { throw "No VM was moved: $(@($errs | ForEach-Object { "$($_.VM) $($_.Status)" }) -join '; ')" }
$r = [ordered]@{ Folder = $Folder; Moved = $moved; AlreadyThere = @($rows | Where-Object Status -eq 'OK already there').Count; Failed = $errs.Count; ChangeTicket = $ChangeTicket }
$r['Details'] = @($rows | ForEach-Object { "$($_.VM): $($_.Status)" })
return $r
