#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - VM troubleshooting: correlates guest OS, vSphere and Aria Operations data for one VM over a time
    window and ranks the probable causes (read-only).
.DESCRIPTION
    Sources (each optional; a source that fails is reported and the others still run):
      * vSphere          always: performance counters (CPU ready / co-stop, balloon / swap, disk latency, network drops)
                         of the VM and its host, snapshots, VMware Tools, datastores, events and tasks.
      * Guest OS         when UseGuest and a guest credential (vault) are given: read-only script through VMware Tools.
      * Aria Operations  when the site has Aria configured and UseAria is set (execution.aria = optional):
                         Health / Risk / Efficiency, stats with MAX rollup, alerts; optional report definition (PDF).
    Window: last 1 h / 24 h / 7 d, or an incident time (operations.troubleshooting.timeZone) +- minutes.
    Output: verdict and ranked findings in the result, an HTML report with a latency / CPU chart, CSV per section and an
    evidence pack (zip) with every raw sample. Thresholds: operations.troubleshooting.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] [string] $VMName,
    [ValidateSet('Last1h', 'Last24h', 'Last7d', 'Incident')] [string] $WindowMode = 'Last24h',
    [string] $IncidentTime,
    [ValidateRange(0, 1440)] [int] $MinutesBefore = 60,
    [ValidateRange(0, 1440)] [int] $MinutesAfter = 30,
    [bool] $IncludeHost = $true,
    [bool] $UseGuest = $false,
    [pscredential] $GuestCredential,
    [bool] $UseAria = $true,
    [string] $AriaReport,
    [string] $Symptom,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}
Import-Module (Join-Path $Context.PortalRoot 'automation/lib/Portal.Guest.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $Context.PortalRoot 'automation/lib/Portal.AriaOps.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $Context.PortalRoot 'automation/lib/Portal.Diagnostics.psm1') -Force -DisableNameChecking

$vi  = $Context.VIServer
$ops = if ($Context.Operations -and $Context.Operations.Contains('troubleshooting')) { $Context.Operations.troubleshooting } else { @{} }
$tz  = if ($ops -and $ops['timeZone']) { [string]$ops['timeZone'] } else { 'UTC' }
$maxEvents = if ($ops -and $ops['maxEvents']) { [int]$ops['maxEvents'] } else { 2000 }
$minDsFree = if ($Context.Site.defaults.Contains('minDatastoreFreePercent')) { [double]$Context.Site.defaults.minDatastoreFreePercent } else { 15 }

# ---- Pre-checks ---------------------------------------------------------------------------------
if ($UseGuest -and -not $GuestCredential) { throw 'Guest OS analysis needs a guest credential from the vault (or clear "Include guest OS").' }
$window = Resolve-PortalTimeWindow -Mode $WindowMode -IncidentTime $IncidentTime -MinutesBefore $MinutesBefore -MinutesAfter $MinutesAfter -TimeZone $tz
Write-JobLog -Level STEP "Window: $($window.Label)$(if ($Symptom) { " - symptom: $Symptom" })"

$sources = [ordered]@{}
$vs = $null; $guest = $null; $ariaData = $null; $ariaReportFile = $null

# ---- vSphere ------------------------------------------------------------------------------------
Write-JobLog -Level STEP "vSphere: collecting $VMName"
$vs = Get-PortalVsphereEvidence -VMName $VMName -Server $vi -Window $window -IncludeHost $IncludeHost -MaxEvents $maxEvents
$sources['vSphere'] = "OK ($($vs.Perf.Interval.Label) samples, $(@($vs.Perf.Series).Count) counters, $(@($vs.Events).Count) events)"
if (@($vs.Perf.Missing).Count) { Write-JobLog -Level WARN "Counters not available at this interval (statistics level): $($vs.Perf.Missing -join ', ')" }
Write-JobLog -Level OK "vSphere: host $($vs.Host), $(@($vs.Snapshots).Count) snapshot(s), $(@($vs.Events).Count) event(s)."

