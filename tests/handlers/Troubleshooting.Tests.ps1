#Requires -Version 7.2
<#
.SYNOPSIS
    Offline tests: Aria Operations client, diagnostics library, vm-troubleshoot, vm-incident-evidence, aria-report.
    PowerCLI cmdlets are stubbed; Aria Operations is a fake connection (New-TestAria) answering by route.
#>
. (Join-Path $PSScriptRoot '_TestHelpers.ps1')
Start-TestGroup 'Troubleshooting and Aria Operations'
Import-Module (Join-Path $global:SspHandlerTestRoot 'automation/lib/Portal.Diagnostics.psm1') -Force -Global -DisableNameChecking

#region Fixtures ----------------------------------------------------------------------------------------------
$now = [DateTimeOffset]::UtcNow
$incident = $now.AddHours(-2)
$global:TsIncident = $incident
$incidentText = $incident.UtcDateTime.ToString('yyyy-MM-dd HH:mm')
$global:TsHost = [pscustomobject]@{ Name = 'esx-app-07.test.local'; ConnectionState = 'Connected'; Id = 'HostSystem-host-7' }
$global:TsVm = [pscustomobject]@{
    Name = 'APP-SQL01'; Id = 'VirtualMachine-vm-101'; PowerState = 'PoweredOn'; NumCpu = 4; MemoryGB = 32; HardwareVersion = 'vmx-21'; VMHost = $global:TsHost
    ExtensionData = [pscustomobject]@{ Guest = [pscustomobject]@{ ToolsRunningStatus = 'guestToolsRunning'; ToolsVersionStatus2 = 'guestToolsCurrent'; GuestFamily = 'windowsGuest' } }
}
$global:TsCalls = [System.Collections.Generic.List[string]]::new()
$global:TsGuestThrow = $null

