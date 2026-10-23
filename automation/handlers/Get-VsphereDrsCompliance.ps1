#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - DRS rule compliance report for a cluster (read-only).
.DESCRIPTION
    Rules
      * Every VM-VM rule of the cluster: enabled, members found, and placement compliance (Separate = every powered-on
        member on a different host; Together = all powered-on members on the same host).
      * Expected rules from the data file drsRules (Admin > Data files) for this site / cluster: rule exists, type
        and exact members.
      Status: COMPLIANT | WARN (disabled, member differences, members powered off) | NON-COMPLIANT (placement violated,
      expected rule missing).
    Hosts: physical memory, vRAM of powered-on VMs (over-commit %), memory in use, vCPU:core ratio, swapped /
    ballooned memory and the large VMs each host runs (largeVmGB / mediumVmGB).
    VMs matching vmNamePattern (e.g. SQL): host, vCPU, memory, reservation, swap / balloon, rules.
    Pending DRS recommendations and decommission candidates.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] [string] $Cluster,
    [string] $VmNamePattern,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}
function Get-V { param($O, [string] $N, $D = $null) if ($null -eq $O) { return $D }; if ($O -is [System.Collections.IDictionary]) { if ($O.Contains($N) -and $null -ne $O[$N]) { return $O[$N] } return $D }; $p = $O.PSObject.Properties[$N]; if ($p -and $null -ne $p.Value) { $p.Value } else { $D } }
function Get-Short { param([string] $n) ($n -split '\.')[0] }

$vi = $Context.VIServer
$allowed = @($Context.Site.defaults.allowedClusters | Where-Object { $_ })
if ($allowed -and $allowed -notcontains $Cluster) { throw "Cluster '$Cluster' is not allowed for $Site (allowed: $($allowed -join ', '))." }
$cl = Get-Cluster -Name $Cluster -Server $vi -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $cl) { throw "Cluster '$Cluster' was not found in $Site." }

$data = Get-PortalDataFile -Name drsRules
$largeGB  = [double](Get-V $data 'largeVmGB' 512)
$mediumGB = [double](Get-V $data 'mediumVmGB' 192)
$pattern  = if ($VmNamePattern) { $VmNamePattern } else { [string](Get-V $data 'vmNamePattern' '') }
if ($pattern) { try { [void][regex]::new($pattern) } catch { throw "VM name pattern '$pattern' is not a valid regular expression." } }
$expectedCfg = @(Get-V $data 'clusters' @()) | Where-Object { [string](Get-V $_ 'site' '') -eq $Site -and [string](Get-V $_ 'cluster' '') -eq $Cluster } | Select-Object -First 1
$expected = @(if ($expectedCfg) { Get-V $expectedCfg 'rules' @() })
$decom = @(if ($expectedCfg) { Get-V $expectedCfg 'decommission' @() })
Write-JobLog -Level STEP "Cluster $Cluster - $($expected.Count) expected rule(s) in the data file"

$hosts = @(Get-VMHost -Location $cl -Server $vi | Sort-Object Name)
$vms = @(Get-VM -Location $cl -Server $vi)
$byId = @{}; foreach ($v in $vms) { $byId[[string]$v.Id] = $v }
$rules = @(Get-DrsRule -Cluster $cl -Server $vi -ErrorAction SilentlyContinue)
$recs = @(try { Get-DrsRecommendation -Cluster $cl -Server $vi -ErrorAction Stop } catch { @() }) | Where-Object { $_ }

