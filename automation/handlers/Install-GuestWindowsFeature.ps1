#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - installs a predefined Windows Server role/feature bundle, or configures MSDTC, inside a VM.
.DESCRIPTION
    Runs inside the guest through VMware Tools guest operations (automation/lib/Portal.Guest.psm1); no WinRM.
    Bundles:
      IIS                Web-Server, Web-Mgmt-Console, Web-Asp-Net45, Web-Net-Ext45
      DotNet             NET-Framework-45-Core, NET-Framework-Features (.NET 3.5 needs the Windows media or
                         Windows Update / WSUS reachable by the guest)
      FailoverClustering Failover-Clustering, RSAT-Clustering
      FileServer         FS-FileServer
      MSDTC              no feature install: configures the LOCAL DTC network settings (Set-DtcNetworkSetting
                         -DtcName Local), enables the "Distributed Transaction Coordinator" firewall rule group,
                         restarts the MSDTC service and verifies with Get-DtcNetworkSetting.
                         A clustered DTC resource (WSFC role) is not configured by this item.
    Install-WindowsFeature is idempotent (already installed features report NoChangeNeeded).
    Restart: the result reports RestartNeeded; the guest is restarted only when RestartIfNeeded is true.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] [string] $VMName,
    [Parameter(Mandatory)] [pscredential] $GuestCredential,
    [Parameter(Mandatory)] [ValidateSet('IIS', 'DotNet', 'FailoverClustering', 'MSDTC', 'FileServer')] [string] $Features,
    [bool] $MsdtcNetworkAccess = $true,
    [bool] $MsdtcAllowInbound = $true,
    [bool] $MsdtcAllowOutbound = $true,
    [ValidateSet('Mutual', 'Incoming', 'NoAuth')] [string] $MsdtcAuthentication = 'Mutual',
    [bool] $RestartIfNeeded = $false,
    [string] $ChangeTicket,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}
Import-Module (Join-Path $Context.PortalRoot 'automation/lib/Portal.Guest.psm1') -Force -DisableNameChecking

$vi = $Context.VIServer
function Q([string] $v) { ConvertTo-PortalGuestLiteral -Value $v }
function B([bool] $v) { if ($v) { '$true' } else { '$false' } }

$bundles = [ordered]@{
    IIS                = @('Web-Server', 'Web-Mgmt-Console', 'Web-Asp-Net45', 'Web-Net-Ext45')
    DotNet             = @('NET-Framework-45-Core', 'NET-Framework-Features')
    FailoverClustering = @('Failover-Clustering', 'RSAT-Clustering')
    FileServer         = @('FS-FileServer')
    MSDTC              = @()
}