function global:Get-VM { param($Name, $Server, $Location, [Parameter(ValueFromRemainingArguments)] $Rest) if ($Name -eq 'APP-SQL01') { $global:TsVm } }
function global:Get-VMGuest { param($VM, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) [pscustomobject]@{ State = 'Running'; GuestFamily = 'windowsGuest'; OSFullName = 'Microsoft Windows Server 2022 (64-bit)' } }
function global:Get-Cluster { param([Parameter(ValueFromPipeline)] $InputObject, $Name, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) process { [pscustomobject]@{ Name = 'CL-APP-01' } } }
function global:Get-Snapshot { param($VM, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) @() }
function global:Get-Datastore { param($RelatedObject, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) [pscustomobject]@{ Name = 'DS-APP-03'; CapacityGB = 4096; FreeSpaceGB = 512 } }
function global:Get-VIEvent {
    param($Entity, $Start, $Finish, $MaxSamples, $Server, [Parameter(ValueFromRemainingArguments)] $Rest)
    $global:TsCalls.Add("Get-VIEvent:$($Entity.Name)")
    if ($Entity.Name -ne 'APP-SQL01') { return }
    $t = $global:TsIncident.UtcDateTime.ToLocalTime()
    [pscustomobject]@{ CreatedTime = $t.AddMinutes(-12); FullFormattedMessage = 'Task: Create virtual machine snapshot'; UserName = 'CORP\svc-backup'; EventType = 'TaskEvent' }
    [pscustomobject]@{ CreatedTime = $t.AddMinutes(12); FullFormattedMessage = 'Task: Remove snapshot'; UserName = 'CORP\svc-backup'; EventType = 'TaskEvent' }
    [pscustomobject]@{ CreatedTime = $t.AddMinutes(1); FullFormattedMessage = 'User CORP\jdoe logged in'; UserName = 'CORP\jdoe'; EventType = 'UserLoginSessionEvent' }
}
function global:Get-Stat {
    param($Entity, $Stat, $Start, $Finish, $IntervalMins, $IntervalSecs, [switch] $Realtime, $Server, [Parameter(ValueFromRemainingArguments)] $Rest)
    $global:TsCalls.Add("Get-Stat:$($Entity.Name):${Stat}:$IntervalMins")
    if ($Stat -eq 'cpu.costop.summation') { throw 'Metric not available at this interval.' }   # missing counter must be skipped
    $s = [datetime]$Start; $f = [datetime]$Finish
    $peakAt = $global:TsIncident.UtcDateTime.ToLocalTime()
    for ($t = $s; $t -le $f; $t = $t.AddMinutes(5)) {
        $near = [math]::Abs(($t - $peakAt).TotalMinutes) -le 5
        $v = switch ($Stat) {
            'cpu.usage.average'                     { 40 }
            'cpu.ready.summation'                   { 3000 }          # 3000 ms / 300 s / 4 vCPU = 0.25 %
            'mem.usage.average'                     { 55 }
            'mem.vmmemctl.average'                  { 0 }
            'mem.swapped.average'                   { 0 }
            'mem.swapinRate.average'                { 0 }
            'disk.maxTotalLatency.latest'           { if ($near) { 58 } else { 4 } }
            'virtualDisk.totalWriteLatency.average' { if ($near) { 52 } else { 3 } }
            'virtualDisk.totalReadLatency.average'  { 2 }
            default                                 { 0 }
        }
        [pscustomobject]@{ Entity = $Entity; MetricId = $Stat; Value = $v; Timestamp = $t; Instance = '' }
        if ($Stat -like 'virtualDisk.*') { [pscustomobject]@{ Entity = $Entity; MetricId = $Stat; Value = 1; Timestamp = $t; Instance = 'scsi0:1' } }
        if ($Stat -eq 'cpu.usage.average') { [pscustomobject]@{ Entity = $Entity; MetricId = $Stat; Value = 99; Timestamp = $t; Instance = '0' } }   # per-core rows ignored
    }
}
$global:TsGuestJson = [ordered]@{
    family = 'windows'; os = 'Microsoft Windows Server 2022 Standard'; uptimeHours = 430.5; memoryUsedPercent = 91.2; cpuLoadPercent = 35; pendingReboot = @()
    disks = @([ordered]@{ name = 'C:'; sizeGB = 100; freeGB = 41; freePercent = 41 }, [ordered]@{ name = 'L:'; sizeGB = 200; freeGB = 14; freePercent = 7 })
    topProcesses = @([ordered]@{ name = 'sqlservr'; memoryMB = 28100; cpuSeconds = 9000 }); stoppedServices = @()
    eventCounts = [ordered]@{ critical = 0; error = 3 }
    events = @([ordered]@{ log = 'System'; source = 'Microsoft-Windows-FailoverClustering'; id = 1135; level = 'Error'; count = 2; first = '2026-10-21T08:41:00Z'; message = 'Cluster node was removed' })
} | ConvertTo-Json -Depth 5 -Compress
function global:Invoke-VMScript {
    param($VM, $Server, $GuestCredential, $ScriptText, $ScriptType, $ToolsWaitSecs, [Parameter(ValueFromRemainingArguments)] $Rest)
    $global:TsCalls.Add("Invoke-VMScript:$ScriptType")
    if ($global:TsGuestThrow) { throw $global:TsGuestThrow }
    [pscustomobject]@{ ScriptOutput = "__SSP_JSON=$($global:TsGuestJson)`n__SSP_EXIT=0"; ExitCode = 0 }
}