# ---- Rules --------------------------------------------------------------------------------------
function Test-Placement {
    param($Members, [bool] $Together)
    $issues = [System.Collections.Generic.List[string]]::new(); $placement = [System.Collections.Generic.List[string]]::new()
    $on = @($Members | Where-Object { $_ -and [string]$_.PowerState -eq 'PoweredOn' })
    foreach ($m in $Members) {
        if (-not $m) { continue }
        $placement.Add("$($m.Name) -> $(Get-Short ([string]$m.VMHost.Name))$(if ([string]$m.PowerState -ne 'PoweredOn') { " ($($m.PowerState))" })")
    }
    $violation = $false
    if ($Together) {
        $hs = @($on | ForEach-Object { [string]$_.VMHost.Name } | Sort-Object -Unique)
        if ($hs.Count -gt 1) { $issues.Add("Members run on $($hs.Count) hosts ($(@($hs | ForEach-Object { Get-Short $_ }) -join ', ')).") ; $violation = $true }
    }
    else {
        foreach ($g in @($on | Group-Object { [string]$_.VMHost.Name } | Where-Object Count -gt 1)) {
            $issues.Add("$(@($g.Group.Name) -join ' + ') share $(Get-Short $g.Name).") ; $violation = $true
        }
    }
    $off = @($Members | Where-Object { $_ -and [string]$_.PowerState -ne 'PoweredOn' })
    if ($off.Count) { $issues.Add("Powered off: $(@($off.Name) -join ', ').") }
    return [pscustomobject]@{ Issues = $issues; Placement = $placement; Violation = $violation }
}

$ruleRows = [System.Collections.Generic.List[object]]::new()
$checked = @{}
foreach ($e in $expected) {
    $name = [string](Get-V $e 'name' ''); $together = ([string](Get-V $e 'type' 'Separate') -eq 'Together')
    $expVms = @(Get-V $e 'vms' @() | ForEach-Object { [string]$_ })
    $rule = $rules | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    $issues = [System.Collections.Generic.List[string]]::new()
    $members = @()
    if (-not $rule) {
        $issues.Add('Rule not found in vCenter.')
        $members = @($expVms | ForEach-Object { $n = $_; $vms | Where-Object Name -eq $n | Select-Object -First 1 })
    }
    else {
        $checked[$name] = $true
        if (-not [bool]$rule.Enabled) { $issues.Add('Rule disabled.') }
        if ([bool]$rule.KeepTogether -ne $together) { $issues.Add("Rule type is $(if ($rule.KeepTogether) { 'Keep together' } else { 'Separate' }) (expected $(if ($together) { 'Keep together' } else { 'Separate' })).") }
        $ruleVmNames = @(@($rule.VMIds) | ForEach-Object { if ($byId[[string]$_]) { $byId[[string]$_].Name } else { [string]$_ } })
        $missing = @($expVms | Where-Object { $_ -notin $ruleVmNames }); $extra = @($ruleVmNames | Where-Object { $_ -notin $expVms })
        if ($missing.Count) { $issues.Add("Missing in rule: $($missing -join ', ').") }
        if ($extra.Count) { $issues.Add("Not expected in rule: $($extra -join ', ').") }
        $members = @(@($rule.VMIds) | ForEach-Object { $byId[[string]$_] })
    }
    foreach ($n in $expVms) { if (-not ($vms | Where-Object Name -eq $n)) { $issues.Add("$n not found in the cluster.") } }
    $pl = Test-Placement -Members $members -Together $together
    foreach ($i in $pl.Issues) { $issues.Add($i) }
    $status = if (-not $rule -or $pl.Violation) { 'NON-COMPLIANT' } elseif ($issues.Count) { 'WARN' } else { 'COMPLIANT' }
    $ruleRows.Add([ordered]@{ Rule = $name; Source = 'Expected (data file)'; Type = $(if ($together) { 'Together' } else { 'Separate' }); Placement = @($pl.Placement); Compliance = $status; Issues = $(if ($issues.Count) { @($issues) -join ' ' } else { '' }); Note = [string](Get-V $e 'note' '') })
}
foreach ($rule in $rules) {
    if ($checked.ContainsKey([string]$rule.Name)) { continue }
    $members = @(@($rule.VMIds) | ForEach-Object { $byId[[string]$_] })
    $pl = Test-Placement -Members $members -Together ([bool]$rule.KeepTogether)
    $issues = [System.Collections.Generic.List[string]]::new()
    if (-not [bool]$rule.Enabled) { $issues.Add('Rule disabled.') }
    foreach ($i in $pl.Issues) { $issues.Add($i) }
    $status = if ($pl.Violation -and [bool]$rule.Enabled) { 'NON-COMPLIANT' } elseif ($issues.Count) { 'WARN' } else { 'COMPLIANT' }
    $ruleRows.Add([ordered]@{ Rule = [string]$rule.Name; Source = 'vCenter'; Type = $(if ($rule.KeepTogether) { 'Together' } else { 'Separate' }); Placement = @($pl.Placement); Compliance = $status; Issues = (@($issues) -join ' '); Note = '' })
}

