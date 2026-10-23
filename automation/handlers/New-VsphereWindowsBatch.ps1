#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - builds one or many Windows VMs from a CSV list: clone, hardware, network, extra disks, then a
    portal-driven in-guest bootstrap (network, rename, Windows Update, activation, firewall / RDP, disks, domain
    join, local accounts), read-only validation and a closure report.
.DESCRIPTION
    1. Validate   every CSV row (names, sizes, IP / gateway / prefix, duplicates, existing VMs, portgroups). With
                  ValidateOnly the job stops here and returns the per-row result (use it before approval).
    2. Deploy     clone from the template with the site customization spec (per-VM non-persistent copy), CPU /
                  memory, portgroup, primary disk growth, extra disks, VM notes, power on, wait for customization.
    3. Bootstrap  per-VM state machine driven from the portal through VMware Tools, up to MaxParallel VMs at a time:
                  NETWORK (static only) > RENAME > reboot > UPDATES (rounds, reboots) > ACTIVATION > FIREWALL >
                  DISKS > DOMAIN_JOIN > reboot > ACCOUNTS > CLEANUP > DONE.
                  Profile Citrix skips Windows Update, activation and firewall (template already prepared).
                  A VM that does not progress for operations.batchBuild.stuckMinutes is marked STUCK and left as is.
    4. Validate   read-only checks per VM (host name, domain, IP, activation, volumes, CD-ROM, RDP, local groups,
                  no leftover files) and a closure report (HTML + CSV) with ticket text.
    Security: no password is written in the guest or on the command line. The domain password and the local
    account password are sent only inside the step that needs them (sensitive, never logged).
    Rollback: with jobs.rollbackOnFailure a VM whose clone / reconfiguration failed is deleted; VMs that fail in the
    bootstrap are kept for troubleshooting.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] [string] $Cluster,
    [Parameter(Mandatory)] [string] $Datastore,
    [Parameter(Mandatory)] [string] $Template,
    [Parameter(Mandatory)] [string] $CustomizationSpec,
    [string] $Folder,
    [Parameter(Mandatory)] [string] $VmList,
    [ValidateSet('Standard', 'Citrix')] [string] $Profile = 'Standard',
    [Parameter(Mandatory)] [pscredential] $GuestCredential,
    [bool] $JoinDomain = $true,
    [string] $Domain,
    [string] $OUPath,
    [pscredential] $DomainCredential,
    [string] $LocalAdmins,
    [string] $RemoteDesktopUsers,
    [pscredential] $LocalAccount,
    [bool] $WindowsUpdate = $true,
    [ValidateSet('Keep', 'EnableRdpRule', 'Disable')] [string] $FirewallMode = 'EnableRdpRule',
    [ValidateSet('Default', '64K')] [string] $AllocationUnit = 'Default',
    [ValidateRange(1, 10)] [int] $MaxParallel = 5,
    [bool] $ValidateOnly = $false,
    [string] $ChangeTicket,
    [System.Collections.IDictionary] $VmNotes,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}
