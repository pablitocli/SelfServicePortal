#Requires -Version 7.2
<#
.SYNOPSIS
    Portal.WindowsBuild - guest step scripts and CSV validation for the batch Windows build (vm-windows-batch).
.DESCRIPTION
    The build is driven by the portal job, step by step, through VMware Tools (Portal.Guest). Unlike a self-running
    bootstrap, no configuration file with passwords is ever written in the guest: secrets (domain join, local
    account) are passed only in the script of the step that needs them (sensitive, never logged) and nothing is left
    on disk. The only file written in the guest is the Windows Update runner (no secret), removed at cleanup.

    Every script starts with a "# SSP-STEP:<NAME>" marker (used by the offline tests) and prints __SSP_KV: lines.
    Scripts run in Windows PowerShell 5.1.
#>

Set-StrictMode -Version Latest

function Get-WbVal { param($O, [string] $N, $D = $null) if ($null -eq $O) { return $D }; if ($O -is [System.Collections.IDictionary]) { if ($O.Contains($N) -and $null -ne $O[$N] -and "$($O[$N])" -ne '') { return $O[$N] } return $D }; $p = $O.PSObject.Properties[$N]; if ($p -and $null -ne $p.Value -and "$($p.Value)" -ne '') { $p.Value } else { $D } }
function ConvertTo-WbLiteral { param([AllowEmptyString()] [string] $V) return ConvertTo-PortalGuestLiteral $V }
function ConvertTo-WbArray { param([string[]] $V) return '@(' + ((@($V) | Where-Object { $_ } | ForEach-Object { ConvertTo-PortalGuestLiteral $_ }) -join ', ') + ')' }

#region CSV ---------------------------------------------------------------------------------------------------

$script:Columns = 'VMName', 'CPU', 'MemoryGB', 'DiskGB', 'Portgroup', 'IP', 'PrefixLength', 'Gateway', 'DNS', 'ExtraDisksGB', 'DriveLetters', 'Hostname'

function Test-WbIPv4 { param([string] $V) $ip = $null; return ($V -match '^\d{1,3}(\.\d{1,3}){3}$' -and [System.Net.IPAddress]::TryParse($V, [ref]$ip)) }
function ConvertTo-WbUInt32 { param([string] $Ip) $b = ([System.Net.IPAddress]::Parse($Ip)).GetAddressBytes(); [array]::Reverse($b); return [BitConverter]::ToUInt32($b, 0) }

