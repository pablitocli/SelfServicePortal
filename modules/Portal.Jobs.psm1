#Requires -Version 7.2
<#
.SYNOPSIS
    Portal.Jobs - request lifecycle, approval workflow, job dispatcher and inventory refresh.
.DESCRIPTION
    Request state machine:

        PendingApproval --approve--> Queued --dispatch--> Dispatched --runner--> Running --> Succeeded | Failed
              |  \--reject--> Rejected      \--cancel--> Cancelled
              \--cancel--> Cancelled

    Each request is a JSON document in data/requests/<id>.json. All mutations go through
    Update-PortalRequest, which holds a cross-process lock so web runspaces and runner processes never
    overwrite each other. Jobs run out-of-process (pwsh automation/Invoke-CatalogJob.ps1), which isolates
    PowerCLI sessions. A job still running when the portal stops is marked Failed by the dispatcher at the next start.
#>

Set-StrictMode -Version Latest

$script:Transitions = @{
    'PendingApproval' = @('Queued', 'Rejected', 'Cancelled')
    'Queued'          = @('Dispatched', 'Cancelled')
    'Dispatched'      = @('Running', 'Failed')
    'Running'         = @('Succeeded', 'Failed')
}
$script:FinalStates = @('Succeeded', 'Failed', 'Rejected', 'Cancelled')
$script:IdPattern   = '^REQ-\d{8}-[A-F0-9]{6}$'

#region Request store ---------------------------------------------------------------------------------------

function Get-RequestPath {
    param([Parameter(Mandatory)] [string] $Id)
    if ($Id -notmatch $script:IdPattern) { throw "Invalid request id '$Id'." }
    return (Join-Path (Get-PortalPath -Name Requests) "$Id.json")
}

function New-PortalRequestId {
    $rand = -join ((1..6) | ForEach-Object { '{0:X}' -f (Get-Random -Maximum 16) })
    return ('REQ-{0:yyyyMMdd}-{1}' -f (Get-Date).ToUniversalTime(), $rand)
}

function Get-PortalRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Id)
    return (Read-PortalJson -Path (Get-RequestPath -Id $Id))
}

function ConvertTo-PortalRequestSummary {
    param([Parameter(Mandatory)] $Request)
    return [ordered]@{
        id        = $Request.id
        itemId    = $Request.itemId
        itemName  = $Request.itemName
        category  = $Request.category
        status    = $Request.status
        site      = $Request.site
        target    = $Request.target
        requester = $Request.requester
        createdAt = $Request.createdAt
        updatedAt = $Request.updatedAt
        approvalRequired = $Request.approval.required
    }
}

function Get-PortalRequestList {
    <# Lists requests (newest first). Filters are optional. #>
    [CmdletBinding()]
    param(
        [string]   $Requester,
        [string[]] $Status,
        [int]      $Top = 500
    )
    $folder = Get-PortalPath -Name Requests
    $list = foreach ($f in Get-ChildItem -LiteralPath $folder -Filter 'REQ-*.json' -File) {
        try { $r = Read-PortalJson -Path $f.FullName } catch { continue }
        if (-not $r) { continue }
        if ($Requester -and $r.requester.username -ne $Requester) { continue }
        if ($Status -and $Status -notcontains $r.status) { continue }
        $r
    }
    return @($list | Sort-Object { $_.createdAt } -Descending | Select-Object -First $Top)
}

function Update-PortalRequest {
    <#
    .SYNOPSIS Locked read-modify-write of a request, with state-machine enforcement.
    .PARAMETER Status   Target status (optional). Transition must be allowed from the current status.
    .PARAMETER Mutate   Scriptblock receiving the request hashtable as $args[0] for extra changes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Id,
        [string] $Status,
        [string] $Actor = 'system',
        [string] $Note,
        [scriptblock] $Mutate
    )
    $path = Get-RequestPath -Id $Id
    Invoke-PortalLock -Name "req-$Id" -ScriptBlock {
        $req = Read-PortalJson -Path $path
        if (-not $req) { throw "Request $Id not found." }
        if ($Status -and $Status -ne $req.status) {
            $allowed = @($script:Transitions[$req.status])
            if ($allowed -notcontains $Status) { throw "Request $Id cannot move from '$($req.status)' to '$Status'." }
            $req.status = $Status
            $req.history += , ([ordered]@{ ts = (Get-PortalTimestamp); status = $Status; actor = $Actor; note = $Note })
        }
        if ($Mutate) { & $Mutate $req }
        $req.updatedAt = Get-PortalTimestamp
        Write-PortalJson -Path $path -Value $req
        $req
    }
}

