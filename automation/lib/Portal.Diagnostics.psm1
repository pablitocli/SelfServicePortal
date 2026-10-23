#Requires -Version 7.2
<#
.SYNOPSIS
    Portal.Diagnostics - read-only data collection and analysis for the VM troubleshooting and incident evidence items.
.DESCRIPTION
    Three sources, each optional and independent (a failing source is reported, the others still run):
      * vSphere  : performance counters (Get-Stat), events and tasks, snapshots, VMware Tools, host and datastores.
      * Guest OS : one read-only script through VMware Tools (Portal.Guest, vault credential): uptime, pending reboot,
                   memory, disks, top processes, stopped automatic services, error events in the window.
      * Aria Ops : resource, parents (host, datastores), Health / Risk / Efficiency, stats with MAX rollup, alerts.
    Get-PortalTroubleshootFindings turns the data into ranked findings with the sources that support each one.
    Nothing here changes the VM, the guest, vCenter or Aria Operations.
#>

Set-StrictMode -Version Latest

function Get-DiagVal {
    param($Object, [string] $Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] } return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function Write-DiagLog {
    param([string] $Message, [string] $Level = 'INFO')
    if (Get-Command Write-JobLog -ErrorAction SilentlyContinue) { Write-JobLog $Message -Level $Level } else { Write-Verbose "[$Level] $Message" }
}

#region Time window -----------------------------------------------------------------------------------------

function Resolve-PortalTimeWindow {
    <#
    .SYNOPSIS Analysis window as UTC [DateTimeOffset] Start / End.
    .PARAMETER Mode          Last1h | Last24h | Last7d | Incident
    .PARAMETER IncidentTime  'yyyy-MM-dd HH:mm' in TimeZone (Windows or IANA id; operations.troubleshooting.timeZone).
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Last1h', 'Last24h', 'Last7d', 'Incident')] [string] $Mode = 'Last24h',
        [string] $IncidentTime,
        [ValidateRange(0, 1440)] [int] $MinutesBefore = 60,
        [ValidateRange(0, 1440)] [int] $MinutesAfter = 30,
        [string] $TimeZone = 'UTC',
        [DateTimeOffset] $Now = [DateTimeOffset]::UtcNow
    )
    $tz = try { [TimeZoneInfo]::FindSystemTimeZoneById($(if ($TimeZone) { $TimeZone } else { 'UTC' })) } catch { throw "Time zone '$TimeZone' is not known on the portal server (operations.troubleshooting.timeZone)." }
    switch ($Mode) {
        'Last1h'  { $s = $Now.AddHours(-1); $e = $Now }
        'Last24h' { $s = $Now.AddHours(-24); $e = $Now }
        'Last7d'  { $s = $Now.AddDays(-7); $e = $Now }
        'Incident' {
            if (-not $IncidentTime) { throw 'Incident time is required for the "Around an incident" window (format yyyy-MM-dd HH:mm).' }
            $local = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($IncidentTime.Trim(), [string[]]@('yyyy-MM-dd HH:mm', 'yyyy-MM-dd HH:mm:ss', "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss"),
                    [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$local)) {
                throw "Incident time '$IncidentTime' is not valid (use yyyy-MM-dd HH:mm, time zone $($tz.Id))."
            }
            $offset = $tz.GetUtcOffset([datetime]::SpecifyKind($local, [DateTimeKind]::Unspecified))
            $at = [DateTimeOffset]::new([datetime]::SpecifyKind($local, [DateTimeKind]::Unspecified), $offset).ToUniversalTime()
            if ($at -gt $Now.AddMinutes(5)) { throw "Incident time $IncidentTime ($($tz.Id)) is in the future." }
            $s = $at.AddMinutes(-$MinutesBefore); $e = $at.AddMinutes($MinutesAfter)
            if ($e -gt $Now) { $e = $Now }
            return [pscustomobject]@{ Start = $s; End = $e; Incident = $at; TimeZone = $tz.Id
                                      Label = ('{0:yyyy-MM-dd HH:mm} -> {1:HH:mm} UTC (incident {2} {3})' -f $s, $e, $IncidentTime, $tz.Id) }
        }
    }
    return [pscustomobject]@{ Start = $s; End = $e; Incident = $null; TimeZone = $tz.Id; Label = ('{0:yyyy-MM-dd HH:mm} -> {1:yyyy-MM-dd HH:mm} UTC' -f $s, $e) }
}

#endregion

#region vSphere ---------------------------------------------------------------------------------------------

function Get-PortalStatInterval {
    <# Collection interval vCenter still keeps for a window starting at Start: realtime (20 s, last hour) or a historical rollup. #>
    param([DateTimeOffset] $Start, [DateTimeOffset] $Now = [DateTimeOffset]::UtcNow)
    $age = $Now - $Start
    if ($age.TotalMinutes -le 62) { return [pscustomobject]@{ Realtime = $true; Seconds = 20; Minutes = 0; Label = 'realtime (20 s)' } }
    if ($age.TotalDays -le 1)     { return [pscustomobject]@{ Realtime = $false; Seconds = 300; Minutes = 5; Label = '5 min' } }
    if ($age.TotalDays -le 7)     { return [pscustomobject]@{ Realtime = $false; Seconds = 1800; Minutes = 30; Label = '30 min' } }
    if ($age.TotalDays -le 30)    { return [pscustomobject]@{ Realtime = $false; Seconds = 7200; Minutes = 120; Label = '2 h' } }
    return [pscustomobject]@{ Realtime = $false; Seconds = 86400; Minutes = 1440; Label = '1 day' }
}

