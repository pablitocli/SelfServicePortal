#Requires -Version 7.2
<#
.SYNOPSIS
    Offline tests: dc-promote, spec-copy.
#>
. (Join-Path $PSScriptRoot '_TestHelpers.ps1')
Start-TestGroup 'Directory and platform admin (DC promotion, customization spec copy)'

#region DC promotion ------------------------------------------------------------------------------------------------
function Reset-Dc { param([string] $Role = '3', [string] $Domain = 'corp.example.com', [bool] $SnapFail = $false, [string] $Test = 'Success')
    $global:DcG = @{ role = $Role; domain = $Domain; ntds = 'absent'; sysvol = 'False|False'; boot = 1; promoted = $false }
    $global:DcCalls = [System.Collections.Generic.List[string]]::new(); $global:DcScripts = [System.Collections.Generic.List[string]]::new()
    $global:DcSnapFail = $SnapFail; $global:DcTest = $Test }
Reset-Dc
$global:DcVm = [pscustomobject]@{ Name = 'DC-NEW01'; PowerState = 'PoweredOn'; ExtensionData = [pscustomobject]@{ Guest = [pscustomobject]@{ ToolsRunningStatus = 'guestToolsRunning'; GuestFamily = 'windowsGuest' } } }
function global:Get-VM { param($Name, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) if ($Name -eq 'DC-NEW01') { $global:DcVm } }
function global:Get-VMGuest { param($VM, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) [pscustomobject]@{ State = 'Running'; GuestFamily = 'windowsGuest'; OSFullName = 'Microsoft Windows Server 2025' } }
function global:New-Snapshot { param($VM, $Name, $Description, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) if ($global:DcSnapFail) { throw 'Snapshot not allowed: insufficient space' }; $global:DcCalls.Add("New-Snapshot:$Name") }
function global:Restart-VMGuest { param($VM, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) $global:DcCalls.Add('Restart-VMGuest'); $global:DcG.boot++; if ($global:DcG.promoted) { $global:DcG.role = '4'; $global:DcG.ntds = 'Running'; $global:DcG.sysvol = 'True|True' } }
function global:Invoke-VMScript {
    param($VM, $Server, $GuestCredential, $ScriptText, $ScriptType, $ToolsWaitSecs, [Parameter(ValueFromRemainingArguments)] $Rest)
    $b = if ($ScriptText -match "FromBase64String\('([^']+)'\)") { [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1])) } else { $ScriptText }
    $global:DcScripts.Add($b); $g = $global:DcG
    $out = if ($b -match 'Install-WindowsFeature') { $global:DcCalls.Add('feature'); '__SSP_KV:feature=Success' }
           elseif ($b -match 'Test-ADDSDomainControllerInstallation') { $global:DcCalls.Add('test'); "__SSP_KV:test=$($global:DcTest)`n__SSP_KV:testMessage=$(if ($global:DcTest -ne 'Success') { 'The specified domain does not exist or could not be contacted.' })" }
           elseif ($b -match 'Install-ADDSDomainController') { $global:DcCalls.Add('promote'); $g.promoted = $true; "__SSP_KV:promote=Success`n__SSP_KV:promoteMessage=Operation completed successfully" }
           else { "__SSP_KV:role=$($g.role)`n__SSP_KV:domain=$($g.domain)`n__SSP_KV:ntds=$($g.ntds)`n__SSP_KV:sysvol=$($g.sysvol)`n__SSP_KV:boot=2026-10-22T0$($g.boot):00:00Z" }
    [pscustomobject]@{ ScriptOutput = "$out`n__SSP_EXIT=0"; ExitCode = 0 }
}
$dom = [pscredential]::new('CORP\da-admin', (ConvertTo-SecureString 'D0mainAdm!n' -AsPlainText -Force))
$dsrm = [pscredential]::new('dsrm', (ConvertTo-SecureString 'Dsrm$ecret9' -AsPlainText -Force))
function New-DcCtx { $c = New-TestContext -ItemId 'dc-promote'; $c | Add-Member -NotePropertyName DcWaitSeconds -NotePropertyValue 0; $c }
$p = @{ Site = 'DC1'; VMName = 'DC-NEW01'; Domain = 'corp.example.com'; DomainCredential = $dom; DsrmCredential = $dsrm; InstallDns = $true }

