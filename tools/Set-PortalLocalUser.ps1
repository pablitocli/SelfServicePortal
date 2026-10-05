#Requires -Version 7.2
<#
.SYNOPSIS
    Command-line management of local portal accounts (same logic as Admin > Local users in the portal).
.EXAMPLE
    .\tools\Set-PortalLocalUser.ps1 -Username admin                      # reset password (prompt)
.EXAMPLE
    .\tools\Set-PortalLocalUser.ps1 -Username ops1 -Roles Requester      # new user (prompts for password)
.EXAMPLE
    .\tools\Set-PortalLocalUser.ps1 -Username breakglass -Roles Admin -BreakGlass     # emergency account (works when local sign-in is disabled)
.EXAMPLE
    .\tools\Set-PortalLocalUser.ps1 -Username admin -Unlock -ResetMfa                  # clear lockout and authenticator
.EXAMPLE
    .\tools\Set-PortalLocalUser.ps1 -Username ops1 -Disable
.EXAMPLE
    .\tools\Set-PortalLocalUser.ps1 -Username ops1 -Remove
#>
[CmdletBinding(DefaultParameterSetName = 'Set')]
param(
    [Parameter(Mandatory)] [string] $Username,
    [Parameter(ParameterSetName = 'Set')] [ValidateSet('Requester', 'Approver', 'Admin', 'CatalogAdmin', 'SecurityAdmin', 'VaultAdmin')] [string[]] $Roles,
    [Parameter(ParameterSetName = 'Set')] [string[]] $Teams,
    [Parameter(ParameterSetName = 'Set')] [string] $DisplayName,
    [Parameter(ParameterSetName = 'Set')] [securestring] $Password,
    [Parameter(ParameterSetName = 'Set')] [switch] $NoPasswordChange,     # do not force a change at next sign-in
    [Parameter(ParameterSetName = 'Set')] [switch] $BreakGlass,
    [Parameter(ParameterSetName = 'Set')] [switch] $Unlock,
    [Parameter(ParameterSetName = 'Set')] [switch] $ResetMfa,
    [Parameter(ParameterSetName = 'Disable')] [switch] $Disable,
    [Parameter(ParameterSetName = 'Remove')] [switch] $Remove
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$env:SSP_PORTAL_ROOT = $root
Import-Module (Join-Path $root 'modules/Portal.Core.psm1') -Force
Import-Module (Join-Path $root 'modules/Portal.Security.psm1') -Force
Import-Module (Join-Path $root 'modules/Portal.Vault.psm1') -Force
Import-Module (Join-Path $root 'modules/Portal.Identity.psm1') -Force
Import-Module (Join-Path $root 'modules/Portal.Auth.psm1') -Force
$actor = "CLI\$([Environment]::UserName)"

switch ($PSCmdlet.ParameterSetName) {
    'Remove'  { Remove-PortalLocalUserEntry -Username $Username -Actor $actor; Write-Host "Removed '$Username'." -ForegroundColor Green }
    'Disable' { Set-PortalLocalUserEntry -Username $Username -Enabled $false -Actor $actor; Write-Host "Disabled '$Username'." -ForegroundColor Green }
    default {
        if ($Unlock)   { Clear-PortalLockout -Key ('u:' + $Username.ToLowerInvariant()) -Actor $actor; Get-PortalLockoutList | Where-Object kind -eq 'ip' | ForEach-Object { Clear-PortalLockout -Key $_.key -Actor $actor }; Write-Host "Unlocked '$Username'." -ForegroundColor Green }
        if ($ResetMfa) { Reset-PortalMfa -Username "LOCAL\$Username" -Actor $actor; Revoke-PortalSession -Username "LOCAL\$Username" -Actor $actor; Write-Host "Authenticator removed for '$Username'." -ForegroundColor Green }
        if (($Unlock -or $ResetMfa) -and -not ($Password -or $Roles -or $Teams -or $DisplayName -or $BreakGlass)) { break }
        if (-not $Password) { $Password = Read-Host -AsSecureString "Password for $Username" }
        $plain = [System.Net.NetworkCredential]::new('', $Password).Password
        $splat = @{ Username = $Username; Password = $plain; Enabled = $true; Actor = $actor }
        if ($Roles)            { $splat['Roles'] = $Roles }
        if ($Teams)            { $splat['Teams'] = $Teams }
        if ($DisplayName)      { $splat['DisplayName'] = $DisplayName }
        if ($NoPasswordChange) { $splat['MustChangePassword'] = $false }
        if ($BreakGlass)       { $splat['BreakGlass'] = $true }
        Set-PortalLocalUserEntry @splat
        Write-Host "Saved '$Username'." -ForegroundColor Green
    }
}
