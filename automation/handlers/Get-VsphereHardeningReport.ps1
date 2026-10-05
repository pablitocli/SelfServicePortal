#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - read-only hardening compliance report for ESXi hosts (and optionally VMs).
.DESCRIPTION
    Checks come from the "Hardening baseline" data file (config/hardening-baseline.json, Admin > Data files):
      esxiAdvancedSettings[]  { id, name, operator, expected, [defaultCompliant], description }   Get-AdvancedSetting per host
      esxiServices[]          { key, [running], [policy], description }                          Get-VMHostService per host
      esxiNtpRequired         true -> at least one NTP server configured and the ntpd service running
      vmAdvancedSettings[]    same shape as esxiAdvancedSettings, read from Config.ExtraConfig (only with -IncludeVms)
    Operators: eq | ne | le | ge | range [min,max] | nonEmpty. A setting that is absent is PASS when defaultCompliant is
    true (the product default meets the control), otherwise NOT SET.
    Nothing is changed. Remediation will be a separate item that requires approval.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [string] $Cluster,
    [bool] $IncludeVms = $false,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}

$vi = $Context.VIServer
if (-not $vi) { throw 'No vCenter session (the item requires a vCenter connection).' }

function Get-Val { param($T, [string] $K, $D = $null) if ($T -is [System.Collections.IDictionary] -and $T.Contains($K) -and $null -ne $T[$K]) { $T[$K] } else { $D } }