$script:VmCounters = @(
    [pscustomobject]@{ Id = 'cpu.usage.average';               Name = 'CPU usage';            Unit = '%';      Mode = 'aggregate'; Kind = 'percent' }
    [pscustomobject]@{ Id = 'cpu.ready.summation';             Name = 'CPU ready';            Unit = '%';      Mode = 'aggregate'; Kind = 'readyPct' }
    [pscustomobject]@{ Id = 'cpu.costop.summation';            Name = 'CPU co-stop';          Unit = '%';      Mode = 'aggregate'; Kind = 'readyPct' }
    [pscustomobject]@{ Id = 'mem.usage.average';               Name = 'Memory active';        Unit = '%';      Mode = 'aggregate'; Kind = 'percent' }
    [pscustomobject]@{ Id = 'mem.vmmemctl.average';            Name = 'Memory balloon';       Unit = 'MB';     Mode = 'aggregate'; Kind = 'kbToMb' }
    [pscustomobject]@{ Id = 'mem.swapped.average';             Name = 'Memory swapped';       Unit = 'MB';     Mode = 'aggregate'; Kind = 'kbToMb' }
    [pscustomobject]@{ Id = 'mem.swapinRate.average';          Name = 'Swap-in rate';         Unit = 'KBps';   Mode = 'aggregate'; Kind = 'raw' }
    [pscustomobject]@{ Id = 'disk.maxTotalLatency.latest';     Name = 'Disk latency (max)';   Unit = 'ms';     Mode = 'aggregate'; Kind = 'raw' }
    [pscustomobject]@{ Id = 'virtualDisk.totalReadLatency.average';  Name = 'Disk read latency';  Unit = 'ms'; Mode = 'maxInstance'; Kind = 'raw' }
    [pscustomobject]@{ Id = 'virtualDisk.totalWriteLatency.average'; Name = 'Disk write latency'; Unit = 'ms'; Mode = 'maxInstance'; Kind = 'raw' }
    [pscustomobject]@{ Id = 'net.droppedRx.summation';         Name = 'Network drops rx';     Unit = 'pkts';   Mode = 'aggregate'; Kind = 'raw' }
    [pscustomobject]@{ Id = 'net.droppedTx.summation';         Name = 'Network drops tx';     Unit = 'pkts';   Mode = 'aggregate'; Kind = 'raw' }
)
$script:HostCounters = @(
    [pscustomobject]@{ Id = 'cpu.usage.average';           Name = 'Host CPU usage';          Unit = '%';  Mode = 'aggregate'; Kind = 'percent' }
    [pscustomobject]@{ Id = 'mem.usage.average';           Name = 'Host memory usage';       Unit = '%';  Mode = 'aggregate'; Kind = 'percent' }
    [pscustomobject]@{ Id = 'disk.maxTotalLatency.latest'; Name = 'Host disk latency (max)'; Unit = 'ms'; Mode = 'aggregate'; Kind = 'raw' }
)

function Get-PortalPerfSeries {
    <#
    .SYNOPSIS Reads counters for one entity and returns one series per counter (missing counters are skipped and listed).
    .OUTPUTS  @{ Interval; Series = @( @{ Id; Name; Unit; Points = @(@{ Time; Value }) } ); Missing = @(ids) }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Entity,
        [Parameter(Mandatory)] $Server,
        [Parameter(Mandatory)] [DateTimeOffset] $Start,
        [Parameter(Mandatory)] [DateTimeOffset] $End,
        [ValidateSet('vm', 'host')] [string] $Kind = 'vm',
        [int] $NumCpu = 1
    )
    $iv = Get-PortalStatInterval -Start $Start
    $counters = if ($Kind -eq 'vm') { $script:VmCounters } else { $script:HostCounters }
    $series = [System.Collections.Generic.List[object]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($c in $counters) {
        $p = @{ Entity = $Entity; Stat = $c.Id; Start = $Start.UtcDateTime.ToLocalTime(); Finish = $End.UtcDateTime.ToLocalTime(); Server = $Server; ErrorAction = 'Stop' }
        if ($iv.Realtime) { $p['Realtime'] = $true; $p['IntervalSecs'] = 20 } else { $p['IntervalMins'] = $iv.Minutes }
        $rows = @(try { Get-Stat @p } catch { $null })
        $rows = @($rows | Where-Object { $_ })
        if (-not $rows.Count) { $missing.Add($c.Id); continue }
        $byTime = [ordered]@{}
        foreach ($r in $rows) {
            $inst = [string](Get-DiagVal $r 'Instance' '')
            if ($c.Mode -eq 'aggregate' -and $inst -ne '') { continue }
            $t = [DateTimeOffset]([datetime]$r.Timestamp)
            $k = $t.UtcTicks
            $v = [double]$r.Value
            if ($byTime.Contains($k)) { if ($v -gt $byTime[$k].Value) { $byTime[$k].Value = $v } }
            else { $byTime[$k] = [pscustomobject]@{ Time = $t.ToUniversalTime(); Value = $v } }
        }
        $sec = if ($iv.Realtime) { 20 } else { $iv.Seconds }
        $pts = foreach ($pt in $byTime.Values) {
            $v = switch ($c.Kind) {
                'readyPct' { [math]::Round($pt.Value / ($sec * 1000) * 100 / [math]::Max(1, $NumCpu), 2) }
                'kbToMb'   { [math]::Round($pt.Value / 1024, 1) }
                default    { [math]::Round($pt.Value, 2) }
            }
            [pscustomobject]@{ Time = $pt.Time; Value = $v }
        }
        $pts = @($pts | Sort-Object { $_.Time.UtcTicks })
        if (-not $pts.Count) { $missing.Add($c.Id); continue }
        $series.Add([pscustomobject]@{ Id = $c.Id; Name = $c.Name; Unit = $c.Unit; Points = $pts })
    }
    return [pscustomobject]@{ Interval = $iv; Series = $series.ToArray(); Missing = $missing.ToArray() }
}

function Get-PortalSeriesSummary {
    <# Max / average / time of max for each series. #>
    param([object[]] $Series, [string] $Source = 'vSphere', [string] $Object = '')
    foreach ($s in @($Series)) {
        $pts = @($s.Points)
        if (-not $pts.Count) { continue }
        $max = $pts | Sort-Object Value -Descending | Select-Object -First 1
        [pscustomobject]@{
            Source = $Source; Object = $Object; Metric = $s.Name; Unit = $s.Unit
            Max = [math]::Round([double]$max.Value, 2); Avg = [math]::Round(($pts | Measure-Object Value -Average).Average, 2)
            PeakAt = $max.Time; Samples = $pts.Count
        }
    }
}

