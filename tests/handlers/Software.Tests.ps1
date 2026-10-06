#Requires -Version 7.2
<#
.SYNOPSIS
    Offline tests - "Software installation" group: Portal.Guest library, sql-server-2022, windows-roles,
    agent-baseline, almalinux-baseline. Invoke-VMScript is stubbed: each call is recorded (wrapped + decoded script)
    and answered by $global:SwResponder, which returns @{ Output; Exit } for the decoded script.
#>
. (Join-Path $PSScriptRoot '_TestHelpers.ps1')
Start-TestGroup 'Software installation'

$guestLib = Join-Path $global:SspHandlerTestRoot 'automation/lib/Portal.Guest.psm1'
Import-Module $guestLib -Force -Global -DisableNameChecking

#region Stubs ---------------------------------------------------------------------------------------------------
$global:SwVMs = @{
    'SQL01'  = @{ Os = 'Microsoft Windows Server 2022 (64-bit)'; Family = 'windowsGuest'; Power = 'PoweredOn' }
    'WIN10'  = @{ Os = 'Microsoft Windows 10 (64-bit)'; Family = 'windowsGuest'; Power = 'PoweredOn' }
    'APP01'  = @{ Os = 'Microsoft Windows Server 2025 (64-bit)'; Family = 'windowsGuest'; Power = 'PoweredOn' }
    'LNX01'  = @{ Os = 'AlmaLinux 9 (64-bit)'; Family = 'linuxGuest'; Power = 'PoweredOn' }
    'OFF01'  = @{ Os = 'Microsoft Windows Server 2022 (64-bit)'; Family = 'windowsGuest'; Power = 'PoweredOff' }
}
$global:SwScripts = [System.Collections.Generic.List[object]]::new()
$global:SwRestarts = [System.Collections.Generic.List[string]]::new()
$global:SwAll = [System.Collections.Generic.List[object]]::new()
$global:SwResponder = { param($Text, $Type) @{ Output = ''; Exit = 0 } }

function global:Get-VM {
    param($Name, $Server, $Id, [Parameter(ValueFromRemainingArguments)] $Rest)
    $n = [string]$Name
    if (-not $global:SwVMs.ContainsKey($n)) { return }
    $d = $global:SwVMs[$n]
    [pscustomobject]@{ Name = $n; Id = "VirtualMachine-$n"; PowerState = $d.Power
                       ExtensionData = [pscustomobject]@{ Guest = [pscustomobject]@{ ToolsRunningStatus = 'guestToolsRunning'; GuestFamily = $d.Family } } }
}
function global:Get-VMGuest {
    param($VM, $Server, [Parameter(ValueFromRemainingArguments)] $Rest)
    $d = $global:SwVMs[$VM.Name]
    [pscustomobject]@{ VM = $VM; State = 'Running'; OSFullName = $d.Os; GuestFamily = $d.Family }
}
function global:Restart-VMGuest { param($VM, $Server, [switch] $Confirm, [Parameter(ValueFromRemainingArguments)] $Rest) $global:SwRestarts.Add($VM.Name) }
function global:Get-SwDecoded {
    <# The script as the handler wrote it (unwrapped from the Portal.Guest wrapper). #>
    param([string] $Wrapped, [string] $Type)
    if ($Type -eq 'Powershell' -and $Wrapped -match "FromBase64String\('([^']+)'\)") { return [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1])) }
    if ($Wrapped -match "(?s)<<'(__SSP_EOF_\w+__)'\n(.*?)\n\1") { return $Matches[2] }
    return $Wrapped
}
function global:Invoke-VMScript {
    param($VM, $Server, $GuestCredential, $ScriptText, $ScriptType, $ToolsWaitSecs, [Parameter(ValueFromRemainingArguments)] $Rest)
    $decoded = Get-SwDecoded -Wrapped $ScriptText -Type $ScriptType
    $rec = [pscustomobject]@{ VM = $VM.Name; Type = $ScriptType; Wrapped = $ScriptText; Text = $decoded; User = $GuestCredential.UserName }
    $global:SwScripts.Add($rec); $global:SwAll.Add($rec)
    $r = & $global:SwResponder $decoded $ScriptType
    if ($r.Throw) { throw $r.Throw }
    $out = [string]$r.Output
    if (-not $r.NoSentinel) { $out = $out + "`n__SSP_EXIT=$($r.Exit)" }
    [pscustomobject]@{ ScriptOutput = $out; ExitCode = 0 }
}
function New-SwCred([string] $User, [string] $Pw) { [pscredential]::new($User, (ConvertTo-SecureString $Pw -AsPlainText -Force)) }
function Merge-Sw([hashtable] $A, [hashtable] $B) { $h = @{} + $A; foreach ($k in $B.Keys) { $h[$k] = $B[$k] }; $h }
function Reset-Sw { $global:SwScripts.Clear(); $global:SwRestarts.Clear() }

$guestCred = New-SwCred 'CORP\svc-portal' 'GuestP@ssw0rd!'
$vi = [pscustomobject]@{ Name = 'vc-dc1.test.local' }
#endregion

#region Portal.Guest library -----------------------------------------------------------------------------------
$p = ConvertFrom-PortalGuestOutput -Text "line1`nline2`n__SSP_EXIT=0`n"
Assert-Test -Name 'Lib: sentinel parsed (0) and removed' -Condition ($p.ExitCode -eq 0 -and $p.Output -eq "line1`nline2")
$p = ConvertFrom-PortalGuestOutput -Text "boom`r`n__SSP_EXIT=7"
Assert-Test -Name 'Lib: sentinel parsed (7)' -Condition ($p.ExitCode -eq 7 -and $p.Output -eq 'boom')
$p = ConvertFrom-PortalGuestOutput -Text 'no sentinel here'
Assert-Test -Name 'Lib: missing sentinel = -1' -Condition ($p.ExitCode -eq -1)

