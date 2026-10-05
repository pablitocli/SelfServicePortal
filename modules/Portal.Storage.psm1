#Requires -Version 7.2
<#
.SYNOPSIS
    Portal.Storage - storage device discovery and controlled HBA rescans for the "New datastore" item.
.DESCRIPTION
    A storage rescan touches every host of a cluster, so the portal treats it as a sensitive operation:
      * every rescan requires a recent re-authentication in the portal (security.reauth window, default 5 minutes);
      * only one rescan per cluster at a time (lock), and a cooldown between rescans (operations.storage.rescanCooldownMinutes, default 10);
      * who started it, when and from which IP is kept in the scan state and in the audit log.
    The scan runs out of process (automation/Get-PortalStorageDevices.ps1) and writes
    data/inventory/storage/<SITE>__<cluster>.json: state, devices (unused LUNs visible to the cluster), history of rescans.
    The catalog lookup 'storageDevices' only reads that file, so opening a form never rescans anything.
    Job handlers (New datastore) take the same lock with Enter-PortalStorageLock / Exit-PortalStorageLock.
#>

Set-StrictMode -Version Latest

function Get-SV { param($T, [string] $K, $D = $null) if ($T -is [System.Collections.IDictionary] -and $T.Contains($K) -and $null -ne $T[$K]) { $T[$K] } else { $D } }

function Get-PortalStorageSettings {
    $cfg = Get-PortalConfig
    $st = Get-SV (Get-SV $cfg 'operations' @{}) 'storage' @{}
    return [ordered]@{
        rescanCooldownMinutes = [int](Get-SV $st 'rescanCooldownMinutes' 10)
        lockTimeoutMinutes    = [int](Get-SV $st 'lockTimeoutMinutes' 30)
        minLunSizeGB          = [int](Get-SV $st 'minLunSizeGB' 1)
    }
}

function Get-PortalStorageStatePath {
    param([Parameter(Mandatory)] [string] $Site, [Parameter(Mandatory)] [string] $Cluster)
    if ($Site -notmatch '^[A-Za-z0-9_-]+$') { throw 'Invalid site code.' }
    $dir = Join-Path (Get-PortalPath -Name Inventory) 'storage'
    $null = New-Item -ItemType Directory -Path $dir -Force
    $safe = ($Cluster -replace '[^A-Za-z0-9_.-]', '_')
    return (Join-Path $dir ('{0}__{1}.json' -f $Site.ToUpper(), $safe))
}

function Get-PortalStorageState {
    <# Current scan state for a cluster (never null). #>
    [CmdletBinding()] param([Parameter(Mandatory)] [string] $Site, [Parameter(Mandatory)] [string] $Cluster)
    $p = Get-PortalStorageStatePath -Site $Site -Cluster $Cluster
    $s = if (Test-Path -LiteralPath $p) { Read-PortalJson -Path $p } else { $null }
    if (-not $s) { $s = [ordered]@{ site = $Site.ToUpper(); cluster = $Cluster; state = 'Never'; devices = @(); history = @() } }
    foreach ($k in 'devices', 'history') { if (-not $s.Contains($k)) { $s[$k] = @() } }
    return $s
}