function New-PortalRequest {
    <#
    .SYNOPSIS Creates a request from validated inputs. Returns the request.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Item,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Values,
        [Parameter(Mandatory)] $User,
        [System.Collections.IDictionary] $Authorization     # re-authentication evidence for sensitive items (by / at / ip)
    )
    $cfg  = Get-PortalConfig
    $exec = $Item.execution
    $approvalRequired = [bool]($Item.Contains('approval') -and $Item.approval.required)
    $siteInput = if ($exec.Contains('siteInput')) { $exec.siteInput } else { 'Site' }
    $now = Get-PortalTimestamp
    $status = if ($approvalRequired) { 'PendingApproval' } else { 'Queued' }

    $req = [ordered]@{
        id          = New-PortalRequestId
        itemId      = $Item.id
        itemName    = $Item.name
        itemVersion = $Item.version
        category    = $Item.category
        status      = $status
        site        = if ($exec.Contains('cloud') -and $exec.cloud) { ([string]$exec.cloud).ToUpper() -replace 'AZURE', 'Azure' }
                      elseif ($Values.Contains($siteInput)) { $Values[$siteInput] } else { $null }
        target      = @('VMName', 'InstanceName', 'VmName') | Where-Object { $Values.Contains($_) } | ForEach-Object { $Values[$_] } | Select-Object -First 1
        requester   = [ordered]@{ username = $User.username; name = $User.name; email = $User.email }
        teams       = @(if ($Item.Contains('access') -and $Item.access.Contains('teams')) { $Item.access.teams } else { @() })
        createdAt   = $now
        updatedAt   = $now
        inputs      = $Values
        approval    = [ordered]@{
            required      = $approvalRequired
            approverRoles = if ($approvalRequired -and $Item.approval.Contains('approverRoles')) { @($Item.approval.approverRoles) } else { @('Approver', 'Admin') }
            decision      = $null
            decidedBy     = $null
            decidedAt     = $null
            comment       = $null
        }
        # Snapshot of the execution contract at submission time (item file may change later).
        execution   = [ordered]@{
            handler         = $exec.handler
            requiresVCenter = if ($exec.Contains('requiresVCenter')) { [bool]$exec.requiresVCenter } else { $true }
            cloud           = if ($exec.Contains('cloud')) { [string]$exec.cloud } else { $null }
            vmNotes         = @(@($Item.inputs) | Where-Object { $_.Contains('isNote') -and $_.isNote } | ForEach-Object { [ordered]@{ input = $_.name; key = $_.noteKey; label = $_.label } })
            siteInput       = $siteInput
            timeoutMinutes  = if ($exec.Contains('timeoutMinutes')) { [int]$exec.timeoutMinutes } else { [int]$cfg.jobs.defaultTimeoutMinutes }
            fixedParameters = if ($exec.Contains('fixedParameters')) { $exec.fixedParameters } else { @{} }
            credentials     = if ($exec.Contains('credentials')) { $exec.credentials } else { @{} }
            requireReauth   = (Test-PortalItemRequiresReauth -Item $Item)
            credentialInputs = @(@($Item.inputs) | Where-Object { $_.type -eq 'credential' } | ForEach-Object { $_.name })
        }
        job         = [ordered]@{ pid = $null; host = $null; dispatchedAt = $null; startedAt = $null; finishedAt = $null }
        result      = $null
        error       = $null
        history     = @([ordered]@{ ts = $now; status = $status; actor = $User.username; note = 'Request submitted' })
    }
    if ($status -eq 'Queued') { $req.job['queuedAt'] = $now }
    if ($Authorization) { $req['authorization'] = $Authorization }

    Write-PortalJson -Path (Get-RequestPath -Id $req.id) -Value $req
    Write-PortalAudit -Actor $User.username -Action 'request.create' -Target $req.id -Details @{ item = $Item.id; version = $Item.version; status = $status }
    return $req
}

#endregion

#region Workflow actions ------------------------------------------------------------------------------------