function New-TsAria {
    $vmRes = @{ identifier = 'aria-vm-1'; resourceKey = @{ name = 'APP-SQL01'; resourceKindKey = 'VirtualMachine'; adapterKindKey = 'VMWARE' } }
    $t0 = $global:TsIncident.AddMinutes(-10).ToUnixTimeMilliseconds(); $t1 = $global:TsIncident.ToUnixTimeMilliseconds()
    New-TestAria -Routes ([ordered]@{
        'GET /resources?name=APP-SQL01&resourceKind=VirtualMachine*' = @{ resourceList = @($vmRes, @{ identifier = 'x'; resourceKey = @{ name = 'APP-SQL01-OLD'; resourceKindKey = 'VirtualMachine' } }) }
        'GET /resources?name=esx-app-07*'                           = @{ resourceList = @(@{ identifier = 'aria-host-7'; resourceKey = @{ name = 'esx-app-07.test.local'; resourceKindKey = 'HostSystem' } }) }
        'GET /resources/aria-vm-1/relationships/parents'           = @{ resourceList = @(@{ identifier = 'aria-host-7'; resourceKey = @{ name = 'esx-app-07.test.local'; resourceKindKey = 'HostSystem' } }, @{ identifier = 'aria-ds-3'; resourceKey = @{ name = 'DS-APP-03'; resourceKindKey = 'Datastore' } }) }
        'GET /resources/aria-vm-1/stats/latest*'                   = @{ values = @(@{ resourceId = 'aria-vm-1'; 'stat-list' = @{ stat = @(@{ statKey = @{ key = 'badge|health' }; data = @(62) }, @{ statKey = @{ key = 'badge|risk' }; data = @(75) }, @{ statKey = @{ key = 'badge|efficiency' }; data = @(88) }) } }) }
        'GET /resources/aria-vm-1/statkeys'                        = @{ 'stat-key' = @(@{ key = 'cpu|readyPct' }, @{ key = 'virtualDisk:Aggregate of all instances|totalWriteLatency_average' }, @{ key = 'sys|poweredOn' }) }
        'GET /resources/aria-host-7/statkeys'                      = @{ 'stat-key' = @(@{ key = 'cpu|readyPct' }, @{ key = 'datastore|totalLatency_max' }) }
        'POST /resources/stats/query'                              = { param($Body) $global:TsStatBody = $Body
            @{ values = @(@{ resourceId = $Body.resourceId[0]; 'stat-list' = @{ stat = @($Body.statKey | ForEach-Object { @{ statKey = @{ key = $_ }; timestamps = @($t0, $t1); data = @(1.5, $(if ($_ -match 'Latency') { 61.2 } else { 2.1 })) } }) } }) } | ConvertTo-Json -Depth 10 | ConvertFrom-Json }.GetNewClosure()
        'GET /alerts?resourceId=aria-vm-1*'                        = @{ alerts = @(@{ alertDefinitionName = 'Virtual machine disk latency is high'; alertLevel = 'CRITICAL'; status = 'ACTIVE'; startTimeUTC = $t0; updateTimeUTC = $t1 },
                                                                                 @{ alertDefinitionName = 'Old cancelled alert'; alertLevel = 'WARNING'; status = 'CANCELED'; startTimeUTC = 1000; updateTimeUTC = 2000; cancelTimeUTC = 3000 }) }
        'GET /alerts?resourceId=aria-host-7*'                      = @{ alerts = @() }
        'POST /reports'                                            = @{ id = 'rep-123'; status = 'QUEUED' }
        'GET /reports/rep-123'                                     = @{ id = 'rep-123'; status = 'COMPLETED' }
        'GET /reports/rep-123/download*'                           = 'file'
        'GET /resources?name=CL-APP-01&resourceKind=ClusterComputeResource*' = @{ resourceList = @(@{ identifier = 'aria-cl-1'; resourceKey = @{ name = 'CL-APP-01'; resourceKindKey = 'ClusterComputeResource' } }) }
        'GET /resources?name=*'                                    = @{ resourceList = @() }
    })
}
$guestCred = [pscredential]::new('CORP\svc-diag', (ConvertTo-SecureString 'Gu3stDiagP@ss' -AsPlainText -Force))
#endregion

