#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - before / after metrics of ESXi hosts around a change (MTU, firmware, multipathing, network...),
    from vCenter historical statistics (read-only).
.DESCRIPTION
    For every host of the cluster (or the hosts listed) and for a BEFORE and an AFTER window:
      datastore read / write latency (avg, p95, max), device max latency (avg, p95, max), network usage (avg, max)
      and dropped / errored packets (sum). Counters not collected at the vCenter statistics level are reported empty.
    Windows: either "around the change" (the same number of hours before and after ChangeTime) or explicit start /
    end times. Times are read in operations.troubleshooting.timeZone. vCenter keeps 30-minute rollups for 7 days and
    2-hour rollups for 30 days: older windows are smoothed.
    Result per metric: OK improved (lower latency / drops, < -5 %), WARN worse (> +5 %), or unchanged.
    Optional: current iSCSI vmkernel MTU and session count per host (esxcli, read-only).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] [string] $Cluster,
    [string] $HostNames,
    [Parameter(Mandatory)] [string] $ChangeDescription,
    [ValidateSet('AroundChange', 'Explicit')] [string] $WindowMode = 'AroundChange',
    [string] $ChangeTime,
    [ValidateRange(1, 168)] [int] $Hours = 48,
    [string] $BeforeStart,
    [string] $BeforeEnd,
    [string] $AfterStart,
    [string] $AfterEnd,
    [bool] $IncludeIscsi = $true,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}
Import-Module (Join-Path $Context.PortalRoot 'automation/lib/Portal.Diagnostics.psm1') -Force -DisableNameChecking

$vi = $Context.VIServer
$ops = if ($Context.Operations -and $Context.Operations.Contains('troubleshooting')) { $Context.Operations.troubleshooting } else { @{} }
$tz = if ($ops -and $ops['timeZone']) { [string]$ops['timeZone'] } else { 'UTC' }
$now = [DateTimeOffset]::UtcNow

# ---- Windows ------------------------------------------------------------------------------------
if ($WindowMode -eq 'AroundChange') {
    if (-not $ChangeTime) { throw 'Change time is required (yyyy-MM-dd HH:mm).' }
    $c = ConvertTo-PortalUtcTime -Text $ChangeTime -TimeZone $tz -Label 'Change time'
    $b0 = $c.AddHours(-$Hours); $b1 = $c; $a0 = $c; $a1 = $c.AddHours($Hours)
    if ($a1 -gt $now) { $a1 = $now }
}
else {
    foreach ($p in 'BeforeStart', 'BeforeEnd', 'AfterStart', 'AfterEnd') { if (-not (Get-Variable -Name $p -ValueOnly)) { throw "$p is required for explicit windows." } }
    $b0 = ConvertTo-PortalUtcTime -Text $BeforeStart -TimeZone $tz -Label 'Before start'; $b1 = ConvertTo-PortalUtcTime -Text $BeforeEnd -TimeZone $tz -Label 'Before end'
    $a0 = ConvertTo-PortalUtcTime -Text $AfterStart -TimeZone $tz -Label 'After start'; $a1 = ConvertTo-PortalUtcTime -Text $AfterEnd -TimeZone $tz -Label 'After end'
}
if ($b1 -le $b0 -or $a1 -le $a0) { throw 'Each window must end after it starts.' }
if ($a0 -lt $b1) { throw 'The after window must start when or after the before window ends.' }
if ($a0 -ge $now) { throw 'The after window has not started yet.' }
if (($a1 - $a0).TotalHours -lt 1) { throw 'The after window is shorter than one hour; wait for more data.' }
$lenRatio = ($a1 - $a0).TotalMinutes / ($b1 - $b0).TotalMinutes
if ($lenRatio -lt 0.5 -or $lenRatio -gt 2) { Write-JobLog -Level WARN "Windows have different lengths ($([math]::Round(($b1 - $b0).TotalHours, 1)) h vs $([math]::Round(($a1 - $a0).TotalHours, 1)) h): sums (drops / errors) are not comparable." }

# ---- Hosts --------------------------------------------------------------------------------------
$allowed = @($Context.Site.defaults.allowedClusters | Where-Object { $_ })
if ($allowed -and $allowed -notcontains $Cluster) { throw "Cluster '$Cluster' is not allowed for $Site (allowed: $($allowed -join ', '))." }
$cl = Get-Cluster -Name $Cluster -Server $vi -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $cl) { throw "Cluster '$Cluster' was not found in $Site." }
$hosts = @(Get-VMHost -Location $cl -Server $vi | Sort-Object Name)
if ($HostNames) {
    $want = @($HostNames -split '[,;\s]+' | Where-Object { $_ })
    $unknown = @($want | Where-Object { $w = $_; -not ($hosts | Where-Object { $_.Name -eq $w -or ($_.Name -split '\.')[0] -eq $w }) })
    if ($unknown.Count) { throw "Host(s) not in cluster ${Cluster}: $($unknown -join ', ')." }
    $hosts = @($hosts | Where-Object { $h = $_; $want | Where-Object { $h.Name -eq $_ -or ($h.Name -split '\.')[0] -eq $_ } })
}
if (-not $hosts.Count) { throw "Cluster '$Cluster' has no hosts." }
Write-JobLog -Level STEP "$($hosts.Count) host(s) - before $($b0.UtcDateTime.ToString('yyyy-MM-dd HH:mm'))..$($b1.UtcDateTime.ToString('MM-dd HH:mm')) UTC, after $($a0.UtcDateTime.ToString('yyyy-MM-dd HH:mm'))..$($a1.UtcDateTime.ToString('MM-dd HH:mm')) UTC"