# ---- Hosts --------------------------------------------------------------------------------------
$hostRows = foreach ($h in $hosts) {
    $hv = @($vms | Where-Object { [string]$_.VMHost.Id -eq [string]$h.Id -and [string]$_.PowerState -eq 'PoweredOn' })
    $phys = [double](Get-V $h 'MemoryTotalGB' 0); $used = [double](Get-V $h 'MemoryUsageGB' 0)
    $vram = [double](($hv | Measure-Object MemoryGB -Sum).Sum); $vcpu = [int](($hv | Measure-Object NumCpu -Sum).Sum)
    $cores = 0; try { $cores = [int]$h.ExtensionData.Hardware.CpuInfo.NumCpuCores } catch { $cores = 0 }
    $swap = 0.0; $bal = 0.0
    foreach ($v in $hv) { try { $swap += [double]$v.ExtensionData.Summary.QuickStats.SwappedMemory; $bal += [double]$v.ExtensionData.Summary.QuickStats.BalloonedMemory } catch { } }
    $large = @($hv | Where-Object { $_.MemoryGB -ge $largeGB }); $medium = @($hv | Where-Object { $_.MemoryGB -ge $mediumGB -and $_.MemoryGB -lt $largeGB })
    $commit = if ($phys -gt 0) { [math]::Round(100 * $vram / $phys) } else { 0 }
    $flags = [System.Collections.Generic.List[string]]::new()
    if ($commit -gt 100) { $flags.Add("vRAM over-committed ($commit %)") }
    if ($large.Count -gt 1) { $flags.Add("$($large.Count) VMs >= $largeGB GB") }
    if ($large.Count -ge 1 -and $medium.Count -ge 1) { $flags.Add("$largeGB GB VM + $($medium.Count) VM(s) >= $mediumGB GB") }
    if ($swap -gt 0) { $flags.Add("swapped $([math]::Round($swap / 1024, 1)) GB") }
    if ($bal -gt 0) { $flags.Add("ballooned $([math]::Round($bal / 1024, 1)) GB") }
    [ordered]@{
        Host = Get-Short ([string]$h.Name); State = [string](Get-V $h 'ConnectionState' ''); VMs = $hv.Count; 'Physical GB' = [math]::Round($phys); 'vRAM GB' = [math]::Round($vram)
        'vRAM %' = $commit; 'Memory used %' = $(if ($phys -gt 0) { [math]::Round(100 * $used / $phys) } else { 0 }); 'vCPU:core' = $(if ($cores) { [math]::Round($vcpu / $cores, 2) } else { '' })
        'Swap / balloon GB' = "$([math]::Round($swap / 1024, 1)) / $([math]::Round($bal / 1024, 1))"
        'Large VMs' = @($hv | Where-Object { $_.MemoryGB -ge $mediumGB } | Sort-Object MemoryGB -Descending | ForEach-Object { "$($_.Name) ($($_.NumCpu)/$([math]::Round($_.MemoryGB)))" })
        Status = $(if ($flags.Count) { 'WARN ' + (@($flags) -join '; ') } else { 'OK' })
    }
}