#region Library ---------------------------------------------------------------------------------------------------
$w = Resolve-PortalTimeWindow -Mode Incident -IncidentTime '2026-03-10 02:20' -MinutesBefore 30 -MinutesAfter 20 -TimeZone 'America/Chicago' -Now ([DateTimeOffset]'2026-03-11T00:00:00Z')
Assert-Test -Name 'Window: incident time read in the configured time zone (CDT = UTC-5)' -Condition ($w.Incident.UtcDateTime -eq [datetime]'2026-03-10T07:20:00' -and $w.Start.UtcDateTime -eq [datetime]'2026-03-10T06:50:00' -and $w.End.UtcDateTime -eq [datetime]'2026-03-10T07:40:00') -Detail "$($w.Incident) $($w.Start) $($w.End)"
$e = $null; try { $null = Resolve-PortalTimeWindow -Mode Incident -IncidentTime '21/10/2026' } catch { $e = $_.Exception.Message }
Assert-Test -Name 'Window: invalid incident time rejected' -Condition ($e -match 'not valid') -Detail $e
$e = $null; try { $null = Resolve-PortalTimeWindow -Mode Incident -IncidentTime ($now.AddDays(2).UtcDateTime.ToString('yyyy-MM-dd HH:mm')) } catch { $e = $_.Exception.Message }
Assert-Test -Name 'Window: future incident time rejected' -Condition ($e -match 'future') -Detail $e
$w = Resolve-PortalTimeWindow -Mode Last1h
Assert-Test -Name 'Window: last hour uses realtime samples' -Condition ((Get-PortalStatInterval -Start $w.Start).Realtime -and -not (Get-PortalStatInterval -Start $now.AddDays(-3)).Realtime -and (Get-PortalStatInterval -Start $now.AddDays(-3)).Minutes -eq 30)

$a = New-TsAria
$r = Find-PortalAriaResource -Aria $a -Name 'APP-SQL01'
Assert-Test -Name 'Aria: resource found by exact name (not prefix)' -Condition ($r.Id -eq 'aria-vm-1' -and $r.Kind -eq 'VirtualMachine')
$st = @(Get-PortalAriaStats -Aria $a -ResourceId 'aria-vm-1' -StatKey 'cpu|readyPct' -Start $incident.AddHours(-1) -End $incident -RollUp MAX)
Assert-Test -Name 'Aria: stats parsed (MAX rollup, 5-minute interval in the query)' -Condition ($st.Count -eq 2 -and $global:TsStatBody.rollUpType -eq 'MAX' -and $global:TsStatBody.intervalQuantifier -eq 5 -and $st[1].Value -eq 2.1)
$al = @(Get-PortalAriaAlerts -Aria $a -ResourceId 'aria-vm-1' -Start $incident.AddHours(-1) -End $incident.AddHours(1))
Assert-Test -Name 'Aria: only alerts that overlap the window' -Condition ($al.Count -eq 1 -and $al[0].Level -eq 'CRITICAL')
$b = Get-PortalAriaBadges -Aria $a -ResourceId 'aria-vm-1'
Assert-Test -Name 'Aria: health / risk / efficiency' -Condition ($b.Health -eq 62 -and $b.Risk -eq 75 -and $b.Efficiency -eq 88)
$e = $null; try { $null = Invoke-PortalAriaRequest -Aria $a -Path '/nothing' } catch { $e = $_.Exception.Message }
Assert-Test -Name 'Aria: unknown route fails with a clear message' -Condition ($e -match 'HTTP 404')
Assert-Test -Name 'Aria: object link from template' -Condition ((Get-PortalAriaResourceUrl -Aria $a -ResourceId 'aria-vm-1') -eq 'https://ops.test.local/ui/object/aria-vm-1')
$e = $null; try { $null = Connect-PortalAria -Site ([ordered]@{ code = 'DC9'; aria = [ordered]@{ enabled = $true; endpoint = '' } }) } catch { $e = $_.Exception.Message }
Assert-Test -Name 'Aria: connect refuses a site without endpoint' -Condition ($e -match 'not configured') -Detail $e

