#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - brings data disks online, initializes and formats them with the requested drive letters on
    one or more Windows VMs (through VMware Tools, vault credential).
.DESCRIPTION
    For each requested letter (in order):
      * a fixed volume already using the letter -> SKIP (nothing changed);
      * otherwise the next disk WITHOUT data partitions (not boot / system; disk-number order = SCSI order) is used:
        set online and writable, initialized GPT when RAW, partition with the letter, formatted.
      * a CD-ROM holding the letter is moved to the last free letter (MoveCdRom), as when a template leaves the
        CD-ROM on D:.
    Disks that already have a data partition are never touched. DryRun (default) only shows the plan.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] [string] $VMNames,
    [Parameter(Mandatory)] [string] $DriveLetters,
    [string] $Labels,
    [ValidateSet('NTFS', 'ReFS')] [string] $FileSystem = 'NTFS',
    [ValidateSet('Default', '4K', '64K')] [string] $AllocationUnit = 'Default',
    [bool] $MoveCdRom = $true,
    [Parameter(Mandatory)] [pscredential] $GuestCredential,
    [bool] $DryRun = $true,
    [string] $ChangeTicket,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}
Import-Module (Join-Path $Context.PortalRoot 'automation/lib/Portal.Guest.psm1') -Force -DisableNameChecking
$vi = $Context.VIServer

$vmList = @($VMNames -split '[,;\s]+' | Where-Object { $_ } | Select-Object -Unique)
if (-not $vmList.Count) { throw 'List at least one VM.' }
if ($vmList.Count -gt 50) { throw "At most 50 VMs per request ($($vmList.Count) given)." }
$letters = @($DriveLetters.ToUpperInvariant() -split '[,;\s:]+' | Where-Object { $_ })
foreach ($l in $letters) { if ($l -notmatch '^[D-Y]$') { throw "Drive letter '$l' is not valid (D to Y)." } }
if (@($letters | Select-Object -Unique).Count -ne $letters.Count) { throw 'A drive letter is listed twice.' }
$labelList = @(if ($Labels) { $Labels -split '[,;]' | ForEach-Object { $_.Trim() } })
foreach ($lb in $labelList) { if ($lb -and $lb -notmatch '^[A-Za-z0-9 _-]{1,32}$') { throw "Volume label '$lb' is not valid (max 32 letters, digits, space, _ or -)." } }
$au = switch ($AllocationUnit) { '4K' { 4096 } '64K' { 65536 } default { 0 } }

