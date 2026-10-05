#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - creates an isolated test clone of a VM.
.DESCRIPTION
    Pre-checks: clone name unused, DaysToKeep within operations.testClones.maxDays, the port group exists, is not
    one of the source VM's current networks and (when operations.testClones.isolatedPortgroup is set) equals that
    value or matches it as a regular expression; the datastore has room for the source's used space + 10 %.
    Steps: full clone (New-VM -VM) on the source VM's host and the chosen datastore into the folder
    operations.testClones.folder (created under the datacenter when missing); every adapter of the clone gets a new
    manual MAC (00:50:56:00:00:00-00:50:56:3F:FF:FF) and is moved to the isolated port group; custom attribute
    "Portal.TestClone" = "<requestId>;expires=<yyyy-MM-dd>"; optional power-on.
    On failure with RollbackOnFailure, the clone is deleted.
.NOTES
    Cloning a running VM is crash-consistent. The clone keeps the source's hostname / IP / domain identity, which is
    why its adapters are moved to the isolated network before it can be powered on.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] [string] $VMName,
    [string] $CloneName,
    [Parameter(Mandatory)] [string] $IsolatedPortGroup,
    [Parameter(Mandatory)] [string] $Datastore,
    [int] $DaysToKeep = 7,
    [bool] $PowerOn = $false,
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
function New-ManualMac {
    # VMware manual range: 00:50:56:00:00:00 - 00:50:56:3F:FF:FF
    param([System.Collections.Generic.HashSet[string]] $Used)
    do { $mac = '00:50:56:{0:X2}:{1:X2}:{2:X2}' -f (Get-Random -Min 0 -Max 0x40), (Get-Random -Min 0 -Max 0x100), (Get-Random -Min 0 -Max 0x100) }
    while (-not $Used.Add($mac))
    return $mac
}

$vi       = $Context.VIServer
$ops      = $Context.Operations.testClones
$folderNm = [string](Get-OpSetting $ops 'folder' 'Portal-TestClones')
$isoRule  = [string](Get-OpSetting $ops 'isolatedPortgroup' '')
$maxDays  = [int](Get-OpSetting $ops 'maxDays' 7)
$namePfx  = [string](Get-OpSetting $ops 'namePrefix' 'TST-')
$attrName = 'Portal.TestClone'

# ---- Pre-checks ---------------------------------------------------------------------------------
if ($DaysToKeep -lt 1 -or $DaysToKeep -gt $maxDays) { throw "DaysToKeep must be between 1 and $maxDays (operations.testClones.maxDays)." }
if (-not $CloneName) { $CloneName = "$namePfx$VMName" }
$CloneName = $CloneName.Trim()
if ($CloneName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{1,79}$') { throw "Clone name '$CloneName' is not valid (letters, digits, . _ -; 2-80 characters)." }
if ($CloneName -ieq $VMName) { throw 'The clone name must differ from the source VM name.' }

if ($isoRule) {
    $ok = $IsolatedPortGroup -ieq $isoRule
    if (-not $ok) { try { $ok = $IsolatedPortGroup -match $isoRule } catch { $ok = $false } }
    if (-not $ok) { throw "Port group '$IsolatedPortGroup' is not the approved isolated network ('$isoRule', operations.testClones.isolatedPortgroup)." }
}
else { Write-JobLog -Level WARN 'operations.testClones.isolatedPortgroup is not set: isolation of the chosen port group is not enforced by the portal.' }

$vm = Get-VM -Name $VMName -Server $vi -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $vm) { throw "Source VM '$VMName' was not found in $Site." }
if (Get-VM -Name $CloneName -Server $vi -ErrorAction SilentlyContinue) { throw "A VM named '$CloneName' already exists." }

$srcNics = @(Get-NetworkAdapter -VM $vm -Server $vi)
if ($srcNics | Where-Object { $_.NetworkName -eq $IsolatedPortGroup }) {
    throw "Port group '$IsolatedPortGroup' is used by the source VM; a test clone must be on an isolated network."
}
$pg = Get-VirtualPortGroup -Name $IsolatedPortGroup -Server $vi -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $pg) { throw "Port group '$IsolatedPortGroup' was not found." }
$isDistributed = [bool]($pg.PSObject.Properties['VDSwitch'] -or ([string]$pg.Key -like 'dvportgroup-*'))