function Test-PortalStorageLockActive {
    param($State)
    $lock = Get-SV $State 'lock'
    if (-not $lock) { return $false }
    $since = [datetime]::Parse([string]$lock.since, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    $max = (Get-PortalStorageSettings).lockTimeoutMinutes
    if (((Get-Date).ToUniversalTime() - $since).TotalMinutes -gt $max) { return $false }    # stale lock (crashed process)
    if ($lock.Contains('pid') -and $lock.pid -and $lock.host -eq [Environment]::MachineName) {
        $p = Get-Process -Id ([int]$lock.pid) -ErrorAction SilentlyContinue
        if (-not $p) { return $false }
    }
    return $true
}

function Get-PortalStorageCooldown {
    <# Seconds left before the next rescan of this cluster is allowed (0 = allowed). #>
    param($State)
    $last = Get-SV $State 'lastRescanAt'
    if (-not $last) { return 0 }
    $t = [datetime]::Parse([string]$last, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    $left = $t.AddMinutes((Get-PortalStorageSettings).rescanCooldownMinutes) - (Get-Date).ToUniversalTime()
    return [math]::Max(0, [int][math]::Ceiling($left.TotalSeconds))
}

function Update-PortalStorageState {
    param([string] $Site, [string] $Cluster, [scriptblock] $Mutate)
    $p = Get-PortalStorageStatePath -Site $Site -Cluster $Cluster
    $out = Invoke-PortalLock -Name ('storage-{0}' -f [IO.Path]::GetFileNameWithoutExtension($p)) -ScriptBlock {
        $s = Get-PortalStorageState -Site $Site -Cluster $Cluster
        $r = & $Mutate $s
        Write-PortalJson -Path $p -Value $s
        , @($r)
    }
    return $out
}

function Start-PortalStorageRescan {
    <#
    .SYNOPSIS Starts a storage scan of one cluster (with -Rescan: HBA + VMFS rescan on every host) out of process.
    .DESCRIPTION Throws with Exception.Data['status'] = 409 (lock) or 429 (cooldown). The caller enforces re-authentication.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Site, [Parameter(Mandatory)] [string] $Cluster,
        [Parameter(Mandatory)] $User, [string] $Ip, [switch] $Rescan, [string] $ItemId
    )
    $siteCfg = Get-PortalSite -Code $Site
    if (-not $siteCfg -or -not $siteCfg.enabled) { throw "Site $Site is not enabled." }
    $inv = Read-PortalJson -Path (Join-Path (Get-PortalPath -Name Inventory) "$($Site.ToUpper()).json")
    if ($inv -and @($inv.clusters).Count -and @($inv.clusters | ForEach-Object { $_.name }) -notcontains $Cluster) { throw "Cluster '$Cluster' is not in the inventory of $Site." }
    $allowed = @(Get-SV (Get-SV $siteCfg 'defaults' @{}) 'allowedClusters' @())
    if ($allowed.Count -and $allowed -notcontains $Cluster) { throw "Cluster '$Cluster' is not allowed for portal operations on $Site." }

    $now = Get-PortalTimestamp
    $who = [string]$User.username
    $result = Update-PortalStorageState -Site $Site -Cluster $Cluster -Mutate {
        param($s)
        if (Test-PortalStorageLockActive -State $s) {
            $ex = [System.InvalidOperationException]::new("A storage operation is already running on cluster $Cluster (started by $($s.lock.by) at $($s.lock.since)). Wait for it to finish.")
            $ex.Data['status'] = 409; throw $ex
        }
        if ($Rescan) {
            $left = Get-PortalStorageCooldown -State $s
            if ($left -gt 0) {
                $ex = [System.InvalidOperationException]::new(("Cluster {0} was rescanned recently by {1}. Next rescan allowed in {2} min {3:D2} s." -f $Cluster, (Get-SV $s 'lastRescanBy' '?'), [int][math]::Floor($left / 60), ($left % 60)))
                $ex.Data['status'] = 429; $ex.Data['retryAfter'] = $left; throw $ex
            }
        }
        $s['state'] = 'Running'; $s['error'] = $null
        $s['lock'] = [ordered]@{ by = $who; since = $now; ip = $Ip; reason = $(if ($Rescan) { 'rescan' } else { 'scan' }); host = [Environment]::MachineName; pid = $null }
        if ($Rescan) { $s['lastRescanAt'] = $now; $s['lastRescanBy'] = $who }
        $h = @($s.history) + [ordered]@{ at = $now; by = $who; ip = $Ip; action = $(if ($Rescan) { 'rescan' } else { 'scan' }); item = $ItemId; reauthenticated = $true }
        $s['history'] = @($h | Select-Object -Last 50)
        'ok'
    }
    $script = Join-Path (Get-PortalPath -Name Automation) 'Get-PortalStorageDevices.ps1'
    $args2 = @('-Site', $Site.ToUpper(), '-Cluster', "`"$Cluster`"")
    if ($Rescan) { $args2 += '-Rescan' }
    try {
        $proc = Start-PortalProcess -Script $script -Arguments $args2 -LogBase (Join-Path (Get-PortalPath -Name JobLogs) ("storage-{0}" -f ($Site.ToUpper())))
        $null = Update-PortalStorageState -Site $Site -Cluster $Cluster -Mutate { param($s) if ($s.Contains('lock') -and $s.lock) { $s.lock['pid'] = $proc.Id } }
    }
    catch {
        $msg = $_.Exception.Message
        $null = Update-PortalStorageState -Site $Site -Cluster $Cluster -Mutate { param($s) $s['state'] = 'Failed'; $s['error'] = $msg; $s['lock'] = $null }
        throw
    }
    Write-PortalAudit -Actor $who -Action $(if ($Rescan) { 'storage.rescan' } else { 'storage.scan' }) -Target "$($Site.ToUpper())/$Cluster" -Details @{ ip = $Ip; item = $ItemId; reauthenticated = $true }
    return (Get-PortalStorageView -Site $Site -Cluster $Cluster)
}

function Get-PortalStorageView {
    <# State for the UI (no internal fields). #>
    [CmdletBinding()] param([Parameter(Mandatory)] [string] $Site, [Parameter(Mandatory)] [string] $Cluster)
    $s = Get-PortalStorageState -Site $Site -Cluster $Cluster
    $running = Test-PortalStorageLockActive -State $s
    $state = [string]$s.state
    if ($state -eq 'Running' -and -not $running) { $state = 'Failed' }
    return [ordered]@{
        site = $s.site; cluster = $s.cluster; state = $state; running = $running
        scannedAt = Get-SV $s 'scannedAt'; lastRescanAt = Get-SV $s 'lastRescanAt'; lastRescanBy = Get-SV $s 'lastRescanBy'
        cooldownSeconds = (Get-PortalStorageCooldown -State $s); cooldownMinutes = (Get-PortalStorageSettings).rescanCooldownMinutes
        lockedBy = $(if ($running) { $s.lock.by } else { $null })
        devices = @($s.devices).Count; error = Get-SV $s 'error'
    }
}

function Get-PortalStorageDeviceOption {
    <# Options for the 'storageDevices' lookup: unused LUNs seen by every connected host of the cluster (cached scan). #>
    [CmdletBinding()] param([Parameter(Mandatory)] [string] $Site, [Parameter(Mandatory)] [string] $Cluster)
    $s = Get-PortalStorageState -Site $Site -Cluster $Cluster
    if ($s.state -eq 'Never' -or -not (Get-SV $s 'scannedAt')) {
        throw "No storage scan for cluster $Cluster yet. Use 'Rescan storage' (requires re-authentication)."
    }
    $min = (Get-PortalStorageSettings).minLunSizeGB
    $when = ([datetime]::Parse([string]$s.scannedAt, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')
    return @(@($s.devices) | Where-Object { [double](Get-SV $_ 'sizeGB' 0) -ge $min -and (Get-SV $_ 'allHosts' $false) } |
        Sort-Object { $_.canonicalName } | ForEach-Object {
            [ordered]@{ value = [string]$_.canonicalName
                        label = ('{0} - {1:N0} GB - {2} {3} (scanned {4} UTC)' -f $_.canonicalName, [double]$_.sizeGB, (Get-SV $_ 'vendor' ''), (Get-SV $_ 'model' ''), $when).Replace('  ', ' ') }
        })
}

function Enter-PortalStorageLock {
    <# Used by job handlers: takes the cluster lock (no cooldown check; the request was re-authenticated at submission). #>
    [CmdletBinding()] param([Parameter(Mandatory)] [string] $Site, [Parameter(Mandatory)] [string] $Cluster, [Parameter(Mandatory)] [string] $By, [string] $Reason = 'job')
    $now = Get-PortalTimestamp
    $null = Update-PortalStorageState -Site $Site -Cluster $Cluster -Mutate {
        param($s)
        if (Test-PortalStorageLockActive -State $s) { throw "A storage operation is already running on cluster $Cluster (by $($s.lock.by) since $($s.lock.since))." }
        $s['lock'] = [ordered]@{ by = $By; since = $now; reason = $Reason; host = [Environment]::MachineName; pid = $PID }
        $s['history'] = @(@($s.history) + [ordered]@{ at = $now; by = $By; action = $Reason } | Select-Object -Last 50)
    }
}

function Exit-PortalStorageLock {
    [CmdletBinding()] param([Parameter(Mandatory)] [string] $Site, [Parameter(Mandatory)] [string] $Cluster, [switch] $Rescanned, [string] $By)
    $now = Get-PortalTimestamp
    $null = Update-PortalStorageState -Site $Site -Cluster $Cluster -Mutate {
        param($s)
        $s['lock'] = $null
        if ($Rescanned) { $s['lastRescanAt'] = $now; $s['lastRescanBy'] = $By }
        if ($s.state -eq 'Running') { $s['state'] = 'Succeeded' }
    }
}

function Complete-PortalStorageScan {
    <# Called by Get-PortalStorageDevices.ps1 at the end of a scan. #>
    [CmdletBinding()] param([Parameter(Mandatory)] [string] $Site, [Parameter(Mandatory)] [string] $Cluster, $Devices, [string] $ErrorMessage, $Hosts)
    $now = Get-PortalTimestamp
    $null = Update-PortalStorageState -Site $Site -Cluster $Cluster -Mutate {
        param($s)
        $s['lock'] = $null
        if ($ErrorMessage) { $s['state'] = 'Failed'; $s['error'] = $ErrorMessage }
        else { $s['state'] = 'Succeeded'; $s['error'] = $null; $s['scannedAt'] = $now; $s['devices'] = @($Devices); $s['hosts'] = @($Hosts) }
    }
}

Export-ModuleMember -Function Get-PortalStorageSettings, Get-PortalStorageState, Get-PortalStorageView, Get-PortalStorageCooldown, Start-PortalStorageRescan,
    Get-PortalStorageDeviceOption, Enter-PortalStorageLock, Exit-PortalStorageLock, Complete-PortalStorageScan, Test-PortalStorageLockActive
