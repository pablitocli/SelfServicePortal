#Requires -Version 7.2
<#
.SYNOPSIS
    Portal.Cloud - Cloud Ops connection management (AWS VPC / Azure VNet) for the Admin UI and the catalog.
.DESCRIPTION
    Settings live in portal.config.json -> clouds.aws / clouds.azure. Secrets (AWS secret access key,
    Azure client secret) are stored in the portal vault (entries cloud-aws / cloud-azure, system scope),
    exactly like the vCenter credentials. The browser never receives a secret.
#>

Set-StrictMode -Version Latest

$script:Providers = @('aws', 'azure')

function Get-CV {
    param($Table, [string] $Key, $Default = $null)
    if ($Table -is [System.Collections.IDictionary] -and $Table.Contains($Key) -and $null -ne $Table[$Key]) { return $Table[$Key] }
    return $Default
}

function New-PortalCloudDefaults {
    <# Default (disabled) cloud section used by fresh installs and config upgrades. #>
    [ordered]@{
        aws = [ordered]@{
            enabled          = $false
            displayName      = 'AWS'
            authMode         = 'AccessKey'            # AccessKey | DefaultChain (instance profile / environment)
            accessKeyId      = ''
            credentialRef    = ''
            roleArn          = ''                     # optional: assume this role after authenticating
            region           = 'us-east-1'
            vpcId            = ''
            subnets          = @()                    # [{ id: "subnet-...", label: "private-a" }]
            securityGroupIds = @()
            keyPairName      = ''
            instanceTypes    = @('t3.medium', 't3.large', 'm6i.large', 'm6i.xlarge', 'r6i.large')
            images           = [ordered]@{
                Windows2025 = [ordered]@{ ssmParameter = '/aws/service/ami-windows-latest/Windows_Server-2025-English-Full-Base'; amiId = '' }
                AlmaLinux   = [ordered]@{ ssmParameter = ''; amiId = ''; ownerId = '764336703387'; namePattern = 'AlmaLinux OS 9*x86_64*' }
            }
            defaultTags      = [ordered]@{ ManagedBy = 'SelfService-Portal' }
        }
        azure = [ordered]@{
            enabled           = $false
            displayName       = 'Azure'
            authMode          = 'ServicePrincipal'     # ServicePrincipal | ManagedIdentity
            tenantId          = ''
            subscriptionId    = ''
            clientId          = ''
            credentialRef     = ''
            location          = 'eastus'
            resourceGroup     = ''
            vnetResourceGroup = ''
            vnetName          = ''
            subnets           = @()                    # subnet names in the VNet
            nsgName           = ''
            vmSizes           = @('Standard_B2ms', 'Standard_D2s_v5', 'Standard_D4s_v5', 'Standard_E2s_v5')
            adminUsername     = 'sspadmin'
            sshPublicKey      = ''
            keyVaultName      = ''                     # Windows local admin passwords are stored here
            images            = [ordered]@{
                Windows2025 = [ordered]@{ urn = 'MicrosoftWindowsServer:WindowsServer:2025-datacenter-azure-edition:latest'; plan = $false }
                AlmaLinux   = [ordered]@{ urn = 'almalinux:almalinux-x86_64:9-gen2:latest'; plan = $true }
            }
            defaultTags       = [ordered]@{ ManagedBy = 'SelfService-Portal' }
        }
    }
}

function Get-PortalCloudConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [ValidateSet('aws', 'azure')] [string] $Provider)
    $cfg = Get-PortalConfig
    if (-not $cfg.Contains('clouds') -or -not $cfg.clouds.Contains($Provider)) { return (New-PortalCloudDefaults)[$Provider] }
    return $cfg.clouds[$Provider]
}

function Get-PortalCloudSecretPath {
    param([string] $Provider)
    $c = Get-PortalCloudConfig -Provider $Provider
    $p = [string](Get-CV $c 'credentialPath' "data/secrets/$Provider.cloud.xml")
    if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path (Get-PortalRoot) $p }
    return $p
}

