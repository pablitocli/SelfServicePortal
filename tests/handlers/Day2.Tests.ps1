#Requires -Version 7.2
<#
.SYNOPSIS
    Offline tests: guest-local-groups, guest-data-disks, vm-move-folder, ad-move-computer, vm-power (batch).
#>
. (Join-Path $PSScriptRoot '_TestHelpers.ps1')
Start-TestGroup 'Day 2 (local groups, data disks, folders, AD OU, batch power)'

#region Stubs ---------------------------------------------------------------------------------------------------
function New-D2Vm([string] $Name, [string] $Power = 'PoweredOn', [string] $Tools = 'guestToolsRunning', [string] $Family = 'windowsGuest', [string] $FolderId = 'Folder-old') {
    [pscustomobject]@{ Name = $Name; Id = "VirtualMachine-$Name"; PowerState = $Power; FolderId = $FolderId; Folder = [pscustomobject]@{ Name = 'Discovered virtual machine' }
                       ExtensionData = [pscustomobject]@{ Guest = [pscustomobject]@{ ToolsRunningStatus = $Tools; GuestFamily = $Family } } }
}
$global:D2Vms = @{
    'WIN-01' = (New-D2Vm 'WIN-01'); 'WIN-02' = (New-D2Vm 'WIN-02'); 'LNX-01' = (New-D2Vm 'LNX-01' -Family 'linuxGuest')
    'OFF-01' = (New-D2Vm 'OFF-01' 'PoweredOff' 'guestToolsNotRunning'); 'HUNG-01' = (New-D2Vm 'HUNG-01' 'PoweredOn' 'guestToolsNotRunning'); 'IN-01' = (New-D2Vm 'IN-01' -FolderId 'Folder-target')
}
$global:D2Calls = [System.Collections.Generic.List[string]]::new()
$global:D2Scripts = [System.Collections.Generic.List[string]]::new()
$global:D2GuestOut = ''
function global:Get-VM { param($Name, $Id, $Server, [Parameter(ValueFromRemainingArguments)] $Rest)
    if ($Id) { return ($global:D2Vms.Values | Where-Object Id -eq $Id) }
    if ($global:D2Vms.ContainsKey($Name)) { $global:D2Vms[$Name] } }
function global:Get-VMGuest { param($VM, $Server, [Parameter(ValueFromRemainingArguments)] $Rest)
    [pscustomobject]@{ State = 'Running'; GuestFamily = $VM.ExtensionData.Guest.GuestFamily; OSFullName = $(if ($VM.ExtensionData.Guest.GuestFamily -match 'linux') { 'AlmaLinux 9' } else { 'Microsoft Windows Server 2025' }) } }
function global:Invoke-VMScript {
    param($VM, $Server, $GuestCredential, $ScriptText, $ScriptType, $ToolsWaitSecs, [Parameter(ValueFromRemainingArguments)] $Rest)
    $body = if ($ScriptText -match "FromBase64String\('([^']+)'\)") { [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1])) } else { $ScriptText }
    $global:D2Scripts.Add($body)
    $out = if ($global:D2GuestOut -is [scriptblock]) { & $global:D2GuestOut $VM.Name } else { $global:D2GuestOut }
    [pscustomobject]@{ ScriptOutput = "$out`n__SSP_EXIT=0"; ExitCode = 0 }
}
function global:Get-Datacenter { param($Name, $VM, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) [pscustomobject]@{ Name = 'DC-MAIN' } }
function global:Get-Folder { param($Name, $Location, $Type, [switch] $NoRecursion, $Server, [Parameter(ValueFromRemainingArguments)] $Rest)
    switch ($Name) { 'vm' { [pscustomobject]@{ Name = 'vm'; Id = 'Folder-vm' } } 'Apps' { [pscustomobject]@{ Name = 'Apps'; Id = 'Folder-apps' } } 'Prod' { [pscustomobject]@{ Name = 'Prod'; Id = 'Folder-target' } } default { $null } } }
