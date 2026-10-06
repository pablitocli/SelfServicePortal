#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - read-only vSphere health report (hosts, alarms, clusters, datastores, snapshots, VMware Tools,
    optional orphaned VMDKs).
.DESCRIPTION
    Uses Get-View with selected properties so large inventories stay fast. Nothing is changed.
    Datastore status: FAIL below the site minDatastoreFreePercent, WARN below minDatastoreFreePercent + 10, else OK.
    Orphaned VMDKs (optional, slow): *.vmdk files found with the datastore browser (SearchDatastoreSubFolders) that are
    not referenced by any VM or template (LayoutEx), excluding extent / delta / CBT files
    (-flat, -delta, -ctk, -sesparse, -rdm, -rdmp). Review each one before deleting anything.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [bool] $IncludeOrphanedVmdk = $false,
    [ValidateRange(1, 3650)] [int] $SnapshotAgeDays = 7,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}

$vi = $Context.VIServer
if (-not $vi) { throw 'No vCenter session (the item requires a vCenter connection).' }
$minFree = 15
if ($Context.Site -and $Context.Site.defaults -and $null -ne $Context.Site.defaults.minDatastoreFreePercent) {
    $minFree = [double]$Context.Site.defaults.minDatastoreFreePercent
}
$warnFree = $minFree + 10
$now = Get-Date
$key = { param($m) if ($null -eq $m) { '' } else { [string]$m } }   # MoRef -> string key

# --- Clusters --------------------------------------------------------------------------------------------------
Write-JobLog -Level STEP 'Reading clusters'
$clusterViews = @(Get-View -Server $vi -ViewType ClusterComputeResource -Property Name, ConfigurationEx.DasConfig.Enabled,
    ConfigurationEx.DasConfig.AdmissionControlEnabled, ConfigurationEx.DrsConfig.Enabled, ConfigurationEx.DrsConfig.DefaultVmBehavior,
    Summary.CurrentEVCModeKey)
$clusterName = @{}
$clusterRows = foreach ($c in $clusterViews) {
    $clusterName[(& $key $c.MoRef)] = $c.Name
    $ha  = [bool]$c.ConfigurationEx.DasConfig.Enabled
    $drs = [bool]$c.ConfigurationEx.DrsConfig.Enabled
    $issues = @()
    if (-not $ha)  { $issues += 'HA disabled' }
    if (-not $drs) { $issues += 'DRS disabled' }
    [ordered]@{
        Cluster          = $c.Name
        HAEnabled        = $ha
        AdmissionControl = [bool]$c.ConfigurationEx.DasConfig.AdmissionControlEnabled
        DRSEnabled       = $drs
        DRSAutomation    = $(if ($drs) { [string]$c.ConfigurationEx.DrsConfig.DefaultVmBehavior } else { '-' })
        EVCMode          = $(if ($c.Summary.CurrentEVCModeKey) { [string]$c.Summary.CurrentEVCModeKey } else { 'Disabled' })
        Status           = $(if ($issues) { 'WARN' } else { 'OK' })
        Detail           = ($issues -join '; ')
    }
}

# --- Hosts -----------------------------------------------------------------------------------------------------
Write-JobLog -Level STEP 'Reading hosts'
$hostViews = @(Get-View -Server $vi -ViewType HostSystem -Property Name, Parent, Runtime.ConnectionState, Runtime.InMaintenanceMode,
    Runtime.BootTime, Config.Product.Version, Config.Product.Build)
$hostRows = foreach ($h in ($hostViews | Sort-Object Name)) {
    $conn = [string]$h.Runtime.ConnectionState
    $maint = [bool]$h.Runtime.InMaintenanceMode
    $status = if ($conn -ne 'connected') { 'FAIL' } elseif ($maint) { 'WARN' } else { 'OK' }
    $uptime = if ($h.Runtime.BootTime) { [math]::Floor(($now - [datetime]$h.Runtime.BootTime).TotalDays) } else { $null }
    [ordered]@{
        Host        = $h.Name
        Cluster     = $(if ($clusterName.ContainsKey((& $key $h.Parent))) { $clusterName[(& $key $h.Parent)] } else { '(standalone)' })
        Connection  = $conn
        Maintenance = $maint
        Version     = [string]$h.Config.Product.Version
        Build       = [string]$h.Config.Product.Build
        UptimeDays  = $uptime
        Status      = $status
    }
}
Write-JobLog "Hosts: $(@($hostRows).Count), clusters: $(@($clusterRows).Count)"

