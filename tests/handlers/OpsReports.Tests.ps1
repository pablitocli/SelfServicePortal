#Requires -Version 7.2
<#
.SYNOPSIS
    Offline tests: report-drs-compliance, report-change-impact, report-orphaned-vmdk (PowerCLI stubs).
#>
. (Join-Path $PSScriptRoot '_TestHelpers.ps1')
Start-TestGroup 'Operational reports (DRS, change impact, orphaned disks)'

#region DRS rule compliance ---------------------------------------------------------------------------------------
$global:OrHosts = @(1..3 | ForEach-Object {
    [pscustomobject]@{ Name = "esx-db-0$_.test.local"; Id = "HostSystem-host-$_"; ConnectionState = 'Connected'; MemoryTotalGB = 1024; MemoryUsageGB = 700
                       ExtensionData = [pscustomobject]@{ Hardware = [pscustomobject]@{ CpuInfo = [pscustomobject]@{ NumCpuCores = 32 } } } } })
function New-OrVm([string] $Name, [int] $HostIdx, [int] $Mem = 512, [string] $Power = 'PoweredOn', [int] $Swap = 0) {
    [pscustomobject]@{ Name = $Name; Id = "VirtualMachine-$Name"; PowerState = $Power; NumCpu = 16; MemoryGB = $Mem; VMHost = $global:OrHosts[$HostIdx]
                       ExtensionData = [pscustomobject]@{ Summary = [pscustomobject]@{ QuickStats = [pscustomobject]@{ SwappedMemory = $Swap; BalloonedMemory = 0 } }
                                                         ResourceConfig = [pscustomobject]@{ MemoryAllocation = [pscustomobject]@{ Reservation = 0 } } } }
}
$global:OrVms = @(
    (New-OrVm 'SQL-PROD-01' 0), (New-OrVm 'SQL-PROD-02' 0),                 # share host 1 -> violation
    (New-OrVm 'SQL-RPT-01' 1 192), (New-OrVm 'SQL-RPT-02' 2 192),
    (New-OrVm 'APP-01' 1 16), (New-OrVm 'APP-02' 2 16 'PoweredOff'),
    (New-OrVm 'BIG-01' 1 600 'PoweredOn' 2048)                                # host 2: 600 + 192 + 16 > 1024 * ... and swap
)
$global:OrRules = @(
    [pscustomobject]@{ Name = 'AA-SQL-PROD'; Enabled = $true; KeepTogether = $false; VMIds = @('VirtualMachine-SQL-PROD-01', 'VirtualMachine-SQL-PROD-02') }
    [pscustomobject]@{ Name = 'AA-SQL-RPT'; Enabled = $true; KeepTogether = $false; VMIds = @('VirtualMachine-SQL-RPT-01', 'VirtualMachine-SQL-RPT-02') }
    [pscustomobject]@{ Name = 'KT-APP'; Enabled = $false; KeepTogether = $true; VMIds = @('VirtualMachine-APP-01', 'VirtualMachine-APP-02') }
)
function global:Get-Cluster { param($Name, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) if ($Name -and $Name -ne 'CL-OTHER' -and $Name -notlike '*NOPE*') { [pscustomobject]@{ Name = $Name; DrsAutomationLevel = 'FullyAutomated' } } }
function global:Get-VMHost { param($Location, $Name, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) $global:OrHosts }
function global:Get-VM { param($Name, $Location, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) if ($Name) { $global:OrVms | Where-Object Name -eq $Name } else { $global:OrVms } }
function global:Get-DrsRule { param($Cluster, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) $global:OrRules }
function global:Get-DrsRecommendation { param($Cluster, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) [pscustomobject]@{ Priority = 2; Reason = 'Fix anti-affinity rule violation'; Recommendation = 'Migrate SQL-PROD-02 to esx-db-03' } }

$drsPath = Join-Path $global:SspHandlerTestRoot 'config/drs-rules.json'
Write-PortalJson -Path $drsPath -Value ([ordered]@{ largeVmGB = 512; mediumVmGB = 192; vmNamePattern = '(?i)sql'
    clusters = @([ordered]@{ site = 'DC1'; cluster = 'CL-DB-01'; decommission = @('BIG-01', 'GONE-01')
        rules = @([ordered]@{ name = 'AA-SQL-PROD'; type = 'Separate'; vms = @('SQL-PROD-01', 'SQL-PROD-02') }, [ordered]@{ name = 'AA-SQL-MISSING'; type = 'Separate'; vms = @('SQL-RPT-01', 'SQL-X') }) }) })