function Test-HardeningValue {
    <# Returns $true / $false for a present value against operator + expected. #>
    param($Value, [string] $Operator, $Expected)
    $num = { param($x) $d = 0.0; if ([double]::TryParse([string]$x, [System.Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$d)) { $d } else { $null } }
    $same = {
        param($a, $b)
        if ($b -is [bool]) { $s = ([string]$a).Trim().ToLowerInvariant(); return ($s -in 'true', '1', 'yes') -eq $b -and ($s -in 'true', '1', 'yes', 'false', '0', 'no') }
        $na = & $num $a; $nb = & $num $b
        if ($null -ne $na -and $null -ne $nb) { return $na -eq $nb }
        return ([string]$a).Trim() -ieq ([string]$b).Trim()
    }
    switch ($Operator) {
        'eq'       { return [bool](& $same $Value $Expected) }
        'ne'       { return -not (& $same $Value $Expected) }
        'le'       { $v = & $num $Value; return ($null -ne $v -and $v -le [double]$Expected) }
        'ge'       { $v = & $num $Value; return ($null -ne $v -and $v -ge [double]$Expected) }
        'range'    { $v = & $num $Value; $e = @($Expected); return ($null -ne $v -and $v -ge [double]$e[0] -and $v -le [double]$e[1]) }
        'nonEmpty' { return -not [string]::IsNullOrWhiteSpace([string]$Value) }
        default    { throw "Unknown operator '$Operator'." }
    }
}

function Format-Expected { param([string] $Operator, $Expected)
    switch ($Operator) {
        'range'    { $e = @($Expected); "$($e[0])..$($e[1])" }
        'nonEmpty' { 'not empty' }
        'eq'       { "$Expected" }
        default    { "$Operator $Expected" }
    }
}

$rows = [System.Collections.Generic.List[object]]::new()
function Add-CheckRow {
    param([string] $Entity, [string] $Type, [string] $Check, [string] $Setting, [string] $Expected, $Actual, [string] $Result, [string] $Description)
    $rows.Add([ordered]@{ Entity = $Entity; Type = $Type; Check = $Check; Setting = $Setting; Expected = $Expected
                          Actual = $(if ($null -eq $Actual) { '(absent)' } else { [string]$Actual }); Result = $Result; Description = $Description })
}
function Invoke-SettingChecks {
    <# Evaluates a list of setting checks against a name -> value map (absent keys = not configured). #>
    param([string] $Entity, [string] $Type, $Checks, [hashtable] $Values)
    foreach ($c in $Checks) {
        $name = [string](Get-Val $c 'name' ''); $op = [string](Get-Val $c 'operator' 'eq'); $exp = Get-Val $c 'expected'
        $desc = [string](Get-Val $c 'description' '')
        if ($Values.ContainsKey($name)) {
            $ok = Test-HardeningValue -Value $Values[$name] -Operator $op -Expected $exp
            Add-CheckRow $Entity $Type ([string]$c.id) $name (Format-Expected $op $exp) $Values[$name] $(if ($ok) { 'PASS' } else { 'FAIL' }) $desc
        }
        elseif ([bool](Get-Val $c 'defaultCompliant' $false)) {
            Add-CheckRow $Entity $Type ([string]$c.id) $name (Format-Expected $op $exp) $null 'PASS' "$desc (absent: product default is compliant)"
        }
        else {
            Add-CheckRow $Entity $Type ([string]$c.id) $name (Format-Expected $op $exp) $null 'NOT SET' $desc
        }
    }
}

$baseline   = Get-PortalDataFile -Name hardeningBaseline
$esxChecks  = @(Get-Val $baseline 'esxiAdvancedSettings' @() | Where-Object { $_ })
$svcChecks  = @(Get-Val $baseline 'esxiServices' @() | Where-Object { $_ })
$ntpReq     = [bool](Get-Val $baseline 'esxiNtpRequired' $false)
$vmChecks   = @(Get-Val $baseline 'vmAdvancedSettings' @() | Where-Object { $_ })

# --- Scope -----------------------------------------------------------------------------------------------------
if ($Cluster) {
    $allowed = @()
    if ($Context.Site -and $Context.Site.defaults -and $Context.Site.defaults.allowedClusters) { $allowed = @($Context.Site.defaults.allowedClusters) }
    if ($allowed.Count -and $allowed -notcontains $Cluster) { throw "Cluster '$Cluster' is not allowed for site $Site ($($allowed -join ', '))." }
    $cl = Get-Cluster -Name $Cluster -Server $vi
    $vmHosts = @(Get-VMHost -Location $cl -Server $vi)
    $scope = "cluster $Cluster"
}
else {
    $vmHosts = @(Get-VMHost -Server $vi)
    $scope = 'all hosts'
}
if (-not $vmHosts.Count) { throw "No ESXi hosts found ($scope)." }
Write-JobLog -Level STEP "Checking $($vmHosts.Count) host(s) in $scope against $($esxChecks.Count) settings, $($svcChecks.Count) services$(if ($ntpReq) { ', NTP' })"

$names = @($esxChecks | ForEach-Object { [string]$_.name } | Where-Object { $_ })
foreach ($h in ($vmHosts | Sort-Object Name)) {
    if ([string]$h.ConnectionState -notin 'Connected', 'Maintenance') {
        Add-CheckRow $h.Name 'Host' 'host-reachable' 'ConnectionState' 'Connected' ([string]$h.ConnectionState) 'FAIL' 'Host not connected: checks skipped.'
        continue
    }
    try {
        # Advanced settings: one call per host for all names (absent names are simply not returned).
        $values = @{}
        if ($names) { foreach ($s in @(Get-AdvancedSetting -Entity $h -Name $names -Server $vi -ErrorAction SilentlyContinue)) { if ($s) { $values[[string]$s.Name] = $s.Value } } }
        Invoke-SettingChecks -Entity $h.Name -Type 'Host' -Checks $esxChecks -Values $values

        # Services
        $services = @()
        if ($svcChecks -or $ntpReq) { $services = @(Get-VMHostService -VMHost $h -Server $vi) }
        foreach ($c in $svcChecks) {
            $svc = $services | Where-Object { $_.Key -eq $c.key } | Select-Object -First 1
            $exp = @(); $act = @(); $ok = $true
            if ($c -is [System.Collections.IDictionary] -and $c.Contains('running')) {
                $exp += "running=$([bool]$c.running)".ToLower()
                if ($svc) { $act += "running=$([bool]$svc.Running)".ToLower(); if ([bool]$svc.Running -ne [bool]$c.running) { $ok = $false } }
            }
            if ($c -is [System.Collections.IDictionary] -and $c.Contains('policy') -and $c.policy) {
                $exp += "policy=$($c.policy)"
                if ($svc) { $act += "policy=$($svc.Policy)"; if ([string]$svc.Policy -ne [string]$c.policy) { $ok = $false } }
            }
            $result = if (-not $svc) { 'NOT SET' } elseif ($ok) { 'PASS' } else { 'FAIL' }
            Add-CheckRow $h.Name 'Host' "service-$($c.key)" "Service $($c.key)" ($exp -join ', ') $(if ($svc) { $act -join ', ' } else { $null }) $result ([string](Get-Val $c 'description' ''))
        }

        # NTP
        if ($ntpReq) {
            $ntpServers = @(Get-VMHostNtpServer -VMHost $h -Server $vi -ErrorAction SilentlyContinue | Where-Object { $_ })
            $ntpd = $services | Where-Object { $_.Key -eq 'ntpd' } | Select-Object -First 1
            $ok = $ntpServers.Count -gt 0 -and $ntpd -and [bool]$ntpd.Running
            Add-CheckRow $h.Name 'Host' 'esxi-ntp' 'NTP' 'servers configured, ntpd running' ("servers=$($ntpServers -join ' '); ntpd running=$(if ($ntpd) { [bool]$ntpd.Running } else { 'n/a' })") `
                $(if ($ok) { 'PASS' } else { 'FAIL' }) 'Time synchronised with NTP.'
        }
    }
    catch {
        Write-JobLog -Level WARN "Host $($h.Name): $($_.Exception.Message)"
        Add-CheckRow $h.Name 'Host' 'host-readable' '-' '-' $_.Exception.Message 'FAIL' 'Checks could not be read.'
    }
}

# --- VMs (optional, from Config.ExtraConfig: one Get-View call for all VMs) -------------------------------------
$vmCount = 0
if ($IncludeVms -and $vmChecks) {
    Write-JobLog -Level STEP "Checking VM advanced settings ($($vmChecks.Count) checks)"
    $hostIds = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($h in $vmHosts) { [void]$hostIds.Add([string]$h.Id) }
    foreach ($v in (@(Get-View -Server $vi -ViewType VirtualMachine -Property Name, Config.Template, Config.ExtraConfig, Runtime.Host) | Sort-Object Name)) {
        if ($v.Config.Template) { continue }
        if ($Cluster -and -not $hostIds.Contains([string]$v.Runtime.Host)) { continue }
        $vmCount++
        $values = @{}
        foreach ($o in @($v.Config.ExtraConfig)) { if ($o -and $o.Key) { $values[[string]$o.Key] = $o.Value } }
        Invoke-SettingChecks -Entity $v.Name -Type 'VM' -Checks $vmChecks -Values $values
    }
    Write-JobLog "VMs checked: $vmCount"
}

# --- Report ----------------------------------------------------------------------------------------------------
$pass = @($rows | Where-Object Result -eq 'PASS').Count
$fail = @($rows | Where-Object Result -eq 'FAIL').Count
$notSet = @($rows | Where-Object Result -eq 'NOT SET').Count
$pct = if ($rows.Count) { [math]::Round($pass / $rows.Count * 100, 1) } else { 0 }

$byEntity = @($rows | Group-Object Entity | ForEach-Object {
    $g = @($_.Group)
    $f = @($g | Where-Object Result -eq 'FAIL').Count; $n = @($g | Where-Object Result -eq 'NOT SET').Count
    [ordered]@{ Entity = $_.Name; Type = $g[0].Type; Checks = $g.Count; Pass = @($g | Where-Object Result -eq 'PASS').Count; Fail = $f; NotSet = $n
                Result = $(if ($f) { 'FAIL' } elseif ($n) { 'NOT SET' } else { 'PASS' }) }
})
$cols = 'Entity', 'Check', 'Setting', 'Expected', 'Actual', 'Result', 'Description'
$sections = @(
    New-PortalReportSection -Title 'Summary by entity' -Rows $byEntity -Columns Entity, Type, Checks, Pass, Fail, NotSet, Result `
        -Note 'Read-only assessment. Remediation will be a separate item that requires approval.'
    New-PortalReportSection -Title 'ESXi checks' -Rows @($rows | Where-Object Type -eq 'Host') -Columns $cols `
        -Note 'NOT SET: the setting is absent and the product default does not meet the control.'
)
if ($IncludeVms) {
    $sections += New-PortalReportSection -Title 'VM checks' -Rows @($rows | Where-Object Type -eq 'VM') -Columns $cols
}
$summary = [ordered]@{ 'Checks' = $rows.Count; 'Pass' = $pass; 'Fail' = $fail; 'Not set' = $notSet; 'Compliance %' = $pct }
$files = New-PortalReport -Title "Hardening compliance - $Site" -Subtitle "Scope: $scope$(if ($IncludeVms) { ' + VMs' })" -Context $Context -Sections $sections -Summary $summary -FileName 'hardening-compliance'
Write-JobLog -Level OK "Report written: $($files[0].name) ($pct% compliant)"

return [ordered]@{
    Site              = $Site
    Scope             = $scope
    Hosts             = $vmHosts.Count
    VMs               = $vmCount
    Checks            = $rows.Count
    Pass              = $pass
    Fail              = $fail
    NotSet            = $notSet
    CompliancePercent = $pct
    Report            = $files[0].name
    NextSteps         = @('Remediation will be a separate item that requires approval.')
}