Assert-Test -Name 'Lib: PowerShell literal doubles quotes' -Condition ((ConvertTo-PortalGuestLiteral "O'Brien") -eq "'O''Brien'" -and (ConvertTo-PortalGuestLiteral "a$([char]0x2019)b") -eq "'a$([char]0x2019)$([char]0x2019)b'")
Assert-Test -Name 'Lib: Bash literal escapes quotes' -Condition ((ConvertTo-PortalBashLiteral "it's") -eq "'it'\''s'")

$vmObj = Get-VM -Name 'SQL01'
Reset-Sw
$global:SwResponder = { param($Text, $Type) @{ Output = "hello`n__SSP_KV:Answer=42"; Exit = 0 } }
$o = Invoke-PortalGuestScript -VM $vmObj -Credential $guestCred -ScriptText 'Write-Output hello' -Type PowerShell -Server $vi -Description 'unit'
Assert-Test -Name 'Lib: success returns output without sentinel' -Condition ($o -notmatch '__SSP_EXIT' -and $o -match 'hello' -and (Get-PortalGuestData -Output $o).Answer -eq '42')
Assert-Test -Name 'Lib: PowerShell wrapper (base64 + Start-Job + sentinel), ToolsWaitSecs passed' -Condition ($global:SwScripts[0].Wrapped -match 'Start-Job' -and $global:SwScripts[0].Wrapped -match '__SSP_EXIT=' -and $global:SwScripts[0].Text -match 'Write-Output hello')

$global:SwResponder = { param($Text, $Type) @{ Output = ((1..30 | ForEach-Object { "out $_" }) + 'ERROR: failed with GuestP@ssw0rd! and TopSecret99') -join "`n"; Exit = 3 } }
$err = $null; try { $null = Invoke-PortalGuestScript -VM $vmObj -Credential $guestCred -ScriptText 'x' -Type Bash -Server $vi -Description 'failing' -Secrets 'TopSecret99' } catch { $err = $_.Exception.Message }
Assert-Test -Name 'Lib: non-zero exit throws with exit code' -Condition ($err -match 'exit code 3' -and $err -match 'failing') -Detail $err
Assert-Test -Name 'Lib: error carries only the last 20 lines' -Condition ($err -match 'out 30' -and $err -notmatch 'out 10\b') -Detail $err
Assert-Test -Name 'Lib: secrets redacted from errors' -Condition ($err -and $err -notmatch 'GuestP@ssw0rd!' -and $err -notmatch 'TopSecret99' -and $err -match '\*\*\*\*\*\*\*\*') -Detail $err

$global:SwResponder = { param($Text, $Type) @{ Output = 'killed'; NoSentinel = $true } }
$err = $null; try { $null = Invoke-PortalGuestScript -VM $vmObj -Credential $guestCred -ScriptText 'x' -Server $vi } catch { $err = $_.Exception.Message }
Assert-Test -Name 'Lib: missing sentinel throws' -Condition ($err -match 'no exit status') -Detail $err

$global:SwResponder = { param($Text, $Type) @{ Throw = 'Failed to authenticate with the guest operating system using the supplied credentials.' } }
$err = $null; try { $null = Invoke-PortalGuestScript -VM $vmObj -Credential $guestCred -ScriptText 'x' -Server $vi -Description 'auth' } catch { $err = $_.Exception.Message }
Assert-Test -Name 'Lib: Invoke-VMScript error wrapped' -Condition ($err -match "could not run" -and $err -match 'guest credential') -Detail $err

$global:JobLog.Clear()
$global:SwResponder = { param($Text, $Type) @{ Output = ''; Exit = 0 } }
$null = Invoke-PortalGuestScript -VM $vmObj -Credential $guestCred -ScriptText "echo 'TopSecret99'" -Type Bash -Server $vi -Description 'secret step' -Sensitive -Secrets 'TopSecret99'
Assert-Test -Name 'Lib: sensitive script text never logged' -Condition (-not (@($global:JobLog) -match 'TopSecret99') -and (@($global:JobLog) -match 'sensitive'))

# Real wrapper execution (local interpreters): proves the sentinel reflects the script result.
if ((Get-Command bash -ErrorAction SilentlyContinue) -and (Get-Command timeout -ErrorAction SilentlyContinue)) {
    $okOut  = & bash -c (New-PortalGuestWrapper -ScriptText "echo hi`necho there" -Type Bash -TimeoutSeconds 30) 2>&1 | Out-String
    $badOut = & bash -c (New-PortalGuestWrapper -ScriptText "echo before`nfalse`necho after" -Type Bash -TimeoutSeconds 30) 2>&1 | Out-String
    $p1 = ConvertFrom-PortalGuestOutput -Text $okOut; $p2 = ConvertFrom-PortalGuestOutput -Text $badOut
    Assert-Test -Name 'Lib: Bash wrapper runs (exit 0)' -Condition ($p1.ExitCode -eq 0 -and $p1.Output -match 'there') -Detail $okOut
    Assert-Test -Name 'Lib: Bash wrapper stops on error (set -e) and reports it' -Condition ($p2.ExitCode -eq 1 -and $p2.Output -notmatch 'after') -Detail $badOut
}
$psOk  = & pwsh -NoProfile -NonInteractive -Command (New-PortalGuestWrapper -ScriptText "Write-Output 'fine'" -TimeoutSeconds 60) 2>&1 | Out-String
$psBad = & pwsh -NoProfile -NonInteractive -Command (New-PortalGuestWrapper -ScriptText "Write-Output 'step1'; throw 'kaboom'" -TimeoutSeconds 60) 2>&1 | Out-String
$q1 = ConvertFrom-PortalGuestOutput -Text $psOk; $q2 = ConvertFrom-PortalGuestOutput -Text $psBad
Assert-Test -Name 'Lib: PowerShell wrapper runs (exit 0)' -Condition ($q1.ExitCode -eq 0 -and $q1.Output -match 'fine') -Detail $psOk
Assert-Test -Name 'Lib: PowerShell wrapper turns a throw into exit 1' -Condition ($q2.ExitCode -eq 1 -and $q2.Output -match 'kaboom') -Detail $psBad
#endregion