function ConvertFrom-PortalBuildCsv {
    <#
    .SYNOPSIS Parses and validates the VM list (CSV with a header line). Returns @{ Rows; Errors (per row) }.
    .DESCRIPTION
        Columns: VMName, CPU, MemoryGB, DiskGB (optional, primary disk; empty = template size), Portgroup,
        IP (empty = DHCP), PrefixLength, Gateway, DNS (; separated), ExtraDisksGB (; separated), DriveLetters
        (; separated, same order as the extra disks; default D, E, F...), Hostname (optional, default = VMName).
        Lines starting with # are comments.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Text, [int] $MaxRows = 20, [string[]] $DefaultDns = @())
    $lines = @($Text -split "\r?\n" | Where-Object { $_.Trim() -and $_.Trim() -notlike '#*' })
    if ($lines.Count -lt 2) { throw 'The VM list needs a header line and at least one VM line.' }
    $rows = @($lines | ConvertFrom-Csv)
    $header = @($lines[0] -split ',' | ForEach-Object { $_.Trim() })
    $unknown = @($header | Where-Object { $script:Columns -notcontains $_ })
    if ($unknown.Count) { throw "Unknown column(s): $($unknown -join ', '). Allowed: $($script:Columns -join ', ')." }
    foreach ($c in 'VMName', 'CPU', 'MemoryGB', 'Portgroup') { if ($header -notcontains $c) { throw "Column '$c' is required." } }
    if ($rows.Count -gt $MaxRows) { throw "At most $MaxRows VMs per request ($($rows.Count) given)." }
    $out = [System.Collections.Generic.List[object]]::new(); $errors = [ordered]@{}
    $i = 0
    foreach ($r in $rows) {
        $i++; $e = [System.Collections.Generic.List[string]]::new()
        $g = { param($n) $p = $r.PSObject.Properties[$n]; if ($p -and $null -ne $p.Value) { ([string]$p.Value).Trim() } else { '' } }
        $name = & $g 'VMName'
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,62}$') { $e.Add("VMName '$name' is not valid.") }
        $hostName = & $g 'Hostname'; if (-not $hostName) { $hostName = $name }
        if ($hostName -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$' -or $hostName -match '^\d+$') { $e.Add("Host name '$hostName' must be 1-15 letters, digits or - (NetBIOS); set the Hostname column when the VM name is longer.") }
        $cpu = 0; if (-not [int]::TryParse((& $g 'CPU'), [ref]$cpu) -or $cpu -lt 1 -or $cpu -gt 64) { $e.Add('CPU must be 1-64.') }
        $mem = 0; if (-not [int]::TryParse((& $g 'MemoryGB'), [ref]$mem) -or $mem -lt 1 -or $mem -gt 1024) { $e.Add('MemoryGB must be 1-1024.') }
        $disk = 0; $ds = & $g 'DiskGB'; if ($ds -and (-not [int]::TryParse($ds, [ref]$disk) -or $disk -lt 20 -or $disk -gt 4096)) { $e.Add('DiskGB must be 20-4096 (or empty for the template size).') }
        $pg = & $g 'Portgroup'; if (-not $pg -or $pg.Length -gt 80) { $e.Add('Portgroup is required.') }
        $ip = & $g 'IP'; $prefix = 0; $gw = & $g 'Gateway'
        $dns = @((& $g 'DNS') -split '[;\s]+' | Where-Object { $_ }); if (-not $dns.Count) { $dns = @($DefaultDns) }
        if ($ip) {
            if (-not (Test-WbIPv4 $ip)) { $e.Add("IP '$ip' is not valid.") }
            if (-not [int]::TryParse((& $g 'PrefixLength'), [ref]$prefix) -or $prefix -lt 8 -or $prefix -gt 30) { $e.Add('PrefixLength must be 8-30 for a static IP.') }
            if (-not (Test-WbIPv4 $gw)) { $e.Add("Gateway '$gw' is not valid.") }
            elseif ((Test-WbIPv4 $ip) -and $prefix -ge 8) {
                $mask = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $prefix))
                if (((ConvertTo-WbUInt32 $ip) -band $mask) -ne ((ConvertTo-WbUInt32 $gw) -band $mask)) { $e.Add("Gateway $gw is not in $ip/$prefix.") }
                if ($ip -eq $gw) { $e.Add('IP and gateway are the same.') }
            }
            if (-not $dns.Count) { $e.Add('DNS servers are required for a static IP (column DNS or site DNS servers).') }
            foreach ($d in $dns) { if (-not (Test-WbIPv4 $d)) { $e.Add("DNS server '$d' is not valid.") } }
        }
        $extra = @(); foreach ($x in @((& $g 'ExtraDisksGB') -split '[;\s]+' | Where-Object { $_ })) { $n = 0; if (-not [int]::TryParse($x, [ref]$n) -or $n -lt 1 -or $n -gt 16384) { $e.Add("Extra disk size '$x' is not valid (1-16384 GB).") } else { $extra += $n } }
        if ($extra.Count -gt 12) { $e.Add('At most 12 extra disks.') }
        $letters = @((& $g 'DriveLetters').ToUpperInvariant() -split '[;\s:,]+' | Where-Object { $_ })
        foreach ($l in $letters) { if ($l -notmatch '^[D-Y]$') { $e.Add("Drive letter '$l' is not valid (D-Y).") } }
        if ($letters.Count -gt $extra.Count) { $e.Add('More drive letters than extra disks.') }
        if (@($letters | Select-Object -Unique).Count -ne $letters.Count) { $e.Add('A drive letter is repeated.') }
        if (-not $letters.Count -and $extra.Count) {
            $letters = @([char[]](68..89) | ForEach-Object { [string]$_ } | Select-Object -First $extra.Count)
        }
        elseif ($letters.Count -lt $extra.Count) {
            $free = @([char[]](68..89) | ForEach-Object { [string]$_ } | Where-Object { $letters -notcontains $_ })
            $letters = @($letters) + @($free | Select-Object -First ($extra.Count - $letters.Count))
        }
        $out.Add([pscustomobject]@{ Row = $i; VMName = $name; Hostname = $hostName.ToUpperInvariant(); CPU = $cpu; MemoryGB = $mem; DiskGB = $disk; Portgroup = $pg
                                    IP = $ip; PrefixLength = $prefix; Gateway = $gw; DNS = @($dns); ExtraDisksGB = @($extra); DriveLetters = @($letters) })
        if ($e.Count) { $errors["$i"] = @($e) }
    }
    foreach ($dup in @($out | Group-Object VMName | Where-Object Count -gt 1)) { foreach ($x in $dup.Group) { $errors["$($x.Row)"] = @(@($errors["$($x.Row)"]) + "VM name $($dup.Name) is listed twice." | Where-Object { $_ }) } }
    foreach ($dup in @($out | Where-Object IP | Group-Object IP | Where-Object Count -gt 1)) { foreach ($x in $dup.Group) { $errors["$($x.Row)"] = @(@($errors["$($x.Row)"]) + "IP $($dup.Name) is used twice." | Where-Object { $_ }) } }
    foreach ($dup in @($out | Group-Object Hostname | Where-Object Count -gt 1)) { foreach ($x in $dup.Group) { $errors["$($x.Row)"] = @(@($errors["$($x.Row)"]) + "Host name $($dup.Name) is used twice." | Where-Object { $_ }) } }
    return [pscustomobject]@{ Rows = $out.ToArray(); Errors = $errors }
}

