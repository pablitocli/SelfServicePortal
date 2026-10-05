#Requires -Version 7.2
<#
.SYNOPSIS
    Offline tests for the Reports group: report-vsphere-health, report-version-compliance, report-hardening,
    report-certificates, report-capacity-forecast. PowerCLI calls are stubbed; Get-View returns fake views.
#>
. (Join-Path $PSScriptRoot '_TestHelpers.ps1')
Start-TestGroup 'Reports'

$now = Get-Date
function New-Fake { param([hashtable] $P) [pscustomobject]$P }
function Get-ReportCsv { param($Context, [string] $Pattern) $f = Get-ChildItem $Context.ReportDir -Filter $Pattern | Select-Object -First 1; if ($f) { @(Import-Csv $f.FullName) } else { @() } }

# ---------------------------------------------------------------------------------------------------------------
# PowerCLI stubs
# ---------------------------------------------------------------------------------------------------------------
$global:RptViews = @{}
$global:RptById = @{}
function global:Get-View {
    param($ViewType, $Id, $Property, $Server, $Filter, $VIObject)
    if ($ViewType) { return @($global:RptViews[[string]$ViewType]) }
    foreach ($i in @($Id)) { $global:RptById[[string]$i] }
}
function global:Get-VM { param($Name, $Id, $Server, $Location) [pscustomobject]@{ Name = $Name; Id = $Id } }
function global:Get-Snapshot { param($VM, $Server, $Name) @($global:RptSnapshots | Where-Object { $_.VMId -eq $VM.Id }) }
function global:Get-Cluster { param($Name, $Server) [pscustomobject]@{ Name = $Name } }
function global:Get-VMHost { param($Name, $Location, $Server) @($global:RptHosts | Where-Object { -not $Location -or $_.Cluster -eq $Location.Name }) }
function global:Get-AdvancedSetting {
    param($Entity, $Name, $Server)
    $set = $global:RptAdv[$Entity.Name]; if (-not $set) { return }
    foreach ($k in $set.Keys) { if (-not $Name -or @($Name) -contains $k) { [pscustomobject]@{ Name = $k; Value = $set[$k] } } }
}
function global:Get-VMHostService { param($VMHost, $Server) @($global:RptServices[$VMHost.Name]) }
function global:Get-VMHostNtpServer { param($VMHost, $Server) @('ntp1.test.local') }
$stubs = 'Get-View', 'Get-VM', 'Get-Snapshot', 'Get-Cluster', 'Get-VMHost', 'Get-AdvancedSetting', 'Get-VMHostService', 'Get-VMHostNtpServer', 'Get-PortalTlsCertificate'