$r = Invoke-TestHandler -Handler 'Install-GuestDomainController.ps1' -Parameters ($p + @{ Mode = 'Check'; Context = (New-DcCtx) })
Assert-Test -Name 'DC: check mode reports the role, changes nothing' -Condition ($null -eq $r.Error -and $r.Result.Role -eq 'Member server' -and -not $global:DcCalls.Count) -Detail $r.Error
$r = Invoke-TestHandler -Handler 'Install-GuestDomainController.ps1' -Parameters ($p + @{ Mode = 'Promote'; ConfirmVMName = 'DC-NEW02'; Context = (New-DcCtx) })
Assert-Test -Name 'DC: promotion refused without the typed VM name' -Condition ($r.Error -match "Type the VM name" -and -not $global:DcCalls.Count) -Detail $r.Error
$r = Invoke-TestHandler -Handler 'Install-GuestDomainController.ps1' -Parameters ($p + @{ Mode = 'Promote'; ConfirmVMName = 'DC-NEW01'; AdSiteName = 'HQ'; Context = (New-DcCtx) })
Assert-Test -Name 'DC: snapshot, feature, prerequisite test, promotion, reboot - in that order' -Condition ($null -eq $r.Error -and (@($global:DcCalls | ForEach-Object { $_ -replace ':.*$', '' }) -join ',') -eq 'New-Snapshot,feature,test,promote,Restart-VMGuest' -and $r.Result.Role -eq 'Backup domain controller' -and $r.Result.Snapshot -like 'Pre-DCPromo-*') -Detail "$($r.Error) $($global:DcCalls -join ',')"
$promo = @($global:DcScripts | Where-Object { $_ -match 'Install-ADDSDomainController @a' })[0]
Assert-Test -Name 'DC: no reboot by AD DS, site and DNS passed, passwords only in the sensitive scripts' -Condition ($promo -match 'NoRebootOnCompletion:\$true' -and $promo -match "SiteName'\] = 'HQ'" -and $promo -match 'InstallDns = \$true' -and -not ($r.Log -match 'D0mainAdm!n|Dsrm\$ecret9') -and -not (@($global:DcScripts | Where-Object { $_ -match 'Dsrm\$ecret9' -and $_ -notmatch 'ADDSDeployment' }).Count))
Assert-Test -Name 'DC: next steps warn about the snapshot' -Condition ([bool](@($r.Result.NextSteps) -match 'never revert'))
Reset-Dc -Role '4'
$r = Invoke-TestHandler -Handler 'Install-GuestDomainController.ps1' -Parameters ($p + @{ Mode = 'Promote'; ConfirmVMName = 'DC-NEW01'; Context = (New-DcCtx) })
Assert-Test -Name 'DC: an existing DC is not promoted again' -Condition ($r.Error -match 'already a domain controller' -and -not $global:DcCalls.Count) -Detail $r.Error
Reset-Dc -Domain 'other.example.com'
$r = Invoke-TestHandler -Handler 'Install-GuestDomainController.ps1' -Parameters ($p + @{ Mode = 'Promote'; ConfirmVMName = 'DC-NEW01'; Context = (New-DcCtx) })
Assert-Test -Name 'DC: wrong domain refused' -Condition ($r.Error -match "joined to 'other.example.com'") -Detail $r.Error
Reset-Dc -SnapFail $true
$r = Invoke-TestHandler -Handler 'Install-GuestDomainController.ps1' -Parameters ($p + @{ Mode = 'Promote'; ConfirmVMName = 'DC-NEW01'; Context = (New-DcCtx) })
Assert-Test -Name 'DC: snapshot failure stops before any change' -Condition ($r.Error -match 'Snapshot failed, nothing was changed' -and -not ($global:DcCalls -contains 'feature')) -Detail $r.Error
Reset-Dc -Test 'Error'
$r = Invoke-TestHandler -Handler 'Install-GuestDomainController.ps1' -Parameters ($p + @{ Mode = 'Promote'; ConfirmVMName = 'DC-NEW01'; Context = (New-DcCtx) })
Assert-Test -Name 'DC: failed prerequisite test stops before the promotion' -Condition ($r.Error -match 'Prerequisite test failed' -and -not ($global:DcCalls -contains 'promote')) -Detail $r.Error
#endregion

