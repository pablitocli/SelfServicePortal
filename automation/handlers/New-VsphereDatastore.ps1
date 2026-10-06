#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - creates a VMFS 6 or NFS datastore on every host of a cluster, optionally in a datastore cluster.
.DESCRIPTION
    Used by catalog item datastore-create (approval + re-authentication on submit and approve).
    The cluster storage lock (Portal.Storage) is held for the whole run, so no portal rescan or other datastore job
    runs on the same cluster at the same time; it is always released in 'finally' (with the rescan stamp when this
    job rescanned the hosts).

    Pre-checks: name pattern (operations.storage.datastoreNamePattern) and unused vCenter-wide; cluster allowed;
                >= 1 connected host; VMFS: LUN visible on EVERY connected host and not in use (QueryAvailableDisksForVmfs);
                NFS: server answers on TCP 2049 from the portal (export permissions are verified by the mount itself);
                datastore cluster: DatastoreCluster and NewDatastoreCluster are mutually exclusive, existing pod holds
                datastores of the same type only.
    Execution:  rescan HBA + VMFS on all hosts -> VMFS: New-Datastore on the first host + VMFS rescan on the others /
                NFS: New-Datastore on every host -> datastore cluster (existing or new, SDRS Manual) -> optional tag
                Portal/Created-by-portal (only if it already exists) -> verify accessible on every host.
    Rollback (RollbackOnFailure): the datastore created by this run is removed, then a datastore cluster created by it.
    The portal inventory timer picks the new datastore up; no refresh is triggered here.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] [string] $Cluster,
    [Parameter(Mandatory)] [ValidateSet('VMFS', 'NFS')] [string] $DatastoreType,
    [string] $Lun,                                   # VMFS: canonical name (naa.*)
    [string] $NfsServer,
    [string] $NfsPath,
    [ValidateSet('', '3', '4.1')] [string] $NfsVersion = '3',
    [Parameter(Mandatory)] [string] $DatastoreName,
    [string] $DatastoreCluster,                      # existing datastore cluster (optional)
    [string] $NewDatastoreCluster,                   # create a new datastore cluster (optional, SDRS Manual)
    [string] $ChangeTicket,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}
if (-not (Get-Command Test-PortalTcpPort -ErrorAction SilentlyContinue)) {
    function Test-PortalTcpPort {
        <# TCP connect probe from the portal server (overridable for tests). #>
        param([Parameter(Mandatory)] [string] $ComputerName, [Parameter(Mandatory)] [int] $Port, [int] $TimeoutMs = 3000)
        $c = [System.Net.Sockets.TcpClient]::new()
        try { return ($c.ConnectAsync($ComputerName, $Port).Wait($TimeoutMs) -and $c.Connected) }
        catch { return $false }
        finally { $c.Dispose() }
    }
}

$vi       = $Context.VIServer
$defaults = $Context.Site.defaults
$by       = "$($Context.Requester.username) ($($Context.RequestId))"
$locked   = $false
$rescanned = $false
$ds       = $null
$createdOn = [System.Collections.Generic.List[object]]::new()   # hosts where this run created / mounted the datastore
$createdPod = $null

$namePattern = '^[A-Za-z0-9][A-Za-z0-9_-]{2,41}$'
$opsStorage = if ($Context.Operations) { $Context.Operations['storage'] } else { $null }
if ($opsStorage -and $opsStorage['datastoreNamePattern']) { $namePattern = [string]$opsStorage['datastoreNamePattern'] }

