#Requires -Version 7.2
<#
.SYNOPSIS
    Stores the vCenter service-account credential of a site in the portal SecretManagement vault.
.DESCRIPTION
    Run ONCE per site on the portal server, as the Windows account that runs the portal service,
    so the vault is readable by the job runners. Vault and secret names come from portal.config.json.
.EXAMPLE
    .\tools\Register-PortalCredential.ps1 -Site DC1
#>
[CmdletBinding()]
param([Parameter(Mandatory)] [string] $Site)

$root = Split-Path -Parent $PSScriptRoot
$env:SSP_PORTAL_ROOT = $root
Import-Module (Join-Path $root 'modules/Portal.Core.psm1') -Force

$s = Get-PortalSite -Code $Site
if (-not $s) { throw "Site $Site not found in portal.config.json." }
if ($s.credential.type -ne 'SecretManagement') { throw "Site $Site uses credential type '$($s.credential.type)'. This tool only handles SecretManagement." }

foreach ($m in 'Microsoft.PowerShell.SecretManagement', 'Microsoft.PowerShell.SecretStore') {
    if (-not (Get-Module -ListAvailable $m)) { throw "Module $m is not installed. Install-Module $m -Scope AllUsers" }
}
Import-Module Microsoft.PowerShell.SecretManagement, Microsoft.PowerShell.SecretStore

if (-not (Get-SecretVault -Name $s.credential.vault -ErrorAction SilentlyContinue)) {
    Write-Host "Registering vault '$($s.credential.vault)' (SecretStore)..."
    Register-SecretVault -Name $s.credential.vault -ModuleName Microsoft.PowerShell.SecretStore
    Write-Warning 'Configure the SecretStore for unattended use (Set-SecretStoreConfiguration -Authentication None) or use an enterprise vault extension.'
}

$cred = Get-Credential -Message "vCenter service account for $($s.code) ($($s.vcenter))"
Set-Secret -Vault $s.credential.vault -Name $s.credential.secret -Secret $cred
Write-Host "Credential stored as '$($s.credential.secret)' in vault '$($s.credential.vault)'." -ForegroundColor Green