function Test-PortalCanApprove {
    param([Parameter(Mandatory)] $Request, [Parameter(Mandatory)] $User)
    if ($Request.status -ne 'PendingApproval') { return $false }
    if (-not (Test-PortalRole -User $User -Role @($Request.approval.approverRoles))) { return $false }
    # Approvers only decide on requests of their own team(s).
    if (-not (Test-PortalTeamAccess -User $User -Teams @(if ($Request.Contains('teams')) { $Request.teams } else { @() }))) { return $false }
    $auth = (Get-PortalConfig).auth
    $selfOk = $auth.Contains('allowSelfApproval') -and [bool]$auth.allowSelfApproval
    if (-not $selfOk -and $Request.requester.username -eq $User.username) { return $false }
    # Separation of duties: the custodian of the vault does not approve jobs that use vault credentials.
    $usesVault = [bool](($Request.execution.Contains('credentials') -and @($Request.execution.credentials.Keys).Count) -or
                        ($Request.execution.Contains('credentialInputs') -and @($Request.execution.credentialInputs).Count))
    if ($usesVault -and @($User.roles) -contains 'VaultAdmin' -and
        -not (Get-PortalSecurityPolicy).separationOfDuties.vaultAdminCanApprove) { return $false }
    return $true
}

function Approve-PortalRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Id, [Parameter(Mandatory)] $User, [string] $Comment)
    $req = Get-PortalRequest -Id $Id
    if (-not $req) { throw "Request $Id not found." }
    if (-not (Test-PortalCanApprove -Request $req -User $User)) { throw 'You are not allowed to approve this request.' }
    $out = Update-PortalRequest -Id $Id -Status 'Queued' -Actor $User.username -Note $Comment -Mutate {
        param($r)
        $r.approval.decision = 'Approved'; $r.approval.decidedBy = $User.username
        $r.approval.decidedAt = Get-PortalTimestamp; $r.approval.comment = $Comment
        $r.job['queuedAt'] = Get-PortalTimestamp
    }
    Write-PortalAudit -Actor $User.username -Action 'request.approve' -Target $Id -Details @{ comment = $Comment }
    return $out
}

function Deny-PortalRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Id, [Parameter(Mandatory)] $User, [Parameter(Mandatory)] [string] $Comment)
    $req = Get-PortalRequest -Id $Id
    if (-not $req) { throw "Request $Id not found." }
    if (-not (Test-PortalCanApprove -Request $req -User $User)) { throw 'You are not allowed to reject this request.' }
    $out = Update-PortalRequest -Id $Id -Status 'Rejected' -Actor $User.username -Note $Comment -Mutate {
        param($r)
        $r.approval.decision = 'Rejected'; $r.approval.decidedBy = $User.username
        $r.approval.decidedAt = Get-PortalTimestamp; $r.approval.comment = $Comment
    }
    Write-PortalAudit -Actor $User.username -Action 'request.reject' -Target $Id -Details @{ comment = $Comment }
    return $out
}

function Stop-PortalRequest {
    <# Cancels a request that has not started yet (requester or Admin). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Id, [Parameter(Mandatory)] $User)
    $req = Get-PortalRequest -Id $Id
    if (-not $req) { throw "Request $Id not found." }
    $isOwner = $req.requester.username -eq $User.username
    if (-not ($isOwner -or (Test-PortalRole -User $User -Role 'Admin'))) { throw 'You are not allowed to cancel this request.' }
    $out = Update-PortalRequest -Id $Id -Status 'Cancelled' -Actor $User.username -Note 'Cancelled by user'
    Write-PortalAudit -Actor $User.username -Action 'request.cancel' -Target $Id
    return $out
}

function Get-PortalReportDir {
    <# data/reports/<REQ-ID> (validated id). #>
    [CmdletBinding()] param([Parameter(Mandatory)] [string] $Id)
    $null = Get-RequestPath -Id $Id
    return (Join-Path (Get-PortalPath -Name Reports) $Id)
}

function Get-PortalRequestReport {
    <# Reports produced by a request: name, type (html/csv/pdf/zip/json), size. With -Name returns the validated file path or $null. #>
    [CmdletBinding()] param([Parameter(Mandatory)] [string] $Id, [string] $Name)
    $dir = Get-PortalReportDir -Id $Id
    if ($Name) {
        if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,150}\.(html|csv|pdf|zip|json)$') { return $null }
        $p = Join-Path $dir $Name
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p } else { return $null }
    }
    if (-not (Test-Path -LiteralPath $dir)) { return }
    foreach ($f in Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Extension -in '.html', '.csv', '.pdf', '.zip', '.json' } | Sort-Object { $_.Extension -ne '.html' }, Name) {
        [ordered]@{ name = $f.Name; type = $f.Extension.TrimStart('.'); sizeKB = [math]::Ceiling($f.Length / 1KB) }
    }
}