#region sql-server-2022 ----------------------------------------------------------------------------------------
$global:SwSqlRaw = 4
$global:SwSqlSetupFound = $true
$global:SwResponder = {
    param($Text, $Type)
    if ($Text -match 'Win32_ComputerSystem') {
        $raw = @(1..$global:SwSqlRaw | ForEach-Object { [ordered]@{ Number = $_; SizeGB = 100; Offline = $true } })
        $facts = [ordered]@{ Caption = $global:SwSqlCaption; ProductType = $(if ($global:SwSqlCaption -match 'Server') { 3 } else { 1 }); Cores = 4; TotalMB = 16384; RawDisks = $raw
                             Volumes = @([ordered]@{ Letter = 'C'; Type = 'Fixed'; FileSystem = 'NTFS' }, [ordered]@{ Letter = 'D'; Type = 'CD-ROM'; FileSystem = '' })
                             SetupFound = $global:SwSqlSetupFound; InstanceExists = $false; Account = 'CORP\svc-portal' }
        return @{ Output = '__SSP_JSON=' + ($facts | ConvertTo-Json -Compress -Depth 5); Exit = 0 }
    }
    if ($Text -match 'Initialize-Disk') { return @{ Output = (0..3 | ForEach-Object { "__SSP_KV:Disk$_=X: disk $($_ + 1) 100 GB NTFS 64K" }) -join "`n"; Exit = 0 } }
    if ($Text -match 'ConfigurationFile\.ini') { return @{ Output = '__SSP_KV:SetupExit=0'; Exit = 0 } }
    if ($Text -match 'sp_configure') { return @{ Output = "__SSP_KV:Version=Microsoft SQL Server 2022 (RTM) - 16.0.1000.6 (X64)`n__SSP_KV:ProductVersion=16.0.1000.6 Developer Edition (64-bit)`n__SSP_KV:Client=sqlcmd`n__SSP_KV:ServiceStatus=Running"; Exit = 0 } }
    @{ Output = ''; Exit = 0 }
}
$global:SwSqlCaption = 'Microsoft Windows Server 2022 Datacenter'
$sqlBase = @{ Site = 'DC1'; VMName = 'SQL01'; GuestCredential = $guestCred; SysAdminGroup = 'CORP\SQL-Admins'; InstallerPath = '\\fs01\software\SQL2022' }

# Pre-check: fewer than 4 RAW disks.
Reset-Sw; $global:SwSqlRaw = 2
$ctx = New-TestContext -ItemId 'sql-server-2022'
$r = Invoke-TestHandler -Handler 'Install-GuestSqlServer.ps1' -Parameters (Merge-Sw $sqlBase @{ Context = $ctx })
Assert-Test -Name 'SQL: fewer than 4 RAW disks fails with the needed layout' -Condition ($r.Error -match 'needs 4 RAW' -and $r.Error -match 'Found 2' -and $r.Error -match 'T: tempdb') -Detail $r.Error
Assert-Test -Name 'SQL: nothing changed after failed pre-check' -Condition (-not ($global:SwScripts | Where-Object { $_.Text -match 'Initialize-Disk|ConfigurationFile' }))

# Pre-check: placeholder media path, setup.exe missing, client OS.
$r = Invoke-TestHandler -Handler 'Install-GuestSqlServer.ps1' -Parameters (Merge-Sw $sqlBase @{ InstallerPath = 'TBD-\\fileserver\software\SQL2022'; Context = $ctx })
Assert-Test -Name 'SQL: TBD InstallerPath fails early' -Condition ($r.Error -match 'not configured for site DC1') -Detail $r.Error
$global:SwSqlRaw = 4; $global:SwSqlSetupFound = $false
$r = Invoke-TestHandler -Handler 'Install-GuestSqlServer.ps1' -Parameters (Merge-Sw $sqlBase @{ Context = $ctx })
Assert-Test -Name 'SQL: setup.exe not found fails' -Condition ($r.Error -match 'setup\.exe was not found') -Detail $r.Error
$global:SwSqlSetupFound = $true
$global:SwSqlCaption = 'Microsoft Windows 10 Enterprise'
$r = Invoke-TestHandler -Handler 'Install-GuestSqlServer.ps1' -Parameters (Merge-Sw $sqlBase @{ VMName = 'WIN10'; Context = $ctx })
$global:SwSqlCaption = 'Microsoft Windows Server 2022 Datacenter'
Assert-Test -Name 'SQL: non-Windows-Server guest fails' -Condition ($r.Error -match 'Windows Server') -Detail $r.Error
$r = Invoke-TestHandler -Handler 'Install-GuestSqlServer.ps1' -Parameters (Merge-Sw $sqlBase @{ VMName = 'OFF01'; Context = $ctx })
Assert-Test -Name 'SQL: powered-off VM fails' -Condition ($r.Error -match 'PoweredOff') -Detail $r.Error
$r = Invoke-TestHandler -Handler 'Install-GuestSqlServer.ps1' -Parameters (Merge-Sw $sqlBase @{ SysAdminGroup = 'SQL-Admins'; Context = $ctx })
Assert-Test -Name 'SQL: sysadmin group without domain rejected' -Condition ($r.Error -match 'DOMAIN\\Group') -Detail $r.Error

