#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - creates a DRS rule (VM-VM affinity / anti-affinity or VM-Host) on a cluster.
.DESCRIPTION
    Used by catalog item drs-rule and called directly by the three-tier blueprint handler: keep the parameter
    contract (Site, Cluster, RuleType, RuleName, VMNames, HostNames, ChangeTicket, Context) stable.

    Pre-checks: >= 2 VMs for VM-VM rules; every VM exists and runs in the cluster; every host belongs to the cluster;
    the rule name is unused; no enabled VM-VM rule of the opposite type already holds >= 2 of the same VMs.
    VM-VM:   New-DrsRule -KeepTogether $true (VmAffinity) / $false (VmAntiAffinity).
    VM-Host: DRS groups "<RuleName>-vms" and "<RuleName>-hosts" are created or reused (missing members added),
             then New-DrsVMHostRule. Groups created by this run are removed again if the rule creation fails.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] [string] $Cluster,
    [Parameter(Mandatory)] [ValidateSet('VmAntiAffinity', 'VmAffinity', 'VmHostMust', 'VmHostShould', 'VmHostMustNot', 'VmHostShouldNot')] [string] $RuleType,
    [Parameter(Mandatory)] [string] $RuleName,
    [Parameter(Mandatory)] [string] $VMNames,
    [string] $HostNames,
    [string] $ChangeTicket,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}

$vi       = $Context.VIServer
$defaults = $Context.Site.defaults
$isVmVm   = $RuleType -in 'VmAntiAffinity', 'VmAffinity'
$created  = [System.Collections.Generic.List[object]]::new()   # DRS groups created by this run (rollback)

function Split-NameList { param([string] $Text) @(($Text -split '[,;\r\n]+') | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique) }