$ctx = New-TestContext -ItemId 'report-drs-compliance'
$r = Invoke-TestHandler -Handler 'Get-VsphereDrsCompliance.ps1' -Parameters @{ Site = 'DC1'; Cluster = 'CL-DB-01'; Context = $ctx }
Assert-Test -Name 'DRS: 4 rules checked (2 expected + 2 found only in vCenter)' -Condition ($null -eq $r.Error -and $r.Result.Rules -eq 4) -Detail "$($r.Error) $($r.Result | ConvertTo-Json -Compress)"
Assert-Test -Name 'DRS: shared host and missing expected rule are violations' -Condition ($r.Result.Violations -eq 2 -and ($r.Result.NonCompliant -match 'AA-SQL-PROD: .*share esx-db-01') -and ($r.Result.NonCompliant -match 'AA-SQL-MISSING: Rule not found')) -Detail ($r.Result.NonCompliant -join ' | ')
Assert-Test -Name 'DRS: compliant rule counted, disabled rule only a warning' -Condition ($r.Result.Compliant -eq 1)
$csv = Get-ChildItem $ctx.ReportDir -Filter 'drs-compliance-02-host-allocation.csv' | Select-Object -First 1
$hosts = if ($csv) { @(Import-Csv $csv.FullName) } else { @() }
Assert-Test -Name 'DRS: host 2 flagged (two large VMs, swapping)' -Condition (($hosts | Where-Object { $_.Host -eq 'esx-db-02' }).Status -match 'WARN.*swapped 2') -Detail (($hosts | ConvertTo-Json -Compress))
$html = Get-Content -Raw (Join-Path $ctx.ReportDir 'drs-compliance.html')
Assert-Test -Name 'DRS: VM detail, recommendations and decommission sections' -Condition ($html -match 'VM detail' -and $html -match 'Migrate SQL-PROD-02' -and $html -match 'WARN still present' -and $html -match 'OK removed')
$r = Invoke-TestHandler -Handler 'Get-VsphereDrsCompliance.ps1' -Parameters @{ Site = 'DC1'; Cluster = 'CL-OTHER'; Context = (New-TestContext) }
Assert-Test -Name 'DRS: cluster outside allowedClusters refused' -Condition ($r.Error -match 'not allowed') -Detail $r.Error
$r = Invoke-TestHandler -Handler 'Get-VsphereDrsCompliance.ps1' -Parameters @{ Site = 'DC1'; Cluster = 'CL-DB-01'; VmNamePattern = '(['; Context = (New-TestContext) }
Assert-Test -Name 'DRS: invalid name pattern refused' -Condition ($r.Error -match 'not a valid regular expression') -Detail $r.Error
$e = @(Test-PortalDataFile -Name drsRules -Content ([ordered]@{ clusters = @([ordered]@{ site = 'DC1'; cluster = 'C'; rules = @([ordered]@{ name = 'R'; type = 'Apart'; vms = @('a') }) }) }))
Assert-Test -Name 'DRS: data file validation (type, at least two VMs)' -Condition ($e.Count -eq 2) -Detail ($e -join '; ')
#endregion