# Happy path with a service account.
Reset-Sw
$svcPw = 'SvcS3cret#2026'
$ctx = New-TestContext -ItemId 'sql-server-2022'
$r = Invoke-TestHandler -Handler 'Install-GuestSqlServer.ps1' -Parameters (Merge-Sw $sqlBase @{ Collation = 'Latin1_General_CI_AS'; SqlServiceCredential = (New-SwCred 'CORP\svc-sql01' $svcPw); Context = $ctx })
Assert-Test -Name 'SQL: install succeeded' -Condition ($null -eq $r.Error -and $r.Result.Instance -eq 'SQL01' -and $r.Result.Version -match '^16\.0') -Detail $r.Error
$disk = $global:SwScripts | Where-Object { $_.Text -match 'Initialize-Disk' } | Select-Object -First 1
Assert-Test -Name 'SQL: disks formatted NTFS 64K, GPT, letters D/E/F/T' -Condition ($disk -and $disk.Text -match 'AllocationUnitSize 65536' -and $disk.Text -match 'FileSystem NTFS' -and $disk.Text -match 'PartitionStyle GPT' -and $disk.Text -match "L = 'D'.*L = 'E'.*L = 'F'.*L = 'T'")
Assert-Test -Name 'SQL: disk prep brings offline disks online and moves CD-ROM' -Condition ($disk.Text -match 'IsOffline \$false' -and $disk.Text -match 'CD-ROM')
$inst = $global:SwScripts | Where-Object { $_.Text -match 'ConfigurationFile\.ini' } | Select-Object -First 1
$iniText = if ($inst) { $inst.Text } else { '' }
Assert-Test -Name 'SQL: ini ACTION/FEATURES/INSTANCENAME' -Condition ($iniText -match 'ACTION="Install"' -and $iniText -match 'FEATURES=SQLENGINE' -and $iniText -match 'INSTANCENAME="MSSQLSERVER"')
Assert-Test -Name 'SQL: ini collation' -Condition ($iniText -match 'SQLCOLLATION="Latin1_General_CI_AS"')
Assert-Test -Name 'SQL: ini sysadmin group (+ install account)' -Condition ($iniText -match 'SQLSYSADMINACCOUNTS="CORP\\SQL-Admins" "CORP\\svc-portal"')
Assert-Test -Name 'SQL: ini directories D/E/F/T' -Condition ($iniText -match 'INSTALLSQLDATADIR="D:\\"' -and $iniText -match 'SQLUSERDBLOGDIR="E:\\MSSQL\\Logs"' -and $iniText -match 'SQLBACKUPDIR="F:\\MSSQL\\Backup"' -and $iniText -match 'SQLTEMPDBDIR="T:\\MSSQL\\TempDB"')
Assert-Test -Name 'SQL: ini tempdb files auto = min(8, cores)' -Condition ($iniText -match 'SQLTEMPDBFILECOUNT="4"')
Assert-Test -Name 'SQL: ini license, no updates, TCP, quiet' -Condition ($iniText -match 'IACCEPTSQLSERVERLICENSETERMS="True"' -and $iniText -match 'UpdateEnabled="False"' -and $iniText -match 'TCPENABLED="1"' -and $iniText -match 'QUIET="True"')
Assert-Test -Name 'SQL: ini service account' -Condition ($iniText -match 'SQLSVCACCOUNT="CORP\\svc-sql01"')
Assert-Test -Name 'SQL: temp ini removed in finally' -Condition ($iniText -match '(?s)finally \{ Remove-Item -LiteralPath \$dir -Recurse')
$post = $global:SwScripts | Where-Object { $_.Text -match 'sp_configure' } | Select-Object -First 1
Assert-Test -Name 'SQL: post-config memory/MAXDOP/cost threshold/compression' -Condition ($post -and $post.Text -match "max server memory \(MB\)'', 12288" -and $post.Text -match "max degree of parallelism'', 4" -and $post.Text -match "cost threshold for parallelism'', 50" -and $post.Text -match "backup compression default'', 1" -and $post.Text -match '@@VERSION')
Assert-Test -Name 'SQL: result settings' -Condition ($r.Result.MaxDop -eq 4 -and $r.Result.MaxServerMemoryMB -eq 12288 -and $r.Result.TempDbFiles -eq 4 -and @($r.Result.Disks).Count -eq 4)
Assert-Test -Name 'SQL: service password not in job log' -Condition (-not (@($r.Log) -match [regex]::Escape($svcPw)) -and (@($r.Log) -match 'setup.*sensitive')) -Detail (@($r.Log) -join ' | ')

# Explicit settings and virtual accounts.
Reset-Sw
$r = Invoke-TestHandler -Handler 'Install-GuestSqlServer.ps1' -Parameters (Merge-Sw $sqlBase @{ InstanceName = 'APP1'; MaxDop = 2; MaxServerMemoryMB = 8192; TempDbFiles = 6; Context = $ctx })
$iniText = ($global:SwScripts | Where-Object { $_.Text -match 'ConfigurationFile\.ini' } | Select-Object -First 1).Text
Assert-Test -Name 'SQL: named instance with virtual account and explicit settings' -Condition ($null -eq $r.Error -and $iniText -match 'SQLSVCACCOUNT="NT Service\\MSSQL\$APP1"' -and $iniText -match 'SQLTEMPDBFILECOUNT="6"' -and $r.Result.MaxDop -eq 2 -and $r.Result.MaxServerMemoryMB -eq 8192 -and $r.Result.Instance -eq 'SQL01\APP1') -Detail $r.Error
#endregion

