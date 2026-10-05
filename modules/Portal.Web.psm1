#Requires -Version 7.2
<#
.SYNOPSIS
    Portal.Web - framework-agnostic API helpers used by the Pode routes in Start-Portal.ps1.
.DESCRIPTION
    Routes stay thin: they call Invoke-PortalApi with the authenticated user and an action scriptblock,
    then write the returned Status/Body with Write-PodeJsonResponse. Keeping Pode out of this module
    makes the API logic testable without a running web server (see tests/).
#>

Set-StrictMode -Version Latest

function New-PortalApiError {
    <# Throws an exception carrying an HTTP status code (and optional field errors). #>
    param(
        [Parameter(Mandatory)] [int] $Status,
        [Parameter(Mandatory)] [string] $Message,
        $Fields
    )
    $ex = [System.InvalidOperationException]::new($Message)
    $ex.Data['status'] = $Status
    if ($Fields) { $ex.Data['fields'] = $Fields }
    throw $ex
}

function Invoke-PortalApi {
    <#
    .SYNOPSIS Runs an API action with session checks, authorization and uniform error handling.
    .PARAMETER WebEvent        Pode $WebEvent (auth user, client IP, headers). Tests may pass -AuthUser instead.
    .PARAMETER Roles           Any of these roles is required (default: any portal role).
    .PARAMETER Permission      Named permission (catalog.manage, security.manage, vault.manage, connections.manage, audit.read).
    .PARAMETER AllowRestricted Usable while a password change / MFA enrolment is pending (account self-service).
    .PARAMETER RequireReauth   Sensitive action: password re-entered within the re-authentication window.
    .PARAMETER Action          { param($User) ... return body }   ($User.meta = client ip / user agent)
    .OUTPUTS   @{ Status = int; Body = object }
    #>
    [CmdletBinding()]
    param(
        $WebEvent,
        $AuthUser,
        [string[]] $Roles,
        [string] $Permission,
        [switch] $AllowRestricted,
        [switch] $RequireReauth,
        [switch] $SkipSessionGate,
        [Parameter(Mandatory)] [scriptblock] $Action
    )
    try {
        $meta = if ($WebEvent) { Get-PortalRequestMeta -WebEvent $WebEvent } else { [ordered]@{ ip = ''; background = $false; userAgent = '' } }
        if (-not $AuthUser -and $WebEvent) { try { $AuthUser = $WebEvent.Auth.User } catch { } }
        if (-not $AuthUser) { New-PortalApiError -Status 401 -Message 'Not signed in.' -Fields @{ code = 'SESSION_EXPIRED' } }
        $user = Get-PortalUserContext -AuthUser $AuthUser -ClientIp $meta.ip
        if ($WebEvent -and -not $SkipSessionGate) {
            $null = Test-PortalSessionGate -Sid $user.sid -Background:$meta.background -AllowRestricted:$AllowRestricted -RequireReauth:$RequireReauth
        }
        if (-not $user.roles) { New-PortalApiError -Status 403 -Message 'Your account is not mapped to any portal role.' }
        if ($Roles -and -not (Test-PortalRole -User $user -Role $Roles)) { New-PortalApiError -Status 403 -Message 'Insufficient permissions.' }
        if ($Permission -and -not (Test-PortalPermission -User $user -Permission $Permission)) {
            $why = if ($user.networkRestricted) { ' Administrative roles are only available from the management network.' } else { '' }
            New-PortalApiError -Status 403 -Message "Insufficient permissions.$why"
        }
        $user['meta'] = $meta
        $body = & $Action $user
        return @{ Status = 200; Body = $body }
    }
    catch {
        $ex = $_.Exception
        while ($ex.InnerException -and -not $ex.Data.Contains('status')) { $ex = $ex.InnerException }
        if ($ex.Data.Contains('status')) {
            $b = [ordered]@{ error = $ex.Message }
            if ($ex.Data.Contains('fields')) { $b['fields'] = $ex.Data['fields'] }
            return @{ Status = [int]$ex.Data['status']; Body = $b }
        }
        $ref = [guid]::NewGuid().ToString('N').Substring(0, 8)
        try { Write-PortalLog -Level ERROR -Message "API error [$ref]: $($_.Exception.Message) $($_.ScriptStackTrace)" } catch { }
        return @{ Status = 500; Body = [ordered]@{ error = "Unexpected server error (ref $ref)." } }
    }
}

function Assert-PortalRequestVisible {
    <# Requesters see their own requests; Approvers/Admins see all. #>
    param([Parameter(Mandatory)] $Request, [Parameter(Mandatory)] $User)
    if ($Request.requester.username -eq $User.username) { return }
    if ((Test-PortalRole -User $User -Role 'Approver', 'Admin') -and
        (Test-PortalTeamAccess -User $User -Teams @(if ($Request.Contains('teams')) { $Request.teams } else { @() }))) { return }
    New-PortalApiError -Status 404 -Message 'Request not found.'
}

function Get-PortalRequestView {
    <# Request document + UI permission flags for the current user. #>
    param([Parameter(Mandatory)] $Request, [Parameter(Mandatory)] $User)
    $view = [ordered]@{}
    foreach ($k in $Request.Keys) { if ($k -ne 'execution') { $view[$k] = $Request[$k] } }
    $view['execution'] = [ordered]@{ timeoutMinutes = $Request.execution.timeoutMinutes }
    $view['canApprove'] = [bool](Test-PortalCanApprove -Request $Request -User $User)
    $view['reports'] = @(Get-PortalRequestReport -Id $Request.id)
    $view['requiresReauth'] = [bool]($Request.execution.Contains('requireReauth') -and $Request.execution.requireReauth)
    $view['canCancel']  = [bool](@('PendingApproval', 'Queued') -contains $Request.status -and
                                 ($Request.requester.username -eq $User.username -or (Test-PortalRole -User $User -Role 'Admin')))
    return $view
}

Export-ModuleMember -Function New-PortalApiError, Invoke-PortalApi, Assert-PortalRequestVisible, Get-PortalRequestView