# Shared inventory views
$global:RptViews['ClusterComputeResource'] = @(
    New-Fake @{ MoRef = 'ClusterComputeResource-domain-c1'; Name = 'CL-APP-01'; Summary = @{ CurrentEVCModeKey = 'intel-broadwell' }
                ConfigurationEx = @{ DasConfig = @{ Enabled = $true; AdmissionControlEnabled = $true }; DrsConfig = @{ Enabled = $true; DefaultVmBehavior = 'fullyAutomated' } } }
    New-Fake @{ MoRef = 'ClusterComputeResource-domain-c2'; Name = 'CL-DB-01'; Summary = @{ CurrentEVCModeKey = $null }
                ConfigurationEx = @{ DasConfig = @{ Enabled = $false; AdmissionControlEnabled = $false }; DrsConfig = @{ Enabled = $true; DefaultVmBehavior = 'manual' } } }
)
$global:RptViews['HostSystem'] = @(
    New-Fake @{ MoRef = 'HostSystem-host-1'; Name = 'esx01.test.local'; Parent = 'ClusterComputeResource-domain-c1'
                Runtime = @{ ConnectionState = 'connected'; InMaintenanceMode = $false; BootTime = $now.AddDays(-40) }; Config = @{ Product = @{ Version = '8.0.3'; Build = '24585383' } } }
    New-Fake @{ MoRef = 'HostSystem-host-2'; Name = 'esx02.test.local'; Parent = 'ClusterComputeResource-domain-c1'
                Runtime = @{ ConnectionState = 'connected'; InMaintenanceMode = $true; BootTime = $now.AddDays(-3) }; Config = @{ Product = @{ Version = '8.0.3'; Build = '24280767' } } }
    New-Fake @{ MoRef = 'HostSystem-host-3'; Name = 'esx03.test.local'; Parent = 'ClusterComputeResource-domain-c2'
                Runtime = @{ ConnectionState = 'notResponding'; InMaintenanceMode = $false; BootTime = $null }; Config = $null }
)
$gb = 1GB
$global:RptViews['Datastore'] = @(
    New-Fake @{ MoRef = 'Datastore-ds-1'; Name = 'DS-OK';   Browser = 'HostDatastoreBrowser-b1'; Summary = @{ Capacity = 1000 * $gb; FreeSpace = 500 * $gb; Type = 'VMFS'; Accessible = $true } }
    New-Fake @{ MoRef = 'Datastore-ds-2'; Name = 'DS-WARN'; Browser = 'HostDatastoreBrowser-b1'; Summary = @{ Capacity = 1000 * $gb; FreeSpace = 200 * $gb; Type = 'VMFS'; Accessible = $true } }
    New-Fake @{ MoRef = 'Datastore-ds-3'; Name = 'DS-FAIL'; Browser = 'HostDatastoreBrowser-b1'; Summary = @{ Capacity = 1000 * $gb; FreeSpace = 100 * $gb; Type = 'NFS'; Accessible = $true } }
)
$oldSnapTime = $now.AddDays(-10); $newSnapTime = $now.AddDays(-1)
$global:RptViews['VirtualMachine'] = @(
    New-Fake @{ MoRef = 'VirtualMachine-vm-1'; Name = 'app01'; Config = @{ Template = $false; Version = 'vmx-19'; ExtraConfig = @() }; Runtime = @{ PowerState = 'poweredOn'; Host = 'HostSystem-host-1' }
                Guest = @{ ToolsVersionStatus2 = 'guestToolsCurrent'; ToolsRunningStatus = 'guestToolsRunning'; ToolsVersion = '12352' }
                Snapshot = @{ RootSnapshotList = @(@{ Name = 'pre-patch'; CreateTime = $oldSnapTime; ChildSnapshotList = @(@{ Name = 'recent'; CreateTime = $newSnapTime; ChildSnapshotList = @() }) }) }
                LayoutEx = @{ File = @(@{ Name = '[DS-OK] app01/app01.vmdk'; Type = 'diskDescriptor' }, @{ Name = '[DS-OK] app01/app01-flat.vmdk'; Type = 'diskExtent' }) } }
    New-Fake @{ MoRef = 'VirtualMachine-vm-2'; Name = '<script>x</script>'; Config = @{ Template = $false; Version = 'vmx-14'; ExtraConfig = @(@{ Key = 'RemoteDisplay.maxConnections'; Value = '1' }, @{ Key = 'isolation.tools.copy.disable'; Value = 'FALSE' }) }
                Runtime = @{ PowerState = 'poweredOn'; Host = 'HostSystem-host-3' }; Guest = @{ ToolsVersionStatus2 = 'guestToolsNotInstalled'; ToolsRunningStatus = 'guestToolsNotRunning'; ToolsVersion = '0' }
                Snapshot = $null; LayoutEx = @{ File = @() } }
    New-Fake @{ MoRef = 'VirtualMachine-vm-3'; Name = 'db01'; Config = @{ Template = $false; Version = 'vmx-19'; ExtraConfig = @() }; Runtime = @{ PowerState = 'poweredOn'; Host = 'HostSystem-host-2' }
                Guest = @{ ToolsVersionStatus2 = 'guestToolsNeedUpgrade'; ToolsRunningStatus = 'guestToolsNotRunning'; ToolsVersion = '11365' }; Snapshot = $null; LayoutEx = @{ File = @() } }
    New-Fake @{ MoRef = 'VirtualMachine-vm-4'; Name = 'tpl01'; Config = @{ Template = $true; Version = 'vmx-19'; ExtraConfig = @() }; Runtime = @{ PowerState = 'poweredOff'; Host = 'HostSystem-host-1' }
                Guest = @{ ToolsVersionStatus2 = 'guestToolsNotInstalled'; ToolsRunningStatus = 'guestToolsNotRunning' }
                Snapshot = $null; LayoutEx = @{ File = @(@{ Name = '[DS-OK] tpl01/tpl01.vmdk'; Type = 'diskDescriptor' }) } }
)
$global:RptSnapshots = @(
    New-Fake @{ VMId = 'VirtualMachine-vm-1'; Name = 'pre-patch'; Created = $oldSnapTime; SizeGB = 12.5 }
    New-Fake @{ VMId = 'VirtualMachine-vm-1'; Name = 'recent'; Created = $newSnapTime; SizeGB = 1 }
)
$global:RptById['ServiceInstance'] = New-Fake @{ Content = @{ RootFolder = 'Folder-group-d1'; About = @{ Build = '24022515'; Version = '8.0.3' } } }
$global:RptById['Folder-group-d1'] = New-Fake @{ MoRef = 'Folder-group-d1'; TriggeredAlarmState = @(
    New-Fake @{ Entity = 'HostSystem-host-3'; Alarm = 'Alarm-alarm-1'; OverallStatus = 'red'; Time = $now.AddHours(-2); Acknowledged = $false }) }
