#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - deploys a new VM from a template with guest customization.
.DESCRIPTION
    Used by catalog items vm-windows-2022 and vm-rhel-9 (GuestFamily + CustomizationSpec come from
    execution.fixedParameters). Runs inside automation/Invoke-CatalogJob.ps1 with an open vCenter session.

    Flow: pre-flight checks -> temporary non-persistent customization spec -> clone -> size -> network
          -> data disk -> custom attributes -> power on -> wait for customization + VMware Tools -> result.
    On failure after the clone, the VM is removed when jobs.rollbackOnFailure = true.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] [string] $VMName,
    [string] $Description,
    [Parameter(Mandatory)] [string] $Template,          # fixed per catalog item (per site), not chosen by the requester
    [ValidateSet('App', 'DB')] [string] $Workload = 'App',
    [string] $Cluster,                                   # optional override; normally derived from Workload
    [Parameter(Mandatory)] [string] $Datastore,
    [Parameter(Mandatory)] [string] $Folder,
    [Parameter(Mandatory)] [int] $CpuCount,
    [Parameter(Mandatory)] [int] $MemoryGB,
    [int] $AdditionalDiskGB = 0,
    [Parameter(Mandatory)] [string] $PortGroup,
    [ValidateSet('Static', 'DHCP')] [string] $IpMode = 'Static',
    [string] $IPAddress,
    [string] $SubnetMask,
    [string] $Gateway,
    [string] $DnsServers,
    [string] $Owner,
    [string] $CostCenter,
    [string] $ChangeTicket,
    [bool] $PowerOn = $true,
    [Parameter(Mandatory)] [ValidateSet('Windows', 'Linux')] [string] $GuestFamily,
    [Parameter(Mandatory)] [string] $CustomizationSpec,
    [System.Collections.IDictionary] $VmNotes,         # "VM notes" section of the form (Label = value)
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}

$vi        = $Context.VIServer
$defaults  = $Context.Site.defaults
$requestId = $Context.RequestId
$vm        = $null
$tmpSpec   = $null

function Resolve-PortalFolder {
    <# Resolves "Datacenter/Folder/SubFolder" (as produced by the inventory collector) to a VM folder. #>
    param([string] $Path)
    $parts = $Path -split '/' | Where-Object { $_ }
    $dc = Get-Datacenter -Name $parts[0] -Server $vi
    $current = Get-Folder -Name 'vm' -Location $dc -Type VM -NoRecursion -Server $vi
    foreach ($p in ($parts | Select-Object -Skip 1)) {
        $current = Get-Folder -Name $p -Location $current -Type VM -NoRecursion -Server $vi
    }
    return $current
}

