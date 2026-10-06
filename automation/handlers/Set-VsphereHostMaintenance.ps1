#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - puts an ESXi host into maintenance mode (with evacuation) or takes it out again.
.DESCRIPTION
    Used by catalog item host-maintenance (Admin only, re-authentication required, no approval).

    Enter pre-checks: host belongs to the cluster; at least one other connected host remains; N+1 memory - the
    powered-on VMs of the cluster must fit in 90 % of the memory of the remaining connected hosts; DRS must be fully
    automated (it performs the evacuation). HA admission control settings are logged for the record.
    Enter: Set-VMHost -State Maintenance -Evacuate:<EvacuatePoweredOff> (+ -VsanDataMigrationMode EnsureAccessibility
    when vSAN is enabled). The job timeout of the runner bounds a stuck evacuation.
    Exit:  Set-VMHost -State Connected.
    Evidence: the VMs on the host before the change, the authorization (Context.Authorization by / at / ip) and the
    reason are logged, returned and written to the portal audit trail (Write-PortalAudit, action host.maintenance).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] [string] $Cluster,
    [Parameter(Mandatory)] [string] $HostName,
    [Parameter(Mandatory)] [ValidateSet('Enter', 'Exit')] [string] $Action,
    [bool] $EvacuatePoweredOff = $true,
    [Parameter(Mandatory)] [string] $Reason,
    [string] $ChangeTicket,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}

$vi       = $Context.VIServer
$defaults = $Context.Site.defaults
$auth     = $Context.Authorization
$authBy   = if ($auth) { [string]$auth.by } else { '' }
$authAt   = if ($auth) { [string]$auth.at } else { '' }
$authIp   = if ($auth) { [string]$auth.ip } else { '' }

#region 1. Common checks ------------------------------------------------------------------------------------
Write-JobLog -Level STEP "$Action maintenance mode: $HostName ($Cluster)"
Write-JobLog "Requested by $($Context.Requester.username); re-authenticated by '$authBy' at $authAt from $authIp. Reason: $Reason"
if (-not $Reason.Trim()) { throw 'A reason is required.' }

$allowed = @($defaults.allowedClusters | Where-Object { $_ })
if ($allowed.Count -and -not ($allowed | Where-Object { $_ -ieq $Cluster })) { throw "Cluster $Cluster is not in the allowed clusters of site $Site ($($allowed -join ', '))." }

$cl = Get-Cluster -Name $Cluster -Server $vi
$clusterHosts = @(Get-VMHost -Location $cl -Server $vi)
$vmh = $clusterHosts | Where-Object { $_.Name -ieq $HostName } | Select-Object -First 1
if (-not $vmh) { throw "Host $HostName is not a member of cluster $Cluster." }
$state = [string]$vmh.ConnectionState

$vmsBefore = @(Get-VM -Location $vmh -Server $vi)
$vmLines   = [string[]]@($vmsBefore | ForEach-Object { "$($_.Name) ($($_.PowerState))" })
Write-JobLog "VMs on $HostName before the change ($($vmLines.Count)): $(if ($vmLines) { $vmLines -join ', ' } else { 'none' })"
#endregion

