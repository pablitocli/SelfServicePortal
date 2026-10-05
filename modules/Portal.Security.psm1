#Requires -Version 7.2
<#
.SYNOPSIS
    Portal.Security - maps the authenticated identity (AD or local) to portal roles (Requester / Approver / Admin)
    and teams (e.g. Infrastructure / Cloud). Roles define WHAT a user can do; teams define WHICH catalog items they see.
#>

Set-StrictMode -Version Latest

function Get-PortalAllowedGroups {
    <# All AD groups that grant access to the portal (union of every role mapping). #>
    [CmdletBinding()] param()
    $map = (Get-PortalConfig).auth.roleMapping
    return @($map.Keys | ForEach-Object { $map[$_] } | Where-Object { $_ } | Sort-Object -Unique)
}

$script:AdminRoles = @('Admin', 'CatalogAdmin', 'SecurityAdmin', 'VaultAdmin')
$script:AllRoles   = @('Requester', 'Approver', 'Admin', 'CatalogAdmin', 'SecurityAdmin', 'VaultAdmin')

# Permission -> roles allowed. Admin holds every permission; the *Admin roles split administration (separation of duties).
$script:Permissions = @{
    'catalog.manage'     = @('Admin', 'CatalogAdmin')     # catalog editor, handlers, branding / teams / VM notes
    'security.manage'    = @('Admin', 'SecurityAdmin')    # identity providers, local users, role mapping, security policies, sessions
    'vault.manage'       = @('Admin', 'VaultAdmin')       # credential vault
    'connections.manage' = @('Admin')                     # vCenter / cloud connections, inventory
    'audit.read'         = @('Admin', 'SecurityAdmin')
}

function Get-PortalRoleList { [CmdletBinding()] param() return $script:AllRoles }

function Test-PortalIpInCidr {
    <# True when $Ip is inside any of the CIDR ranges (IPv4 / IPv6). Single addresses are accepted as /32 or /128. #>
    param([string] $Ip, [string[]] $Cidr)
    $addr = $null
    if (-not $Ip -or -not [System.Net.IPAddress]::TryParse($Ip, [ref]$addr)) { return $false }
    if ($addr.IsIPv4MappedToIPv6) { $addr = $addr.MapToIPv4() }
    foreach ($c in @($Cidr | Where-Object { $_ })) {
        $parts = ([string]$c).Trim() -split '/'
        $net = $null
        if (-not [System.Net.IPAddress]::TryParse($parts[0], [ref]$net)) { continue }
        if ($net.AddressFamily -ne $addr.AddressFamily) { continue }
        $a = $addr.GetAddressBytes(); $n = $net.GetAddressBytes()
        $bits = if ($parts.Count -gt 1) { [int]$parts[1] } else { $a.Length * 8 }
        $match = $true
        for ($i = 0; $i -lt $a.Length -and $bits -gt 0; $i++) {
            $mask = if ($bits -ge 8) { 0xFF } else { (0xFF -shl (8 - $bits)) -band 0xFF }
            if (($a[$i] -band $mask) -ne ($n[$i] -band $mask)) { $match = $false; break }
            $bits -= 8
        }
        if ($match) { return $true }
    }
    return $false
}

