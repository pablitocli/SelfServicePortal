#Requires -Version 7.2
<#
.SYNOPSIS
    Portal.Core - shared primitives for the Self-Service Portal.
.DESCRIPTION
    Paths, configuration, JSON persistence (atomic writes), cross-process locking and audit logging.
    This module is loaded by the Pode web server (every runspace) AND by the out-of-process job runner,
    so it must not depend on Pode.
#>

Set-StrictMode -Version Latest

$script:ConfigCache = $null
$script:ConfigStamp = [datetime]::MinValue

function Get-PortalRoot {
    [CmdletBinding()] param()
    if ($env:SSP_PORTAL_ROOT -and (Test-Path -LiteralPath $env:SSP_PORTAL_ROOT)) { return $env:SSP_PORTAL_ROOT }
    return (Split-Path -Parent $PSScriptRoot)
}

function Get-PortalPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Root', 'Config', 'CatalogItems', 'CatalogSchema', 'Handlers', 'AutomationLib', 'Automation',
                     'Requests', 'Inventory', 'JobLogs', 'Audit', 'PortalLog', 'Web', 'Reports')]
        [string] $Name
    )
    $root = Get-PortalRoot
    switch ($Name) {
        'Root'          { $root }
        'Config'        { Join-Path $root 'config/portal.config.json' }
        'CatalogItems'  { Join-Path $root 'catalog/items' }
        'CatalogSchema' { Join-Path $root 'catalog/schema/catalog-item.schema.json' }
        'Automation'    { Join-Path $root 'automation' }
        'Handlers'      { Join-Path $root 'automation/handlers' }
        'AutomationLib' { Join-Path $root 'automation/lib' }
        'Requests'      { Join-Path $root 'data/requests' }
        'Inventory'     { Join-Path $root 'data/inventory' }
        'Reports'       { Join-Path $root 'data/reports' }
        'JobLogs'       { Join-Path $root 'logs/jobs' }
        'Audit'         { Join-Path $root 'logs/audit.jsonl' }
        'PortalLog'     { Join-Path $root 'logs/portal.log' }
        'Web'           { Join-Path $root 'web' }
    }
}

function ConvertTo-PortalHashtable {
    <# Deep-converts PSCustomObject graphs (e.g. Pode request bodies) into ordered hashtables. #>
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)] $InputObject)
    process {
        if ($null -eq $InputObject) { return $null }
        if ($InputObject -is [System.Collections.IDictionary]) {
            $h = [ordered]@{}
            foreach ($k in $InputObject.Keys) { $h[[string]$k] = ConvertTo-PortalHashtable $InputObject[$k] }
            return $h
        }
        if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
            $h = [ordered]@{}
            foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-PortalHashtable $p.Value }
            return $h
        }
        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            return , @($InputObject | ForEach-Object { ConvertTo-PortalHashtable $_ })
        }
        return $InputObject
    }
}

function Read-PortalJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = [System.IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json -AsHashtable -Depth 64)
}

function Write-PortalJson {
    <# Atomic write: serialize to a temp file in the same folder, then replace the target. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] $Value
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    $tmp = Join-Path $dir (".{0}.{1}.tmp" -f (Split-Path -Leaf $Path), [guid]::NewGuid().ToString('N'))
    $json = $Value | ConvertTo-Json -Depth 64
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::Move($tmp, $Path, $true)
}