#region Spec copy -----------------------------------------------------------------------------------------------------
$global:ScSpecs = @{ 'vc-dc1.test.local' = @{ 'WIN2025-BASE' = [pscustomobject]@{ Name = 'WIN2025-BASE'; OSType = 'Windows'; Type = 'Persistent' } }; 'vc-dc2.test.local' = @{} }
$global:ScCalls = [System.Collections.Generic.List[string]]::new()
function global:Get-OSCustomizationSpec { param($Name, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) $global:ScSpecs[$Server.Name][$Name] }
function global:New-OSCustomizationSpec { param($OSCustomizationSpec, $Name, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) $s = [pscustomobject]@{ Name = $Name; OSType = $OSCustomizationSpec.OSType; Type = 'Persistent' }; $global:ScSpecs[$Server.Name][$Name] = $s; $global:ScCalls.Add("New:$($Server.Name):$Name"); $s }
function global:Set-OSCustomizationSpec { param($OSCustomizationSpec, $AdminPassword, $DomainUsername, $DomainPassword, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) $global:ScCalls.Add("Set:$($OSCustomizationSpec.Name):admin=$([bool]$AdminPassword):domain=$DomainUsername") }
function global:Remove-OSCustomizationSpec { param($OSCustomizationSpec, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) $global:ScSpecs[$Server.Name].Remove($OSCustomizationSpec.Name); $global:ScCalls.Add("Remove:$($OSCustomizationSpec.Name)") }
function global:Connect-PortalVIServer { param($SiteCode) [pscustomobject]@{ Name = "vc-$($SiteCode.ToLower()).test.local" } }
function global:Disconnect-PortalVIServer { param($Server) $global:ScCalls.Add("Disconnect:$($Server.Name)") }
$adm = [pscredential]::new('Administrator', (ConvertTo-SecureString 'Sp3cAdminPw' -AsPlainText -Force))
$join = [pscredential]::new('CORP\svc-join', (ConvertTo-SecureString 'J0inPw!!' -AsPlainText -Force))
$ctx = New-TestContext -ItemId 'spec-copy'
$r = Invoke-TestHandler -Handler 'Copy-VsphereCustomizationSpec.ps1' -Parameters @{ SourceSite = 'DC1'; TargetSite = 'DC2'; SpecName = 'WIN2025-BASE'; AdminPassword = $adm; DomainJoinCredential = $join; Context = $ctx }
Assert-Test -Name 'Spec: copied to the target with admin and domain passwords set' -Condition ($null -eq $r.Error -and ($global:ScCalls -contains 'New:vc-dc2.test.local:WIN2025-BASE') -and ($global:ScCalls -contains 'Set:WIN2025-BASE:admin=True:domain=CORP\svc-join') -and ($global:ScCalls -contains 'Disconnect:vc-dc2.test.local')) -Detail "$($r.Error) $($global:ScCalls -join ',')"
$r = Invoke-TestHandler -Handler 'Copy-VsphereCustomizationSpec.ps1' -Parameters @{ SourceSite = 'DC1'; TargetSite = 'DC2'; SpecName = 'WIN2025-BASE'; AdminPassword = $adm; Context = (New-TestContext) }
Assert-Test -Name 'Spec: existing spec on the target kept without Overwrite' -Condition ($r.Error -match 'already exists') -Detail $r.Error
$ctx = New-TestContext -ItemId 'spec-copy'
$r = Invoke-TestHandler -Handler 'Copy-VsphereCustomizationSpec.ps1' -Parameters @{ SourceSite = 'DC1'; TargetSite = 'DC2'; SpecName = 'WIN2025-BASE'; AdminPassword = $adm; Overwrite = $true; Context = $ctx }
Assert-Test -Name 'Spec: overwrite saves the previous settings first' -Condition ($null -eq $r.Error -and $r.Result.Replaced -and ($global:ScCalls -contains 'Remove:WIN2025-BASE') -and ((Get-TestReportFiles -Context $ctx) -contains 'previous-spec-WIN2025-BASE.json')) -Detail $r.Error
$r = Invoke-TestHandler -Handler 'Copy-VsphereCustomizationSpec.ps1' -Parameters @{ SourceSite = 'DC1'; TargetSite = 'DC1'; SpecName = 'WIN2025-BASE'; AdminPassword = $adm; Context = (New-TestContext) }
Assert-Test -Name 'Spec: same source and target refused' -Condition ($r.Error -match 'must be different') -Detail $r.Error
$r = Invoke-TestHandler -Handler 'Copy-VsphereCustomizationSpec.ps1' -Parameters @{ SourceSite = 'DC1'; TargetSite = 'DC2'; SpecName = 'NOPE'; AdminPassword = $adm; Context = (New-TestContext) }
Assert-Test -Name 'Spec: unknown source spec refused' -Condition ($r.Error -match "'NOPE' was not found") -Detail $r.Error
#endregion

'Get-VM', 'Get-VMGuest', 'New-Snapshot', 'Restart-VMGuest', 'Invoke-VMScript', 'Get-OSCustomizationSpec', 'New-OSCustomizationSpec', 'Set-OSCustomizationSpec', 'Remove-OSCustomizationSpec', 'Connect-PortalVIServer', 'Disconnect-PortalVIServer' |
    ForEach-Object { Remove-Item "function:global:$_" -ErrorAction SilentlyContinue }