function Get-PortalEventCategory {
    param([string] $Type, [string] $Message)
    switch -Regex ("$Type $Message") {
        '(?i)snapshot|consolidat'                         { return 'Snapshot' }
        '(?i)migrat|vmotion|relocat'                      { return 'Migration' }
        '(?i)\bHA\b|das|failover|restarted on'            { return 'HA' }
        '(?i)reconfigur'                                   { return 'Reconfigure' }
        '(?i)power|reset|reboot|shut|guest.*restart'      { return 'Power' }
        '(?i)disconnect|not responding|lost.*(access|connect)|heartbeat|apd|pdl|redundan' { return 'Connectivity' }
        '(?i)alarm'                                        { return 'Alarm' }
        default                                            { return 'Other' }
    }
}

function Get-PortalEntityEvents {
    <# vCenter events and tasks of entities in the window: Time (UTC), Object, Category, Type, User, Message. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]] $Entity, [Parameter(Mandatory)] $Server, [Parameter(Mandatory)] [DateTimeOffset] $Start, [Parameter(Mandatory)] [DateTimeOffset] $End, [int] $MaxSamples = 2000)
    $rows = foreach ($en in @($Entity | Where-Object { $_ })) {
        $ev = @(try { Get-VIEvent -Entity $en -Start $Start.UtcDateTime.ToLocalTime() -Finish $End.UtcDateTime.ToLocalTime() -MaxSamples $MaxSamples -Server $Server -ErrorAction Stop }
                catch { Write-DiagLog -Level WARN "Events of $($en.Name) could not be read: $($_.Exception.Message)"; @() })
        foreach ($e in $ev) {
            if (-not $e) { continue }
            $type = [string]$e.GetType().Name
            if ($type -in 'PSCustomObject', 'Hashtable') { $type = [string](Get-DiagVal $e 'EventType' 'Event') }
            $msg = [string](Get-DiagVal $e 'FullFormattedMessage' '')
            [pscustomobject]@{
                Time     = ([DateTimeOffset]([datetime]$e.CreatedTime)).ToUniversalTime()
                Object   = [string]$en.Name
                Category = Get-PortalEventCategory -Type $type -Message $msg
                Type     = $type
                User     = [string](Get-DiagVal $e 'UserName' '')
                Message  = $(if ($msg.Length -gt 300) { $msg.Substring(0, 300) + '...' } else { $msg })
            }
        }
    }
    return @($rows | Sort-Object { $_.Time.UtcTicks })
}

function Get-PortalVsphereEvidence {
    <#
    .SYNOPSIS VM, host and datastores, Tools, snapshots, performance series (VM + optional host) and events.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VMName,
        [Parameter(Mandatory)] $Server,
        [Parameter(Mandatory)] $Window,
        [bool] $IncludeHost = $true,
        [int] $MaxEvents = 2000
    )
    $vm = @(Get-VM -Name $VMName -Server $Server -ErrorAction SilentlyContinue)
    if (-not $vm.Count) { throw "VM '$VMName' was not found in $($Server.Name)." }
    if ($vm.Count -gt 1) { throw "More than one VM is named '$VMName' in $($Server.Name)." }
    $vm = $vm[0]
    $vmHost = Get-DiagVal $vm 'VMHost'
    $tools = ''
    try { $tools = [string]$vm.ExtensionData.Guest.ToolsRunningStatus + ' / ' + [string]$vm.ExtensionData.Guest.ToolsVersionStatus2 } catch { $tools = '' }
    $snaps = @(try { Get-Snapshot -VM $vm -Server $Server -ErrorAction Stop } catch { @() }) | Where-Object { $_ } | ForEach-Object {
        [pscustomobject]@{ Name = [string]$_.Name; Created = ([DateTimeOffset]([datetime]$_.Created)).ToUniversalTime(); SizeGB = [math]::Round([double](Get-DiagVal $_ 'SizeGB' 0), 1); Description = [string](Get-DiagVal $_ 'Description' '') }
    }
    $ds = @(try { Get-Datastore -RelatedObject $vm -Server $Server -ErrorAction Stop } catch { @() }) | Where-Object { $_ } | ForEach-Object {
        $cap = [double](Get-DiagVal $_ 'CapacityGB' 0); $free = [double](Get-DiagVal $_ 'FreeSpaceGB' 0)
        [pscustomobject]@{ Name = [string]$_.Name; CapacityGB = [math]::Round($cap); FreeGB = [math]::Round($free); FreePercent = $(if ($cap -gt 0) { [math]::Round(100 * $free / $cap, 1) } else { $null }) }
    }
    $numCpu = [int](Get-DiagVal $vm 'NumCpu' 1)
    Write-DiagLog "vSphere: reading performance counters of $VMName ($((Get-PortalStatInterval -Start $Window.Start).Label) samples)."
    $perf = Get-PortalPerfSeries -Entity $vm -Server $Server -Start $Window.Start -End $Window.End -Kind vm -NumCpu $numCpu
    $hostPerf = $null
    if ($IncludeHost -and $vmHost) { $hostPerf = Get-PortalPerfSeries -Entity $vmHost -Server $Server -Start $Window.Start -End $Window.End -Kind host }
    $entities = @($vm) + @(if ($IncludeHost -and $vmHost) { $vmHost })
    $events = Get-PortalEntityEvents -Entity $entities -Server $Server -Start $Window.Start -End $Window.End -MaxSamples $MaxEvents
    return [pscustomobject]@{
        VM         = $vm
        Name       = [string]$vm.Name
        PowerState = [string]$vm.PowerState
        NumCpu     = $numCpu
        MemoryGB   = [double](Get-DiagVal $vm 'MemoryGB' 0)
        Host       = $(if ($vmHost) { [string]$vmHost.Name } else { '' })
        HostState  = $(if ($vmHost) { [string](Get-DiagVal $vmHost 'ConnectionState' '') } else { '' })
        Cluster    = $(try { [string]($vm | Get-Cluster -ErrorAction Stop).Name } catch { '' })
        Tools      = $tools
        HwVersion  = [string](Get-DiagVal $vm 'HardwareVersion' '')
        Snapshots  = @($snaps)
        Datastores = @($ds)
        Perf       = $perf
        HostPerf   = $hostPerf
        Events     = @($events)
    }
}

