#Requires -Version 7.2
<#
.SYNOPSIS
    Portal.Auth - sign-in orchestration and session security.
.DESCRIPTION
    Sign-in (POST /api/auth/login) -> Invoke-PortalLogin:
        lockout check -> route to local / LDAP provider -> credential check -> role check -> MFA (TOTP or recovery code)
        -> session record -> one-time ticket. The login page then posts the ticket to Pode's form login (/login),
        whose auth script redeems it (Use-PortalLoginTicket); Pode creates the session cookie.
    Every API call -> Test-PortalSessionGate (from Invoke-PortalApi):
        session record exists and is not revoked, idle timeout, absolute timeout, forced password change,
        forced MFA enrolment, recent re-authentication for sensitive actions.
    State (data/security/*.json, cross-process locks): sessions, lockouts, MFA enrolments, login tickets.
#>

Set-StrictMode -Version Latest

$script:Dir = $null
function Get-AuthPath {
    param([string] $Name)
    $dir = Join-Path (Get-PortalRoot) 'data/security'
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    return (Join-Path $dir "$Name.json")
}
function Read-AuthStore { param([string] $Name) $s = Read-PortalJson -Path (Get-AuthPath $Name); if (-not $s) { $s = [ordered]@{} }; return $s }
function Save-AuthStore { param([string] $Name, $Value) Write-PortalJson -Path (Get-AuthPath $Name) -Value $Value }
function Get-AV { param($T, [string] $K, $D = $null) if ($T -is [System.Collections.IDictionary] -and $T.Contains($K) -and $null -ne $T[$K]) { $T[$K] } else { $D } }
function Get-NowUtc { return [datetime]::UtcNow }
function ConvertTo-Utc { param($Value) if (-not $Value) { return $null } return ([datetime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)) }
function New-RandomToken { param([int] $Bytes = 32) $b = [byte[]]::new($Bytes); [System.Security.Cryptography.RandomNumberGenerator]::Fill($b); return ([Convert]::ToBase64String($b) -replace '\+', '-' -replace '/', '_' -replace '=', '') }
function Get-Sha256 { param([string] $Text) return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Text))) }

#region Request metadata -------------------------------------------------------------------------------------

function Get-PortalRequestMeta {
    <#
    .SYNOPSIS Client IP (honours X-Forwarded-For only from security.trustedProxies), background flag and user agent.
    .PARAMETER WebEvent  Pode $WebEvent, or a test double @{ RemoteIp; Headers = @{} }.
    #>
    param($WebEvent)
    $ip = ''; $headers = @{}
    if ($WebEvent) {
        if ($WebEvent -is [System.Collections.IDictionary] -and $WebEvent.Contains('RemoteIp')) {
            $ip = [string]$WebEvent.RemoteIp; $headers = Get-AV $WebEvent 'Headers' @{}
        }
        else {
            try { $ip = [string]$WebEvent.Request.RemoteEndPoint.Address } catch { }
            try { $headers = $WebEvent.Request.Headers } catch { }
        }
    }
    $ip = $ip -replace '^::ffff:', ''
    $h = { param($n) try { [string]$headers[$n] } catch { '' } }
    $xff = & $h 'X-Forwarded-For'
    if ($xff) {
        $proxies = @((Get-PortalSecurityPolicy).trustedProxies)
        if ($proxies -and (Test-PortalIpInCidr -Ip $ip -Cidr $proxies)) { $ip = ($xff -split ',')[0].Trim() }
    }
    return [ordered]@{ ip = $ip; background = ((& $h 'X-Portal-Background') -eq '1'); userAgent = (& $h 'User-Agent') }
}

#endregion

#region Lockout ----------------------------------------------------------------------------------------------

function Get-LockKey { param([string] $Username) return ('u:' + ($Username.Trim().ToLowerInvariant() -replace '^.*\\', '' -replace '@.*$', '')) }

function Get-PortalLockoutState {
    <# Remaining lock time (seconds) for a username or IP; 0 = not locked. #>
    param([string] $Username, [string] $Ip)
    $store = Invoke-PortalLock -Name 'auth-lockout' -ScriptBlock { Read-AuthStore 'lockouts' }
    $now = Get-NowUtc
    $max = 0
    foreach ($k in @($(if ($Username) { Get-LockKey $Username }), $(if ($Ip) { "ip:$Ip" })) | Where-Object { $_ }) {
        $e = Get-AV $store $k
        $until = ConvertTo-Utc (Get-AV $e 'lockedUntil')
        if ($until -and $until -gt $now) { $max = [math]::Max($max, [int]($until - $now).TotalSeconds) }
    }
    return $max
}

function Register-PortalLoginFailure {
    param([string] $Username, [string] $Ip)
    $pol = (Get-PortalSecurityPolicy).lockout
    $locked = $false
    Invoke-PortalLock -Name 'auth-lockout' -ScriptBlock {
        $store = Read-AuthStore 'lockouts'
        $now = Get-NowUtc
        # IPs get a higher threshold (several users behind one NAT / proxy).
        foreach ($pair in @(@((Get-LockKey $Username), $pol.threshold), @("ip:$Ip", ($pol.threshold * 4)))) {
            $k = $pair[0]; if (-not $Ip -and $k -eq 'ip:') { continue }
            $e = Get-AV $store $k ([ordered]@{ failures = @(); lockedUntil = $null })
            $recent = @(@($e.failures) | Where-Object { $_ -and (ConvertTo-Utc $_) -gt $now.AddMinutes(-$pol.windowMinutes) })
            $recent += $now.ToString('o')
            $e.failures = $recent
            if ($recent.Count -ge $pair[1]) {
                $e.lockedUntil = $now.AddMinutes($pol.durationMinutes).ToString('o'); $e.failures = @()
                if ($k -like 'u:*') { $script:JustLocked = $true }
            }
            $store[$k] = $e
        }
        Save-AuthStore 'lockouts' $store
    } | Out-Null
}

function Clear-PortalLoginFailure {
    param([string] $Username)
    Invoke-PortalLock -Name 'auth-lockout' -ScriptBlock {
        $store = Read-AuthStore 'lockouts'
        $k = Get-LockKey $Username
        if ($store.Contains($k)) { $store.Remove($k); Save-AuthStore 'lockouts' $store }
    } | Out-Null
}

function Get-PortalLockoutList {
    [CmdletBinding()] param()
    $store = Invoke-PortalLock -Name 'auth-lockout' -ScriptBlock { Read-AuthStore 'lockouts' }
    $now = Get-NowUtc
    foreach ($k in $store.Keys) {
        $until = ConvertTo-Utc (Get-AV $store[$k] 'lockedUntil')
        if ($until -and $until -gt $now) {
            [ordered]@{ key = $k; kind = $(if ($k -like 'ip:*') { 'ip' } else { 'user' }); name = ($k -replace '^(u|ip):', ''); lockedUntil = $until.ToString('o') }
        }
    }
}

function Clear-PortalLockout {
    [CmdletBinding()] param([Parameter(Mandatory)] [string] $Key, [Parameter(Mandatory)] [string] $Actor)
    Invoke-PortalLock -Name 'auth-lockout' -ScriptBlock {
        $store = Read-AuthStore 'lockouts'
        if ($store.Contains($Key)) { $store.Remove($Key); Save-AuthStore 'lockouts' $store }
    } | Out-Null
    Write-PortalAudit -Actor $Actor -Action 'security.unlock' -Target $Key
}

#endregion

#region TOTP (RFC 6238) ----------------------------------------------------------------------------------------

$script:B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'

function ConvertTo-Base32 {
    param([byte[]] $Bytes)
    $sb = [System.Text.StringBuilder]::new(); $buffer = 0; $bits = 0
    foreach ($b in $Bytes) {
        $buffer = (($buffer -shl 8) -bor [int]$b) -band 0xFFFF; $bits += 8
        while ($bits -ge 5) { [void]$sb.Append($script:B32[($buffer -shr ($bits - 5)) -band 31]); $bits -= 5 }
    }
    if ($bits -gt 0) { [void]$sb.Append($script:B32[($buffer -shl (5 - $bits)) -band 31]) }
    return $sb.ToString()
}

function ConvertFrom-Base32 {
    param([string] $Text)
    $clean = ($Text.ToUpperInvariant() -replace '[^A-Z2-7]', '')
    $out = [System.Collections.Generic.List[byte]]::new(); $buffer = 0; $bits = 0
    foreach ($ch in $clean.ToCharArray()) {
        $buffer = (($buffer -shl 5) -bor $script:B32.IndexOf($ch)) -band 0xFFFF; $bits += 5
        if ($bits -ge 8) { $out.Add([byte](($buffer -shr ($bits - 8)) -band 0xFF)); $bits -= 8 }
    }
    return $out.ToArray()
}

function Get-PortalTotpCode {
    <# 6-digit HMAC-SHA1 code for a 30-second time step. #>
    param([byte[]] $Secret, [long] $Step)
    $msg = [BitConverter]::GetBytes($Step); if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($msg) }
    $hmac = [System.Security.Cryptography.HMACSHA1]::new($Secret)
    try { $h = $hmac.ComputeHash($msg) } finally { $hmac.Dispose() }
    $o = [int]($h[19] -band 0x0F)
    $bin = (([int]$h[$o] -band 0x7F) -shl 24) -bor ([int]$h[$o + 1] -shl 16) -bor ([int]$h[$o + 2] -shl 8) -bor [int]$h[$o + 3]
    return ('{0:D6}' -f ($bin % 1000000))
}

function Get-TotpStep { param([datetime] $At = [datetime]::UtcNow) return [long][math]::Floor(([DateTimeOffset]$At).ToUnixTimeSeconds() / 30) }

function Test-PortalTotp {
    <# Verifies a code within +-1 step; returns the matched step (replay protection) or -1. #>
    param([byte[]] $Secret, [string] $Code, [long] $LastStep = -1)
    $c = ($Code -replace '\s', '')
    if ($c -notmatch '^\d{6}$') { return -1 }
    $now = Get-TotpStep
    foreach ($s in ($now - 1), $now, ($now + 1)) {
        if ($s -le $LastStep) { continue }
        $expected = Get-PortalTotpCode -Secret $Secret -Step $s
        if ([System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals([Text.Encoding]::ASCII.GetBytes($expected), [Text.Encoding]::ASCII.GetBytes($c))) { return $s }
    }
    return -1
}

function Get-MfaKey { param([string] $Username) return $Username.ToLowerInvariant() }

function Get-PortalMfaStatus {
    param([Parameter(Mandatory)] [string] $Username)
    $store = Invoke-PortalLock -Name 'auth-mfa' -ScriptBlock { Read-AuthStore 'mfa' }
    $e = Get-AV $store (Get-MfaKey $Username)
    return [ordered]@{
        enrolled       = [bool]($e -and (Get-AV $e 'secret'))
        enrolledAt     = Get-AV $e 'enrolledAt'
        recoveryLeft   = @(Get-AV $e 'recovery' @()).Count
    }
}

function Test-PortalMfaRequired {
    param([Parameter(Mandatory)] $User)
    $req = @((Get-PortalSecurityPolicy).mfa.requiredRoles)
    return [bool](@($User.roles) | Where-Object { $req -contains $_ })
}

function Start-PortalMfaEnrollment {
    <# Creates a pending TOTP secret. Returns the secret (base32) and the otpauth:// URI for the authenticator app. #>
    [CmdletBinding()] param([Parameter(Mandatory)] [string] $Username, [string] $DisplayName)
    $secret = [byte[]]::new(20); [System.Security.Cryptography.RandomNumberGenerator]::Fill($secret)
    $b32 = ConvertTo-Base32 $secret
    $k = Get-MfaKey $Username
    Invoke-PortalLock -Name 'auth-mfa' -ScriptBlock {
        $store = Read-AuthStore 'mfa'
        $e = Get-AV $store $k ([ordered]@{})
        $e['pending'] = Protect-PortalSecretValue -Value $b32 -Context "mfa-pending|$k"
        $e['pendingAt'] = (Get-NowUtc).ToString('o')
        $store[$k] = $e
        Save-AuthStore 'mfa' $store
    } | Out-Null
    $issuer = (Get-PortalSecurityPolicy).mfa.issuer
    if (-not $issuer) { $issuer = [string](Get-PortalConfig).portal.name }
    $label = [uri]::EscapeDataString("${issuer}:$Username")
    return [ordered]@{
        secret = $b32
        uri    = "otpauth://totp/${label}?secret=$b32&issuer=$([uri]::EscapeDataString($issuer))&algorithm=SHA1&digits=6&period=30"
    }
}

function Complete-PortalMfaEnrollment {
    <# Confirms the pending secret with a code. Returns 10 one-time recovery codes (shown once). #>
    [CmdletBinding()] param([Parameter(Mandatory)] [string] $Username, [Parameter(Mandatory)] [string] $Code)
    $k = Get-MfaKey $Username
    $codes = Invoke-PortalLock -Name 'auth-mfa' -ScriptBlock {
        $store = Read-AuthStore 'mfa'
        $e = Get-AV $store $k
        if (-not $e -or -not (Get-AV $e 'pending')) { throw 'Start the enrolment again (no pending authenticator).' }
        if ((ConvertTo-Utc $e.pendingAt) -lt (Get-NowUtc).AddMinutes(-15)) { throw 'The enrolment expired. Start again.' }
        $b32 = Unprotect-PortalSecretValue -Data $e.pending -Context "mfa-pending|$k"
        $step = Test-PortalTotp -Secret (ConvertFrom-Base32 $b32) -Code $Code
        if ($step -lt 0) { throw 'The code is not valid. Check the time on your phone and try again.' }
        $rc = @(1..10 | ForEach-Object { (New-RandomToken -Bytes 6).ToLowerInvariant().Substring(0, 8) -replace '(.{4})(.{4})', '$1-$2' })
        $store[$k] = [ordered]@{
            secret     = Protect-PortalSecretValue -Value $b32 -Context "mfa|$k"
            enrolledAt = (Get-NowUtc).ToString('o')
            lastStep   = $step
            recovery   = @($rc | ForEach-Object { Get-Sha256 "$k|$_" })
        }
        Save-AuthStore 'mfa' $store
        $rc
    }
    Write-PortalAudit -Actor $Username -Action 'mfa.enrolled'
    return $codes
}

function Test-PortalMfaCode {
    <# Verifies a TOTP code or a recovery code (consumed). #>
    param([Parameter(Mandatory)] [string] $Username, [string] $Code)
    if (-not $Code) { return $false }
    $k = Get-MfaKey $Username
    $ok = Invoke-PortalLock -Name 'auth-mfa' -ScriptBlock {
        $store = Read-AuthStore 'mfa'
        $e = Get-AV $store $k
        if (-not $e -or -not (Get-AV $e 'secret')) { return $false }
        $c = $Code.Trim().ToLowerInvariant()
        if ($c -match '^[a-z0-9_-]{4}-[a-z0-9_-]{4}$') {
            $h = Get-Sha256 "$k|$c"
            if (@($e.recovery) -contains $h) {
                $e.recovery = @(@($e.recovery) | Where-Object { $_ -ne $h }); $store[$k] = $e; Save-AuthStore 'mfa' $store
                Write-PortalAudit -Actor $Username -Action 'mfa.recoverycode.used' -Details @{ left = @($e.recovery).Count }
                return $true
            }
            return $false
        }
        $b32 = Unprotect-PortalSecretValue -Data $e.secret -Context "mfa|$k"
        $step = Test-PortalTotp -Secret (ConvertFrom-Base32 $b32) -Code $c -LastStep ([long](Get-AV $e 'lastStep' -1))
        if ($step -lt 0) { return $false }
        $e.lastStep = $step; $store[$k] = $e; Save-AuthStore 'mfa' $store
        return $true
    }
    return [bool]$ok
}

function Reset-PortalMfa {
    [CmdletBinding()] param([Parameter(Mandatory)] [string] $Username, [Parameter(Mandatory)] [string] $Actor)
    $k = Get-MfaKey $Username
    Invoke-PortalLock -Name 'auth-mfa' -ScriptBlock {
        $store = Read-AuthStore 'mfa'
        if ($store.Contains($k)) { $store.Remove($k); Save-AuthStore 'mfa' $store }
    } | Out-Null
    Write-PortalAudit -Actor $Actor -Action 'mfa.reset' -Target $Username
}

#endregion

#region Sessions -----------------------------------------------------------------------------------------------

function New-PortalSessionRecord {
    param([Parameter(Mandatory)] $AuthUser, [Parameter(Mandatory)] $User, [string] $Ip, [string] $UserAgent, [hashtable] $Flags)
    $sid = New-RandomToken -Bytes 18
    $now = (Get-NowUtc).ToString('o')
    Invoke-PortalLock -Name 'auth-sessions' -ScriptBlock {
        $store = Read-AuthStore 'sessions'
        # Housekeeping: drop sessions that ended more than a day ago.
        $cut = (Get-NowUtc).AddDays(-1)
        foreach ($k in @($store.Keys)) {
            $end = ConvertTo-Utc (Get-AV $store[$k] 'endedAt')
            if ($end -and $end -lt $cut) { $store.Remove($k) }
        }
        $store[$sid] = [ordered]@{
            username = $User.username; name = $User.name; provider = $User.provider; ip = $Ip; userAgent = $UserAgent
            loginAt = $now; lastActivity = $now; lastSeen = $now; reauthAt = $now; endedAt = $null; endReason = $null
            mustChangePassword = [bool](Get-AV $Flags 'mustChangePassword' $false)
            mfaEnrollRequired  = [bool](Get-AV $Flags 'mfaEnrollRequired' $false)
            breakGlass         = [bool](Get-AV $Flags 'breakGlass' $false)
        }
        Save-AuthStore 'sessions' $store
    } | Out-Null
    return $sid
}

function Update-PortalSessionRecord {
    param([Parameter(Mandatory)] [string] $Sid, [Parameter(Mandatory)] [scriptblock] $Mutate)
    Invoke-PortalLock -Name 'auth-sessions' -ScriptBlock {
        $store = Read-AuthStore 'sessions'
        $s = Get-AV $store $Sid
        if (-not $s) { return }
        & $Mutate $s
        Save-AuthStore 'sessions' $store
    } | Out-Null
}

function Stop-PortalSession {
    [CmdletBinding()] param([Parameter(Mandatory)] [string] $Sid, [string] $Reason = 'logout', [string] $Actor)
    Update-PortalSessionRecord -Sid $Sid -Mutate { param($s) if (-not $s.endedAt) { $s.endedAt = (Get-NowUtc).ToString('o'); $s.endReason = $Reason } }
    if ($Actor) { Write-PortalAudit -Actor $Actor -Action "session.$Reason" -Target $Sid.Substring(0, 8) }
}

function Get-PortalSessionList {
    <# Active sessions (Admin > Security). The session id is shortened; full ids never leave the server. #>
    [CmdletBinding()] param()
    $store = Invoke-PortalLock -Name 'auth-sessions' -ScriptBlock { Read-AuthStore 'sessions' }
    $pol = (Get-PortalSecurityPolicy).session
    $now = Get-NowUtc
    foreach ($k in $store.Keys) {
        $s = $store[$k]
        if (Get-AV $s 'endedAt') { continue }
        if ((ConvertTo-Utc $s.lastActivity).AddMinutes($pol.idleTimeoutMinutes) -lt $now) { continue }
        if ((ConvertTo-Utc $s.loginAt).AddMinutes($pol.absoluteTimeoutMinutes) -lt $now) { continue }
        [ordered]@{ id = $k.Substring(0, 10); username = $s.username; name = $s.name; provider = $s.provider; ip = $s.ip
                    userAgent = $s.userAgent; loginAt = $s.loginAt; lastActivity = $s.lastActivity; breakGlass = [bool](Get-AV $s 'breakGlass' $false) }
    }
}

function Revoke-PortalSession {
    <# Ends sessions by short id (from Get-PortalSessionList) or every session of a user. #>
    [CmdletBinding()] param([string] $ShortId, [string] $Username, [Parameter(Mandatory)] [string] $Actor)
    $n = 0
    Invoke-PortalLock -Name 'auth-sessions' -ScriptBlock {
        $store = Read-AuthStore 'sessions'
        foreach ($k in @($store.Keys)) {
            $s = $store[$k]
            if (Get-AV $s 'endedAt') { continue }
            if (($ShortId -and $k.StartsWith($ShortId)) -or ($Username -and $s.username -ieq $Username)) {
                $s.endedAt = (Get-NowUtc).ToString('o'); $s.endReason = 'revoked'
            }
        }
        Save-AuthStore 'sessions' $store
    } | Out-Null
    Write-PortalAudit -Actor $Actor -Action 'session.revoke' -Target $(if ($ShortId) { $ShortId } else { $Username })
}

function Get-PortalSessionInfo {
    <# Timers for the browser (idle warning, absolute expiry). #>
    param([Parameter(Mandatory)] [string] $Sid)
    $store = Invoke-PortalLock -Name 'auth-sessions' -ScriptBlock { Read-AuthStore 'sessions' }
    $s = Get-AV $store $Sid
    $pol = (Get-PortalSecurityPolicy).session
    if (-not $s) { return $null }
    return [ordered]@{
        idleTimeoutMinutes = $pol.idleTimeoutMinutes
        warningSeconds     = $pol.warningSeconds
        lastActivity       = $s.lastActivity
        expiresAt          = (ConvertTo-Utc $s.loginAt).AddMinutes($pol.absoluteTimeoutMinutes).ToString('o')
        mustChangePassword = [bool]$s.mustChangePassword
        mfaEnrollRequired  = [bool]$s.mfaEnrollRequired
        reauthValidUntil   = (ConvertTo-Utc $s.reauthAt).AddMinutes($pol.reauthWindowMinutes).ToString('o')
    }
}

function Test-PortalSessionGate {
    <#
    .SYNOPSIS Enforces the session rules for one API call. Throws an API error (401/403 + code) or returns the record.
    .PARAMETER Background  Automatic refreshes (X-Portal-Background: 1) do not count as user activity.
    .PARAMETER AllowRestricted  Endpoint usable while a password change / MFA enrolment is pending.
    .PARAMETER RequireReauth  Sensitive action: password re-entered within security.session.reauthWindowMinutes.
    #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Sid, [switch] $Background, [switch] $AllowRestricted, [switch] $RequireReauth)
    $fail = { param($status, $code, $msg) $ex = [System.InvalidOperationException]::new($msg); $ex.Data['status'] = $status; $ex.Data['fields'] = @{ code = $code }; throw $ex }
    if (-not $Sid) { & $fail 401 'SESSION_EXPIRED' 'Your session has expired. Please sign in again.' }
    $pol = (Get-PortalSecurityPolicy).session
    $result = Invoke-PortalLock -Name 'auth-sessions' -ScriptBlock {
        $store = Read-AuthStore 'sessions'
        $s = Get-AV $store $Sid
        $now = Get-NowUtc
        if (-not $s) { return @{ code = 'SESSION_EXPIRED' } }
        if (Get-AV $s 'endedAt') { return @{ code = $(if ($s.endReason -eq 'revoked') { 'SESSION_REVOKED' } else { 'SESSION_EXPIRED' }) } }
        if ((ConvertTo-Utc $s.lastActivity).AddMinutes($pol.idleTimeoutMinutes) -lt $now) {
            $s.endedAt = $now.ToString('o'); $s.endReason = 'idle'; Save-AuthStore 'sessions' $store; return @{ code = 'SESSION_IDLE' }
        }
        if ((ConvertTo-Utc $s.loginAt).AddMinutes($pol.absoluteTimeoutMinutes) -lt $now) {
            $s.endedAt = $now.ToString('o'); $s.endReason = 'expired'; Save-AuthStore 'sessions' $store; return @{ code = 'SESSION_EXPIRED' }
        }
        $dirty = $false
        if (-not $Background -and (ConvertTo-Utc $s.lastActivity) -lt $now.AddSeconds(-10)) { $s.lastActivity = $now.ToString('o'); $dirty = $true }
        if ((ConvertTo-Utc $s.lastSeen) -lt $now.AddSeconds(-30)) { $s.lastSeen = $now.ToString('o'); $dirty = $true }
        if ($dirty) { Save-AuthStore 'sessions' $store }
        return @{ code = $null; record = $s }
    }
    switch ($result.code) {
        'SESSION_IDLE'    { & $fail 401 'SESSION_IDLE' "Signed out after $($pol.idleTimeoutMinutes) minutes of inactivity." }
        'SESSION_REVOKED' { & $fail 401 'SESSION_REVOKED' 'Your session was ended by an administrator.' }
        'SESSION_EXPIRED' { & $fail 401 'SESSION_EXPIRED' 'Your session has expired. Please sign in again.' }
    }
    $s = $result.record
    if (-not $AllowRestricted) {
        if ($s.mustChangePassword) { & $fail 403 'PASSWORD_CHANGE_REQUIRED' 'You must change your password before continuing.' }
        if ($s.mfaEnrollRequired)  { & $fail 403 'MFA_ENROLLMENT_REQUIRED' 'Your role requires multi-factor authentication. Set up your authenticator app to continue.' }
    }
    if ($RequireReauth -and (ConvertTo-Utc $s.reauthAt).AddMinutes($pol.reauthWindowMinutes) -lt (Get-NowUtc)) {
        & $fail 401 'REAUTH_REQUIRED' 'Confirm your password to continue.'
    }
    return $s
}

#endregion

#region Sign-in --------------------------------------------------------------------------------------------------

function Invoke-PortalPrimaryAuthentication {
    <# Username + password against the routed provider. Returns @{ ok; code; message; authUser }. #>
    param([string] $Username, [string] $Password)
    $target = Resolve-PortalLoginTarget -Username $Username
    if (-not $target) { return [ordered]@{ ok = $false; code = 'invalid'; message = 'Invalid username or password.' } }
    if ($target.kind -eq 'local') {
        $u = Test-PortalLocalCredential -Username $target.login -Password $Password
        if (-not $u) { return [ordered]@{ ok = $false; code = 'invalid'; message = 'Invalid username or password.' } }
        return [ordered]@{ ok = $true; authUser = $u }
    }
    $r = Invoke-PortalLdapAuthentication -Provider $target.provider -Login $target.login -Password $Password -Upn ([string](Get-AV $target 'upn' ''))
    if (-not $r.ok) { return $r }
    return [ordered]@{ ok = $true; authUser = $r.user }
}

function Invoke-PortalLogin {
    <#
    .SYNOPSIS Full sign-in. Returns @{ ok; next ('mfa' | $null); message; ticket } - never says whether a user exists.
    #>
    [CmdletBinding()]
    param([string] $Username, [string] $Password, [string] $Otp, [string] $Ip, [string] $UserAgent)
    $Username = ([string]$Username).Trim()
    if (-not $Username -or -not $Password -or $Username.Length -gt 256) { return [ordered]@{ ok = $false; message = 'Enter your username and password.' } }

    $lock = Get-PortalLockoutState -Username $Username -Ip $Ip
    if ($lock -gt 0) {
        Write-PortalAudit -Actor $Username -Action 'auth.locked' -Details @{ ip = $Ip }
        return [ordered]@{ ok = $false; message = "Too many failed attempts. Try again in $([math]::Ceiling($lock / 60)) minute(s)." }
    }

    $primary = Invoke-PortalPrimaryAuthentication -Username $Username -Password $Password
    if (-not $primary.ok) {
        $script:JustLocked = $false
        if ($primary.code -ne 'unavailable') { Register-PortalLoginFailure -Username $Username -Ip $Ip }
        Write-PortalAudit -Actor $Username -Action 'auth.failed' -Details @{ ip = $Ip; reason = $primary.code }
        $msg = if ($script:JustLocked) { 'Too many failed attempts. The account is locked for a few minutes.' }
               elseif ($primary.code -in 'locked', 'expired', 'mustchange', 'disabled', 'unavailable') { $primary.message }
               else { 'Invalid username or password.' }
        return [ordered]@{ ok = $false; message = $msg }
    }

    $auth = $primary.authUser
    $user = Get-PortalUserContext -AuthUser $auth -ClientIp $Ip
    if (-not $user.roles) {
        Write-PortalAudit -Actor $user.username -Action 'auth.norole' -Details @{ ip = $Ip }
        return [ordered]@{ ok = $false; message = 'Your account is not authorised for this portal (no role assigned).' }
    }

    $mfa = Get-PortalMfaStatus -Username $user.username
    if ($mfa.enrolled) {
        if (-not $Otp) { return [ordered]@{ ok = $false; next = 'mfa'; message = 'Enter the 6-digit code from your authenticator app.' } }
        $mfaOk = try { Test-PortalMfaCode -Username $user.username -Code $Otp } catch {
            Write-PortalLog -Level ERROR -Message "MFA verification failed for $($user.username): $($_.Exception.Message)"
            return [ordered]@{ ok = $false; message = 'Multi-factor verification is unavailable (vault key). Contact your administrator.' }
        }
        if (-not $mfaOk) {
            $script:JustLocked = $false
            Register-PortalLoginFailure -Username $Username -Ip $Ip
            Write-PortalAudit -Actor $user.username -Action 'auth.mfa.failed' -Details @{ ip = $Ip }
            return [ordered]@{ ok = $false; next = 'mfa'; message = $(if ($script:JustLocked) { 'Too many failed attempts. The account is locked for a few minutes.' } else { 'The verification code is not valid.' }) }
        }
    }
    Clear-PortalLoginFailure -Username $Username

    $flags = @{
        mustChangePassword = [bool](Get-AV $auth 'MustChangePassword' $false)
        mfaEnrollRequired  = (-not $mfa.enrolled -and (Test-PortalMfaRequired -User $user))
        breakGlass         = [bool](Get-AV $auth 'BreakGlass' $false)
    }
    $sid = New-PortalSessionRecord -AuthUser $auth -User $user -Ip $Ip -UserAgent $UserAgent -Flags $flags
    $auth['Sid'] = $sid
    $auth.Remove('MustChangePassword'); $auth.Remove('BreakGlass')

    $ticket = New-RandomToken -Bytes 32
    Invoke-PortalLock -Name 'auth-tickets' -ScriptBlock {
        $store = Read-AuthStore 'tickets'
        $now = Get-NowUtc
        foreach ($k in @($store.Keys)) { if ((ConvertTo-Utc $store[$k].expires) -lt $now) { $store.Remove($k) } }
        $store[(Get-Sha256 $ticket)] = [ordered]@{ user = $auth; ip = $Ip; expires = $now.AddSeconds(60).ToString('o') }
        Save-AuthStore 'tickets' $store
    } | Out-Null

    $action = if ($flags.breakGlass) { 'auth.breakglass' } else { 'auth.success' }
    Write-PortalAudit -Actor $user.username -Action $action -Details @{ ip = $Ip; provider = $user.provider; mfa = $mfa.enrolled }
    if ($flags.breakGlass) { Write-PortalLog -Level WARN -Message "BREAK-GLASS account $($user.username) signed in from $Ip." }
    return [ordered]@{ ok = $true; ticket = $ticket }
}

function Use-PortalLoginTicket {
    <# Pode form-auth script: exchanges the one-time ticket for the auth user. Returns $null when invalid. #>
    [CmdletBinding()] param([string] $Ticket, [string] $Ip)
    if (-not $Ticket -or $Ticket.Length -lt 20) { return $null }
    $h = Get-Sha256 $Ticket
    return (Invoke-PortalLock -Name 'auth-tickets' -ScriptBlock {
        $store = Read-AuthStore 'tickets'
        $t = Get-AV $store $h
        if (-not $t) { return $null }
        $store.Remove($h); Save-AuthStore 'tickets' $store
        if ((ConvertTo-Utc $t.expires) -lt (Get-NowUtc)) { return $null }
        if ($Ip -and $t.ip -and $t.ip -ne $Ip) { return $null }
        return $t.user
    })
}

function Confirm-PortalReauthentication {
    <# Re-enter password (+ MFA code when enrolled) for sensitive actions. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $User, [string] $Password, [string] $Otp, [string] $Ip)
    $lock = Get-PortalLockoutState -Username $User.username -Ip $Ip
    if ($lock -gt 0) { throw "Too many failed attempts. Try again in $([math]::Ceiling($lock / 60)) minute(s)." }
    $bare = $User.username -replace '^.*\\', ''
    $r = if ($User.local -or -not $User.provider -or $User.provider -eq 'local') { Invoke-PortalPrimaryAuthentication -Username "LOCAL\$bare" -Password $Password }
         else {
             $prov = Get-PortalIdentityProvider -Id $User.provider
             if (-not $prov) { [ordered]@{ ok = $false } } else { Invoke-PortalLdapAuthentication -Provider $prov -Login $bare -Password $Password }
         }
    $ok = $r.ok
    if ($ok -and (Get-PortalMfaStatus -Username $User.username).enrolled) {
        if (-not $Otp) { return [ordered]@{ ok = $false; next = 'mfa' } }
        $ok = Test-PortalMfaCode -Username $User.username -Code $Otp
    }
    if (-not $ok) {
        Register-PortalLoginFailure -Username $User.username -Ip $Ip
        Write-PortalAudit -Actor $User.username -Action 'auth.reauth.failed' -Details @{ ip = $Ip }
        throw 'The password or code is not correct.'
    }
    Update-PortalSessionRecord -Sid $User.sid -Mutate { param($s) $s.reauthAt = (Get-NowUtc).ToString('o'); $s.lastActivity = (Get-NowUtc).ToString('o') }
    Write-PortalAudit -Actor $User.username -Action 'auth.reauth' -Details @{ ip = $Ip }
    return [ordered]@{ ok = $true }
}

function Clear-PortalSessionFlag {
    param([Parameter(Mandatory)] [string] $Sid, [ValidateSet('mustChangePassword', 'mfaEnrollRequired')] [string] $Flag)
    Update-PortalSessionRecord -Sid $Sid -Mutate { param($s) $s[$Flag] = $false; $s.reauthAt = (Get-NowUtc).ToString('o') }
}

#endregion

Export-ModuleMember -Function Get-PortalRequestMeta, Invoke-PortalLogin, Use-PortalLoginTicket, Test-PortalSessionGate, Get-PortalSessionInfo,
    Stop-PortalSession, Get-PortalSessionList, Revoke-PortalSession, Confirm-PortalReauthentication, Clear-PortalSessionFlag,
    Get-PortalLockoutState, Get-PortalLockoutList, Clear-PortalLockout, Get-PortalMfaStatus, Start-PortalMfaEnrollment, Complete-PortalMfaEnrollment,
    Test-PortalMfaCode, Reset-PortalMfa, Test-PortalMfaRequired, Get-PortalTotpCode, ConvertFrom-Base32, ConvertTo-Base32, Get-TotpStep