function Get-PortalUserContext {
    <#
    .SYNOPSIS Normalises the authenticated identity into the portal user context (roles, teams, session id).
    .PARAMETER AuthUser  $WebEvent.Auth.User (set at sign-in by Portal.Auth: Username, Name, Email, Domain, Groups,
                         Provider, Sid; local accounts also carry PortalRoles / PortalTeams).
    .PARAMETER ClientIp  When security.adminAllowedCidrs is set, administrative roles only apply from those networks.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $AuthUser, [string] $ClientIp)

    $u = ConvertTo-PortalHashtable $AuthUser
    $groups = @($u['Groups']) | Where-Object { $_ } | ForEach-Object { ([string]$_) -replace '^.*\\', '' }
    $cfg = Get-PortalConfig
    $map = $cfg.auth.roleMapping

    if ($u.Contains('PortalRoles') -and $u['PortalRoles']) {
        $assigned = @($u['PortalRoles'])          # local accounts carry their roles explicitly
    }
    else {
        $assigned = @(foreach ($role in $map.Keys) {
            $roleGroups = @($map[$role])
            if ($groups | Where-Object { $roleGroups -contains $_ }) { $role }   # -contains is case-insensitive
        })
    }

    # Administrative roles can be limited to management networks.
    $restricted = $false
    $cidrs = @(if ($cfg.Contains('security') -and $cfg.security.Contains('adminAllowedCidrs')) { $cfg.security.adminAllowedCidrs } else { @() }) | Where-Object { $_ }
    if ($cidrs -and $ClientIp -and -not (Test-PortalIpInCidr -Ip $ClientIp -Cidr $cidrs)) {
        if ($assigned | Where-Object { $script:AdminRoles -contains $_ }) { $restricted = $true }
        $assigned = @($assigned | Where-Object { $script:AdminRoles -notcontains $_ })
    }

    # Admin implies every role; Approver implies Requester.
    $effective = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $assigned) {
        [void]$effective.Add($r)
        if ($r -eq 'Admin')    { $script:AllRoles | ForEach-Object { [void]$effective.Add($_) } }
        if ($r -eq 'Approver') { [void]$effective.Add('Requester') }
    }

    $username = [string]$u['Username']
    if ($u['Domain'] -and $username -notmatch '\\') { $username = '{0}\{1}' -f $u['Domain'], $username }

    # Teams: local accounts carry them; directory users get them from teams[].adGroups.
    $teams = if ($u.Contains('PortalTeams')) { @($u['PortalTeams'] | Where-Object { $_ }) }
             else {
                 @(@(if ($cfg.Contains('teams')) { $cfg.teams } else { @() }) | Where-Object {
                     $tg = @(if ($_.Contains('adGroups')) { $_.adGroups } else { @() })
                     $groups | Where-Object { $tg -contains $_ }
                 } | ForEach-Object { $_.id })
             }

    return [ordered]@{
        username      = $username
        name          = if ($u['Name']) { [string]$u['Name'] } else { $username }
        email         = [string]$u['Email']
        roles         = @($effective | Sort-Object)
        assignedRoles = @($assigned | Sort-Object -Unique)
        teams         = @($teams | Sort-Object -Unique)
        provider      = if ($u['Provider']) { [string]$u['Provider'] } elseif ($u['Domain'] -eq 'LOCAL') { 'local' } else { '' }
        local         = ($u['Domain'] -eq 'LOCAL')
        sid           = [string]$u['Sid']
        networkRestricted = $restricted
    }
}

function Test-PortalPermission {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $User, [Parameter(Mandatory)] [string] $Permission)
    $roles = $script:Permissions[$Permission]
    if (-not $roles) { throw "Unknown permission '$Permission'." }
    return (Test-PortalRole -User $User -Role $roles)
}

function Get-PortalPermissionSet {
    <# Permissions of a user (drives which Admin tabs the UI shows). #>
    param([Parameter(Mandatory)] $User)
    return @($script:Permissions.Keys | Where-Object { Test-PortalPermission -User $User -Permission $_ } | Sort-Object)
}

#region Local accounts (lab / break-glass) ---------------------------------------------------------------------

$script:Pbkdf2Iterations = 210000
$script:DummyHash = 'pbkdf2-sha256$210000$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='

function Get-PortalLocalUserStore {
    $cfg = (Get-PortalConfig).auth
    if (-not ($cfg.Contains('localUsers') -and $cfg.localUsers.enabled)) { return $null }
    $file = if ($cfg.localUsers.Contains('file')) { $cfg.localUsers.file } else { 'config/local-users.json' }
    if (-not [System.IO.Path]::IsPathRooted($file)) { $file = Join-Path (Get-PortalRoot) $file }
    return $file
}

function New-PortalPasswordHash {
    <# PBKDF2-HMAC-SHA256, random 16-byte salt. Returns "pbkdf2-sha256$<iterations>$<salt b64>$<hash b64>". #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Password, [int] $Iterations = $script:Pbkdf2Iterations)
    $salt = [byte[]]::new(16)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($salt)
    $hash = [System.Security.Cryptography.Rfc2898DeriveBytes]::Pbkdf2(
        [System.Text.Encoding]::UTF8.GetBytes($Password), $salt, $Iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256, 32)
    return ('pbkdf2-sha256${0}${1}${2}' -f $Iterations, [Convert]::ToBase64String($salt), [Convert]::ToBase64String($hash))
}