# --- Triggered alarms (root folder aggregates the alarms of all descendants) -----------------------------------
Write-JobLog -Level STEP 'Reading triggered alarms'
$alarmRows = @()
try {
    $si = Get-View -Server $vi -Id 'ServiceInstance'
    $root = Get-View -Server $vi -Id $si.Content.RootFolder -Property TriggeredAlarmState
    $states = @($root.TriggeredAlarmState | Where-Object { $_ })
    if ($states.Count) {
        $names = @{}
        $entityIds = @($states | ForEach-Object { $_.Entity } | Where-Object { $_ } | Group-Object { & $key $_ } | ForEach-Object { $_.Group[0] })
        $alarmIds  = @($states | ForEach-Object { $_.Alarm }  | Where-Object { $_ } | Group-Object { & $key $_ } | ForEach-Object { $_.Group[0] })
        if ($entityIds) { foreach ($v in @(Get-View -Server $vi -Id $entityIds -Property Name)) { $names[(& $key $v.MoRef)] = $v.Name } }
        if ($alarmIds)  { foreach ($v in @(Get-View -Server $vi -Id $alarmIds -Property Info.Name)) { $names[(& $key $v.MoRef)] = $v.Info.Name } }
        $alarmRows = foreach ($s in ($states | Sort-Object Time -Descending)) {
            $st = [string]$s.OverallStatus
            [ordered]@{
                Entity = $(if ($names.ContainsKey((& $key $s.Entity))) { $names[(& $key $s.Entity)] } else { & $key $s.Entity })
                Alarm  = $(if ($names.ContainsKey((& $key $s.Alarm)))  { $names[(& $key $s.Alarm)] }  else { & $key $s.Alarm })
                Status = $(switch ($st) { 'red' { 'CRITICAL' } 'yellow' { 'WARN' } 'green' { 'OK' } default { $st.ToUpper() } })
                Time   = $(if ($s.Time) { ([datetime]$s.Time).ToUniversalTime().ToString('yyyy-MM-dd HH:mm') } else { '' })
                Acknowledged = [bool]$s.Acknowledged
            }
        }
    }
}
catch { Write-JobLog -Level WARN "Triggered alarms could not be read: $($_.Exception.Message)" }

# --- Datastores ------------------------------------------------------------------------------------------------
Write-JobLog -Level STEP 'Reading datastores'
$dsProps = @('Name', 'Summary.Capacity', 'Summary.FreeSpace', 'Summary.Type', 'Summary.Accessible')
if ($IncludeOrphanedVmdk) { $dsProps += 'Browser' }
$dsViews = @(Get-View -Server $vi -ViewType Datastore -Property $dsProps)
$dsRows = foreach ($d in ($dsViews | Sort-Object Name)) {
    $cap = [double]$d.Summary.Capacity; $free = [double]$d.Summary.FreeSpace
    $pct = if ($cap -gt 0) { [math]::Round($free / $cap * 100, 1) } else { 0 }
    $status = if (-not $d.Summary.Accessible) { 'FAIL' } elseif ($pct -lt $minFree) { 'FAIL' } elseif ($pct -lt $warnFree) { 'WARN' } else { 'OK' }
    [ordered]@{
        Datastore   = $d.Name
        Type        = [string]$d.Summary.Type
        CapacityGB  = [math]::Round($cap / 1GB, 1)
        FreeGB      = [math]::Round($free / 1GB, 1)
        FreePercent = $pct
        Accessible  = [bool]$d.Summary.Accessible
        Status      = $status
    }
}

# --- VMs: snapshots and VMware Tools ---------------------------------------------------------------------------
Write-JobLog -Level STEP 'Reading virtual machines'
$vmProps = @('Name', 'Config.Template', 'Runtime.PowerState', 'Guest.ToolsVersionStatus2', 'Guest.ToolsRunningStatus', 'Snapshot')
if ($IncludeOrphanedVmdk) { $vmProps += 'LayoutEx.File' }
$vmViews = @(Get-View -Server $vi -ViewType VirtualMachine -Property $vmProps)
$cutoff = $now.AddDays(-$SnapshotAgeDays)

