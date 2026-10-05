<#
.SYNOPSIS
    Self-Service Portal - web server (Pode).
.DESCRIPTION
    Single portal with local / Active Directory / OpenLDAP sign-in (MFA, lockout, idle timeout) and a JSON-driven marketplace. Every catalog item
    (catalog/items/*.json) is rendered as a service card and a request form; submitted requests go
    through optional approval and are executed out-of-process by automation/Invoke-CatalogJob.ps1.

    Adding a service = drop a JSON item + its handler script. No restart and no web changes required.
.PARAMETER ShowErrors
    Troubleshooting: writes Pode errors (with stack trace) to the console instead of logs/.
    Do not leave enabled in production.
.PARAMETER Http
    Lab only: listen on plain HTTP (ignores protocol/certificate from the configuration).
.NOTES
    Requires PowerShell 7.2+. If launched from Windows PowerShell 5.1 the script relaunches itself in
    pwsh.exe automatically (this file is kept 5.1-parseable for that reason; the modules are PS7-only).
.EXAMPLE
    pwsh -File .\Start-Portal.ps1
#>
[CmdletBinding()]
param([switch] $Http, [switch] $ShowErrors)

$ErrorActionPreference = 'Stop'

# --- PowerShell 7 guard: relaunch in pwsh when started from Windows PowerShell 5.1 ---------------------
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if (-not $pwsh) {
        $candidate = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
        if (Test-Path $candidate) { $pwsh = Get-Item $candidate }
    }
    if (-not $pwsh) {
        throw ('PowerShell 7.2+ is required (current: {0}). Install it with: winget install --id Microsoft.PowerShell -e  ' +
               '(or the MSI from https://aka.ms/powershell-release?tag=stable), then run: pwsh -File "{1}"') -f $PSVersionTable.PSVersion, $PSCommandPath
    }
    $exe = if ($pwsh.Source) { $pwsh.Source } else { $pwsh.FullName }
    Write-Host "Windows PowerShell $($PSVersionTable.PSVersion) detected - relaunching in $exe" -ForegroundColor Yellow
    $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($Http) { $relaunch += '-Http' }
    if ($ShowErrors) { $relaunch += '-ShowErrors' }
    & $exe @relaunch
    exit $LASTEXITCODE
}

$root = $PSScriptRoot
$env:SSP_PORTAL_ROOT = $root

# --- Remove Mark-of-the-Web from the whole portal tree ----------------------------------------------------
# Files extracted from a downloaded zip are "blocked" and PowerShell asks "Run once?" for every script/module.
# Approving this launcher once unblocks everything else, so modules, handlers, runners and tools load silently.
if ($IsWindows) {
    Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1', '.json', '.html', '.js', '.css' } |
        Unblock-File -ErrorAction SilentlyContinue
}

Import-Module Pode -MinimumVersion 2.10.0 -ErrorAction Stop
$portalModules = 'Portal.Core', 'Portal.Security', 'Portal.Vault', 'Portal.Identity', 'Portal.Auth', 'Portal.Data', 'Portal.Catalog', 'Portal.Jobs',
                 'Portal.Storage', 'Portal.Sites', 'Portal.Cloud', 'Portal.Settings', 'Portal.Web' |
    ForEach-Object { Join-Path $root "modules/$_.psm1" }
$portalModules | ForEach-Object { Import-Module $_ -Force }

Initialize-PortalConfiguration          # first run: create config from defaults; upgrades: add new settings
Initialize-PortalTeamScopes             # upgrades: scope existing catalog items / local users to teams (once)
Import-PortalLegacySecrets              # upgrades: DPAPI CliXml credentials -> portal vault (Windows)
$null = Get-PortalVaultStatus            # creates / validates the vault master key before serving requests
$config = Get-PortalConfig
if (-not $IsWindows -and @(Get-PortalIdentityProvider -EnabledOnly).Count) {
    $libOk = @('libldap-2.5.so.0', 'libldap.so.2' | Where-Object { [System.Runtime.InteropServices.NativeLibrary]::TryLoad($_, [ref][IntPtr]::Zero) })
    if (-not ($libOk -contains 'libldap-2.5.so.0')) {
        Write-Warning ('LDAP sign-in needs the OpenLDAP client library as libldap-2.5.so.0 (.NET 8). ' +
                       'Install openldap / libldap and, on OpenLDAP 2.6 systems, run packaging/linux/install.sh (creates the compatibility link).')
    }
}
foreach ($d in 'Requests', 'Inventory', 'JobLogs') {
    $p = Get-PortalPath -Name $d
    if (-not (Test-Path $p)) { $null = New-Item -ItemType Directory -Path $p -Force }
}

Start-PodeServer -Threads 8 -RootPath $root {

    #region Endpoint & logging --------------------------------------------------------------------------
    $cfg = Get-PortalConfig
    if ($Http -or $cfg.portal.protocol -ne 'Https') {
        Add-PodeEndpoint -Address $cfg.portal.address -Port $cfg.portal.port -Protocol Http
    }
    else {
        $thumb = ([string]$cfg.portal.certificateThumbprint) -replace '[^0-9A-Fa-f]', ''
        $certFile = if ($cfg.portal.Contains('certificateFile')) { [string]$cfg.portal.certificateFile } else { '' }
        $ep = @{ Address = $cfg.portal.address; Port = $cfg.portal.port; Protocol = 'Https' }
        if ($certFile) {
            # PEM (certificate + certificateKeyFile) or PFX (+ password from an environment variable). Linux / appliance default.
            if (-not (Test-Path -LiteralPath $certFile)) { throw "portal.certificateFile '$certFile' not found." }
            $ep['Certificate'] = $certFile
            $keyFile = if ($cfg.portal.Contains('certificateKeyFile')) { [string]$cfg.portal.certificateKeyFile } else { '' }
            if ($keyFile) { $ep['CertificateKey'] = $keyFile }
            $pwVar = if ($cfg.portal.Contains('certificatePasswordEnvVar')) { [string]$cfg.portal.certificatePasswordEnvVar } else { '' }
            if ($pwVar -and [Environment]::GetEnvironmentVariable($pwVar)) { $ep['CertificatePassword'] = [Environment]::GetEnvironmentVariable($pwVar) }
        }
        elseif ($thumb.Length -eq 40) {
            # Server certificates normally live in Cert:\LocalMachine\My (Pode defaults to CurrentUser).
            $storeLocation = if ($cfg.portal.Contains('certificateStoreLocation')) { $cfg.portal.certificateStoreLocation } else { 'LocalMachine' }
            if (-not (Test-Path "Cert:\$storeLocation\My\$thumb")) {
                throw "Certificate $thumb not found in Cert:\$storeLocation\My. Import the portal certificate or fix portal.certificateThumbprint."
            }
            $ep['CertificateThumbprint']    = $thumb
            $ep['CertificateStoreName']     = 'My'
            $ep['CertificateStoreLocation'] = $storeLocation
        }
        else {
            # No real certificate configured yet: lab mode with a Pode self-signed certificate.
            Write-Warning 'No certificate configured (portal.certificateFile / certificateThumbprint) - using a SELF-SIGNED certificate (lab only).'
            $ep['SelfSigned'] = $true
        }
        Add-PodeEndpoint @ep
    }
    if ($ShowErrors) {
        # Pode 2.14+ uses New-PodeLogTerminalMethod; older 2.x uses New-PodeLoggingMethod -Terminal.
        $terminal = if (Get-Command New-PodeLogTerminalMethod -ErrorAction SilentlyContinue) { New-PodeLogTerminalMethod } else { New-PodeLoggingMethod -Terminal }
        $terminal | Enable-PodeErrorLogging -Levels Error, Warning, Informational, Verbose
    }
    else {
        New-PodeLoggingMethod -File -Name 'pode-errors' -Path (Join-Path $root 'logs') | Enable-PodeErrorLogging
    }
    New-PodeLoggingMethod -File -Name 'pode-requests' -Path (Join-Path $root 'logs') | Enable-PodeRequestLogging

    foreach ($m in $portalModules) { Import-PodeModule -Path $m }
    #endregion

    #region Security: sessions, sign-in, CSRF guard ---------------------------------------------------------
    # Pode session = signed cookie with an absolute lifetime. Idle timeout, revocation, forced password change,
    # MFA enrolment and re-authentication are enforced per request by Portal.Auth (Test-PortalSessionGate).
    $pol = Get-PortalSecurityPolicy
    $sessionArgs = @{ Duration = [int]$pol.session.absoluteTimeoutMinutes * 60; Extend = $false; HttpOnly = $true }
    if (-not $Http -and $cfg.portal.protocol -eq 'Https') { $sessionArgs['Secure'] = $true }
    $secret = [Environment]::GetEnvironmentVariable($cfg.portal.sessionSecretEnvVar)
    if ($secret) { $sessionArgs['Secret'] = $secret }
    else { Write-Warning "$($cfg.portal.sessionSecretEnvVar) is not set: session cookies are signed with a random secret generated at every start." }
    # Note: Pode keeps sessions in memory - users sign in again after a portal restart (by design for this release).
    Enable-PodeSessionMiddleware @sessionArgs

    # Sign-in is a two-step exchange:
    #   1. POST /api/auth/login (JSON) runs every check (lockout, local / AD / OpenLDAP, roles, MFA) and returns a
    #      single-use ticket valid for 60 seconds, bound to the client IP;
    #   2. the login page posts the ticket to /login, where this form scheme redeems it and Pode issues the session.
    New-PodeAuthScheme -Form | Add-PodeAuth -Name 'Portal' -FailureUrl '/login?error=1' -SuccessUrl '/' -ScriptBlock {
        param($username, $password)
        $meta = Get-PortalRequestMeta -WebEvent $WebEvent
        $user = Use-PortalLoginTicket -Ticket $password -Ip $meta.ip
        if ($user) { return @{ User = $user } }
        return @{ Message = 'Sign-in expired, please try again.' }
    }
    $authName = 'Portal'
    if ($cfg.auth.Contains('localUsers') -and $cfg.auth.localUsers.enabled) {
        Write-Warning 'Local portal accounts are ENABLED. Disable them in Admin > Identity once directory groups are in place (break-glass accounts keep working).'
    }

    # State-changing API calls must carry X-Portal-Request: 1 (not settable cross-site without CORS).
    Add-PodeMiddleware -Name 'PortalCsrfGuard' -Route '/api/*' -ScriptBlock {
        if ($WebEvent.Method -ne 'get' -and (Get-PodeHeader -Name 'X-Portal-Request') -ne '1') {
            Write-PodeJsonResponse -StatusCode 403 -Value @{ error = 'Missing anti-forgery header.' }
            return $false
        }
        Set-PodeHeader -Name 'Cache-Control' -Value 'no-store'
        return $true
    }
    if (Get-Command Set-PodeSecurity -ErrorAction SilentlyContinue) { Set-PodeSecurity -Type Simple }
    #endregion

    #region Pages -----------------------------------------------------------------------------------------
    Add-PodeStaticRoute -Path '/assets' -Source (Join-Path $root 'web/assets')

    # Public branding (login page needs it before authentication).
    Add-PodeRoute -Method Get -Path '/api/branding' -ScriptBlock {
        try { Write-PodeJsonResponse -Value (Get-PortalBranding) -Depth 5 }
        catch { Write-PodeJsonResponse -StatusCode 500 -Value @{ error = 'Branding unavailable.' } }
    }
    Add-PodeRoute -Method Get -Path '/brand/logo' -ScriptBlock {
        $logo = Get-PortalLogoPath
        if (-not $logo) { Set-PodeResponseStatus -Code 404; return }
        Set-PodeHeader -Name 'Cache-Control' -Value 'public, max-age=86400'
        Write-PodeFileResponse -Path $logo
    }

    Add-PodeRoute -Method Get -Path '/login' -Authentication $authName -Login -ScriptBlock {
        Write-PodeFileResponse -Path (Join-Path (Get-PodeServerPath) 'web/login.html')
    }
    Add-PodeRoute -Method Post -Path '/login'  -Authentication $authName -Login
    Add-PodeRoute -Method Post -Path '/logout' -Authentication $authName -Logout

    # Step 1 of sign-in (public). Body: { username, password, otp? } -> { ok, ticket } | { ok:false, next:'mfa'?, message }
    Add-PodeRoute -Method Post -Path '/api/auth/login' -ScriptBlock {
        $body = ConvertTo-PortalHashtable $WebEvent.Data
        if (-not $body) { $body = @{} }
        try {
            $meta = Get-PortalRequestMeta -WebEvent $WebEvent
            $res = Invoke-PortalLogin -Username ([string]$body['username']) -Password ([string]$body['password']) -Otp ([string]$body['otp']) -Ip $meta.ip -UserAgent $meta.userAgent
            Write-PodeJsonResponse -Value $res -StatusCode $(if ($res.ok -or $res.Contains('next')) { 200 } else { 401 })
        }
        catch {
            Write-PortalLog -Level ERROR -Message "Login error: $($_.Exception.Message)"
            Write-PodeJsonResponse -StatusCode 500 -Value @{ ok = $false; message = 'Sign-in is temporarily unavailable. Contact your administrator.' }
        }
    }

    # Session timers for the idle warning (background polls do not extend the session).
    Add-PodeRoute -Method Get -Path '/api/session' -Authentication $authName -ScriptBlock {
        $r = Invoke-PortalApi -WebEvent $WebEvent -AllowRestricted -Action { param($u) Get-PortalSessionInfo -Sid $u.sid }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 5
    }
    Add-PodeRoute -Method Post -Path '/api/session/keepalive' -Authentication $authName -ScriptBlock {
        $r = Invoke-PortalApi -WebEvent $WebEvent -AllowRestricted -Action { param($u) Get-PortalSessionInfo -Sid $u.sid }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 5
    }
    Add-PodeRoute -Method Post -Path '/api/session/logout' -Authentication $authName -ScriptBlock {
        try { $u = Get-PortalUserContext -AuthUser $WebEvent.Auth.User; if ($u.sid) { Stop-PortalSession -Sid $u.sid -Reason 'logout' -Actor $u.username } } catch { }
        Write-PodeJsonResponse -Value @{ ok = $true }
    }
    # Re-authentication for sensitive actions. Body: { password, otp? }
    Add-PodeRoute -Method Post -Path '/api/session/reauth' -Authentication $authName -ScriptBlock {
        $body = ConvertTo-PortalHashtable $WebEvent.Data
        $r = Invoke-PortalApi -WebEvent $WebEvent -AllowRestricted -Action {
            param($u)
            try { Confirm-PortalReauthentication -User $u -Password ([string]$body['password']) -Otp ([string]$body['otp']) -Ip $u.meta.ip }
            catch { New-PortalApiError -Status 422 -Message $_.Exception.Message }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 5
    }

    Add-PodeRoute -Method Get -Path '/' -Authentication $authName -ScriptBlock {
        Write-PodeFileResponse -Path (Join-Path (Get-PodeServerPath) 'web/index.html')
    }
    #endregion

    #region API: identity & catalog ---------------------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/api/me' -Authentication $authName -ScriptBlock {
        $r = Invoke-PortalApi -WebEvent $WebEvent -AllowRestricted -Action {
            param($u)
            $c = Get-PortalConfig
            $sid = $u.sid
            $u.Remove('meta'); $u.Remove('sid')
            [ordered]@{
                user        = $u
                permissions = @(Get-PortalPermissionSet -User $u)
                mfa         = Get-PortalMfaStatus -Username $u.username
                session     = Get-PortalSessionInfo -Sid $sid
                portal = [ordered]@{ name = $c.portal.name; organization = $c.portal.organization }
                sites  = @(Get-PortalSite -EnabledOnly | ForEach-Object { [ordered]@{ code = $_.code; name = $_.name } })
                teams  = @(Get-PortalTeamList | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name } })
            }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 20
    }

    # Self-service password change (local accounts). Body: { currentPassword, newPassword }
    Add-PodeRoute -Method Post -Path '/api/me/password' -Authentication $authName -ScriptBlock {
        $body = ConvertTo-PortalHashtable $WebEvent.Data
        $r = Invoke-PortalApi -WebEvent $WebEvent -AllowRestricted -Action {
            param($u)
            if (-not $u.local) { New-PortalApiError -Status 409 -Message 'Directory passwords are changed in your directory (AD / LDAP), not in the portal.' }
            try { Set-PortalOwnPassword -Username $u.username -CurrentPassword ([string]$body['currentPassword']) -NewPassword ([string]$body['newPassword']) }
            catch { New-PortalApiError -Status 422 -Message $_.Exception.Message }
            Clear-PortalSessionFlag -Sid $u.sid -Flag mustChangePassword
            [ordered]@{ changed = $true }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 5
    }
    # MFA enrolment: begin -> { secret, uri } ; confirm { code } -> { recoveryCodes[] }
    Add-PodeRoute -Method Post -Path '/api/me/mfa/begin' -Authentication $authName -ScriptBlock {
        $r = Invoke-PortalApi -WebEvent $WebEvent -AllowRestricted -Action {
            param($u)
            # Replacing an existing authenticator needs a fresh password confirmation.
            if ((Get-PortalMfaStatus -Username $u.username).enrolled) { $null = Test-PortalSessionGate -Sid $u.sid -AllowRestricted -RequireReauth }
            Start-PortalMfaEnrollment -Username $u.username -DisplayName $u.name
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 5
    }
    Add-PodeRoute -Method Post -Path '/api/me/mfa/confirm' -Authentication $authName -ScriptBlock {
        $body = ConvertTo-PortalHashtable $WebEvent.Data
        $r = Invoke-PortalApi -WebEvent $WebEvent -AllowRestricted -Action {
            param($u)
            try { $codes = Complete-PortalMfaEnrollment -Username $u.username -Code ([string]$body['code']) }
            catch { New-PortalApiError -Status 422 -Message $_.Exception.Message }
            Clear-PortalSessionFlag -Sid $u.sid -Flag mfaEnrollRequired
            [ordered]@{ enrolled = $true; recoveryCodes = @($codes) }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 5
    }

    Add-PodeRoute -Method Get -Path '/api/catalog' -Authentication $authName -ScriptBlock {
        $r = Invoke-PortalApi -WebEvent $WebEvent -Action {
            param($u) [ordered]@{ items = @(Get-PortalCatalogForUser -User $u) }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 20
    }

    Add-PodeRoute -Method Get -Path '/api/catalog/:id' -Authentication $authName -ScriptBlock {
        $id = $WebEvent.Parameters['id']
        $r = Invoke-PortalApi -WebEvent $WebEvent -Action {
            param($u)
            $item = Get-PortalCatalogItem -Id $id
            if (-not $item -or -not (Test-PortalItemAccess -Item $item -User $u)) { New-PortalApiError -Status 404 -Message 'Catalog item not found.' }
            ConvertTo-PortalPublicItem -Item $item
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 20
    }

    # Dynamic options for a select input. Body: { "values": { "Site": "DC1", "Workload": "App" } }
    Add-PodeRoute -Method Post -Path '/api/catalog/:id/options/:input' -Authentication $authName -ScriptBlock {
        $id = $WebEvent.Parameters['id']; $inputName = $WebEvent.Parameters['input']
        $body = ConvertTo-PortalHashtable $WebEvent.Data
        $values = if ($body -and $body['values']) { $body['values'] } else { @{} }
        $r = Invoke-PortalApi -WebEvent $WebEvent -Action {
            param($u)
            $item = Get-PortalCatalogItem -Id $id
            if (-not $item -or -not (Test-PortalItemAccess -Item $item -User $u)) { New-PortalApiError -Status 404 -Message 'Catalog item not found.' }
            $def = @($item.inputs) | Where-Object { $_.name -eq $inputName } | Select-Object -First 1
            if ($def -and $def.Contains('requireReauth') -and $def.requireReauth) { $null = Test-PortalSessionGate -Sid $u.sid -RequireReauth }
            try { $opts = @(Get-PortalLookupOptions -Item $item -InputName $inputName -Values $values) }
            catch { New-PortalApiError -Status 409 -Message $_.Exception.Message }
            [ordered]@{ options = $opts }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 20
    }
    #endregion

    #region API: requests ---------------------------------------------------------------------------------
    Add-PodeRoute -Method Post -Path '/api/requests' -Authentication $authName -ScriptBlock {
        $data = ConvertTo-PortalHashtable $WebEvent.Data
        if (-not $data) { $data = @{} }
        $r = Invoke-PortalApi -WebEvent $WebEvent -Action {
            param($u)
            $item = Get-PortalCatalogItem -Id ([string]$data['itemId'])
            if (-not $item -or -not (Test-PortalItemAccess -Item $item -User $u)) { New-PortalApiError -Status 404 -Message 'Catalog item not found.' }
            $authz = $null
            if (Test-PortalItemRequiresReauth -Item $item) {
                $null = Test-PortalSessionGate -Sid $u.sid -RequireReauth
                $authz = [ordered]@{ by = $u.username; at = (Get-PortalTimestamp); ip = [string]$u.meta.ip; reauthenticated = $true }
            }
            $check = Test-PortalRequestInput -Item $item -Submitted $(if ($data['inputs']) { $data['inputs'] } else { @{} })
            if (-not $check.valid) { New-PortalApiError -Status 422 -Message 'Please correct the highlighted fields.' -Fields $check.errors }
            $req = New-PortalRequest -Item $item -Values $check.values -User $u -Authorization $authz
            [ordered]@{ id = $req.id; status = $req.status }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 20
    }

    # scope = mine (default) | all (Approver/Admin) | approvals (pending items the user can approve)
    Add-PodeRoute -Method Get -Path '/api/requests' -Authentication $authName -ScriptBlock {
        $scope = if ($WebEvent.Query['scope']) { $WebEvent.Query['scope'] } else { 'mine' }
        $r = Invoke-PortalApi -WebEvent $WebEvent -Action {
            param($u)
            $list = switch ($scope) {
                'all' {
                    if (-not (Test-PortalRole -User $u -Role 'Approver', 'Admin')) { New-PortalApiError -Status 403 -Message 'Insufficient permissions.' }
                    Get-PortalRequestList | Where-Object { Test-PortalTeamAccess -User $u -Teams @(if ($_.Contains('teams')) { $_.teams } else { @() }) }
                }
                'approvals' { Get-PortalRequestList -Status 'PendingApproval' | Where-Object { Test-PortalCanApprove -Request $_ -User $u } }
                default     { Get-PortalRequestList -Requester $u.username }
            }
            [ordered]@{ requests = @($list | ForEach-Object { ConvertTo-PortalRequestSummary -Request $_ }) }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 20
    }

    Add-PodeRoute -Method Get -Path '/api/requests/:id' -Authentication $authName -ScriptBlock {
        $id = $WebEvent.Parameters['id']
        $r = Invoke-PortalApi -WebEvent $WebEvent -Action {
            param($u)
            $req = try { Get-PortalRequest -Id $id } catch { $null }
            if (-not $req) { New-PortalApiError -Status 404 -Message 'Request not found.' }
            Assert-PortalRequestVisible -Request $req -User $u
            Get-PortalRequestView -Request $req -User $u
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 20
    }

    Add-PodeRoute -Method Get -Path '/api/requests/:id/log' -Authentication $authName -ScriptBlock {
        $id = $WebEvent.Parameters['id']
        $r = Invoke-PortalApi -WebEvent $WebEvent -Action {
            param($u)
            $req = try { Get-PortalRequest -Id $id } catch { $null }
            if (-not $req) { New-PortalApiError -Status 404 -Message 'Request not found.' }
            Assert-PortalRequestVisible -Request $req -User $u
            [ordered]@{ status = $req.status; log = (Get-PortalRequestLog -Id $id) }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 5
    }

    # Reports produced by a job (HTML / CSV). Served with a CSP that forbids scripts.
    Add-PodeRoute -Method Get -Path '/api/requests/:id/reports/:file' -Authentication $authName -ScriptBlock {
        $id = $WebEvent.Parameters['id']; $file = $WebEvent.Parameters['file']
        $r = Invoke-PortalApi -WebEvent $WebEvent -Action {
            param($u)
            $req = try { Get-PortalRequest -Id $id } catch { $null }
            if (-not $req) { New-PortalApiError -Status 404 -Message 'Request not found.' }
            Assert-PortalRequestVisible -Request $req -User $u
            $p = Get-PortalRequestReport -Id $id -Name $file
            if (-not $p) { New-PortalApiError -Status 404 -Message 'Report not found.' }
            $p
        }
        if ($r.Status -ne 200) { Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status; return }
        Set-PodeHeader -Name 'Content-Security-Policy' -Value "default-src 'none'; style-src 'unsafe-inline'; img-src data:"
        Set-PodeHeader -Name 'X-Content-Type-Options' -Value 'nosniff'
        if ($file -like '*.csv') { Set-PodeHeader -Name 'Content-Disposition' -Value ('attachment; filename=' + $file) }
        Write-PodeFileResponse -Path $r.Body
    }

    #region API: storage scan / rescan (New datastore) ---------------------------------------------------
    # Every rescan needs a recent re-authentication; one per cluster at a time, cooldown between rescans; who / when / IP audited.
    Add-PodeRoute -Method Get -Path '/api/storage/scan' -Authentication $authName -ScriptBlock {
        $q = $WebEvent.Query
        $r = Invoke-PortalApi -WebEvent $WebEvent -Action {
            param($u)
            $item = Get-PortalCatalogItem -Id ([string]$q['itemId'])
            if (-not $item -or -not (Test-PortalItemAccess -Item $item -User $u)) { New-PortalApiError -Status 404 -Message 'Catalog item not found.' }
            if (-not (@($item.inputs) | Where-Object { $_.Contains('source') -and $_.source.type -eq 'storageDevices' })) { New-PortalApiError -Status 400 -Message 'This item does not use storage devices.' }
            if (-not (Get-PortalSite -Code ([string]$q['site']))) { New-PortalApiError -Status 404 -Message 'Site not found.' }
            Get-PortalStorageView -Site ([string]$q['site']) -Cluster ([string]$q['cluster'])
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 10
    }

    # Body: { itemId, site, cluster }
    Add-PodeRoute -Method Post -Path '/api/storage/rescan' -Authentication $authName -ScriptBlock {
        $body = ConvertTo-PortalHashtable $WebEvent.Data
        if (-not $body) { $body = @{} }
        $r = Invoke-PortalApi -WebEvent $WebEvent -RequireReauth -Action {
            param($u)
            $item = Get-PortalCatalogItem -Id ([string]$body['itemId'])
            if (-not $item -or -not (Test-PortalItemAccess -Item $item -User $u)) { New-PortalApiError -Status 404 -Message 'Catalog item not found.' }
            if (-not (@($item.inputs) | Where-Object { $_.Contains('source') -and $_.source.type -eq 'storageDevices' })) { New-PortalApiError -Status 400 -Message 'This item does not use storage devices.' }
            $site = [string]$body['site']; $cluster = [string]$body['cluster']
            if (-not $site -or -not $cluster) { New-PortalApiError -Status 400 -Message 'Select the site and the cluster first.' }
            if (-not (Get-PortalSite -Code $site)) { New-PortalApiError -Status 404 -Message 'Site not found.' }
            Start-PortalStorageRescan -Site $site -Cluster $cluster -User $u -Ip ([string]$u.meta.ip) -Rescan -ItemId $item.id
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 10
    }
    #endregion

    #region API: admin data files (software repository, baselines, backup policies) ----------------------
    Add-PodeRoute -Method Get -Path '/api/admin/datafiles' -Authentication $authName -ScriptBlock {
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'catalog.manage' -Action {
            param($u) [ordered]@{ files = @(Get-PortalDataFileList) }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 30
    }

    # Body: { json: "<file content>", validateOnly?: bool }
    Add-PodeRoute -Method Post -Path '/api/admin/datafiles/:name' -Authentication $authName -ScriptBlock {
        $name = $WebEvent.Parameters['name']
        $body = ConvertTo-PortalHashtable $WebEvent.Data
        if (-not $body) { $body = @{} }
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'catalog.manage' -Action {
            param($u)
            if (@(Get-PortalDataFileList | ForEach-Object { $_.name }) -notcontains $name) { New-PortalApiError -Status 404 -Message 'Unknown data file.' }
            $json = [string]$body['json']
            if ($body['validateOnly']) {
                $content = try { $json | ConvertFrom-Json -AsHashtable -Depth 30 } catch { New-PortalApiError -Status 422 -Message "Invalid JSON: $($_.Exception.Message)" }
                $errs = @(Test-PortalDataFile -Name $name -Content $content)
                return [ordered]@{ valid = (-not $errs.Count); errors = [string[]]$errs }
            }
            $null = Test-PortalSessionGate -Sid $u.sid -RequireReauth
            try { Set-PortalDataFile -Name $name -Json $json -Actor $u.username }
            catch {
                $errs = @(if ($_.Exception.Data.Contains('errors')) { $_.Exception.Data['errors'] } else { $_.Exception.Message })
                New-PortalApiError -Status 422 -Message 'The file is not valid.' -Fields @{ errors = [string[]]$errs }
            }
            [ordered]@{ saved = $true; file = $name }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 10
    }
    #endregion

    foreach ($action in 'approve', 'reject', 'cancel') {
        Add-PodeRoute -Method Post -Path "/api/requests/:id/$action" -Authentication $authName -ArgumentList $action -ScriptBlock {
            param($action)
            $id = $WebEvent.Parameters['id']
            $body = ConvertTo-PortalHashtable $WebEvent.Data
            $comment = if ($body) { [string]$body['comment'] } else { '' }
            $r = Invoke-PortalApi -WebEvent $WebEvent -Action {
                param($u)
                try {
                    if ($action -eq 'approve') {
                        $pending = Get-PortalRequest -Id $id
                        if ($pending -and $pending.execution.Contains('requireReauth') -and $pending.execution.requireReauth) { $null = Test-PortalSessionGate -Sid $u.sid -RequireReauth }
                    }
                    $req = switch ($action) {
                        'approve' { Approve-PortalRequest -Id $id -User $u -Comment $comment }
                        'reject'  {
                            if ([string]::IsNullOrWhiteSpace($comment)) { New-PortalApiError -Status 422 -Message 'A comment is required to reject a request.' }
                            Deny-PortalRequest -Id $id -User $u -Comment $comment
                        }
                        'cancel'  { Stop-PortalRequest -Id $id -User $u }
                    }
                }
                catch {
                    if ($_.Exception.Data.Contains('status')) { throw }
                    New-PortalApiError -Status 409 -Message $_.Exception.Message
                }
                [ordered]@{ id = $req.id; status = $req.status }
            }
            Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 10
        }
    }
    #endregion

    #region API: administration ----------------------------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/api/admin/catalog' -Authentication $authName -ScriptBlock {
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'catalog.manage' -Action {
            param($u)
            $cat = Get-PortalCatalog
            [ordered]@{
                items  = @($cat.items | ForEach-Object {
                    [ordered]@{ id = $_.id; name = $_.name; version = $_.version; category = $_.category
                                enabled = $(if ($_.Contains('enabled')) { [bool]$_['enabled'] } else { $true }); file = $_._file; updated = $_._updated
                                handler = $_.execution.handler; approval = [bool]($_['approval'] -and $_.approval.required)
                                roles = @(if ($_['access']) { $_.access.roles } else { 'Requester', 'Approver', 'Admin' }) } })
                errors = @($cat.errors)
            }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 20
    }

    Add-PodeRoute -Method Get -Path '/api/admin/inventory' -Authentication $authName -ScriptBlock {
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'connections.manage' -Action {
            param($u) [ordered]@{ sites = @(Get-PortalInventoryStatus) }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 20
    }

    Add-PodeRoute -Method Post -Path '/api/admin/inventory/refresh' -Authentication $authName -ScriptBlock {
        $body = ConvertTo-PortalHashtable $WebEvent.Data
        $site = if ($body) { [string]$body['site'] } else { '' }
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'connections.manage' -Action {
            param($u) [ordered]@{ started = @(Start-PortalInventoryRefresh -Site $site -Actor $u.username) }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 10
    }

    Add-PodeRoute -Method Get -Path '/api/admin/audit' -Authentication $authName -ScriptBlock {
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'audit.read' -Action {
            param($u)
            $path = Get-PortalPath -Name Audit
            $lines = if (Test-Path $path) { Get-Content -LiteralPath $path -Tail 200 } else { @() }
            [ordered]@{ entries = @($lines | ForEach-Object { $_ | ConvertFrom-Json } | Sort-Object ts -Descending) }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 10
    }
    #endregion

    #region API: administration - vCenter connections ------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/api/admin/sites' -Authentication $authName -ScriptBlock {
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'connections.manage' -Action { param($u) [ordered]@{ sites = @(Get-PortalSiteView) } }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 20
    }

    # Body: { code?, new?, name, vcenter, enabled, invalidCertificateAction, workloadClusters:{App,DB}, vmFolder, dnsDomain, dnsServers[], username?, password? }
    Add-PodeRoute -Method Post -Path '/api/admin/sites' -Authentication $authName -ScriptBlock {
        $body = ConvertTo-PortalHashtable $WebEvent.Data
        if (-not $body) { $body = @{} }
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'connections.manage' -Action {
            param($u)
            if ($body['password']) { $null = Test-PortalSessionGate -Sid $u.sid -RequireReauth }
            try {
                Set-PortalSiteSettings -Code ([string]$body['code']) -Settings $body -New:([bool]$body['new']) -Actor $u.username
                if ($body['username'] -and $body['password']) {
                    Set-PortalSiteCredential -Code ([string]$body['code']) -Username ([string]$body['username']) -Password ([string]$body['password']) -Actor $u.username
                }
            }
            catch { New-PortalApiError -Status 422 -Message $_.Exception.Message }
            [ordered]@{ saved = $true; sites = @(Get-PortalSiteView) }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 20
    }

    Add-PodeRoute -Method Post -Path '/api/admin/sites/:code/test' -Authentication $authName -ScriptBlock {
        $code = $WebEvent.Parameters['code']
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'connections.manage' -Action {
            param($u)
            try { $res = Test-PortalSiteConnection -Code $code -Actor $u.username } catch { New-PortalApiError -Status 422 -Message $_.Exception.Message }
            if ($res.ok) { $null = Start-PortalInventoryRefresh -Site $code -Actor $u.username }   # warm the drop-downs
            $res
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 20
    }
    #endregion

    #region API: administration - cloud connections (AWS VPC / Azure VNet) ------------------------------------
    Add-PodeRoute -Method Get -Path '/api/admin/clouds' -Authentication $authName -ScriptBlock {
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'connections.manage' -Action { param($u) [ordered]@{ clouds = @(Get-PortalCloudView) } }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 20
    }

    # Body: { provider: "aws"|"azure", settings: {...}, secret?: "..." }
    Add-PodeRoute -Method Post -Path '/api/admin/clouds' -Authentication $authName -ScriptBlock {
        $body = ConvertTo-PortalHashtable $WebEvent.Data
        if (-not $body) { $body = @{} }
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'connections.manage' -Action {
            param($u)
            $settings = if ($body['settings'] -is [System.Collections.IDictionary]) { $body['settings'] } else { @{} }
            if ($body['secret']) { $null = Test-PortalSessionGate -Sid $u.sid -RequireReauth }
            try { Set-PortalCloudSettings -Provider ([string]$body['provider']) -Settings $settings -Secret ([string]$body['secret']) -Actor $u.username }
            catch { New-PortalApiError -Status 422 -Message $_.Exception.Message }
            [ordered]@{ saved = $true; clouds = @(Get-PortalCloudView) }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 20
    }

    Add-PodeRoute -Method Post -Path '/api/admin/clouds/:provider/test' -Authentication $authName -ScriptBlock {
        $provider = $WebEvent.Parameters['provider']
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'connections.manage' -Action {
            param($u)
            try { Test-PortalCloudConnection -Provider $provider -Actor $u.username } catch { New-PortalApiError -Status 422 -Message $_.Exception.Message }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 20
    }
    #endregion

    #region API: administration - customization (branding, teams, role mapping, VM notes, policies) ---------
    Add-PodeRoute -Method Get -Path '/api/admin/settings' -Authentication $authName -ScriptBlock {
        $r = Invoke-PortalApi -WebEvent $WebEvent -Action {
            param($u)
            if (-not ((Test-PortalPermission -User $u -Permission 'catalog.manage') -or (Test-PortalPermission -User $u -Permission 'security.manage'))) {
                New-PortalApiError -Status 403 -Message 'Insufficient permissions.'
            }
            Get-PortalSettingsView
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 20
    }
    Add-PodeRoute -Method Post -Path '/api/admin/settings' -Authentication $authName -ScriptBlock {
        $body = ConvertTo-PortalHashtable $WebEvent.Data
        if (-not $body) { $body = @{} }
        $r = Invoke-PortalApi -WebEvent $WebEvent -Action {
            param($u)
            foreach ($k in @($body.Keys)) {
                $need = if ($k -in 'roleMapping', 'policies') { 'security.manage' } else { 'catalog.manage' }
                if (-not (Test-PortalPermission -User $u -Permission $need)) { New-PortalApiError -Status 403 -Message "Insufficient permissions for '$k'." }
            }
            if ($body.Contains('roleMapping') -or $body.Contains('policies')) { $null = Test-PortalSessionGate -Sid $u.sid -RequireReauth }
            try { Set-PortalSettings -Settings $body -Actor $u.username } catch { New-PortalApiError -Status 422 -Message $_.Exception.Message }
            Get-PortalSettingsView
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 20
    }
    # Body: { dataUrl: "data:image/png;base64,..." }  (empty = remove logo)
    Add-PodeRoute -Method Post -Path '/api/admin/settings/logo' -Authentication $authName -ScriptBlock {
        $body = ConvertTo-PortalHashtable $WebEvent.Data
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'catalog.manage' -Action {
            param($u)
            try { Set-PortalBrandLogo -DataUrl ([string]$body['dataUrl']) -Actor $u.username } catch { New-PortalApiError -Status 422 -Message $_.Exception.Message }
            Get-PortalBranding
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 5
    }
    #endregion

    #region API: administration - local users ---------------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/api/admin/users' -Authentication $authName -ScriptBlock {
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'security.manage' -Action {
            param($u)
            $list = @(Get-PortalLocalUserList | ForEach-Object { $_['mfaEnrolled'] = (Get-PortalMfaStatus -Username "LOCAL\$($_.username)").enrolled; $_ })
            [ordered]@{ users = $list; me = $u.username; roles = @(Get-PortalRoleList) }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 10
    }

    # Body: { username, displayName, email, roles[], enabled, password?, new? }
    Add-PodeRoute -Method Post -Path '/api/admin/users' -Authentication $authName -ScriptBlock {
        $body = ConvertTo-PortalHashtable $WebEvent.Data
        if (-not $body) { $body = @{} }
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'security.manage' -RequireReauth -Action {
            param($u)
            $splat = @{ Username = [string]$body['username']; Actor = $u.username; New = [bool]$body['new'] }
            if ($body.Contains('mustChangePassword')) { $splat['MustChangePassword'] = [bool]$body['mustChangePassword'] }
            if ($body.Contains('breakGlass'))         { $splat['BreakGlass'] = [bool]$body['breakGlass'] }
            if ($body.Contains('displayName')) { $splat['DisplayName'] = [string]$body['displayName'] }
            if ($body.Contains('email'))       { $splat['Email'] = [string]$body['email'] }
            if ($body['roles'])                { $splat['Roles'] = [string[]]@($body['roles']) }
            if ($body.Contains('teams'))       { $splat['Teams'] = [string[]]@($body['teams'] | Where-Object { $_ }) }
            if ($body.Contains('enabled'))     { $splat['Enabled'] = [bool]$body['enabled'] }
            if ($body['password'])             { $splat['Password'] = [string]$body['password'] }
            try { Set-PortalLocalUserEntry @splat } catch { New-PortalApiError -Status 422 -Message $_.Exception.Message }
            $target = "LOCAL\$($splat.Username)"
            if ($target -ine $u.username -and -not $splat.New -and (($splat.ContainsKey('Enabled') -and -not $splat.Enabled) -or $splat.ContainsKey('Roles') -or $splat.ContainsKey('Password'))) {
                Revoke-PortalSession -Username $target -Actor $u.username
            }
            [ordered]@{ saved = $true; users = @(Get-PortalLocalUserList) }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 10
    }

    Add-PodeRoute -Method Delete -Path '/api/admin/users/:username' -Authentication $authName -ScriptBlock {
        $name = $WebEvent.Parameters['username']
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'security.manage' -Action {
            param($u)
            $null = Test-PortalSessionGate -Sid $u.sid -RequireReauth
            try { Remove-PortalLocalUserEntry -Username $name -Actor $u.username } catch { New-PortalApiError -Status 422 -Message $_.Exception.Message }
            Revoke-PortalSession -Username "LOCAL\$name" -Actor $u.username
            [ordered]@{ deleted = $name; users = @(Get-PortalLocalUserList) }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 10
    }
    #endregion

    #region API: administration - identity providers (AD / OpenLDAP) --------------------------------------------
    Add-PodeRoute -Method Get -Path '/api/admin/identity' -Authentication $authName -ScriptBlock {
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'security.manage' -Action {
            param($u)
            $auth = (Get-PortalConfig).auth
            [ordered]@{
                providers         = @(if ($auth.Contains('providers')) { $auth.providers } else { @() })
                defaultProvider   = if ($auth.Contains('defaultProvider')) { $auth.defaultProvider } else { '' }
                localUsersEnabled = [bool]($auth.Contains('localUsers') -and $auth.localUsers.enabled)
                bindCredentials   = @(Get-PortalVaultEntry | Where-Object { $_.scope.system } | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name; username = $_.username } })
                platform          = $(if ($IsWindows) { 'windows' } else { 'linux' })
            }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 20
    }
    # Body: { provider: {...}, mode: "create" | "update" }
    Add-PodeRoute -Method Post -Path '/api/admin/identity' -Authentication $authName -ScriptBlock {
        $body = ConvertTo-PortalHashtable $WebEvent.Data
        if (-not $body) { $body = @{} }
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'security.manage' -RequireReauth -Action {
            param($u)
            if ($body['provider'] -isnot [System.Collections.IDictionary]) { New-PortalApiError -Status 422 -Message 'Missing provider definition.' }
            try { Set-PortalIdentityProvider -Provider $body['provider'] -New:([string]$body['mode'] -eq 'create') -Actor $u.username }
            catch { New-PortalApiError -Status 422 -Message $_.Exception.Message }
            [ordered]@{ saved = $true }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 10
    }
    Add-PodeRoute -Method Delete -Path '/api/admin/identity/:id' -Authentication $authName -ScriptBlock {
        $id = $WebEvent.Parameters['id']
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'security.manage' -RequireReauth -Action {
            param($u) Remove-PortalIdentityProvider -Id $id -Actor $u.username; [ordered]@{ deleted = $id }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 5
    }
    # Body: { lookupUser? }
    Add-PodeRoute -Method Post -Path '/api/admin/identity/:id/test' -Authentication $authName -ScriptBlock {
        $id = $WebEvent.Parameters['id']; $body = ConvertTo-PortalHashtable $WebEvent.Data
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'security.manage' -Action {
            param($u)
            try { Test-PortalIdentityProvider -Id $id -LookupUser ([string]$body['lookupUser']) } catch { New-PortalApiError -Status 422 -Message $_.Exception.Message }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 10
    }
    # Sign-in simulation (no session is created): which roles / teams would this account get? Body: { username, password }
    Add-PodeRoute -Method Post -Path '/api/admin/identity/simulate' -Authentication $authName -ScriptBlock {
        $body = ConvertTo-PortalHashtable $WebEvent.Data
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'security.manage' -Action {
            param($u)
            $target = Resolve-PortalLoginTarget -Username ([string]$body['username'])
            if (-not $target) { New-PortalApiError -Status 422 -Message 'No identity provider handles this domain.' }
            $res = if ($target.kind -eq 'local') {
                $lu = Test-PortalLocalCredential -Username $target.login -Password ([string]$body['password'])
                if ($lu) { [ordered]@{ ok = $true; user = $lu } } else { [ordered]@{ ok = $false; message = 'Invalid username or password.' } }
            } else { Invoke-PortalLdapAuthentication -Provider $target.provider -Login $target.login -Password ([string]$body['password']) }
            Write-PortalAudit -Actor $u.username -Action 'identity.simulate' -Target ([string]$body['username']) -Details @{ ok = [bool]$res.ok }
            if (-not $res.ok) { return [ordered]@{ ok = $false; provider = $(if ($target.provider) { $target.provider.id } else { 'local' }); message = $res.message } }
            $ctx = Get-PortalUserContext -AuthUser $res.user
            [ordered]@{ ok = $true; provider = $(if ($target.provider) { $target.provider.id } else { 'local' }); username = $ctx.username
                        groups = @($res.user.Groups); roles = $ctx.roles; teams = $ctx.teams; mfaRequired = (Test-PortalMfaRequired -User $ctx) }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 10
    }
    # Body: { defaultProvider?, localUsersEnabled? }
    Add-PodeRoute -Method Post -Path '/api/admin/identity/options' -Authentication $authName -ScriptBlock {
        $body = ConvertTo-PortalHashtable $WebEvent.Data
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'security.manage' -RequireReauth -Action {
            param($u)
            Update-PortalConfig -Mutate {
                param($cfg)
                if ($body.Contains('defaultProvider')) { $cfg.auth['defaultProvider'] = [string]$body['defaultProvider'] }
                if ($body.Contains('localUsersEnabled')) {
                    if (-not $cfg.auth.Contains('localUsers')) { $cfg.auth['localUsers'] = [ordered]@{ file = 'config/local-users.json' } }
                    $cfg.auth.localUsers['enabled'] = [bool]$body['localUsersEnabled']
                }
            }
            Write-PortalAudit -Actor $u.username -Action 'identity.options' -Details $body
            [ordered]@{ saved = $true }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 5
    }
    #endregion

    #region API: administration - security (policy, sessions, lockouts, MFA reset) --------------------------------
    Add-PodeRoute -Method Get -Path '/api/admin/security' -Authentication $authName -ScriptBlock {
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'security.manage' -Action {
            param($u)
            $audit = Get-PortalPath -Name Audit
            $bg = @(if (Test-Path $audit) { @(Get-Content -LiteralPath $audit -Tail 2000 | Where-Object { $_ -match '"auth\.breakglass"' } | Select-Object -Last 5 | ForEach-Object { $_ | ConvertFrom-Json }) })
            [ordered]@{
                policy     = Get-PortalSecurityPolicy
                roles      = @(Get-PortalRoleList)
                sessions   = @(Get-PortalSessionList)
                lockouts   = @(Get-PortalLockoutList)
                breakGlass = $bg
                clientIp   = $u.meta.ip
                vault      = Get-PortalVaultKeyInfo
            }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 10
    }
    Add-PodeRoute -Method Post -Path '/api/admin/security/policy' -Authentication $authName -ScriptBlock {
        $body = ConvertTo-PortalHashtable $WebEvent.Data
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'security.manage' -RequireReauth -Action {
            param($u)
            try { Set-PortalSecurityPolicy -Policy $body -Actor $u.username -ActorIp $u.meta.ip } catch { New-PortalApiError -Status 422 -Message $_.Exception.Message }
            [ordered]@{ saved = $true; policy = Get-PortalSecurityPolicy }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 10
    }
    # Body: { id? (short session id), username? }
    Add-PodeRoute -Method Post -Path '/api/admin/security/sessions/revoke' -Authentication $authName -ScriptBlock {
        $body = ConvertTo-PortalHashtable $WebEvent.Data
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'security.manage' -Action {
            param($u)
            if (-not $body['id'] -and -not $body['username']) { New-PortalApiError -Status 422 -Message 'Session id or username required.' }
            Revoke-PortalSession -ShortId ([string]$body['id']) -Username ([string]$body['username']) -Actor $u.username
            [ordered]@{ sessions = @(Get-PortalSessionList) }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 10
    }
    Add-PodeRoute -Method Post -Path '/api/admin/security/lockouts/clear' -Authentication $authName -ScriptBlock {
        $body = ConvertTo-PortalHashtable $WebEvent.Data
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'security.manage' -Action {
            param($u)
            if (-not $body -or -not $body['key']) { New-PortalApiError -Status 422 -Message 'Lockout key required.' }
            Clear-PortalLockout -Key ([string]$body['key']) -Actor $u.username; [ordered]@{ lockouts = @(Get-PortalLockoutList) }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 10
    }
    # Body: { username }  (DOMAIN\user or LOCAL\user)
    Add-PodeRoute -Method Post -Path '/api/admin/security/mfa/reset' -Authentication $authName -ScriptBlock {
        $body = ConvertTo-PortalHashtable $WebEvent.Data
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'security.manage' -RequireReauth -Action {
            param($u)
            $name = [string]$body['username']
            if (-not $name) { New-PortalApiError -Status 422 -Message 'Username required.' }
            Reset-PortalMfa -Username $name -Actor $u.username
            Revoke-PortalSession -Username $name -Actor $u.username
            [ordered]@{ reset = $name }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 5
    }
    #endregion

    #region API: administration - credential vault ----------------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/api/admin/vault' -Authentication $authName -ScriptBlock {
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'vault.manage' -Action {
            param($u)
            [ordered]@{
                status  = Get-PortalVaultStatus
                entries = @(Get-PortalVaultEntry | ForEach-Object { $_['usedBy'] = @(Get-PortalVaultReference -Id $_.id); $_ })
                teams   = @(Get-PortalTeamList | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name } })
                items   = @((Get-PortalCatalog).items | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name } })
            }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 10
    }
    # Body: { mode: create|update, id, name, type, description, username, target, secret?, passphrase?, fields{}, scope{system,teams[],items[]}, tags[], expiresAt }
    Add-PodeRoute -Method Post -Path '/api/admin/vault' -Authentication $authName -ScriptBlock {
        $body = ConvertTo-PortalHashtable $WebEvent.Data
        if (-not $body) { $body = @{} }
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'vault.manage' -RequireReauth -Action {
            param($u)
            $splat = @{ Id = [string]$body['id']; Actor = $u.username; New = ([string]$body['mode'] -eq 'create') }
            foreach ($k in 'name', 'type', 'description', 'username', 'target', 'expiresAt') { if ($body.Contains($k)) { $splat[(Get-Culture).TextInfo.ToTitleCase($k) -replace 'Expiresat', 'ExpiresAt'] = [string]$body[$k] } }
            if ($body['secret'])                              { $splat['Secret'] = [string]$body['secret'] }
            if ($body.Contains('passphrase') -and $body['secret']) { $splat['Passphrase'] = [string]$body['passphrase'] }
            if ($body['fields'] -is [System.Collections.IDictionary]) { $splat['Fields'] = $body['fields'] }
            if ($body['scope'] -is [System.Collections.IDictionary])  { $splat['Scope'] = $body['scope'] }
            if ($body.Contains('tags'))                       { $splat['Tags'] = [string[]]@($body['tags'] | Where-Object { $_ }) }
            try { Set-PortalVaultEntry @splat } catch { New-PortalApiError -Status 422 -Message $_.Exception.Message }
            Get-PortalVaultEntry -Id $splat.Id
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 10
    }
    Add-PodeRoute -Method Delete -Path '/api/admin/vault/:id' -Authentication $authName -ScriptBlock {
        $id = $WebEvent.Parameters['id']
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'vault.manage' -RequireReauth -Action {
            param($u)
            try { Remove-PortalVaultEntry -Id $id -Actor $u.username } catch { New-PortalApiError -Status 422 -Message $_.Exception.Message }
            [ordered]@{ deleted = $id }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 5
    }
    #endregion

    #region API: administration - catalog editor ------------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/api/admin/catalog/:id' -Authentication $authName -ScriptBlock {
        $id = $WebEvent.Parameters['id']
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'catalog.manage' -Action {
            param($u)
            $f = try { Get-PortalCatalogItemFile -Id $id } catch { $null }
            if (-not $f) { New-PortalApiError -Status 404 -Message 'Catalog item not found.' }
            [ordered]@{ item = $f.item; file = (Split-Path -Leaf $f.file) }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 30
    }

    # Body: { item: {...}, mode: "create" | "update" | "validate" }
    Add-PodeRoute -Method Post -Path '/api/admin/catalog' -Authentication $authName -ScriptBlock {
        $body = ConvertTo-PortalHashtable $WebEvent.Data
        if (-not $body) { $body = @{} }
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'catalog.manage' -Action {
            param($u)
            $item = $body['item']
            if ($item -isnot [System.Collections.IDictionary]) { New-PortalApiError -Status 422 -Message 'Missing item definition.' }
            $mode = [string]$body['mode']
            $res = Save-PortalCatalogItem -Item $item -Actor $u.username -New:($mode -eq 'create') -ValidateOnly:($mode -eq 'validate')
            if ($res.errors.Count) { New-PortalApiError -Status 422 -Message 'The catalog item is not valid.' -Fields @{ errors = @($res.errors) } }
            $res
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 20
    }

    Add-PodeRoute -Method Delete -Path '/api/admin/catalog/:id' -Authentication $authName -ScriptBlock {
        $id = $WebEvent.Parameters['id']
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'catalog.manage' -Action {
            param($u)
            try { Remove-PortalCatalogItem -Id $id -Actor $u.username } catch { New-PortalApiError -Status 422 -Message $_.Exception.Message }
            [ordered]@{ deleted = $id }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 5
    }

    Add-PodeRoute -Method Get -Path '/api/admin/handlers' -Authentication $authName -ScriptBlock {
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'catalog.manage' -Action {
            param($u) [ordered]@{ handlers = @(Get-PortalHandlerList); roots = @(Get-PortalHandlerRoot) }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 10
    }

    # Body: { handler } -> parameters declared by the script (used to pre-build inputs)
    Add-PodeRoute -Method Post -Path '/api/admin/handlers/inspect' -Authentication $authName -ScriptBlock {
        $body = ConvertTo-PortalHashtable $WebEvent.Data
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'catalog.manage' -Action {
            param($u)
            try {
                $path = Resolve-PortalHandlerPath -Handler ([string]$body['handler']) -MustExist
                [ordered]@{ path = $path; parameters = @(Get-PortalHandlerInfo -Path $path) }
            }
            catch { New-PortalApiError -Status 422 -Message $_.Exception.Message }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 10
    }

    # Body: { handler, parameters[], requiresVCenter } -> creates a skeleton script
    Add-PodeRoute -Method Post -Path '/api/admin/handlers/stub' -Authentication $authName -ScriptBlock {
        $body = ConvertTo-PortalHashtable $WebEvent.Data
        $r = Invoke-PortalApi -WebEvent $WebEvent -Permission 'catalog.manage' -Action {
            param($u)
            try {
                $path = New-PortalHandlerStub -Handler ([string]$body['handler']) -Parameters ([string[]]@($body['parameters'])) `
                                              -RequiresVCenter ([bool]$body['requiresVCenter']) -Actor $u.username
                [ordered]@{ created = $path }
            }
            catch { New-PortalApiError -Status 422 -Message $_.Exception.Message }
        }
        Write-PodeJsonResponse -Value $r.Body -StatusCode $r.Status -Depth 5
    }
    #endregion

    #region Background timers -----------------------------------------------------------------------------
    Add-PodeTimer -Name 'JobDispatcher' -Interval ([int]$cfg.jobs.dispatcherIntervalSeconds) -ScriptBlock {
        try { Invoke-PortalJobDispatcher } catch { Write-PortalLog -Level ERROR -Message "Dispatcher: $($_.Exception.Message)" }
    }
    Add-PodeTimer -Name 'InventoryRefresh' -Interval ([int]$cfg.inventory.refreshIntervalMinutes * 60) -ScriptBlock {
        try { $null = Start-PortalInventoryRefresh } catch { Write-PortalLog -Level ERROR -Message "Inventory timer: $($_.Exception.Message)" }
    }
    Add-PodeTimer -Name 'InventoryWarmup' -Interval 20 -Limit 1 -ScriptBlock {
        try { $null = Start-PortalInventoryRefresh } catch { Write-PortalLog -Level ERROR -Message "Inventory warm-up: $($_.Exception.Message)" }
    }
    #endregion

    Write-PortalLog -Message "Portal started on port $($cfg.portal.port) (catalog: $(@((Get-PortalCatalog).items).Count) items)."
}