function Test-PortalPasswordHash {
    param([string] $Password, [string] $Stored)
    $parts = $Stored -split '\$'
    if ($parts.Count -ne 4 -or $parts[0] -ne 'pbkdf2-sha256') { return $false }
    $salt = [Convert]::FromBase64String($parts[2]); $expected = [Convert]::FromBase64String($parts[3])
    $actual = [System.Security.Cryptography.Rfc2898DeriveBytes]::Pbkdf2(
        [System.Text.Encoding]::UTF8.GetBytes($Password), $salt, [int]$parts[1], [System.Security.Cryptography.HashAlgorithmName]::SHA256, $expected.Length)
    return [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($actual, $expected)
}

function Test-PortalLocalAccountExists {
    <# True when an (enabled) local account has this name - used to route bare usernames. #>
    param([string] $Username)
    $file = Get-PortalLocalUserFile
    if (-not $Username -or -not (Test-Path -LiteralPath $file)) { return $false }
    $name = ($Username -replace '^(LOCAL|\.)\\', '').Trim()
    return [bool](@((Read-PortalJson -Path $file).users) | Where-Object { $_ -and $_.username -eq $name -and $_.enabled })
}

function Get-PortalSecurityPolicy {
    <# Effective security policy (security.* in portal.config.json merged with defaults). #>
    [CmdletBinding()] param()
    $cfg = Get-PortalConfig
    $sec = if ($cfg.Contains('security')) { $cfg.security } else { @{} }
    $get = { param($section, $key, $def) if ($sec.Contains($section) -and $sec[$section] -is [System.Collections.IDictionary] -and $sec[$section].Contains($key) -and $null -ne $sec[$section][$key]) { $sec[$section][$key] } else { $def } }
    $legacyAbs = if ($cfg.portal.Contains('sessionDurationMinutes')) { [int]$cfg.portal.sessionDurationMinutes } else { 480 }
    return [ordered]@{
        session = [ordered]@{
            idleTimeoutMinutes     = [int](& $get 'session' 'idleTimeoutMinutes' 30)
            absoluteTimeoutMinutes = [int](& $get 'session' 'absoluteTimeoutMinutes' $legacyAbs)
            warningSeconds         = [int](& $get 'session' 'warningSeconds' 120)
            reauthWindowMinutes    = [int](& $get 'session' 'reauthWindowMinutes' 5)
        }
        password = [ordered]@{
            minLength      = [int](& $get 'password' 'minLength' 14)
            requireClasses = [int](& $get 'password' 'requireClasses' 3)
            history        = [int](& $get 'password' 'history' 5)
            maxAgeDays     = [int](& $get 'password' 'maxAgeDays' 0)
        }
        lockout = [ordered]@{
            threshold       = [int](& $get 'lockout' 'threshold' 5)
            windowMinutes   = [int](& $get 'lockout' 'windowMinutes' 15)
            durationMinutes = [int](& $get 'lockout' 'durationMinutes' 15)
        }
        mfa = [ordered]@{
            requiredRoles = @(& $get 'mfa' 'requiredRoles' @('Admin', 'SecurityAdmin', 'VaultAdmin'))
            issuer        = [string](& $get 'mfa' 'issuer' '')
        }
        adminAllowedCidrs  = @(if ($sec.Contains('adminAllowedCidrs')) { $sec.adminAllowedCidrs } else { @() })
        trustedProxies     = @(if ($sec.Contains('trustedProxies')) { $sec.trustedProxies } else { @() })
        separationOfDuties = [ordered]@{ vaultAdminCanApprove = [bool](& $get 'separationOfDuties' 'vaultAdminCanApprove' $false) }
    }
}

function Test-PortalPasswordPolicy {
    <# Returns the list of policy violations (empty = compliant). #>
    [CmdletBinding()]
    param([string] $Password, [string] $Username, [string[]] $History)
    $pol = (Get-PortalSecurityPolicy).password
    $errs = [System.Collections.Generic.List[string]]::new()
    if (-not $Password -or $Password.Length -lt $pol.minLength) { $errs.Add("at least $($pol.minLength) characters") }
    $classes = @('[a-z]', '[A-Z]', '[0-9]', '[^A-Za-z0-9]' | Where-Object { $Password -cmatch $_ }).Count
    if ($classes -lt $pol.requireClasses) { $errs.Add("$($pol.requireClasses) of: lowercase, uppercase, digit, symbol") }
    if ($Username -and $Password -and $Password.IndexOf(($Username -replace '^.*\\', ''), [StringComparison]::OrdinalIgnoreCase) -ge 0) { $errs.Add('must not contain the username') }
    foreach ($h in @($History | Where-Object { $_ })) {
        if (Test-PortalPasswordHash -Password $Password -Stored $h) { $errs.Add("must differ from the last $($pol.history) passwords"); break }
    }
    return $errs.ToArray()
}

function Test-PortalLocalCredential {
    <#
    .SYNOPSIS Validates a local portal account. Returns the auth user object, or $null.
    .NOTES    When local accounts are disabled (auth.localUsers.enabled = false) only break-glass accounts can sign in.
    #>
    [CmdletBinding()]
    param([string] $Username, [string] $Password)
    $file = Get-PortalLocalUserFile
    if (-not (Test-Path -LiteralPath $file) -or -not $Username -or -not $Password) { return $null }
    $localEnabled = [bool](Get-PortalLocalUserStore)
    $name = ($Username -replace '^(LOCAL|\.)\\', '').Trim()
    $entry = @((Read-PortalJson -Path $file).users) | Where-Object { $_ -and $_.username -eq $name -and $_.enabled } | Select-Object -First 1
    if (-not $entry) {
        # Same cost as a wrong password, so response time does not reveal which accounts exist.
        $null = Test-PortalPasswordHash -Password $Password -Stored $script:DummyHash
        Start-Sleep -Milliseconds 800
        return $null
    }
    $breakGlass = [bool]($entry.Contains('breakGlass') -and $entry.breakGlass)
    if (-not $localEnabled -and -not $breakGlass) { return $null }
    if (-not (Test-PortalPasswordHash -Password $Password -Stored $entry.passwordHash)) {
        Start-Sleep -Milliseconds 800     # slow down guessing
        return $null
    }
    $pol = (Get-PortalSecurityPolicy).password
    $must = [bool]($entry.Contains('mustChangePassword') -and $entry.mustChangePassword)
    if (-not $must -and $pol.maxAgeDays -gt 0 -and $entry.Contains('passwordChangedAt') -and $entry.passwordChangedAt) {
        if (([datetime]$entry.passwordChangedAt).AddDays($pol.maxAgeDays) -lt (Get-Date)) { $must = $true }
    }
    return [ordered]@{
        Username           = $entry.username
        Name               = if ($entry.Contains('displayName')) { $entry.displayName } else { $entry.username }
        Email              = if ($entry.Contains('email')) { $entry.email } else { '' }
        Domain             = 'LOCAL'
        Provider           = 'local'
        Groups             = @()
        PortalRoles        = @($entry.roles)
        PortalTeams        = @(if ($entry.Contains('teams')) { $entry.teams } else { @() })
        MustChangePassword = $must
        BreakGlass         = $breakGlass
    }
}

function Get-PortalLocalUserFile {
    $cfg = (Get-PortalConfig).auth
    $file = if ($cfg.Contains('localUsers') -and $cfg.localUsers.Contains('file')) { $cfg.localUsers.file } else { 'config/local-users.json' }
    if (-not [System.IO.Path]::IsPathRooted($file)) { $file = Join-Path (Get-PortalRoot) $file }
    return $file
}

function Get-PortalLocalUserList {
    <# Local accounts without password hashes. #>
    [CmdletBinding()] param()
    $store = Read-PortalJson -Path (Get-PortalLocalUserFile)
    foreach ($u in @($store ? $store.users : @()) | Where-Object { $_ }) {
        [ordered]@{
            username    = $u.username
            displayName = if ($u.Contains('displayName')) { $u.displayName } else { $u.username }
            email       = if ($u.Contains('email')) { $u.email } else { '' }
            roles       = @($u.roles)
            teams       = @(if ($u.Contains('teams')) { $u.teams } else { @() })
            enabled     = [bool]$u.enabled
            mustChangePassword = [bool]($u.Contains('mustChangePassword') -and $u.mustChangePassword)
            breakGlass  = [bool]($u.Contains('breakGlass') -and $u.breakGlass)
            passwordChangedAt = if ($u.Contains('passwordChangedAt')) { $u.passwordChangedAt } else { $null }
            createdAt   = if ($u.Contains('createdAt')) { $u.createdAt } else { $null }
            updatedAt   = if ($u.Contains('updatedAt')) { $u.updatedAt } else { $null }
        }
    }
}

function Set-PortalLocalUserEntry {
    <#
    .SYNOPSIS Creates or updates a local account. Password optional on update (security.password policy applies when given).
    .NOTES    An account cannot disable, demote or delete itself (prevents Admin lock-out).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Username,
        [string] $DisplayName,
        [string] $Email,
        [string[]] $Roles,
        [string[]] $Teams,
        [string] $Password,
        [Nullable[bool]] $Enabled,
        [Nullable[bool]] $MustChangePassword,
        [Nullable[bool]] $BreakGlass,
        [switch] $New,
        [Parameter(Mandatory)] [string] $Actor
    )
    if ($Username -notmatch '^[A-Za-z0-9._-]{3,32}$') { throw 'Username must be 3-32 characters: letters, digits, dot, underscore or hyphen.' }
    foreach ($r in @($Roles)) { if ($r -and $script:AllRoles -notcontains $r) { throw "Unknown role '$r'." } }
    $known = @(Get-PortalTeamList | ForEach-Object { $_.id })
    foreach ($t in @($Teams)) { if ($t -and $known -notcontains $t) { throw "Unknown team '$t' (Admin > Customization > Teams)." } }
    $file = Get-PortalLocalUserFile
    $bound = @{} + $PSBoundParameters
    $isSelf = ($Actor -ieq "LOCAL\$Username")
    if ($isSelf -and (($null -ne $Enabled -and -not $Enabled) -or ($Roles -and -not ($Roles | Where-Object { $_ -in 'Admin', 'SecurityAdmin' })))) {
        throw 'You cannot disable your own account or remove your own administrative role.'
    }
    $histMax = (Get-PortalSecurityPolicy).password.history
    Invoke-PortalLock -Name 'local-users' -ScriptBlock {
        $store = Read-PortalJson -Path $file
        if (-not $store) { $store = [ordered]@{ users = @() } }
        $users = [System.Collections.Generic.List[object]]::new()
        @($store.users) | Where-Object { $_ } | ForEach-Object { $users.Add($_) }
        $u = $users | Where-Object { $_.username -eq $Username } | Select-Object -First 1
        if ($New -and $u) { throw "User '$Username' already exists." }
        if (-not $u) {
            if (-not $Password) { throw 'A password is required for a new user.' }
            if (-not $Roles) { throw 'At least one role is required for a new user.' }
            $u = [ordered]@{ username = $Username; displayName = $Username; email = ''; roles = @(); enabled = $true; passwordHash = ''; createdAt = (Get-PortalTimestamp) }
            $users.Add($u)
        }
        if ($bound.ContainsKey('DisplayName') -and $DisplayName) { $u.displayName = $DisplayName }
        if ($bound.ContainsKey('Email')) { $u.email = [string]$Email }
        if ($Roles) { $u.roles = @($Roles) }
        if ($bound.ContainsKey('Teams')) { $u['teams'] = @($Teams | Where-Object { $_ }) }
        if ($null -ne $Enabled) { $u.enabled = [bool]$Enabled }
        if ($null -ne $BreakGlass) { $u['breakGlass'] = [bool]$BreakGlass }
        if ($Password) {
            $hist = @(if ($u.Contains('passwordHistory')) { $u.passwordHistory } else { @() })
            $bad = @(Test-PortalPasswordPolicy -Password $Password -Username $Username -History (@($hist) + $(if ($u.passwordHash) { $u.passwordHash } else { @() })))
            if ($bad) { throw "Password policy: $($bad -join '; ')." }
            if ($u.passwordHash) { $u['passwordHistory'] = @(@($hist) + $u.passwordHash | Select-Object -Last $histMax) }
            $u.passwordHash = New-PortalPasswordHash -Password $Password
            $u['passwordChangedAt'] = Get-PortalTimestamp
            # A password set by someone else must be changed by its owner at next sign-in.
            $u['mustChangePassword'] = if ($null -ne $MustChangePassword) { [bool]$MustChangePassword } else { -not $isSelf }
        }
        elseif ($null -ne $MustChangePassword) { $u['mustChangePassword'] = [bool]$MustChangePassword }
        $u['updatedAt'] = Get-PortalTimestamp

        $store.users = $users.ToArray()
        Write-PortalJson -Path $file -Value $store
    } | Out-Null
    Write-PortalAudit -Actor $Actor -Action 'localuser.save' -Target $Username -Details @{ roles = @($Roles); teams = @($Teams); enabled = $Enabled; passwordChanged = [bool]$Password; breakGlass = $BreakGlass }
}