$global:RptById['HostSystem-host-3'] = New-Fake @{ MoRef = 'HostSystem-host-3'; Name = 'esx03.test.local' }
$global:RptById['Alarm-alarm-1'] = New-Fake @{ MoRef = 'Alarm-alarm-1'; Info = @{ Name = 'Host connection and power state' } }
$browser = New-Fake @{ MoRef = 'HostDatastoreBrowser-b1' }
$browser | Add-Member -MemberType ScriptMethod -Name SearchDatastoreSubFolders -Value {
    param($Path, $Spec)
    $global:RptBrowserCalls.Add($Path)
    if ($Path -ne '[DS-OK]') { return @() }
    @(
        [pscustomobject]@{ FolderPath = '[DS-OK] app01/'; File = @(
            [pscustomobject]@{ Path = 'app01.vmdk'; FileSize = 1KB; Modification = $now }
            [pscustomobject]@{ Path = 'app01-flat.vmdk'; FileSize = 40GB; Modification = $now }
            [pscustomobject]@{ Path = 'app01-ctk.vmdk'; FileSize = 1MB; Modification = $now }
            [pscustomobject]@{ Path = 'old-disk.vmdk'; FileSize = 2KB; Modification = $now.AddDays(-200) }) }
        [pscustomobject]@{ FolderPath = '[DS-OK] tpl01'; File = @([pscustomobject]@{ Path = 'tpl01.vmdk'; FileSize = 1KB; Modification = $now }) }
    )
}
$global:RptById['HostDatastoreBrowser-b1'] = $browser
$global:RptBrowserCalls = [System.Collections.Generic.List[string]]::new()

# ---------------------------------------------------------------------------------------------------------------
# 13. report-vsphere-health
# ---------------------------------------------------------------------------------------------------------------
$ctx = New-TestContext -ItemId 'report-vsphere-health'
$r = Invoke-TestHandler -Handler 'Get-VsphereHealthReport.ps1' -Parameters @{ Site = 'DC1'; SnapshotAgeDays = 7; IncludeOrphanedVmdk = $true; Context = $ctx }
$files = Get-TestReportFiles -Context $ctx
Assert-Test -Name 'Health: ran' -Condition ($null -eq $r.Error) -Detail $r.Error
Assert-Test -Name 'Health: html + csv files' -Condition ($files -contains 'vsphere-health.html' -and @($files -like '*.csv').Count -eq 7 -and $r.Result.Report -eq 'vsphere-health.html') -Detail ($files -join ', ')
$ds = Get-ReportCsv $ctx 'vsphere-health-04-*.csv'
Assert-Test -Name 'Health: datastore below site minimum = FAIL' -Condition (($ds | Where-Object Datastore -eq 'DS-FAIL').Status -eq 'FAIL')
Assert-Test -Name 'Health: datastore below minimum+10 = WARN, healthy = OK' -Condition (($ds | Where-Object Datastore -eq 'DS-WARN').Status -eq 'WARN' -and ($ds | Where-Object Datastore -eq 'DS-OK').Status -eq 'OK')
$hs = Get-ReportCsv $ctx 'vsphere-health-01-*.csv'
Assert-Test -Name 'Health: host statuses (connected OK, maintenance WARN, notResponding FAIL)' -Condition (
    ($hs | Where-Object Host -eq 'esx01.test.local').Status -eq 'OK' -and ($hs | Where-Object Host -eq 'esx02.test.local').Status -eq 'WARN' -and
    ($hs | Where-Object Host -eq 'esx03.test.local').Status -eq 'FAIL' -and ($hs | Where-Object Host -eq 'esx01.test.local').UptimeDays -eq '40' -and
    ($hs | Where-Object Host -eq 'esx01.test.local').Cluster -eq 'CL-APP-01')
$cs = Get-ReportCsv $ctx 'vsphere-health-03-*.csv'
Assert-Test -Name 'Health: cluster with HA off = WARN' -Condition (($cs | Where-Object Cluster -eq 'CL-DB-01').Status -eq 'WARN' -and ($cs | Where-Object Cluster -eq 'CL-APP-01').Status -eq 'OK')
$al = Get-ReportCsv $ctx 'vsphere-health-02-*.csv'
Assert-Test -Name 'Health: triggered alarm resolved to names' -Condition ($al.Count -eq 1 -and $al[0].Entity -eq 'esx03.test.local' -and $al[0].Alarm -eq 'Host connection and power state' -and $al[0].Status -eq 'CRITICAL')
$sn = Get-ReportCsv $ctx 'vsphere-health-05-*.csv'
Assert-Test -Name 'Health: only the snapshot older than N days, with size' -Condition ($sn.Count -eq 1 -and $sn[0].Snapshot -eq 'pre-patch' -and $sn[0].SizeGB -eq '12.5' -and $sn[0].AgeDays -eq '10') -Detail ($sn | ConvertTo-Json -Compress)
$tl = Get-ReportCsv $ctx 'vsphere-health-06-*.csv'
Assert-Test -Name 'Health: tools issues (notInstalled FAIL, old+notRunning WARN, template skipped)' -Condition (
    $tl.Count -eq 2 -and ($tl | Where-Object VM -eq '<script>x</script>').Status -eq 'FAIL' -and ($tl | Where-Object VM -eq 'db01').Issue -eq 'toolsOld, notRunning')