#endregion

#region Guest OS --------------------------------------------------------------------------------------------

function New-PortalGuestDiagScript {
    <# Read-only diagnostic script for the guest (PowerShell 5.1 or Bash). Times are passed in UTC. Exposed for tests. #>
    [CmdletBinding()] [OutputType([string])]
    param([ValidateSet('windows', 'linux')] [string] $Family, [Parameter(Mandatory)] [DateTimeOffset] $Start, [Parameter(Mandatory)] [DateTimeOffset] $End)
    $s = $Start.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ'); $e = $End.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
    if ($Family -eq 'windows') {
        return @"
`$st = [DateTime]::Parse('$s', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal).ToLocalTime()
`$en = [DateTime]::Parse('$e', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal).ToLocalTime()
`$os = Get-CimInstance Win32_OperatingSystem
`$o = [ordered]@{ family = 'windows'; os = [string]`$os.Caption; lastBoot = `$os.LastBootUpTime.ToUniversalTime().ToString('o') }
`$o.uptimeHours = [math]::Round(((Get-Date) - `$os.LastBootUpTime).TotalHours, 1)
`$o.memoryUsedPercent = [math]::Round(100 * (1 - `$os.FreePhysicalMemory / `$os.TotalVisibleMemorySize), 1)
`$o.cpuLoadPercent = [math]::Round((Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average, 0)
`$pr = @()
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { `$pr += 'Component Based Servicing' }
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { `$pr += 'Windows Update' }
if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue)) { `$pr += 'Pending file rename' }
`$o.pendingReboot = @(`$pr)
`$o.disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { [ordered]@{ name = `$_.DeviceID; label = [string]`$_.VolumeName; sizeGB = [math]::Round(`$_.Size / 1GB, 1); freeGB = [math]::Round(`$_.FreeSpace / 1GB, 1); freePercent = `$(if (`$_.Size) { [math]::Round(100 * `$_.FreeSpace / `$_.Size, 1) } else { 0 }) } })
`$o.topProcesses = @(Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 6 | ForEach-Object { [ordered]@{ name = `$_.ProcessName; memoryMB = [math]::Round(`$_.WorkingSet64 / 1MB); cpuSeconds = [math]::Round([double]`$_.CPU) } })
`$skip = '^(sppsvc|RemoteRegistry|gupdate|gupdatem|edgeupdate|edgeupdatem|MapsBroker|tiledatamodelsvc|WbioSrvc|CDPSvc|TrustedInstaller|ShellHWDetection|wuauserv|BITS|UsoSvc|DoSvc|sysmain|GoogleUpdate.*|clr_optimization.*|DPS|WinDefend|Sense)$'
`$o.stoppedServices = @(Get-CimInstance Win32_Service -Filter "StartMode='Auto' AND State<>'Running'" | Where-Object { `$_.Name -notmatch `$skip } | ForEach-Object { [ordered]@{ name = `$_.Name; displayName = `$_.DisplayName; state = [string]`$_.State } })
`$ev = @()
foreach (`$log in 'System', 'Application', 'Microsoft-Windows-FailoverClustering/Operational') {
    try { `$ev += @(Get-WinEvent -FilterHashtable @{ LogName = `$log; Level = 1, 2; StartTime = `$st; EndTime = `$en } -MaxEvents 400 -ErrorAction Stop) } catch { }
}
`$o.eventCounts = [ordered]@{ critical = @(`$ev | Where-Object { `$_.Level -eq 1 }).Count; error = @(`$ev | Where-Object { `$_.Level -eq 2 }).Count }
`$o.events = @(`$ev | Group-Object LogName, ProviderName, Id | Sort-Object Count -Descending | Select-Object -First 15 | ForEach-Object {
    `$f = `$_.Group | Sort-Object TimeCreated | Select-Object -First 1
    `$m = [string]`$f.Message; if (`$m.Length -gt 220) { `$m = `$m.Substring(0, 220) + '...' }
    [ordered]@{ log = `$f.LogName; source = `$f.ProviderName; id = `$f.Id; level = `$(if (`$f.Level -eq 1) { 'Critical' } else { 'Error' }); count = `$_.Count; first = `$f.TimeCreated.ToUniversalTime().ToString('o'); message = (`$m -replace '\s+', ' ') } })
Write-Output ('__SSP_JSON=' + (`$o | ConvertTo-Json -Depth 5 -Compress))
"@
    }
    return @"
since='$($Start.UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss')) UTC'; until='$($End.UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss')) UTC'
echo "__SSP_KV:os=`$( . /etc/os-release 2>/dev/null; echo "`${PRETTY_NAME:-linux}")"
echo "__SSP_KV:uptimeHours=`$(awk '{printf "%.1f", `$1/3600}' /proc/uptime)"
echo "__SSP_KV:memoryUsedPercent=`$(awk '/MemTotal/{t=`$2}/MemAvailable/{a=`$2}END{if(t>0)printf "%.1f",(t-a)/t*100}' /proc/meminfo)"
echo "__SSP_KV:load1=`$(cut -d' ' -f1 /proc/loadavg)"
echo "__SSP_KV:cpus=`$(nproc 2>/dev/null || echo 1)"
pr=''
[ -f /var/run/reboot-required ] && pr='reboot-required'
if command -v needs-restarting >/dev/null 2>&1; then needs-restarting -r >/dev/null 2>&1 || pr="`${pr:+`$pr,}needs-restarting"; fi
echo "__SSP_KV:pendingReboot=`$pr"
df -P -k -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null | awk 'NR>1 && `$2>0 {printf "DISK|%s|%.1f|%.1f|%.1f\n", `$6, `$2/1048576, `$4/1048576, `$4/`$2*100}' || true
ps -eo comm,rss,pcpu --sort=-rss 2>/dev/null | awk 'NR>1 && NR<=7 {printf "PROC|%s|%d|%s\n", `$1, `$2/1024, `$3}' || true
if command -v systemctl >/dev/null 2>&1; then systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print "SVC|"`$1}' || true; fi
if command -v journalctl >/dev/null 2>&1; then
  journalctl -p 3 --since "`$since" --until "`$until" -o short-iso --no-pager -q 2>/dev/null | awk '{ id=`$3; sub(/\[.*`$/,"",id); sub(/:`$/,"",id); c[id]++; if(!(id in f)){ f[id]=`$1; m=`$0; sub(/^[^ ]+ [^ ]+ [^ ]+ /,"",m); msg[id]=substr(m,1,200) } } END { for (k in c) printf "EVT|%s|%d|%s|%s\n", k, c[k], f[k], msg[k] }' || true
  echo "__SSP_KV:journalCritical=`$(journalctl -p 2 --since "`$since" --until "`$until" -q --no-pager 2>/dev/null | wc -l)"
fi
exit 0
"@
}

function ConvertFrom-PortalGuestDiagOutput {
    <# Normalises the guest output (Windows JSON or Linux KV / pipe lines) to one ordered dictionary. Exposed for tests. #>
    [CmdletBinding()]
    param([ValidateSet('windows', 'linux')] [string] $Family, [AllowEmptyString()] [string] $Output)
    $d = Get-PortalGuestData -Output $Output
    if ($Family -eq 'windows') { return $d }
    $o = [ordered]@{ family = 'linux'; os = [string](Get-DiagVal $d 'os' ''); uptimeHours = [double](Get-DiagVal $d 'uptimeHours' 0)
                     memoryUsedPercent = [double](Get-DiagVal $d 'memoryUsedPercent' 0)
                     cpuLoadPercent = $(if ([double](Get-DiagVal $d 'cpus' 1) -gt 0) { [math]::Round(100 * [double](Get-DiagVal $d 'load1' 0) / [double](Get-DiagVal $d 'cpus' 1)) } else { 0 })
                     pendingReboot = @(([string](Get-DiagVal $d 'pendingReboot' '')).Split(',') | Where-Object { $_ })
                     disks = @(); topProcesses = @(); stoppedServices = @(); events = @()
                     eventCounts = [ordered]@{ critical = [int](Get-DiagVal $d 'journalCritical' 0); error = 0 } }
    $disks = [System.Collections.Generic.List[object]]::new(); $procs = [System.Collections.Generic.List[object]]::new()
    $svcs = [System.Collections.Generic.List[object]]::new(); $evts = [System.Collections.Generic.List[object]]::new()
    foreach ($l in @($Output -split "\r?\n")) {
        $f = $l.Split('|')
        switch ($f[0]) {
            'DISK' { if ($f.Count -ge 5) { $disks.Add([ordered]@{ name = $f[1]; label = ''; sizeGB = [double]$f[2]; freeGB = [double]$f[3]; freePercent = [double]$f[4] }) } }
            'PROC' { if ($f.Count -ge 4) { $procs.Add([ordered]@{ name = $f[1]; memoryMB = [int]$f[2]; cpuSeconds = $null; cpuPercent = [double]$f[3] }) } }
            'SVC'  { if ($f.Count -ge 2) { $svcs.Add([ordered]@{ name = $f[1]; displayName = $f[1]; state = 'failed' }) } }
            'EVT'  { if ($f.Count -ge 5) { $evts.Add([ordered]@{ log = 'journal'; source = $f[1]; id = ''; level = 'Error'; count = [int]$f[2]; first = $f[3]; message = ($f[4..($f.Count - 1)] -join '|') }) } }
        }
    }
    $o.disks = $disks.ToArray(); $o.topProcesses = $procs.ToArray(); $o.stoppedServices = $svcs.ToArray()
    $o.events = @($evts | Sort-Object { $_.count } -Descending | Select-Object -First 15)
    $o.eventCounts.error = [int](($evts | Measure-Object -Property { $_.count } -Sum).Sum)
    return $o
}

function Get-PortalGuestDiagnostics {
    <# Runs the diagnostic script in the guest (read-only). Returns the normalised dictionary. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $VM, [Parameter(Mandatory)] $Server, [Parameter(Mandatory)] [pscredential] $Credential, [Parameter(Mandatory)] $Window)
    $g = Resolve-PortalGuestVM -Name ([string]$VM.Name) -Server $Server -TimeoutSeconds 60
    if (-not $g.Family) { throw "The guest OS family of $($VM.Name) could not be determined (VMware Tools)." }
    $script = New-PortalGuestDiagScript -Family $g.Family -Start $Window.Start -End $Window.End
    $type = if ($g.Family -eq 'windows') { 'PowerShell' } else { 'Bash' }
    $out = Invoke-PortalGuestScript -VM $g.VM -Credential $Credential -ScriptText $script -Type $type -Server $Server -TimeoutSeconds 240 -Description 'read-only diagnostics'
    $d = ConvertFrom-PortalGuestDiagOutput -Family $g.Family -Output $out
    if (-not $d.Contains('os') -or -not $d['os']) { $d['os'] = $g.OSFullName }
    return $d
}

#endregion

#region Aria Operations -------------------------------------------------------------------------------------

$script:AriaPatterns = @{
    VirtualMachine = '^(cpu\|(readyPct|costopPct|usage_average|demandPct|swapwaitPct)|mem\|(balloonPct|swapped_average|host_contentionPct|usage_average|compressed)|virtualDisk:Aggregate of all instances\|(totalReadLatency_average|totalWriteLatency_average|commandsAborted_summation)|datastore\|(totalLatency_max|demand_oio)|net\|(droppedPct|dropped)|diskspace\|snapshot)'
    HostSystem     = '^(cpu\|(readyPct|costopPct|usage_average|demandPct)|mem\|(host_usagePct|balloonPct|usage_average)|net\|(droppedPct|dropped)|datastore\|(totalLatency_max|maxTotalLatency_latest)|disk\|(totalLatency_average|kernelLatency_average|deviceLatency_average|commandsAborted_summation))'
}

function Get-PortalAriaEvidence {
    <#
    .SYNOPSIS VM (and host) in Aria Operations: badges, parents, stats (MAX rollup) and alerts that overlap the window.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Aria, [Parameter(Mandatory)] [string] $VMName, [Parameter(Mandatory)] $Window, [bool] $IncludeHost = $true, [int] $IntervalMinutes = 5)
    $vm = Find-PortalAriaResource -Aria $Aria -Name $VMName -ResourceKind VirtualMachine
    if (-not $vm) { throw "VM '$VMName' was not found in Aria Operations ($($Aria.Endpoint))." }
    $parents = @(Get-PortalAriaRelated -Aria $Aria -ResourceId $vm.Id -Relation parents)
    $esx = $parents | Where-Object { $_.Kind -eq 'HostSystem' } | Select-Object -First 1
    $dss = @($parents | Where-Object { $_.Kind -eq 'Datastore' })
    $badges = Get-PortalAriaBadges -Aria $Aria -ResourceId $vm.Id
    $targets = @([pscustomobject]@{ Res = $vm; Pattern = $script:AriaPatterns.VirtualMachine; Label = "VM $($vm.Name)" })
    if ($IncludeHost -and $esx) { $targets += [pscustomobject]@{ Res = $esx; Pattern = $script:AriaPatterns.HostSystem; Label = "Host $($esx.Name)" } }
    $stats = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $targets) {
        $keys = @(Get-PortalAriaStatKey -Aria $Aria -ResourceId $t.Res.Id -Pattern $t.Pattern)
        if (-not $keys.Count) { Write-DiagLog -Level WARN "Aria: no matching stat keys for $($t.Label)."; continue }
        foreach ($r in @(Get-PortalAriaStats -Aria $Aria -ResourceId $t.Res.Id -StatKey $keys -Start $Window.Start -End $Window.End -RollUp MAX -IntervalMinutes $IntervalMinutes)) {
            $stats.Add([pscustomobject]@{ Object = $t.Label; StatKey = $r.StatKey; Time = $r.Time; Value = [math]::Round($r.Value, 2) })
        }
    }
    $ids = @($vm.Id) + @(if ($IncludeHost -and $esx) { $esx.Id })
    $alerts = @(Get-PortalAriaAlerts -Aria $Aria -ResourceId $ids -Start $Window.Start -End $Window.End) | ForEach-Object {
        $_ | Add-Member -NotePropertyName Object -NotePropertyValue $(if ($_.ResourceId -eq $vm.Id) { "VM $($vm.Name)" } else { "Host $($esx.Name)" }) -PassThru
    }
    return [pscustomobject]@{
        Resource   = $vm
        Host       = $esx
        Datastores = $dss
        Parents    = $parents
        Badges     = $badges
        Stats      = $stats.ToArray()
        Alerts     = @($alerts)
        Link       = Get-PortalAriaResourceUrl -Aria $Aria -ResourceId $vm.Id
    }
}