Write-JobLog -Level STEP "Pre-checks on $VMName"
$g = Resolve-PortalGuestVM -Name $VMName -Server $vi -ExpectedFamily windows
$vm = $g.VM
$facts = Get-PortalGuestData -Output (Invoke-PortalGuestScript -VM $vm -Server $vi -Credential $GuestCredential -Type PowerShell -TimeoutSeconds 300 -Description 'collect facts' -ScriptText @'
$os = Get-CimInstance Win32_OperatingSystem
Write-Output ('__SSP_KV:Caption=' + $os.Caption)
Write-Output ('__SSP_KV:ProductType=' + $os.ProductType)
Write-Output ('__SSP_KV:ServerManager=' + [bool](Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue))
Write-Output ('__SSP_KV:Dtc=' + [bool](Get-Command Set-DtcNetworkSetting -ErrorAction SilentlyContinue))
'@)
if ([string]$facts.ProductType -eq '1' -or [string]$facts.Caption -notmatch 'Windows Server') { throw "$VMName runs '$($facts.Caption)'. Roles and features are installed on Windows Server only." }
Write-JobLog "Guest: $($facts.Caption)"

$result = [ordered]@{ VMName = $VMName; Bundle = $Features }
$restartNeeded = $false

if ($Features -eq 'MSDTC') {
    if ($facts.Dtc -ne 'True') { throw "The MsDtc PowerShell module (Set-DtcNetworkSetting) is not available on $VMName." }
    $inbound = $MsdtcAllowInbound; $outbound = $MsdtcAllowOutbound
    if (-not $MsdtcNetworkAccess -and ($inbound -or $outbound)) {
        Write-JobLog -Level WARN 'Network DTC access is disabled: inbound and outbound transactions are disabled too.'
        $inbound = $false; $outbound = $false
    }
    $auth = switch ($MsdtcAuthentication) { 'Mutual' { 'Mutual' } 'Incoming' { 'Incoming' } 'NoAuth' { 'NoAuth' } }
    if ($auth -eq 'NoAuth') { Write-JobLog -Level WARN 'MSDTC authentication NoAuth: use only when a partner cannot do mutual authentication (e.g. cross-domain without trust).' }
    Write-JobLog -Level STEP "Configuring MSDTC (network access $MsdtcNetworkAccess, inbound $inbound, outbound $outbound, authentication $auth)"
    $dtcScript = @"
Set-DtcNetworkSetting -DtcName Local -AuthenticationLevel $(Q $auth) -InboundTransactionsEnabled $(B $inbound) -OutboundTransactionsEnabled $(B $outbound) -RemoteClientAccessEnabled $(B $MsdtcNetworkAccess) -RemoteAdministrationAccessEnabled `$false -XATransactionsEnabled `$false -LUTransactionsEnabled `$true -Confirm:`$false
if ($(B $MsdtcNetworkAccess)) { Enable-NetFirewallRule -DisplayGroup 'Distributed Transaction Coordinator' }
Restart-Service -Name MSDTC -Force
(Get-Service -Name MSDTC).WaitForStatus('Running', [TimeSpan]::FromMinutes(2))
`$s = Get-DtcNetworkSetting -DtcName Local
`$fw = @(Get-NetFirewallRule -DisplayGroup 'Distributed Transaction Coordinator' -ErrorAction SilentlyContinue | Where-Object { `$_.Enabled -eq 'True' }).Count
Write-Output ('__SSP_JSON=' + (ConvertTo-Json -Compress -InputObject ([ordered]@{
    AuthenticationLevel = [string]`$s.AuthenticationLevel
    Inbound = [bool]`$s.InboundTransactionsEnabled; Outbound = [bool]`$s.OutboundTransactionsEnabled
    RemoteClient = [bool]`$s.RemoteClientAccessEnabled; RemoteAdmin = [bool]`$s.RemoteAdministrationAccessEnabled
    XA = [bool]`$s.XATransactionsEnabled; LU = [bool]`$s.LUTransactionsEnabled
    Service = [string](Get-Service -Name MSDTC).Status; FirewallRulesEnabled = `$fw })))
"@
    $d = Get-PortalGuestData -Output (Invoke-PortalGuestScript -VM $vm -Server $vi -Credential $GuestCredential -ScriptText $dtcScript -Type PowerShell -TimeoutSeconds 600 -Description 'configure MSDTC')
    $mismatch = @()
    if ([string]$d.AuthenticationLevel -ne $auth) { $mismatch += "AuthenticationLevel=$($d.AuthenticationLevel)" }
    if ([bool]$d.Inbound -ne $inbound) { $mismatch += "Inbound=$($d.Inbound)" }
    if ([bool]$d.Outbound -ne $outbound) { $mismatch += "Outbound=$($d.Outbound)" }
    if ([bool]$d.RemoteClient -ne $MsdtcNetworkAccess) { $mismatch += "RemoteClientAccess=$($d.RemoteClient)" }
    if ([string]$d.Service -ne 'Running') { $mismatch += "Service=$($d.Service)" }
    if ($mismatch) { throw "MSDTC verification failed on ${VMName}: $($mismatch -join ', ')." }
    Write-JobLog -Level OK "MSDTC verified: auth $($d.AuthenticationLevel), inbound $($d.Inbound), outbound $($d.Outbound), network access $($d.RemoteClient), firewall rules enabled $($d.FirewallRulesEnabled)"
    $result.MsdtcAuthentication = [string]$d.AuthenticationLevel
    $result.MsdtcNetworkAccess  = [bool]$d.RemoteClient
    $result.MsdtcInbound        = [bool]$d.Inbound
    $result.MsdtcOutbound       = [bool]$d.Outbound
    $result.FirewallRules       = [int]$d.FirewallRulesEnabled
}
else {
    if ($facts.ServerManager -ne 'True') { throw "Install-WindowsFeature is not available on $VMName (ServerManager module missing)." }
    $names = $bundles[$Features]
    Write-JobLog -Level STEP "Installing $Features bundle: $($names -join ', ')"
    $list = ($names | ForEach-Object { Q $_ }) -join ', '
    $featScript = @"
`$names = @($list)
`$unknown = @(`$names | Where-Object { -not (Get-WindowsFeature -Name `$_) })
if (`$unknown) { throw ('Feature(s) not available on this OS: ' + (`$unknown -join ', ')) }
`$before = @(Get-WindowsFeature -Name `$names | Where-Object { `$_.Installed } | ForEach-Object { `$_.Name })
try { `$r = Install-WindowsFeature -Name `$names }
catch {
    if (`$_.Exception.Message -match '0x800f081f|source files could not be found') { throw ('Source files not found (.NET 3.5 needs the Windows media sources\sxs or Windows Update/WSUS). ' + `$_.Exception.Message) }
    throw
}
if (-not `$r.Success) { throw ('Install-WindowsFeature failed: exit code ' + `$r.ExitCode) }
`$after = @(Get-WindowsFeature -Name `$names | Where-Object { `$_.Installed } | ForEach-Object { `$_.Name })
Write-Output ('__SSP_JSON=' + (ConvertTo-Json -Compress -InputObject ([ordered]@{
    ExitCode = [string]`$r.ExitCode; RestartNeeded = [string]`$r.RestartNeeded
    AlreadyInstalled = @(`$before); Installed = @(`$after | Where-Object { `$before -notcontains `$_ }); Missing = @(`$names | Where-Object { `$after -notcontains `$_ }) })))
"@
    $d = Get-PortalGuestData -Output (Invoke-PortalGuestScript -VM $vm -Server $vi -Credential $GuestCredential -ScriptText $featScript -Type PowerShell -TimeoutSeconds 2700 -Description "Install-WindowsFeature $Features")
    if (@($d.Missing).Count) { throw "Feature(s) not installed after Install-WindowsFeature: $(@($d.Missing) -join ', ')." }
    $restartNeeded = ([string]$d.RestartNeeded -eq 'Yes')
    Write-JobLog -Level OK "Installed: $(if (@($d.Installed).Count) { @($d.Installed) -join ', ' } else { 'none (all present)' }); restart needed: $($d.RestartNeeded)"
    $result.Installed        = @($d.Installed)
    $result.AlreadyInstalled = @($d.AlreadyInstalled)
}

$result.RestartNeeded = $restartNeeded
$result.Restarted = $false
if ($restartNeeded) {
    if ($RestartIfNeeded) {
        Write-JobLog -Level STEP "Restarting $VMName (guest restart)"
        $null = Restart-VMGuest -VM $vm -Server $vi -Confirm:$false
        $null = Wait-PortalGuestReady -VM $vm -Server $vi -InitialDelaySeconds 60 -TimeoutSeconds 900
        Write-JobLog -Level OK "$VMName is back (VMware Tools running)"
        $result.Restarted = $true
    }
    else {
        Write-JobLog -Level WARN "$VMName needs a restart to complete the installation (RestartIfNeeded = false)."
        $result.NextSteps = @("Restart $VMName in the change window$(if ($ChangeTicket) { " ($ChangeTicket)" }) to complete the installation.")
    }
}
if ($ChangeTicket) { $result.ChangeTicket = $ChangeTicket }
return $result
