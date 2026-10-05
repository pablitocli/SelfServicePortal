#Requires -Version 7.2
<#
.SYNOPSIS
    Cloud Ops handler - deploys an Azure VM (Windows Server 2025 or AlmaLinux) into the configured VNet.
.DESCRIPTION
    Uses Admin > Cloud connections > Azure (subscription, resource group, location, VNet/subnets, NSG, images, Key Vault).
    Windows: a random local admin password is generated and stored ONLY in Key Vault (secret "<vm>-localadmin").
    Linux  : SSH public key authentication (password login disabled).
    AlmaLinux marketplace images carry a purchase plan; the plan is attached and the terms accepted automatically.
    Flow: pre-flight -> NIC (+ optional public IP) -> VM config -> New-AzVM -> result. Rolled back on failure.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{2,62}$')] [string] $VmName,
    [string] $Description,
    [Parameter(Mandatory)] [ValidateSet('Windows2025', 'AlmaLinux')] [string] $OsFlavor,
    [Parameter(Mandatory)] [string] $VmSize,
    [Parameter(Mandatory)] [string] $Subnet,
    [int] $DataDiskGB = 0,
    [bool] $PublicIp = $false,
    [string] $Owner,
    [string] $CostCenter,
    [string] $ChangeTicket,
    [System.Collections.IDictionary] $VmNotes,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) { function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" } }
Import-Module Az.Compute, Az.Network, Az.Resources -ErrorAction Stop

$az  = $Context.Cloud
$s   = $az.Settings
$rg  = [string]$s.resourceGroup
$loc = $az.Location
$created = [System.Collections.Generic.List[string]]::new()     # resource ids for rollback

try {
    #region Pre-flight
    Write-JobLog -Level STEP "Pre-flight (subscription $($az.SubscriptionId), $rg, $loc)"
    if ($OsFlavor -eq 'Windows2025' -and $VmName.Length -gt 15) { throw 'Windows computer names are limited to 15 characters.' }
    if (-not (Get-AzResourceGroup -Name $rg -ErrorAction SilentlyContinue)) { throw "Resource group '$rg' not found." }
    if (Get-AzVM -ResourceGroupName $rg -Name $VmName -ErrorAction SilentlyContinue) { throw "A VM named '$VmName' already exists in $rg." }
    if (@($s.vmSizes) -and @($s.vmSizes) -notcontains $VmSize) { throw "VM size $VmSize is not in the allowed list." }
    $vnetRg = if ($s.vnetResourceGroup) { $s.vnetResourceGroup } else { $rg }
    $vnet = Get-AzVirtualNetwork -Name $s.vnetName -ResourceGroupName $vnetRg
    $sn = $vnet.Subnets | Where-Object Name -eq $Subnet
    if (-not $sn) { throw "Subnet '$Subnet' not found in VNet $($s.vnetName)." }

    $img = $s.images[$OsFlavor]
    $urn = ([string]$img.urn).Split(':')
    if ($urn.Count -ne 4) { throw "Image URN for $OsFlavor must be publisher:offer:sku:version." }
    if ($OsFlavor -eq 'Windows2025' -and -not $s.keyVaultName) { throw 'keyVaultName is required to store the Windows local admin password (Admin > Cloud connections > Azure).' }
    if ($OsFlavor -eq 'AlmaLinux' -and -not $s.sshPublicKey) { throw 'sshPublicKey is required for Linux VMs (Admin > Cloud connections > Azure).' }
    #endregion

    $tags = @{ Owner = $Owner; CostCenter = $CostCenter; ChangeTicket = $ChangeTicket; PortalRequestId = $Context.RequestId
               RequestedBy = $Context.Requester.username; OS = $OsFlavor; Description = $Description }
    foreach ($k in @($s.defaultTags.Keys)) { if (-not $tags.ContainsKey($k)) { $tags[$k] = [string]$s.defaultTags[$k] } }
    if ($VmNotes) { foreach ($k in $VmNotes.Keys) { $tags["Note-$(($k -replace '[<>%&\\?/]', '').Trim())"] = ([string]$VmNotes[$k]).Substring(0, [Math]::Min(256, ([string]$VmNotes[$k]).Length)) } }
    foreach ($k in @($tags.Keys)) { if (-not $tags[$k]) { $tags.Remove($k) } }

    #region Network
    Write-JobLog -Level STEP "Creating NIC in $($s.vnetName)/$Subnet"
    $nicArgs = @{ Name = "$VmName-nic01"; ResourceGroupName = $rg; Location = $loc; SubnetId = $sn.Id; Tag = $tags; Force = $true }
    if ($s.nsgName) {
        $nsg = Get-AzNetworkSecurityGroup -Name $s.nsgName -ResourceGroupName $vnetRg -ErrorAction SilentlyContinue
        if (-not $nsg) { $nsg = Get-AzNetworkSecurityGroup -Name $s.nsgName -ResourceGroupName $rg }
        $nicArgs['NetworkSecurityGroupId'] = $nsg.Id
    }
    if ($PublicIp) {
        $pip = New-AzPublicIpAddress -Name "$VmName-pip01" -ResourceGroupName $rg -Location $loc -AllocationMethod Static -Sku Standard -Tag $tags -Force
        $created.Add($pip.Id); $nicArgs['PublicIpAddressId'] = $pip.Id
    }
    $nic = New-AzNetworkInterface @nicArgs
    $created.Add($nic.Id)
    #endregion

    #region VM definition
    $vm = New-AzVMConfig -VMName $VmName -VMSize $VmSize -Tags $tags
    if ($OsFlavor -eq 'Windows2025') {
        $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%*-_+='
        $pw = -join (1..24 | ForEach-Object { $chars[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($chars.Length)] }) + 'aA1!'
        $sec = ConvertTo-SecureString $pw -AsPlainText -Force
        Import-Module Az.KeyVault -ErrorAction Stop
        $null = Set-AzKeyVaultSecret -VaultName $s.keyVaultName -Name "$VmName-localadmin" -SecretValue $sec -Tag @{ vm = $VmName; request = $Context.RequestId }
        Write-JobLog -Level OK "Local admin password stored in Key Vault $($s.keyVaultName) as '$VmName-localadmin'."
        $cred = [pscredential]::new($s.adminUsername, $sec)
        $vm = Set-AzVMOperatingSystem -VM $vm -Windows -ComputerName $VmName -Credential $cred -ProvisionVMAgent -EnableAutoUpdate
    }
    else {
        $dummy = [pscredential]::new($s.adminUsername, (ConvertTo-SecureString ([guid]::NewGuid().ToString()) -AsPlainText -Force))
        $vm = Set-AzVMOperatingSystem -VM $vm -Linux -ComputerName $VmName.ToLower() -Credential $dummy -DisablePasswordAuthentication
        $vm = Add-AzVMSshPublicKey -VM $vm -KeyData $s.sshPublicKey -Path "/home/$($s.adminUsername)/.ssh/authorized_keys"
    }
    $vm = Set-AzVMSourceImage -VM $vm -PublisherName $urn[0] -Offer $urn[1] -Skus $urn[2] -Version $urn[3]
    if ($img.Contains('plan') -and $img.plan) {
        Import-Module Az.MarketplaceOrdering -ErrorAction Stop
        $terms = Get-AzMarketplaceTerms -Publisher $urn[0] -Product $urn[1] -Name $urn[2] -OfferType 'virtualmachine'
        if (-not $terms.Accepted) { $null = Set-AzMarketplaceTerms -Publisher $urn[0] -Product $urn[1] -Name $urn[2] -Terms $terms -Accept; Write-JobLog 'Marketplace terms accepted.' }
        $vm = Set-AzVMPlan -VM $vm -Publisher $urn[0] -Product $urn[1] -Name $urn[2]
    }
    $vm = Add-AzVMNetworkInterface -VM $vm -Id $nic.Id -Primary
    $vm = Set-AzVMOSDisk -VM $vm -Name "$VmName-osdisk" -CreateOption FromImage -StorageAccountType Premium_LRS
    if ($DataDiskGB -gt 0) { $vm = Add-AzVMDataDisk -VM $vm -Name "$VmName-data01" -CreateOption Empty -DiskSizeInGB $DataDiskGB -Lun 0 -StorageAccountType Premium_LRS }
    $vm = Set-AzVMBootDiagnostic -VM $vm -Enable
    #endregion

    Write-JobLog -Level STEP "Deploying $VmName ($VmSize, $($img.urn))"
    $null = New-AzVM -ResourceGroupName $rg -Location $loc -VM $vm
    $created.Add("vm:$VmName")
    $state = Get-AzVM -ResourceGroupName $rg -Name $VmName -Status
    $nicNow = Get-AzNetworkInterface -ResourceId $nic.Id
    $privateIp = $nicNow.IpConfigurations[0].PrivateIpAddress
    $publicIpAddr = if ($PublicIp) { (Get-AzPublicIpAddress -Name "$VmName-pip01" -ResourceGroupName $rg).IpAddress } else { 'none' }
    Write-JobLog -Level OK "VM deployed. Private IP $privateIp. Power state: $(($state.Statuses | Where-Object Code -like 'PowerState/*').DisplayStatus)"

    $next = @('Register the internal DNS record through your change process if the VM needs an internal name.')
    if ($OsFlavor -eq 'Windows2025') { $next += "Local admin '$($s.adminUsername)': password in Key Vault $($s.keyVaultName), secret '$VmName-localadmin'." }
    else { $next += "SSH as '$($s.adminUsername)' with the configured key." }

    return [ordered]@{
        Cloud          = 'Azure'
        VmName         = $VmName
        OS             = $OsFlavor
        VmSize         = $VmSize
        Location       = $loc
        ResourceGroup  = $rg
        VNet           = "$($s.vnetName)/$Subnet"
        PrivateIp      = $privateIp
        PublicIp       = $publicIpAddr
        Image          = $img.urn
        NextSteps      = $next
    }
}
catch {
    $err = $_
    if ($created.Count -and $Context.RollbackOnFailure) {
        Write-JobLog -Level WARN 'Rolling back created resources...'
        try {
            if ($created -contains "vm:$VmName") { $null = Remove-AzVM -ResourceGroupName $rg -Name $VmName -Force }
            foreach ($d in "$VmName-osdisk", "$VmName-data01") { Remove-AzDisk -ResourceGroupName $rg -DiskName $d -Force -ErrorAction SilentlyContinue | Out-Null }
            foreach ($id in ($created | Where-Object { $_ -like '/subscriptions/*' } | Sort-Object { $_ -like '*publicIPAddresses*' })) { Remove-AzResource -ResourceId $id -Force -ErrorAction SilentlyContinue | Out-Null }
            Write-JobLog -Level WARN 'Rollback completed.'
        }
        catch { Write-JobLog -Level ERROR "Rollback incomplete - check resource group $rg for '$VmName*': $($_.Exception.Message)" }
    }
    throw $err
}