function Get-PortalAriaStatSummary {
    <# One row per object + stat key: max, average, time of max. #>
    param([object[]] $Stats)
    foreach ($g in @($Stats | Group-Object Object, StatKey)) {
        $max = $g.Group | Sort-Object Value -Descending | Select-Object -First 1
        [pscustomobject]@{ Source = 'Aria Operations'; Object = $max.Object; Metric = $max.StatKey; Unit = ''
                           Max = [double]$max.Value; Avg = [math]::Round(($g.Group | Measure-Object Value -Average).Average, 2); PeakAt = $max.Time; Samples = $g.Count }
    }
}

#endregion

#region Analysis --------------------------------------------------------------------------------------------

function Get-PortalTroubleshootFindings {
    <#
    .SYNOPSIS Ranked findings from the collected data. Each: Severity (CRITICAL | WARN | INFO), Title, Evidence, Sources, Score.
    .PARAMETER Thresholds  operations.troubleshooting.
    #>
    [CmdletBinding()]
    param($Vsphere, $Guest, $Aria, $Thresholds, $Window, [double] $MinDatastoreFreePercent = 15)
    $th = { param($k, $d) $v = Get-DiagVal $Thresholds $k $null; if ($null -eq $v -or "$v" -eq '') { $d } else { [double]$v } }
    $readyW = & $th 'cpuReadyWarnPercent' 5; $readyC = & $th 'cpuReadyCriticalPercent' 10; $coW = & $th 'coStopWarnPercent' 3
    $latW = & $th 'diskLatencyWarnMs' 20; $latC = & $th 'diskLatencyCriticalMs' 30
    $dfW = & $th 'guestDiskFreeWarnPercent' 20; $dfC = & $th 'guestDiskFreeCriticalPercent' 10; $gmW = & $th 'guestMemoryWarnPercent' 90
    $list = [System.Collections.Generic.List[object]]::new()
    $add = {
        param($sev, $title, $evidence, [string[]] $sources, [string] $key)
        $existing = if ($key) { $list | Where-Object { $_.Key -eq $key } | Select-Object -First 1 } else { $null }
        if ($existing) {
            foreach ($s in $sources) { if ($existing.Sources -notcontains $s) { $existing.Sources += $s } }
            $existing.Evidence = "$($existing.Evidence) $evidence".Trim()
            if ($sev -eq 'CRITICAL') { $existing.Severity = 'CRITICAL' }
            return
        }
        $list.Add([pscustomobject]@{ Key = $key; Severity = $sev; Title = $title; Evidence = $evidence; Sources = @($sources) })
    }
    $fmtT = { param($t) if ($t) { ([DateTimeOffset]$t).UtcDateTime.ToString('MM-dd HH:mm') + ' UTC' } else { '' } }
    $peak = { param($series, $id) $s = @($series | Where-Object { $_.Id -eq $id }) | Select-Object -First 1; if ($s -and @($s.Points).Count) { @($s.Points) | Sort-Object Value -Descending | Select-Object -First 1 } else { $null } }

    if ($Vsphere) {
        $ser = @($Vsphere.Perf.Series)
        $p = & $peak $ser 'cpu.ready.summation'
        if ($p -and $p.Value -ge $readyW) { & $add $(if ($p.Value -ge $readyC) { 'CRITICAL' } else { 'WARN' }) "CPU contention: ready $($p.Value) % at peak" "CPU ready peaked at $($p.Value) % ($(& $fmtT $p.Time)) with $($Vsphere.NumCpu) vCPU; host $($Vsphere.Host)." @('vSphere') 'cpu-ready' }
        $p = & $peak $ser 'cpu.costop.summation'
        if ($p -and $p.Value -ge $coW) { & $add 'WARN' "vCPU co-scheduling: co-stop $($p.Value) %" "Co-stop peaked at $($p.Value) % ($(& $fmtT $p.Time)); consider fewer vCPU." @('vSphere') 'costop' }
        $bal = & $peak $ser 'mem.vmmemctl.average'; $swp = & $peak $ser 'mem.swapped.average'; $sin = & $peak $ser 'mem.swapinRate.average'
        if (($bal -and $bal.Value -gt 0) -or ($swp -and $swp.Value -gt 0)) {
            & $add $(if ($sin -and $sin.Value -gt 0) { 'CRITICAL' } else { 'WARN' }) 'Host memory pressure on the VM (balloon / swap)' ("Balloon max $(if ($bal) { $bal.Value } else { 0 }) MB, swapped max $(if ($swp) { $swp.Value } else { 0 }) MB" + $(if ($sin -and $sin.Value -gt 0) { ", swap-in $($sin.Value) KBps (active swapping)." } else { '.' })) @('vSphere') 'mem-pressure'
        }
        $lat = @('disk.maxTotalLatency.latest', 'virtualDisk.totalWriteLatency.average', 'virtualDisk.totalReadLatency.average' | ForEach-Object { & $peak $ser $_ } | Where-Object { $_ }) | Sort-Object Value -Descending | Select-Object -First 1
        if ($lat -and $lat.Value -ge $latW) {
            $dsNames = (@($Vsphere.Datastores | ForEach-Object Name) -join ', ')
            & $add $(if ($lat.Value -ge $latC) { 'CRITICAL' } else { 'WARN' }) "Storage latency peak: $($lat.Value) ms" "Disk latency peaked at $($lat.Value) ms ($(& $fmtT $lat.Time)) on $dsNames (threshold $latW ms)." @('vSphere') 'disk-latency'
            # Snapshot / backup activity around the peak (+- 30 min) is the usual cause.
            $snapEv = @($Vsphere.Events | Where-Object { $_.Category -eq 'Snapshot' -and [math]::Abs(($_.Time - $lat.Time).TotalMinutes) -le 30 })
            if ($snapEv.Count) {
                $ev = ($snapEv | Select-Object -First 3 | ForEach-Object { "$(& $fmtT $_.Time) $($_.Message)" }) -join '; '
                & $add 'CRITICAL' 'Snapshot / backup activity during the latency peak' "$ev" @('vSphere') 'snapshot-io'
            }
        }
        $hl = if ($Vsphere.HostPerf) { & $peak @($Vsphere.HostPerf.Series) 'disk.maxTotalLatency.latest' } else { $null }
        if ($hl -and $hl.Value -ge $latW) { & $add $(if ($hl.Value -ge $latC) { 'CRITICAL' } else { 'WARN' }) "Storage latency peak: $($hl.Value) ms" "Host $($Vsphere.Host) disk latency peaked at $($hl.Value) ms ($(& $fmtT $hl.Time)): the datastore or path is affected, not only this VM." @('vSphere') 'disk-latency' }
        $drop = @('net.droppedRx.summation', 'net.droppedTx.summation' | ForEach-Object { & $peak $ser $_ } | Where-Object { $_ -and $_.Value -gt 0 })
        if ($drop.Count) { & $add 'WARN' 'Network packets dropped' ("Dropped packets peaked at $(($drop | Measure-Object Value -Maximum).Maximum) per sample.") @('vSphere') 'net-drops' }
        foreach ($s in @($Vsphere.Snapshots)) {
            $age = [math]::Round(([DateTimeOffset]::UtcNow - $s.Created).TotalDays, 1)
            & $add $(if ($age -gt 3) { 'WARN' } else { 'INFO' }) 'Snapshot present on the VM' "Snapshot '$($s.Name)' $($s.SizeGB) GB, $age day(s) old." @('vSphere') 'snapshot-present'
        }
        foreach ($cat in 'Migration', 'HA', 'Connectivity', 'Power', 'Reconfigure') {
            $ev = @($Vsphere.Events | Where-Object Category -eq $cat)
            if (-not $ev.Count) { continue }
            $sev = if ($cat -in 'HA', 'Connectivity') { 'WARN' } else { 'INFO' }
            & $add $sev "$cat events in the window ($($ev.Count))" (($ev | Select-Object -First 3 | ForEach-Object { "$(& $fmtT $_.Time) $($_.Message)" }) -join '; ') @('vSphere') "ev-$cat"
        }
        foreach ($d in @($Vsphere.Datastores | Where-Object { $null -ne $_.FreePercent -and $_.FreePercent -lt $MinDatastoreFreePercent })) {
            & $add 'WARN' "Datastore $($d.Name) low on space ($($d.FreePercent) % free)" "$($d.FreeGB) GB free of $($d.CapacityGB) GB." @('vSphere') "ds-$($d.Name)"
        }
        if ($Vsphere.Tools -and $Vsphere.Tools -notmatch 'guestToolsRunning') { & $add 'WARN' 'VMware Tools not running' "Tools status: $($Vsphere.Tools)." @('vSphere') 'tools' }
    }

    if ($Guest) {
        foreach ($d in @(Get-DiagVal $Guest 'disks' @())) {
            $fp = [double](Get-DiagVal $d 'freePercent' 100)
            if ($fp -lt $dfW) { & $add $(if ($fp -lt $dfC) { 'CRITICAL' } else { 'WARN' }) "Guest disk $(Get-DiagVal $d 'name' '') low on space ($fp % free)" "$(Get-DiagVal $d 'freeGB' 0) GB free of $(Get-DiagVal $d 'sizeGB' 0) GB." @('Guest OS') "gdisk-$(Get-DiagVal $d 'name' '')" }
        }
        $mp = [double](Get-DiagVal $Guest 'memoryUsedPercent' 0)
        if ($mp -ge $gmW) {
            $top = @(Get-DiagVal $Guest 'topProcesses' @()) | Select-Object -First 1
            & $add 'WARN' "Guest memory in use $mp %" "Top process: $(Get-DiagVal $top 'name' '?') $(Get-DiagVal $top 'memoryMB' '?') MB (check whether it is by design, e.g. a database cache)." @('Guest OS') 'gmem'
        }
        $pr = @(Get-DiagVal $Guest 'pendingReboot' @())
        if ($pr.Count) { & $add 'WARN' 'Reboot pending in the guest' "Pending: $($pr -join ', ')." @('Guest OS') 'greboot' }
        $svc = @(Get-DiagVal $Guest 'stoppedServices' @())
        if ($svc.Count) { & $add 'WARN' "$($svc.Count) automatic service(s) not running" (($svc | Select-Object -First 5 | ForEach-Object { Get-DiagVal $_ 'name' '' }) -join ', ') @('Guest OS') 'gsvc' }
        $ec = Get-DiagVal $Guest 'eventCounts' @{}
        $crit = [int](Get-DiagVal $ec 'critical' 0); $errs = [int](Get-DiagVal $ec 'error' 0)
        if ($crit + $errs -gt 0) {
            $top = (@(Get-DiagVal $Guest 'events' @()) | Select-Object -First 3 | ForEach-Object { "$(Get-DiagVal $_ 'source' '') $(Get-DiagVal $_ 'id' '') x$(Get-DiagVal $_ 'count' 1)" }) -join '; '
            & $add $(if ($crit -gt 0) { 'CRITICAL' } else { 'WARN' }) "Guest logged $crit critical / $errs error event(s) in the window" "Most frequent: $top." @('Guest OS') 'gevents'
        }
        $up = [double](Get-DiagVal $Guest 'uptimeHours' 99999)
        if ($Window -and $up -lt (([DateTimeOffset]::UtcNow - $Window.Start).TotalHours)) { & $add 'INFO' "Guest restarted during or after the window (uptime $up h)" 'Correlate with power events and the incident time.' @('Guest OS') 'grestart' }
    }

    if ($Aria) {
        foreach ($a in @($Aria.Alerts)) {
            $sev = switch -Regex ($a.Level) { 'CRITICAL' { 'CRITICAL' } 'IMMEDIATE|WARNING' { 'WARN' } default { 'INFO' } }
            & $add $sev "Aria alert: $($a.Name)" "$($a.Object), $($a.Level), $($a.Status), since $(& $fmtT $a.Started)." @('Aria Operations') "aa-$($a.Name)"
        }
        $h = Get-DiagVal $Aria.Badges 'Health'
        if ($null -ne $h -and $h -lt 75) { & $add $(if ($h -lt 50) { 'CRITICAL' } else { 'WARN' }) "Aria health score $h" "Risk $(Get-DiagVal $Aria.Badges 'Risk' '-'), efficiency $(Get-DiagVal $Aria.Badges 'Efficiency' '-')." @('Aria Operations') 'aria-health' }
        # Aria peaks confirm (and source-tag) the vSphere findings.
        $map = @{ 'cpu\|readyPct' = 'cpu-ready'; 'cpu\|costopPct' = 'costop'; 'mem\|(balloonPct|swapped)' = 'mem-pressure'; 'Latency' = 'disk-latency'; 'dropped' = 'net-drops' }
        foreach ($k in $map.Keys) {
            $hit = @($Aria.Stats | Where-Object { $_.StatKey -match $k -and $_.Value -gt 0 })
            if (-not $hit.Count) { continue }
            $f = $list | Where-Object { $_.Key -eq $map[$k] } | Select-Object -First 1
            if ($f -and $f.Sources -notcontains 'Aria Operations') {
                $mx = $hit | Sort-Object Value -Descending | Select-Object -First 1
                $f.Sources += 'Aria Operations'; $f.Evidence = "$($f.Evidence) Aria $($mx.StatKey) max $($mx.Value) ($(& $fmtT $mx.Time))."
            }
        }
    }

    $w = @{ CRITICAL = 300; WARN = 200; INFO = 100 }
    $rank = 0
    return @($list | ForEach-Object { $_ | Add-Member -NotePropertyName Score -NotePropertyValue ($w[$_.Severity] + 10 * @($_.Sources).Count) -Force -PassThru } |
        Sort-Object @{ Expression = 'Score'; Descending = $true }, Title | ForEach-Object { $rank++; $_ | Add-Member -NotePropertyName Rank -NotePropertyValue $rank -Force -PassThru })
}

#endregion

Export-ModuleMember -Function Resolve-PortalTimeWindow, Get-PortalStatInterval, Get-PortalPerfSeries, Get-PortalSeriesSummary, Get-PortalEventCategory, Get-PortalEntityEvents,
    Get-PortalVsphereEvidence, New-PortalGuestDiagScript, ConvertFrom-PortalGuestDiagOutput, Get-PortalGuestDiagnostics, Get-PortalAriaEvidence, Get-PortalAriaStatSummary,
    Get-PortalTroubleshootFindings