# Guest scripts: syntax of the generated PowerShell and Bash.
$ps = New-PortalGuestDiagScript -Family windows -Start $incident.AddHours(-1) -End $incident
$tok = $null; $perr = $null; $null = [System.Management.Automation.Language.Parser]::ParseInput($ps, [ref]$tok, [ref]$perr)
Assert-Test -Name 'Guest: Windows diagnostic script parses' -Condition (-not $perr.Count) -Detail (($perr | ForEach-Object Message) -join '; ')
$sh = New-PortalGuestDiagScript -Family linux -Start $incident.AddHours(-1) -End $incident
if (Get-Command bash -ErrorAction SilentlyContinue) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "ssp-diag-$([guid]::NewGuid().ToString('N')).sh"
    Set-Content -LiteralPath $tmp -Value (New-PortalGuestWrapper -ScriptText $sh -Type Bash -TimeoutSeconds 60) -NoNewline
    $o = & bash -n $tmp 2>&1; $ok = $LASTEXITCODE -eq 0
    Remove-Item $tmp -Force
    Assert-Test -Name 'Guest: Linux diagnostic script passes bash -n' -Condition $ok -Detail "$o"
}
Assert-Test -Name 'Guest: scripts contain no write operation' -Condition ($ps -notmatch '(?i)\b(Set-|Remove-|Stop-Service|Restart-|New-Item|Clear-EventLog)' -and $sh -notmatch '\brm\b|systemctl (restart|stop|start)')
$lin = ConvertFrom-PortalGuestDiagOutput -Family linux -Output ("__SSP_KV:os=AlmaLinux 9.4`n__SSP_KV:uptimeHours=12.5`n__SSP_KV:memoryUsedPercent=40.1`n__SSP_KV:load1=3.2`n__SSP_KV:cpus=4`n__SSP_KV:pendingReboot=needs-restarting`n" +
    "DISK|/|50.0|4.0|8.0`nDISK|/var|100.0|60.0|60.0`nPROC|java|2048|12.5`nSVC|httpd.service`nEVT|kernel|7|2026-10-21T08:41:00+0000|I/O error, dev sdb`n__SSP_KV:journalCritical=1")
Assert-Test -Name 'Guest: Linux output normalised' -Condition ($lin.os -eq 'AlmaLinux 9.4' -and $lin.cpuLoadPercent -eq 80 -and @($lin.disks).Count -eq 2 -and $lin.disks[0].freePercent -eq 8 -and @($lin.stoppedServices).Count -eq 1 -and $lin.eventCounts.error -eq 7 -and @($lin.pendingReboot) -contains 'needs-restarting')
$f = @(Get-PortalTroubleshootFindings -Guest $lin -Thresholds @{})
Assert-Test -Name 'Findings: Linux guest (disk 8 % = CRITICAL, failed unit, journal errors)' -Condition (($f | Where-Object { $_.Title -match 'disk /' -and $_.Severity -eq 'CRITICAL' }) -and ($f | Where-Object Title -match 'automatic service') -and $f[0].Severity -eq 'CRITICAL')
$f = @(Get-PortalTroubleshootFindings -Vsphere ([pscustomobject]@{ Perf = [pscustomobject]@{ Series = @() }; HostPerf = $null; Events = @(); Snapshots = @(); Datastores = @(); Tools = 'guestToolsRunning'; NumCpu = 2; Host = 'h' }) -Thresholds @{})
Assert-Test -Name 'Findings: quiet VM gives no finding' -Condition ($f.Count -eq 0)
#endregion

#region vm-troubleshoot -----------------------------------------------------------------------------------------
$ctx = New-TestContext -ItemId 'vm-troubleshoot' -Aria (New-TsAria)
$global:TsCalls.Clear()
$r = Invoke-TestHandler -Handler 'Get-VmTroubleshooting.ps1' -Parameters @{ Site = 'DC1'; VMName = 'APP-SQL01'; WindowMode = 'Incident'; IncidentTime = $incidentText; MinutesBefore = 60; MinutesAfter = 30
    IncludeHost = $true; UseGuest = $true; GuestCredential = $guestCred; UseAria = $true; AriaReport = 'def-vm-troubleshooting'; Symptom = 'Slowness'; Context = $ctx }