#endregion

#region Guest step scripts --------------------------------------------------------------------------------------

function New-WbBootScript {
    return @'
# SSP-STEP:BOOT
$os = Get-CimInstance Win32_OperatingSystem
Write-Output ('__SSP_KV:boot=' + $os.LastBootUpTime.ToUniversalTime().ToString('o'))
Write-Output ('__SSP_KV:name=' + $env:COMPUTERNAME)
'@
}

function New-WbNetworkScript {
    param([Parameter(Mandatory)] $Row)
    return @"
# SSP-STEP:NETWORK
`$ip = $(ConvertTo-WbLiteral $Row.IP); `$prefix = $([int]$Row.PrefixLength); `$gw = $(ConvertTo-WbLiteral $Row.Gateway); `$dns = $(ConvertTo-WbArray $Row.DNS)
`$a = Get-NetAdapter | Where-Object Status -eq 'Up' | Sort-Object ifIndex | Select-Object -First 1
if (-not `$a) { throw 'No active network adapter.' }
`$cur = @(Get-NetIPAddress -InterfaceIndex `$a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { `$_.IPAddress -eq `$ip })
if (-not `$cur.Count) {
    Set-NetIPInterface -InterfaceIndex `$a.ifIndex -Dhcp Disabled -ErrorAction SilentlyContinue
    Get-NetIPAddress -InterfaceIndex `$a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:`$false -ErrorAction SilentlyContinue
    Get-NetRoute -InterfaceIndex `$a.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:`$false -ErrorAction SilentlyContinue
    `$null = New-NetIPAddress -InterfaceIndex `$a.ifIndex -IPAddress `$ip -PrefixLength `$prefix -DefaultGateway `$gw
}
Set-DnsClientServerAddress -InterfaceIndex `$a.ifIndex -ServerAddresses `$dns
Start-Sleep -Seconds 4
Write-Output ('__SSP_KV:gateway=' + [string](Test-Connection -ComputerName `$gw -Count 2 -Quiet))
"@
}

function New-WbRenameScript {
    param([Parameter(Mandatory)] [string] $Hostname)
    return @"
# SSP-STEP:RENAME
`$n = $(ConvertTo-WbLiteral $Hostname)
if (`$env:COMPUTERNAME -eq `$n) { Write-Output '__SSP_KV:rename=done'; return }
`$pending = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -ErrorAction SilentlyContinue).ComputerName
if (`$pending -ne `$n) {
    # Rename-Computer can hang on DNS / DC lookups: run it in a job and check the staged name.
    `$j = Start-Job -ScriptBlock { param(`$x) Rename-Computer -NewName `$x -Force -WarningAction SilentlyContinue } -ArgumentList `$n
    `$null = Wait-Job `$j -Timeout 90
    `$pending = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -ErrorAction SilentlyContinue).ComputerName
}
if (`$pending -eq `$n) { Write-Output '__SSP_KV:rename=reboot' } else { throw "Rename to `$n was not staged." }
"@
}