try {
    #region 1. Pre-checks -----------------------------------------------------------------------------------
    Write-JobLog -Level STEP "Pre-checks: $RuleType rule '$RuleName' on cluster $Cluster"
    if ($RuleName -notmatch '^[A-Za-z0-9][A-Za-z0-9 _.-]{2,75}$') { throw "Rule name '$RuleName' is invalid (3-76 characters: letters, digits, space, '_', '.', '-')." }

    $allowed = @($defaults.allowedClusters | Where-Object { $_ })
    if ($allowed.Count -and -not ($allowed | Where-Object { $_ -ieq $Cluster })) { throw "Cluster $Cluster is not in the allowed clusters of site $Site ($($allowed -join ', '))." }

    $vmList   = Split-NameList $VMNames
    $hostList = Split-NameList $HostNames
    if ($isVmVm -and $vmList.Count -lt 2) { throw "A $RuleType rule needs at least 2 VMs ($($vmList.Count) given)." }
    if (-not $isVmVm -and $vmList.Count -lt 1) { throw 'A VM-Host rule needs at least 1 VM.' }
    if (-not $isVmVm -and $hostList.Count -lt 1) { throw 'A VM-Host rule needs at least 1 host (HostNames).' }
    if ($isVmVm -and $hostList.Count) { Write-JobLog -Level WARN "HostNames is ignored for $RuleType rules." }

    $cl = Get-Cluster -Name $Cluster -Server $vi
    if ($cl.PSObject.Properties['DrsEnabled'] -and -not $cl.DrsEnabled) { Write-JobLog -Level WARN "DRS is disabled on ${Cluster}: the rule is stored but not enforced until DRS is enabled." }

    # VMs: exist + run in the cluster.
    $clusterVms = @(Get-VM -Location $cl -Server $vi)
    $vms = [System.Collections.Generic.List[object]]::new()
    $missing = @(); $outside = @()
    foreach ($n in $vmList) {
        $inCl = $clusterVms | Where-Object { $_.Name -ieq $n } | Select-Object -First 1
        if ($inCl) { $vms.Add($inCl); continue }
        if (Get-VM -Name $n -Server $vi -ErrorAction SilentlyContinue) { $outside += $n } else { $missing += $n }
    }
    if ($missing) { throw "VM(s) not found: $($missing -join ', ')." }
    if ($outside) { throw "VM(s) not running in cluster ${Cluster}: $($outside -join ', ')." }

    # Hosts: belong to the cluster (FQDN or short name).
    $hosts = [System.Collections.Generic.List[object]]::new()
    if (-not $isVmVm) {
        $clusterHosts = @(Get-VMHost -Location $cl -Server $vi)
        $badHosts = @()
        foreach ($h in $hostList) {
            $m = $clusterHosts | Where-Object { $_.Name -ieq $h -or $_.Name -ilike "$h.*" } | Select-Object -First 1
            if ($m) { $hosts.Add($m) } else { $badHosts += $h }
        }
        if ($badHosts) { throw "Host(s) not in cluster ${Cluster}: $($badHosts -join ', ')." }
    }

    # Rule name unused (VM-VM and VM-Host rules share the cluster rule namespace).
    $vmVmRules   = @(Get-DrsRule -Cluster $cl -Server $vi -ErrorAction SilentlyContinue)
    $vmHostRules = @(Get-DrsVMHostRule -Cluster $cl -Server $vi -ErrorAction SilentlyContinue)
    if (($vmVmRules + $vmHostRules) | Where-Object { $_.Name -ieq $RuleName }) { throw "A DRS rule named '$RuleName' already exists on cluster $Cluster." }

    # Conflict check: enabled VM-VM rule of the opposite type sharing >= 2 VMs.
    if ($isVmVm) {
        $idToName = @{}; foreach ($v in $clusterVms) { if ($v.Id) { $idToName[[string]$v.Id] = $v.Name } }
        $wantKeep = $RuleType -eq 'VmAffinity'
        foreach ($r in $vmVmRules | Where-Object { $_.Enabled }) {
            $keep = if ($null -ne $r.KeepTogether) { [bool]$r.KeepTogether } else { [string]$r.Type -eq 'VMAffinity' }
            if ($keep -eq $wantKeep) { continue }
            $members = @($r.VMIds | ForEach-Object { if ($idToName.ContainsKey([string]$_)) { $idToName[[string]$_] } else { [string]$_ } })
            $common = @($vmList | Where-Object { $members -icontains $_ })
            if ($common.Count -ge 2) {
                $otherType = if ($keep) { 'affinity' } else { 'anti-affinity' }
                throw "Conflict: enabled $otherType rule '$($r.Name)' on $Cluster already contains $($common -join ', '). Disable or change that rule first."
            }
        }
    }
    if ($RuleType -eq 'VmAntiAffinity') {
        $hostCount = @(Get-VMHost -Location $cl -Server $vi | Where-Object ConnectionState -eq 'Connected').Count
        if ($hostCount -and $vmList.Count -gt $hostCount) { Write-JobLog -Level WARN "$($vmList.Count) VMs but only $hostCount connected hosts: DRS cannot satisfy the anti-affinity rule for every VM." }
    }
    Write-JobLog "VMs: $($vmList -join ', ')$(if ($hosts.Count) { "; hosts: $(@($hosts.Name) -join ', ')" })"
    #endregion

    #region 2. Create -----------------------------------------------------------------------------------------
    $vmGroupName = $null; $hostGroupName = $null
    if ($isVmVm) {
        Write-JobLog -Level STEP "Creating $RuleType rule $RuleName"
        $rule = New-DrsRule -Cluster $cl -Name $RuleName -KeepTogether ($RuleType -eq 'VmAffinity') -VM $vms.ToArray() -Enabled $true -Server $vi
    }
    else {
        $vmGroupName = "$RuleName-vms"; $hostGroupName = "$RuleName-hosts"

        Write-JobLog -Level STEP "DRS VM group $vmGroupName"
        $vg = Get-DrsClusterGroup -Cluster $cl -Name $vmGroupName -Server $vi -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($vg) {
            $have = @($vg.Member | ForEach-Object Name)
            $add = @($vms | Where-Object { $have -notcontains $_.Name })
            if ($add) { $vg = Set-DrsClusterGroup -DrsClusterGroup $vg -VM $add -Add -Server $vi; Write-JobLog "Reused $vmGroupName, added $(@($add.Name) -join ', ')." }
            else { Write-JobLog "Reused $vmGroupName (members already present)." }
        }
        else {
            $vg = New-DrsClusterGroup -Cluster $cl -Name $vmGroupName -VM $vms.ToArray() -Server $vi
            $created.Add($vg); Write-JobLog -Level OK "Created $vmGroupName."
        }

        Write-JobLog -Level STEP "DRS host group $hostGroupName"
        $hg = Get-DrsClusterGroup -Cluster $cl -Name $hostGroupName -Server $vi -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hg) {
            $have = @($hg.Member | ForEach-Object Name)
            $add = @($hosts | Where-Object { $have -notcontains $_.Name })
            if ($add) { $hg = Set-DrsClusterGroup -DrsClusterGroup $hg -VMHost $add -Add -Server $vi; Write-JobLog "Reused $hostGroupName, added $(@($add.Name) -join ', ')." }
            else { Write-JobLog "Reused $hostGroupName (members already present)." }
        }
        else {
            $hg = New-DrsClusterGroup -Cluster $cl -Name $hostGroupName -VMHost $hosts.ToArray() -Server $vi
            $created.Add($hg); Write-JobLog -Level OK "Created $hostGroupName."
        }

        $type = @{ VmHostMust = 'MustRunOn'; VmHostShould = 'ShouldRunOn'; VmHostMustNot = 'MustNotRunOn'; VmHostShouldNot = 'ShouldNotRunOn' }[$RuleType]
        Write-JobLog -Level STEP "Creating VM-Host rule $RuleName ($type)"
        $rule = New-DrsVMHostRule -Cluster $cl -Name $RuleName -VMGroup $vg -VMHostGroup $hg -Type $type -Enabled $true -Server $vi
    }
    Write-JobLog -Level OK "DRS rule $($rule.Name) created on $Cluster (change $ChangeTicket, request $($Context.RequestId))."
    #endregion
}
catch {
    $msg = $_.Exception.Message
    if ($created.Count -and $Context.RollbackOnFailure) {
        foreach ($g in $created) {
            Write-JobLog -Level WARN "Rolling back: removing DRS group $($g.Name)"
            try { Remove-DrsClusterGroup -DrsClusterGroup $g -Confirm:$false }
            catch { Write-JobLog -Level ERROR "Rollback failed for $($g.Name): $($_.Exception.Message)" }
        }
    }
    throw $msg
}

return [ordered]@{
    RuleName     = $RuleName
    RuleType     = $RuleType
    Cluster      = $Cluster
    VMs          = [string[]]@($vms | ForEach-Object Name)
    Hosts        = [string[]]@($hosts | ForEach-Object Name)
    VMGroup      = [string]$vmGroupName
    HostGroup    = [string]$hostGroupName
    ChangeTicket = $ChangeTicket
    NextSteps    = @("Check the rule in vSphere Client > $Cluster > Configure > VM/Host Rules after the next DRS run.")
}