function Get-SnapshotTreeNode { param($Nodes) foreach ($n in @($Nodes)) { if ($n) { $n; Get-SnapshotTreeNode -Nodes $n.ChildSnapshotList } } }

$snapRows = [System.Collections.Generic.List[object]]::new()
$toolsRows = [System.Collections.Generic.List[object]]::new()
foreach ($v in ($vmViews | Sort-Object Name)) {
    if ($v.Config.Template) { continue }
    # Snapshots: the view narrows candidates; Get-Snapshot (sizes) runs only for VMs with old snapshots.
    $old = @(Get-SnapshotTreeNode -Nodes $v.Snapshot.RootSnapshotList | Where-Object { $_.CreateTime -and [datetime]$_.CreateTime -lt $cutoff })
    if ($old.Count) {
        $sizes = @{}
        try {
            $vmObj = Get-VM -Server $vi -Id (& $key $v.MoRef)
            foreach ($s in @(Get-Snapshot -Server $vi -VM $vmObj -ErrorAction SilentlyContinue)) { $sizes["$($s.Name)|$(([datetime]$s.Created).ToString('s'))"] = $s.SizeGB }
        }
        catch { Write-JobLog -Level WARN "Snapshot sizes for $($v.Name) not available: $($_.Exception.Message)" }
        foreach ($s in $old) {
            $created = [datetime]$s.CreateTime
            $size = $sizes["$($s.Name)|$($created.ToString('s'))"]
            $snapRows.Add([ordered]@{
                VM       = $v.Name
                Snapshot = [string]$s.Name
                Created  = $created.ToString('yyyy-MM-dd HH:mm')
                AgeDays  = [math]::Floor(($now - $created).TotalDays)
                SizeGB   = $(if ($null -ne $size) { [math]::Round([double]$size, 2) } else { '' })
                Status   = 'WARN'
            })
        }
    }
    # VMware Tools (powered-on VMs only)
    if ([string]$v.Runtime.PowerState -ne 'poweredOn') { continue }
    $ver = [string]$v.Guest.ToolsVersionStatus2; $run = [string]$v.Guest.ToolsRunningStatus
    $issues = @(); $status = 'WARN'
    if ($ver -eq 'guestToolsNotInstalled') { $issues += 'notInstalled'; $status = 'FAIL' }
    else {
        if ($ver -in 'guestToolsTooOld', 'guestToolsBlacklisted') { $issues += 'toolsOld (unsupported)'; $status = 'FAIL' }
        elseif ($ver -in 'guestToolsNeedUpgrade', 'guestToolsSupportedOld') { $issues += 'toolsOld' }
        if ($run -and $run -ne 'guestToolsRunning') { $issues += 'notRunning' }
    }
    if ($issues) {
        $toolsRows.Add([ordered]@{ VM = $v.Name; Issue = ($issues -join ', '); VersionStatus = $ver; RunningStatus = $run; Status = $status })
    }
}