function New-WbUpdateStartScript {
    <# Writes the Windows Update runner (WUA COM API, no PSGallery needed, no secret) and starts it as SYSTEM. #>
    return @'
# SSP-STEP:UPDATES_START
$dir = Join-Path $env:ProgramData 'SSP'
$null = New-Item -ItemType Directory -Path $dir -Force
$au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
if (-not (Test-Path $au)) { $null = New-Item -Path $au -Force }
Set-ItemProperty -Path $au -Name NoAutoUpdate -Value 1 -Type DWord
$runner = @"
`$status = Join-Path `$env:ProgramData 'SSP\wu-status.json'
function Save([hashtable] `$s) { `$s.at = (Get-Date).ToUniversalTime().ToString('o'); (`$s | ConvertTo-Json -Compress) | Set-Content -Path `$status -Encoding UTF8 }
try {
    Save @{ state = 'searching' }
    `$session = New-Object -ComObject Microsoft.Update.Session
    `$result = `$session.CreateUpdateSearcher().Search("IsInstalled=0 and Type='Software' and IsHidden=0")
    `$list = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach (`$u in `$result.Updates) { if (-not `$u.EulaAccepted) { `$u.AcceptEula() }; `$null = `$list.Add(`$u) }
    if (`$list.Count -eq 0) { Save @{ state = 'done'; found = 0; installed = 0; rebootRequired = `$false }; exit }
    Save @{ state = 'downloading'; found = `$list.Count }
    `$d = `$session.CreateUpdateDownloader(); `$d.Updates = `$list; `$null = `$d.Download()
    Save @{ state = 'installing'; found = `$list.Count }
    `$i = `$session.CreateUpdateInstaller(); `$i.Updates = `$list; `$r = `$i.Install()
    `$ok = 0; for (`$k = 0; `$k -lt `$list.Count; `$k++) { if (`$r.GetUpdateResult(`$k).ResultCode -eq 2) { `$ok++ } }
    Save @{ state = 'done'; found = `$list.Count; installed = `$ok; rebootRequired = [bool]`$r.RebootRequired; resultCode = `$r.ResultCode }
}
catch { Save @{ state = 'failed'; message = `$_.Exception.Message } }
"@
Set-Content -Path (Join-Path $dir 'wu.ps1') -Value $runner -Encoding UTF8
Remove-Item (Join-Path $dir 'wu-status.json') -ErrorAction SilentlyContinue
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $dir 'wu.ps1') + '"')
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 3) -AllowStartIfOnBatteries
$null = Register-ScheduledTask -TaskName 'SSP-WindowsUpdate' -Action $action -Principal $principal -Settings $settings -Force
Start-ScheduledTask -TaskName 'SSP-WindowsUpdate'
Write-Output '__SSP_KV:updates=started'
'@
}

function New-WbUpdatePollScript {
    return @'
# SSP-STEP:UPDATES_POLL
$f = Join-Path $env:ProgramData 'SSP\wu-status.json'
if (Test-Path $f) { Write-Output ('__SSP_JSON=' + ((Get-Content $f -Raw) -replace '\s+$', '')) } else { Write-Output '__SSP_KV:state=starting' }
'@
}

function New-WbActivationScript {
    return @'
# SSP-STEP:ACTIVATION
$q = "ApplicationId='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL"
$lic = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter $q -OperationTimeoutSec 30 | Select-Object -First 1
if ($lic -and $lic.LicenseStatus -eq 1) { Write-Output '__SSP_KV:licensed=already'; return }
$j = Start-Job -ScriptBlock { cscript.exe //NoLogo C:\Windows\System32\slmgr.vbs /ato | Out-String }
if (Wait-Job $j -Timeout 90) { $o = Receive-Job $j; Write-Output ('__SSP_KV:slmgr=' + (($o -replace '\s+', ' ').Trim())) } else { Write-Output '__SSP_KV:slmgr=timeout' }
$lic = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter $q -OperationTimeoutSec 30 | Select-Object -First 1
Write-Output ('__SSP_KV:licensed=' + $(if ($lic -and $lic.LicenseStatus -eq 1) { 'yes' } else { 'no' }))
'@
}

function New-WbFirewallScript {
    param([ValidateSet('Keep', 'EnableRdpRule', 'Disable')] [string] $Mode, [bool] $EnableRdp = $true)
    return @"
# SSP-STEP:FIREWALL
`$mode = $(ConvertTo-WbLiteral $Mode); `$rdp = `$$($EnableRdp.ToString().ToLower())
if (`$rdp) { Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0 }
if (`$mode -eq 'EnableRdpRule' -or (`$rdp -and `$mode -ne 'Disable')) { Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue; Get-NetFirewallRule -Name 'RemoteDesktop*' -ErrorAction SilentlyContinue | Enable-NetFirewallRule }
if (`$mode -eq 'Disable') { Set-NetFirewallProfile -Profile Domain, Public, Private -Enabled False }
Write-Output ('__SSP_KV:firewall=' + `$mode)
"@
}

function New-WbDisksScript {
    param([Parameter(Mandatory)] $Row, [bool] $RemoveRecovery = $true, [bool] $AssignCdRomLetter = $true, [int] $AllocationUnit = 0)
    return @"
# SSP-STEP:DISKS
`$letters = $(ConvertTo-WbArray $Row.DriveLetters); `$removeRecovery = `$$($RemoveRecovery.ToString().ToLower()); `$cdLetter = `$$($AssignCdRomLetter.ToString().ToLower()); `$au = $AllocationUnit
`$c = Get-Partition -DriveLetter C
if (`$removeRecovery) {
    # Only a recovery partition placed right after C: on the boot disk blocks the extension.
    `$after = Get-Partition -DiskNumber `$c.DiskNumber | Where-Object { `$_.Offset -gt `$c.Offset } | Sort-Object Offset | Select-Object -First 1
    if (`$after -and [string]`$after.Type -eq 'Recovery') {
        "select disk `$(`$c.DiskNumber)``r``nselect partition `$(`$after.PartitionNumber)``r``ndelete partition override" | diskpart | Out-Null
        Write-Output '__SSP_KV:recovery=removed'
    }
}
`$max = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
if (`$max -gt (Get-Partition -DriveLetter C).Size + 1MB) { Resize-Partition -DriveLetter C -Size `$max; Write-Output '__SSP_KV:cExtended=yes' }
# CD-ROM off the data letters
`$cd = Get-CimInstance Win32_Volume -Filter 'DriveType=5' | Select-Object -First 1
if (`$cd -and `$cd.DriveLetter) { `$null = Set-CimInstance -InputObject `$cd -Property @{ DriveLetter = `$null } }
`$used = @()
foreach (`$L in `$letters) {
    `$v = Get-Volume -DriveLetter `$L -ErrorAction SilentlyContinue
    if (`$v) { Write-Output "DISK|`$L|SKIP|in use"; continue }
    `$d = Get-Disk | Where-Object { -not `$_.IsBoot -and -not `$_.IsSystem -and `$used -notcontains `$_.Number -and
        -not @(Get-Partition -DiskNumber `$_.Number -ErrorAction SilentlyContinue | Where-Object { [string]`$_.Type -ne 'Reserved' }).Count } | Sort-Object Number | Select-Object -First 1
    if (-not `$d) { Write-Output "DISK|`$L|ERROR|no free disk"; continue }
    `$used += `$d.Number
    if (`$d.IsOffline) { Set-Disk -Number `$d.Number -IsOffline `$false }
    if (`$d.IsReadOnly) { Set-Disk -Number `$d.Number -IsReadOnly `$false }
    if ([string]`$d.PartitionStyle -eq 'RAW') { Initialize-Disk -Number `$d.Number -PartitionStyle GPT }
    `$fp = @{ FileSystem = 'NTFS'; NewFileSystemLabel = "Data`$L"; Confirm = `$false }; if (`$au -gt 0) { `$fp['AllocationUnitSize'] = `$au }
    `$null = New-Partition -DiskNumber `$d.Number -UseMaximumSize -DriveLetter `$L | Format-Volume @fp
    Write-Output "DISK|`$L|OK|disk `$(`$d.Number)"
}
if (`$cd -and `$cdLetter) {
    `$taken = @(Get-Volume | Where-Object DriveLetter | ForEach-Object { [string]`$_.DriveLetter })
    `$next = @(68..90 | ForEach-Object { [string][char]`$_ } | Where-Object { `$taken -notcontains `$_ }) | Select-Object -First 1
    `$cd = Get-CimInstance Win32_Volume -Filter 'DriveType=5' | Select-Object -First 1
    if (`$next) { `$null = Set-CimInstance -InputObject `$cd -Property @{ DriveLetter = "`$(`$next):" }; Write-Output "__SSP_KV:cdrom=`$(`$next):" }
}
"@
}