#region windows-roles ------------------------------------------------------------------------------------------
$global:SwResponder = {
    param($Text, $Type)
    if ($Text -match 'Win32_OperatingSystem') { return @{ Output = "__SSP_KV:Caption=Microsoft Windows Server 2025 Standard`n__SSP_KV:ProductType=3`n__SSP_KV:ServerManager=True`n__SSP_KV:Dtc=True"; Exit = 0 } }
    if ($Text -match 'Set-DtcNetworkSetting') {
        $j = [ordered]@{ AuthenticationLevel = 'Mutual'; Inbound = $true; Outbound = $true; RemoteClient = $true; RemoteAdmin = $false; XA = $false; LU = $true; Service = 'Running'; FirewallRulesEnabled = 3 }
        return @{ Output = '__SSP_JSON=' + ($j | ConvertTo-Json -Compress); Exit = 0 }
    }
    if ($Text -match 'Install-WindowsFeature') {
        $j = [ordered]@{ ExitCode = 'Success'; RestartNeeded = 'Yes'; AlreadyInstalled = @('Web-Mgmt-Console'); Installed = @('Web-Server', 'Web-Asp-Net45', 'Web-Net-Ext45'); Missing = @() }
        return @{ Output = '__SSP_JSON=' + ($j | ConvertTo-Json -Compress); Exit = 0 }
    }
    @{ Output = ''; Exit = 0 }
}
$winBase = @{ Site = 'DC1'; VMName = 'APP01'; GuestCredential = $guestCred }

Reset-Sw
$ctx = New-TestContext -ItemId 'windows-roles'
$r = Invoke-TestHandler -Handler 'Install-GuestWindowsFeature.ps1' -Parameters (Merge-Sw $winBase @{ Features = 'MSDTC'; Context = $ctx })
$dtc = ($global:SwScripts | Where-Object { $_.Text -match 'Set-DtcNetworkSetting -DtcName' } | Select-Object -First 1).Text
Assert-Test -Name 'MSDTC: configured and verified' -Condition ($null -eq $r.Error -and $r.Result.MsdtcAuthentication -eq 'Mutual' -and $r.Result.MsdtcInbound -and $r.Result.MsdtcOutbound) -Detail $r.Error
Assert-Test -Name 'MSDTC: Set-DtcNetworkSetting arguments' -Condition ($dtc -match "-DtcName Local -AuthenticationLevel 'Mutual'" -and $dtc -match '-InboundTransactionsEnabled \$true' -and $dtc -match '-OutboundTransactionsEnabled \$true' -and $dtc -match '-RemoteClientAccessEnabled \$true' -and $dtc -match '-RemoteAdministrationAccessEnabled \$false' -and $dtc -match '-XATransactionsEnabled \$false' -and $dtc -match '-LUTransactionsEnabled \$true' -and $dtc -match '-Confirm:\$false')
Assert-Test -Name 'MSDTC: firewall group, service restart, verification' -Condition ($dtc -match "Enable-NetFirewallRule -DisplayGroup 'Distributed Transaction Coordinator'" -and $dtc -match 'Restart-Service -Name MSDTC' -and $dtc -match 'Get-DtcNetworkSetting')
Assert-Test -Name 'MSDTC: no feature install' -Condition (-not ($global:SwScripts | Where-Object { $_.Text -match 'Install-WindowsFeature -Name' }))

Reset-Sw
$r = Invoke-TestHandler -Handler 'Install-GuestWindowsFeature.ps1' -Parameters (Merge-Sw $winBase @{ Features = 'MSDTC'; MsdtcAuthentication = 'Incoming'; MsdtcAllowInbound = $false; Context = $ctx })
Assert-Test -Name 'MSDTC: verification mismatch fails' -Condition ($r.Error -match 'MSDTC verification failed' -and $r.Error -match 'AuthenticationLevel=Mutual') -Detail $r.Error
$dtc = ($global:SwScripts | Where-Object { $_.Text -match 'Set-DtcNetworkSetting -DtcName' } | Select-Object -First 1).Text
Assert-Test -Name 'MSDTC: Incoming / inbound off passed through' -Condition ($dtc -match "-AuthenticationLevel 'Incoming'" -and $dtc -match '-InboundTransactionsEnabled \$false')

Reset-Sw
$r = Invoke-TestHandler -Handler 'Install-GuestWindowsFeature.ps1' -Parameters (Merge-Sw $winBase @{ Features = 'IIS'; Context = $ctx })
$feat = ($global:SwScripts | Where-Object { $_.Text -match 'Install-WindowsFeature' } | Select-Object -Last 1).Text
Assert-Test -Name 'Features: IIS bundle installed' -Condition ($null -eq $r.Error -and @($r.Result.Installed).Count -eq 3 -and $feat -match "'Web-Server', 'Web-Mgmt-Console', 'Web-Asp-Net45', 'Web-Net-Ext45'") -Detail $r.Error
Assert-Test -Name 'Features: restart reported, not performed' -Condition ($r.Result.RestartNeeded -eq $true -and $r.Result.Restarted -eq $false -and $global:SwRestarts.Count -eq 0 -and @($r.Result.NextSteps).Count -eq 1)

Reset-Sw
$r = Invoke-TestHandler -Handler 'Install-GuestWindowsFeature.ps1' -Parameters (Merge-Sw $winBase @{ VMName = 'LNX01'; Features = 'IIS'; Context = $ctx })
Assert-Test -Name 'Features: Linux guest rejected' -Condition ($r.Error -match 'needs a windows guest') -Detail $r.Error
#endregion