function global:Move-VM { param($VM, $InventoryLocation, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) $global:D2Calls.Add("Move-VM:$($VM.Name)->$($InventoryLocation.Name)") }
function global:Start-VM { param($VM, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) $global:D2Calls.Add("Start-VM:$($VM.Name)"); $VM.PowerState = 'PoweredOn' }
function global:Stop-VMGuest { param($VM, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) $global:D2Calls.Add("Stop-VMGuest:$($VM.Name)"); $VM.PowerState = 'PoweredOff' }
function global:Restart-VMGuest { param($VM, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) $global:D2Calls.Add("Restart-VMGuest:$($VM.Name)") }
function global:Restart-VM { param($VM, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) $global:D2Calls.Add("Restart-VM:$($VM.Name)") }
$cred = [pscredential]::new('CORP\svc-build', (ConvertTo-SecureString 'B@dPassw0rdX' -AsPlainText -Force))
function Test-D2Parse([string] $Text) { $t = $null; $e = $null; $null = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$t, [ref]$e); return @($e).Count -eq 0 }
#endregion

#region Local groups ------------------------------------------------------------------------------------------------
$global:D2GuestOut = { param($vm) if ($vm -eq 'WIN-01') { "RES|Administrators|CORP\SQL-Admins|PRESENT|`nRES|Administrators|CORP\jdoe|ADDED|`nRES|Remote Desktop Users|CORP\SQL-Admins|ADDED|`nRES|Remote Desktop Users|CORP\jdoe|ADDED|" } else { "RES|Administrators|CORP\SQL-Admins|FAILED|The specified account name is not valid.`nRES|Administrators|CORP\jdoe|ADDED|" } }
$ctx = New-TestContext -ItemId 'guest-local-groups'
$r = Invoke-TestHandler -Handler 'Set-GuestLocalGroupMembers.ps1' -Parameters @{ Site = 'DC1'; VMNames = "WIN-01`nWIN-02, LNX-01"; Group = 'Both'; Accounts = "CORP\SQL-Admins`r`nCORP\jdoe"; GuestCredential = $cred; Context = $ctx }
Assert-Test -Name 'Groups: added / present / failed per VM, Linux VM refused' -Condition ($null -eq $r.Error -and $r.Result.Added -eq 4 -and $r.Result.AlreadyPresent -eq 1 -and $r.Result.Failed -eq 2 -and ($r.Result.FailedItems -match 'LNX-01.*windows guest')) -Detail "$($r.Error) $($r.Result | ConvertTo-Json -Compress)"
$s = $global:D2Scripts[0]
Assert-Test -Name 'Groups: script uses well-known SIDs, quotes accounts, parses' -Condition ($s -match "'S-1-5-32-544', 'S-1-5-32-555'" -and $s -match "'CORP\\SQL-Admins'" -and (Test-D2Parse $s) -and $s -notmatch 'Remove') -Detail $s
Assert-Test -Name 'Groups: password not in script or log' -Condition (-not ($global:D2Scripts -match 'B@dPassw0rdX') -and -not ($r.Log -match 'B@dPassw0rdX'))
$global:D2Scripts.Clear(); $global:D2GuestOut = 'RES|Administrators|CORP\x|MISSING|'
$r = Invoke-TestHandler -Handler 'Set-GuestLocalGroupMembers.ps1' -Parameters @{ Site = 'DC1'; VMNames = 'WIN-01'; Group = 'Administrators'; Accounts = 'CORP\x'; GuestCredential = $cred; ReportOnly = $true; Context = (New-TestContext) }
Assert-Test -Name 'Groups: report only lists missing, script in read mode' -Condition ($null -eq $r.Error -and @($r.Result.Missing).Count -eq 1 -and $global:D2Scripts[0] -match '\$reportOnly = \$true') -Detail $r.Error
$r = Invoke-TestHandler -Handler 'Set-GuestLocalGroupMembers.ps1' -Parameters @{ Site = 'DC1'; VMNames = 'WIN-01'; Group = 'Administrators'; Accounts = "CORP\x'; Remove-Item C:\ -Recurse #"; GuestCredential = $cred; Context = (New-TestContext) }
Assert-Test -Name 'Groups: injection attempt in account rejected' -Condition ($r.Error -match 'is not valid') -Detail $r.Error
#endregion