Import-Module (Join-Path $Context.PortalRoot 'automation/lib/Portal.Guest.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $Context.PortalRoot 'automation/lib/Portal.WindowsBuild.psm1') -Force -DisableNameChecking

$vi = $Context.VIServer
$bb = if ($Context.Operations -and $Context.Operations.Contains('batchBuild')) { $Context.Operations.batchBuild } else { @{} }
function Get-BbSetting { param([string] $K, $D) if ($bb -and $bb.Contains($K) -and $null -ne $bb[$K] -and "$($bb[$K])" -ne '') { $bb[$K] } else { $D } }
$pollSeconds   = if ($Context.PSObject.Properties['BatchPollSeconds']) { [int]$Context.BatchPollSeconds } else { [int](Get-BbSetting 'pollSeconds' 30) }
$stuckMinutes  = [double](Get-BbSetting 'stuckMinutes' 45)
$updateRounds  = [int](Get-BbSetting 'updateRounds' 3)
$updateMinutes = [double](Get-BbSetting 'updateRoundMinutes' 120)
$customizeMin  = [double](Get-BbSetting 'customizationMinutes' 40)
$joinAttempts  = [int](Get-BbSetting 'domainJoinAttempts' 3)
$siteDns = @($Context.Site.defaults.dnsServers | Where-Object { $_ })
if (-not $Domain -and $Context.Site.defaults.Contains('dnsDomain')) { $Domain = [string]$Context.Site.defaults.dnsDomain }
$adminList = @(if ($LocalAdmins) { $LocalAdmins -split '[,;\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ } })
$rdpList = @(if ($RemoteDesktopUsers) { $RemoteDesktopUsers -split '[,;\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ } })
foreach ($a in @($adminList + $rdpList)) { if ($a -notmatch '^([A-Za-z0-9][A-Za-z0-9._-]{0,63}\\)?[A-Za-z0-9][A-Za-z0-9 ._$-]{0,103}$') { throw "Account '$a' is not valid (DOMAIN\name or a local name)." } }
if ($LocalAccount -and ($LocalAccount.UserName -split '\\')[-1] -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,19}$') { throw 'The local account name (vault entry user name) must be 1-20 letters, digits, ., _ or -.' }
$secrets = @($GuestCredential.GetNetworkCredential().Password)
if ($DomainCredential) { $secrets += $DomainCredential.GetNetworkCredential().Password }
if ($LocalAccount) { $secrets += $LocalAccount.GetNetworkCredential().Password }
$au = if ($AllocationUnit -eq '64K') { 65536 } else { 0 }
$light = $Profile -eq 'Citrix'

# =====================================================================================================
# 1. Validate
# =====================================================================================================
Write-JobLog -Level STEP 'Validating the VM list and placement'
$parsed = ConvertFrom-PortalBuildCsv -Text $VmList -MaxRows ([int](Get-BbSetting 'maxVms' 20)) -DefaultDns $siteDns
$rows = @($parsed.Rows); $rowErrors = $parsed.Errors
$allowed = @($Context.Site.defaults.allowedClusters | Where-Object { $_ })
if ($allowed -and $allowed -notcontains $Cluster) { throw "Cluster '$Cluster' is not allowed for $Site (allowed: $($allowed -join ', '))." }
$clusterObj = Get-Cluster -Name $Cluster -Server $vi -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $clusterObj) { throw "Cluster '$Cluster' was not found in $Site." }
$dsObj = @(Get-Datastore -Name $Datastore -Server $vi -ErrorAction SilentlyContinue)[0]
if (-not $dsObj) { $dsObj = @(Get-DatastoreCluster -Name $Datastore -Server $vi -ErrorAction SilentlyContinue)[0] }
if (-not $dsObj) { throw "Datastore or datastore cluster '$Datastore' was not found." }
$tplObj = Get-Template -Name $Template -Server $vi -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $tplObj) { throw "Template '$Template' was not found in $Site." }
$specObj = Get-OSCustomizationSpec -Name $CustomizationSpec -Server $vi -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $specObj) { throw "Customization spec '$CustomizationSpec' was not found (site catalog value windowsCustomizationSpec)." }
if ($JoinDomain -and -not $light -and -not $Domain) { throw 'Domain is required to join the domain (or clear "Join domain").' }
if ($JoinDomain -and -not $DomainCredential) { throw 'A domain join credential (vault) is required to join the domain.' }
if ($OUPath -and $OUPath -notmatch '^(?i)OU=.+,DC=.+') { throw "OU path '$OUPath' must be a distinguished name (OU=...,DC=...)." }
$pgNames = @{}
foreach ($pg in @(Get-VirtualPortGroup -Server $vi -ErrorAction SilentlyContinue)) { $pgNames[[string]$pg.Name] = $true }
$freeGB = [double]$(if ($dsObj.PSObject.Properties['FreeSpaceGB']) { $dsObj.FreeSpaceGB } else { 0 })
$needGB = 0
foreach ($r in $rows) {
    $e = [System.Collections.Generic.List[string]]::new(); foreach ($x in @($rowErrors["$($r.Row)"])) { if ($x) { $e.Add($x) } }
    if ($r.VMName -and (Get-VM -Name $r.VMName -Server $vi -ErrorAction SilentlyContinue)) { $e.Add("A VM named $($r.VMName) already exists.") }
    if ($r.Portgroup -and $pgNames.Count -and -not $pgNames.ContainsKey($r.Portgroup)) { $e.Add("Portgroup '$($r.Portgroup)' was not found.") }
    $needGB += [math]::Max([double]$r.DiskGB, 60) + (($r.ExtraDisksGB | Measure-Object -Sum).Sum)
    $rowErrors["$($r.Row)"] = @($e)
}
$checkRows = @($rows | ForEach-Object {
    $errs = @($rowErrors["$($_.Row)"])
    [ordered]@{ Row = $_.Row; VM = $_.VMName; Hostname = $_.Hostname; 'vCPU / GB' = "$($_.CPU) / $($_.MemoryGB)"; Portgroup = $_.Portgroup
                IP = $(if ($_.IP) { "$($_.IP)/$($_.PrefixLength) gw $($_.Gateway)" } else { 'DHCP' }); 'Extra disks' = (@(for ($k = 0; $k -lt @($_.ExtraDisksGB).Count; $k++) { "$($_.DriveLetters[$k]):$($_.ExtraDisksGB[$k]) GB" }) -join ', ')
                Result = $(if ($errs.Count) { 'FAIL ' + ($errs -join ' ') } else { 'OK' }) } })
$invalid = @($checkRows | Where-Object { $_.Result -ne 'OK' }).Count
if ($freeGB -gt 0 -and $needGB -gt $freeGB) { Write-JobLog -Level WARN "Provisioned size about $([math]::Round($needGB)) GB; datastore $Datastore has $([math]::Round($freeGB)) GB free (thin disks may still fit)." }
Write-JobLog "$($rows.Count) VM(s), $invalid invalid row(s)."
if ($ValidateOnly -or $invalid) {
    $files = New-PortalReport -Title "Windows build - validation$(if ($invalid) { ' (errors)' })" -Subtitle "$Site / $Cluster / $Datastore" -Context $Context -FileName 'build-validation' `
        -Sections @(New-PortalReportSection -Title 'VM list' -Columns 'Row', 'VM', 'Hostname', 'vCPU / GB', 'Portgroup', 'IP', 'Extra disks', 'Result' -Rows $checkRows) -Summary ([ordered]@{ VMs = $rows.Count; Invalid = $invalid })
    if ($invalid) { throw "$invalid row(s) of the VM list are not valid: $(@($checkRows | Where-Object { $_.Result -ne 'OK' } | ForEach-Object { "row $($_.Row) $($_.VM): $($_.Result.Substring(5))" }) -join ' | ')" }
    return [ordered]@{ ValidateOnly = $true; VMs = $rows.Count; Valid = $rows.Count; Report = $files[0].name; NextSteps = @('Submit again with "Validate only" cleared to build the VMs.') }
}

# =====================================================================================================
# 2. Deploy
# =====================================================================================================
$folderObj = $null
if ($Folder) {
    $parts = @($Folder -split '/' | Where-Object { $_ })
    $dcObj = Get-Datacenter -Name $parts[0] -Server $vi
    $folderObj = Get-Folder -Name 'vm' -Location $dcObj -Type VM -NoRecursion -Server $vi
    foreach ($p in ($parts | Select-Object -Skip 1)) { $folderObj = Get-Folder -Name $p -Location $folderObj -Type VM -NoRecursion -Server $vi }
}
elseif ($Context.Site.defaults.vmFolder) { $folderObj = Get-Folder -Name ([string]$Context.Site.defaults.vmFolder) -Type VM -Server $vi -ErrorAction SilentlyContinue | Select-Object -First 1 }

$state = [ordered]@{}
foreach ($r in $rows) { $state[$r.VMName] = [pscustomobject]@{ Row = $r; VM = $null; State = 'DEPLOY'; Since = (Get-Date); Error = $null; Warnings = [System.Collections.Generic.List[string]]::new(); Boot = $null; Next = $null; Rounds = 0; JoinTries = 0; History = [System.Collections.Generic.List[string]]::new(); Checks = @() } }
function Set-VmState {
    param($S, [string] $New, [string] $Note)
    $S.History.Add(('{0:HH:mm:ss} {1} -> {2}{3}' -f (Get-Date), $S.State, $New, $(if ($Note) { " ($Note)" })))
    Write-JobLog "$($S.Row.VMName): $($S.State) -> $New$(if ($Note) { " ($Note)" })"
    $S.State = $New; $S.Since = Get-Date
}

Write-JobLog -Level STEP "Cloning $($rows.Count) VM(s) from $Template"
$tasks = @{}
foreach ($s in $state.Values) {
    $r = $s.Row
    try {
        $tmpSpec = New-OSCustomizationSpec -OSCustomizationSpec $specObj -Name ("SSP-$($r.VMName)-" + (Get-Date -Format 'HHmmss')) -Type NonPersistent -Server $vi
        $p = @{ Name = $r.VMName; Template = $tplObj; ResourcePool = $clusterObj; Datastore = $dsObj; OSCustomizationSpec = $tmpSpec; Server = $vi; RunAsync = $true; ErrorAction = 'Stop' }
        if ($folderObj) { $p['Location'] = $folderObj }
        $tasks[$r.VMName] = New-VM @p
    }
    catch { $s.Error = "Clone could not start: $($_.Exception.Message)"; Set-VmState $s 'FAILED' 'clone' }
}
foreach ($s in @($state.Values | Where-Object State -eq 'DEPLOY')) {
    $r = $s.Row
    try {
        $null = Wait-Task -Task $tasks[$r.VMName] -ErrorAction Stop
        $vm = Get-VM -Name $r.VMName -Server $vi -ErrorAction Stop
        $s.VM = $vm
        $null = Set-VM -VM $vm -NumCpu $r.CPU -MemoryGB $r.MemoryGB -Confirm:$false -Server $vi
        $nic = Get-NetworkAdapter -VM $vm -Server $vi | Select-Object -First 1
        if (-not $nic) { throw 'The template has no network adapter.' }
        $null = Set-NetworkAdapter -NetworkAdapter $nic -NetworkName $r.Portgroup -StartConnected:$true -Confirm:$false -Server $vi
        if ($r.DiskGB -gt 0) {
            $d0 = Get-HardDisk -VM $vm -Server $vi | Sort-Object Name | Select-Object -First 1
            if ([double]$d0.CapacityGB -lt $r.DiskGB) { $null = Set-HardDisk -HardDisk $d0 -CapacityGB $r.DiskGB -Confirm:$false -Server $vi }
            elseif ([double]$d0.CapacityGB -gt $r.DiskGB) { $s.Warnings.Add("Primary disk kept at $($d0.CapacityGB) GB (template is larger than $($r.DiskGB) GB).") }
        }
        foreach ($gb in @($r.ExtraDisksGB)) { $null = New-HardDisk -VM $vm -CapacityGB $gb -Datastore $(if ($dsObj.GetType().Name -match 'Cluster') { (Get-Datastore -RelatedObject $vm -Server $vi | Select-Object -First 1) } else { $dsObj }) -Confirm:$false -Server $vi }
        $note = @("Built by the Self-Service Portal - request $($Context.RequestId) ($((Get-Date).ToString('yyyy-MM-dd')))")
        if ($VmNotes) { foreach ($k in $VmNotes.Keys) { $note += "${k}: $($VmNotes[$k])" } }
        if ($ChangeTicket) { $note += "Change: $ChangeTicket" }
        $null = Set-VM -VM $vm -Notes ($note -join "`n") -Confirm:$false -Server $vi
        $null = Start-VM -VM $vm -Confirm:$false -Server $vi
        Set-VmState $s 'CUSTOMIZING' 'powered on'
    }
    catch {
        $s.Error = "Deploy: $($_.Exception.Message)"; Set-VmState $s 'FAILED' 'deploy'
        if ($Context.RollbackOnFailure) {
            $v = Get-VM -Name $r.VMName -Server $vi -ErrorAction SilentlyContinue
            if ($v) { try { if ([string]$v.PowerState -eq 'PoweredOn') { $null = Stop-VM -VM $v -Confirm:$false -Server $vi }; Remove-VM -VM $v -DeletePermanently -Confirm:$false -Server $vi; $s.Warnings.Add('Partially created VM deleted (rollback).') } catch { $s.Warnings.Add("Rollback failed: $($_.Exception.Message)") } }
        }
    }
}

# =====================================================================================================
# 3. Bootstrap (round-robin, MaxParallel at a time)
# =====================================================================================================
function Invoke-Step {
    param($S, [string] $Script, [string] $Description, [int] $Timeout = 600, [switch] $Sensitive)
    $p = @{ VM = $S.VM; Credential = $GuestCredential; ScriptText = $Script; Server = $vi; TimeoutSeconds = $Timeout; Description = $Description; Secrets = $secrets }
    if ($Sensitive) { $p['Sensitive'] = $true }
    $out = Invoke-PortalGuestScript @p
    return [pscustomobject]@{ Output = $out; Data = (Get-PortalGuestData -Output $out) }
}
function Test-GuestUp {
    param($S)
    try {
        $v = Get-VM -Name $S.Row.VMName -Server $vi
        if ([string]$v.ExtensionData.Guest.ToolsRunningStatus -ne 'guestToolsRunning') { return $null }
        return (Invoke-Step $S (New-WbBootScript) 'boot check' 60).Data
    }
    catch { return $null }
}
function Start-Reboot {
    param($S, [string] $Next)
    $b = Test-GuestUp $S
    $S.Boot = if ($b) { [string]$b['boot'] } else { '' }
    $S.Next = $Next
    $null = Restart-VMGuest -VM $S.VM -Confirm:$false -Server $vi
    Set-VmState $S 'REBOOTING' "then $Next"
}
function Get-NextAfter {
    param([string] $From)
    $order = @('NETWORK', 'RENAME', 'UPDATES', 'ACTIVATION', 'FIREWALL', 'DISKS', 'DOMAIN_JOIN', 'ACCOUNTS', 'CLEANUP', 'DONE')
    $i = [array]::IndexOf($order, $From)
    for ($k = $i + 1; $k -lt $order.Count; $k++) {
        $n = $order[$k]
        if ($light -and $n -in 'UPDATES', 'ACTIVATION', 'FIREWALL') { continue }
        if ($n -eq 'UPDATES' -and -not $WindowsUpdate) { continue }
        if ($n -eq 'DOMAIN_JOIN' -and -not $JoinDomain) { continue }
        return $n
    }
    return 'DONE'
}

Write-JobLog -Level STEP "Bootstrap (profile $Profile, up to $MaxParallel VM(s) in parallel)"
$deadline = (Get-Date).AddMinutes([double](Get-BbSetting 'maxBootstrapMinutes' 300))
while ($true) {
    $pending = @($state.Values | Where-Object { $_.State -notin 'DONE', 'FAILED', 'STUCK' })
    if (-not $pending.Count) { break }
    if ((Get-Date) -gt $deadline) { foreach ($s in $pending) { $s.Error = "Bootstrap time limit reached in $($s.State)."; Set-VmState $s 'STUCK' 'time limit' }; break }
    $slots = $MaxParallel
    foreach ($s in $state.Values) {
        if ($s.State -in 'DONE', 'FAILED', 'STUCK') { continue }
        if ($slots -le 0) { break }
        $slots--
        if (((Get-Date) - $s.Since).TotalMinutes -gt $(if ($s.State -eq 'UPDATES_WAIT') { $updateMinutes } elseif ($s.State -eq 'CUSTOMIZING') { $customizeMin } else { $stuckMinutes })) {
            if ($s.State -eq 'UPDATES_WAIT') { $s.Warnings.Add("Windows Update round $($s.Rounds) did not finish in $updateMinutes min; continuing."); Set-VmState $s (Get-NextAfter 'UPDATES') 'update timeout'; continue }
            $s.Error = "No progress in $($s.State) for more than $stuckMinutes min."; Set-VmState $s 'STUCK'; continue
        }
        $r = $s.Row
        try {
            switch ($s.State) {
                'CUSTOMIZING' {
                    $ev = @(Get-VIEvent -Entity $s.VM -Server $vi -MaxSamples 200 -ErrorAction SilentlyContinue | Where-Object { $_ })
                    $types = @($ev | ForEach-Object { $t = $_.GetType().Name; if ($t -eq 'PSCustomObject' -and $_.PSObject.Properties['EventType']) { $_.EventType } else { $t } })
                    if ($types -match 'CustomizationFailed|CustomizationSysprepFailed|CustomizationUnknownFailure') { throw 'Guest customization failed (see the VM events in vCenter).' }
                    if ($types -match 'CustomizationSucceeded') {
                        $b = Test-GuestUp $s
                        if ($b) { Set-VmState $s $(if ($r.IP) { 'NETWORK' } else { 'RENAME' }) 'customization done' }
                    }
                }
                'REBOOTING' {
                    $b = Test-GuestUp $s
                    if ($b -and [string]$b['boot'] -and [string]$b['boot'] -ne $s.Boot) { Set-VmState $s $s.Next 'guest back' }
                }
                'NETWORK' {
                    $x = Invoke-Step $s (New-WbNetworkScript -Row $r) "static IP $($r.IP)" 300
                    if ([string]$x.Data['gateway'] -ne 'True') { throw "Gateway $($r.Gateway) is not reachable after setting $($r.IP)/$($r.PrefixLength) (VLAN / portgroup?)." }
                    Set-VmState $s 'RENAME' 'IP set'
                }
                'RENAME' {
                    $x = Invoke-Step $s (New-WbRenameScript -Hostname $r.Hostname) "rename to $($r.Hostname)" 300
                    if ($x.Data['rename'] -eq 'done') { Set-VmState $s (Get-NextAfter 'RENAME') 'name already set' }
                    else { Start-Reboot $s (Get-NextAfter 'RENAME') }
                }
                'UPDATES' {
                    $s.Rounds++
                    $null = Invoke-Step $s (New-WbUpdateStartScript) "Windows Update round $($s.Rounds)" 300
                    Set-VmState $s 'UPDATES_WAIT' "round $($s.Rounds)"
                }
                'UPDATES_WAIT' {
                    $x = Invoke-Step $s (New-WbUpdatePollScript) 'Windows Update status' 120
                    switch ([string]$x.Data['state']) {
                        'done' {
                            $found = [int]$x.Data['found']
                            if ($found -gt 0) { $s.History.Add("updates: round $($s.Rounds) installed $($x.Data['installed']) of $found") }
                            if ([bool]$x.Data['rebootRequired'] -and $s.Rounds -lt $updateRounds) { Start-Reboot $s 'UPDATES' }
                            elseif ([bool]$x.Data['rebootRequired']) { Start-Reboot $s (Get-NextAfter 'UPDATES') }
                            elseif ($found -gt 0 -and $s.Rounds -lt $updateRounds) { Set-VmState $s 'UPDATES' 'search again' }
                            else { Set-VmState $s (Get-NextAfter 'UPDATES') "$(if ($found) { 'updates installed' } else { 'no updates' })" }
                        }
                        'failed' { $s.Warnings.Add("Windows Update failed: $($x.Data['message'])"); Set-VmState $s (Get-NextAfter 'UPDATES') 'update failed' }
                        default { }
                    }
                }
                'ACTIVATION' {
                    $x = Invoke-Step $s (New-WbActivationScript) 'activation' 240
                    if ($x.Data['licensed'] -eq 'no') { $s.Warnings.Add("Windows not activated ($($x.Data['slmgr'])) - check the KMS host / key.") }
                    Set-VmState $s (Get-NextAfter 'ACTIVATION') "licensed: $($x.Data['licensed'])"
                }
                'FIREWALL' {
                    $null = Invoke-Step $s (New-WbFirewallScript -Mode $FirewallMode) "firewall $FirewallMode" 180
                    Set-VmState $s (Get-NextAfter 'FIREWALL')
                }
                'DISKS' {
                    $x = Invoke-Step $s (New-WbDisksScript -Row $r -AllocationUnit $au) 'disks' 1800
                    foreach ($l in @($x.Output -split "\r?\n" | Where-Object { $_ -like 'DISK|*|ERROR|*' })) { $s.Warnings.Add("Disk $(($l -split '\|')[1]): $(($l -split '\|')[3])") }
                    Set-VmState $s (Get-NextAfter 'DISKS')
                }
                'DOMAIN_JOIN' {
                    $s.JoinTries++
                    try {
                        $x = Invoke-Step $s (New-WbDomainJoinScript -Domain $Domain -Credential $DomainCredential -OUPath $OUPath) "join $Domain" 300 -Sensitive
                        if ($x.Data['join'] -eq 'already') { Set-VmState $s 'ACCOUNTS' 'already joined' } else { Start-Reboot $s 'ACCOUNTS' }
                    }
                    catch {
                        if ($s.JoinTries -ge $joinAttempts) { throw }
                        Write-JobLog -Level WARN "$($r.VMName): join attempt $($s.JoinTries) failed: $($_.Exception.Message)"
                    }
                }
                'ACCOUNTS' {
                    $x = Invoke-Step $s (New-WbAccountsScript -LocalAdmins $adminList -RdpUsers $rdpList -LocalAccount $LocalAccount) 'local accounts' 300 -Sensitive:([bool]$LocalAccount)
                    foreach ($l in @($x.Output -split "\r?\n" | Where-Object { $_ -like 'ACCT|*|FAILED' })) { $s.Warnings.Add("Could not add $(($l -split '\|')[2]) to $(($l -split '\|')[1]).") }
                    Set-VmState $s 'CLEANUP'
                }
                'CLEANUP' {
                    $null = Invoke-Step $s (New-WbCleanupScript) 'cleanup' 180
                    Set-VmState $s 'DONE'
                }
            }
        }
        catch {
            $msg = Protect-PortalGuestText -Text $_.Exception.Message -Secrets $secrets
            $s.Error = "$($s.State): $msg"
            Set-VmState $s 'FAILED' $s.State
        }
    }
    if (@($state.Values | Where-Object { $_.State -notin 'DONE', 'FAILED', 'STUCK' }).Count -and $pollSeconds -gt 0) { Start-Sleep -Seconds $pollSeconds }
}

# =====================================================================================================
# 4. Validate (read-only) and closure report
# =====================================================================================================
Write-JobLog -Level STEP 'Validation'
$checkRows = [System.Collections.Generic.List[object]]::new()
foreach ($s in $state.Values) {
    if ($s.State -ne 'DONE') { continue }
    $r = $s.Row
    try {
        $f = (Invoke-Step $s (New-WbValidateScript) 'validation (read-only)' 300).Data
        $add = { param($check, [bool] $ok, $value) $checkRows.Add([ordered]@{ VM = $r.VMName; Check = $check; Result = $(if ($ok) { 'PASS' } else { 'FAIL' }); Value = [string]$value }) }
        & $add 'Host name' ([string]$f['hostname'] -eq $r.Hostname) $f['hostname']
        if ($JoinDomain) { & $add 'Domain' ([bool]$f['partOfDomain'] -and ([string]$f['domain']).ToLower() -eq ([string]$Domain).ToLower()) $f['domain'] }
        if ($r.IP) { & $add 'IP address' (@($f['ipv4']) -contains $r.IP) (@($f['ipv4']) -join ', ') }
        if (-not $light) { & $add 'Activation' ([bool]$f['licensed']) $(if ($f['licensed']) { 'licensed' } else { 'not licensed' }) }
        foreach ($L in @($r.DriveLetters)) { & $add "Drive ${L}:" (@($f['volumes']) -contains $L) (@($f['volumes']) -join ', ') }
        & $add 'CD-ROM letter' ($r.DriveLetters -notcontains ([string]$f['cdrom']).TrimEnd(':')) $(if ($f['cdrom']) { $f['cdrom'] } else { 'none' })
        & $add 'RDP enabled' ([bool]$f['rdpEnabled']) $f['rdpEnabled']
        if ($FirewallMode -eq 'Disable') { & $add 'Firewall disabled' (-not @($f['firewallOn']).Count) (@($f['firewallOn']) -join ', ') }
        $admins = @($f['admins'] | ForEach-Object { ([string]$_).ToLower() })
        foreach ($a in @($adminList)) { & $add "Local admin $a" ($admins -contains $(if ($a -match '\\') { $a.ToLower() } else { "$($r.Hostname)\$a".ToLower() })) '' }
        $rdpm = @($f['rdpUsers'] | ForEach-Object { ([string]$_).ToLower() })
        foreach ($a in @($rdpList)) { & $add "RDP user $a" ($rdpm -contains $(if ($a -match '\\') { $a.ToLower() } else { "$($r.Hostname)\$a".ToLower() })) '' }
        & $add 'No leftover bootstrap files' (-not [bool]$f['leftovers']) ''
        $v = Get-VM -Name $r.VMName -Server $vi
        & $add 'VMware Tools' ([string]$v.ExtensionData.Guest.ToolsRunningStatus -eq 'guestToolsRunning') $v.ExtensionData.Guest.ToolsRunningStatus
    }
    catch { $checkRows.Add([ordered]@{ VM = $r.VMName; Check = 'Validation'; Result = 'FAIL'; Value = (Protect-PortalGuestText -Text $_.Exception.Message -Secrets $secrets) }) }
}

$vmRows = @($state.Values | ForEach-Object {
    $n = $_.Row.VMName
    $bad = @($checkRows | Where-Object { $_.VM -eq $n -and $_.Result -eq 'FAIL' })
    $status = switch ($_.State) { 'DONE' { if ($bad.Count) { 'WARN validation' } elseif ($_.Warnings.Count) { 'WARN' } else { 'OK' } } 'STUCK' { 'FAIL stuck' } default { 'FAIL' } }
    [ordered]@{ VM = $n; Hostname = $_.Row.Hostname; IP = $(if ($_.Row.IP) { $_.Row.IP } else { 'DHCP' }); State = $_.State; Status = $status
                'Failed checks' = (@($bad | ForEach-Object Check) -join ', '); Error = [string]$_.Error; Warnings = (@($_.Warnings) -join ' ') }
})
$ok = @($vmRows | Where-Object { $_.Status -notlike 'FAIL*' }).Count
$failed = @($vmRows | Where-Object { $_.Status -like 'FAIL*' }).Count
$ticket = [System.Collections.Generic.List[string]]::new()
$ticket.Add("Build of $($rows.Count) Windows VM(s) at $Site ($Cluster / $Datastore), template $Template, profile $Profile$(if ($ChangeTicket) { ", change $ChangeTicket" }).")
foreach ($v in $vmRows) { $ticket.Add("- $($v.VM) ($($v.Hostname), $($v.IP)): $($v.Status)$(if ($v.'Failed checks') { " - failed checks: $($v.'Failed checks')" })$(if ($v.Error) { " - $($v.Error)" })") }
$ticket.Add("Validation: $(@($checkRows | Where-Object Result -eq 'PASS').Count) checks passed, $(@($checkRows | Where-Object Result -eq 'FAIL').Count) failed.")
$history = @($state.Values | ForEach-Object { $n = $_.Row.VMName; @($_.History) | ForEach-Object { [ordered]@{ VM = $n; Step = $_ } } })

$files = New-PortalReport -Title 'Windows build - closure report' -Subtitle "$Site / $Cluster - profile $Profile" -Context $Context -FileName 'build-closure' -Summary ([ordered]@{
    VMs = $rows.Count; Built = $ok; Failed = $failed; 'Checks passed' = @($checkRows | Where-Object Result -eq 'PASS').Count; 'Checks failed' = @($checkRows | Where-Object Result -eq 'FAIL').Count }) -Sections @(
    New-PortalReportSection -Title 'VMs' -Columns 'VM', 'Hostname', 'IP', 'State', 'Status', 'Failed checks', 'Error', 'Warnings' -Rows $vmRows
    New-PortalReportSection -Title 'Validation checks' -Columns 'VM', 'Check', 'Result', 'Value' -Rows $checkRows
    New-PortalReportSection -Title 'Ticket text' -Columns 'Line' -Rows @($ticket | ForEach-Object { [ordered]@{ Line = $_ } }) -Note 'Ready to paste in the change / request ticket.'
    New-PortalReportSection -Title 'Bootstrap timeline' -Columns 'VM', 'Step' -Rows $history
)
Write-JobLog -Level OK "$ok of $($rows.Count) VM(s) built; $failed failed."
if (-not $ok) { throw "No VM was built: $(@($vmRows | ForEach-Object { "$($_.VM): $($_.Error)" }) -join ' | ')" }
$res = [ordered]@{
    VMs = $rows.Count; Built = $ok; Failed = $failed; Profile = $Profile
    Details = @($vmRows | ForEach-Object { "$($_.VM): $($_.Status) ($($_.State))$(if ($_.'Failed checks') { " failed checks: $($_.'Failed checks')" })$(if ($_.Error) { " - $($_.Error)" })" })
    Report = $files[0].name; ChangeTicket = $ChangeTicket
}
$next = @()
if ($failed) { $next += 'Failed / stuck VMs were kept for troubleshooting: open the console, fix the cause and use the Day 2 items, or delete them with the decommission item.' }
if (@($checkRows | Where-Object { $_.Result -eq 'FAIL' -and $_.Check -like 'Local admin*' }).Count) { $next += 'Run "Local admins & RDP users" for the missing accounts.' }
if ($next) { $res['NextSteps'] = $next }
return $res