function Set-PortalOwnPassword {
    <# Self-service password change for local accounts (verifies the current password, applies policy and history). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Username, [Parameter(Mandatory)] [string] $CurrentPassword, [Parameter(Mandatory)] [string] $NewPassword)
    $name = ($Username -replace '^(LOCAL|\.)\\', '')
    $file = Get-PortalLocalUserFile
    $entry = @((Read-PortalJson -Path $file).users) | Where-Object { $_ -and $_.username -eq $name } | Select-Object -First 1
    if (-not $entry -or -not (Test-PortalPasswordHash -Password $CurrentPassword -Stored $entry.passwordHash)) {
        Start-Sleep -Milliseconds 800
        throw 'The current password is not correct.'
    }
    if ($CurrentPassword -ceq $NewPassword) { throw 'The new password must be different.' }
    Set-PortalLocalUserEntry -Username $name -Password $NewPassword -MustChangePassword $false -Actor "LOCAL\$name"
}

function Remove-PortalLocalUserEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Username, [Parameter(Mandatory)] [string] $Actor)
    if ($Actor -ieq "LOCAL\$Username") { throw 'You cannot delete your own account.' }
    $file = Get-PortalLocalUserFile
    Invoke-PortalLock -Name 'local-users' -ScriptBlock {
        $store = Read-PortalJson -Path $file
        $users = @(@($store.users) | Where-Object { $_ -and $_.username -ne $Username })
        if (@($store.users).Count -eq $users.Count) { throw "User '$Username' not found." }
        $store.users = $users
        Write-PortalJson -Path $file -Value $store
    } | Out-Null
    Write-PortalAudit -Actor $Actor -Action 'localuser.delete' -Target $Username
}