#region Data disks ------------------------------------------------------------------------------------------------
$global:D2Scripts.Clear(); $global:D2GuestOut = "RES|D|PLAN|disk 1 100 GB (RAW, Offline) - CD-ROM moved off D:`nRES|L|PLAN|disk 2 50 GB (GPT, Online)"
$ctx = New-TestContext -ItemId 'guest-data-disks'
$r = Invoke-TestHandler -Handler 'Initialize-GuestDataDisks.ps1' -Parameters @{ Site = 'DC1'; VMNames = 'WIN-01'; DriveLetters = 'd, L'; Labels = 'Data,Logs'; AllocationUnit = '64K'; GuestCredential = $cred; Context = $ctx }
$s = $global:D2Scripts[0]
Assert-Test -Name 'Disks: dry run by default returns the plan' -Condition ($null -eq $r.Error -and $r.Result.DryRun -and @($r.Result.Details | Where-Object { $_ -match 'PLAN' }).Count -eq 2 -and $r.Result.NextSteps) -Detail $r.Error
Assert-Test -Name 'Disks: script has letters, labels, 64K, dry flag, and parses' -Condition ($s -match "\`$letters = @\('D', 'L'\)" -and $s -match "'Data', 'Logs'" -and $s -match '\$au = 65536' -and $s -match '\$dry = \$true' -and (Test-D2Parse $s)) -Detail $s
Assert-Test -Name 'Disks: only partition-less, non-boot disks are candidates' -Condition ($s -match 'IsBoot' -and $s -match 'IsSystem' -and $s -match "Type\] -ne 'Reserved'|Type -ne 'Reserved'|\.Type -ne 'Reserved'")
$global:D2Scripts.Clear(); $global:D2GuestOut = "RES|D|OK|disk 1 100 GB formatted NTFS 100 GB label DataD`nRES|E|SKIP|already exists (50 GB NTFS)"
$r = Invoke-TestHandler -Handler 'Initialize-GuestDataDisks.ps1' -Parameters @{ Site = 'DC1'; VMNames = 'WIN-01'; DriveLetters = 'D,E'; GuestCredential = $cred; DryRun = $false; Context = (New-TestContext) }
Assert-Test -Name 'Disks: formatted and skipped counted' -Condition ($null -eq $r.Error -and $r.Result.Formatted -eq 1 -and $r.Result.Skipped -eq 1 -and $global:D2Scripts[0] -match '\$dry = \$false') -Detail $r.Error
$r = Invoke-TestHandler -Handler 'Initialize-GuestDataDisks.ps1' -Parameters @{ Site = 'DC1'; VMNames = 'WIN-01'; DriveLetters = 'C'; GuestCredential = $cred; Context = (New-TestContext) }
Assert-Test -Name 'Disks: system letter refused' -Condition ($r.Error -match "'C' is not valid") -Detail $r.Error
$r = Invoke-TestHandler -Handler 'Initialize-GuestDataDisks.ps1' -Parameters @{ Site = 'DC1'; VMNames = 'WIN-01'; DriveLetters = 'D'; Labels = "x';evil"; GuestCredential = $cred; Context = (New-TestContext) }
Assert-Test -Name 'Disks: invalid label refused' -Condition ($r.Error -match 'label') -Detail $r.Error
#endregion