Assert-Test -Name 'Troubleshoot: all sources succeed' -Condition ($null -eq $r.Error -and @($r.Result.Sources | Where-Object { $_ -match ': OK' }).Count -eq 3) -Detail "$($r.Error) $($r.Result.Sources -join ' | ')"
Assert-Test -Name 'Troubleshoot: verdict = snapshot activity during the latency peak' -Condition ($r.Result.Verdict -match 'Snapshot / backup activity|Storage latency') -Detail $r.Result.Verdict
$tf = @($r.Result.TopFindings)
Assert-Test -Name 'Troubleshoot: storage latency confirmed by vSphere and Aria' -Condition (@($tf | Where-Object { $_ -match 'Storage latency' -and $_ -match 'vSphere' -and $_ -match 'Aria Operations' }).Count -eq 1) -Detail ($tf -join ' | ')
Assert-Test -Name 'Troubleshoot: guest findings (disk L: 7 %, cluster events)' -Condition ((@($tf) -join ' ') -match 'Guest disk L:|error event') -Detail ($tf -join ' | ')
Assert-Test -Name 'Troubleshoot: CPU ready normal is not reported' -Condition (-not (@($tf) -match 'CPU contention'))
Assert-Test -Name 'Troubleshoot: missing counter skipped with a warning' -Condition (@($r.Log | Where-Object { $_ -match 'cpu.costop.summation' }).Count -ge 1)
$files = Get-TestReportFiles -Context $ctx
Assert-Test -Name 'Troubleshoot: report, CSV, Aria PDF and evidence pack' -Condition ($files -contains 'troubleshooting.html' -and ($files -like '*.csv').Count -ge 3 -and $files -contains 'aria-report-APP-SQL01.pdf' -and $files -contains 'evidence-APP-SQL01.zip' -and $r.Result.AriaReport -eq 'aria-report-APP-SQL01.pdf') -Detail ($files -join ', ')
$html = Get-Content -Raw (Join-Path $ctx.ReportDir 'troubleshooting.html')
Assert-Test -Name 'Troubleshoot: report has the latency chart (inline SVG, no script)' -Condition ($html -match '<svg' -and $html -match 'polyline' -and $html -notmatch '<script')
$zip = [IO.Compression.ZipFile]::OpenRead((Join-Path $ctx.ReportDir 'evidence-APP-SQL01.zip')); $entries = @($zip.Entries.Name); $zip.Dispose()
Assert-Test -Name 'Troubleshoot: evidence pack holds raw samples and guest data' -Condition ($entries -contains 'vsphere-samples.csv' -and $entries -contains 'aria-stats.csv' -and $entries -contains 'guest.json' -and $entries -contains 'troubleshooting.html') -Detail ($entries -join ', ')
Assert-Test -Name 'Troubleshoot: guest password never logged' -Condition (-not ($r.Log -match 'Gu3stDiagP@ss'))
Assert-Test -Name 'Troubleshoot: host events read too' -Condition ($global:TsCalls -contains 'Get-VIEvent:esx-app-07.test.local')

$ctx = New-TestContext -ItemId 'vm-troubleshoot'
$r = Invoke-TestHandler -Handler 'Get-VmTroubleshooting.ps1' -Parameters @{ Site = 'DC1'; VMName = 'APP-SQL01'; WindowMode = 'Last24h'; UseGuest = $false; UseAria = $true; Context = $ctx }
Assert-Test -Name 'Troubleshoot: works without Aria (reported as not available)' -Condition ($null -eq $r.Error -and ($r.Result.Sources -match 'Aria Operations: NOT AVAILABLE') -and $r.Result.NextSteps -match 'Include guest OS') -Detail $r.Error

$r = Invoke-TestHandler -Handler 'Get-VmTroubleshooting.ps1' -Parameters @{ Site = 'DC1'; VMName = 'APP-SQL01'; UseGuest = $true; Context = (New-TestContext) }
Assert-Test -Name 'Troubleshoot: guest without credential refused' -Condition ($r.Error -match 'guest credential') -Detail $r.Error

