#Requires -Version 7.2
<#
.SYNOPSIS
    Blueprint handler - deploys a three-tier Windows application (WEB, APP, DB VMs) in one request.
.DESCRIPTION
    Used by catalog item blueprint-three-tier. Orchestrates other catalog handlers (automation/handlers, called by file
    with only the parameters each script declares, so a signature change does not break the blueprint):

      1. New-VsphereVM.ps1            x3  <AppCode>WEB01 / <AppCode>APP01 on the Workload cluster,
                                          <AppCode>DB01 on the site's DB workload cluster (same datastore)
      2. DB data disks (InstallSql)       3 extra thin disks so the DB VM has 4 RAW disks for SQL disk preparation
      3. New-VsphereDrsRule.ps1           VM anti-affinity WEB <-> APP when both run in the same cluster
      4. Install-GuestAgentBaseline.ps1   software baseline set on each VM
      5. Set-PortalBackupPolicy.ps1       backup policy on the three VMs
      6. Install-GuestSqlServer.ps1       SQL Server on the DB VM (InstallSql)

    Pre-checks: AppCode / names (<= 15 chars, unused), distinct IPs, clusters mapped, datastore visible on both the
    APP-tier and the DB cluster, fixed parameters configured (no TBD- placeholders), every sub-handler file present and
    every mandatory parameter of each sub-handler supplied.
    Every step is recorded (Step, Target, Status, Detail) and written to a summary report (also on failure).
    On failure with RollbackOnFailure: the DRS rule and the VMs created by this run are removed, in reverse order.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $AppCode,
    [Parameter(Mandatory)] [string] $Site,
    [ValidateSet('App', 'DB')] [string] $Workload = 'App',
    [Parameter(Mandatory)] [string] $Datastore,
    [Parameter(Mandatory)] [string] $Folder,
    [Parameter(Mandatory)] [string] $PortGroup,
    [Parameter(Mandatory)] [string] $IpWeb,
    [Parameter(Mandatory)] [string] $IpApp,
    [Parameter(Mandatory)] [string] $IpDb,
    [Parameter(Mandatory)] [string] $SubnetMask,
    [Parameter(Mandatory)] [string] $Gateway,
    [string] $DnsServers,
    [ValidateSet('Small', 'Medium', 'Large')] [string] $Size = 'Medium',
    [Parameter(Mandatory)] [pscredential] $GuestCredential,
    [string] $BaselineSet,
    [string] $BackupPolicy,
    [bool] $InstallSql = $true,
    [string] $SysAdminGroup,
    [string] $ChangeTicket,
    [Parameter(Mandatory)] [string] $Owner,
    [Parameter(Mandatory)] [string] $CostCenter,
    [Parameter(Mandatory)] [string] $Template,            # fixed per site
    [Parameter(Mandatory)] [string] $CustomizationSpec,   # fixed per site
    [string] $SqlInstallerPath,                           # fixed per site (folder with setup.exe)
    [string] $SqlDiskSizesGB = '100,50,100,50',           # fixed: data, logs, backup, tempdb disks of the DB VM
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}

$vi          = $Context.VIServer
$defaults    = $Context.Site.defaults
$handlerDir  = Join-Path $Context.PortalRoot 'automation/handlers'
$steps       = [System.Collections.Generic.List[object]]::new()
$createdVMs  = [System.Collections.Generic.List[string]]::new()
$createdRule = $null
$plan        = [System.Collections.Generic.List[object]]::new()
$vmRows      = [System.Collections.Generic.List[object]]::new()

function Get-MapValue {
    param($Map, [string] $Key)
    if ($Map -is [System.Collections.IDictionary]) { foreach ($k in $Map.Keys) { if ([string]$k -ieq $Key) { return $Map[$k] } } }
    elseif ($Map) { $p = $Map.PSObject.Properties | Where-Object { $_.Name -ieq $Key } | Select-Object -First 1; if ($p) { return $p.Value } }
    return $null
}

function Add-Step {
    param([string] $Step, [string] $Target, [string] $Status, [string] $Detail)
    $row = [ordered]@{ '#' = $steps.Count + 1; Step = $Step; Target = $Target; Status = $Status; Detail = $Detail }
    $steps.Add($row); return $row
}