#endregion

function Get-PortalTeamList {
    <# Teams defined in portal.config.json (Admin > Customization > Teams). #>
    [CmdletBinding()] param()
    $cfg = Get-PortalConfig
    return @(if ($cfg.Contains('teams')) { $cfg.teams } else { @() })
}

function Test-PortalTeamAccess {
    <#
    .SYNOPSIS True when the user may see / act on something scoped to $Teams.
    .NOTES    Empty scope = everyone. Admins see every team.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $User, $Teams)
    $scope = @($Teams | Where-Object { $_ })
    if (-not $scope) { return $true }
    if (Test-PortalRole -User $User -Role 'Admin') { return $true }
    $mine = @(if ($User.Contains('teams')) { $User.teams } else { @() })
    foreach ($t in $scope) { if ($mine -contains $t) { return $true } }
    return $false
}

function Test-PortalRole {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $User,
        [Parameter(Mandatory)] [string[]] $Role
    )
    foreach ($r in $Role) { if ($User.roles -contains $r) { return $true } }
    return $false
}

Export-ModuleMember -Function Get-PortalAllowedGroups, Get-PortalUserContext, Test-PortalRole, Get-PortalTeamList, Test-PortalTeamAccess,
    New-PortalPasswordHash, Test-PortalPasswordHash, Test-PortalLocalCredential, Get-PortalLocalUserList, Set-PortalLocalUserEntry, Remove-PortalLocalUserEntry,
    Get-PortalLocalUserFile, Test-PortalLocalAccountExists, Get-PortalSecurityPolicy, Test-PortalPasswordPolicy, Set-PortalOwnPassword,
    Test-PortalPermission, Get-PortalPermissionSet, Get-PortalRoleList, Test-PortalIpInCidr
