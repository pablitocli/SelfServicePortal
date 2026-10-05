#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - advisory vCPU / memory right-sizing report (no change is made).
.DESCRIPTION
    Reads cpu.usage.average and mem.usage.average (percent) with Get-Stat for one VM or every powered-on VM of the
    cluster (max 200), over LookbackDays (2-hour samples up to 30 days, daily samples beyond), and computes the
    average and the 95th percentile (nearest rank) per VM.

    Recommendation (thresholds from operations.rightSizing; target utilisation T = 0.75 x high threshold):
      CPU    p95 < cpuLowPercent and vCPU > 1   -> WARN (oversized),  vCPU' = max(1, ceil(vCPU x p95 / T))
             p95 > cpuHighPercent               -> FAIL (undersized), vCPU' = ceil(vCPU x p95 / T)
      Memory p95 < memoryLowPercent              -> WARN (oversized),  GB'   = max(2, ceil(GB x p95 / T))
             p95 > memoryHighPercent             -> FAIL (undersized), GB'   = ceil(GB x p95 / T)
    A down-size that does not reduce the value is ignored. Status = FAIL if any resource is undersized, else WARN
    if any is oversized, else OK. Fewer than 6 samples = NO DATA.
    mem.usage.average is guest *active* memory: memory down-sizing advice must be confirmed with the application owner.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] [string] $Cluster,
    [string] $VMName,
    [ValidateRange(1, 90)] [int] $LookbackDays = 30,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}
function Get-OpSetting {
    param($Section, [string] $Key, $Default)
    if ($null -eq $Section) { return $Default }
    $v = if ($Section -is [System.Collections.IDictionary]) { if ($Section.Contains($Key)) { $Section[$Key] } } else { $Section.PSObject.Properties[$Key].Value }
    if ($null -eq $v -or ($v -is [string] -and $v -eq '')) { return $Default }
    return $v
}
function Get-P95 {
    param([double[]] $Values)
    if (-not $Values) { return 0 }
    $s = @($Values | Sort-Object)
    return $s[[math]::Max(0, [int][math]::Ceiling(0.95 * $s.Count) - 1)]
}

$vi      = $Context.VIServer
$ops     = $Context.Operations.rightSizing
$cpuLow  = [double](Get-OpSetting $ops 'cpuLowPercent' 20)
$cpuHigh = [double](Get-OpSetting $ops 'cpuHighPercent' 80)
$memLow  = [double](Get-OpSetting $ops 'memoryLowPercent' 30)
$memHigh = [double](Get-OpSetting $ops 'memoryHighPercent' 85)
$maxVms  = 200
$minSamples = 6

# ---- Pre-checks ---------------------------------------------------------------------------------
$allowed = @($Context.Site.defaults.allowedClusters | Where-Object { $_ })
if ($allowed -and $allowed -notcontains $Cluster) { throw "Cluster '$Cluster' is not allowed for $Site (allowed: $($allowed -join ', '))." }
$cl = Get-Cluster -Name $Cluster -Server $vi -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $cl) { throw "Cluster '$Cluster' was not found in $Site." }

if ($VMName) {
    $vms = @(Get-VM -Name $VMName -Location $cl -Server $vi -ErrorAction SilentlyContinue | Select-Object -First 1)
    if (-not $vms) { throw "VM '$VMName' was not found in cluster '$Cluster'." }
    if ($vms[0].PowerState -ne 'PoweredOn') { throw "VM '$VMName' is $($vms[0].PowerState); right-sizing needs usage history of a running VM." }
}
else {
    $all = @(Get-VM -Location $cl -Server $vi | Where-Object { $_.PowerState -eq 'PoweredOn' } | Sort-Object Name)
    if ($all.Count -gt $maxVms) { Write-JobLog -Level WARN "$($all.Count) powered-on VMs in $Cluster; only the first $maxVms (by name) are analysed." }
    $vms = @($all | Select-Object -First $maxVms)
    if (-not $vms) { throw "No powered-on VMs in cluster '$Cluster'." }
}

$interval = if ($LookbackDays -le 30) { 120 } else { 1440 }
$start = (Get-Date).AddDays(-$LookbackDays)
Write-JobLog -Level STEP "Reading $LookbackDays days of CPU / memory usage for $($vms.Count) VM(s) in $Cluster ($interval-minute samples)."

# ---- Statistics (batches of 50 VMs) -------------------------------------------------------------
$byVm = @{}
for ($i = 0; $i -lt $vms.Count; $i += 50) {
    $batch = @($vms[$i..([math]::Min($i + 49, $vms.Count - 1))])
    $stats = @(try { Get-Stat -Entity $batch -Stat 'cpu.usage.average', 'mem.usage.average' -Start $start -Finish (Get-Date) -IntervalMins $interval -Server $vi -ErrorAction SilentlyContinue } catch { Write-JobLog -Level WARN "Get-Stat failed: $($_.Exception.Message)" })
    foreach ($s in $stats) {
        if ($s.Instance) { continue }                         # aggregate instance only
        $key = [string]$s.EntityId
        if (-not $byVm.ContainsKey($key)) { $byVm[$key] = @{ cpu = [System.Collections.Generic.List[double]]::new(); mem = [System.Collections.Generic.List[double]]::new() } }
        if ($s.MetricId -eq 'cpu.usage.average') { $byVm[$key].cpu.Add([double]$s.Value) } elseif ($s.MetricId -eq 'mem.usage.average') { $byVm[$key].mem.Add([double]$s.Value) }
    }
}