#region agent-baseline -----------------------------------------------------------------------------------------
$swPath = Get-PortalDataFilePath -Name software
$swOriginal = Get-Content -LiteralPath $swPath -Raw
$sw = [ordered]@{
    repository = [ordered]@{ windowsBase = '\\fs01\software'; linuxBase = 'https://repo.test.local/software' }
    packages   = @(
        [ordered]@{ id = 'monitoring-agent-win'; name = 'Monitoring agent'; os = 'windows'; version = '7.1'; installer = 'monitoring/agent.msi'; installArgs = '/qn /norestart'; verify = @{ type = 'service'; value = 'MonAgent' }; status = 'Approved' }
        [ordered]@{ id = 'edr-agent-win'; name = 'EDR agent'; os = 'windows'; version = '3.2'; installer = 'edr/setup.exe'; installArgs = '/quiet'; verify = @{ type = 'service'; value = 'EdrSvc' }; status = 'Approved' }
        [ordered]@{ id = 'backup-agent-win'; name = 'Backup agent'; os = 'windows'; version = ''; installer = 'backup/agent.msi'; installArgs = '/qn'; verify = @{ type = 'service'; value = 'TBD' }; status = 'Pending'; notes = 'No product yet' }
        [ordered]@{ id = 'old-agent-win'; name = 'Old agent'; os = 'windows'; version = '1'; installer = 'old/agent.msi'; installArgs = '/qn'; verify = @{ type = 'file'; value = 'C:\old' }; status = 'Retired' }
        [ordered]@{ id = 'monitoring-agent-linux'; name = 'Monitoring agent'; os = 'linux'; version = '7.1'; installer = 'monitoring/agent.rpm'; installArgs = ''; verify = @{ type = 'package'; value = 'mon-agent' }; status = 'Approved' }
        [ordered]@{ id = 'pending-linux'; name = 'Pending agent'; os = 'linux'; version = '1'; installer = 'p/agent.rpm'; installArgs = ''; verify = @{ type = 'service'; value = 'x' }; status = 'Pending' }
    )
    sets       = @(
        [ordered]@{ id = 'baseline-windows'; name = 'Windows server baseline'; os = 'windows'; packages = @('monitoring-agent-win', 'edr-agent-win', 'backup-agent-win', 'old-agent-win') }
        [ordered]@{ id = 'baseline-linux'; name = 'Linux server baseline'; os = 'linux'; packages = @('monitoring-agent-linux') }
        [ordered]@{ id = 'pending-only'; name = 'Pending only'; os = 'linux'; packages = @('pending-linux') }
    )
}
$errs = @(Test-PortalDataFile -Name software -Content ($sw | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable))
Assert-Test -Name 'Agents: test software.json is valid' -Condition (-not $errs.Count) -Detail ($errs -join '; ')
Set-Content -LiteralPath $swPath -Value ($sw | ConvertTo-Json -Depth 10) -Encoding utf8

$global:SwResponder = {
    param($Text, $Type)
    if ($Text -match 'monitoring') { return @{ Output = "__SSP_KV:ExitCode=0`n__SSP_KV:State=Installed"; Exit = 0 } }
    if ($Text -match 'EdrSvc') { return @{ Output = '__SSP_KV:State=AlreadyPresent'; Exit = 0 } }
    @{ Output = ''; Exit = 0 }
}
Reset-Sw
$ctx = New-TestContext -ItemId 'agent-baseline'
$r = Invoke-TestHandler -Handler 'Install-GuestAgentBaseline.ps1' -Parameters @{ Site = 'DC1'; VMName = 'APP01'; BaselineSet = 'baseline-windows'; GuestCredential = $guestCred; Context = $ctx }
Assert-Test -Name 'Agents: succeeded' -Condition ($null -eq $r.Error) -Detail $r.Error
Assert-Test -Name 'Agents: only Approved packages processed' -Condition ($global:SwScripts.Count -eq 2 -and -not ($global:SwScripts | Where-Object { $_.Text -match 'backup|old' })) -Detail "$($global:SwScripts.Count) scripts"
Assert-Test -Name 'Agents: installed vs already present' -Condition (@($r.Result.Installed) -contains 'Monitoring agent 7.1' -and @($r.Result.AlreadyPresent) -contains 'EDR agent 3.2')
Assert-Test -Name 'Agents: Pending / Retired listed as skipped' -Condition (@($r.Result.Skipped) -contains 'Not installed: Backup agent (Pending)' -and @($r.Result.Skipped) -contains 'Not installed: Old agent (Retired)')
$msi = ($global:SwScripts | Where-Object { $_.Text -match 'monitoring' } | Select-Object -First 1).Text
Assert-Test -Name 'Agents: msi source from repository + msiexec /l*v + verify service' -Condition ($msi -match [regex]::Escape("'\\fs01\software\monitoring\agent.msi'") -and $msi -match "msiexec\.exe" -and $msi -match '/l\*v' -and $msi -match "Get-Service -Name 'MonAgent'" -and $msi -match "/qn /norestart")
Assert-Test -Name 'Agents: idempotent (verify before install)' -Condition ($msi -match "(?s)if \(Test-Pkg\) \{ Write-Output '__SSP_KV:State=AlreadyPresent'; return \}.*Start-Process")

Reset-Sw
$global:SwResponder = { param($Text, $Type) @{ Output = '__SSP_KV:State=Installed'; Exit = 0 } }
$r = Invoke-TestHandler -Handler 'Install-GuestAgentBaseline.ps1' -Parameters @{ Site = 'DC1'; VMName = 'LNX01'; BaselineSet = 'baseline-linux'; GuestCredential = (New-SwCred 'root' 'R00tPass!'); Context = $ctx }
$rpm = ($global:SwScripts | Select-Object -Last 1)
Assert-Test -Name 'Agents: Linux rpm via dnf from URL, verify rpm -q, Bash' -Condition ($null -eq $r.Error -and $rpm.Type -eq 'Bash' -and $rpm.Text -match [regex]::Escape("dnf install -y 'https://repo.test.local/software/monitoring/agent.rpm'") -and $rpm.Text -match "rpm -q 'mon-agent'") -Detail $r.Error