#region Change impact ---------------------------------------------------------------------------------------------
$global:OrChange = [DateTimeOffset]::UtcNow.AddDays(-3)
function global:Get-Stat {
    param($Entity, $Stat, $Start, $Finish, $IntervalMins, [switch] $Realtime, $Server, [Parameter(ValueFromRemainingArguments)] $Rest)
    if ($Stat -like 'net.errors*') { throw 'not collected at this statistics level' }
    $after = ([datetime]$Start).ToUniversalTime() -ge $global:OrChange.UtcDateTime.AddMinutes(-1)
    $v = switch ($Stat) {
        'datastore.totalReadLatency.average'  { if ($after) { 4 } else { 9 } }
        'datastore.totalWriteLatency.average' { if ($after) { 6 } else { 18 } }
        'disk.maxTotalLatency.latest'         { if ($after) { 12 } else { 40 } }
        'net.usage.average'                   { if ($after) { 310000 } else { 295000 } }
        'net.droppedRx.summation'             { if ($after) { 0 } else { 15 } }
        default                               { 0 }
    }
    for ($i = 0; $i -lt 10; $i++) { [pscustomobject]@{ Entity = $Entity; MetricId = $Stat; Value = $v + ($i % 2); Timestamp = ([datetime]$Start).AddMinutes(30 * $i); Instance = $(if ($Stat -like 'datastore.*') { 'ds-uuid' } else { '' }) } }
}
function global:Get-EsxCli {
    param($VMHost, [switch] $V2, $Server, [Parameter(ValueFromRemainingArguments)] $Rest)
    $np = [pscustomobject]@{}; $np | Add-Member ScriptMethod Invoke { @([pscustomobject]@{ Vmknic = 'vmk1'; MTU = 9000 }, [pscustomobject]@{ Vmknic = 'vmk2'; MTU = 9000 }) }
    $se = [pscustomobject]@{}; $se | Add-Member ScriptMethod Invoke { @(1..4 | ForEach-Object { [pscustomobject]@{ Session = $_ } }) }
    [pscustomobject]@{ iscsi = [pscustomobject]@{ networkportal = [pscustomobject]@{ list = $np }; session = [pscustomobject]@{ list = $se } } }
}
$ct = $global:OrChange.UtcDateTime.ToString('yyyy-MM-dd HH:mm')
$ctx = New-TestContext -ItemId 'report-change-impact'
$r = Invoke-TestHandler -Handler 'Get-VsphereChangeImpact.ps1' -Parameters @{ Site = 'DC1'; Cluster = 'CL-DB-01'; ChangeDescription = 'MTU 9000 iSCSI'; WindowMode = 'AroundChange'; ChangeTime = $ct; Hours = 24; IncludeIscsi = $true; Context = $ctx }
Assert-Test -Name 'Change: completed for 3 hosts' -Condition ($null -eq $r.Error -and $r.Result.Hosts -eq 3) -Detail $r.Error
Assert-Test -Name 'Change: latency and drops improved, nothing worse' -Condition ($r.Result.Improved -ge 5 -and $r.Result.Worse -eq 0) -Detail ($r.Result.KeyResults -join ' | ')
Assert-Test -Name 'Change: write latency avg 18.5 -> 6.5 reported' -Condition (@($r.Result.KeyResults | Where-Object { $_ -match 'Datastore write latency \(ms\) \(avg\): 18.5 -> 6.5 \(OK improved\)' }).Count -eq 1) -Detail ($r.Result.KeyResults -join ' | ')
$csv = Get-ChildItem $ctx.ReportDir -Filter 'change-impact-01-*.csv' | Select-Object -First 1
$cl = @(Import-Csv $csv.FullName)
Assert-Test -Name 'Change: counters not collected shown as n/a' -Condition (($cl | Where-Object { $_.Metric -like 'Packet errors rx*' }).Result -like 'n/a*')
Assert-Test -Name 'Change: iSCSI MTU listed' -Condition ((Get-Content -Raw (Join-Path $ctx.ReportDir 'change-impact.html')) -match 'vmk1=9000 vmk2=9000')
$r = Invoke-TestHandler -Handler 'Get-VsphereChangeImpact.ps1' -Parameters @{ Site = 'DC1'; Cluster = 'CL-DB-01'; ChangeDescription = 'x'; WindowMode = 'Explicit'; BeforeStart = '2026-10-10 00:00'; BeforeEnd = '2026-10-12 00:00'; AfterStart = '2026-10-11 00:00'; AfterEnd = '2026-10-13 00:00'; Context = (New-TestContext) }
Assert-Test -Name 'Change: overlapping windows refused' -Condition ($r.Error -match 'after window must start') -Detail $r.Error
$r = Invoke-TestHandler -Handler 'Get-VsphereChangeImpact.ps1' -Parameters @{ Site = 'DC1'; Cluster = 'CL-DB-01'; HostNames = 'esx-db-01, esx-zz-09'; ChangeDescription = 'x'; ChangeTime = $ct; Context = (New-TestContext) }
Assert-Test -Name 'Change: unknown host refused' -Condition ($r.Error -match 'esx-zz-09') -Detail $r.Error
$r = Invoke-TestHandler -Handler 'Get-VsphereChangeImpact.ps1' -Parameters @{ Site = 'DC1'; Cluster = 'CL-DB-01'; HostNames = 'esx-db-02'; ChangeDescription = 'x'; ChangeTime = $ct; IncludeIscsi = $false; Context = (New-TestContext) }
Assert-Test -Name 'Change: host filter by short name' -Condition ($null -eq $r.Error -and $r.Result.Hosts -eq 1) -Detail $r.Error
#endregion