$global:TsGuestThrow = 'A specified parameter was not correct: guest credential'
$r = Invoke-TestHandler -Handler 'Get-VmTroubleshooting.ps1' -Parameters @{ Site = 'DC1'; VMName = 'APP-SQL01'; UseGuest = $true; GuestCredential = $guestCred; UseAria = $false; Context = (New-TestContext) }
$global:TsGuestThrow = $null
Assert-Test -Name 'Troubleshoot: guest failure does not stop the diagnosis' -Condition ($null -eq $r.Error -and ($r.Result.Sources -match 'Guest OS: FAILED') -and -not ($r.Result.Sources -match 'Gu3stDiagP@ss')) -Detail "$($r.Error) $($r.Result.Sources -join ' | ')"

$r = Invoke-TestHandler -Handler 'Get-VmTroubleshooting.ps1' -Parameters @{ Site = 'DC1'; VMName = 'NOPE'; Context = (New-TestContext) }
Assert-Test -Name 'Troubleshoot: unknown VM fails clearly' -Condition ($r.Error -match "VM 'NOPE' was not found") -Detail $r.Error
#endregion

#region vm-incident-evidence -----------------------------------------------------------------------------------
$ctx = New-TestContext -ItemId 'vm-incident-evidence' -Aria (New-TsAria)
$r = Invoke-TestHandler -Handler 'Export-VmIncidentEvidence.ps1' -Parameters @{ Site = 'DC1'; VMName = 'APP-SQL01'; IncidentTime = $incidentText; MinutesBefore = 30; MinutesAfter = 30; IncludeHost = $true; UseAria = $true; Reference = 'INC0012345'; Context = $ctx }
Assert-Test -Name 'Evidence: completed with Aria alerts and events' -Condition ($null -eq $r.Error -and $r.Result.AriaAlerts -eq 1 -and $r.Result.Events -ge 3 -and $r.Result.AriaLink) -Detail $r.Error
$zip = [IO.Compression.ZipFile]::OpenRead((Join-Path $ctx.ReportDir 'evidence-APP-SQL01.zip')); $entries = @($zip.Entries.Name); $zip.Dispose()
Assert-Test -Name 'Evidence: pack has Aria stats per object, vSphere samples, events CSV' -Condition (($entries -like 'aria-stats-VM_APP-SQL01.csv') -and ($entries -like 'aria-stats-Host_esx-app-07*') -and ($entries -contains 'vsphere-samples.csv') -and ($entries -like '*events*')) -Detail ($entries -join ', ')
Assert-Test -Name 'Evidence: Aria stats queried with MAX rollup' -Condition ($global:TsStatBody.rollUpType -eq 'MAX')
$r = Invoke-TestHandler -Handler 'Export-VmIncidentEvidence.ps1' -Parameters @{ Site = 'DC1'; VMName = 'APP-SQL01'; IncidentTime = 'yesterday'; Context = (New-TestContext) }
Assert-Test -Name 'Evidence: invalid incident time refused' -Condition ($r.Error -match 'not valid') -Detail $r.Error
#endregion