$or = Get-ReportCsv $ctx 'vsphere-health-07-*.csv'
Assert-Test -Name 'Health: orphaned VMDK found, attached / flat / ctk / template disks excluded' -Condition ($or.Count -eq 1 -and $or[0].Path -eq '[DS-OK] app01/old-disk.vmdk') -Detail (($or | ForEach-Object Path) -join ', ')
Assert-Test -Name 'Health: summary counts' -Condition ($r.Result.Hosts -eq 3 -and $r.Result.TriggeredAlarms -eq 1 -and $r.Result.DatastoresBelowThreshold -eq 2 -and $r.Result.OldSnapshots -eq 1 -and $r.Result.ToolsIssues -eq 2 -and $r.Result.OrphanedVmdks -eq 1)
$html = Get-Content -Raw (Join-Path $ctx.ReportDir 'vsphere-health.html')
Assert-Test -Name 'Health: HTML escapes a malicious VM name' -Condition ($html -notmatch '<script>x</script>' -and $html -match '&lt;script&gt;x&lt;/script&gt;')

$global:RptBrowserCalls.Clear()
$ctx = New-TestContext -ItemId 'report-vsphere-health'
$r = Invoke-TestHandler -Handler 'Get-VsphereHealthReport.ps1' -Parameters @{ Site = 'DC1'; Context = $ctx }
Assert-Test -Name 'Health: orphan search skipped by default (no browser calls, 6 CSV)' -Condition ($null -eq $r.Error -and $global:RptBrowserCalls.Count -eq 0 -and @(Get-TestReportFiles -Context $ctx | Where-Object { $_ -like '*.csv' }).Count -eq 6 -and -not $r.Result.Contains('OrphanedVmdks')) -Detail $r.Error

$ctx = New-TestContext -ItemId 'report-vsphere-health'; $ctx.VIServer = $null
$r = Invoke-TestHandler -Handler 'Get-VsphereHealthReport.ps1' -Parameters @{ Site = 'DC1'; Context = $ctx }
Assert-Test -Name 'Health: fails without a vCenter session' -Condition ($r.Error -match 'No vCenter session') -Detail $r.Error