function New-WbDomainJoinScript {
    <# Sensitive: contains the join password. Never logged; nothing written to disk. #>
    param([Parameter(Mandatory)] [string] $Domain, [Parameter(Mandatory)] [pscredential] $Credential, [string] $OUPath)
    $pw = $Credential.GetNetworkCredential().Password
    return @"
# SSP-STEP:DOMAIN_JOIN
if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) { Write-Output '__SSP_KV:join=already'; return }
`$j = Start-Job -ScriptBlock {
    param(`$d, `$u, `$p, `$ou)
    `$c = New-Object System.Management.Automation.PSCredential(`$u, (ConvertTo-SecureString `$p -AsPlainText -Force))
    `$a = @{ DomainName = `$d; Credential = `$c; Force = `$true; ErrorAction = 'Stop'; WarningAction = 'SilentlyContinue' }
    if (`$ou) { `$a['OUPath'] = `$ou }
    Add-Computer @a
} -ArgumentList $(ConvertTo-WbLiteral $Domain), $(ConvertTo-WbLiteral $Credential.UserName), $(ConvertTo-WbLiteral $pw), $(ConvertTo-WbLiteral $OUPath)
if (-not (Wait-Job `$j -Timeout 180)) { throw 'Domain join did not finish in 180 s (DNS / domain controller reachable?).' }
`$err = `$null; `$null = Receive-Job `$j -ErrorVariable err -ErrorAction SilentlyContinue
if (`$j.State -eq 'Failed' -or `$err) { throw ('Domain join failed: ' + `$(if (`$err) { [string]`$err[0] } else { [string]`$j.ChildJobs[0].JobStateInfo.Reason.Message })) }
Write-Output '__SSP_KV:join=reboot'
"@
}