Reset-Sw
$r = Invoke-TestHandler -Handler 'Install-GuestAgentBaseline.ps1' -Parameters @{ Site = 'DC1'; VMName = 'APP01'; BaselineSet = 'baseline-linux'; GuestCredential = $guestCred; Context = $ctx }
Assert-Test -Name 'Agents: OS mismatch fails' -Condition ($r.Error -match "is for linux but APP01 runs windows") -Detail $r.Error

Reset-Sw
$r = Invoke-TestHandler -Handler 'Install-GuestAgentBaseline.ps1' -Parameters @{ Site = 'DC1'; VMName = 'LNX01'; BaselineSet = 'pending-only'; GuestCredential = $guestCred; Context = $ctx }
Assert-Test -Name 'Agents: 0 approved packages = success with warning' -Condition ($null -eq $r.Error -and @($r.Result.Installed).Count -eq 0 -and @($r.Result.Skipped) -contains 'Not installed: Pending agent (Pending)' -and (@($r.Log) -match '^\[WARN\].*nothing to install') -and $global:SwScripts.Count -eq 0) -Detail $r.Error

$r = Invoke-TestHandler -Handler 'Install-GuestAgentBaseline.ps1' -Parameters @{ Site = 'DC1'; VMName = 'APP01'; BaselineSet = 'nope'; GuestCredential = $guestCred; Context = $ctx }
Assert-Test -Name 'Agents: unknown set fails' -Condition ($r.Error -match "'nope' does not exist") -Detail $r.Error

Reset-Sw
$global:SwResponder = { param($Text, $Type) if ($Text -match 'EdrSvc') { @{ Output = 'Installer exit code 1603'; Exit = 1 } } else { @{ Output = '__SSP_KV:State=Installed'; Exit = 0 } } }
$r = Invoke-TestHandler -Handler 'Install-GuestAgentBaseline.ps1' -Parameters @{ Site = 'DC1'; VMName = 'APP01'; BaselineSet = 'baseline-windows'; GuestCredential = $guestCred; Context = $ctx }
Assert-Test -Name 'Agents: package failure reported after trying the others' -Condition ($r.Error -match '1 of 2 package' -and $r.Error -match 'EDR agent' -and $r.Error -match 'Installed: Monitoring agent') -Detail $r.Error
Set-Content -LiteralPath $swPath -Value $swOriginal -Encoding utf8 -NoNewline
#endregion

#region almalinux-baseline -------------------------------------------------------------------------------------
$global:SwLinuxId = 'almalinux'
$global:SwLinuxRealms = ''
$global:SwResponder = {
    param($Text, $Type)
    if ($Text -match '/etc/os-release') { return @{ Output = "__SSP_KV:Id=$($global:SwLinuxId)`n__SSP_KV:Version=9.4`n__SSP_KV:Pretty=AlmaLinux 9.4 (Seafoam Ocelot)`n__SSP_KV:Uid=0`n__SSP_KV:Root=yes`n__SSP_KV:Realms=$($global:SwLinuxRealms)"; Exit = 0 } }
    @{ Output = ''; Exit = 0 }
}
$joinPw = 'J0in-Secret!x'
$lnxBase = @{ Site = 'DC1'; VMName = 'LNX01'; GuestCredential = (New-SwCred 'root' 'R00tPass!') }
$ctx = New-TestContext -ItemId 'almalinux-baseline'

Reset-Sw
$r = Invoke-TestHandler -Handler 'Set-GuestAlmaLinuxBaseline.ps1' -Parameters (Merge-Sw $lnxBase @{ JoinDomain = $false; ExtraPackages = 'vim-enhanced, bad;rm -rf /'; Context = $ctx })
Assert-Test -Name 'Linux: bad package name rejected before any guest call' -Condition ($r.Error -match 'Invalid package name' -and $r.Error -match 'bad;rm' -and $global:SwScripts.Count -eq 0) -Detail $r.Error
$r = Invoke-TestHandler -Handler 'Set-GuestAlmaLinuxBaseline.ps1' -Parameters (Merge-Sw $lnxBase @{ JoinDomain = $false; ExtraPackages = '--nogpgcheck'; Context = $ctx })
Assert-Test -Name 'Linux: option-like package name rejected' -Condition ($r.Error -match 'Invalid package name') -Detail $r.Error
$r = Invoke-TestHandler -Handler 'Set-GuestAlmaLinuxBaseline.ps1' -Parameters (Merge-Sw $lnxBase @{ JoinDomain = $true; Context = $ctx })
Assert-Test -Name 'Linux: DomainName required when joining' -Condition ($r.Error -match 'DomainName is required') -Detail $r.Error
$r = Invoke-TestHandler -Handler 'Set-GuestAlmaLinuxBaseline.ps1' -Parameters (Merge-Sw $lnxBase @{ JoinDomain = $true; DomainName = 'corp.test.local'; Context = $ctx })
Assert-Test -Name 'Linux: join without credential fails' -Condition ($r.Error -match 'no DomainJoinCredential') -Detail $r.Error

$global:SwLinuxId = 'ubuntu'
$r = Invoke-TestHandler -Handler 'Set-GuestAlmaLinuxBaseline.ps1' -Parameters (Merge-Sw $lnxBase @{ JoinDomain = $false; Context = $ctx })
Assert-Test -Name 'Linux: non-AlmaLinux distribution rejected' -Condition ($r.Error -match "ID=ubuntu") -Detail $r.Error
$global:SwLinuxId = 'almalinux'

