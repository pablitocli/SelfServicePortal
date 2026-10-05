#Requires -Version 7.2
<#
.SYNOPSIS
    Installs every PowerShell module the portal needs, for all users (run once, elevated, from pwsh).
.DESCRIPTION
    Core     : Pode
    vSphere  : VMware.PowerCLI
    AWS      : AWS.Tools.Common, AWS.Tools.EC2, AWS.Tools.SecurityToken, AWS.Tools.SimpleSystemsManagement
    Azure    : Az.Accounts, Az.Compute, Az.Network, Az.Resources, Az.KeyVault, Az.MarketplaceOrdering
    Use -Skip Aws / Azure to leave a provider out. Already installed modules are skipped.
.EXAMPLE
    pwsh -File .\tools\Install-PortalPrerequisites.ps1
#>
[CmdletBinding()]
param([ValidateSet('Aws', 'Azure', 'VSphere')] [string[]] $Skip = @())

$ErrorActionPreference = 'Stop'
$isAdmin = if ($IsWindows) { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } else { $true }
if (-not $isAdmin) { throw 'Run this script from an elevated pwsh session (modules are installed for all users).' }

$sets = [ordered]@{
    Core    = @('Pode')
    VSphere = @('VMware.PowerCLI')
    Aws     = @('AWS.Tools.Common', 'AWS.Tools.EC2', 'AWS.Tools.SecurityToken', 'AWS.Tools.SimpleSystemsManagement')
    Azure   = @('Az.Accounts', 'Az.Compute', 'Az.Network', 'Az.Resources', 'Az.KeyVault', 'Az.MarketplaceOrdering')
}
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
foreach ($set in $sets.Keys) {
    if ($Skip -contains $set) { Write-Host "Skipping $set" -ForegroundColor DarkGray; continue }
    foreach ($m in $sets[$set]) {
        if (Get-Module -ListAvailable -Name $m) { Write-Host "[ok]      $m" -ForegroundColor Green; continue }
        Write-Host "[install] $m" -ForegroundColor Yellow
        Install-Module -Name $m -Scope AllUsers -Force -AllowClobber -AcceptLicense
    }
}
if ($Skip -notcontains 'VSphere') {
    Import-Module VMware.VimAutomation.Core
    $null = Set-PowerCLIConfiguration -Scope AllUsers -ParticipateInCEIP $false -InvalidCertificateAction Ignore -Confirm:$false
}
Write-Host 'Prerequisites ready.' -ForegroundColor Green