$lit = { param($s) ConvertTo-PortalGuestLiteral $s }
$script = @"
`$letters = @($((@($letters) | ForEach-Object { & $lit $_ }) -join ', '))
`$labels = @($((@(for ($i = 0; $i -lt $letters.Count; $i++) { $(if ($i -lt $labelList.Count -and $labelList[$i]) { $labelList[$i] } else { "Data$($letters[$i])" }) }) | ForEach-Object { & $lit $_ }) -join ', '))
`$dry = `$$($DryRun.ToString().ToLower()); `$moveCd = `$$($MoveCdRom.ToString().ToLower()); `$fs = $(& $lit $FileSystem); `$au = $au
`$used = @()
for (`$i = 0; `$i -lt `$letters.Count; `$i++) {
    `$L = `$letters[`$i]
    `$vol = Get-Volume -DriveLetter `$L -ErrorAction SilentlyContinue
    if (`$vol -and [string]`$vol.DriveType -eq 'Fixed') { Write-Output ("RES|`$L|SKIP|already exists ({0} GB {1})" -f [math]::Round(`$vol.Size / 1GB, 1), `$vol.FileSystem); continue }
    `$cd = Get-CimInstance Win32_Volume -Filter ("DriveType=5 AND DriveLetter='" + `$L + ":'") -ErrorAction SilentlyContinue
    if (`$vol -and -not `$cd) { Write-Output "RES|`$L|ERROR|letter used by a `$(`$vol.DriveType) volume"; continue }
    `$disk = Get-Disk | Where-Object { -not `$_.IsBoot -and -not `$_.IsSystem -and `$used -notcontains `$_.Number -and
        -not @(Get-Partition -DiskNumber `$_.Number -ErrorAction SilentlyContinue | Where-Object { [string]`$_.Type -ne 'Reserved' }).Count } | Sort-Object Number | Select-Object -First 1
    if (-not `$disk) { Write-Output "RES|`$L|ERROR|no disk without data partitions left (add the disk in vCenter first)"; continue }
    `$used += `$disk.Number
    `$plan = "disk {0} {1} GB ({2}, {3})" -f `$disk.Number, [math]::Round(`$disk.Size / 1GB, 1), `$disk.PartitionStyle, `$disk.OperationalStatus
    if (`$cd -and -not `$moveCd) { Write-Output "RES|`$L|ERROR|letter held by the CD-ROM (enable 'Move CD-ROM')"; continue }
    if (`$dry) { Write-Output ("RES|`$L|PLAN|`$plan" + `$(if (`$cd) { ' - CD-ROM moved off ' + `$L + ':' } else { '' })); continue }
    try {
        if (`$cd) {
            `$taken = @(Get-CimInstance Win32_Volume | ForEach-Object { [string]`$_.DriveLetter }) + @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { `$_.Name + ':' })
            `$free = @(90..69 | ForEach-Object { [string][char]`$_ + ':' } | Where-Object { `$taken -notcontains `$_ -and `$letters -notcontains `$_.Substring(0, 1) }) | Select-Object -First 1
            if (-not `$free) { throw 'no free letter for the CD-ROM' }
            `$null = Set-CimInstance -InputObject `$cd -Property @{ DriveLetter = `$free }
        }
        if (`$disk.IsOffline) { Set-Disk -Number `$disk.Number -IsOffline `$false }
        if (`$disk.IsReadOnly) { Set-Disk -Number `$disk.Number -IsReadOnly `$false }
        if ([string]`$disk.PartitionStyle -eq 'RAW') { Initialize-Disk -Number `$disk.Number -PartitionStyle GPT }
        `$p = New-Partition -DiskNumber `$disk.Number -UseMaximumSize -DriveLetter `$L
        `$fp = @{ FileSystem = `$fs; NewFileSystemLabel = `$labels[`$i]; Confirm = `$false }
        if (`$au -gt 0) { `$fp['AllocationUnitSize'] = `$au }
        `$null = `$p | Format-Volume @fp
        `$v = Get-Volume -DriveLetter `$L
        Write-Output ("RES|`$L|OK|`$plan formatted {0} {1} GB label {2}" -f `$fs, [math]::Round(`$v.Size / 1GB, 1), `$labels[`$i])
    }
    catch { Write-Output "RES|`$L|ERROR|`$(`$_.Exception.Message)" }
}
"@

$rows = [System.Collections.Generic.List[object]]::new()
foreach ($name in $vmList) {
    Write-JobLog -Level STEP "$name$(if ($DryRun) { ' (dry run)' })"
    try {
        $g = Resolve-PortalGuestVM -Name $name -Server $vi -ExpectedFamily windows -TimeoutSeconds 120
        $out = Invoke-PortalGuestScript -VM $g.VM -Credential $GuestCredential -ScriptText $script -Server $vi -TimeoutSeconds 900 -Description "data disks $($letters -join ',')$(if ($DryRun) { ' (dry run)' })"
        foreach ($l in @($out -split "\r?\n" | Where-Object { $_ -like 'RES|*' })) {
            $f = $l.Split('|', 4)
            $st = switch ($f[2]) { 'OK' { 'OK' } 'SKIP' { 'OK skipped' } 'PLAN' { 'PLAN' } default { 'ERROR' } }
            $rows.Add([ordered]@{ VM = $name; Letter = "$($f[1]):"; Status = $st; Detail = $f[3] })
        }
    }
    catch { $rows.Add([ordered]@{ VM = $name; Letter = ''; Status = 'ERROR'; Detail = $_.Exception.Message }); Write-JobLog -Level ERROR "${name}: $($_.Exception.Message)" }
}
foreach ($r in $rows) { Write-JobLog -Level $(if ($r.Status -eq 'ERROR') { 'WARN' } else { 'INFO' }) "$($r.VM) $($r.Letter) $($r.Status) $($r.Detail)" }

$errors = @($rows | Where-Object Status -eq 'ERROR').Count
$files = New-PortalReport -Title "Data disks$(if ($DryRun) { ' - plan (dry run)' })" -Subtitle "$Site - letters $($letters -join ', ')" -Context $Context -FileName 'data-disks' -Sections @(
    New-PortalReportSection -Title $(if ($DryRun) { 'Plan' } else { 'Result' }) -Columns 'VM', 'Letter', 'Status', 'Detail' -Rows $rows) -Summary ([ordered]@{ VMs = $vmList.Count; Formatted = @($rows | Where-Object Status -eq 'OK').Count; Planned = @($rows | Where-Object Status -eq 'PLAN').Count; Errors = $errors })
if ($errors -and $errors -eq $rows.Count) { throw "No disk could be prepared: $(@($rows)[0].Detail)" }
$res = [ordered]@{ DryRun = $DryRun; VMs = $vmList.Count; Formatted = @($rows | Where-Object Status -eq 'OK').Count; Skipped = @($rows | Where-Object Status -eq 'OK skipped').Count; Errors = $errors; Report = $files[0].name; ChangeTicket = $ChangeTicket }
$res['Details'] = @($rows | ForEach-Object { "$($_.VM) $($_.Letter) $($_.Status) $($_.Detail)" })
if ($DryRun) { $res['NextSteps'] = @('Review the plan, then submit again with "Dry run" cleared.') }
return $res