# ---- Guest OS -----------------------------------------------------------------------------------
if ($UseGuest) {
    if ($vs.PowerState -ne 'PoweredOn') { $sources['Guest OS'] = "SKIPPED (VM is $($vs.PowerState))" }
    else {
        Write-JobLog -Level STEP 'Guest OS: running read-only diagnostics through VMware Tools'
        try {
            $guest = Get-PortalGuestDiagnostics -VM $vs.VM -Server $vi -Credential $GuestCredential -Window $window
            $sources['Guest OS'] = "OK ($($guest['os']))"
            Write-JobLog -Level OK "Guest OS: uptime $($guest['uptimeHours']) h, memory $($guest['memoryUsedPercent']) %, $(@($guest['events']).Count) event group(s)."
        }
        catch { $sources['Guest OS'] = "FAILED: $($_.Exception.Message)"; Write-JobLog -Level WARN "Guest OS: $($_.Exception.Message)" }
    }
}
else { $sources['Guest OS'] = 'NOT REQUESTED' }

# ---- Aria Operations ----------------------------------------------------------------------------
if (-not $UseAria) { $sources['Aria Operations'] = 'NOT REQUESTED' }
elseif (-not $Context.Aria) { $sources['Aria Operations'] = 'NOT AVAILABLE (not configured for the site or unreachable - see log)' }
else {
    Write-JobLog -Level STEP "Aria Operations: collecting $VMName"
    try {
        $ariaData = Get-PortalAriaEvidence -Aria $Context.Aria -VMName $VMName -Window $window -IncludeHost $IncludeHost
        $sources['Aria Operations'] = "OK ($(@($ariaData.Stats).Count) samples, $(@($ariaData.Alerts).Count) alert(s))"
        Write-JobLog -Level OK "Aria Operations: health $($ariaData.Badges.Health), $(@($ariaData.Alerts).Count) alert(s) in the window."
        if ($AriaReport) {
            Write-JobLog -Level STEP "Aria Operations: generating report definition $AriaReport"
            try {
                $rep = Invoke-PortalAriaReport -Aria $Context.Aria -DefinitionId $AriaReport -ResourceId $ariaData.Resource.Id -OutDir $Context.ReportDir -BaseName ("aria-report-" + ($VMName -replace '[^A-Za-z0-9_-]', '_')) -Format PDF
                $ariaReportFile = Split-Path -Leaf @($rep.Files)[0]
                Write-JobLog -Level OK "Aria report ready: $ariaReportFile"
            }
            catch { Write-JobLog -Level WARN "Aria report: $($_.Exception.Message)" }
        }
    }
    catch { $sources['Aria Operations'] = "FAILED: $($_.Exception.Message)"; Write-JobLog -Level WARN "Aria Operations: $($_.Exception.Message)" }
}

# ---- Analysis -----------------------------------------------------------------------------------
$findings = @(Get-PortalTroubleshootFindings -Vsphere $vs -Guest $guest -Aria $ariaData -Thresholds $ops -Window $window -MinDatastoreFreePercent $minDsFree)
$top = $findings | Where-Object { $_.Severity -ne 'INFO' } | Select-Object -First 1
$verdict = if ($top) { $top.Title } else { 'No anomaly found in the window' }
$confidence = if (-not $top) { '' } elseif (@($top.Sources).Count -ge 2) { 'high' } elseif ($top.Severity -eq 'CRITICAL') { 'medium' } else { 'low' }
Write-JobLog -Level OK "Verdict: $verdict$(if ($confidence) { " (confidence $confidence)" })"

# ---- Report + evidence pack ---------------------------------------------------------------------
$fmt = { param($t) if ($t) { ([DateTimeOffset]$t).UtcDateTime.ToString('yyyy-MM-dd HH:mm') } else { '' } }
$sevStatus = @{ CRITICAL = 'CRITICAL'; WARN = 'WARN'; INFO = 'OK' }
$summaryRows = @(Get-PortalSeriesSummary -Series $vs.Perf.Series -Source 'vSphere' -Object "VM $($vs.Name)")
if ($vs.HostPerf) { $summaryRows += @(Get-PortalSeriesSummary -Series $vs.HostPerf.Series -Source 'vSphere' -Object "Host $($vs.Host)") }
if ($ariaData) { $summaryRows += @(Get-PortalAriaStatSummary -Stats $ariaData.Stats) }