#region Orphaned VMDK ---------------------------------------------------------------------------------------------
$old = (Get-Date).AddDays(-200); $new = (Get-Date).AddDays(-2)
function New-OrFile([string] $Path, [double] $GB = 0.001, [datetime] $Mod = $old) { [pscustomobject]@{ Path = $Path; FileSize = $GB * 1GB; Modification = $Mod } }
$global:OrBrowse = @{
    'browser-1' = @(
        [pscustomobject]@{ FolderPath = '[DS-A] vm1'; File = @((New-OrFile 'vm1.vmx'), (New-OrFile 'vm1.vmdk'), (New-OrFile 'vm1-flat.vmdk' 100), (New-OrFile 'vm1_1.vmdk'), (New-OrFile 'vm1_1-flat.vmdk' 500),
                                                            (New-OrFile 'vm1-000002.vmdk' 0.001 $new), (New-OrFile 'vm1-000002-delta.vmdk' 20 $new), (New-OrFile 'vm1_2-ctk.vmdk' 0.01)) }
        [pscustomobject]@{ FolderPath = '[DS-A] old'; File = @((New-OrFile 'old.vmx'), (New-OrFile 'old.vmdk'), (New-OrFile 'old-flat.vmdk' 80)) }
        [pscustomobject]@{ FolderPath = '[DS-A] contentlib-123/item'; File = @((New-OrFile 'img.vmdk'), (New-OrFile 'img-flat.vmdk' 40)) }
    )
    'browser-9' = @([pscustomobject]@{ FolderPath = '[SHARED] other'; File = @((New-OrFile 'other.vmdk'), (New-OrFile 'other-flat.vmdk' 60)) })
}
function New-OrDs([string] $Name, [string] $Url, [string] $Browser, [bool] $Ok = $true) {
    $b = [pscustomobject]@{ Id = $Browser }
    [pscustomobject]@{ Name = $Name; MoRef = [pscustomobject]@{ Value = "ds-$Name" }; Info = [pscustomobject]@{ Url = $Url }; Browser = $b
                       Summary = [pscustomobject]@{ Accessible = $Ok; Type = 'VMFS'; Capacity = 4TB } }
}
$global:OrViews = @{
    'vc-dc1.test.local' = @{
        Datastore = @((New-OrDs 'DS-A' 'ds:///vmfs/volumes/a/' 'browser-1'), (New-OrDs 'SHARED' 'ds:///vmfs/volumes/9/' 'browser-9'), (New-OrDs 'DS-DOWN' 'ds:///vmfs/volumes/x/' 'browser-x' $false))
        VirtualMachine = @([pscustomobject]@{ Name = 'vm1'; Datastore = @([pscustomobject]@{ Value = 'ds-DS-A' })
            LayoutEx = [pscustomobject]@{ File = @([pscustomobject]@{ Name = '[DS-A] vm1/vm1.vmx' }, [pscustomobject]@{ Name = '[DS-A] vm1/vm1.vmdk' }, [pscustomobject]@{ Name = '[DS-A] vm1/vm1-flat.vmdk' }) }
            Config = [pscustomobject]@{ Files = [pscustomobject]@{ VmPathName = '[DS-A] vm1/vm1.vmx' } } })
    }
    'vc-dc2.test.local' = @{
        Datastore = @((New-OrDs 'SHARED' 'ds:///vmfs/volumes/9/' 'browser-9'))
        VirtualMachine = @([pscustomobject]@{ Name = 'other'; Datastore = @([pscustomobject]@{ Value = 'ds-SHARED' })
            LayoutEx = [pscustomobject]@{ File = @([pscustomobject]@{ Name = '[SHARED] other/other.vmdk' }) }; Config = [pscustomobject]@{ Files = [pscustomobject]@{ VmPathName = '[SHARED] other/other.vmx' } } })
    }
}
function global:Get-View {
    param($ViewType, $Property, $Id, $Server, [Parameter(ValueFromRemainingArguments)] $Rest)
    if ($Id) {
        $o = [pscustomobject]@{ Key = $Id.Id }
        $o | Add-Member ScriptMethod SearchDatastoreSubFolders { param($Path, $Spec) $global:OrBrowse[$this.Key] }
        return $o
    }
    $global:OrViews[$Server.Name][$ViewType]
}
function global:Connect-PortalVIServer { param($SiteCode) $global:OrConnected.Add($SiteCode); [pscustomobject]@{ Name = "vc-$($SiteCode.ToLower()).test.local"; Version = '8.0.3' } }
function global:Disconnect-PortalVIServer { param($Server) $global:OrDisconnected.Add($Server.Name) }
$global:OrConnected = [System.Collections.Generic.List[string]]::new(); $global:OrDisconnected = [System.Collections.Generic.List[string]]::new()