function New-WbAccountsScript {
    <# Local group membership by well-known SID (+ optional local account: sensitive). #>
    param([string[]] $LocalAdmins = @(), [string[]] $RdpUsers = @(), [pscredential] $LocalAccount)
    $acctName = if ($LocalAccount) { ($LocalAccount.UserName -split '\\')[-1] } else { '' }
    $acctPw = if ($LocalAccount) { $LocalAccount.GetNetworkCredential().Password } else { '' }
    return @"
# SSP-STEP:ACCOUNTS
`$cn = `$env:COMPUTERNAME
function Add-Members([string] `$sid, [string[]] `$names) {
    `$gname = (New-Object System.Security.Principal.SecurityIdentifier(`$sid)).Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]
    `$g = [ADSI]("WinNT://`$cn/`$gname,group")
    `$members = @(`$g.psbase.Invoke('Members') | ForEach-Object { `$p = [string]`$_.GetType().InvokeMember('ADsPath', 'GetProperty', `$null, `$_, `$null); `$s = @((`$p -replace '^WinNT://', '') -split '/'); if (`$s.Count -ge 2) { (`$s[-2] + '\' + `$s[-1]).ToLower() } else { `$s[-1].ToLower() } })
    foreach (`$a in @(`$names | Where-Object { `$_ })) {
        `$full = if (`$a -match '\\') { `$a } else { "`$cn\`$a" }
        if (`$members -contains `$full.ToLower()) { Write-Output "ACCT|`$gname|`$a|PRESENT"; continue }
        try { `$g.Add('WinNT://' + (`$full -replace '\\', '/')); Write-Output "ACCT|`$gname|`$a|ADDED" } catch { Write-Output "ACCT|`$gname|`$a|FAILED" }
    }
}
`$acct = $(ConvertTo-WbLiteral $acctName)
if (`$acct) {
    `$sp = ConvertTo-SecureString $(ConvertTo-WbLiteral $acctPw) -AsPlainText -Force
    if (Get-LocalUser -Name `$acct -ErrorAction SilentlyContinue) { Set-LocalUser -Name `$acct -Password `$sp } else { `$null = New-LocalUser -Name `$acct -Password `$sp -PasswordNeverExpires -AccountNeverExpires -Description 'Created by the Self-Service Portal' }
    Write-Output "__SSP_KV:localAccount=`$acct"
}
Add-Members 'S-1-5-32-544' (@($(ConvertTo-WbArray $LocalAdmins)) + @(`$acct))
Add-Members 'S-1-5-32-555' (@($(ConvertTo-WbArray $RdpUsers)) + @(`$acct))
"@
}