try {
    Enter-PortalStorageLock -Site $Site -Cluster $Cluster -By $by -Reason 'datastore-create'
    $locked = $true
    Write-JobLog "Storage lock taken on $Site/$Cluster by $by."

    #region 1. Pre-checks -----------------------------------------------------------------------------------
    Write-JobLog -Level STEP "Pre-checks: $DatastoreType datastore '$DatastoreName' on cluster $Cluster"
    if ($DatastoreName -cnotmatch $namePattern) { throw "Datastore name '$DatastoreName' does not match the naming rule $namePattern." }
    if ($DatastoreCluster -and $NewDatastoreCluster) { throw 'Choose either an existing datastore cluster or a new one, not both.' }
    if ($NewDatastoreCluster -and $NewDatastoreCluster -cnotmatch $namePattern) { throw "Datastore cluster name '$NewDatastoreCluster' does not match the naming rule $namePattern." }

    $allowed = @($defaults.allowedClusters | Where-Object { $_ })
    if ($allowed.Count -and -not ($allowed | Where-Object { $_ -ieq $Cluster })) { throw "Cluster $Cluster is not in the allowed clusters of site $Site ($($allowed -join ', '))." }

    if (Get-Datastore -Name $DatastoreName -Server $vi -ErrorAction SilentlyContinue) { throw "A datastore named '$DatastoreName' already exists in $($vi.Name)." }

    $cl = Get-Cluster -Name $Cluster -Server $vi
    $hosts = @(Get-VMHost -Location $cl -Server $vi | Where-Object { [string]$_.ConnectionState -eq 'Connected' })
    if (-not $hosts.Count) { throw "Cluster $Cluster has no connected host." }
    $first = $hosts[0]
    Write-JobLog "$($hosts.Count) connected host(s): $(@($hosts.Name) -join ', ')"

    if ($DatastoreType -eq 'VMFS') {
        if (-not $Lun) { throw 'Select the LUN (storage device) for the VMFS datastore.' }
        $notVisible = @($hosts | Where-Object { -not (Get-ScsiLun -VmHost $_ -CanonicalName $Lun -Server $vi -ErrorAction SilentlyContinue) })
        if ($notVisible.Count) { throw "LUN $Lun is not visible on every host of $Cluster (missing on: $(@($notVisible.Name) -join ', ')). Fix the zoning / masking and rescan." }
        $dsSys = Get-View -Id $first.ExtensionData.ConfigManager.DatastoreSystem -Server $vi
        $free = @($dsSys.QueryAvailableDisksForVmfs($null))
        $dev = $free | Where-Object { [string]$_.CanonicalName -eq $Lun } | Select-Object -First 1
        if (-not $dev) { throw "LUN $Lun is not available for VMFS on $($first.Name) (already in use by a datastore or RDM)." }
        $lunGB = [math]::Round(([double]$dev.Capacity.BlockSize * [double]$dev.Capacity.Block) / 1GB, 1)
        Write-JobLog -Level OK "LUN $Lun ($lunGB GB) visible on all $($hosts.Count) host(s) and unused."
    }
    else {
        if (-not $NfsServer) { throw 'NFS server is required.' }
        if ($NfsServer -notmatch '^[A-Za-z0-9]([A-Za-z0-9.-]{0,252})$') { throw "NFS server '$NfsServer' is not a valid host name or IPv4 address." }
        if ($NfsPath -notmatch '^/') { throw "NFS export path '$NfsPath' must start with '/'." }
        if (-not $NfsVersion) { $NfsVersion = '3' }
        if (-not (Test-PortalTcpPort -ComputerName $NfsServer -Port 2049 -TimeoutMs 3000)) {
            throw "NFS server $NfsServer does not answer on TCP 2049 from the portal server. Check the server, the firewall and the name."
        }
        Write-JobLog -Level OK "NFS server $NfsServer answers on TCP 2049 (export permissions are verified by the mount)."
    }

    $pod = $null
    $wantType = if ($DatastoreType -eq 'VMFS') { @('VMFS') } else { @('NFS', 'NFS41') }
    if ($DatastoreCluster) {
        $pod = Get-DatastoreCluster -Name $DatastoreCluster -Server $vi
        $types = @(Get-Datastore -Location $pod -Server $vi -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Type } | Select-Object -Unique)
        $bad = @($types | Where-Object { $wantType -notcontains $_ })
        if ($bad.Count) { throw "Datastore cluster $DatastoreCluster holds $($bad -join '/') datastores; a $DatastoreType datastore cannot join it." }
    }
    elseif ($NewDatastoreCluster) {
        if (Get-DatastoreCluster -Name $NewDatastoreCluster -Server $vi -ErrorAction SilentlyContinue) { throw "Datastore cluster '$NewDatastoreCluster' already exists." }
    }
    Write-JobLog -Level OK 'Pre-checks passed.'
    #endregion

    #region 2. Rescan + create -----------------------------------------------------------------------------
    Write-JobLog -Level STEP "Rescanning HBAs + VMFS on $($hosts.Count) host(s)"
    foreach ($h in $hosts) { $null = Get-VMHostStorage -VMHost $h -RescanAllHba -RescanVmfs -Server $vi }
    $rescanned = $true

    if ($DatastoreType -eq 'VMFS') {
        Write-JobLog -Level STEP "Creating VMFS 6 datastore '$DatastoreName' on $Lun (host $($first.Name))"
        $ds = New-Datastore -Vmfs -VMHost $first -Name $DatastoreName -Path $Lun -FileSystemVersion 6 -Server $vi
        $createdOn.Add($first)
        foreach ($h in @($hosts | Select-Object -Skip 1)) { $null = Get-VMHostStorage -VMHost $h -RescanVmfs -Server $vi }
        Write-JobLog -Level OK "Datastore created; VMFS rescan done on the other host(s)."
    }
    else {
        Write-JobLog -Level STEP "Mounting NFS $NfsVersion ${NfsServer}:$NfsPath as '$DatastoreName' on every host"
        foreach ($h in $hosts) {
            $nfsArgs = @{ Nfs = $true; VMHost = $h; Name = $DatastoreName; NfsHost = $NfsServer; Path = $NfsPath; Server = $vi }
            if ($NfsVersion -eq '4.1') { $nfsArgs['FileSystemVersion'] = '4.1' }
            $ds = New-Datastore @nfsArgs
            $createdOn.Add($h)
            Write-JobLog "Mounted on $($h.Name)."
        }
        Write-JobLog -Level OK "NFS datastore mounted on $($createdOn.Count) host(s)."
    }
    #endregion

    #region 3. Datastore cluster + tag ----------------------------------------------------------------------
    if ($NewDatastoreCluster) {
        Write-JobLog -Level STEP "Creating datastore cluster '$NewDatastoreCluster' (SDRS automation Manual)"
        $dc = Get-Datacenter -Cluster $cl -Server $vi
        $pod = New-DatastoreCluster -Name $NewDatastoreCluster -Location $dc -Server $vi
        $createdPod = $pod
        $pod = Set-DatastoreCluster -DatastoreCluster $pod -SdrsAutomationLevel Manual -Confirm:$false
    }
    if ($pod) {
        Write-JobLog -Level STEP "Adding '$DatastoreName' to datastore cluster $($pod.Name)"
        $null = Move-Datastore -Datastore (Get-Datastore -Name $DatastoreName -Server $vi | Select-Object -First 1) -Destination $pod
    }
    try {
        $tag = Get-Tag -Name 'Created-by-portal' -Category 'Portal' -Server $vi -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($tag) { $null = New-TagAssignment -Tag $tag -Entity (Get-Datastore -Name $DatastoreName -Server $vi | Select-Object -First 1) -Server $vi; Write-JobLog 'Tag Portal/Created-by-portal assigned.' }
    }
    catch { Write-JobLog -Level WARN "Optional tag not assigned: $($_.Exception.Message)" }
    #endregion

    #region 4. Verify ----------------------------------------------------------------------------------------
    Write-JobLog -Level STEP 'Verifying the datastore on every host'
    $missing = @($hosts | Where-Object {
        $d = Get-Datastore -VMHost $_ -Server $vi -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $DatastoreName } | Select-Object -First 1
        -not $d -or ($d.PSObject.Properties['Accessible'] -and -not $d.Accessible)
    })
    if ($missing.Count) { throw "Datastore '$DatastoreName' is not accessible on: $(@($missing.Name) -join ', ')." }
    $final = Get-Datastore -Name $DatastoreName -Server $vi | Select-Object -First 1
    Write-JobLog -Level OK "Datastore '$DatastoreName' accessible on all $($hosts.Count) host(s): $([math]::Round([double]$final.CapacityGB)) GB."
    #endregion

    $auth = $Context.Authorization
    $appr = $Context.Approval
    return [ordered]@{
        Datastore        = $DatastoreName
        Type             = $(if ($DatastoreType -eq 'NFS') { "NFS $NfsVersion" } else { 'VMFS 6' })
        Site             = $Site
        Cluster          = $Cluster
        Hosts            = $hosts.Count
        CapacityGB       = [math]::Round([double]$final.CapacityGB)
        Backing          = $(if ($DatastoreType -eq 'VMFS') { $Lun } else { "${NfsServer}:$NfsPath" })
        DatastoreCluster = $(if ($pod) { [string]$pod.Name } else { 'none' })
        ChangeTicket     = $ChangeTicket
        AuthorizedBy     = $(if ($auth) { [string]$auth.by } else { '' })
        AuthorizedAt     = $(if ($auth) { [string]$auth.at } else { '' })
        AuthorizedFrom   = $(if ($auth) { [string]$auth.ip } else { '' })
        ApprovedBy       = $(if ($appr) { [string]$appr.decidedBy } else { '' })
        NextSteps        = @(
            'The datastore appears in request forms after the next scheduled inventory refresh.',
            'Update the storage capacity records / CMDB with the new datastore.'
        )
    }
}
catch {
    $err = $_
    if ($createdOn.Count -and $Context.RollbackOnFailure) {
        Write-JobLog -Level WARN "Rolling back: removing datastore '$DatastoreName'."
        $targets = if ($DatastoreType -eq 'VMFS') { @($createdOn[0]) } else { @($createdOn.ToArray()) }
        foreach ($h in $targets) {
            try { Remove-Datastore -Datastore $DatastoreName -VMHost $h -Confirm:$false -Server $vi; Write-JobLog -Level WARN "Removed '$DatastoreName' from $($h.Name)." }
            catch { Write-JobLog -Level ERROR "Rollback failed on $($h.Name) - remove '$DatastoreName' manually: $($_.Exception.Message)" }
        }
    }
    if ($createdPod -and $Context.RollbackOnFailure) {
        try { Remove-DatastoreCluster -DatastoreCluster $createdPod -Confirm:$false -Server $vi; Write-JobLog -Level WARN "Removed datastore cluster '$NewDatastoreCluster'." }
        catch { Write-JobLog -Level ERROR "Rollback failed - remove datastore cluster '$NewDatastoreCluster' manually: $($_.Exception.Message)" }
    }
    throw $err
}
finally {
    if ($locked) {
        try {
            if ($rescanned) { Exit-PortalStorageLock -Site $Site -Cluster $Cluster -Rescanned -By $by }
            else { Exit-PortalStorageLock -Site $Site -Cluster $Cluster }
            Write-JobLog "Storage lock released on $Site/$Cluster."
        }
        catch { Write-JobLog -Level ERROR "Could not release the storage lock on $Site/${Cluster}: $($_.Exception.Message) (it expires after operations.storage.lockTimeoutMinutes)." }
    }
}