#region Move to folder -----------------------------------------------------------------------------------------------
$global:D2Calls.Clear()
$r = Invoke-TestHandler -Handler 'Move-VsphereVmFolder.ps1' -Parameters @{ Site = 'DC1'; VMNames = 'WIN-01, IN-01, NOPE'; Folder = 'DC-MAIN/Apps/Prod'; Context = (New-TestContext) }
Assert-Test -Name 'Folder: moved, already there, not found' -Condition ($null -eq $r.Error -and $r.Result.Moved -eq 1 -and $r.Result.AlreadyThere -eq 1 -and $r.Result.Failed -eq 1 -and $global:D2Calls -contains 'Move-VM:WIN-01->Prod') -Detail "$($r.Error) $($r.Result.Details -join ' | ')"
$r = Invoke-TestHandler -Handler 'Move-VsphereVmFolder.ps1' -Parameters @{ Site = 'DC1'; VMNames = 'WIN-01'; Folder = 'DC-MAIN/Apps/Missing'; Context = (New-TestContext) }
Assert-Test -Name 'Folder: unknown folder refused' -Condition ($r.Error -match "missing 'Missing'") -Detail $r.Error
$r = Invoke-TestHandler -Handler 'Move-VsphereVmFolder.ps1' -Parameters @{ Site = 'DC1'; VMNames = 'NOPE'; Folder = 'DC-MAIN/Apps'; Context = (New-TestContext) }
Assert-Test -Name 'Folder: fails when no VM could be moved' -Condition ($r.Error -match 'No VM was moved') -Detail $r.Error
#endregion

#region AD move -------------------------------------------------------------------------------------------------------
$global:D2Ad = [ordered]@{
    'OU=Prod,OU=Servers,DC=corp,DC=example,DC=com' = 'ou'
    'CN=SQL01,OU=Staging,DC=corp,DC=example,DC=com' = 'SQL01$'
    'CN=SQL02,OU=Prod,OU=Servers,DC=corp,DC=example,DC=com' = 'SQL02$'
}
$global:D2Moves = [System.Collections.Generic.List[string]]::new()
function global:Connect-PortalDirectory {
    param($ProviderId, $Credential)
    if ($ProviderId -ne 'ad') { throw "Directory '$ProviderId' is not an enabled identity provider (Admin > Identity)." }
    $o = [pscustomobject]@{ BaseDn = 'DC=corp,DC=example,DC=com' }
    $o | Add-Member ScriptMethod Search { param($Base, $Filter, $Scope, $Attributes, $SizeLimit)
        if ($Scope -eq 'Base') { if ($global:D2Ad.Contains($Base) -and $global:D2Ad[$Base] -eq 'ou') { [pscustomobject]@{ dn = $Base } }; return }
        foreach ($k in $global:D2Ad.Keys) { if ($Filter -match [regex]::Escape("sAMAccountName=$($global:D2Ad[$k])")) { [pscustomobject]@{ dn = $k } } } }
    $o | Add-Member ScriptMethod Move { param($Dn, $Parent) $global:D2Moves.Add("$Dn => $Parent") }
    $o | Add-Member ScriptMethod Close { }
    return $o
}
Import-Module (Join-Path $global:SspHandlerTestRoot 'automation/lib/Portal.Directory.psm1') -Function ConvertTo-PortalDirectoryFilterValue, Get-PortalDirectoryParent -Force -Global
$ctx = New-TestContext -ItemId 'ad-move-computer' -NoVCenter
$r = Invoke-TestHandler -Handler 'Move-AdComputerOu.ps1' -Parameters @{ Directory = 'ad'; ComputerNames = "sql01.corp.example.com`nSQL02`nSQL99"; TargetOU = 'OU=Prod,OU=Servers,DC=corp,DC=example,DC=com'; DirectoryCredential = $cred; Context = $ctx }
Assert-Test -Name 'AD: moved, already there, not found' -Condition ($null -eq $r.Error -and $r.Result.Moved -eq 1 -and $r.Result.AlreadyThere -eq 1 -and $r.Result.Failed -eq 1) -Detail "$($r.Error) $($r.Result.Details -join ' | ')"
Assert-Test -Name 'AD: previous OU reported for revert' -Condition (($r.Result.Details -match 'SQL01: OK moved \(was OU=Staging') -and $global:D2Moves[0] -eq 'CN=SQL01,OU=Staging,DC=corp,DC=example,DC=com => OU=Prod,OU=Servers,DC=corp,DC=example,DC=com') -Detail ($r.Result.Details -join ' | ')
$r = Invoke-TestHandler -Handler 'Move-AdComputerOu.ps1' -Parameters @{ Directory = 'ad'; ComputerNames = 'SQL01'; TargetOU = 'OU=Other,DC=evil,DC=com'; DirectoryCredential = $cred; Context = $ctx }
Assert-Test -Name 'AD: OU outside the base DN refused' -Condition ($r.Error -match 'outside the directory base DN') -Detail $r.Error
$r = Invoke-TestHandler -Handler 'Move-AdComputerOu.ps1' -Parameters @{ Directory = 'ad'; ComputerNames = 'SQL01'; TargetOU = 'OU=Gone,DC=corp,DC=example,DC=com'; DirectoryCredential = $cred; Context = $ctx }
Assert-Test -Name 'AD: missing OU refused' -Condition ($r.Error -match 'was not found') -Detail $r.Error
$r = Invoke-TestHandler -Handler 'Move-AdComputerOu.ps1' -Parameters @{ Directory = 'ad'; ComputerNames = 'SQL01)(cn=*'; TargetOU = 'OU=Prod,OU=Servers,DC=corp,DC=example,DC=com'; DirectoryCredential = $cred; Context = $ctx }
Assert-Test -Name 'AD: LDAP filter injection rejected by name validation' -Condition ($r.Error -match 'not a valid computer name') -Detail $r.Error
Assert-Test -Name 'AD: filter value escaping' -Condition ((ConvertTo-PortalDirectoryFilterValue 'a*(b)\c') -eq 'a\2a\28b\29\5cc')
#endregion

