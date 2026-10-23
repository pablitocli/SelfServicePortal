#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - incident evidence export (RCA) for one VM: peak metrics, alerts, events and snapshots around an
    incident time, packed for the incident ticket (read-only).
.DESCRIPTION
    * Aria Operations (when configured for the site): VM and host stats with the MAX rollup (peaks are not averaged
      away), Health / Risk / Efficiency and the alerts that overlap the window.
    * vSphere: VM and host performance counters, events and tasks (snapshots, vMotion, HA, power, connectivity),
      current snapshots.
    Output: summary HTML (timeline chart + peaks), one CSV per section and evidence-<vm>.zip with every raw sample.
    The incident time is read in operations.troubleshooting.timeZone.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] [string] $VMName,
    [Parameter(Mandatory)] [string] $IncidentTime,
    [ValidateRange(5, 1440)] [int] $MinutesBefore = 60,
    [ValidateRange(5, 1440)] [int] $MinutesAfter = 60,
    [bool] $IncludeHost = $true,
    [bool] $UseAria = $true,
    [string] $Reference,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}
Import-Module (Join-Path $Context.PortalRoot 'automation/lib/Portal.AriaOps.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $Context.PortalRoot 'automation/lib/Portal.Diagnostics.psm1') -Force -DisableNameChecking

$vi  = $Context.VIServer
$ops = if ($Context.Operations -and $Context.Operations.Contains('troubleshooting')) { $Context.Operations.troubleshooting } else { @{} }
$tz  = if ($ops -and $ops['timeZone']) { [string]$ops['timeZone'] } else { 'UTC' }
$fmt = { param($t) if ($t) { ([DateTimeOffset]$t).UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '' } }

$window = Resolve-PortalTimeWindow -Mode Incident -IncidentTime $IncidentTime -MinutesBefore $MinutesBefore -MinutesAfter $MinutesAfter -TimeZone $tz
Write-JobLog -Level STEP "Evidence window: $($window.Label)$(if ($Reference) { " - reference $Reference" })"

# ---- vSphere ------------------------------------------------------------------------------------
$vs = Get-PortalVsphereEvidence -VMName $VMName -Server $vi -Window $window -IncludeHost $IncludeHost -MaxEvents $(if ($ops -and $ops['maxEvents']) { [int]$ops['maxEvents'] } else { 2000 })
Write-JobLog -Level OK "vSphere: $(@($vs.Perf.Series).Count) VM counters, $(@($vs.Events).Count) events, host $($vs.Host)."
if (@($vs.Perf.Missing).Count) { Write-JobLog -Level WARN "vSphere counters not kept at this interval: $($vs.Perf.Missing -join ', ') (Aria Operations keeps 5-minute peaks longer)." }

# ---- Aria Operations ----------------------------------------------------------------------------
$aria = $null; $ariaStatus = 'NOT REQUESTED'
if ($UseAria) {
    if (-not $Context.Aria) { $ariaStatus = 'NOT AVAILABLE (not configured for the site or unreachable)' }
    else {
        try {
            $aria = Get-PortalAriaEvidence -Aria $Context.Aria -VMName $VMName -Window $window -IncludeHost $IncludeHost
            $ariaStatus = "OK ($(@($aria.Stats).Count) samples, $(@($aria.Alerts).Count) alerts)"
            Write-JobLog -Level OK "Aria Operations: $ariaStatus"
        }
        catch { $ariaStatus = "FAILED: $($_.Exception.Message)"; Write-JobLog -Level WARN "Aria Operations: $($_.Exception.Message)" }
    }
}

# ---- Report -------------------------------------------------------------------------------------
$peaks = @(Get-PortalSeriesSummary -Series $vs.Perf.Series -Source 'vSphere' -Object "VM $($vs.Name)")
if ($vs.HostPerf) { $peaks += @(Get-PortalSeriesSummary -Series $vs.HostPerf.Series -Source 'vSphere' -Object "Host $($vs.Host)") }
if ($aria) { $peaks += @(Get-PortalAriaStatSummary -Stats $aria.Stats) }
$markers = @(@{ Time = $window.Incident; Label = 'incident' }) + @(@($vs.Events) | Where-Object { $_.Category -ne 'Other' -and $_.Category -ne 'Alarm' } | Select-Object -First 8 |
    ForEach-Object { @{ Time = $_.Time; Label = "$($_.Time.UtcDateTime.ToString('HH:mm')) $($_.Category)" } })
$lat = @(@($vs.Perf.Series) | Where-Object { $_.Unit -eq 'ms' } | ForEach-Object { @{ Name = "$($_.Name) (ms)"; Points = $_.Points } })
if ($vs.HostPerf) { $lat += @(@($vs.HostPerf.Series) | Where-Object { $_.Unit -eq 'ms' } | ForEach-Object { @{ Name = "$($_.Name) (ms)"; Points = $_.Points } }) }

$sections = @(
    New-PortalReportChart -Title 'Storage latency around the incident' -Series $lat -Markers $markers -Unit 'ms'
    New-PortalReportChart -Title 'CPU ready / usage around the incident' -Series @(@($vs.Perf.Series) | Where-Object { $_.Id -in 'cpu.ready.summation', 'cpu.usage.average', 'cpu.costop.summation' } | ForEach-Object { @{ Name = "$($_.Name) (%)"; Points = $_.Points } }) -Markers $markers -Unit '%'
    New-PortalReportSection -Title 'Peaks by metric' -Columns 'Source', 'Object', 'Metric', 'Unit', 'Max', 'Avg', 'Peak (UTC)', 'Samples' -Rows @($peaks | Sort-Object Source, Object, Metric | ForEach-Object {
        [ordered]@{ Source = $_.Source; Object = $_.Object; Metric = $_.Metric; Unit = $_.Unit; Max = $_.Max; Avg = $_.Avg; 'Peak (UTC)' = (& $fmt $_.PeakAt); Samples = $_.Samples } })
    New-PortalReportSection -Title 'vCenter events and tasks' -Columns 'Time (UTC)', 'Object', 'Category', 'Type', 'User', 'Message' -Rows @($vs.Events | ForEach-Object {
        [ordered]@{ 'Time (UTC)' = (& $fmt $_.Time); Object = $_.Object; Category = $_.Category; Type = $_.Type; User = $_.User; Message = $_.Message } })
    New-PortalReportSection -Title 'Snapshots now' -Columns 'Name', 'Created (UTC)', 'Size GB', 'Description' -Rows @($vs.Snapshots | ForEach-Object {
        [ordered]@{ Name = $_.Name; 'Created (UTC)' = (& $fmt $_.Created); 'Size GB' = $_.SizeGB; Description = $_.Description } })
)
if ($aria) {
    $sections += New-PortalReportSection -Title 'Aria Operations alerts' -Columns 'Object', 'Alert', 'Level', 'Status', 'Started (UTC)', 'Updated (UTC)', 'Cancelled (UTC)' -Rows @($aria.Alerts | ForEach-Object {
        [ordered]@{ Object = $_.Object; Alert = $_.Name; Level = $_.Level; Status = $_.Status; 'Started (UTC)' = (& $fmt $_.Started); 'Updated (UTC)' = (& $fmt $_.Updated); 'Cancelled (UTC)' = (& $fmt $_.Cancelled) } })
}
$sections += New-PortalReportSection -Title 'Scope' -Columns 'Property', 'Value' -Rows @(
    [ordered]@{ Property = 'VM / host / cluster'; Value = "$($vs.Name) / $($vs.Host) / $($vs.Cluster)" },
    [ordered]@{ Property = 'Window'; Value = $window.Label },
    [ordered]@{ Property = 'vSphere sampling'; Value = $vs.Perf.Interval.Label },
    [ordered]@{ Property = 'Aria Operations'; Value = $ariaStatus },
    [ordered]@{ Property = 'Reference'; Value = $Reference })

$files = New-PortalReport -Title "Incident evidence - $($vs.Name)" -Subtitle "$Site - $($window.Label)" -Context $Context -Sections $sections -FileName 'incident-evidence' -Summary ([ordered]@{
    'Events in window' = @($vs.Events).Count
    'Aria alerts' = $(if ($aria) { @($aria.Alerts).Count } else { '-' })
    'Peak latency (ms)' = (($peaks | Where-Object { $_.Unit -eq 'ms' } | Measure-Object Max -Maximum).Maximum)
})

$raw = Join-Path $Context.ReportDir '_raw'
$null = New-Item -ItemType Directory -Path $raw -Force
@(@($vs.Perf.Series) + @(if ($vs.HostPerf) { $vs.HostPerf.Series }) | ForEach-Object { $s = $_; @($s.Points) | ForEach-Object { [pscustomobject]@{ Metric = $s.Name; Unit = $s.Unit; TimeUtc = (& $fmt $_.Time); Value = $_.Value } } }) |
    Export-Csv -LiteralPath (Join-Path $raw 'vsphere-samples.csv') -NoTypeInformation -Encoding utf8
if ($aria) {
    foreach ($g in @($aria.Stats | Group-Object Object)) {
        $g.Group | ForEach-Object { [pscustomobject]@{ Object = $_.Object; StatKey = $_.StatKey; TimeUtc = (& $fmt $_.Time); Value = $_.Value } } |
            Export-Csv -LiteralPath (Join-Path $raw ('aria-stats-' + (($g.Name -replace '[^A-Za-z0-9_-]+', '_').Trim('_')) + '.csv')) -NoTypeInformation -Encoding utf8
    }
}
$zipName = 'evidence-' + ($VMName -replace '[^A-Za-z0-9_-]', '_') + '.zip'
$pack = @(Get-ChildItem -LiteralPath $Context.ReportDir -File | Where-Object { $_.Extension -in '.html', '.csv' }) + @(Get-ChildItem -LiteralPath $raw -File)
Compress-Archive -LiteralPath @($pack.FullName) -DestinationPath (Join-Path $Context.ReportDir $zipName) -Force
Remove-Item -LiteralPath $raw -Recurse -Force

$r = [ordered]@{
    VM           = $vs.Name
    Window       = $window.Label
    Events       = @($vs.Events).Count
    AriaAlerts   = $(if ($aria) { @($aria.Alerts).Count } else { 0 })
    Aria         = $ariaStatus
    Report       = $files[0].name
    EvidencePack = $zipName
}
if ($aria) { $r['AriaLink'] = $aria.Link }
return $r