$changed = $true
if ($Action -eq 'Enter') {
    #region 2a. Enter ---------------------------------------------------------------------------------------
    if ($state -eq 'Maintenance') {
        Write-JobLog -Level WARN "$HostName is already in maintenance mode; nothing to do."
        $changed = $false
    }
    else {
        if ($state -ne 'Connected') { throw "$HostName is $state; only a connected host can enter maintenance mode from the portal." }

        if (-not $cl.DrsEnabled -or [string]$cl.DrsAutomationLevel -ne 'FullyAutomated') {
            throw "DRS must be fully automated to evacuate (cluster ${Cluster}: DRS enabled=$($cl.DrsEnabled), level=$($cl.DrsAutomationLevel))."
        }
        Write-JobLog ("HA: enabled={0}, admission control={1}, failover level={2}." -f $cl.HAEnabled, $cl.HAAdmissionControlEnabled, $cl.HAFailoverLevel)

        $remaining = @($clusterHosts | Where-Object { $_.Name -ne $vmh.Name -and [string]$_.ConnectionState -eq 'Connected' })
        if (-not $remaining) { throw "N+1 check failed: no other connected host would remain in $Cluster." }
        $onVms   = @(Get-VM -Location $cl -Server $vi | Where-Object { [string]$_.PowerState -eq 'PoweredOn' })
        $needGB  = [double](($onVms | Measure-Object -Property MemoryGB -Sum).Sum)
        $capGB   = [double](($remaining | Measure-Object -Property MemoryTotalGB -Sum).Sum) * 0.9
        Write-JobLog ("N+1: {0:N0} GB powered-on VM memory vs {1:N0} GB usable (90% of {2} remaining host(s))." -f $needGB, $capGB, $remaining.Count)
        if ($needGB -gt $capGB) {
            throw ("N+1 check failed: the {0} powered-on VMs need {1:N0} GB but the {2} remaining host(s) offer {3:N0} GB (90%). Power off or move workloads first." -f $onVms.Count, $needGB, $remaining.Count, $capGB)
        }

        $setArgs = @{ VMHost = $vmh; State = 'Maintenance'; Evacuate = $EvacuatePoweredOff; Server = $vi; Confirm = $false }
        if ($cl.VsanEnabled) { $setArgs.VsanDataMigrationMode = 'EnsureAccessibility'; Write-JobLog 'vSAN enabled: data migration mode EnsureAccessibility.' }
        Write-JobLog -Level STEP "Entering maintenance mode (evacuate powered-off VMs: $EvacuatePoweredOff)"
        $null = Set-VMHost @setArgs
        $left = @(Get-VM -Location $vmh -Server $vi | Where-Object { [string]$_.PowerState -eq 'PoweredOn' })
        if ($left) { Write-JobLog -Level WARN "Powered-on VMs still on ${HostName}: $(@($left.Name) -join ', ')" }
        Write-JobLog -Level OK "$HostName is in maintenance mode."
    }
    #endregion
}
else {
    #region 2b. Exit ----------------------------------------------------------------------------------------
    if ($state -eq 'Connected') {
        Write-JobLog -Level WARN "$HostName is not in maintenance mode; nothing to do."
        $changed = $false
    }
    else {
        if ($state -ne 'Maintenance') { throw "$HostName is $state; only a host in maintenance mode can be exited from the portal." }
        Write-JobLog -Level STEP 'Exiting maintenance mode'
        $null = Set-VMHost -VMHost $vmh -State Connected -Server $vi -Confirm:$false
        Write-JobLog -Level OK "$HostName is connected. DRS will rebalance workloads."
    }
    #endregion
}

#region 3. Evidence -----------------------------------------------------------------------------------------
if (Get-Command Write-PortalAudit -ErrorAction SilentlyContinue) {
    try {
        Write-PortalAudit -Actor $Context.Requester.username -Action 'host.maintenance' -Target $HostName -Details @{
            requestId = $Context.RequestId; site = $Site; cluster = $Cluster; action = $Action; changed = $changed
            reason = $Reason; changeTicket = $ChangeTicket; vmsBefore = $vmLines
            authorization = @{ by = $authBy; at = $authAt; ip = $authIp }
        }
        Write-JobLog 'Audit entry written (host.maintenance).'
    }
    catch { Write-JobLog -Level WARN "Audit entry could not be written: $($_.Exception.Message)" }
}
#endregion

return [ordered]@{
    HostName       = $HostName
    Cluster        = $Cluster
    Action         = $Action
    Changed        = $(if ($changed) { 'Yes' } else { 'No (already in the requested state)' })
    VMsBefore      = $vmLines
    Reason         = $Reason
    AuthorizedBy   = $authBy
    AuthorizedAt   = $authAt
    AuthorizedFrom = $authIp
    ChangeTicket   = $ChangeTicket
    NextSteps      = @($(if ($Action -eq 'Enter') { "Run 'Exit' for $HostName when the work is done." } else { "Verify DRS has rebalanced $Cluster." }))
}