#region Batch power ----------------------------------------------------------------------------------------------------
$global:D2Calls.Clear()
$ctx = New-TestContext -ItemId 'vm-power'; $ctx | Add-Member -NotePropertyName PowerWaitSeconds -NotePropertyValue 0
$r = Invoke-TestHandler -Handler 'Invoke-VsphereVmPower.ps1' -Parameters @{ Site = 'DC1'; VMName = 'WIN-01'; AdditionalVMs = "WIN-02`nHUNG-01`nOFF-01"; Action = 'Restart'; ResetIfToolsDown = $true; Context = $ctx }
Assert-Test -Name 'Power: batch restart with reset fallback, powered-off VM reported' -Condition ($null -eq $r.Error -and $r.Result.VMs -eq 4 -and $r.Result.Succeeded -eq 3 -and $r.Result.Failed -eq 1 -and $global:D2Calls -contains 'Restart-VMGuest:WIN-01' -and $global:D2Calls -contains 'Restart-VM:HUNG-01') -Detail "$($r.Error) $($r.Result.Details -join ' | ')"
$global:D2Calls.Clear()
$r = Invoke-TestHandler -Handler 'Invoke-VsphereVmPower.ps1' -Parameters @{ Site = 'DC1'; VMName = 'HUNG-01'; Action = 'Restart'; Context = $ctx }
Assert-Test -Name 'Power: no silent hard reset without the option' -Condition ($r.Error -match 'Tools not running' -and -not ($global:D2Calls -match 'Restart-VM:')) -Detail $r.Error
$r = Invoke-TestHandler -Handler 'Invoke-VsphereVmPower.ps1' -Parameters @{ Site = 'DC1'; VMName = 'OFF-01'; Action = 'Start'; ChangeTicket = 'CHG1'; Context = $ctx }
Assert-Test -Name 'Power: single VM keeps the original result shape' -Condition ($null -eq $r.Error -and $r.Result.PowerStateBefore -eq 'PoweredOff' -and $r.Result.PowerStateAfter -eq 'PoweredOn' -and $r.Result.ChangeTicket -eq 'CHG1') -Detail $r.Error
#endregion

'Get-VM', 'Get-VMGuest', 'Invoke-VMScript', 'Get-Datacenter', 'Get-Folder', 'Move-VM', 'Start-VM', 'Stop-VMGuest', 'Restart-VMGuest', 'Restart-VM', 'Connect-PortalDirectory' |
    ForEach-Object { Remove-Item "function:global:$_" -ErrorAction SilentlyContinue }
