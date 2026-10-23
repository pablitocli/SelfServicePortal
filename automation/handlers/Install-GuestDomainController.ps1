#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - promotes a domain-joined Windows VM to an additional domain controller (or only checks its role).
.DESCRIPTION
    High-impact, hard-to-reverse change. Safeguards:
      * the VM must already be a member server of the SAME domain (DomainRole 3); a DC is never promoted twice;
      * the requester must type the VM name to confirm; the item requires approval and re-authentication;
      * a pre-promotion snapshot is mandatory - if it fails nothing is changed;
      * Test-ADDSDomainControllerInstallation must succeed before Install-ADDSDomainController runs.
    Secrets (domain admin and DSRM passwords) travel only inside the sensitive guest scripts (VMware Tools); no
    configuration file is written in the guest. Install-ADDSDomainController runs with -NoRebootOnCompletion and the
    portal restarts the guest itself, then verifies DomainRole, the NTDS service and the SYSVOL / NETLOGON shares.
    The snapshot is a safety net for a failed promotion only: never revert a DC snapshot after it has replicated
    (USN rollback). Delete it once replication is confirmed.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] [string] $VMName,
    [Parameter(Mandatory)] [ValidateSet('Check', 'Promote')] [string] $Mode,
    [Parameter(Mandatory)] [string] $Domain,
    [Parameter(Mandatory)] [pscredential] $DomainCredential,
    [pscredential] $DsrmCredential,
    [bool] $InstallDns = $true,
    [string] $AdSiteName,
    [string] $ReplicationSourceDC,
    [string] $ConfirmVMName,
    [string] $ChangeTicket,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}
Import-Module (Join-Path $Context.PortalRoot 'automation/lib/Portal.Guest.psm1') -Force -DisableNameChecking
$vi = $Context.VIServer
$waitSeconds = if ($Context.PSObject.Properties['DcWaitSeconds']) { [int]$Context.DcWaitSeconds } else { 20 }
$lit = { param($s) ConvertTo-PortalGuestLiteral $s }
if ($Domain -notmatch '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$') { throw "Domain '$Domain' must be a DNS domain name (e.g. corp.example.com)." }
foreach ($v in @($AdSiteName, $ReplicationSourceDC) | Where-Object { $_ }) { if ($v -notmatch '^[A-Za-z0-9._-]{1,64}$') { throw "'$v' is not a valid AD site / domain controller name." } }