function Invoke-PortalLock {
    <#
    .SYNOPSIS Runs a scriptblock under a named, cross-process mutex (web runspaces + job runner processes).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
        [int] $TimeoutSeconds = 30
    )
    $safe = ($Name -replace '[^A-Za-z0-9_-]', '_')
    $mutex = [System.Threading.Mutex]::new($false, "Global\SspPortal_$safe")
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds)) }
        catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw "Timed out waiting for lock '$Name'." }
        return (& $ScriptBlock)
    }
    finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Get-PortalConfig {
    <# Returns the portal configuration (hashtable). Re-read automatically when the file changes. #>
    [CmdletBinding()] param([switch] $Force)
    $path = Get-PortalPath -Name Config
    if (-not (Test-Path -LiteralPath $path)) {
        # First run from a release package: only *.default.json files are shipped (never overwrite a live config).
        $dir = Split-Path -Parent $path
        foreach ($n in 'portal.config', 'local-users') {
            $src = Join-Path $dir "$n.default.json"; $dst = Join-Path $dir "$n.json"
            if ((Test-Path -LiteralPath $src) -and -not (Test-Path -LiteralPath $dst)) { Copy-Item -LiteralPath $src -Destination $dst }
        }
    }
    if (-not (Test-Path -LiteralPath $path)) { throw "Portal configuration not found: $path" }
    $stamp = (Get-Item -LiteralPath $path).LastWriteTimeUtc
    if ($Force -or $null -eq $script:ConfigCache -or $stamp -ne $script:ConfigStamp) {
        $script:ConfigCache = Read-PortalJson -Path $path
        $script:ConfigStamp = $stamp
    }
    return $script:ConfigCache
}

function Get-PortalSite {
    [CmdletBinding()]
    param([string] $Code, [switch] $EnabledOnly)
    $sites = @((Get-PortalConfig).sites)
    if ($EnabledOnly) { $sites = @($sites | Where-Object { $_.enabled }) }
    if ($Code) { return ($sites | Where-Object { $_.code -eq $Code } | Select-Object -First 1) }
    return $sites
}

function Write-PortalLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')] [string] $Level = 'INFO'
    )
    $line = '{0:yyyy-MM-ddTHH:mm:ss.fffK} [{1}] {2}' -f (Get-Date), $Level, $Message
    $path = Get-PortalPath -Name PortalLog
    Invoke-PortalLock -Name 'portal-log' -ScriptBlock { Add-Content -LiteralPath $path -Value $line -Encoding utf8 } | Out-Null
}

function Write-PortalAudit {
    <# Append-only JSON Lines audit trail: who did what, on which request, when. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Actor,
        [Parameter(Mandatory)] [string] $Action,
        [string] $Target,
        [hashtable] $Details = @{}
    )
    $entry = [ordered]@{
        ts      = (Get-Date).ToUniversalTime().ToString('o')
        actor   = $Actor
        action  = $Action
        target  = $Target
        details = $Details
    } | ConvertTo-Json -Depth 10 -Compress
    $path = Get-PortalPath -Name Audit
    Invoke-PortalLock -Name 'audit' -ScriptBlock { Add-Content -LiteralPath $path -Value $entry -Encoding utf8 } | Out-Null
}

function Get-PortalTimestamp { (Get-Date).ToUniversalTime().ToString('o') }

function Get-PortalErrorDetail {
    <# Flattens an error and all inner exceptions into one readable line ("see inner exception" is useless in a UI). #>
    param($ErrorRecord)
    $ex = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
    $msgs = [System.Collections.Generic.List[string]]::new()
    $guard = 0
    while ($ex -and $guard++ -lt 10) {
        $m = ([string]$ex.Message) -replace '\s+', ' ' -replace '^\d{1,2}/\d{1,2}/\d{4} \d{1,2}:\d{2}:\d{2} [AP]M\s+', ''
        if ($m -and -not ($msgs | Where-Object { $_ -eq $m })) { $msgs.Add($m.Trim()) }
        $ex = $ex.InnerException
    }
    return ($msgs -join ' -> ')
}

function Get-PortalHandlerRoot {
    <# Folders from which catalog handlers may be executed (automation/handlers + config automation.allowedHandlerRoots). #>
    [CmdletBinding()] param()
    $roots = [System.Collections.Generic.List[string]]::new()
    $roots.Add([System.IO.Path]::GetFullPath((Get-PortalPath -Name Handlers)))
    $cfg = Get-PortalConfig
    if ($cfg.Contains('automation') -and $cfg.automation.Contains('allowedHandlerRoots')) {
        foreach ($r in @($cfg.automation.allowedHandlerRoots)) {
            if (-not $r) { continue }
            $full = if ([System.IO.Path]::IsPathRooted($r)) { $r } else { Join-Path (Get-PortalRoot) $r }
            $roots.Add([System.IO.Path]::GetFullPath($full))
        }
    }
    return @($roots | Select-Object -Unique)
}