# ---- VM detail, recommendations, decommission ----------------------------------------------------
$membership = @{}
foreach ($r in $rules) { foreach ($id in @($r.VMIds)) { $v = $byId[[string]$id]; if ($v) { $membership[$v.Name] = @($membership[$v.Name]) + [string]$r.Name | Where-Object { $_ } } } }
$vmRows = @(if ($pattern) { $vms | Where-Object { $_.Name -match $pattern } | Sort-Object { $_.VMHost.Name }, Name | ForEach-Object {
    $qs = $null; $res = 0
    try { $qs = $_.ExtensionData.Summary.QuickStats } catch { $qs = $null }
    try { $res = [math]::Round([double]$_.ExtensionData.ResourceConfig.MemoryAllocation.Reservation / 1024) } catch { $res = 0 }
    [ordered]@{ VM = $_.Name; Host = Get-Short ([string]$_.VMHost.Name); Power = [string]$_.PowerState; vCPU = $_.NumCpu; 'Memory GB' = [math]::Round($_.MemoryGB)
                'Reservation GB' = $res; 'Swapped MB' = $(if ($qs) { $qs.SwappedMemory } else { '' }); 'Ballooned MB' = $(if ($qs) { $qs.BalloonedMemory } else { '' })
                'DRS rules' = (@($membership[$_.Name]) -join ', ') }
} })
$recRows = @($recs | ForEach-Object { [ordered]@{ Priority = (Get-V $_ 'Priority' ''); Reason = [string](Get-V $_ 'Reason' ''); Recommendation = [string](Get-V $_ 'Recommendation' '') } })
$decomRows = @($decom | ForEach-Object {
    $n = [string]$_; $v = @(Get-VM -Name $n -Server $vi -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($v) { [ordered]@{ VM = $n; Status = "WARN still present ($($v.PowerState))"; Host = Get-Short ([string]$v.VMHost.Name); 'Memory GB' = $v.MemoryGB } }
    else { [ordered]@{ VM = $n; Status = 'OK removed'; Host = ''; 'Memory GB' = '' } }
})

$compliant = @($ruleRows | Where-Object { $_.Compliance -eq 'COMPLIANT' }).Count
$violations = @($ruleRows | Where-Object { $_.Compliance -eq 'NON-COMPLIANT' }).Count
$over = @($hostRows | Where-Object { $_['vRAM %'] -gt 100 }).Count
$sections = @(
    New-PortalReportSection -Title 'DRS rule compliance' -Columns 'Rule', 'Source', 'Type', 'Placement', 'Compliance', 'Issues', 'Note' -Rows $ruleRows -Note 'Separate = every powered-on member on a different host. Together = all powered-on members on one host.'
    New-PortalReportSection -Title 'Host allocation' -Columns 'Host', 'State', 'VMs', 'Physical GB', 'vRAM GB', 'vRAM %', 'Memory used %', 'vCPU:core', 'Swap / balloon GB', 'Large VMs', 'Status' -Rows @($hostRows) -Note "vRAM % = memory configured on powered-on VMs / physical memory. Large VMs = $mediumGB GB or more (vCPU/GB)."
)
if ($pattern) { $sections += New-PortalReportSection -Title "VM detail ($pattern)" -Columns 'VM', 'Host', 'Power', 'vCPU', 'Memory GB', 'Reservation GB', 'Swapped MB', 'Ballooned MB', 'DRS rules' -Rows $vmRows }
$sections += New-PortalReportSection -Title 'Pending DRS recommendations' -Columns 'Priority', 'Reason', 'Recommendation' -Rows $recRows
if ($decomRows.Count) { $sections += New-PortalReportSection -Title 'Decommission candidates' -Columns 'VM', 'Status', 'Host', 'Memory GB' -Rows $decomRows }

$drsLevel = [string](Get-V $cl 'DrsAutomationLevel' '')
$files = New-PortalReport -Title "DRS rule compliance - $Cluster" -Subtitle "$Site - DRS automation $drsLevel" -Context $Context -Sections $sections -FileName 'drs-compliance' -Summary ([ordered]@{
    'Rules compliant' = "$compliant / $($ruleRows.Count)"; 'Rules violated' = $violations; 'Hosts vRAM > 100 %' = $over; 'DRS recommendations' = $recRows.Count })
Write-JobLog -Level OK "$compliant of $($ruleRows.Count) rule(s) compliant, $violations violated, $over host(s) over-committed."

$r = [ordered]@{ Cluster = $Cluster; Rules = $ruleRows.Count; Compliant = $compliant; Violations = $violations; HostsOvercommitted = $over; Report = $files[0].name }
$viol = @($ruleRows | Where-Object { $_.Compliance -eq 'NON-COMPLIANT' } | ForEach-Object { "$($_.Rule): $($_.Issues)" })
if ($viol.Count) { $r['NonCompliant'] = $viol; $r['NextSteps'] = @('Let DRS apply its recommendations or move the VMs with the "vMotion" item; create missing rules with the "DRS Rule" item.') }
return $r
