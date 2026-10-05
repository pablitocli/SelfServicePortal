#Requires -Version 7.2
<#
.SYNOPSIS
    Tests the AWS or Azure connection configured in Admin > Cloud connections and validates the network
    landing zone (VPC / subnets / security groups / key pair, or VNet / subnets / resource group / Key Vault).
    Writes data/inventory/cloud-<provider>.conn.json.
#>
[CmdletBinding()]
param([Parameter(Mandatory)] [ValidateSet('aws', 'azure')] [string] $Provider)

$ErrorActionPreference = 'Stop'
$root = if ($env:SSP_PORTAL_ROOT) { $env:SSP_PORTAL_ROOT } else { Split-Path -Parent $PSScriptRoot }
$env:SSP_PORTAL_ROOT = $root
Import-Module (Join-Path $root 'modules/Portal.Core.psm1') -Force
Import-Module (Join-Path $root 'automation/lib/Portal.CloudConnect.psm1') -Force

$out = Join-Path (Get-PortalPath -Name Inventory) "cloud-$Provider.conn.json"
Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$cloud = $null
try {
    $cloud = Connect-PortalCloud -Provider $Provider
    $s = $cloud.Settings
    $checks = [System.Collections.Generic.List[object]]::new()
    function Add-Check([string] $Name, [bool] $Ok, [string] $Detail) { $checks.Add([ordered]@{ name = $Name; ok = $Ok; detail = $Detail }) }

    if ($Provider -eq 'aws') {
        Import-Module AWS.Tools.SecurityToken, AWS.Tools.EC2 -ErrorAction Stop
        $common = @{ Region = $cloud.Region }; if ($cloud.Credential) { $common['Credential'] = $cloud.Credential }
        $id = Get-STSCallerIdentity @common
        $identity = "account $($id.Account) - $($id.Arn)"
        if ($s.vpcId) {
            try { $vpc = Get-EC2Vpc -VpcId $s.vpcId @common; Add-Check "VPC $($s.vpcId)" $true "CIDR $($vpc.CidrBlock)" }
            catch { Add-Check "VPC $($s.vpcId)" $false (Get-PortalErrorDetail $_) }
        } else { Add-Check 'VPC' $false 'vpcId not configured' }
        foreach ($sn in @($s.subnets)) {
            if (-not $sn) { continue }
            try { $x = Get-EC2Subnet -SubnetId $sn.id @common; Add-Check "Subnet $($sn.id)" ($x.VpcId -eq $s.vpcId) "$($x.AvailabilityZone) $($x.CidrBlock)$(if ($x.VpcId -ne $s.vpcId) { " - belongs to $($x.VpcId), not the configured VPC" })" }
            catch { Add-Check "Subnet $($sn.id)" $false (Get-PortalErrorDetail $_) }
        }
        foreach ($g in @($s.securityGroupIds)) {
            if (-not $g) { continue }
            try { $x = Get-EC2SecurityGroup -GroupId $g @common; Add-Check "Security group $g" $true $x.GroupName }
            catch { Add-Check "Security group $g" $false (Get-PortalErrorDetail $_) }
        }
        if ($s.keyPairName) {
            try { $null = Get-EC2KeyPair -KeyName $s.keyPairName @common; Add-Check "Key pair $($s.keyPairName)" $true 'found' }
            catch { Add-Check "Key pair $($s.keyPairName)" $false (Get-PortalErrorDetail $_) }
        }
        $scope = "region $($cloud.Region)"
    }
    else {
        Import-Module Az.Network, Az.Resources -ErrorAction Stop
        $ctx = Get-AzContext
        $identity = "subscription $($ctx.Subscription.Name) ($($ctx.Subscription.Id)) - $($ctx.Account.Id)"
        if ($s.resourceGroup) {
            $rg = Get-AzResourceGroup -Name $s.resourceGroup -ErrorAction SilentlyContinue
            Add-Check "Resource group $($s.resourceGroup)" ([bool]$rg) $(if ($rg) { $rg.Location } else { 'not found' })
        } else { Add-Check 'Resource group' $false 'resourceGroup not configured' }
        $vnetRg = if ($s.vnetResourceGroup) { $s.vnetResourceGroup } else { $s.resourceGroup }
        if ($s.vnetName) {
            $vnet = Get-AzVirtualNetwork -Name $s.vnetName -ResourceGroupName $vnetRg -ErrorAction SilentlyContinue
            Add-Check "VNet $($s.vnetName)" ([bool]$vnet) $(if ($vnet) { ($vnet.AddressSpace.AddressPrefixes -join ', ') } else { "not found in $vnetRg" })
            foreach ($sn in @($s.subnets)) {
                if (-not $sn) { continue }
                $x = if ($vnet) { $vnet.Subnets | Where-Object Name -eq $sn } else { $null }
                Add-Check "Subnet $sn" ([bool]$x) $(if ($x) { ($x.AddressPrefix -join ', ') } else { 'not found' })
            }
        } else { Add-Check 'VNet' $false 'vnetName not configured' }
        if ($s.keyVaultName) {
            Import-Module Az.KeyVault -ErrorAction SilentlyContinue
            $kv = Get-AzKeyVault -VaultName $s.keyVaultName -ErrorAction SilentlyContinue
            Add-Check "Key Vault $($s.keyVaultName)" ([bool]$kv) $(if ($kv) { 'found' } else { 'not found' })
        } else { Add-Check 'Key Vault' $false 'keyVaultName not configured (required for Windows admin passwords)' }
        $scope = "location $($cloud.Location)"
    }

    Write-PortalJson -Path $out -Value ([ordered]@{
        ok         = -not ($checks | Where-Object { -not $_.ok })
        connected  = $true
        testedAt   = Get-PortalTimestamp
        durationMs = $sw.ElapsedMilliseconds
        identity   = $identity
        scope      = $scope
        checks     = $checks.ToArray()
        error      = $null
    })
}
catch {
    Write-PortalJson -Path $out -Value ([ordered]@{ ok = $false; connected = $false; testedAt = (Get-PortalTimestamp); durationMs = $sw.ElapsedMilliseconds; error = (Get-PortalErrorDetail -ErrorRecord $_) })
    exit 1
}
finally { Disconnect-PortalCloud -Cloud $cloud }