# ---------------------------------------------------------------------------------------------------------------
# 14. report-version-compliance
# ---------------------------------------------------------------------------------------------------------------
$vbPath = Join-Path $global:SspHandlerTestRoot 'config/version-baseline.json'
$vbOriginal = Get-Content -Raw $vbPath
[ordered]@{
    targets    = [ordered]@{ vcenter = @{ minBuild = 24022515 }; esxi = @{ minBuild = 24000000 }; vmTools = @{ minVersion = 12352 }; vmHardware = @{ minVersion = 'vmx-19' } }
    advisories = @(@{ id = 'VMSA-2026-0001'; product = 'esxi'; fixedBuild = 24500000; title = 'Test advisory' }, @{ id = 'VMSA-2026-0002'; product = 'vcenter'; fixedBuild = 24000000 })
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $vbPath
$ctx = New-TestContext -ItemId 'report-version-compliance'
$r = Invoke-TestHandler -Handler 'Get-VsphereVersionCompliance.ps1' -Parameters @{ Site = 'DC1'; Context = $ctx }
$files = Get-TestReportFiles -Context $ctx
Assert-Test -Name 'Version: html + csv files' -Condition ($null -eq $r.Error -and $files -contains 'version-compliance.html' -and @($files -like '*.csv').Count -eq 5) -Detail "$($r.Error) $($files -join ', ')"
Assert-Test -Name 'Version: vCenter at target = COMPLIANT' -Condition ($r.Result.VCenter -eq 'COMPLIANT')
$eh = Get-ReportCsv $ctx 'version-compliance-02-*.csv'
Assert-Test -Name 'Version: ESXi build below advisory fixedBuild = NON-COMPLIANT with advisory id' -Condition (
    ($eh | Where-Object Host -eq 'esx02.test.local').Compliance -eq 'NON-COMPLIANT' -and ($eh | Where-Object Host -eq 'esx02.test.local').Advisories -eq 'VMSA-2026-0001')
Assert-Test -Name 'Version: ESXi above target and advisory = COMPLIANT; unknown build = NON-COMPLIANT' -Condition (
    ($eh | Where-Object Host -eq 'esx01.test.local').Compliance -eq 'COMPLIANT' -and ($eh | Where-Object Host -eq 'esx03.test.local').Compliance -eq 'NON-COMPLIANT')
$av = Get-ReportCsv $ctx 'version-compliance-03-*.csv'
Assert-Test -Name 'Version: advisory findings list affected entities only' -Condition ($r.Result.AdvisoryFindings -eq 2 -and @($av | Where-Object Advisory -eq 'VMSA-2026-0001').Entity -contains 'esx02.test.local' -and -not ($av | Where-Object Advisory -eq 'VMSA-2026-0002'))
$vt = Get-ReportCsv $ctx 'version-compliance-04-*.csv'; $hw = Get-ReportCsv $ctx 'version-compliance-05-*.csv'
Assert-Test -Name 'Version: tools and hardware compared numerically (vmx-14 < vmx-19)' -Condition (
    ($vt | Where-Object VM -eq 'app01').Compliance -eq 'COMPLIANT' -and ($vt | Where-Object VM -eq 'db01').Compliance -eq 'NON-COMPLIANT' -and
    ($hw | Where-Object VM -eq '<script>x</script>').Compliance -eq 'NON-COMPLIANT' -and ($hw | Where-Object VM -eq 'app01').Compliance -eq 'COMPLIANT' -and
    -not ($vt | Where-Object VM -eq 'tpl01'))
Set-Content -LiteralPath $vbPath -Value $vbOriginal
$ctx = New-TestContext -ItemId 'report-version-compliance'
$r = Invoke-TestHandler -Handler 'Get-VsphereVersionCompliance.ps1' -Parameters @{ Site = 'DC1'; Context = $ctx }
$vt = Get-ReportCsv $ctx 'version-compliance-04-*.csv'
Assert-Test -Name 'Version: empty targets = NOT SET' -Condition ($null -eq $r.Error -and $r.Result.VCenter -eq 'NOT SET' -and -not ($vt | Where-Object Compliance -ne 'NOT SET')) -Detail $r.Error
$ctx = New-TestContext -ItemId 'report-version-compliance'; $ctx.VIServer = $null
$r = Invoke-TestHandler -Handler 'Get-VsphereVersionCompliance.ps1' -Parameters @{ Site = 'DC1'; Context = $ctx }
Assert-Test -Name 'Version: fails without a vCenter session' -Condition ($r.Error -match 'No vCenter session') -Detail $r.Error

# ---------------------------------------------------------------------------------------------------------------
# 15. report-hardening
# ---------------------------------------------------------------------------------------------------------------
$global:RptHosts = @(
    New-Fake @{ Name = 'esx01.test.local'; Id = 'HostSystem-host-1'; ConnectionState = 'Connected'; Cluster = 'CL-APP-01' }
    New-Fake @{ Name = 'esx02.test.local'; Id = 'HostSystem-host-2'; ConnectionState = 'Maintenance'; Cluster = 'CL-APP-01' }
    New-Fake @{ Name = 'esx03.test.local'; Id = 'HostSystem-host-3'; ConnectionState = 'NotResponding'; Cluster = 'CL-DB-01' }
)
$goodSettings = @{
    'UserVars.ESXiShellInteractiveTimeOut' = 900; 'UserVars.ESXiShellTimeOut' = 600; 'UserVars.DcuiTimeOut' = 600; 'UserVars.HostClientSessionTimeout' = 900
    'Security.AccountLockFailures' = 5; 'Security.AccountUnlockTime' = 900; 'Security.PasswordHistory' = 5; 'Config.HostAgent.plugins.solo.enableMob' = $false
    'Mem.ShareForceSalting' = 2; 'Net.BlockGuestBPDU' = 1; 'UserVars.SuppressShellWarning' = 0; 'Syslog.global.logHost' = 'udp://syslog.test.local:514'
}
$bad = $goodSettings.Clone(); $bad['Security.AccountLockFailures'] = 10; $bad['Syslog.global.logHost'] = ''; $bad.Remove('Mem.ShareForceSalting')
$global:RptAdv = @{ 'esx01.test.local' = $bad; 'esx02.test.local' = $goodSettings }
$global:RptServices = @{
    'esx01.test.local' = @(@{ Key = 'TSM-SSH'; Running = $true; Policy = 'on' }, @{ Key = 'TSM'; Running = $false; Policy = 'off' }, @{ Key = 'ntpd'; Running = $true; Policy = 'on' }) | ForEach-Object { [pscustomobject]$_ }
    'esx02.test.local' = @(@{ Key = 'TSM-SSH'; Running = $false; Policy = 'off' }, @{ Key = 'TSM'; Running = $false; Policy = 'off' }, @{ Key = 'ntpd'; Running = $true; Policy = 'on' }) | ForEach-Object { [pscustomobject]$_ }
}
$ctx = New-TestContext -ItemId 'report-hardening'
$r = Invoke-TestHandler -Handler 'Get-VsphereHardeningReport.ps1' -Parameters @{ Site = 'DC1'; Cluster = 'CL-APP-01'; IncludeVms = $true; Context = $ctx }
$files = Get-TestReportFiles -Context $ctx
Assert-Test -Name 'Hardening: html + csv files' -Condition ($null -eq $r.Error -and $files -contains 'hardening-compliance.html' -and @($files -like '*.csv').Count -eq 3) -Detail "$($r.Error) $($files -join ', ')"
$ec = Get-ReportCsv $ctx 'hardening-compliance-02-*.csv'
$chk = { param($Rows, $Entity, $Check) ($Rows | Where-Object { $_.Entity -eq $Entity -and $_.Check -eq $Check }).Result }
Assert-Test -Name 'Hardening: range violated = FAIL, nonEmpty empty = FAIL' -Condition ((& $chk $ec 'esx01.test.local' 'esxi-account-lockout') -eq 'FAIL' -and (& $chk $ec 'esx01.test.local' 'esxi-remote-syslog') -eq 'FAIL')
Assert-Test -Name 'Hardening: absent ESXi setting without defaultCompliant = NOT SET' -Condition ((& $chk $ec 'esx01.test.local' 'esxi-tps-salting') -eq 'NOT SET')
Assert-Test -Name 'Hardening: boolean eq / ge / range pass' -Condition ((& $chk $ec 'esx01.test.local' 'esxi-mob-disabled') -eq 'PASS' -and (& $chk $ec 'esx02.test.local' 'esxi-account-unlock') -eq 'PASS' -and (& $chk $ec 'esx02.test.local' 'esxi-shell-timeout') -eq 'PASS')
Assert-Test -Name 'Hardening: SSH running = FAIL, stopped = PASS, NTP PASS' -Condition ((& $chk $ec 'esx01.test.local' 'service-TSM-SSH') -eq 'FAIL' -and (& $chk $ec 'esx02.test.local' 'service-TSM-SSH') -eq 'PASS' -and (& $chk $ec 'esx01.test.local' 'esxi-ntp') -eq 'PASS')
Assert-Test -Name 'Hardening: cluster scope excludes other clusters' -Condition (-not ($ec | Where-Object Entity -eq 'esx03.test.local') -and $r.Result.Hosts -eq 2)
$vc = Get-ReportCsv $ctx 'hardening-compliance-03-*.csv'
Assert-Test -Name 'Hardening: absent VM setting with defaultCompliant = PASS' -Condition ((& $chk $vc 'app01' 'vm-copy-disable') -eq 'PASS' -and ($vc | Where-Object { $_.Entity -eq 'app01' -and $_.Check -eq 'vm-copy-disable' }).Actual -eq '(absent)')
Assert-Test -Name 'Hardening: absent VM setting not defaultCompliant = NOT SET; explicit le passes' -Condition ((& $chk $vc 'app01' 'vm-remote-display') -eq 'NOT SET' -and (& $chk $vc 'db01' 'vm-remote-display') -eq 'NOT SET')
Assert-Test -Name 'Hardening: VMs outside the cluster are skipped' -Condition (-not ($vc | Where-Object Entity -eq '<script>x</script>') -and $r.Result.VMs -eq 2)
Assert-Test -Name 'Hardening: summary and compliance %' -Condition ($r.Result.Checks -eq ($r.Result.Pass + $r.Result.Fail + $r.Result.NotSet) -and $r.Result.CompliancePercent -eq [math]::Round($r.Result.Pass / $r.Result.Checks * 100, 1) -and $r.Result.NextSteps[0] -match 'separate item')
$ctx = New-TestContext -ItemId 'report-hardening'
$r = Invoke-TestHandler -Handler 'Get-VsphereHardeningReport.ps1' -Parameters @{ Site = 'DC1'; IncludeVms = $true; Context = $ctx }
$vc = Get-ReportCsv $ctx 'hardening-compliance-03-*.csv'; $ec = Get-ReportCsv $ctx 'hardening-compliance-02-*.csv'
Assert-Test -Name 'Hardening: all hosts when no cluster; explicit VM value FAIL; unreachable host FAIL' -Condition (
    $null -eq $r.Error -and (& $chk $vc '<script>x</script>' 'vm-copy-disable') -eq 'FAIL' -and (& $chk $vc '<script>x</script>' 'vm-remote-display') -eq 'PASS' -and
    (& $chk $ec 'esx03.test.local' 'host-reachable') -eq 'FAIL') -Detail $r.Error
$ctx = New-TestContext -ItemId 'report-hardening'
$r = Invoke-TestHandler -Handler 'Get-VsphereHardeningReport.ps1' -Parameters @{ Site = 'DC1'; Cluster = 'CL-OTHER'; Context = $ctx }
Assert-Test -Name 'Hardening: cluster outside allowedClusters rejected' -Condition ($r.Error -match 'not allowed') -Detail $r.Error

# ---------------------------------------------------------------------------------------------------------------
# 16. report-certificates (Get-PortalTlsCertificate stubbed BEFORE the handler runs)
# ---------------------------------------------------------------------------------------------------------------
$global:TlsCalls = [System.Collections.Generic.List[string]]::new()
function global:Get-PortalTlsCertificate {
    param([string] $HostName, [int] $Port, [int] $TimeoutMs)
    $global:TlsCalls.Add("${HostName}:$Port")
    $days = switch ($HostName) { 'vc-dc1.test.local' { 400 } 'esx01.test.local' { -5 } 'esx02.test.local' { 20 } 'esx03.test.local' { 45 } 'web01.test.local' { 200 } default { throw "No route to host $HostName" } }
    [pscustomobject]@{ Subject = "CN=$HostName"; Issuer = 'CN=VMCA'; NotAfter = (Get-Date).AddDays($days).AddHours(1); Thumbprint = ('AB' * 20) }
}
$ctx = New-TestContext -ItemId 'report-certificates'
$r = Invoke-TestHandler -Handler 'Get-VsphereCertificateReport.ps1' -Parameters @{ Site = 'DC1'; AdditionalEndpoints = "web01.test.local:8443`r`nbad.test.local`n`nesx01.test.local"; WarningDays = 60; Context = $ctx }
$files = Get-TestReportFiles -Context $ctx
Assert-Test -Name 'Certs: html + csv files' -Condition ($null -eq $r.Error -and $files -contains 'certificate-expiry.html' -and @($files -like '*.csv').Count -eq 1) -Detail "$($r.Error) $($files -join ', ')"
$ce = Get-ReportCsv $ctx 'certificate-expiry-01-*.csv'
$st = { param($e) ($ce | Where-Object Endpoint -eq $e).Status }
Assert-Test -Name 'Certs: expired = EXPIRED' -Condition ((& $st 'esx01.test.local:443') -eq 'EXPIRED')
Assert-Test -Name 'Certs: CRITICAL / EXPIRING / OK thresholds' -Condition ((& $st 'esx02.test.local:443') -eq 'CRITICAL' -and (& $st 'esx03.test.local:443') -eq 'EXPIRING' -and (& $st 'vc-dc1.test.local:443') -eq 'OK' -and (& $st 'web01.test.local:8443') -eq 'OK')
Assert-Test -Name 'Certs: unreachable = ERROR row, job still succeeds' -Condition ((& $st 'bad.test.local:443') -eq 'ERROR' -and ($ce | Where-Object Endpoint -eq 'bad.test.local:443').Detail -match 'No route')
Assert-Test -Name 'Certs: endpoints deduplicated, port honoured' -Condition ($global:TlsCalls.Count -eq 6 -and $global:TlsCalls -contains 'web01.test.local:8443' -and $r.Result.Endpoints -eq 6) -Detail ($global:TlsCalls -join ', ')
Assert-Test -Name 'Certs: summary + next steps mention notifications' -Condition ($r.Result.Expired -eq 1 -and $r.Result.Critical -eq 1 -and $r.Result.Expiring -eq 1 -and $r.Result.Unreachable -eq 1 -and ($r.Result.NextSteps -join ' ') -match 'notifications')
$ctx = New-TestContext -ItemId 'report-certificates'
$r = Invoke-TestHandler -Handler 'Get-VsphereCertificateReport.ps1' -Parameters @{ Site = 'DC1'; WarningDays = 10; Context = $ctx }
$ce = Get-ReportCsv $ctx 'certificate-expiry-01-*.csv'
Assert-Test -Name 'Certs: WarningDays below criticalDays keeps CRITICAL, 45 days becomes OK' -Condition ((& $st 'esx03.test.local:443') -eq 'OK' -and (& $st 'esx02.test.local:443') -eq 'CRITICAL')
$ctx = New-TestContext -ItemId 'report-certificates'
$r = Invoke-TestHandler -Handler 'Get-VsphereCertificateReport.ps1' -Parameters @{ Site = 'DC1'; AdditionalEndpoints = "ok.test.local`nhttp://evil.test/<x>"; Context = $ctx }
Assert-Test -Name 'Certs: invalid endpoint rejected' -Condition ($r.Error -match 'Invalid endpoint') -Detail $r.Error
$r = Invoke-TestHandler -Handler 'Get-VsphereCertificateReport.ps1' -Parameters @{ Site = 'DC1'; AdditionalEndpoints = ((1..51 | ForEach-Object { "h$_.test.local" }) -join "`n"); Context = $ctx }
Assert-Test -Name 'Certs: more than 50 endpoints rejected' -Condition ($r.Error -match 'maximum is 50') -Detail $r.Error
$r = Invoke-TestHandler -Handler 'Get-VsphereCertificateReport.ps1' -Parameters @{ Site = 'DC1'; AdditionalEndpoints = 'h1.test.local:70000'; Context = $ctx }
Assert-Test -Name 'Certs: invalid port rejected' -Condition ($r.Error -match 'Invalid port') -Detail $r.Error

# ---------------------------------------------------------------------------------------------------------------
# 17. report-capacity-forecast (synthetic history in the temp root)
# ---------------------------------------------------------------------------------------------------------------
$histDir = Join-Path (Get-PortalPath -Name Inventory) 'history'
$null = New-Item -ItemType Directory -Path $histDir -Force
$start = (Get-Date).ToUniversalTime().Date.AddDays(-29)
$lines = foreach ($d in 0..29) {
    [ordered]@{
        date       = $start.AddDays($d).ToString('yyyy-MM-dd')
        clusters   = @([ordered]@{ name = 'CL-APP-01'; hosts = 4; cpuGHz = 200; memoryGB = 1000; vms = 50 + $d; vcpu = 200 + 2 * $d; vmMemoryGB = 400 + 2 * $d })
        datastores = @(
            [ordered]@{ name = 'DS-GROW'; capacityGB = 1000; freeGB = 500 - 5 * $d }       # used 500 -> 645 GB, +5 GB/day
            [ordered]@{ name = 'DS-FULL'; capacityGB = 1000; freeGB = 100 }                # 90 % used
            [ordered]@{ name = 'DS-SHRINK'; capacityGB = 1000; freeGB = 600 + $d } )       # shrinking usage
    } | ConvertTo-Json -Depth 6 -Compress
}
Set-Content -LiteralPath (Join-Path $histDir 'DC1.jsonl') -Value $lines -Encoding utf8
$ctx = New-TestContext -ItemId 'report-capacity-forecast' -NoVCenter
$r = Invoke-TestHandler -Handler 'Get-VsphereCapacityForecast.ps1' -Parameters @{ Site = 'DC1'; ForecastDays = 90; ThresholdPercent = 85; Context = $ctx }
$files = Get-TestReportFiles -Context $ctx
Assert-Test -Name 'Forecast: html + csv files (no vCenter)' -Condition ($null -eq $r.Error -and $files -contains 'capacity-forecast.html' -and @($files -like '*.csv').Count -eq 3 -and $r.Result.Samples -eq 30) -Detail "$($r.Error) $($files -join ', ')"
$fd = Get-ReportCsv $ctx 'capacity-forecast-01-*.csv'
$grow = $fd | Where-Object Name -eq 'DS-GROW'
# expected: (850 - 645) / 5 = 41 days, projected (645 + 5 * 90) / 1000 = 109.5 %
Assert-Test -Name 'Forecast: linear growth -> days to threshold within +-1' -Condition ([math]::Abs([double]$grow.'Days to threshold' - 41) -le 1 -and [double]$grow.'Growth per day' -eq 5 -and $grow.Status -eq 'WARN') -Detail "days=$($grow.'Days to threshold') growth=$($grow.'Growth per day')"
Assert-Test -Name 'Forecast: projected % at horizon' -Condition ([math]::Abs([double]$grow.'Projected % at 90 days' - 109.5) -lt 0.2 -and [double]$grow.'Current %' -eq 64.5) -Detail ($grow | ConvertTo-Json -Compress)
Assert-Test -Name 'Forecast: above threshold = FAIL, not growing = "-" / OK' -Condition (($fd | Where-Object Name -eq 'DS-FULL').Status -eq 'FAIL' -and ($fd | Where-Object Name -eq 'DS-SHRINK').'Days to threshold' -eq '-' -and ($fd | Where-Object Name -eq 'DS-SHRINK').Status -eq 'OK')
$fm = Get-ReportCsv $ctx 'capacity-forecast-02-*.csv'
# memory: (850 - 458) / 2 = 196 days > 90 -> OK
Assert-Test -Name 'Forecast: cluster memory regression' -Condition ([math]::Abs([double]$fm[0].'Days to threshold' - 196) -le 1 -and $fm[0].Status -eq 'OK' -and [double]$fm[0].'Current %' -eq 45.8)
$fc = Get-ReportCsv $ctx 'capacity-forecast-03-*.csv'
Assert-Test -Name 'Forecast: vCPU growth' -Condition ([double]$fc[0].'Growth per day' -eq 2 -and [double]$fc[0].'Projected vCPU at 90 days' -eq 438)
Assert-Test -Name 'Forecast: summary' -Condition ($r.Result.DatastoresAtRisk -eq 2 -and $r.Result.ClustersAtRisk -eq 0 -and $r.Result.AboveThreshold -eq 1)

Set-Content -LiteralPath (Join-Path $histDir 'DC2.jsonl') -Value ($lines | Select-Object -First 3) -Encoding utf8
$ctx = New-TestContext -ItemId 'report-capacity-forecast' -NoVCenter
$r = Invoke-TestHandler -Handler 'Get-VsphereCapacityForecast.ps1' -Parameters @{ Site = 'DC2'; ForecastDays = 90; ThresholdPercent = 85; Context = $ctx }
Assert-Test -Name 'Forecast: not enough history -> succeeds with message' -Condition ($null -eq $r.Error -and $r.Result.Message -match 'Not enough history yet \(3 days\)' -and (Get-TestReportFiles -Context $ctx) -contains 'capacity-forecast.html') -Detail $r.Error
$ctx = New-TestContext -ItemId 'report-capacity-forecast' -NoVCenter
$r = Invoke-TestHandler -Handler 'Get-VsphereCapacityForecast.ps1' -Parameters @{ Site = 'DC9'; Context = $ctx }
Assert-Test -Name 'Forecast: no history file -> 0 days, defaults from operations' -Condition ($null -eq $r.Error -and $r.Result.Samples -eq 0 -and $global:JobLog -match 'Not enough history yet \(0 days\)') -Detail $r.Error
$r = Invoke-TestHandler -Handler 'Get-VsphereCapacityForecast.ps1' -Parameters @{ Site = '../etc'; Context = $ctx }
Assert-Test -Name 'Forecast: invalid site code rejected' -Condition ($r.Error -match 'Invalid site code') -Detail $r.Error

# Remove the stubs so other groups start clean.
$stubs | ForEach-Object { Remove-Item "function:global:$_" -ErrorAction SilentlyContinue }
Remove-Variable -Scope Global -Name RptViews, RptById, RptSnapshots, RptHosts, RptAdv, RptServices, RptBrowserCalls, TlsCalls -ErrorAction SilentlyContinue