$ds = Get-Datastore -Name $Datastore -Server $vi -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $ds) { throw "Datastore '$Datastore' was not found." }
$needGB = [math]::Ceiling([double]$vm.UsedSpaceGB * 1.1)
if ([double]$ds.FreeSpaceGB -lt $needGB) { throw "Datastore '$Datastore' has $([math]::Round($ds.FreeSpaceGB,1)) GB free; the clone needs about $needGB GB." }

$vmHost = Get-VMHost -VM $vm -Server $vi | Select-Object -First 1
$expires = (Get-Date).Date.AddDays($DaysToKeep).ToString('yyyy-MM-dd')
Write-JobLog -Level STEP "Cloning $VMName to $CloneName on $($vmHost.Name) / $Datastore (isolated network $IsolatedPortGroup, expires $expires, change $ChangeTicket)."
if ($vm.PowerState -eq 'PoweredOn') { Write-JobLog -Level WARN 'Source is powered on: the clone is crash-consistent.' }

$clone = $null
$nicReport = @()
try {
    $dc = Get-Datacenter -VM $vm -Server $vi
    $folder = Get-Folder -Name $folderNm -Location $dc -Type VM -Server $vi -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $folder) {
        $root = Get-Folder -Name 'vm' -Location $dc -Type VM -NoRecursion -Server $vi | Select-Object -First 1
        $folder = New-Folder -Name $folderNm -Location $root -Server $vi
        Write-JobLog "Created folder '$folderNm' in $($dc.Name)."
    }

    $clone = New-VM -VM $vm -Name $CloneName -VMHost $vmHost -Datastore $ds -Location $folder -Server $vi -Confirm:$false
    Write-JobLog -Level OK "Clone $CloneName created."

    $used = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $srcNics) { $null = $used.Add([string]$n.MacAddress) }
    foreach ($nic in @(Get-NetworkAdapter -VM $clone -Server $vi)) {
        $mac = New-ManualMac -Used $used
        $nic = Set-NetworkAdapter -NetworkAdapter $nic -MacAddress $mac -StartConnected:$true -Server $vi -Confirm:$false
        $nic = if ($isDistributed) { Set-NetworkAdapter -NetworkAdapter $nic -Portgroup $pg -Server $vi -Confirm:$false }
               else { Set-NetworkAdapter -NetworkAdapter $nic -NetworkName $IsolatedPortGroup -Server $vi -Confirm:$false }
        $nicReport += "$($nic.Name) = $mac on $IsolatedPortGroup"
        Write-JobLog "Adapter '$($nic.Name)': new MAC $mac, network $IsolatedPortGroup."
    }

    $attr = @(try { Get-CustomAttribute -Name $attrName -TargetType VirtualMachine -Server $vi -ErrorAction SilentlyContinue } catch { })
    if (-not $attr) { $null = New-CustomAttribute -Name $attrName -TargetType VirtualMachine -Server $vi; Write-JobLog "Created custom attribute '$attrName'." }
    $value = "$($Context.RequestId);expires=$expires"
    $null = Set-Annotation -Entity $clone -CustomAttribute $attrName -Value $value -Server $vi
    Write-JobLog -Level OK "Annotation $attrName = $value"

    if ($PowerOn) {
        $clone = Start-VM -VM $clone -Server $vi -Confirm:$false
        Write-JobLog -Level OK 'Clone powered on.'
    }
}
catch {
    $msg = $_.Exception.Message
    Write-JobLog -Level ERROR "Test clone failed: $msg"
    if ($clone -and $Context.RollbackOnFailure) {
        Write-JobLog -Level WARN "Rolling back: deleting $CloneName."
        try {
            $c = Get-VM -Name $CloneName -Server $vi -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($c -and $c.PowerState -ne 'PoweredOff') { $null = Stop-VM -VM $c -Server $vi -Confirm:$false }
            if ($c) { Remove-VM -VM $c -DeletePermanently -Server $vi -Confirm:$false }
        }
        catch { Write-JobLog -Level WARN "Rollback failed: $($_.Exception.Message)" }
    }
    throw "Test clone of $VMName failed: $msg"
}

return [ordered]@{
    SourceVM     = $VMName
    CloneName    = $CloneName
    Host         = [string]$vmHost.Name
    Datastore    = $Datastore
    Folder       = $folderNm
    Network      = $IsolatedPortGroup
    Nics         = @($nicReport)
    Expires      = $expires
    PoweredOn    = $PowerOn
    ChangeTicket = $ChangeTicket
    NextSteps    = @(
        "The clone carries the source's identity (hostname, IP): keep it on '$IsolatedPortGroup' only."
        "Delete $CloneName on or before $expires (annotation $attrName)."
    )
}