#region aria-report --------------------------------------------------------------------------------------------
$ctx = New-TestContext -ItemId 'aria-report' -Aria (New-TsAria)
$ctx.Site['aria'] = [ordered]@{ enabled = $true; endpoint = 'ops.test.local'; reports = @([ordered]@{ id = 'def-cap'; name = 'Host and Cluster Capacity'; subject = @('ClusterComputeResource') }) }
$r = Invoke-TestHandler -Handler 'Invoke-AriaOperationsReport.ps1' -Parameters @{ Site = 'DC1'; ObjectType = 'ClusterComputeResource'; ClusterName = 'CL-APP-01'; ReportDefinition = 'def-cap'; Format = 'Both'; Context = $ctx }
$files = Get-TestReportFiles -Context $ctx
Assert-Test -Name 'Aria report: PDF and CSV downloaded' -Condition ($null -eq $r.Error -and @($files | Where-Object { $_ -like 'aria-host-and-cluster-capacity-CL-APP-01.*' }).Count -eq 2 -and $r.Result.AriaReport -eq 'rep-123') -Detail "$($r.Error) $($files -join ', ')"
Assert-Test -Name 'Aria report: generated, polled and downloaded' -Condition (($global:AriaCalls -contains 'POST /reports') -and ($global:AriaCalls -contains 'GET /reports/rep-123') -and ($global:AriaCalls -contains 'GET /reports/rep-123/download?format=CSV'))
$r = Invoke-TestHandler -Handler 'Invoke-AriaOperationsReport.ps1' -Parameters @{ Site = 'DC1'; ObjectType = 'ClusterComputeResource'; ClusterName = 'CL-APP-01'; ReportDefinition = 'def-other'; Context = $ctx }
Assert-Test -Name 'Aria report: definition not offered for the site refused' -Condition ($r.Error -match 'not offered') -Detail $r.Error
$r = Invoke-TestHandler -Handler 'Invoke-AriaOperationsReport.ps1' -Parameters @{ Site = 'DC1'; ObjectType = 'Datastore'; DatastoreName = 'DS-NOPE'; ReportDefinition = 'def-cap'; Context = $ctx }
Assert-Test -Name 'Aria report: object not in Aria fails clearly' -Condition ($r.Error -match 'not found in Aria') -Detail $r.Error
$r = Invoke-TestHandler -Handler 'Invoke-AriaOperationsReport.ps1' -Parameters @{ Site = 'DC1'; ObjectType = 'VirtualMachine'; VMName = 'APP-SQL01'; ReportDefinition = 'def-cap'; Context = (New-TestContext) }
Assert-Test -Name 'Aria report: refused without Aria connection' -Condition ($r.Error -match 'not available') -Detail $r.Error
#endregion

#region Catalog lookup: ariaReports ------------------------------------------------------------------------------
Import-Module (Join-Path $global:SspHandlerTestRoot 'modules/Portal.Catalog.psm1') -Force -Global
$cfgPath = Get-PortalPath -Name Config
$cfg = Read-PortalJson -Path $cfgPath
$cfg.sites[0].enabled = $true
$cfg.sites[0].aria.enabled = $true; $cfg.sites[0].aria.endpoint = 'ops.test.local'
$cfg.sites[0].aria.reports = @([ordered]@{ id = 'd1'; name = 'VM troubleshooting'; subject = @('VirtualMachine') }, [ordered]@{ id = 'd2'; name = 'Cluster capacity'; subject = @('ClusterComputeResource') })
Write-PortalJson -Path $cfgPath -Value $cfg
$item = Read-PortalJson -Path (Join-Path $global:SspHandlerTestRoot 'catalog/items/vm-troubleshoot.json')
$o = @(Get-PortalLookupOptions -Item $item -InputName 'AriaReport' -Values @{ Site = $cfg.sites[0].code })
Assert-Test -Name 'Lookup: ariaReports filtered by subject' -Condition ($o.Count -eq 1 -and $o[0].value -eq 'd1') -Detail ($o | ConvertTo-Json -Compress)
$cfg.sites[0].aria.enabled = $false; Write-PortalJson -Path $cfgPath -Value $cfg
$e = $null; try { $null = Get-PortalLookupOptions -Item $item -InputName 'AriaReport' -Values @{ Site = $cfg.sites[0].code } } catch { $e = $_.Exception.Message }
Assert-Test -Name 'Lookup: ariaReports explains a disabled connection' -Condition ($e -match 'not enabled') -Detail $e
$cfg.sites[0].enabled = $false; Write-PortalJson -Path $cfgPath -Value $cfg
#endregion

'Get-VM', 'Get-VMGuest', 'Get-Cluster', 'Get-Snapshot', 'Get-Datastore', 'Get-VIEvent', 'Get-Stat', 'Invoke-VMScript' | ForEach-Object { Remove-Item "function:global:$_" -ErrorAction SilentlyContinue }