$cfgPath = Get-PortalPath -Name Config
$cfg = Read-PortalJson -Path $cfgPath; foreach ($s in $cfg.sites) { $s.enabled = $true }; Write-PortalJson -Path $cfgPath -Value $cfg
$ctx = New-TestContext -ItemId 'report-orphaned-vmdk'
$r = Invoke-TestHandler -Handler 'Get-VsphereOrphanedVmdk.ps1' -Parameters @{ Site = 'DC1'; AllSites = $true; AgeThresholdDays = 90; Context = $ctx }
Assert-Test -Name 'Orphans: other site connected and disconnected' -Condition ($null -eq $r.Error -and $global:OrConnected -contains 'DC2' -and $global:OrDisconnected -contains 'vc-dc2.test.local' -and @($r.Result.Scope).Count -eq 2) -Detail $r.Error
Assert-Test -Name 'Orphans: 4 items (detached, snapshot, CBT, unregistered VM); shared disk used in DC2 not reported' -Condition ($r.Result.Items -eq 4) -Detail ($r.Result | ConvertTo-Json -Compress)
$inv = @(Import-Csv (Get-ChildItem $ctx.ReportDir -Filter 'orphaned-vmdk-06-*.csv').FullName)
$cats = @($inv.Category | Sort-Object)
Assert-Test -Name 'Orphans: classification' -Condition (($cats -join ',') -eq 'CBT leftover,Detached disk,Orphaned snapshot,Unregistered VM') -Detail ($cats -join ',')
Assert-Test -Name 'Orphans: Content Library excluded, duplicated datastore scanned once, inaccessible reported' -Condition (-not ($inv.Path -match 'contentlib') -and $r.Result.DatastoresScanned -eq 2 -and $r.Result.NotScanned -eq 1)
Assert-Test -Name 'Orphans: reclaimable = old items only (500 + 80 GB + CBT)' -Condition ([double]$r.Result.ReclaimableTB -eq 0.57 -and [double]$r.Result.OrphanedTB -eq 0.59) -Detail "$($r.Result.ReclaimableTB) / $($r.Result.OrphanedTB)"
$r = Invoke-TestHandler -Handler 'Get-VsphereOrphanedVmdk.ps1' -Parameters @{ Site = 'DC1'; AllSites = $false; Context = (New-TestContext) }
Assert-Test -Name 'Orphans: single site reports the shared disk (limitation documented)' -Condition ($null -eq $r.Error -and $r.Result.Items -eq 5) -Detail "$($r.Error) $($r.Result.Items)"
$r = Invoke-TestHandler -Handler 'Get-VsphereOrphanedVmdk.ps1' -Parameters @{ Site = 'DC1'; AllSites = $false; DatastoreExcludePattern = '(['; Context = (New-TestContext) }
Assert-Test -Name 'Orphans: invalid exclude pattern refused' -Condition ($r.Error -match 'not a valid regular expression') -Detail $r.Error
foreach ($s in $cfg.sites) { $s.enabled = $false }; Write-PortalJson -Path $cfgPath -Value $cfg
#endregion

'Get-Cluster', 'Get-VMHost', 'Get-VM', 'Get-DrsRule', 'Get-DrsRecommendation', 'Get-Stat', 'Get-EsxCli', 'Get-View', 'Connect-PortalVIServer', 'Disconnect-PortalVIServer' |
    ForEach-Object { Remove-Item "function:global:$_" -ErrorAction SilentlyContinue }
