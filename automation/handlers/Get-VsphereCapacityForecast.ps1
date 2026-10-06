#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - capacity forecast per datastore and cluster from the inventory history (no vCenter needed).
.DESCRIPTION
    Reads data/inventory/history/<SITE>.jsonl (one sample per day, written at inventory refresh) and fits a
    least-squares line per entity:
      datastores        used GB = capacityGB - freeGB, as % of the latest capacity
      cluster memory    vmMemoryGB (powered-on VMs) as % of the cluster memoryGB
      cluster vCPU      vCPU growth of powered-on VMs (no threshold: physical cores are not in the history)
    Days to threshold = (threshold - current) / growth per day ("-" when not growing).
    Status: FAIL already at / above the threshold, WARN reaches it within ForecastDays, else OK.
    At least 7 daily samples are required; with fewer the report says so and the job still succeeds.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [ValidateRange(0, 3650)] [int] $ForecastDays = 0,
    [ValidateRange(0, 100)] [int] $ThresholdPercent = 0,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}

if ($Site -notmatch '^[A-Za-z0-9_-]{1,32}$') { throw "Invalid site code '$Site'." }
$Site = $Site.ToUpperInvariant()
$capCfg = if ($Context.Operations -and $Context.Operations.capacity) { $Context.Operations.capacity } else { @{} }
if ($ForecastDays -le 0)     { $ForecastDays = if ($capCfg.forecastDays) { [int]$capCfg.forecastDays } else { 90 } }
if ($ThresholdPercent -le 0) { $ThresholdPercent = if ($capCfg.thresholdPercent) { [int]$capCfg.thresholdPercent } else { 85 } }
$minSamples = 7

# --- History ---------------------------------------------------------------------------------------------------
$path = Join-Path (Join-Path (Get-PortalPath -Name Inventory) 'history') "$Site.jsonl"
$byDate = [ordered]@{}
if (Test-Path -LiteralPath $path) {
    foreach ($line in Get-Content -LiteralPath $path) {
        if (-not $line.Trim()) { continue }
        try { $s = $line | ConvertFrom-Json -AsHashtable -Depth 10 } catch { Write-JobLog -Level WARN 'Skipping an unreadable history line.'; continue }
        $d = [datetime]::MinValue
        if (-not $s -or -not [datetime]::TryParseExact([string]$s.date, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture, 'AssumeUniversal,AdjustToUniversal', [ref]$d)) { continue }
        $s['_date'] = $d
        $byDate[$d.ToString('yyyy-MM-dd')] = $s      # last sample of a day wins
    }
}
$samples = @($byDate.Values | Sort-Object { $_['_date'] })
$n = $samples.Count
Write-JobLog "History $Site`: $n daily sample(s) ($path)"

$subtitle = "Threshold $ThresholdPercent% - horizon $ForecastDays days"
if ($n -lt $minSamples) {
    $msg = "Not enough history yet ($n days); the portal records one sample per day at inventory refresh"
    Write-JobLog -Level WARN $msg
    $files = New-PortalReport -Title "Capacity forecast - $Site" -Subtitle $subtitle -Context $Context -FileName 'capacity-forecast' `
        -Sections @(New-PortalReportSection -Title 'Forecast' -Rows @() -Note "$msg. At least $minSamples daily samples are needed.") `
        -Summary ([ordered]@{ 'Samples (days)' = $n; 'Needed' = $minSamples })
    return [ordered]@{ Site = $Site; Samples = $n; Message = "$msg."; Report = $files[0].name
                       NextSteps = @("Run the report again after $minSamples days of inventory refreshes.") }
}
$first = $samples[0]['_date']; $lastSample = $samples[-1]
$projCol = "Projected % at $ForecastDays days"

function Get-LinearFit {
    <# Least squares y = a + b*x. Points: @(@(x, y), ...). Returns @{ Slope; Intercept } or $null with < 2 distinct x. #>
    param($Points)
    $p = @($Points | ForEach-Object { , $_ }); if ($p.Count -lt 2) { return $null }
    $mx = ($p | ForEach-Object { $_[0] } | Measure-Object -Average).Average
    $my = ($p | ForEach-Object { $_[1] } | Measure-Object -Average).Average
    $sxx = 0.0; $sxy = 0.0
    foreach ($q in $p) { $dx = $q[0] - $mx; $sxx += $dx * $dx; $sxy += $dx * ($q[1] - $my) }
    if ($sxx -eq 0) { return $null }
    $b = $sxy / $sxx
    return @{ Slope = $b; Intercept = $my - $b * $mx }
}
function Get-Points {
    <# (days since first sample, value) pairs of one entity. Always returns one list (never unrolled). #>
    param([string] $Collection, [string] $Name, [scriptblock] $Value)
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($s in $samples) {
        $e = @($s[$Collection]) | Where-Object { $_ -and $_.name -eq $Name } | Select-Object -First 1
        if (-not $e) { continue }
        $y = & $Value $e
        if ($null -ne $y) { $list.Add([double[]]@((($s['_date'] - $first).TotalDays), [double]$y)) }
    }
    return , $list
}
function Get-ForecastRow {
    <# current / growth in units; limit = 100 % in the same unit. #>
    param([string] $Name, [double] $Limit, [double] $Current, $Fit, [System.Collections.IDictionary] $Extra = [ordered]@{})
    $growth = if ($Fit) { $Fit.Slope } else { 0.0 }
    $thr = $Limit * $ThresholdPercent / 100
    $curPct = if ($Limit -gt 0) { $Current / $Limit * 100 } else { 0 }
    $projPct = if ($Limit -gt 0) { ($Current + $growth * $ForecastDays) / $Limit * 100 } else { 0 }
    $days = if ($Current -ge $thr) { 0 } elseif ($growth -gt 0) { [math]::Round(($thr - $Current) / $growth, 0) } else { '-' }
    $status = if ($Current -ge $thr) { 'FAIL' } elseif ($days -is [ValueType] -and $days -le $ForecastDays) { 'WARN' } else { 'OK' }
    $row = [ordered]@{ Name = $Name }
    foreach ($k in $Extra.Keys) { $row[$k] = $Extra[$k] }
    $row['Current %'] = [math]::Round($curPct, 1)
    $row['Growth per day'] = [math]::Round($growth, 2)
    $row['Days to threshold'] = $days
    $row[$projCol] = [math]::Round([math]::Max(0.0, $projPct), 1)
    $row['Status'] = $status
    return $row
}

