#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - creates a distributed port group (VLAN) on a vSphere Distributed Switch.
.DESCRIPTION
    Used by catalog item dpg-create. Runs inside automation/Invoke-CatalogJob.ps1 with an open vCenter session.

    Pre-checks: the switch exists; no distributed port group with the same name exists on ANY switch of the vCenter;
    the VLAN is not already used by another (non-uplink) port group of the same switch.
    Changes: New-VDPortgroup (static binding = elastic port allocation) -> uplink teaming (load balancing)
             -> security policy (promiscuous / MAC changes / forged transmits).
    On failure after the creation, the port group is removed when jobs.rollbackOnFailure = true.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] [string] $VDSwitch,
    [Parameter(Mandatory)] [ValidateRange(1, 4094)] [int] $VlanId,
    [Parameter(Mandatory)] [string] $Name,
    [string] $Purpose,
    [ValidateRange(1, 8192)] [int] $NumPorts = 8,
    [ValidateSet('LoadBalanceSrcId', 'LoadBalanceLoadBased', 'LoadBalanceIP', 'ExplicitFailover')] [string] $LoadBalancing = 'LoadBalanceSrcId',
    [bool] $SecurityPromiscuous = $false,
    [bool] $SecurityMacChanges = $false,
    [bool] $SecurityForgedTransmits = $false,
    [string] $ChangeTicket,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}

$vi = $Context.VIServer
$pg = $null

function Get-PgVlanId {
    <# Returns the access VLAN id of a distributed port group, or $null for trunk / private VLAN / untagged. #>
    param($PortGroup)
    $cfg = $PortGroup.VlanConfiguration
    if ($cfg -and $cfg.PSObject.Properties['VlanType'] -and [string]$cfg.VlanType -notmatch '^Vlan$') { return $null }
    if ($cfg -and $cfg.PSObject.Properties['VlanId'] -and $cfg.VlanId -is [ValueType]) { return [int]$cfg.VlanId }
    if ($cfg -is [ValueType]) { return [int]$cfg }
    if ($cfg -and "$cfg" -match '^VLAN (\d+)$') { return [int]$Matches[1] }
    $raw = $PortGroup.ExtensionData.Config.DefaultPortConfig.Vlan.VlanId
    if ($raw -is [ValueType]) { return [int]$raw }
    return $null
}

try {
    #region 1. Pre-checks -----------------------------------------------------------------------------------
    Write-JobLog -Level STEP 'Pre-checks'
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{2,79}$') {
        throw "Port group name '$Name' does not follow the naming convention (3-80 characters: letters, digits, '_', '.', '-'; e.g. PG-$Site-$VlanId-APP)."
    }

    $vds = Get-VDSwitch -Name $VDSwitch -Server $vi -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $vds) { throw "Distributed switch '$VDSwitch' not found in $($vi.Name)." }

    $allPgs = @(Get-VDPortgroup -Server $vi -ErrorAction SilentlyContinue)
    $dup = $allPgs | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
    if ($dup) {
        $dupSwitch = if ($dup.VDSwitch) { $dup.VDSwitch.Name } else { 'unknown switch' }
        throw "A port group named '$($dup.Name)' already exists on $dupSwitch. Port group names must be unique in the vCenter."
    }

    $switchPgs = @(Get-VDPortgroup -VDSwitch $vds -Server $vi -ErrorAction SilentlyContinue | Where-Object { -not $_.IsUplink })
    foreach ($p in $switchPgs) {
        if ((Get-PgVlanId -PortGroup $p) -eq $VlanId) {
            throw "VLAN $VlanId is already used on switch $VDSwitch by port group '$($p.Name)'. Reuse that port group or pick another VLAN."
        }
    }
    Write-JobLog "Switch $VDSwitch found ($($switchPgs.Count) port groups); name and VLAN $VlanId are free."
    #endregion

    #region 2. Create -----------------------------------------------------------------------------------------
    $notes = "$Purpose | Change: $ChangeTicket | Portal request $($Context.RequestId) by $($Context.Requester.username)"
    if ($notes.Length -gt 255) { $notes = $notes.Substring(0, 255) }
    Write-JobLog -Level STEP "Creating port group $Name (VLAN $VlanId, $NumPorts ports, static binding) on $VDSwitch"
    $pg = New-VDPortgroup -VDSwitch $vds -Name $Name -VlanId $VlanId -NumPorts $NumPorts -PortBinding Static -Notes $notes -Server $vi
    Write-JobLog -Level OK "Port group $($pg.Name) created."

    # Static binding port groups are elastic (AutoExpand) by default since vSphere 5.1; report it.
    $auto = $pg.ExtensionData.Config.AutoExpand
    if ($auto -eq $false) { Write-JobLog -Level WARN 'Port allocation is not elastic (AutoExpand = false); ask the network team to enable it.' }
    else { Write-JobLog 'Port allocation: elastic (static binding, AutoExpand).' }
    #endregion

    #region 3. Teaming and security ------------------------------------------------------------------------
    Write-JobLog -Level STEP "Teaming: load balancing $LoadBalancing"
    $team = Get-VDUplinkTeamingPolicy -VDPortgroup $pg -Server $vi
    $null = Set-VDUplinkTeamingPolicy -Policy $team -LoadBalancingPolicy $LoadBalancing -Confirm:$false

    Write-JobLog -Level STEP "Security: promiscuous=$SecurityPromiscuous, MAC changes=$SecurityMacChanges, forged transmits=$SecurityForgedTransmits"
    $sec = Get-VDSecurityPolicy -VDPortgroup $pg -Server $vi
    $null = Set-VDSecurityPolicy -Policy $sec -AllowPromiscuous $SecurityPromiscuous -MacChanges $SecurityMacChanges -ForgedTransmits $SecurityForgedTransmits -Confirm:$false
    if ($SecurityPromiscuous -or $SecurityMacChanges -or $SecurityForgedTransmits) {
        Write-JobLog -Level WARN 'One or more security exceptions are enabled (hardening baseline expects Reject). Make sure the change ticket documents why.'
    }
    Write-JobLog -Level OK "Port group $Name configured."
    #endregion
}
catch {
    $msg = $_.Exception.Message
    if ($pg -and $Context.RollbackOnFailure) {
        Write-JobLog -Level WARN "Rolling back: removing port group $($pg.Name)"
        try { Remove-VDPortgroup -VDPortgroup $pg -Confirm:$false; Write-JobLog -Level OK 'Port group removed.' }
        catch { Write-JobLog -Level ERROR "Rollback failed: $($_.Exception.Message). Remove $($pg.Name) manually." }
    }
    throw $msg
}

return [ordered]@{
    PortGroup     = $pg.Name
    VDSwitch      = $VDSwitch
    VlanId        = $VlanId
    NumPorts      = $NumPorts
    LoadBalancing = $LoadBalancing
    Security      = "Promiscuous=$SecurityPromiscuous; MacChanges=$SecurityMacChanges; ForgedTransmits=$SecurityForgedTransmits"
    ChangeTicket  = $ChangeTicket
    NextSteps     = @("Run the inventory refresh so '$Name' appears in the port group lists of the portal.",
                      "Confirm VLAN $VlanId is trunked to the uplinks of $VDSwitch on the physical switches.")
}