function Get-PortalCloudView {
    <# Cloud connection settings for the Admin UI (no secrets) + last test result. #>
    [CmdletBinding()] param()
    foreach ($p in $script:Providers) {
        $c = Get-PortalCloudConfig -Provider $p
        $view = [ordered]@{}
        foreach ($k in $c.Keys) { if ($k -ne 'credentialPath') { $view[$k] = $c[$k] } }
        $ref = [string](Get-CV $c 'credentialRef' '')
        $view['provider']         = $p
        $view['secretConfigured'] = if ($ref) { [bool](Get-PortalVaultEntry -Id $ref) } else { Test-Path -LiteralPath (Get-PortalCloudSecretPath -Provider $p) }
        $view['lastTest']         = Read-PortalJson -Path (Join-Path (Get-PortalPath -Name Inventory) "cloud-$p.conn.json")
        $view
    }
}

function Set-PortalCloudSettings {
    <# Updates clouds.<provider> (whitelisted keys only) and optionally stores the secret. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('aws', 'azure')] [string] $Provider,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Settings,
        [string] $Secret,
        [Parameter(Mandatory)] [string] $Actor
    )
    $allowed = @{
        aws   = @('enabled', 'displayName', 'authMode', 'accessKeyId', 'roleArn', 'region', 'vpcId', 'subnets', 'securityGroupIds', 'keyPairName', 'instanceTypes', 'images', 'defaultTags')
        azure = @('enabled', 'displayName', 'authMode', 'tenantId', 'subscriptionId', 'clientId', 'location', 'resourceGroup', 'vnetResourceGroup', 'vnetName', 'subnets', 'nsgName', 'vmSizes', 'adminUsername', 'sshPublicKey', 'keyVaultName', 'images', 'defaultTags')
    }[$Provider]

    # Light validation of well-known formats.
    $v = $Settings
    if ($Provider -eq 'aws') {
        if ($v.Contains('region') -and $v.region -and $v.region -notmatch '^[a-z]{2}(-gov)?-[a-z]+-\d$') { throw "Invalid AWS region '$($v.region)'." }
        if ($v.Contains('vpcId') -and $v.vpcId -and $v.vpcId -notmatch '^vpc-[0-9a-f]{8,17}$') { throw "Invalid VPC id '$($v.vpcId)'." }
        foreach ($s in @(Get-CV $v 'subnets' @())) { if ($s -and ([string](Get-CV $s 'id' '')) -notmatch '^subnet-[0-9a-f]{8,17}$') { throw "Invalid subnet id '$(Get-CV $s 'id')'." } }
        foreach ($g in @(Get-CV $v 'securityGroupIds' @())) { if ($g -and $g -notmatch '^sg-[0-9a-f]{8,17}$') { throw "Invalid security group id '$g'." } }
        if ($v.Contains('authMode') -and @('AccessKey', 'DefaultChain') -notcontains $v.authMode) { throw 'authMode must be AccessKey or DefaultChain.' }
    }
    else {
        $guid = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
        foreach ($k in 'tenantId', 'subscriptionId', 'clientId') { if ($v.Contains($k) -and $v[$k] -and $v[$k] -notmatch $guid) { throw "$k must be a GUID." } }
        if ($v.Contains('authMode') -and @('ServicePrincipal', 'ManagedIdentity') -notcontains $v.authMode) { throw 'authMode must be ServicePrincipal or ManagedIdentity.' }
    }

    Update-PortalConfig -Mutate {
        param($cfg)
        if (-not $cfg.Contains('clouds')) { $cfg['clouds'] = New-PortalCloudDefaults }
        if (-not $cfg.clouds.Contains($Provider)) { $cfg.clouds[$Provider] = (New-PortalCloudDefaults)[$Provider] }
        $t = $cfg.clouds[$Provider]
        foreach ($k in $allowed) { if ($Settings.Contains($k)) { $t[$k] = $Settings[$k] } }
    }

    if ($Secret) {
        $c = Get-PortalCloudConfig -Provider $Provider
        $id = if ($Provider -eq 'aws') { [string](Get-CV $c 'accessKeyId' '') } else { [string](Get-CV $c 'clientId' '') }
        if (-not $id) { throw ($(if ($Provider -eq 'aws') { 'Access key id is required to store the secret.' } else { 'Client id is required to store the secret.' })) }
        $vid = "cloud-$Provider"
        $fields = if ($Provider -eq 'azure') { [ordered]@{ tenantId = [string](Get-CV $c 'tenantId' '') } } else { [ordered]@{} }
        Set-PortalVaultEntry -Id $vid -Name "$($Provider.ToUpper()) automation identity" -Type ServicePrincipal -Username $id -Secret $Secret `
            -Fields $fields -Scope @{ system = $true } -Actor $Actor -New:(-not (Get-PortalVaultEntry -Id $vid))
        Update-PortalConfig -Mutate { param($cfg) $cfg.clouds[$Provider]['credentialRef'] = $vid }
    }
    Write-PortalAudit -Actor $Actor -Action 'cloud.update' -Target $Provider -Details @{ secretChanged = [bool]$Secret }
}

function Test-PortalCloudConnection {
    <# Runs automation/Test-CloudConnection.ps1 out-of-process (same identity as the job runners). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [ValidateSet('aws', 'azure')] [string] $Provider, [int] $TimeoutSeconds = 90, [string] $Actor = 'system')
    $cfg    = Get-PortalConfig
    $pwsh   = if ($cfg.jobs.pwshPath) { $cfg.jobs.pwshPath } else { 'pwsh' }
    $script = Join-Path (Get-PortalPath -Name Automation) 'Test-CloudConnection.ps1'
    $out    = Join-Path (Get-PortalPath -Name Inventory) "cloud-$Provider.conn.json"
    $logBase = Join-Path (Get-PortalPath -Name JobLogs) "conntest-cloud-$Provider"
    $env:SSP_PORTAL_ROOT = Get-PortalRoot
    $sp = @{ FilePath = $pwsh; PassThru = $true; RedirectStandardOutput = "$logBase.stdout.log"; RedirectStandardError = "$logBase.stderr.log"
             ArgumentList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$script`"", '-Provider', $Provider) }
    if ($IsWindows) { $sp['WindowStyle'] = 'Hidden' }
    $proc = Start-Process @sp
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        Write-PortalJson -Path $out -Value ([ordered]@{ ok = $false; testedAt = (Get-PortalTimestamp); error = "Connection test timed out after $TimeoutSeconds s (outbound HTTPS / proxy from the portal server?)." })
    }
    $r = Read-PortalJson -Path $out
    if (-not $r) {
        $err = if (Test-Path "$logBase.stderr.log") { (Get-Content "$logBase.stderr.log" -Raw) } else { 'No result produced.' }
        $r = [ordered]@{ ok = $false; testedAt = (Get-PortalTimestamp); error = "$err".Trim() }
    }
    Write-PortalAudit -Actor $Actor -Action 'cloud.test' -Target $Provider -Details @{ ok = [bool]$r.ok }
    return $r
}