function Resolve-PortalHandlerPath {
    <#
    .SYNOPSIS Resolves execution.handler to a full path and enforces the allowed handler roots.
    .DESCRIPTION
        "New-VsphereVM.ps1"               -> automation/handlers/New-VsphereVM.ps1
        "D:\Automation\Scripts\Do-X.ps1"   -> allowed only if under a root in automation.allowedHandlerRoots
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Handler, [switch] $MustExist)
    if ($Handler -notmatch '\.ps1$') { throw "Handler '$Handler' must be a .ps1 script." }
    $candidate = if ($Handler -match '^[A-Za-z0-9._-]+\.ps1$') { Join-Path (Get-PortalPath -Name Handlers) $Handler }
                 elseif ([System.IO.Path]::IsPathRooted($Handler)) { $Handler }
                 else { Join-Path (Get-PortalRoot) $Handler }
    $full = [System.IO.Path]::GetFullPath($candidate)
    $sep  = [System.IO.Path]::DirectorySeparatorChar
    $ok = $false
    foreach ($root in Get-PortalHandlerRoot) {
        $prefix = $root.TrimEnd('\', '/') + $sep
        if ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $ok = $true; break }
    }
    if (-not $ok) { throw "Handler path '$Handler' is outside the allowed handler folders (automation/handlers or automation.allowedHandlerRoots in portal.config.json)." }
    if ($MustExist -and -not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Handler script not found: $full" }
    return $full
}

function Resolve-PortalSiteValue {
    <#
    .SYNOPSIS Per-site parameter values. { "DC1": "TPL-A", "DC2": "TPL-B", "*": "default" } -> value for the site.
    #>
    param($Value, [string] $Site)
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Site -and $Value.Contains($Site)) { return $Value[$Site] }
        if ($Value.Contains('*')) { return $Value['*'] }
    }
    # "@site:<key>" -> sites[].catalogValues.<key> of the selected site (config segment, see catalog.siteValues).
    if ($Value -is [string] -and $Value.StartsWith('@site:')) {
        $key = $Value.Substring(6)
        $siteCfg = if ($Site) { Get-PortalSite -Code $Site } else { $null }
        if (-not $siteCfg -or -not $siteCfg.Contains('catalogValues') -or -not $siteCfg.catalogValues.Contains($key)) { return $null }
        return $siteCfg.catalogValues[$key]
    }
    return $Value
}

function Resolve-PortalTeamToken {
    <# "@datacenter" / "@cloud" (config catalog.teamRoles) -> team id. Plain team ids are returned unchanged; unmapped roles -> $null. #>
    param([string] $Team)
    if (-not $Team -or -not $Team.StartsWith('@')) { return $Team }
    $cfg = Get-PortalConfig
    $roles = if ($cfg.Contains('catalog') -and $cfg.catalog.Contains('teamRoles')) { $cfg.catalog.teamRoles } else { @{} }
    $role = $Team.Substring(1)
    if ($roles.Contains($role) -and $roles[$role]) { return [string]$roles[$role] }
    return $null
}

function Get-PortalWorkloadCluster {
    <# Maps a workload (App / DB) to the site cluster configured in sites[].defaults.workloadClusters. #>
    param([string] $Site, [string] $Workload)
    if (-not $Site -or -not $Workload) { return $null }
    $s = Get-PortalSite -Code $Site
    if (-not $s -or -not $s.Contains('defaults') -or -not $s.defaults.Contains('workloadClusters')) { return $null }
    $map = $s.defaults.workloadClusters
    foreach ($k in $map.Keys) { if ($k -ieq $Workload) { return $map[$k] } }
    return $null
}

Export-ModuleMember -Function Get-PortalRoot, Get-PortalPath, ConvertTo-PortalHashtable, Read-PortalJson, Write-PortalJson,
    Invoke-PortalLock, Get-PortalConfig, Get-PortalSite, Write-PortalLog, Write-PortalAudit, Get-PortalTimestamp, Get-PortalErrorDetail,
    Get-PortalHandlerRoot, Resolve-PortalHandlerPath, Resolve-PortalSiteValue, Resolve-PortalTeamToken, Get-PortalWorkloadCluster