$chartSeries = @(@($vs.Perf.Series) | Where-Object { $_.Id -in 'disk.maxTotalLatency.latest', 'virtualDisk.totalWriteLatency.average', 'virtualDisk.totalReadLatency.average' } |
    ForEach-Object { @{ Name = "$($_.Name) (ms)"; Points = $_.Points } })
$cpuSeries = @(@($vs.Perf.Series) | Where-Object { $_.Id -in 'cpu.usage.average', 'cpu.ready.summation', 'mem.usage.average' } | ForEach-Object { @{ Name = "$($_.Name) (%)"; Points = $_.Points } })
$markers = @(@($vs.Events) | Where-Object { $_.Category -in 'Snapshot', 'Migration', 'HA', 'Power', 'Connectivity' } | Select-Object -First 8 |
    ForEach-Object { @{ Time = $_.Time; Label = "$($_.Time.UtcDateTime.ToString('HH:mm')) $($_.Category)" } })
if ($window.Incident) { $markers = @(@{ Time = $window.Incident; Label = 'incident' }) + $markers }

$sections = @(
    New-PortalReportSection -Title 'Probable causes (ranked)' -Columns 'Rank', 'Status', 'Finding', 'Evidence', 'Sources' -Rows @($findings | ForEach-Object {
        [ordered]@{ Rank = $_.Rank; Status = $sevStatus[$_.Severity]; Finding = $_.Title; Evidence = $_.Evidence; Sources = (@($_.Sources) -join ', ') } }) -Note 'Ordered by severity and by how many sources support the finding.'
    New-PortalReportChart -Title 'Disk latency with events' -Series $chartSeries -Markers $markers -Unit 'ms' -Threshold ([double]$(if ($ops -and $ops['diskLatencyWarnMs']) { $ops['diskLatencyWarnMs'] } else { 20 }))
    New-PortalReportChart -Title 'CPU and memory' -Series $cpuSeries -Markers $markers -Unit '%'
    New-PortalReportSection -Title 'Sources' -Columns 'Source', 'Status' -Rows @($sources.Keys | ForEach-Object { [ordered]@{ Source = $_; Status = $(if ($sources[$_] -like 'OK*') { $sources[$_] } elseif ($sources[$_] -like 'FAILED*') { "ERROR $($sources[$_].Substring(7))" } else { "WARN $($sources[$_])" }) } })
    New-PortalReportSection -Title 'Peaks by metric' -Columns 'Source', 'Object', 'Metric', 'Unit', 'Max', 'Avg', 'Peak (UTC)', 'Samples' -Rows @($summaryRows | ForEach-Object {
        [ordered]@{ Source = $_.Source; Object = $_.Object; Metric = $_.Metric; Unit = $_.Unit; Max = $_.Max; Avg = $_.Avg; 'Peak (UTC)' = (& $fmt $_.PeakAt); Samples = $_.Samples } })
    New-PortalReportSection -Title 'vCenter events and tasks' -Columns 'Time (UTC)', 'Object', 'Category', 'Type', 'User', 'Message' -Rows @($vs.Events | ForEach-Object {
        [ordered]@{ 'Time (UTC)' = (& $fmt $_.Time); Object = $_.Object; Category = $_.Category; Type = $_.Type; User = $_.User; Message = $_.Message } })
    New-PortalReportSection -Title 'VM configuration' -Columns 'Property', 'Value' -Rows @(
        [ordered]@{ Property = 'Power state'; Value = $vs.PowerState }, [ordered]@{ Property = 'vCPU / memory'; Value = "$($vs.NumCpu) vCPU / $($vs.MemoryGB) GB" },
        [ordered]@{ Property = 'Host / cluster'; Value = "$($vs.Host) ($($vs.HostState)) / $($vs.Cluster)" }, [ordered]@{ Property = 'VMware Tools'; Value = $vs.Tools },
        [ordered]@{ Property = 'Hardware version'; Value = $vs.HwVersion },
        [ordered]@{ Property = 'Datastores'; Value = (@($vs.Datastores | ForEach-Object { "$($_.Name) ($($_.FreePercent) % free)" }) -join ', ') },
        [ordered]@{ Property = 'Snapshots'; Value = $(if (@($vs.Snapshots).Count) { (@($vs.Snapshots | ForEach-Object { "$($_.Name) $($_.SizeGB) GB $(& $fmt $_.Created)" }) -join '; ') } else { 'none' }) })
)
if ($guest) {
    $sections += New-PortalReportSection -Title 'Guest OS' -Columns 'Property', 'Value' -Rows @(
        [ordered]@{ Property = 'OS'; Value = $guest['os'] }, [ordered]@{ Property = 'Uptime (h)'; Value = $guest['uptimeHours'] },
        [ordered]@{ Property = 'Memory used %'; Value = $guest['memoryUsedPercent'] }, [ordered]@{ Property = 'CPU load %'; Value = $guest['cpuLoadPercent'] },
        [ordered]@{ Property = 'Pending reboot'; Value = $(if (@($guest['pendingReboot']).Count) { @($guest['pendingReboot']) -join ', ' } else { 'No' }) },
        [ordered]@{ Property = 'Stopped automatic services'; Value = (@($guest['stoppedServices'] | ForEach-Object { $_['name'] }) -join ', ') })
    $sections += New-PortalReportSection -Title 'Guest disks' -Columns 'Disk', 'Size GB', 'Free GB', 'Free %', 'Status' -Rows @(@($guest['disks']) | ForEach-Object {
        $fp = [double]$_['freePercent']
        [ordered]@{ Disk = $_['name']; 'Size GB' = $_['sizeGB']; 'Free GB' = $_['freeGB']; 'Free %' = $fp; Status = $(if ($fp -lt 10) { 'CRITICAL' } elseif ($fp -lt 20) { 'WARN' } else { 'OK' }) } })
    $sections += New-PortalReportSection -Title 'Guest top processes (memory)' -Columns 'Process', 'Memory MB' -Rows @(@($guest['topProcesses']) | ForEach-Object { [ordered]@{ Process = $_['name']; 'Memory MB' = $_['memoryMB'] } })
    $sections += New-PortalReportSection -Title 'Guest error events in the window' -Columns 'Log', 'Source', 'Id', 'Level', 'Count', 'First (UTC)', 'Message' -Rows @(@($guest['events']) | ForEach-Object {
        [ordered]@{ Log = $_['log']; Source = $_['source']; Id = $_['id']; Level = $_['level']; Count = $_['count']; 'First (UTC)' = $_['first']; Message = $_['message'] } })
}
if ($ariaData) {
    $sections += New-PortalReportSection -Title 'Aria Operations' -Columns 'Property', 'Value' -Rows @(
        [ordered]@{ Property = 'Health / Risk / Efficiency'; Value = "$($ariaData.Badges.Health) / $($ariaData.Badges.Risk) / $($ariaData.Badges.Efficiency)" },
        [ordered]@{ Property = 'Parents'; Value = (@($ariaData.Parents | ForEach-Object { "$($_.Kind) $($_.Name)" }) -join ', ') },
        [ordered]@{ Property = 'Object link'; Value = $ariaData.Link })
    $sections += New-PortalReportSection -Title 'Aria Operations alerts' -Columns 'Object', 'Alert', 'Level', 'Status', 'Started (UTC)', 'Cancelled (UTC)' -Rows @($ariaData.Alerts | ForEach-Object {
        [ordered]@{ Object = $_.Object; Alert = $_.Name; Level = $_.Level; Status = $_.Status; 'Started (UTC)' = (& $fmt $_.Started); 'Cancelled (UTC)' = (& $fmt $_.Cancelled) } })
}