$counters = [ordered]@{
    'Datastore read latency (ms)'  = @{ Id = 'datastore.totalReadLatency.average'; Kind = 'lat'; AnyInstance = $true }
    'Datastore write latency (ms)' = @{ Id = 'datastore.totalWriteLatency.average'; Kind = 'lat'; AnyInstance = $true }
    'Device max latency (ms)'      = @{ Id = 'disk.maxTotalLatency.latest'; Kind = 'lat' }
    'Network usage (KBps)'         = @{ Id = 'net.usage.average'; Kind = 'usage' }
    'Dropped packets rx'           = @{ Id = 'net.droppedRx.summation'; Kind = 'sum' }
    'Dropped packets tx'           = @{ Id = 'net.droppedTx.summation'; Kind = 'sum' }
    'Packet errors rx'             = @{ Id = 'net.errorsRx.summation'; Kind = 'sum' }
    'Packet errors tx'             = @{ Id = 'net.errorsTx.summation'; Kind = 'sum' }
}
function Get-P95 { param([double[]] $V) $s = @($V | Sort-Object); if (-not $s.Count) { return $null }; $s[[math]::Max(0, [int][math]::Ceiling(0.95 * $s.Count) - 1)] }
function Measure-Window {
    param($VMHost, [DateTimeOffset] $From, [DateTimeOffset] $To)
    $iv = Get-PortalStatInterval -Start $From
    $out = [ordered]@{}
    foreach ($k in $counters.Keys) {
        $c = $counters[$k]
        $p = @{ Entity = $VMHost; Stat = $c.Id; Start = $From.UtcDateTime.ToLocalTime(); Finish = $To.UtcDateTime.ToLocalTime(); Server = $vi; ErrorAction = 'Stop' }
        if ($iv.Realtime) { $p['Realtime'] = $true } else { $p['IntervalMins'] = $iv.Minutes }
        $rows = @(try { Get-Stat @p } catch { $null }) | Where-Object { $_ -and ($c['AnyInstance'] -or [string]$_.Instance -eq '') }
        $vals = @($rows | ForEach-Object { [double]$_.Value })
        if (-not $vals.Count) { $out[$k] = $null; continue }
        $out[$k] = switch ($c.Kind) {
            'sum'   { [ordered]@{ sum = [double](($vals | Measure-Object -Sum).Sum) } }
            'usage' { [ordered]@{ avg = [math]::Round(($vals | Measure-Object -Average).Average, 1); max = [double](($vals | Measure-Object -Maximum).Maximum) } }
            default { [ordered]@{ avg = [math]::Round(($vals | Measure-Object -Average).Average, 2); p95 = (Get-P95 $vals); max = [double](($vals | Measure-Object -Maximum).Maximum) } }
        }
    }
    return [pscustomobject]@{ Interval = $iv.Label; Values = $out }
}

$detail = [System.Collections.Generic.List[object]]::new()
$compare = [System.Collections.Generic.List[object]]::new()
$iscsiRows = [System.Collections.Generic.List[object]]::new()
foreach ($h in $hosts) {
    $bw = Measure-Window -VMHost $h -From $b0 -To $b1
    $aw = Measure-Window -VMHost $h -From $a0 -To $a1
    foreach ($k in $counters.Keys) {
        $kind = $counters[$k].Kind
        foreach ($agg in @(switch ($kind) { 'sum' { 'sum' } 'usage' { 'avg', 'max' } default { 'avg', 'p95', 'max' } })) {
            $bv = if ($bw.Values[$k]) { $bw.Values[$k][$agg] } else { $null }
            $av = if ($aw.Values[$k]) { $aw.Values[$k][$agg] } else { $null }
            $chg = if ($null -ne $bv -and $null -ne $av -and [double]$bv -ne 0) { [math]::Round(([double]$av / [double]$bv - 1) * 100, 1) } else { $null }
            $res = if ($null -eq $bv -or $null -eq $av) { 'n/a (counter not collected)' }
                   elseif ($kind -eq 'usage') { 'informational' }
                   elseif ([double]$bv -eq 0 -and [double]$av -eq 0) { 'OK unchanged (0)' }
                   elseif ([double]$bv -eq 0) { 'WARN worse (was 0)' }
                   elseif ($chg -le -5) { 'OK improved' } elseif ($chg -ge 5) { 'WARN worse' } else { 'unchanged' }
            $compare.Add([ordered]@{ Host = ($h.Name -split '\.')[0]; Metric = "$k ($agg)"; Before = $bv; After = $av; 'Change %' = $chg; Result = $res })
        }
    }
    $detail.Add([ordered]@{ Host = $h.Name; 'Before sampling' = $bw.Interval; 'After sampling' = $aw.Interval })
    if ($IncludeIscsi) {
        try {
            $esx = Get-EsxCli -VMHost $h -V2 -Server $vi -ErrorAction Stop
            $portals = @($esx.iscsi.networkportal.list.Invoke()); $sessions = @($esx.iscsi.session.list.Invoke()).Count
            $iscsiRows.Add([ordered]@{ Host = ($h.Name -split '\.')[0]; 'vmk = MTU' = (@($portals | ForEach-Object { "$($_.Vmknic)=$($_.MTU)" }) -join ' '); Sessions = $sessions })
        }
        catch { $iscsiRows.Add([ordered]@{ Host = ($h.Name -split '\.')[0]; 'vmk = MTU' = "n/a ($($_.Exception.Message))"; Sessions = '' }) }
    }
}