function Get-SubHandlerParameters {
    <# Keeps only the parameters the target script declares; returns @{ Params; Dropped; MissingMandatory }. #>
    param([string] $Path, [hashtable] $Wanted)
    $cmd = Get-Command -Name $Path
    $p = @{}; $dropped = @()
    foreach ($k in $Wanted.Keys) {
        if ($cmd.Parameters.ContainsKey($k)) { if ($null -ne $Wanted[$k] -and "$($Wanted[$k])" -ne '') { $p[$k] = $Wanted[$k] } }
        else { $dropped += $k }
    }
    $missing = @($cmd.Parameters.Values | Where-Object {
        $n = $_.Name
        -not $p.ContainsKey($n) -and @($_.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count
    } | ForEach-Object { $_.Name })
    return @{ Params = $p; Dropped = $dropped; MissingMandatory = $missing }
}

function Remove-BlueprintArtifacts {
    <# Rollback: DRS rule first, then the VMs in reverse creation order. #>
    if ($createdRule) {
        try {
            $cl = Get-Cluster -Name $createdRule.Cluster -Server $vi
            $r = Get-DrsRule -Cluster $cl -Name $createdRule.Name -Server $vi -ErrorAction SilentlyContinue
            if ($r) { Remove-DrsRule -Rule $r -Confirm:$false }
            Write-JobLog -Level WARN "Rollback: DRS rule '$($createdRule.Name)' removed."
            $null = Add-Step -Step 'Rollback: remove DRS rule' -Target $createdRule.Name -Status 'OK' -Detail $createdRule.Cluster
        }
        catch {
            Write-JobLog -Level ERROR "Rollback: could not remove DRS rule '$($createdRule.Name)': $($_.Exception.Message)"
            $null = Add-Step -Step 'Rollback: remove DRS rule' -Target $createdRule.Name -Status 'FAIL' -Detail $_.Exception.Message
        }
    }
    for ($i = $createdVMs.Count - 1; $i -ge 0; $i--) {
        $n = $createdVMs[$i]
        try {
            $v = Get-VM -Name $n -Server $vi -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($v) {
                if ([string]$v.PowerState -eq 'PoweredOn') { $null = Stop-VM -VM $v -Kill -Confirm:$false }
                Remove-VM -VM $v -DeletePermanently -Confirm:$false
            }
            Write-JobLog -Level WARN "Rollback: VM $n removed."
            $null = Add-Step -Step 'Rollback: remove VM' -Target $n -Status 'OK' -Detail 'Deleted permanently'
        }
        catch {
            Write-JobLog -Level ERROR "Rollback: could not remove VM ${n} - manual cleanup required: $($_.Exception.Message)"
            $null = Add-Step -Step 'Rollback: remove VM' -Target $n -Status 'FAIL' -Detail $_.Exception.Message
        }
    }
}

function Write-BlueprintReport {
    param([string] $Outcome)
    try {
        $files = New-PortalReport -Title "Three-tier blueprint $AppCode" -Subtitle "$Site - $Outcome" -Context $Context -FileName "blueprint-$($AppCode.ToLower())" -Sections @(
            New-PortalReportSection -Title 'Steps' -Rows $steps.ToArray() -Columns '#', Step, Target, Status, Detail
            New-PortalReportSection -Title 'Virtual machines' -Rows $vmRows.ToArray() -Columns Tier, VM, Cluster, IPAddress, vCPU, MemoryGB, Status
        ) -Summary ([ordered]@{ Outcome = $Outcome; Steps = $steps.Count; Failed = @($steps | Where-Object { $_.Status -eq 'FAIL' }).Count; VMs = $createdVMs.Count })
        return $files[0].name
    }
    catch { Write-JobLog -Level WARN "Summary report not written: $($_.Exception.Message)"; return $null }
}

try {
    #region 1. Pre-checks -----------------------------------------------------------------------------------
    Write-JobLog -Level STEP "Pre-checks: three-tier blueprint '$AppCode' at site $Site"
    $AppCode = $AppCode.ToUpperInvariant()
    if ($AppCode -notmatch '^[A-Z0-9]{2,8}$') { throw "AppCode '$AppCode' must be 2-8 uppercase letters or digits." }
    $names = [ordered]@{ WEB = "${AppCode}WEB01"; APP = "${AppCode}APP01"; DB = "${AppCode}DB01" }
    foreach ($n in $names.Values) { if ($n.Length -gt 15) { throw "VM name $n exceeds 15 characters (NetBIOS)." } }
    $ips = [ordered]@{ WEB = $IpWeb; APP = $IpApp; DB = $IpDb }
    if (@($ips.Values | Select-Object -Unique).Count -ne 3) { throw "The three IP addresses must be different ($($ips.Values -join ', '))." }

    foreach ($fp in @(@('Template', $Template), @('CustomizationSpec', $CustomizationSpec))) {
        if (-not $fp[1] -or $fp[1] -like 'TBD-*') { throw "Fixed parameter $($fp[0]) is not configured for site $Site ('$($fp[1])'). Update the catalog item." }
    }
    if ($InstallSql) {
        if (-not $SqlInstallerPath -or $SqlInstallerPath -like 'TBD-*') { throw "Fixed parameter SqlInstallerPath is not configured for site $Site ('$SqlInstallerPath'). Update the catalog item or set InstallSql = false." }
        if (-not $SysAdminGroup) { throw 'SysAdminGroup is required when InstallSql is true.' }
    }

    $sizes = @{ Small = @(2, 4); Medium = @(4, 8); Large = @(8, 16) }
    $cpu = $sizes[$Size][0]; $mem = $sizes[$Size][1]
    $dbMem = $mem * 2

    $tierCluster = [string](Get-MapValue $defaults.workloadClusters $Workload)
    $dbCluster   = [string](Get-MapValue $defaults.workloadClusters 'DB')
    if (-not $tierCluster) { throw "No cluster mapped for workload '$Workload' at site $Site." }
    if (-not $dbCluster)   { throw "No DB workload cluster mapped at site $Site." }
    Write-JobLog "WEB/APP -> $tierCluster; DB -> $dbCluster; size $Size ($cpu vCPU / $mem GB, DB $dbMem GB)."

    foreach ($n in $names.Values) { if (Get-VM -Name $n -Server $vi -ErrorAction SilentlyContinue) { throw "A VM named '$n' already exists in $($vi.Name)." } }

    foreach ($c in @($tierCluster, $dbCluster) | Select-Object -Unique) {
        $cl = Get-Cluster -Name $c -Server $vi
        $hosts = @(Get-VMHost -Location $cl -Server $vi | Where-Object { [string]$_.ConnectionState -eq 'Connected' })
        if (-not $hosts.Count) { throw "Cluster $c has no connected hosts." }
        $missing = @($hosts | Where-Object { @(Get-Datastore -VMHost $_ -Server $vi).Name -notcontains $Datastore })
        if ($missing.Count) {
            $role = if ($c -eq $dbCluster -and $c -ne $tierCluster) { 'the DB cluster' } else { 'the WEB/APP cluster' }
            throw "Datastore $Datastore is not visible on $role $c (missing on: $(@($missing.Name) -join ', ')). Choose a datastore shared by $tierCluster and $dbCluster."
        }
    }

    # Sub-handler files.
    $needed = @('New-VsphereVM.ps1', 'New-VsphereDrsRule.ps1', 'Install-GuestAgentBaseline.ps1', 'Set-PortalBackupPolicy.ps1')
    if ($InstallSql) { $needed += 'Install-GuestSqlServer.ps1' }
    $absent = @($needed | Where-Object { -not (Test-Path -LiteralPath (Join-Path $handlerDir $_)) })
    if ($absent.Count) { throw "Blueprint sub-handler(s) missing in ${handlerDir}: $($absent -join ', ')." }

    # Plan: every sub-handler call with its parameters (known up front, so mandatory parameters are checked now).
    $tierLabel = @{ WEB = 'web'; APP = 'application'; DB = 'database' }
    $sqlDisks = @(($SqlDiskSizesGB -split '[,; ]+') | Where-Object { $_ } | ForEach-Object { [int]$_ })
    if ($InstallSql -and $sqlDisks.Count -ne 4) { throw "SqlDiskSizesGB must list 4 sizes (data, logs, backup, tempdb); got '$SqlDiskSizesGB'." }
    foreach ($t in 'WEB', 'APP', 'DB') {
        $isDb = $t -eq 'DB'
        $plan.Add(@{ Kind = 'vm'; Tier = $t; Step = "Create $t VM"; Target = $names[$t]; Handler = 'New-VsphereVM.ps1'; Params = @{
            Site = $Site; VMName = $names[$t]; Description = "$AppCode $($tierLabel[$t]) tier - three-tier blueprint $($Context.RequestId)"
            Template = $Template; Workload = $(if ($isDb) { 'DB' } else { $Workload }); Cluster = $(if ($isDb) { $dbCluster } else { $tierCluster })
            Datastore = $Datastore; Folder = $Folder; CpuCount = $cpu; MemoryGB = $(if ($isDb) { $dbMem } else { $mem })
            AdditionalDiskGB = $(if ($isDb -and $InstallSql) { $sqlDisks[0] } else { 0 }); PortGroup = $PortGroup; IpMode = 'Static'
            IPAddress = $ips[$t]; SubnetMask = $SubnetMask; Gateway = $Gateway; DnsServers = $DnsServers
            Owner = $Owner; CostCenter = $CostCenter; ChangeTicket = $ChangeTicket; PowerOn = $true
            GuestFamily = 'Windows'; CustomizationSpec = $CustomizationSpec; Context = $Context } })
    }
    if ($InstallSql) { $plan.Add(@{ Kind = 'disks'; Step = 'Add SQL disks (logs, backup, tempdb)'; Target = $names.DB; Sizes = @($sqlDisks | Select-Object -Skip 1) }) }
    # Anti-affinity WEB <-> APP only when both land in the same cluster (today always the Workload cluster).
    $webCl = $plan[0].Params.Cluster; $appCl = $plan[1].Params.Cluster
    if ($webCl -eq $appCl) {
        $plan.Add(@{ Kind = 'drs'; Step = 'DRS anti-affinity WEB/APP'; Target = "$AppCode-WEB-APP-separate"; Handler = 'New-VsphereDrsRule.ps1'; Cluster = $webCl; Params = @{
            Site = $Site; Cluster = $webCl; RuleType = 'VmAntiAffinity'; RuleName = "$AppCode-WEB-APP-separate"; VMNames = "$($names.WEB),$($names.APP)"
            ChangeTicket = $ChangeTicket; Context = $Context } })
    }
    else { Write-JobLog "WEB ($webCl) and APP ($appCl) run in different clusters: anti-affinity rule skipped." }
    if ($BaselineSet) {
        foreach ($t in 'WEB', 'APP', 'DB') {
            $plan.Add(@{ Kind = 'call'; Step = "Software baseline $t"; Target = $names[$t]; Handler = 'Install-GuestAgentBaseline.ps1'; Params = @{
                Site = $Site; VMName = $names[$t]; BaselineSet = $BaselineSet; GuestCredential = $GuestCredential; Context = $Context } })
        }
    }
    if ($BackupPolicy) {
        $plan.Add(@{ Kind = 'call'; Step = 'Backup policy'; Target = ($names.Values -join ','); Handler = 'Set-PortalBackupPolicy.ps1'; Params = @{
            Site = $Site; VMName = ($names.Values -join ','); Policy = $BackupPolicy; ChangeTicket = $ChangeTicket; Context = $Context } })
    }
    if ($InstallSql) {
        $plan.Add(@{ Kind = 'call'; Step = 'Install SQL Server'; Target = $names.DB; Handler = 'Install-GuestSqlServer.ps1'; Params = @{
            Site = $Site; VMName = $names.DB; GuestCredential = $GuestCredential; InstanceName = 'MSSQLSERVER'; SysAdminGroup = $SysAdminGroup
            InstallerPath = $SqlInstallerPath; PrepareDisks = $true; Context = $Context } })
    }
    foreach ($s in @($plan | Where-Object { $_.Handler })) {
        $s.Path = Join-Path $handlerDir $s.Handler
        $r = Get-SubHandlerParameters -Path $s.Path -Wanted $s.Params
        if ($r.MissingMandatory.Count) { throw "Sub-handler $($s.Handler) needs parameter(s) the blueprint does not supply: $($r.MissingMandatory -join ', ')." }
        if ($r.Dropped.Count) { Write-JobLog "$($s.Handler) does not declare: $($r.Dropped -join ', ') (not passed)." }
        $s.Bound = $r.Params
    }
    $null = Add-Step -Step 'Pre-checks' -Target $AppCode -Status 'OK' -Detail "$($plan.Count) step(s) planned"
    Write-JobLog -Level OK "Pre-checks passed: $($plan.Count) step(s) planned."
    #endregion

    #region 2. Execute -----------------------------------------------------------------------------------------
    foreach ($s in $plan) {
        Write-JobLog -Level STEP "$($s.Step) - $($s.Target)"
        $row = Add-Step -Step $s.Step -Target $s.Target -Status 'RUNNING' -Detail ''
        try {
            switch ($s.Kind) {
                'disks' {
                    $v = Get-VM -Name $s.Target -Server $vi
                    foreach ($gb in $s.Sizes) { $null = New-HardDisk -VM $v -CapacityGB $gb -StorageFormat Thin -Confirm:$false }
                    $row.Detail = "$(@($s.Sizes) -join ' / ') GB thin"
                }
                default {
                    $bound = $s.Bound
                    $out = @(& $s.Path @bound) | Where-Object { $_ -is [System.Collections.IDictionary] } | Select-Object -Last 1
                    if ($s.Kind -eq 'vm') {
                        $createdVMs.Add($s.Target)
                        $vmRows.Add([ordered]@{ Tier = $s.Tier; VM = $s.Target; Cluster = $s.Params.Cluster; IPAddress = $s.Params.IPAddress; vCPU = $s.Params.CpuCount; MemoryGB = $s.Params.MemoryGB; Status = 'OK' })
                        $row.Detail = "$($s.Params.Cluster) / $($s.Params.IPAddress)"
                    }
                    elseif ($s.Kind -eq 'drs') { $createdRule = @{ Cluster = $s.Cluster; Name = $s.Target }; $row.Detail = $s.Cluster }
                    elseif ($out -and $out.Contains('NextSteps')) { $row.Detail = (@($out.NextSteps) | Select-Object -First 1) }
                }
            }
            $row.Status = 'OK'
            Write-JobLog -Level OK "$($s.Step) done."
        }
        catch {
            $row.Status = 'FAIL'; $row.Detail = $_.Exception.Message
            throw "Step '$($s.Step)' ($($s.Target)) failed: $($_.Exception.Message)"
        }
    }
    #endregion

    $report = Write-BlueprintReport -Outcome 'Succeeded'
    return [ordered]@{
        AppCode   = $AppCode
        Site      = $Site
        VMs       = @($names.Values)
        IPs       = @($names.Keys | ForEach-Object { "$($names[$_])=$($ips[$_])" })
        Clusters  = @("WEB/APP=$tierCluster", "DB=$dbCluster")
        Size      = $Size
        Steps     = @($steps | ForEach-Object { "$($_.Step) [$($_.Target)]: $($_.Status)" })
        Report    = $report
        NextSteps = @(
            'Register the DNS A/PTR records of the three VMs through your DNS change process and record the IPs in IPAM.',
            'Hand over the application tiers to the application team; firewall rules between tiers follow the network change process.'
        )
    }
}
catch {
    $err = $_
    if ($Context.RollbackOnFailure -and ($createdVMs.Count -or $createdRule)) {
        Write-JobLog -Level WARN "Rolling back the blueprint: $($createdVMs.Count) VM(s)$(if ($createdRule) { ' + DRS rule' })."
        Remove-BlueprintArtifacts
        foreach ($r in $vmRows) { $r.Status = 'ROLLED BACK' }
    }
    if ($steps.Count) { $null = Write-BlueprintReport -Outcome 'Failed' }
    throw $err
}