function Get-PortalCloudLookup {
    <# Options for cloud-backed select inputs (awsSubnets, awsInstanceTypes, azureSubnets, azureVmSizes). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Source)
    $provider = if ($Source -like 'aws*') { 'aws' } else { 'azure' }
    $c = Get-PortalCloudConfig -Provider $provider
    if (-not (Get-CV $c 'enabled' $false)) {
        throw "The $((Get-CV $c 'displayName' $provider)) connection is not enabled. Admin > Cloud connections."
    }
    switch ($Source) {
        'awsSubnets'       { @(Get-CV $c 'subnets' @()) | Where-Object { $_ } | ForEach-Object { [ordered]@{ value = $_.id; label = if ($_.Contains('label') -and $_.label) { "$($_.label) ($($_.id))" } else { $_.id } } } }
        'awsInstanceTypes' { @(Get-CV $c 'instanceTypes' @()) | ForEach-Object { [ordered]@{ value = $_; label = $_ } } }
        'azureSubnets'     { @(Get-CV $c 'subnets' @()) | ForEach-Object { [ordered]@{ value = $_; label = "$($_) ($(Get-CV $c 'vnetName' ''))" } } }
        'azureVmSizes'     { @(Get-CV $c 'vmSizes' @()) | ForEach-Object { [ordered]@{ value = $_; label = $_ } } }
    }
}

Export-ModuleMember -Function New-PortalCloudDefaults, Get-PortalCloudConfig, Get-PortalCloudView, Set-PortalCloudSettings,
    Test-PortalCloudConnection, Get-PortalCloudLookup
