#Requires -Version 7.2
<#
.SYNOPSIS
    Portal.CloudConnect - authenticates job runners against AWS / Azure using the portal cloud settings.
.DESCRIPTION
    Required modules on the portal server (AllUsers, from pwsh):
      AWS  : AWS.Tools.Common, AWS.Tools.EC2, AWS.Tools.SecurityToken, AWS.Tools.SimpleSystemsManagement
      Azure: Az.Accounts, Az.Compute, Az.Network, Az.Resources, Az.KeyVault, Az.MarketplaceOrdering
#>

Set-StrictMode -Version Latest

function Get-CC {
    param($Table, [string] $Key, $Default = $null)
    if ($Table -is [System.Collections.IDictionary] -and $Table.Contains($Key) -and $null -ne $Table[$Key]) { return $Table[$Key] }
    return $Default
}

function Get-PortalCloudSettings {
    param([ValidateSet('aws', 'azure')] [string] $Provider)
    $cfg = Get-PortalConfig
    if (-not $cfg.Contains('clouds') -or -not $cfg.clouds.Contains($Provider)) { throw "Cloud provider '$Provider' is not configured (Admin > Cloud connections)." }
    return $cfg.clouds[$Provider]
}

function Get-PortalCloudSecret {
    param([ValidateSet('aws', 'azure')] [string] $Provider, $Settings)
    $ref = [string](Get-CC $Settings 'credentialRef' '')
    if ($ref) {
        if (-not (Get-Command Get-PortalVaultCredential -ErrorAction SilentlyContinue)) { Import-Module (Join-Path (Get-PortalRoot) 'modules/Portal.Vault.psm1') -Force -Global }
        return (Get-PortalVaultCredential -Id $ref -Purpose cloud -Actor "cloud:$Provider")
    }
    $p = [string](Get-CC $Settings 'credentialPath' "data/secrets/$Provider.cloud.xml")
    if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path (Get-PortalRoot) $p }
    if (-not (Test-Path -LiteralPath $p)) { throw "No $Provider secret stored. Admin > Cloud connections: enter the secret and Save." }
    try { return (Import-Clixml -LiteralPath $p) }
    catch { throw "The stored $Provider secret cannot be decrypted by account '$([Environment]::UserName)'. Save it again from Admin > Cloud connections." }
}

function Assert-PortalModule {
    param([string[]] $Name, [string] $Provider)
    $missing = @($Name | Where-Object { -not (Get-Module -ListAvailable -Name $_) })
    if ($missing) { throw "$Provider PowerShell modules missing on the portal server: $($missing -join ', '). Run tools\Install-PortalPrerequisites.ps1 (elevated pwsh) once." }
    Import-Module $Name -ErrorAction Stop
}

function Connect-PortalCloud {
    <#
    .SYNOPSIS Returns a cloud context for handlers: Provider, Settings (no secrets), Region/Location and credentials.
    .OUTPUTS  AWS  : @{ Provider='aws'; Region; Credential = [Amazon.Runtime.AWSCredentials] or $null (default chain); Settings }
              Azure: @{ Provider='azure'; Location; SubscriptionId; Account; Settings }  (Az context is process-scoped)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [ValidateSet('aws', 'azure')] [string] $Provider)
    $s = Get-PortalCloudSettings -Provider $Provider
    if (-not (Get-CC $s 'enabled' $false)) { throw "The $Provider connection is disabled (Admin > Cloud connections)." }

    if ($Provider -eq 'aws') {
        Assert-PortalModule -Name AWS.Tools.Common, AWS.Tools.EC2 -Provider 'AWS'
        $region = [string](Get-CC $s 'region' 'us-east-1')
        $cred = $null
        if ((Get-CC $s 'authMode' 'AccessKey') -eq 'AccessKey') {
            $sec  = Get-PortalCloudSecret -Provider aws -Settings $s
            $cred = New-AWSCredential -AccessKey $sec.UserName -SecretKey $sec.GetNetworkCredential().Password
        }
        $role = [string](Get-CC $s 'roleArn' '')
        if ($role) {
            Import-Module AWS.Tools.SecurityToken -ErrorAction Stop
            $sp = @{ RoleArn = $role; RoleSessionName = "ssp-portal-$PID"; Region = $region }
            if ($cred) { $sp['Credential'] = $cred }
            $assumed = Use-STSRole @sp
            $cred = New-AWSCredential -AccessKey $assumed.Credentials.AccessKeyId -SecretKey $assumed.Credentials.SecretAccessKey -SessionToken $assumed.Credentials.SessionToken
        }
        return [pscustomobject]@{ Provider = 'aws'; Region = $region; Credential = $cred; Settings = $s }
    }

    Assert-PortalModule -Name Az.Accounts, Az.Compute, Az.Network -Provider 'Azure'
    $null = Disable-AzContextAutosave -Scope Process -ErrorAction SilentlyContinue
    $sub = [string](Get-CC $s 'subscriptionId' '')
    if ((Get-CC $s 'authMode' 'ServicePrincipal') -eq 'ManagedIdentity') {
        $acct = Connect-AzAccount -Identity -Subscription $sub -Scope Process -ErrorAction Stop
    }
    else {
        $sec = Get-PortalCloudSecret -Provider azure -Settings $s
        $acct = Connect-AzAccount -ServicePrincipal -Tenant ([string](Get-CC $s 'tenantId' '')) -Credential $sec -Subscription $sub -Scope Process -ErrorAction Stop
    }
    return [pscustomobject]@{ Provider = 'azure'; Location = [string](Get-CC $s 'location' 'eastus'); SubscriptionId = $sub; Account = $acct; Settings = $s }
}

function Disconnect-PortalCloud {
    param($Cloud)
    if ($Cloud -and $Cloud.Provider -eq 'azure') { Disconnect-AzAccount -Scope Process -ErrorAction SilentlyContinue | Out-Null }
}

Export-ModuleMember -Function Connect-PortalCloud, Disconnect-PortalCloud, Get-PortalCloudSettings