function New-WbCleanupScript {
    return @'
# SSP-STEP:CLEANUP
Unregister-ScheduledTask -TaskName 'SSP-WindowsUpdate' -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:ProgramData 'SSP') -Recurse -Force -ErrorAction SilentlyContinue
$au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
if (Test-Path $au) { Remove-ItemProperty -Path $au -Name NoAutoUpdate -ErrorAction SilentlyContinue }
Write-Output '__SSP_KV:cleanup=done'
'@
}

function New-WbValidateScript {
    <# Read-only facts for the closure checks. #>
    return @'
# SSP-STEP:VALIDATE
$cs = Get-CimInstance Win32_ComputerSystem
$q = "ApplicationId='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL"
$lic = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter $q -OperationTimeoutSec 30 -ErrorAction SilentlyContinue | Select-Object -First 1
$members = {
    param($sid)
    $gname = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]
    $g = [ADSI]("WinNT://$env:COMPUTERNAME/$gname,group")
    @($g.psbase.Invoke('Members') | ForEach-Object { $p = [string]$_.GetType().InvokeMember('ADsPath', 'GetProperty', $null, $_, $null); $s = @(($p -replace '^WinNT://', '') -split '/'); if ($s.Count -ge 2) { $s[-2] + '\' + $s[-1] } else { $s[-1] } })
}
$o = [ordered]@{
    hostname = $env:COMPUTERNAME; partOfDomain = [bool]$cs.PartOfDomain; domain = [string]$cs.Domain
    ipv4 = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -ne '127.0.0.1' } | ForEach-Object { $_.IPAddress })
    licensed = [bool]($lic -and $lic.LicenseStatus -eq 1)
    volumes = @(Get-Volume | Where-Object { $_.DriveLetter -and [string]$_.DriveType -eq 'Fixed' } | ForEach-Object { [string]$_.DriveLetter })
    cdrom = [string](@(Get-CimInstance Win32_Volume -Filter 'DriveType=5' | ForEach-Object { $_.DriveLetter }) | Select-Object -First 1)
    rdpEnabled = ((Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server').fDenyTSConnections -eq 0)
    firewallOn = @(Get-NetFirewallProfile | Where-Object Enabled | ForEach-Object Name)
    admins = @(& $members 'S-1-5-32-544'); rdpUsers = @(& $members 'S-1-5-32-555')
    leftovers = (Test-Path (Join-Path $env:ProgramData 'SSP'))
}
Write-Output ('__SSP_JSON=' + ($o | ConvertTo-Json -Compress -Depth 4))
'@
}

#endregion

Export-ModuleMember -Function ConvertFrom-PortalBuildCsv, New-WbBootScript, New-WbNetworkScript, New-WbRenameScript, New-WbUpdateStartScript, New-WbUpdatePollScript,
    New-WbActivationScript, New-WbFirewallScript, New-WbDisksScript, New-WbDomainJoinScript, New-WbAccountsScript, New-WbCleanupScript, New-WbValidateScript
