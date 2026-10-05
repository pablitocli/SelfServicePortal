#Requires -Version 7.2
<#
.SYNOPSIS
    Out-of-process job runner. Executes ONE portal request through its catalog handler.
.DESCRIPTION
    Started by the dispatcher (Portal.Jobs\Invoke-PortalJobDispatcher) as:
        pwsh -NoProfile -File automation/Invoke-CatalogJob.ps1 -RequestId REQ-yyyyMMdd-XXXXXX

    Contract with handlers (automation/handlers/*.ps1):
      * Parameters = the catalog item's input names + execution.fixedParameters keys (+ optional -Context).
      * -Context exposes RequestId, Requester, Site (config), VIServer (connected session), RollbackOnFailure.
      * Log with Write-JobLog "message" [-Level INFO|WARN|ERROR]; Write-Host / Write-Warning are also captured.
      * Return a hashtable with the outcome (shown to the requester). Throw to fail the job.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^REQ-\d{8}-[A-F0-9]{6}$')]
    [string] $RequestId
)

$ErrorActionPreference = 'Stop'
$root = if ($env:SSP_PORTAL_ROOT) { $env:SSP_PORTAL_ROOT } else { Split-Path -Parent $PSScriptRoot }
$env:SSP_PORTAL_ROOT = $root

Import-Module (Join-Path $root 'modules/Portal.Core.psm1')     -Force
Import-Module (Join-Path $root 'modules/Portal.Security.psm1') -Force
Import-Module (Join-Path $root 'modules/Portal.Jobs.psm1')     -Force
Import-Module (Join-Path $root 'modules/Portal.Vault.psm1')    -Force
Import-Module (Join-Path $root 'automation/lib/Portal.Vsphere.psm1') -Force
Import-Module (Join-Path $root 'automation/lib/Portal.CloudConnect.psm1') -Force

$global:SspJobLogPath = Join-Path (Get-PortalPath -Name JobLogs) "$RequestId.log"

function global:Write-JobLog {
    param(
        [Parameter(Mandatory, Position = 0)] [string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'STEP', 'OK')] [string] $Level = 'INFO'
    )
    # Never write a decrypted vault secret to the log.
    foreach ($s in $global:JobSecrets) { if ($s -and $s.Length -ge 4) { $Message = $Message.Replace($s, '********') } }
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1,-5}] {2}' -f (Get-Date), $Level, $Message
    Add-Content -LiteralPath $global:SspJobLogPath -Value $line -Encoding utf8
}

$global:JobSecrets = [System.Collections.Generic.List[string]]::new()
$vi = $null
$cloud = $null
try {
    $req = Get-PortalRequest -Id $RequestId
    if (-not $req) { throw "Request $RequestId not found." }

    $null = Update-PortalRequest -Id $RequestId -Status 'Running' -Actor 'runner' -Note "PID $PID" -Mutate {
        param($r) $r.job.pid = $PID; $r.job.startedAt = Get-PortalTimestamp; $r.job.host = [Environment]::MachineName
    }

    Write-JobLog -Level STEP "Request $RequestId - $($req.itemName) v$($req.itemVersion)"
    Write-JobLog "Requested by $($req.requester.name) ($($req.requester.username))"
    if ($req.approval.required) { Write-JobLog "Approved by $($req.approval.decidedBy) at $($req.approval.decidedAt)" }

    # Resolve handler (file name only, confined to automation/handlers).
    $handlerName = [string]$req.execution.handler
    $handlerPath = Resolve-PortalHandlerPath -Handler $handlerName -MustExist   # enforces allowed handler roots
    $declared = (Get-Command -Name $handlerPath).Parameters.Keys

    # vCenter session.
    $siteCfg = $null
    if ($req.execution.requiresVCenter) {
        $siteCode = [string]$req.inputs[$req.execution.siteInput]
        $siteCfg  = Get-PortalSite -Code $siteCode
        Write-JobLog -Level STEP "Connecting to vCenter $($siteCfg.vcenter) (site $siteCode)"
        $vi = Connect-PortalVIServer -SiteCode $siteCode
        Write-JobLog -Level OK "Connected to $($vi.Name) - vCenter $($vi.Version) build $($vi.Build)"
    }

    # Cloud session (AWS / Azure) for Cloud Ops items.
    $cloud = $null
    if ($req.execution.Contains('cloud') -and $req.execution.cloud) {
        Write-JobLog -Level STEP "Authenticating to $($req.execution.cloud.ToUpper())"
        $cloud = Connect-PortalCloud -Provider $req.execution.cloud
        Write-JobLog -Level OK "Connected to $($req.execution.cloud.ToUpper()) ($(if ($cloud.Provider -eq 'aws') { $cloud.Region } else { "subscription $($cloud.SubscriptionId)" }))"
    }

    $cfg = Get-PortalConfig
    $context = [pscustomobject]@{
        Cloud             = $cloud
        RequestId         = $RequestId
        Requester         = $req.requester
        Site              = $siteCfg
        VIServer          = $vi
        RollbackOnFailure = [bool]$cfg.jobs.rollbackOnFailure
        PortalRoot        = $root
    }

    # Build the parameter set: inputs + fixed parameters, only those the handler declares.
    $params = @{}
    foreach ($k in $req.inputs.Keys)                    { if ($declared -contains $k) { $params[$k] = $req.inputs[$k] } }
    # Fixed parameters may be per-site maps: { "DC1": "TPL-A", "DC2": "TPL-B" }.
    $siteForFixed = [string]$req.inputs[$req.execution.siteInput]
    foreach ($k in $req.execution.fixedParameters.Keys) {
        if ($declared -contains $k) { $params[$k] = Resolve-PortalSiteValue -Value $req.execution.fixedParameters[$k] -Site $siteForFixed }
    }
    if ($declared -contains 'Context') { $params['Context'] = $context }
    # Vault credentials: fixed bindings (execution.credentials) and "credential" inputs (value = vault id).
    $credBindings = [ordered]@{}
    if ($req.execution.Contains('credentials')) { foreach ($k in $req.execution.credentials.Keys) { $credBindings[$k] = [string]$req.execution.credentials[$k] } }
    if ($req.execution.Contains('credentialInputs')) { foreach ($k in @($req.execution.credentialInputs)) { if ($req.inputs.Contains($k) -and $req.inputs[$k]) { $credBindings[$k] = [string]$req.inputs[$k] } } }
    foreach ($k in $credBindings.Keys) {
        if ($declared -notcontains $k) { continue }
        $sec = Get-PortalVaultSecret -Id $credBindings[$k] -Purpose item -ItemId ([string]$req.itemId) -Teams @(if ($req.Contains('teams')) { $req.teams } else { @() }) -RequestId $RequestId -Actor 'runner'
        $global:JobSecrets.Add($sec.Credential.GetNetworkCredential().Password)
        if ($sec.Passphrase) { $global:JobSecrets.Add([System.Net.NetworkCredential]::new('', $sec.Passphrase).Password) }
        $params[$k] = $sec.Credential
        Write-JobLog "Credential $k <- vault '$($credBindings[$k])' (user $($sec.Credential.UserName))"
    }
    # VM notes section -> one ordered dictionary: Label = value (empty values skipped).
    if ($declared -contains 'VmNotes' -and $req.execution.Contains('vmNotes')) {
        $notes = [ordered]@{}
        foreach ($n in @($req.execution.vmNotes)) {
            $v = $req.inputs[$n.input]
            if ($null -ne $v -and "$v" -ne '') { $notes[[string]$n.label] = [string]$v }
        }
        $params['VmNotes'] = $notes
        Write-JobLog "VM notes: $(@($notes.Keys | ForEach-Object { "$_=$($notes[$_])" }) -join '; ')"
    }

    $safeView = ($params.GetEnumerator() | Where-Object Key -ne 'Context' | Sort-Object Key | ForEach-Object {
        if ($_.Value -is [pscredential]) { "$($_.Key)=<credential $($_.Value.UserName)>" } else { "$($_.Key)=$($_.Value)" } }) -join '; '
    Write-JobLog "Parameters: $safeView"
    Write-JobLog -Level STEP "Invoking handler $handlerName"

    $outputs = [System.Collections.Generic.List[object]]::new()
    & $handlerPath @params 3>&1 6>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.InformationRecord]) { Write-JobLog ([string]$_.MessageData) }
        elseif ($_ -is [System.Management.Automation.WarningRecord]) { Write-JobLog -Level WARN $_.Message }
        else { $outputs.Add($_) }
    }
    $result = $outputs | Where-Object { $_ -is [System.Collections.IDictionary] -or $_ -is [pscustomobject] } | Select-Object -Last 1
    $result = ConvertTo-PortalHashtable $result

    $null = Update-PortalRequest -Id $RequestId -Status 'Succeeded' -Actor 'runner' -Note 'Completed' -Mutate {
        param($r) $r.result = $result; $r.job.finishedAt = Get-PortalTimestamp
    }
    Write-JobLog -Level OK 'Job completed successfully.'
    Write-PortalAudit -Actor 'runner' -Action 'job.succeeded' -Target $RequestId
    exit 0
}
catch {
    $msg = Get-PortalErrorDetail -ErrorRecord $_
    foreach ($s in $global:JobSecrets) { if ($s -and $s.Length -ge 4) { $msg = $msg.Replace($s, '********') } }
    try {
        Write-JobLog -Level ERROR $msg
        if ($_.ScriptStackTrace) { Write-JobLog -Level ERROR ($_.ScriptStackTrace -replace "`r?`n", ' <- ') }
        $null = Update-PortalRequest -Id $RequestId -Status 'Failed' -Actor 'runner' -Note $msg -Mutate {
            param($r) $r.error = $msg; $r.job.finishedAt = Get-PortalTimestamp
        }
        Write-PortalAudit -Actor 'runner' -Action 'job.failed' -Target $RequestId -Details @{ error = $msg }
    }
    catch { Write-Error "Could not record failure for ${RequestId}: $($_.Exception.Message)" }
    exit 1
}
finally {
    if ($cloud) { Disconnect-PortalCloud -Cloud $cloud }
    if ($vi) {
        Disconnect-PortalVIServer -Server $vi
        Write-JobLog 'Disconnected from vCenter.'
    }
}
