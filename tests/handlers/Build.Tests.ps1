#Requires -Version 7.2
<#
.SYNOPSIS
    Offline tests: vm-windows-batch (CSV validation, deploy, portal-driven bootstrap state machine, validation).
    The guest is simulated per VM: each step script is recognised by its "# SSP-STEP:" marker.
#>
. (Join-Path $PSScriptRoot '_TestHelpers.ps1')
Start-TestGroup 'Batch Windows build'
Import-Module (Join-Path $global:SspHandlerTestRoot 'automation/lib/Portal.WindowsBuild.psm1') -Force -Global -DisableNameChecking

#region Library: CSV ---------------------------------------------------------------------------------------------
$csv = @"
VMName,CPU,MemoryGB,Portgroup,IP,PrefixLength,Gateway,DNS,ExtraDisksGB,DriveLetters,Hostname
# comment line
APP-WEB01,4,16,VL-210,10.10.210.21,24,10.10.210.1,10.0.0.53;10.0.0.54,100;50,D;L,
APP-WEB02,2,8,VL-210,,,,,,,
APP-SQL-PRODUCTION-01,8,64,VL-220,10.10.220.15,24,10.10.220.1,,100,,SQLPROD01
"@
$p = ConvertFrom-PortalBuildCsv -Text $csv -DefaultDns @('10.0.0.53')
Assert-Test -Name 'CSV: rows parsed, comments skipped, defaults applied' -Condition ($p.Rows.Count -eq 3 -and -not $p.Errors.Count -and $p.Rows[0].DriveLetters -join ',' -eq 'D,L' -and $p.Rows[2].DriveLetters[0] -eq 'D' -and $p.Rows[2].DNS[0] -eq '10.0.0.53' -and $p.Rows[1].Hostname -eq 'APP-WEB02' -and $p.Rows[2].Hostname -eq 'SQLPROD01') -Detail ($p.Errors | ConvertTo-Json -Compress)
$bad = @"
VMName,CPU,MemoryGB,Portgroup,IP,PrefixLength,Gateway
APP-LONG-NAME-OVER-15,4,16,VL-210,10.10.210.21,24,10.10.211.1
APP-B,0,16,VL-210,10.10.210.21,24,10.10.210.1
"@
$p = ConvertFrom-PortalBuildCsv -Text $bad -DefaultDns @('10.0.0.53')
$e1 = @($p.Errors['1']) -join ' '; $e2 = @($p.Errors['2']) -join ' '
Assert-Test -Name 'CSV: host name > 15, gateway outside subnet, CPU 0, duplicate IP detected' -Condition ($e1 -match 'Host name' -and $e1 -match 'not in 10.10.210.21/24' -and $e1 -match 'used twice' -and $e2 -match 'CPU must be' -and $e2 -match 'used twice') -Detail "$e1 | $e2"
$e = $null; try { $null = ConvertFrom-PortalBuildCsv -Text "VMName,CPU,MemoryGB,Portgroup,Password`nA,1,1,PG,x" } catch { $e = $_.Exception.Message }
Assert-Test -Name 'CSV: unknown column (e.g. Password) rejected' -Condition ($e -match 'Unknown column') -Detail $e
foreach ($fn in 'New-WbBootScript', 'New-WbUpdateStartScript', 'New-WbUpdatePollScript', 'New-WbActivationScript', 'New-WbCleanupScript', 'New-WbValidateScript') {
    $t = $null; $er = $null; $null = [System.Management.Automation.Language.Parser]::ParseInput((& $fn), [ref]$t, [ref]$er)
    Assert-Test -Name "Scripts: $fn parses" -Condition (-not @($er).Count) -Detail (($er | ForEach-Object Message) -join '; ')
}
$row = (ConvertFrom-PortalBuildCsv -Text $csv -DefaultDns @('10.0.0.53')).Rows[0]
$dc = [pscredential]::new('CORP\svc-join', (ConvertTo-SecureString "J0in'Pass" -AsPlainText -Force))
$la = [pscredential]::new('localops', (ConvertTo-SecureString 'L0cal!Pass' -AsPlainText -Force))
foreach ($t in @((New-WbNetworkScript -Row $row), (New-WbRenameScript -Hostname 'APP-WEB01'), (New-WbFirewallScript -Mode EnableRdpRule), (New-WbDisksScript -Row $row -AllocationUnit 65536), (New-WbDomainJoinScript -Domain 'corp.example.com' -Credential $dc -OUPath 'OU=Servers,DC=corp,DC=example,DC=com'), (New-WbAccountsScript -LocalAdmins 'CORP\SQL-Admins' -RdpUsers 'CORP\Ops' -LocalAccount $la))) {
    $tk = $null; $er = $null; $null = [System.Management.Automation.Language.Parser]::ParseInput($t, [ref]$tk, [ref]$er)
    Assert-Test -Name "Scripts: $((($t -split "`n")[0]) -replace '# SSP-STEP:', '') parses" -Condition (-not @($er).Count) -Detail (($er | ForEach-Object Message) -join '; ')
}
Assert-Test -Name 'Scripts: quote in the join password is escaped' -Condition ((New-WbDomainJoinScript -Domain 'corp.example.com' -Credential $dc) -match "'J0in''Pass'")
Assert-Test -Name 'Scripts: no secret is written to a file' -Condition (-not ((New-WbDomainJoinScript -Domain 'c.local' -Credential $dc) -match 'Set-Content|Out-File') -and -not ((New-WbAccountsScript -LocalAccount $la) -match 'Set-Content|Out-File'))
#endregion

#region Fake vCenter + guests ---------------------------------------------------------------------------------------
function Reset-Fake {
    $global:BbVms = [ordered]@{}; $global:BbGuest = @{}; $global:BbCalls = [System.Collections.Generic.List[string]]::new(); $global:BbScripts = [System.Collections.Generic.List[string]]::new()
    $global:BbNoGateway = @(); $global:BbFailDisk = @(); $global:BbNoCustomization = @()
}
Reset-Fake
function global:Get-Cluster { param($Name, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) if ($Name -and $Name -ne 'CL-OTHER' -and $Name -notlike '*NOPE*') { [pscustomobject]@{ Name = $Name } } }
function global:Get-Datastore { param($Name, $RelatedObject, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) if ($Name -eq 'DS-APP-01' -or $RelatedObject) { [pscustomobject]@{ Name = 'DS-APP-01'; FreeSpaceGB = 4000 } } }
function global:Get-DatastoreCluster { param($Name, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) }
function global:Get-Template { param($Name, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) if ($Name -eq 'TPL-WIN2025') { [pscustomobject]@{ Name = $Name } } }
function global:Get-OSCustomizationSpec { param($Name, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) if ($Name -eq 'WIN2025-BASE') { [pscustomobject]@{ Name = $Name } } }
function global:New-OSCustomizationSpec { param($OSCustomizationSpec, $Name, $Type, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) $global:BbCalls.Add("New-OSCustomizationSpec:$Type"); [pscustomobject]@{ Name = $Name } }
function global:Get-VirtualPortGroup { param($Server, [Parameter(ValueFromRemainingArguments)] $Rest) [pscustomobject]@{ Name = 'VL-210' }; [pscustomobject]@{ Name = 'VL-220' } }
function global:Get-Folder { param($Name, $Location, $Type, [switch] $NoRecursion, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) [pscustomobject]@{ Name = $Name } }
function global:Get-Datacenter { param($Name, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) [pscustomobject]@{ Name = $Name } }
function global:Get-VM { param($Name, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) if ($global:BbVms.Contains([string]$Name)) { $global:BbVms[[string]$Name] } }
function global:New-VM {
    param($Name, $Template, $ResourcePool, $Datastore, $OSCustomizationSpec, $Location, $Server, [switch] $RunAsync, [Parameter(ValueFromRemainingArguments)] $Rest)
    $global:BbCalls.Add("New-VM:$Name")
    $global:BbVms[$Name] = [pscustomobject]@{ Name = $Name; PowerState = 'PoweredOff'; ExtensionData = [pscustomobject]@{ Guest = [pscustomobject]@{ ToolsRunningStatus = 'guestToolsNotRunning' } } }
    $global:BbGuest[$Name] = @{ name = 'WIN-TPL1234'; pending = ''; boot = 1; ip = ''; joined = $false; domain = 'WORKGROUP'; licensed = $false; volumes = @('C'); cdrom = 'D:'; admins = @('WIN-TPL1234\Administrator'); rdp = @(); leftovers = $false; wuRound = 0; wuPolls = 0 }
    [pscustomobject]@{ Id = "Task-$Name"; Name = $Name }
}
function global:Wait-Task { param($Task, [Parameter(ValueFromRemainingArguments)] $Rest) $true }
function global:Set-VM { param($VM, $NumCpu, $MemoryGB, $Notes, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) if ($Notes) { $global:BbCalls.Add("Notes:$($VM.Name):$Notes") } else { $global:BbCalls.Add("Set-VM:$($VM.Name):$NumCpu/$MemoryGB") } }
function global:Get-NetworkAdapter { param($VM, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) [pscustomobject]@{ Name = 'Network adapter 1'; VM = $VM } }
function global:Set-NetworkAdapter { param($NetworkAdapter, $NetworkName, $StartConnected, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) $global:BbCalls.Add("NIC:$($NetworkAdapter.VM.Name):$NetworkName") }
function global:Get-HardDisk { param($VM, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) [pscustomobject]@{ Name = 'Hard disk 1'; CapacityGB = 90 } }
function global:Set-HardDisk { param($HardDisk, $CapacityGB, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) $global:BbCalls.Add("Set-HardDisk:$CapacityGB") }
function global:New-HardDisk { param($VM, $CapacityGB, $Datastore, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) if ($global:BbFailDisk -contains $VM.Name) { throw 'Insufficient disk space on datastore' }; $global:BbCalls.Add("New-HardDisk:$($VM.Name):$CapacityGB") }
function global:Start-VM { param($VM, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) $global:BbCalls.Add("Start-VM:$($VM.Name)"); $VM.PowerState = 'PoweredOn'; $VM.ExtensionData.Guest.ToolsRunningStatus = 'guestToolsRunning' }
function global:Stop-VM { param($VM, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) $VM.PowerState = 'PoweredOff' }
function global:Remove-VM { param($VM, [switch] $DeletePermanently, $Server, [Parameter(ValueFromRemainingArguments)] $Rest) $global:BbCalls.Add("Remove-VM:$($VM.Name)"); $global:BbVms.Remove($VM.Name) }
function global:Get-VIEvent { param($Entity, $Server, $MaxSamples, [Parameter(ValueFromRemainingArguments)] $Rest)
    if ($global:BbNoCustomization -contains $Entity.Name) { return }
    [pscustomobject]@{ EventType = 'CustomizationStartedEvent'; FullFormattedMessage = 'Started customization' }
    [pscustomobject]@{ EventType = 'CustomizationSucceeded'; FullFormattedMessage = 'Customization succeeded' } }
function global:Restart-VMGuest { param($VM, $Server, [Parameter(ValueFromRemainingArguments)] $Rest)
    $g = $global:BbGuest[$VM.Name]; $g.boot++; if ($g.pending) { $g.name = $g.pending; $g.pending = '' }; $global:BbCalls.Add("Restart-VMGuest:$($VM.Name)") }
function global:Invoke-VMScript {
    param($VM, $Server, $GuestCredential, $ScriptText, $ScriptType, $ToolsWaitSecs, [Parameter(ValueFromRemainingArguments)] $Rest)
    $body = if ($ScriptText -match "FromBase64String\('([^']+)'\)") { [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1])) } else { $ScriptText }
    $global:BbScripts.Add($body)
    $g = $global:BbGuest[$VM.Name]
    $step = if ($body -match '# SSP-STEP:(\w+)') { $Matches[1] } else { '?' }
    $global:BbCalls.Add("Step:$($VM.Name):$step")
    $out = switch ($step) {
        'BOOT' { "__SSP_KV:boot=2026-10-22T0$($g.boot):00:00Z`n__SSP_KV:name=$($g.name)" }
        'NETWORK' { if ($body -match "\`$ip = '([\d.]+)'") { $g.ip = $Matches[1] }; "__SSP_KV:gateway=$(if ($global:BbNoGateway -contains $VM.Name) { 'False' } else { 'True' })" }
        'RENAME' { $n = if ($body -match "\`$n = '([^']+)'") { $Matches[1] } else { '' }; if ($g.name -eq $n) { '__SSP_KV:rename=done' } else { $g.pending = $n; '__SSP_KV:rename=reboot' } }
        'UPDATES_START' { $g.wuRound++; $g.wuPolls = 0; $g.leftovers = $true; '__SSP_KV:updates=started' }
        'UPDATES_POLL' { $g.wuPolls++; if ($g.wuPolls -lt 2) { '__SSP_JSON={"state":"installing","found":2}' } elseif ($g.wuRound -eq 1) { '__SSP_JSON={"state":"done","found":2,"installed":2,"rebootRequired":true}' } else { '__SSP_JSON={"state":"done","found":0,"installed":0,"rebootRequired":false}' } }
        'ACTIVATION' { $g.licensed = $true; '__SSP_KV:licensed=yes' }
        'FIREWALL' { '__SSP_KV:firewall=EnableRdpRule' }
        'DISKS' { $ls = if ($body -match "\`$letters = @\(([^)]*)\)") { @([regex]::Matches($Matches[1], "'([A-Z])'") | ForEach-Object { $_.Groups[1].Value }) } else { @() }; $g.volumes = @('C') + $ls; $g.cdrom = [string][char](68 + $ls.Count) + ':'; ($ls | ForEach-Object { "DISK|$_|OK|disk" }) -join "`n" }
        'DOMAIN_JOIN' { if ($g.joined) { '__SSP_KV:join=already' } else { $g.joined = $true; $g.domain = 'corp.example.com'; '__SSP_KV:join=reboot' } }
        'ACCOUNTS' {
            foreach ($m in [regex]::Matches($body, "Add-Members 'S-1-5-32-(544|555)' \(@\(@\(([^)]*)\)\)")) {
                $names = @([regex]::Matches($m.Groups[2].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
                if ($m.Groups[1].Value -eq '544') { $g.admins += $names } else { $g.rdp += $names }
            }
            'ACCT|Administrators|x|ADDED' }
        'CLEANUP' { $g.leftovers = $false; '__SSP_KV:cleanup=done' }
        'VALIDATE' { '__SSP_JSON=' + ([ordered]@{ hostname = $g.name; partOfDomain = $g.joined; domain = $g.domain; ipv4 = @($g.ip) | Where-Object { $_ }; licensed = $g.licensed; volumes = $g.volumes; cdrom = $g.cdrom; rdpEnabled = $true; firewallOn = @('Domain'); admins = $g.admins; rdpUsers = $g.rdp; leftovers = $g.leftovers } | ConvertTo-Json -Compress -Depth 4) }
        default { '' }
    }
    [pscustomobject]@{ ScriptOutput = "$out`n__SSP_EXIT=0"; ExitCode = 0 }
}
$guestCred = [pscredential]::new('Administrator', (ConvertTo-SecureString 'Tpl@dminPass1' -AsPlainText -Force))
function New-BbCtx { param([hashtable] $Ops = @{}) $c = New-TestContext -ItemId 'vm-windows-batch'; $c | Add-Member -NotePropertyName BatchPollSeconds -NotePropertyValue 0
    $bbOps = [ordered]@{ stuckMinutes = 45; customizationMinutes = 40 }; foreach ($k in $Ops.Keys) { $bbOps[$k] = $Ops[$k] }; $c.Operations['batchBuild'] = $bbOps; $c }
function Merge-Bb([hashtable] $Extra) { $h = @{} + $base; foreach ($k in $Extra.Keys) { $h[$k] = $Extra[$k] }; $h }
$base = @{ Site = 'DC1'; Cluster = 'CL-APP-01'; Datastore = 'DS-APP-01'; Template = 'TPL-WIN2025'; CustomizationSpec = 'WIN2025-BASE'; GuestCredential = $guestCred; DomainCredential = $dc; Domain = 'corp.example.com'; LocalAdmins = "CORP\SQL-Admins"; RemoteDesktopUsers = 'CORP\Ops' }
#endregion

#region Validate only / invalid list ------------------------------------------------------------------------------
$ctx = New-BbCtx
$r = Invoke-TestHandler -Handler 'New-VsphereWindowsBatch.ps1' -Parameters (Merge-Bb @{ VmList = $csv; ValidateOnly = $true; Context = $ctx })
Assert-Test -Name 'Validate only: report, nothing cloned' -Condition ($null -eq $r.Error -and $r.Result.ValidateOnly -and $r.Result.Valid -eq 3 -and -not ($global:BbCalls -like 'New-VM:*') -and (Get-TestReportFiles -Context $ctx) -contains 'build-validation.html') -Detail $r.Error
$r = Invoke-TestHandler -Handler 'New-VsphereWindowsBatch.ps1' -Parameters (Merge-Bb @{ VmList = "VMName,CPU,MemoryGB,Portgroup`nAPP-X1,2,8,VL-999"; Context = (New-BbCtx) })
Assert-Test -Name 'Invalid list: unknown portgroup stops the job before cloning' -Condition ($r.Error -match "row 1 APP-X1: Portgroup 'VL-999' was not found" -and -not ($global:BbCalls -like 'New-VM:*')) -Detail $r.Error
$r = Invoke-TestHandler -Handler 'New-VsphereWindowsBatch.ps1' -Parameters (Merge-Bb @{ VmList = $csv; Template = 'TPL-NOPE'; Context = (New-BbCtx) })
Assert-Test -Name 'Missing template refused' -Condition ($r.Error -match "Template 'TPL-NOPE'") -Detail $r.Error
#endregion

#region Full build ------------------------------------------------------------------------------------------------
Reset-Fake
$global:BbNoGateway = @('APP-SQL-PRODUCTION-01')
$ctx = New-BbCtx
$r = Invoke-TestHandler -Handler 'New-VsphereWindowsBatch.ps1' -Parameters (Merge-Bb @{ VmList = $csv; Context = $ctx; ChangeTicket = 'CHG0042'; VmNotes = [ordered]@{ Owner = 'App team' } })
Assert-Test -Name 'Build: 2 built, 1 failed (gateway unreachable)' -Condition ($null -eq $r.Error -and $r.Result.Built -eq 2 -and $r.Result.Failed -eq 1 -and ($r.Result.Details -match 'APP-SQL-PRODUCTION-01: FAIL.*Gateway 10.10.220.1 is not reachable')) -Detail "$($r.Error) $($r.Result.Details -join ' | ')"
Assert-Test -Name 'Build: clone with a non-persistent spec copy, hardware, NIC, disks, notes' -Condition (($global:BbCalls -contains 'New-OSCustomizationSpec:NonPersistent') -and ($global:BbCalls -contains 'Set-VM:APP-WEB01:4/16') -and ($global:BbCalls -contains 'NIC:APP-WEB01:VL-210') -and ($global:BbCalls -contains 'New-HardDisk:APP-WEB01:100') -and ($global:BbCalls -contains 'New-HardDisk:APP-WEB01:50') -and @($global:BbCalls | Where-Object { $_ -like 'Notes:APP-WEB01:*Owner: App team*Change: CHG0042*' }).Count -eq 1)
$w1 = @($global:BbCalls | Where-Object { $_ -like 'Step:APP-WEB01:*' } | ForEach-Object { ($_ -split ':')[2] } | Where-Object { $_ -ne 'BOOT' })
$expected = 'NETWORK', 'RENAME', 'UPDATES_START', 'UPDATES_POLL', 'UPDATES_POLL', 'UPDATES_START', 'UPDATES_POLL', 'UPDATES_POLL', 'ACTIVATION', 'FIREWALL', 'DISKS', 'DOMAIN_JOIN', 'ACCOUNTS', 'CLEANUP', 'VALIDATE'
Assert-Test -Name 'Build: step order for a static-IP VM (2 update rounds)' -Condition (($w1 -join ',') -eq ($expected -join ',')) -Detail ($w1 -join ',')
Assert-Test -Name 'Build: DHCP VM skips NETWORK' -Condition (-not ($global:BbCalls -contains 'Step:APP-WEB02:NETWORK') -and ($global:BbCalls -contains 'Step:APP-WEB02:RENAME'))
Assert-Test -Name 'Build: reboots after rename, update round 1 and domain join' -Condition (@($global:BbCalls | Where-Object { $_ -eq 'Restart-VMGuest:APP-WEB01' }).Count -eq 3)
$csvChecks = @(Import-Csv (Get-ChildItem $ctx.ReportDir -Filter 'build-closure-02-*.csv').FullName)
$web1 = @($csvChecks | Where-Object VM -eq 'APP-WEB01')
Assert-Test -Name 'Build: validation checks all pass for APP-WEB01' -Condition ($web1.Count -ge 9 -and -not ($web1 | Where-Object Result -eq 'FAIL')) -Detail (($web1 | Where-Object Result -eq 'FAIL' | ForEach-Object { "$($_.Check)=$($_.Value)" }) -join '; ')
Assert-Test -Name 'Build: drive and CD-ROM checks present' -Condition (($web1.Check -contains 'Drive D:') -and ($web1.Check -contains 'Drive L:') -and ($web1.Check -contains 'CD-ROM letter'))
Assert-Test -Name 'Build: passwords never logged' -Condition (-not ($r.Log -match "J0in'Pass|Tpl@dminPass1"))
Assert-Test -Name 'Build: join password only inside the DOMAIN_JOIN step' -Condition (@($global:BbScripts | Where-Object { $_ -match "J0in''Pass" }).Count -eq 2 -and -not (@($global:BbScripts | Where-Object { $_ -match "J0in''Pass" -and $_ -notmatch 'SSP-STEP:DOMAIN_JOIN' })))
Assert-Test -Name 'Build: failed VM kept for troubleshooting (no delete)' -Condition (-not ($global:BbCalls -like 'Remove-VM:*'))
$html = Get-Content -Raw (Join-Path $ctx.ReportDir 'build-closure.html')
Assert-Test -Name 'Build: closure report with ticket text and timeline' -Condition ($html -match 'Ticket text' -and $html -match 'CHG0042' -and $html -match 'Bootstrap timeline' -and $html -match 'REBOOTING')
#endregion

#region Citrix profile, rollback, stuck ----------------------------------------------------------------------------
Reset-Fake
$r = Invoke-TestHandler -Handler 'New-VsphereWindowsBatch.ps1' -Parameters (Merge-Bb @{ VmList = "VMName,CPU,MemoryGB,Portgroup`nCTX-01,2,8,VL-210"; Profile = 'Citrix'; Context = (New-BbCtx) })
$steps = @($global:BbCalls | Where-Object { $_ -like 'Step:CTX-01:*' } | ForEach-Object { ($_ -split ':')[2] })
Assert-Test -Name 'Citrix: no Windows Update, activation or firewall step' -Condition ($null -eq $r.Error -and $r.Result.Built -eq 1 -and -not ($steps -match 'UPDATES|ACTIVATION|FIREWALL') -and ($steps -contains 'DOMAIN_JOIN')) -Detail "$($r.Error) $($steps -join ',')"

Reset-Fake
$global:BbFailDisk = @('APP-B2')
$r = Invoke-TestHandler -Handler 'New-VsphereWindowsBatch.ps1' -Parameters (Merge-Bb @{ VmList = "VMName,CPU,MemoryGB,Portgroup,ExtraDisksGB`nAPP-B1,2,8,VL-210,`nAPP-B2,2,8,VL-210,500"; JoinDomain = $false; Context = (New-BbCtx) })
Assert-Test -Name 'Rollback: VM whose reconfiguration failed is deleted, the other is built' -Condition ($null -eq $r.Error -and $r.Result.Built -eq 1 -and ($global:BbCalls -contains 'Remove-VM:APP-B2') -and ($r.Result.Details -match 'APP-B2: FAIL.*Insufficient disk space')) -Detail "$($r.Error) $($r.Result.Details -join ' | ')"
Assert-Test -Name 'No domain: DOMAIN_JOIN skipped' -Condition (-not ($global:BbCalls -contains 'Step:APP-B1:DOMAIN_JOIN'))

Reset-Fake
$global:BbNoCustomization = @('APP-S1')
$r = Invoke-TestHandler -Handler 'New-VsphereWindowsBatch.ps1' -Parameters (Merge-Bb @{ VmList = "VMName,CPU,MemoryGB,Portgroup`nAPP-S1,2,8,VL-210"; Context = (New-BbCtx -Ops @{ customizationMinutes = 0.0002; stuckMinutes = 0.0002 }) })
Assert-Test -Name 'Stuck: customization never completes -> STUCK, job fails with the reason' -Condition ($r.Error -match 'No VM was built' -and $r.Error -match 'No progress in CUSTOMIZING') -Detail $r.Error
#endregion

'Get-Cluster', 'Get-Datastore', 'Get-DatastoreCluster', 'Get-Template', 'Get-OSCustomizationSpec', 'New-OSCustomizationSpec', 'Get-VirtualPortGroup', 'Get-Folder', 'Get-Datacenter', 'Get-VM', 'New-VM', 'Wait-Task',
'Set-VM', 'Get-NetworkAdapter', 'Set-NetworkAdapter', 'Get-HardDisk', 'Set-HardDisk', 'New-HardDisk', 'Start-VM', 'Stop-VM', 'Remove-VM', 'Get-VIEvent', 'Restart-VMGuest', 'Invoke-VMScript' |
    ForEach-Object { Remove-Item "function:global:$_" -ErrorAction SilentlyContinue }