# --- Datastores ------------------------------------------------------------------------------------------------
$dsRows = foreach ($d in (@($lastSample['datastores']) | Where-Object { $_ } | Sort-Object { $_.name })) {
    $cap = [double]$d.capacityGB
    if ($cap -le 0) { continue }
    $fit = Get-LinearFit (Get-Points -Collection 'datastores' -Name $d.name -Value { param($e) if ([double]$e.capacityGB -gt 0) { [double]$e.capacityGB - [double]$e.freeGB } })
    Get-ForecastRow -Name $d.name -Limit $cap -Current ($cap - [double]$d.freeGB) -Fit $fit -Extra ([ordered]@{ 'Capacity GB' = [math]::Round($cap, 0); 'Used GB' = [math]::Round($cap - [double]$d.freeGB, 0) })
}

# --- Clusters --------------------------------------------------------------------------------------------------
$memRows = [System.Collections.Generic.List[object]]::new()
$cpuRows = [System.Collections.Generic.List[object]]::new()
foreach ($c in (@($lastSample['clusters']) | Where-Object { $_ } | Sort-Object { $_.name })) {
    $mem = [double]$c.memoryGB
    if ($mem -gt 0) {
        $fit = Get-LinearFit (Get-Points -Collection 'clusters' -Name $c.name -Value { param($e) $e.vmMemoryGB })
        $memRows.Add((Get-ForecastRow -Name $c.name -Limit $mem -Current ([double]$c.vmMemoryGB) -Fit $fit -Extra ([ordered]@{ 'Memory GB' = [math]::Round($mem, 0); 'VM memory GB' = [math]::Round([double]$c.vmMemoryGB, 0) })))
    }
    $vfit = Get-LinearFit (Get-Points -Collection 'clusters' -Name $c.name -Value { param($e) $e.vcpu })
    $vg = if ($vfit) { $vfit.Slope } else { 0.0 }
    $cpuRows.Add([ordered]@{
        Name = $c.name; Hosts = $c.hosts; 'CPU GHz' = $c.cpuGHz; VMs = $c.vms; vCPU = [int]$c.vcpu
        'Growth per day' = [math]::Round($vg, 2); "Projected vCPU at $ForecastDays days" = [math]::Round([math]::Max(0.0, [double]$c.vcpu + $vg * $ForecastDays), 0)
        'vCPU per host' = $(if ([double]$c.hosts -gt 0) { [math]::Round([double]$c.vcpu / [double]$c.hosts, 1) } else { '' })
    })
}

# --- Report ----------------------------------------------------------------------------------------------------
$dsRows = @($dsRows)
$atRisk = { param($Rows) @($Rows | Where-Object { $_.Status -ne 'OK' }).Count }
$above = @(@($dsRows) + @($memRows) | Where-Object { $_.Status -eq 'FAIL' }).Count
$summary = [ordered]@{
    'Samples (days)'       = $n
    'Datastores at risk'   = (& $atRisk $dsRows)
    'Clusters at risk'     = (& $atRisk $memRows)
    'Above threshold now'  = $above
}
$period = "{0:yyyy-MM-dd} to {1:yyyy-MM-dd}" -f $first, $lastSample['_date']
$sections = @(
    New-PortalReportSection -Title 'Datastores' -Rows $dsRows -Columns Name, 'Capacity GB', 'Used GB', 'Current %', 'Growth per day', 'Days to threshold', $projCol, Status `
        -Note "Used GB trend (least squares, $n samples, $period). Growth per day in GB. FAIL: at or above $ThresholdPercent% now; WARN: reaches it within $ForecastDays days."
    New-PortalReportSection -Title 'Cluster memory' -Rows $memRows -Columns Name, 'Memory GB', 'VM memory GB', 'Current %', 'Growth per day', 'Days to threshold', $projCol, Status `
        -Note 'Configured memory of powered-on VMs as % of cluster physical memory. Growth per day in GB.'
    New-PortalReportSection -Title 'Cluster vCPU' -Rows $cpuRows -Note 'vCPU of powered-on VMs. Informational: physical core counts are not part of the history, so no threshold applies.'
)
$files = New-PortalReport -Title "Capacity forecast - $Site" -Subtitle $subtitle -Context $Context -Sections $sections -Summary $summary -FileName 'capacity-forecast'
Write-JobLog -Level OK "Report written: $($files[0].name)"

return [ordered]@{
    Site              = $Site
    Samples           = $n
    DatastoresAtRisk  = $summary['Datastores at risk']
    ClustersAtRisk    = $summary['Clusters at risk']
    AboveThreshold    = $above
    Report            = $files[0].name
}