$files = New-PortalReport -Title "VM troubleshooting - $($vs.Name)" -Subtitle "$Site - $($window.Label)" -Context $Context -Sections $sections -FileName 'troubleshooting' -Summary ([ordered]@{
    Verdict = $verdict; Findings = @($findings | Where-Object Severity -ne 'INFO').Count
    'Peak disk latency (ms)' = $(($summaryRows | Where-Object { $_.Source -eq 'vSphere' -and $_.Unit -eq 'ms' } | Measure-Object Max -Maximum).Maximum)
    'Peak CPU ready (%)' = $((@($summaryRows | Where-Object Metric -eq 'CPU ready') | Measure-Object Max -Maximum).Maximum)
})

# Raw samples for the evidence pack.
$raw = Join-Path $Context.ReportDir '_raw'
$null = New-Item -ItemType Directory -Path $raw -Force
@(@($vs.Perf.Series) + @(if ($vs.HostPerf) { $vs.HostPerf.Series }) | ForEach-Object { $s = $_; @($s.Points) | ForEach-Object { [pscustomobject]@{ Metric = $s.Name; Unit = $s.Unit; TimeUtc = (& $fmt $_.Time); Value = $_.Value } } }) |
    Export-Csv -LiteralPath (Join-Path $raw 'vsphere-samples.csv') -NoTypeInformation -Encoding utf8