function Get-PortalRequestLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Id, [int] $Tail = 2000)
    $null = Get-RequestPath -Id $Id   # validates id
    $path = Join-Path (Get-PortalPath -Name JobLogs) "$Id.log"
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    return ((Get-Content -LiteralPath $path -Tail $Tail) -join "`n")
}

#endregion

#region Out-of-process execution ----------------------------------------------------------------------------

function Start-PortalProcess {
    <# Starts a detached pwsh process running a portal automation script. Returns the Process. #>
    param(
        [Parameter(Mandatory)] [string] $Script,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [string] $LogBase
    )
    $cfg  = Get-PortalConfig
    $pwsh = if ($cfg.jobs.pwshPath) { $cfg.jobs.pwshPath } else { 'pwsh' }
    $env:SSP_PORTAL_ROOT = Get-PortalRoot
    $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$Script`"") + $Arguments
    $sp = @{
        FilePath               = $pwsh
        ArgumentList           = $argList
        PassThru               = $true
        RedirectStandardOutput = "$LogBase.stdout.log"
        RedirectStandardError  = "$LogBase.stderr.log"
    }
    if ($IsWindows) { $sp['WindowStyle'] = 'Hidden' }
    return (Start-Process @sp)
}

function Test-PortalProcessAlive {
    param($ProcessId)
    if (-not $ProcessId) { return $false }
    $p = Get-Process -Id ([int]$ProcessId) -ErrorAction SilentlyContinue
    return ($null -ne $p -and $p.ProcessName -match 'pwsh|powershell')
}

function Invoke-PortalJobDispatcher {
    <#
    .SYNOPSIS Called by a Pode timer. Reconciles running jobs (crash/timeout) and starts queued jobs up to maxConcurrent.
    #>
    [CmdletBinding()] param()

    Invoke-PortalLock -Name 'dispatcher' -TimeoutSeconds 5 -ScriptBlock {
        $cfg    = Get-PortalConfig
        $runner = Join-Path (Get-PortalPath -Name Automation) 'Invoke-CatalogJob.ps1'
        $active = @(Get-PortalRequestList -Status 'Dispatched', 'Running')
        $now    = (Get-Date).ToUniversalTime()

        # 1. Reconcile active jobs.
        $stillActive = 0
        foreach ($r in $active) {
            $alive = Test-PortalProcessAlive -ProcessId $r.job.pid
            $start = if ($r.job.startedAt) { [datetime]$r.job.startedAt } else { [datetime]$r.job.dispatchedAt }
            $timeout = [int]$r.execution.timeoutMinutes

            if (-not $alive) {
                # Give the runner a grace period to write its final state.
                Start-Sleep -Milliseconds 500
                $fresh = Get-PortalRequest -Id $r.id
                if ($script:FinalStates -contains $fresh.status) { continue }
                Update-PortalRequest -Id $r.id -Status 'Failed' -Note 'Runner process exited unexpectedly' -Mutate {
                    param($x) $x.error = 'Runner process exited unexpectedly. See job log and stderr log.'; $x.job.finishedAt = Get-PortalTimestamp
                } | Out-Null
                Write-PortalLog -Level WARN -Message "Request $($r.id) marked Failed: runner not alive."
                continue
            }
            if ($timeout -gt 0 -and $start.ToUniversalTime().AddMinutes($timeout) -lt $now) {
                Stop-Process -Id ([int]$r.job.pid) -Force -ErrorAction SilentlyContinue
                $target = if ($r.status -eq 'Dispatched') { 'Failed' } else { 'Failed' }
                Update-PortalRequest -Id $r.id -Status $target -Note "Timed out after $timeout min" -Mutate {
                    param($x) $x.error = "Job exceeded its timeout of $timeout minutes and was terminated."; $x.job.finishedAt = Get-PortalTimestamp
                } | Out-Null
                Write-PortalAudit -Actor 'system' -Action 'job.timeout' -Target $r.id
                continue
            }
            $stillActive++
        }

        # 2. Start queued jobs (FIFO).
        $slots = [int]$cfg.jobs.maxConcurrent - $stillActive
        if ($slots -le 0) { return }
        $queued = @(Get-PortalRequestList -Status 'Queued' | Sort-Object { $_.job.queuedAt } | Select-Object -First $slots)
        foreach ($r in $queued) {
            try {
                $logBase = Join-Path (Get-PortalPath -Name JobLogs) $r.id
                $proc = Start-PortalProcess -Script $runner -Arguments @('-RequestId', $r.id) -LogBase $logBase
                Update-PortalRequest -Id $r.id -Status 'Dispatched' -Note "Runner PID $($proc.Id)" -Mutate {
                    param($x) $x.job.pid = $proc.Id; $x.job.host = [Environment]::MachineName; $x.job.dispatchedAt = Get-PortalTimestamp
                } | Out-Null
                Write-PortalAudit -Actor 'system' -Action 'job.dispatch' -Target $r.id -Details @{ pid = $proc.Id }
            }
            catch {
                Write-PortalLog -Level ERROR -Message "Dispatch of $($r.id) failed: $($_.Exception.Message)"
            }
        }
    } | Out-Null
}

#endregion

#region Inventory refresh -----------------------------------------------------------------------------------

function Get-Val {
    param($Table, [string] $Key)
    if ($Table -is [System.Collections.IDictionary] -and $Table.Contains($Key)) { return $Table[$Key] }
    return $null
}

function Get-PortalInventoryStatus {
    [CmdletBinding()] param()
    $cfg = Get-PortalConfig
    $folder = Get-PortalPath -Name Inventory
    foreach ($s in Get-PortalSite) {
        $inv    = Read-PortalJson -Path (Join-Path $folder "$($s.code).json")
        $status = Read-PortalJson -Path (Join-Path $folder "$($s.code).status.json")
        $collected = Get-Val $inv 'collectedAt'
        $age = if ($collected) { [math]::Round(((Get-Date).ToUniversalTime() - ([datetime]$collected).ToUniversalTime()).TotalMinutes) } else { $null }
        [ordered]@{
            site        = $s.code
            vcenter     = $s.vcenter
            enabled     = [bool]$s.enabled
            collectedAt = $collected
            ageMinutes  = $age
            stale       = ($null -eq $age -or $age -gt [int]$cfg.inventory.staleAfterMinutes)
            running     = [bool]((Get-Val $status 'state') -eq 'Running' -and (Test-PortalProcessAlive -ProcessId (Get-Val $status 'pid')))
            lastState   = Get-Val $status 'state'
            lastError   = Get-Val $status 'error'
            counts      = if ($inv) { [ordered]@{
                clusters = @(Get-Val $inv 'clusters').Count; datastores = @(Get-Val $inv 'datastores').Count; portgroups = @(Get-Val $inv 'portgroups').Count
                templates = @(Get-Val $inv 'templates').Count; folders = @(Get-Val $inv 'folders').Count; vms = @(Get-Val $inv 'vms').Count } } else { $null }
        }
    }
}

function Start-PortalInventoryRefresh {
    <# Starts an inventory collection process per enabled site (skips sites already refreshing). #>
    [CmdletBinding()]
    param([string] $Site, [string] $Actor = 'system')
    $script = Join-Path (Get-PortalPath -Name Automation) 'Update-VsphereInventory.ps1'
    $folder = Get-PortalPath -Name Inventory
    $started = @()
    foreach ($s in Get-PortalSite -EnabledOnly) {
        if ($Site -and $s.code -ne $Site) { continue }
        $statusPath = Join-Path $folder "$($s.code).status.json"
        $st = Read-PortalJson -Path $statusPath
        if ((Get-Val $st 'state') -eq 'Running' -and (Test-PortalProcessAlive -ProcessId (Get-Val $st 'pid'))) { continue }
        $proc = Start-PortalProcess -Script $script -Arguments @('-Site', $s.code) -LogBase (Join-Path (Get-PortalPath -Name JobLogs) "inventory-$($s.code)")
        Write-PortalJson -Path $statusPath -Value ([ordered]@{ state = 'Running'; pid = $proc.Id; startedAt = (Get-PortalTimestamp); error = $null })
        $started += $s.code
    }
    if ($started) { Write-PortalAudit -Actor $Actor -Action 'inventory.refresh' -Target ($started -join ',') }
    return $started
}

#endregion

Export-ModuleMember -Function Get-PortalReportDir, Get-PortalRequestReport, New-PortalRequest, Get-PortalRequest, Get-PortalRequestList, ConvertTo-PortalRequestSummary,
    Update-PortalRequest, Test-PortalCanApprove, Approve-PortalRequest, Deny-PortalRequest, Stop-PortalRequest,
    Get-PortalRequestLog, Invoke-PortalJobDispatcher, Get-PortalInventoryStatus, Start-PortalInventoryRefresh, Test-PortalProcessAlive, Start-PortalProcess