try {
    #region 1. Pre-flight -----------------------------------------------------------------------------------
    Write-JobLog -Level STEP 'Pre-flight validation'

    # Workload -> cluster mapping from portal.config.json (sites[].defaults.workloadClusters).
    if (-not $Cluster) {
        $map = $defaults.workloadClusters
        if ($map) { foreach ($k in $map.Keys) { if ($k -ieq $Workload) { $Cluster = $map[$k] } } }
        if (-not $Cluster) { throw "No cluster mapped for workload '$Workload' at site $Site (Admin > vCenter connections)." }
    }
    Write-JobLog "Workload $Workload -> cluster $Cluster; template $Template"

    if (Get-VM -Name $VMName -Server $vi -ErrorAction SilentlyContinue) { throw "A VM named '$VMName' already exists in $($vi.Name)." }

    $tpl     = Get-Template -Name $Template -Server $vi
    $cl      = Get-Cluster -Name $Cluster -Server $vi
    $ds      = Get-Datastore -Name $Datastore -Server $vi
    $folderO = Resolve-PortalFolder -Path $Folder
    $baseSpec = Get-OSCustomizationSpec -Name $CustomizationSpec -Server $vi

    # Datastore must be visible to every connected host of the cluster.
    $hosts = @(Get-VMHost -Location $cl -Server $vi | Where-Object ConnectionState -eq 'Connected')
    if (-not $hosts) { throw "Cluster $Cluster has no connected hosts." }
    $missing = @($hosts | Where-Object { @(Get-Datastore -VMHost $_ -Server $vi).Name -notcontains $Datastore })
    if ($missing) { throw "Datastore $Datastore is not mounted on: $($missing.Name -join ', ')." }

    # Capacity check: template disks + data disk + swap must keep the datastore above the free-space floor.
    $tplDiskGB  = (Get-HardDisk -Template $tpl -Server $vi | Measure-Object -Property CapacityGB -Sum).Sum
    $requiredGB = [math]::Ceiling($tplDiskGB + $AdditionalDiskGB + $MemoryGB)
    $floorPct   = if ($defaults.minDatastoreFreePercent) { [double]$defaults.minDatastoreFreePercent } else { 10 }
    $freeAfter  = $ds.FreeSpaceGB - $requiredGB
    $pctAfter   = 100 * $freeAfter / $ds.CapacityGB
    Write-JobLog ("Datastore {0}: {1:N0} GB free, {2:N0} GB required (worst case), {3:N1}% free after deploy (floor {4}%)." -f $Datastore, $ds.FreeSpaceGB, $requiredGB, $pctAfter, $floorPct)
    if ($pctAfter -lt $floorPct) { throw "Datastore $Datastore would drop below the $floorPct% free-space floor." }

    # Port group: distributed first, then standard.
    $pg = Get-VDPortgroup -Name $PortGroup -Server $vi -ErrorAction SilentlyContinue | Select-Object -First 1
    $pgIsDistributed = [bool]$pg
    if (-not $pg) {
        $pg = Get-VirtualPortGroup -Name $PortGroup -Standard -Server $vi -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $pg) { throw "Port group '$PortGroup' not found." }
    }

    # DNS: request value, else site default.
    $dns = @()
    if ($DnsServers) { $dns = @($DnsServers -split '\s*,\s*' | Where-Object { $_ }) }
    elseif ($defaults.dnsServers) { $dns = @($defaults.dnsServers) }
    $dnsDomain = $defaults.dnsDomain

    if ($IpMode -eq 'Static') {
        foreach ($v in 'IPAddress', 'SubnetMask', 'Gateway') {
            if (-not (Get-Variable -Name $v -ValueOnly)) { throw "$v is required for static IP assignment." }
        }
        if (Test-Connection -TargetName $IPAddress -Count 1 -Quiet -TimeoutSeconds 2 -ErrorAction SilentlyContinue) {
            throw "IP address $IPAddress already answers to ping - refusing to create a duplicate."
        }
    }
    Write-JobLog -Level OK 'Pre-flight validation passed.'
    #endregion

    #region 2. Temporary customization spec -----------------------------------------------------------------
    Write-JobLog -Level STEP "Preparing guest customization from base spec '$CustomizationSpec'"
    $tmpSpec = $baseSpec | New-OSCustomizationSpec -Name "portal-$requestId" -Type NonPersistent -Server $vi
    if ($GuestFamily -eq 'Linux') {
        $specArgs = @{ NamingScheme = 'Fixed'; NamingPrefix = $VMName.ToLower() }
        if ($dnsDomain) { $specArgs['Domain'] = $dnsDomain; $specArgs['DnsSuffix'] = $dnsDomain }
        if ($dns)       { $specArgs['DnsServer'] = $dns }
        $tmpSpec = Set-OSCustomizationSpec -OSCustomizationSpec $tmpSpec @specArgs -Confirm:$false
    }
    else {
        $tmpSpec = Set-OSCustomizationSpec -OSCustomizationSpec $tmpSpec -NamingScheme Fixed -NamingPrefix $VMName.ToUpper() -Confirm:$false
    }

    $nicMap = Get-OSCustomizationNicMapping -OSCustomizationSpec $tmpSpec | Select-Object -First 1
    if ($IpMode -eq 'Static') {
        $nicArgs = @{ IpMode = 'UseStaticIP'; IpAddress = $IPAddress; SubnetMask = $SubnetMask; DefaultGateway = $Gateway }
        if ($GuestFamily -eq 'Windows' -and $dns) { $nicArgs['Dns'] = $dns }
        $null = Set-OSCustomizationNicMapping -OSCustomizationNicMapping $nicMap @nicArgs -Confirm:$false
    }
    else {
        $null = Set-OSCustomizationNicMapping -OSCustomizationNicMapping $nicMap -IpMode UseDhcp -Confirm:$false
    }
    Write-JobLog -Level OK "Customization spec ready ($IpMode)."
    #endregion

    #region 3. Clone ----------------------------------------------------------------------------------------
    $noteLines = @(
        $Description
        "Requested via Self-Service Portal - $requestId"
        "Requester: $($Context.Requester.name) | Owner: $Owner | Cost center: $CostCenter"
    )
    if ($VmNotes) { $noteLines += ''; foreach ($k in $VmNotes.Keys) { $noteLines += "${k}: $($VmNotes[$k])" } }
    $notes = $noteLines -join "`n"
    Write-JobLog -Level STEP "Cloning '$Template' -> '$VMName' on $Cluster / $Datastore"
    $vm = New-VM -Name $VMName -Template $tpl -ResourcePool $cl -Datastore $ds -Location $folderO `
                 -OSCustomizationSpec $tmpSpec -DiskStorageFormat Thin -Notes $notes -Server $vi
    Write-JobLog -Level OK "VM created ($($vm.Id))."
    #endregion

    #region 4. Size, network, disk ----------------------------------------------------------------------------
    Write-JobLog -Level STEP "Sizing: $CpuCount vCPU / $MemoryGB GB"
    $vm = Set-VM -VM $vm -NumCpu $CpuCount -MemoryGB $MemoryGB -Confirm:$false

    Write-JobLog -Level STEP "Connecting NIC to '$PortGroup'"
    $nic = Get-NetworkAdapter -VM $vm | Select-Object -First 1
    if ($pgIsDistributed) { $null = Set-NetworkAdapter -NetworkAdapter $nic -Portgroup $pg -StartConnected:$true -Confirm:$false }
    else                  { $null = Set-NetworkAdapter -NetworkAdapter $nic -NetworkName $PortGroup -StartConnected:$true -Confirm:$false }

    if ($AdditionalDiskGB -gt 0) {
        Write-JobLog -Level STEP "Adding data disk: $AdditionalDiskGB GB (thin)"
        $null = New-HardDisk -VM $vm -CapacityGB $AdditionalDiskGB -StorageFormat Thin -Confirm:$false
    }
    #endregion

    #region 5. Custom attributes (governance) ---------------------------------------------------------------
    $attrs = [ordered]@{
        'Portal.RequestId'    = $requestId
        'Portal.RequestedBy'  = $Context.Requester.username
        'Portal.Owner'        = $Owner
        'Portal.CostCenter'   = $CostCenter
        'Portal.ChangeTicket' = $ChangeTicket
        'Portal.CreatedOn'    = (Get-Date -Format 'yyyy-MM-dd')
    }
    foreach ($a in $attrs.GetEnumerator()) {
        if (-not $a.Value) { continue }
        try {
            $ca = Get-CustomAttribute -Name $a.Key -TargetType VirtualMachine -Server $vi -ErrorAction SilentlyContinue
            if (-not $ca) { $ca = New-CustomAttribute -Name $a.Key -TargetType VirtualMachine -Server $vi }
            $null = Set-Annotation -Entity $vm -CustomAttribute $ca -Value $a.Value
        }
        catch { Write-JobLog -Level WARN "Could not set custom attribute $($a.Key): $($_.Exception.Message)" }
    }
    #endregion

    #region 6. Power on and wait for customization ----------------------------------------------------------
    $ip = $null
    $customization = 'Pending first boot'
    if ($PowerOn) {
        Write-JobLog -Level STEP 'Powering on'
        $bootTime = Get-Date
        $vm = Start-VM -VM $vm -Confirm:$false

        Write-JobLog 'Waiting for guest customization (max 30 min)...'
        $deadline = (Get-Date).AddMinutes(30)
        $customization = 'Unknown'
        while ((Get-Date) -lt $deadline) {
            $events = Get-VIEvent -Entity $vm -Start $bootTime -Server $vi -ErrorAction SilentlyContinue
            if ($events | Where-Object { $_ -is [VMware.Vim.CustomizationSucceeded] }) { $customization = 'Succeeded'; break }
            if ($events | Where-Object { $_ -is [VMware.Vim.CustomizationFailed] })    { $customization = 'Failed'; break }
            Start-Sleep -Seconds 20
        }
        if ($customization -eq 'Failed') { throw 'Guest customization failed. Check guest logs (Windows: C:\Windows\Panther; Linux: /var/log/vmware-imc).' }
        if ($customization -eq 'Unknown') { Write-JobLog -Level WARN 'Customization result not reported within 30 min.' }
        else { Write-JobLog -Level OK "Guest customization $customization." }

        $vm = Wait-Tools -VM $vm -TimeoutSeconds 600 -ErrorAction SilentlyContinue
        $vm = Get-VM -Id $vm.Id -Server $vi
        $ip = @($vm.Guest.IPAddress) | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1
        Write-JobLog -Level OK "VM running. Guest IP: $ip"
    }
    #endregion

    $nextSteps = @('Register the DNS A/PTR records through your DNS change process.')
    if ($IpMode -eq 'Static') { $nextSteps += "Record $IPAddress as allocated in IPAM." }
    if (-not $PowerOn) { $nextSteps += 'Guest customization will run on first power-on.' }

    return [ordered]@{
        VMName        = $vm.Name
        VMId          = $vm.Id
        Site          = $Site
        vCenter       = $vi.Name
        Workload      = $Workload
        Cluster       = $Cluster
        Template      = $Template
        Datastore     = $Datastore
        Folder        = $Folder
        PortGroup     = $PortGroup
        vCPU          = $CpuCount
        MemoryGB      = $MemoryGB
        IPAddress     = if ($ip) { $ip } elseif ($IpMode -eq 'Static') { $IPAddress } else { 'DHCP (pending)' }
        PowerState    = [string]$vm.PowerState
        Customization = $customization
        NextSteps     = $nextSteps
    }
}
catch {
    $err = $_
    if ($vm -and $Context.RollbackOnFailure) {
        Write-JobLog -Level WARN "Rolling back: removing partially provisioned VM '$VMName'."
        try {
            $cur = Get-VM -Id $vm.Id -Server $vi -ErrorAction SilentlyContinue
            if ($cur -and $cur.PowerState -eq 'PoweredOn') { $null = Stop-VM -VM $cur -Kill -Confirm:$false }
            if ($cur) { Remove-VM -VM $cur -DeletePermanently -Confirm:$false }
            Write-JobLog -Level WARN 'Rollback completed.'
        }
        catch { Write-JobLog -Level ERROR "Rollback failed - manual cleanup required: $($_.Exception.Message)" }
    }
    throw $err
}
finally {
    if ($tmpSpec) { Remove-OSCustomizationSpec -OSCustomizationSpec $tmpSpec -Confirm:$false -ErrorAction SilentlyContinue }
}