if ($ariaData) { @($ariaData.Stats | ForEach-Object { [pscustomobject]@{ Object = $_.Object; StatKey = $_.StatKey; TimeUtc = (& $fmt $_.Time); Value = $_.Value } }) | Export-Csv -LiteralPath (Join-Path $raw 'aria-stats.csv') -NoTypeInformation -Encoding utf8 }
if ($guest) { $guest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $raw 'guest.json') -Encoding utf8 }
$zipName = 'evidence-' + ($VMName -replace '[^A-Za-z0-9_-]', '_') + '.zip'
$packFiles = @(Get-ChildItem -LiteralPath $Context.ReportDir -File | Where-Object { $_.Extension -in '.html', '.csv', '.pdf' }) + @(Get-ChildItem -LiteralPath $raw -File)
Compress-Archive -LiteralPath @($packFiles.FullName) -DestinationPath (Join-Path $Context.ReportDir $zipName) -Force
Remove-Item -LiteralPath $raw -Recurse -Force

$result = [ordered]@{
    VM          = $vs.Name
    Window      = $window.Label
    Verdict     = $verdict
    Confidence  = $confidence
    TopFindings = @($findings | Select-Object -First 5 | ForEach-Object { "[$($_.Severity)] $($_.Title) ($(@($_.Sources) -join ', '))" })
    Sources     = @($sources.Keys | ForEach-Object { "${_}: $($sources[$_])" })
    Report      = $files[0].name
    EvidencePack = $zipName
}
if ($ariaReportFile) { $result['AriaReport'] = $ariaReportFile }
if ($ariaData) { $result['AriaLink'] = $ariaData.Link }
$next = [System.Collections.Generic.List[string]]::new()
if ($findings | Where-Object Key -eq 'snapshot-io') { $next.Add('Review the backup / snapshot schedule of this VM and its datastore; consider moving the job out of business hours.') }
if ($findings | Where-Object Key -eq 'disk-latency') { $next.Add('Compare with other VMs of the same datastore (Aria Operations datastore view) and the storage array.') }
if ($findings | Where-Object Key -eq 'cpu-ready') { $next.Add('Check host CPU over-commit, or move the VM with the "vMotion" item.') }
if ($findings | Where-Object Key -eq 'snapshot-present') { $next.Add('Remove old snapshots with the "Snapshot cleanup" item.') }
if (-not $guest -and -not $UseGuest) { $next.Add('Run again with "Include guest OS" to add OS-level evidence.') }
if ($next.Count) { $result['NextSteps'] = $next.ToArray() }
return $result