# --- Orphaned VMDKs (optional) ---------------------------------------------------------------------------------
$orphanRows = [System.Collections.Generic.List[object]]::new()
if ($IncludeOrphanedVmdk) {
    Write-JobLog -Level STEP 'Searching datastores for orphaned VMDK files (this can take a while)'
    $attached = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($v in $vmViews) { foreach ($f in @($v.LayoutEx.File)) { if ($f -and $f.Name) { [void]$attached.Add(([string]$f.Name).Trim()) } } }
    $exclude = '-(flat|delta|ctk|sesparse|rdm|rdmp)\.vmdk$'
    $spec = if ('VMware.Vim.HostDatastoreBrowserSearchSpec' -as [type]) {
        $s = New-Object VMware.Vim.HostDatastoreBrowserSearchSpec
        $s.MatchPattern = @('*.vmdk')
        $s.Details = New-Object VMware.Vim.FileQueryFlags -Property @{ FileSize = $true; Modification = $true; FileType = $true; FileOwner = $false }
        $s
    } else { [pscustomobject]@{ MatchPattern = @('*.vmdk') } }
    foreach ($d in ($dsViews | Sort-Object Name)) {
        if (-not $d.Summary.Accessible -or -not $d.Browser) { continue }
        try {
            $browser = Get-View -Server $vi -Id $d.Browser
            $results = @($browser.SearchDatastoreSubFolders("[$($d.Name)]", $spec))
            foreach ($r in $results) {
                $folder = [string]$r.FolderPath
                if ($folder -notmatch '[/\]]$') { $folder += '/' }
                if ($folder.EndsWith(']')) { $folder += ' ' }
                foreach ($f in @($r.File)) {
                    if (-not $f -or [string]$f.Path -match $exclude) { continue }
                    $full = $folder + $f.Path
                    if ($attached.Contains($full)) { continue }
                    $orphanRows.Add([ordered]@{
                        Datastore = $d.Name
                        Path      = $full
                        SizeGB    = $(if ($null -ne $f.FileSize) { [math]::Round([double]$f.FileSize / 1GB, 2) } else { '' })
                        Modified  = $(if ($f.Modification) { ([datetime]$f.Modification).ToString('yyyy-MM-dd') } else { '' })
                        Status    = 'WARN'
                    })
                }
            }
        }
        catch { Write-JobLog -Level WARN "Datastore $($d.Name) could not be searched: $($_.Exception.Message)" }
    }
    Write-JobLog "Orphaned VMDK candidates: $($orphanRows.Count)"
}

# --- Report ----------------------------------------------------------------------------------------------------
$dsBelow = @($dsRows | Where-Object { $_.Status -ne 'OK' }).Count
$sections = @(
    New-PortalReportSection -Title 'Hosts' -Rows $hostRows -Columns Host, Cluster, Connection, Maintenance, Version, Build, UptimeDays, Status
    New-PortalReportSection -Title 'Triggered alarms' -Rows $alarmRows -Columns Entity, Alarm, Status, Time, Acknowledged
    New-PortalReportSection -Title 'Clusters' -Rows $clusterRows -Columns Cluster, HAEnabled, AdmissionControl, DRSEnabled, DRSAutomation, EVCMode, Status, Detail -Note 'WARN when HA or DRS is disabled.'
    New-PortalReportSection -Title 'Datastores' -Rows $dsRows -Columns Datastore, Type, CapacityGB, FreeGB, FreePercent, Accessible, Status -Note "FAIL below $minFree% free (site minimum), WARN below $warnFree% free."
    New-PortalReportSection -Title "Snapshots older than $SnapshotAgeDays days" -Rows $snapRows -Columns VM, Snapshot, Created, AgeDays, SizeGB, Status
    New-PortalReportSection -Title 'VMware Tools' -Rows $toolsRows -Columns VM, Issue, VersionStatus, RunningStatus, Status -Note 'Powered-on VMs with Tools not installed, not running or out of date.'
)
if ($IncludeOrphanedVmdk) {
    $sections += New-PortalReportSection -Title 'Orphaned VMDKs' -Rows $orphanRows -Columns Datastore, Path, SizeGB, Modified, Status `
        -Note 'VMDK descriptors not referenced by any VM or template. Candidates only: verify (replicas, backups, unregistered VMs) before deleting.'
}
$summary = [ordered]@{
    'Hosts'                      = @($hostRows).Count
    'Triggered alarms'           = @($alarmRows).Count
    'Datastores below threshold' = $dsBelow
    'Old snapshots'              = $snapRows.Count
    'Tools issues'               = $toolsRows.Count
}
if ($IncludeOrphanedVmdk) { $summary['Orphaned VMDKs'] = $orphanRows.Count }

$files = New-PortalReport -Title "vSphere health - $Site" -Subtitle "vCenter $($vi.Name)" -Context $Context -Sections $sections -Summary $summary -FileName 'vsphere-health'
Write-JobLog -Level OK "Report written: $($files[0].name)"

$result = [ordered]@{
    Site                     = $Site
    Hosts                    = @($hostRows).Count
    TriggeredAlarms          = @($alarmRows).Count
    DatastoresBelowThreshold = $dsBelow
    OldSnapshots             = $snapRows.Count
    ToolsIssues              = $toolsRows.Count
}
if ($IncludeOrphanedVmdk) { $result['OrphanedVmdks'] = $orphanRows.Count }
$result['Report'] = $files[0].name
return $result