# ---- Recommendations ----------------------------------------------------------------------------
$cpuT = $cpuHigh * 0.75; $memT = $memHigh * 0.75
$rows = [System.Collections.Generic.List[object]]::new()
$vcpuDelta = 0; $memDelta = 0
foreach ($vm in $vms) {
    $d = $byVm[[string]$vm.Id]
    $vcpu = [int]$vm.NumCpu; $memGB = [double]$vm.MemoryGB
    $row = [ordered]@{ VM = $vm.Name; vCPU = $vcpu; CpuAvg = ''; CpuP95 = ''; RecVcpu = $vcpu; MemoryGB = $memGB; MemAvg = ''; MemP95 = ''; RecMemoryGB = $memGB; Samples = 0; Status = 'NO DATA'; Recommendation = 'Not enough performance samples.' }
    if ($d -and $d.cpu.Count -ge $minSamples -and $d.mem.Count -ge $minSamples) {
        $cpuP95 = [math]::Round((Get-P95 $d.cpu.ToArray()), 1); $memP95 = [math]::Round((Get-P95 $d.mem.ToArray()), 1)
        $row.CpuAvg = [math]::Round(($d.cpu | Measure-Object -Average).Average, 1); $row.CpuP95 = $cpuP95
        $row.MemAvg = [math]::Round(($d.mem | Measure-Object -Average).Average, 1); $row.MemP95 = $memP95
        $row.Samples = [math]::Min($d.cpu.Count, $d.mem.Count)
        $notes = @(); $over = $false; $under = $false

        if ($cpuP95 -gt $cpuHigh) {
            $row.RecVcpu = [int][math]::Ceiling($vcpu * $cpuP95 / $cpuT); $under = $true; $notes += "CPU p95 $cpuP95% > $cpuHigh%: $vcpu -> $($row.RecVcpu) vCPU"
        }
        elseif ($cpuP95 -lt $cpuLow -and $vcpu -gt 1) {
            $rec = [int][math]::Max(1, [math]::Ceiling($vcpu * $cpuP95 / $cpuT))
            if ($rec -lt $vcpu) { $row.RecVcpu = $rec; $over = $true; $notes += "CPU p95 $cpuP95% < $cpuLow%: $vcpu -> $rec vCPU" }
        }
        if ($memP95 -gt $memHigh) {
            $row.RecMemoryGB = [int][math]::Ceiling($memGB * $memP95 / $memT); $under = $true; $notes += "Memory p95 $memP95% > $memHigh%: $memGB -> $($row.RecMemoryGB) GB"
        }
        elseif ($memP95 -lt $memLow) {
            $rec = [int][math]::Max(2, [math]::Ceiling($memGB * $memP95 / $memT))
            if ($rec -lt $memGB) { $row.RecMemoryGB = $rec; $over = $true; $notes += "Memory p95 $memP95% < $memLow%: $memGB -> $rec GB" }
        }
        $row.Status = if ($under) { 'FAIL' } elseif ($over) { 'WARN' } else { 'OK' }
        $row.Recommendation = if ($notes) { $notes -join '; ' } else { 'Size is adequate.' }
        $vcpuDelta += $row.RecVcpu - $vcpu; $memDelta += $row.RecMemoryGB - $memGB
    }
    $rows.Add($row)
}

$cnt = { param($s) @($rows | Where-Object { $_.Status -eq $s }).Count }
$ok = & $cnt 'OK'; $warn = & $cnt 'WARN'; $fail = & $cnt 'FAIL'; $noData = & $cnt 'NO DATA'
$summary = [ordered]@{
    'VMs analysed'     = $rows.Count
    'OK'               = $ok
    'Oversized (WARN)' = $warn
    'Undersized (FAIL)' = $fail
    'No data'          = $noData
    'Net vCPU change'  = $vcpuDelta
    'Net memory change (GB)' = $memDelta
}
$note = "Look-back $LookbackDays days, $interval-minute samples, 95th percentile (nearest rank). Target utilisation = 0.75 x high threshold " +
        "(CPU $cpuT%, memory $memT%). CPU: down when p95 < $cpuLow%, up when p95 > $cpuHigh%; memory: down when p95 < $memLow% (never below 2 GB), " +
        "up when p95 > $memHigh%. New size = ceil(current x p95 / target). Memory usage is guest active memory - confirm down-sizing with the owner."
$files = New-PortalReport -Title 'VM right-sizing' -Subtitle "$Site - $Cluster$(if ($VMName) { " - $VMName" })" -Context $Context -Summary $summary -Sections @(
    New-PortalReportSection -Title 'Recommendations' -Rows ($rows | Sort-Object @{ e = { @{ FAIL = 0; WARN = 1; 'NO DATA' = 2; OK = 3 }[$_.Status] } }, VM) `
        -Columns VM, vCPU, CpuAvg, CpuP95, RecVcpu, MemoryGB, MemAvg, MemP95, RecMemoryGB, Samples, Status, Recommendation -Note $note
)
Write-JobLog -Level OK "Analysed $($rows.Count) VM(s): OK $ok, oversized $warn, undersized $fail, no data $noData."

return [ordered]@{
    Site         = $Site
    Cluster      = $Cluster
    VMsAnalysed  = $rows.Count
    Ok           = $ok
    Oversized    = $warn
    Undersized   = $fail
    NoData       = $noData
    LookbackDays = $LookbackDays
    Report       = $files[0].name
    NextSteps    = @("Apply with the 'Resize VM' item (vm-resize).")
}