$g = Resolve-PortalGuestVM -Name $VMName -Server $vi -ExpectedFamily windows -TimeoutSeconds 120
$roleScript = @'
$cs = Get-CimInstance Win32_ComputerSystem
Write-Output ('__SSP_KV:role=' + $cs.DomainRole)
Write-Output ('__SSP_KV:domain=' + $cs.Domain)
$ntds = Get-Service NTDS -ErrorAction SilentlyContinue
Write-Output ('__SSP_KV:ntds=' + $(if ($ntds) { [string]$ntds.Status } else { 'absent' }))
$shares = @(Get-CimInstance Win32_Share -ErrorAction SilentlyContinue | ForEach-Object Name)
Write-Output ('__SSP_KV:sysvol=' + [string]($shares -contains 'SYSVOL') + '|' + [string]($shares -contains 'NETLOGON'))
Write-Output ('__SSP_KV:boot=' + (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o'))
'@
function Get-Role { $o = Invoke-PortalGuestScript -VM $g.VM -Credential $DomainCredential -ScriptText $roleScript -Server $vi -TimeoutSeconds 120 -Description 'domain role (read-only)'; Get-PortalGuestData -Output $o }
$roleNames = @{ '0' = 'Standalone workstation'; '1' = 'Member workstation'; '2' = 'Standalone server'; '3' = 'Member server'; '4' = 'Backup domain controller'; '5' = 'Primary domain controller' }
$r0 = Get-Role
$roleText = $roleNames[[string]$r0['role']]
Write-JobLog "Current: $roleText in '$($r0['domain'])' (NTDS $($r0['ntds']))"

if ($Mode -eq 'Check') {
    return [ordered]@{ VM = $VMName; Role = $roleText; Domain = $r0['domain']; NTDS = $r0['ntds']; 'SYSVOL|NETLOGON shared' = $r0['sysvol'] }
}

# ---- Promote: pre-checks ------------------------------------------------------------------------
if ($ConfirmVMName -ne $VMName) { throw "Type the VM name '$VMName' in the confirmation field to promote it." }
if (-not $DsrmCredential) { throw 'A DSRM (Directory Services Restore Mode) password from the vault is required.' }
if ([string]$r0['role'] -in '4', '5') { throw "$VMName is already a domain controller ($roleText)." }
if ([string]$r0['role'] -ne '3') { throw "$VMName is a $roleText; only a member server can be promoted." }
if (([string]$r0['domain']).ToLower() -ne $Domain.ToLower()) { throw "$VMName is joined to '$($r0['domain'])', not '$Domain'." }

$snapName = 'Pre-DCPromo-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
Write-JobLog -Level STEP "Mandatory snapshot $snapName"
try { $null = New-Snapshot -VM $g.VM -Name $snapName -Description "Safety snapshot before promotion to DC of $Domain (request $($Context.RequestId)). Delete after replication is confirmed; never revert after replication." -Server $vi -Confirm:$false -ErrorAction Stop }
catch { throw "Snapshot failed, nothing was changed: $($_.Exception.Message)" }

$secrets = @($DomainCredential.GetNetworkCredential().Password, $DsrmCredential.GetNetworkCredential().Password)
Write-JobLog -Level STEP 'Installing the AD DS role'
$null = Invoke-PortalGuestScript -VM $g.VM -Credential $DomainCredential -Server $vi -TimeoutSeconds 1800 -Description 'install AD-Domain-Services' -ScriptText @'
$r = Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
if (-not $r.Success) { throw ('Install-WindowsFeature failed: ' + $r.ExitCode) }
Write-Output ('__SSP_KV:feature=' + $r.ExitCode)
'@

$common = @"
`$c = New-Object System.Management.Automation.PSCredential($(& $lit $DomainCredential.UserName), (ConvertTo-SecureString $(& $lit $DomainCredential.GetNetworkCredential().Password) -AsPlainText -Force))
`$dsrm = ConvertTo-SecureString $(& $lit $DsrmCredential.GetNetworkCredential().Password) -AsPlainText -Force
`$a = @{ DomainName = $(& $lit $Domain); Credential = `$c; SafeModeAdministratorPassword = `$dsrm; InstallDns = `$$($InstallDns.ToString().ToLower()); Force = `$true; WarningAction = 'SilentlyContinue' }
$(if ($AdSiteName) { "`$a['SiteName'] = $(& $lit $AdSiteName)" })
$(if ($ReplicationSourceDC) { "`$a['ReplicationSourceDC'] = $(& $lit $ReplicationSourceDC)" })
Import-Module ADDSDeployment
"@
Write-JobLog -Level STEP 'Prerequisite test (Test-ADDSDomainControllerInstallation)'
$t = Invoke-PortalGuestScript -VM $g.VM -Credential $DomainCredential -Server $vi -TimeoutSeconds 900 -Description 'AD DS prerequisite test' -Sensitive -Secrets $secrets -ScriptText ($common + @'
$t = Test-ADDSDomainControllerInstallation @a
Write-Output ('__SSP_KV:test=' + [string]$t.Status)
Write-Output ('__SSP_KV:testMessage=' + (([string]$t.Message) -replace '\s+', ' '))
'@)
$td = Get-PortalGuestData -Output $t
if ([string]$td['test'] -ne 'Success') { throw "Prerequisite test failed, nothing promoted (snapshot $snapName kept): $($td['testMessage'])" }

Write-JobLog -Level STEP "Promoting $VMName (Install-ADDSDomainController, this takes several minutes)"
$p = Invoke-PortalGuestScript -VM $g.VM -Credential $DomainCredential -Server $vi -TimeoutSeconds 3600 -Description 'Install-ADDSDomainController' -Sensitive -Secrets $secrets -ScriptText ($common + @'
$r = Install-ADDSDomainController @a -NoRebootOnCompletion:$true -Confirm:$false
Write-Output ('__SSP_KV:promote=' + [string]$r.Status)
Write-Output ('__SSP_KV:promoteMessage=' + (([string]$r.Message) -replace '\s+', ' '))
'@)
$pd = Get-PortalGuestData -Output $p
if ([string]$pd['promote'] -ne 'Success') { throw "Promotion failed (snapshot $snapName kept for rollback; the VM did not replicate as a DC): $($pd['promoteMessage'])" }

Write-JobLog -Level STEP 'Restarting the guest'
$null = Restart-VMGuest -VM $g.VM -Server $vi -Confirm:$false
$deadline = (Get-Date).AddMinutes(30); $r1 = $null
do {
    Start-Sleep -Seconds $waitSeconds
    try { $r1 = Get-Role } catch { $r1 = $null }
    $back = $r1 -and [string]$r1['boot'] -ne [string]$r0['boot']
    $ready = $back -and [string]$r1['role'] -in '4', '5' -and [string]$r1['ntds'] -eq 'Running' -and [string]$r1['sysvol'] -eq 'True|True'
} until ($ready -or (Get-Date) -gt $deadline)
if (-not $ready) {
    $state = if ($r1) { "role $($roleNames[[string]$r1['role']]), NTDS $($r1['ntds']), SYSVOL|NETLOGON $($r1['sysvol'])" } else { 'guest not reachable' }
    throw "Promotion finished but the DC is not ready after 30 minutes ($state). Check replication (repadmin /showrepl) before any rollback."
}
Write-JobLog -Level OK "$VMName is now a $($roleNames[[string]$r1['role']]) of $Domain."
return [ordered]@{
    VM = $VMName; Domain = $Domain; Role = $roleNames[[string]$r1['role']]; DNS = $InstallDns; Snapshot = $snapName; ChangeTicket = $ChangeTicket
    NextSteps = @('Confirm replication (repadmin /replsummary, dcdiag) and DNS registration.', "Delete snapshot $snapName once replication is confirmed - never revert a DC after it replicated.")
}