# Cluster-level view: average of the host values per metric.
$clusterRows = foreach ($g in @($compare | Group-Object { $_.Metric })) {
    $b = @($g.Group | Where-Object { $null -ne $_.Before } | ForEach-Object { [double]$_.Before }); $a = @($g.Group | Where-Object { $null -ne $_.After } | ForEach-Object { [double]$_.After })
    if (-not $b.Count -or -not $a.Count) { [ordered]@{ Metric = $g.Name; Before = $null; After = $null; 'Change %' = $null; Result = 'n/a (counter not collected)' }; continue }
    $bv = [math]::Round(($b | Measure-Object -Average).Average, 2); $av = [math]::Round(($a | Measure-Object -Average).Average, 2)
    $chg = if ($bv -ne 0) { [math]::Round(($av / $bv - 1) * 100, 1) } else { $null }
    $res = if ($g.Name -like 'Network usage*') { 'informational' } elseif ($bv -eq 0 -and $av -eq 0) { 'OK unchanged (0)' } elseif ($bv -eq 0) { 'WARN worse (was 0)' } elseif ($chg -le -5) { 'OK improved' } elseif ($chg -ge 5) { 'WARN worse' } else { 'unchanged' }
    [ordered]@{ Metric = $g.Name; Before = $bv; After = $av; 'Change %' = $chg; Result = $res }
}
$clusterRows = @($clusterRows)

$fmt = { param($t) $t.UtcDateTime.ToString('yyyy-MM-dd HH:mm') + ' UTC' }
$sections = @(
    New-PortalReportSection -Title 'Cluster summary (average of hosts)' -Columns 'Metric', 'Before', 'After', 'Change %', 'Result' -Rows $clusterRows -Note 'Latency and packet counters: lower is better. Network usage is shown for context (workload level).'
    New-PortalReportSection -Title 'Per host' -Columns 'Host', 'Metric', 'Before', 'After', 'Change %', 'Result' -Rows $compare
    New-PortalReportSection -Title 'Windows' -Columns 'Window', 'From', 'To', 'Hours' -Rows @(
        [ordered]@{ Window = 'Before'; From = (& $fmt $b0); To = (& $fmt $b1); Hours = [math]::Round(($b1 - $b0).TotalHours, 1) },
        [ordered]@{ Window = 'After'; From = (& $fmt $a0); To = (& $fmt $a1); Hours = [math]::Round(($a1 - $a0).TotalHours, 1) })
    New-PortalReportSection -Title 'Sampling per host' -Columns 'Host', 'Before sampling', 'After sampling' -Rows $detail
)
if ($IncludeIscsi) { $sections += New-PortalReportSection -Title 'iSCSI now' -Columns 'Host', 'vmk = MTU', 'Sessions' -Rows $iscsiRows }

$improved = @($clusterRows | Where-Object { $_.Result -like 'OK improved*' }).Count
$worse = @($clusterRows | Where-Object { $_.Result -like 'WARN*' }).Count
$files = New-PortalReport -Title "Change impact - $ChangeDescription" -Subtitle "$Site / $Cluster" -Context $Context -Sections $sections -FileName 'change-impact' -Summary ([ordered]@{
    Hosts = $hosts.Count; 'Metrics improved' = $improved; 'Metrics worse' = $worse
    'Write latency avg (before > after ms)' = $(($clusterRows | Where-Object { $_.Metric -eq 'Datastore write latency (ms) (avg)' } | ForEach-Object { "$($_.Before) > $($_.After)" }) | Select-Object -First 1)
})
Write-JobLog -Level OK "$improved metric(s) improved, $worse worse."
return [ordered]@{
    Change    = $ChangeDescription
    Hosts     = $hosts.Count
    Improved  = $improved
    Worse     = $worse
    KeyResults = @($clusterRows | Where-Object { $_.Metric -match 'latency \(ms\) \(avg\)|max latency \(ms\) \(p95\)|Dropped|errors' } | ForEach-Object { "$($_.Metric): $($_.Before) -> $($_.After) ($($_.Result))" })
    Report    = $files[0].name
}