Reset-Sw
$r = Invoke-TestHandler -Handler 'Set-GuestAlmaLinuxBaseline.ps1' -Parameters (Merge-Sw $lnxBase @{
    JoinDomain = $true; DomainName = 'CORP.test.local'; DomainJoinCredential = (New-SwCred 'CORP\svc-join' $joinPw); ComputerOU = 'OU=Linux,OU=Servers,DC=corp,DC=test,DC=local'
    SudoGroups = 'linux-admins, dba-team'; NtpServers = 'ntp1.test.local,10.0.0.123'; ExtraPackages = 'vim-enhanced,tmux'; ChangeTicket = 'CHG0001'; Context = $ctx })
$texts = @($global:SwScripts | ForEach-Object Text)
$join  = $texts | Where-Object { $_ -match 'realm join' } | Select-Object -First 1
Assert-Test -Name 'Linux: baseline applied' -Condition ($null -eq $r.Error -and (@($r.Result.AppliedSections) -join ',') -eq 'packages,ntp,domain,mkhomedir,sudo,cis') -Detail "$($r.Error) $(@($r.Result.AppliedSections) -join ',')"
Assert-Test -Name 'Linux: packages incl. realmd stack + extras' -Condition (($texts -match "dnf install -y 'chrony' 'realmd' 'sssd' 'oddjob' 'oddjob-mkhomedir' 'adcli' 'samba-common-tools' 'audit' 'firewalld' 'vim-enhanced' 'tmux'").Count -eq 1)
Assert-Test -Name 'Linux: realm join with password on stdin, user without domain, OU' -Condition ($join -match [regex]::Escape("printf '%s' '$joinPw' | realm join --user='svc-join' --computer-ou='OU=Linux,OU=Servers,DC=corp,DC=test,DC=local' 'corp.test.local'"))
Assert-Test -Name 'Linux: chrony servers' -Condition (($texts -match 'server ntp1\.test\.local iburst').Count -eq 1 -and ($texts -match 'server 10\.0\.0\.123 iburst').Count -eq 1)
$sudo = $texts | Where-Object { $_ -match 'sudoers' } | Select-Object -First 1
Assert-Test -Name 'Linux: sudoers drop-in validated with visudo -cf' -Condition ($sudo -match "for g in 'linux-admins' 'dba-team'" -and $sudo -match 'visudo -cf' -and $sudo -match '/etc/sudoers.d/90-portal-groups' -and $sudo -match 'realm permit -g' -and $sudo -match 'ALL=\(ALL\) ALL')
$cis = $texts | Where-Object { $_ -match 'PermitRootLogin' } | Select-Object -First 1
Assert-Test -Name 'Linux: CIS basics (sysctl, sshd -t, pwquality, auditd, firewalld)' -Condition ($cis -match 'net.ipv4.ip_forward = 0' -and $cis -match 'PermitRootLogin no' -and $cis -match 'sshd -t' -and $cis -match 'minlen = 14' -and $cis -match 'enable --now auditd' -and $cis -match 'enable --now firewalld')
Assert-Test -Name 'Linux: join password never in job log' -Condition (-not (@($r.Log) -match [regex]::Escape($joinPw)) -and (@($r.Log) -match 'domain \[sensitive')) -Detail (@($r.Log) -join ' | ')
Assert-Test -Name 'Linux: only the join script carries the password' -Condition (($texts -match [regex]::Escape($joinPw)).Count -eq 1)

Reset-Sw
$global:SwLinuxRealms = 'corp.test.local'
$r = Invoke-TestHandler -Handler 'Set-GuestAlmaLinuxBaseline.ps1' -Parameters (Merge-Sw $lnxBase @{ JoinDomain = $true; DomainName = 'corp.test.local'; ApplyCisBasics = $false; Context = $ctx })
Assert-Test -Name 'Linux: already joined = join skipped (idempotent), no credential needed' -Condition ($null -eq $r.Error -and -not ($global:SwScripts | Where-Object { $_.Text -match 'realm join' }) -and @($r.Result.AppliedSections) -contains 'domain (already joined)') -Detail $r.Error
$global:SwLinuxRealms = ''
#endregion

#region Syntax of every generated guest script -----------------------------------------------------------------
$psBad = @(); $shBad = @()
foreach ($rec in @($global:SwAll | Where-Object { $_.Text -ne 'x' -and $_.Text -notmatch '^(Write-Output hello|echo .TopSecret99.)$' })) {
    if ($rec.Type -eq 'Powershell') {
        foreach ($t in $rec.Text, $rec.Wrapped) { $e = $null; $null = [System.Management.Automation.Language.Parser]::ParseInput($t, [ref]$null, [ref]$e); if ($e) { $psBad += "$($e[0].Message) :: $($t.Substring(0, [math]::Min(60, $t.Length)))" } }
    }
    elseif (Get-Command bash -ErrorAction SilentlyContinue) {
        $out = $rec.Wrapped | & bash -n 2>&1; if ($LASTEXITCODE) { $shBad += "$out" }
    }
}
Assert-Test -Name "Syntax: all generated PowerShell guest scripts parse ($(@($global:SwAll | Where-Object Type -eq 'Powershell').Count))" -Condition (-not $psBad) -Detail ($psBad -join ' | ')
Assert-Test -Name "Syntax: all generated Bash guest scripts pass bash -n ($(@($global:SwAll | Where-Object Type -eq 'Bash').Count))" -Condition (-not $shBad) -Detail ($shBad -join ' | ')
#endregion

'Get-VM', 'Get-VMGuest', 'Invoke-VMScript', 'Restart-VMGuest', 'Get-SwDecoded' | ForEach-Object { Remove-Item "function:global:$_" -ErrorAction SilentlyContinue }
Remove-Variable -Name SwVMs, SwScripts, SwAll, SwRestarts, SwResponder, SwSqlRaw, SwSqlSetupFound, SwSqlCaption, SwLinuxId, SwLinuxRealms -Scope Global -ErrorAction SilentlyContinue
