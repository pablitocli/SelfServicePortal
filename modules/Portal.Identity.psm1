#Requires -Version 7.2
<#
.SYNOPSIS
    Portal.Identity - directory authentication: Active Directory and OpenLDAP (any RFC 4511 LDAP v3 server).
.DESCRIPTION
    Uses System.DirectoryServices.Protocols (ships with PowerShell 7; on Linux it needs the OpenLDAP client library,
    libldap). One code path for Windows and Linux.

    Provider (portal.config.json -> auth.providers[]):
      id, name, enabled, flavor (ad | openldap), domains[] (login routing: user@domain or DOMAIN\user),
      hosts[], port, security (ldaps | starttls | negotiate [Windows+AD only] | none [lab, needs allowInsecure]),
      baseDn, bindMode (direct: bind as the user | search: service account finds the user DN, then binds as the user),
      bindCredential (vault id, system scope - for bindMode=search and group lookups), upnSuffix (AD direct bind),
      usernamePrefix (portal username = PREFIX\uid), userFilter ({0} = escaped login name),
      groupMode (nested [AD, transitive] | memberOf | search), groupFilter ({dn} / {uid} placeholders), groupBaseDn,
      attributes { username, displayName, mail }, tls { verify, caFile, caDirectory }, timeoutSeconds
#>

Set-StrictMode -Version Latest

$script:LdapLoaded = $false

function Get-IV { param($T, [string] $K, $D = $null) if ($T -is [System.Collections.IDictionary] -and $T.Contains($K) -and $null -ne $T[$K] -and "$($T[$K])" -ne '') { $T[$K] } else { $D } }

$script:FlavorDefaults = @{
    ad = [ordered]@{
        port = 636; security = 'ldaps'; bindMode = 'direct'; groupMode = 'nested'
        userFilter  = '(&(objectCategory=person)(objectClass=user)(sAMAccountName={0}))'
        groupFilter = '(&(objectClass=group)(member={dn}))'
        attributes  = [ordered]@{ username = 'sAMAccountName'; displayName = 'displayName'; mail = 'mail' }
    }
    openldap = [ordered]@{
        port = 636; security = 'ldaps'; bindMode = 'search'; groupMode = 'search'
        userFilter  = '(&(objectClass=inetOrgPerson)(uid={0}))'
        groupFilter = '(|(&(objectClass=groupOfNames)(member={dn}))(&(objectClass=groupOfUniqueNames)(uniqueMember={dn}))(&(objectClass=posixGroup)(memberUid={uid})))'
        attributes  = [ordered]@{ username = 'uid'; displayName = 'cn'; mail = 'mail' }
    }
}

function Initialize-PortalLdap {
    if ($script:LdapLoaded) { return }
    try { Add-Type -AssemblyName System.DirectoryServices.Protocols -ErrorAction Stop }
    catch { throw "System.DirectoryServices.Protocols is not available: $($_.Exception.Message)" }
    $script:LdapLoaded = $true
}

function ConvertTo-PortalLdapFilterValue {
    <# RFC 4515 escaping for values placed in an LDAP filter. #>
    param([string] $Value)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($ch in $Value.ToCharArray()) {
        switch ($ch) {
            '\'      { [void]$sb.Append('\5c') }
            '*'      { [void]$sb.Append('\2a') }
            '('      { [void]$sb.Append('\28') }
            ')'      { [void]$sb.Append('\29') }
            ([char]0) { [void]$sb.Append('\00') }
            default  { [void]$sb.Append($ch) }
        }
    }
    return $sb.ToString()
}

function Get-PortalIdentityProvider {
    <# Configured LDAP providers merged with their flavor defaults. -Id returns one. #>
    [CmdletBinding()] param([string] $Id, [switch] $EnabledOnly)
    $auth = (Get-PortalConfig).auth
    foreach ($p in @(Get-IV $auth 'providers' @())) {
        if (-not $p) { continue }
        if ($Id -and $p.id -ne $Id) { continue }
        if ($EnabledOnly -and -not (Get-IV $p 'enabled' $false)) { continue }
        $flavor = [string](Get-IV $p 'flavor' 'ad')
        $d = $script:FlavorDefaults[$flavor]
        if (-not $d) { $d = $script:FlavorDefaults['openldap'] }
        $m = [ordered]@{}
        foreach ($k in $p.Keys) { $m[$k] = $p[$k] }
        foreach ($k in 'security', 'bindMode', 'groupMode', 'userFilter', 'groupFilter') { if (-not (Get-IV $m $k)) { $m[$k] = $d[$k] } }
        if (-not (Get-IV $m 'port')) { $m['port'] = if ($m.security -eq 'ldaps') { 636 } else { 389 } }
        $attrs = [ordered]@{}
        foreach ($k in $d.attributes.Keys) { $attrs[$k] = Get-IV (Get-IV $p 'attributes' @{}) $k $d.attributes[$k] }
        $m['attributes'] = $attrs
        $m['flavor'] = $flavor
        if (-not (Get-IV $m 'usernamePrefix')) {
            $m['usernamePrefix'] = if ($flavor -eq 'ad' -and @(Get-IV $m 'domains' @()).Count) {
                @(@($m.domains) | Where-Object { $_ -notmatch '\.' } | Select-Object -First 1)[0]
            } else { $null }
            if (-not $m['usernamePrefix']) { $m['usernamePrefix'] = ([string]$m.id).ToUpperInvariant() }
        }
        if (-not (Get-IV $m 'tls')) { $m['tls'] = [ordered]@{ verify = $true } }
        $m
    }
}

function Resolve-PortalLoginTarget {
    <#
    .SYNOPSIS Routes a login name to a provider.
    .OUTPUTS  @{ kind = 'local' | 'ldap'; provider; login (name sent to the directory) }
    .NOTES    DOMAIN\user and user@domain go to the provider listing that domain. A bare name is a local account
              when one exists, otherwise the default provider (auth.defaultProvider, else the first enabled one).
    #>
    [CmdletBinding()] param([Parameter(Mandatory)] [string] $Username)
    $name = $Username.Trim()
    $providers = @(Get-PortalIdentityProvider -EnabledOnly)
    $domain = $null; $login = $name
    if ($name -match '^([^\\]+)\\(.+)$') { $domain = $Matches[1]; $login = $Matches[2] }
    elseif ($name -match '^(.+)@([^@]+)$') { $domain = $Matches[2]; $login = $Matches[1] }

    if ($domain -and $domain -match '^(LOCAL|\.)$') { return [ordered]@{ kind = 'local'; provider = $null; login = $login } }
    if ($domain) {
        $p = $providers | Where-Object { @(Get-IV $_ 'domains' @()) -contains $domain -or $_.id -ieq $domain } | Select-Object -First 1
        if ($p) { return [ordered]@{ kind = 'ldap'; provider = $p; login = $login; upn = $(if ($name -match '@') { $name } else { $null }) } }
        return $null
    }
    if (Test-PortalLocalAccountExists -Username $login) { return [ordered]@{ kind = 'local'; provider = $null; login = $login } }
    $defId = [string](Get-IV (Get-PortalConfig).auth 'defaultProvider' '')
    $p = if ($defId) { $providers | Where-Object { $_.id -eq $defId } | Select-Object -First 1 } else { $null }
    if (-not $p) { $p = $providers | Select-Object -First 1 }
    if ($p) { return [ordered]@{ kind = 'ldap'; provider = $p; login = $login } }
    return [ordered]@{ kind = 'local'; provider = $null; login = $login }
}

function New-PortalLdapConnection {
    <# Opens (not yet bound) an LDAP connection with the provider transport security. #>
    param([Parameter(Mandatory)] $Provider)
    Initialize-PortalLdap
    $hosts = [string[]]@(Get-IV $Provider 'hosts' @())
    if (-not $hosts) { throw "Identity provider '$($Provider.id)' has no hosts." }
    $sec = [string]$Provider.security
    if ($sec -eq 'none' -and -not (Get-IV $Provider 'allowInsecure' $false)) {
        throw "Provider '$($Provider.id)': unencrypted LDAP is disabled. Use ldaps or starttls (or set allowInsecure for a lab)."
    }
    if ($sec -eq 'negotiate' -and -not $IsWindows) { throw "Provider '$($Provider.id)': security 'negotiate' is only available on Windows. Use ldaps or starttls on Linux." }
    $tls = Get-IV $Provider 'tls' @{}
    if (-not $IsWindows) {
        # libldap reads these once per process: one CA bundle and one verification policy for all providers.
        if ((Get-IV $tls 'caFile') -and -not $env:LDAPTLS_CACERT) { $env:LDAPTLS_CACERT = [string]$tls.caFile }
        if (-not (Get-IV $tls 'verify' $true) -and -not $env:LDAPTLS_REQCERT) { $env:LDAPTLS_REQCERT = 'never' }
    }
    $id = [System.DirectoryServices.Protocols.LdapDirectoryIdentifier]::new($hosts, [int]$Provider.port, $false, $false)
    $conn = [System.DirectoryServices.Protocols.LdapConnection]::new($id)
    $conn.Timeout = [timespan]::FromSeconds([int](Get-IV $Provider 'timeoutSeconds' 10))
    $conn.SessionOptions.ProtocolVersion = 3
    $conn.SessionOptions.ReferralChasing = [System.DirectoryServices.Protocols.ReferralChasingOptions]::None
    if ($IsWindows -and -not (Get-IV $tls 'verify' $true)) {
        $conn.SessionOptions.VerifyServerCertificate = { param($c, $cert) $true }
    }
    if (-not $IsWindows -and (Get-IV $tls 'caDirectory')) {
        $conn.SessionOptions.TrustedCertificatesDirectory = [string]$tls.caDirectory
        $conn.SessionOptions.StartNewTlsSessionContext()
    }
    switch ($sec) {
        'ldaps'    { $conn.SessionOptions.SecureSocketLayer = $true }
        'starttls' {
            if (-not $IsWindows) {
                # .NET on Linux connects lazily: StartTLS needs an open connection, so read the rootDSE first (anonymous, no data).
                $conn.AutoBind = $false
                $null = $conn.SendRequest([System.DirectoryServices.Protocols.SearchRequest]::new('', '(objectClass=*)', [System.DirectoryServices.Protocols.SearchScope]::Base, @('supportedExtension')))
            }
            $conn.SessionOptions.StartTransportLayerSecurity($null)
        }
        'negotiate' { $conn.SessionOptions.Signing = $true; $conn.SessionOptions.Sealing = $true }
    }
    $conn.AuthType = if ($sec -eq 'negotiate') { [System.DirectoryServices.Protocols.AuthType]::Negotiate } else { [System.DirectoryServices.Protocols.AuthType]::Basic }
    return $conn
}

function Invoke-PortalLdapBind {
    param($Connection, $Provider, [string] $User, [string] $Password)
    if ([string]::IsNullOrEmpty($Password)) { throw [System.UnauthorizedAccessException]::new('Empty password.') }   # never allow unauthenticated binds
    $nc = if ($Provider.security -eq 'negotiate' -and $User -notmatch '[@=\\]') {
        [System.Net.NetworkCredential]::new($User, $Password, [string]$Provider.usernamePrefix)
    } else { [System.Net.NetworkCredential]::new($User, $Password) }
    $Connection.Bind($nc)
}

function Get-PortalLdapEntry {
    param($Connection, [string] $BaseDn, [string] $Filter, [string[]] $Attributes, [int] $SizeLimit = 2, [string] $Scope = 'Subtree')
    $req = [System.DirectoryServices.Protocols.SearchRequest]::new($BaseDn, $Filter, [System.DirectoryServices.Protocols.SearchScope]::$Scope, $Attributes)
    $req.SizeLimit = $SizeLimit
    $resp = [System.DirectoryServices.Protocols.SearchResponse]$Connection.SendRequest($req)
    foreach ($e in $resp.Entries) { $e }
}

function Get-PortalLdapValue {
    param($Entry, [string] $Name)
    if (-not $Name -or -not $Entry.Attributes.Contains($Name)) { return @() }
    return @($Entry.Attributes[$Name].GetValues([string]))
}

function Get-PortalCnFromDn { param([string] $Dn) if ($Dn -match '^(?i:cn)=((?:\\.|[^,])+)') { return ($Matches[1] -replace '\\(.)', '$1') } return $Dn }

function Get-PortalLdapErrorMessage {
    param($Exception)
    $ex = $Exception
    while ($ex -and $ex -isnot [System.DirectoryServices.Protocols.LdapException] -and $ex.InnerException) { $ex = $ex.InnerException }
    if ($ex -is [System.DirectoryServices.Protocols.LdapException]) {
        $srv = [string]$ex.ServerErrorMessage
        switch -Regex ($srv) {
            'data 775' { return @{ code = 'locked';   message = 'The directory account is locked.' } }
            'data 532' { return @{ code = 'expired';  message = 'The directory password has expired. Change it in your directory first.' } }
            'data 773' { return @{ code = 'mustchange'; message = 'The directory requires a password change before first use.' } }
            'data 533' { return @{ code = 'disabled'; message = 'The directory account is disabled.' } }
            'data 701' { return @{ code = 'expired';  message = 'The directory account has expired.' } }
        }
        if ($ex.ErrorCode -eq 49) { return @{ code = 'invalid'; message = 'Invalid username or password.' } }
        if ($ex.ErrorCode -eq 81 -or $ex.ErrorCode -eq 91) { return @{ code = 'unavailable'; message = "Directory server not reachable ($($ex.Message))." } }
        return @{ code = 'error'; message = "LDAP error $($ex.ErrorCode): $($ex.Message) $srv".Trim() }
    }
    if ($Exception -is [System.UnauthorizedAccessException]) { return @{ code = 'invalid'; message = 'Invalid username or password.' } }
    $m = [string]$Exception.Message
    if ($m -match 'libldap|Unable to load shared library') { return @{ code = 'unavailable'; message = 'The OpenLDAP client library (libldap) is not installed on the portal server.' } }
    return @{ code = 'error'; message = $m }
}

function Get-PortalLdapServiceConnection {
    <# Connection bound with the provider service account (vault entry, system scope). #>
    param($Provider)
    $ref = [string](Get-IV $Provider 'bindCredential' '')
    if (-not $ref) { throw "Provider '$($Provider.id)' needs a bind credential (vault entry) for bindMode=search." }
    $cred = Get-PortalVaultCredential -Id $ref -Purpose identity -Actor "identity:$($Provider.id)"
    $conn = New-PortalLdapConnection -Provider $Provider
    Invoke-PortalLdapBind -Connection $conn -Provider $Provider -User $cred.UserName -Password $cred.GetNetworkCredential().Password
    return $conn
}

function Find-PortalLdapUser {
    param($Connection, $Provider, [string] $Login)
    $a = $Provider.attributes
    $filter = ([string]$Provider.userFilter).Replace('{0}', (ConvertTo-PortalLdapFilterValue $Login))
    $attrs = @($a.username, $a.displayName, $a.mail, 'memberOf', 'distinguishedName') | Where-Object { $_ } | Select-Object -Unique
    $found = @(Get-PortalLdapEntry -Connection $Connection -BaseDn ([string]$Provider.baseDn) -Filter $filter -Attributes $attrs)
    if ($found.Count -gt 1) { throw "More than one directory entry matches '$Login' - make userFilter more specific." }
    return ($found | Select-Object -First 1)
}

function Get-PortalLdapGroups {
    param($Connection, $Provider, $Entry, [string] $Uid)
    $dn = $Entry.DistinguishedName
    $groupBase = [string](Get-IV $Provider 'groupBaseDn' $Provider.baseDn)
    switch ([string]$Provider.groupMode) {
        'memberOf' { return @(Get-PortalLdapValue $Entry 'memberOf' | ForEach-Object { Get-PortalCnFromDn $_ }) }
        'nested' {
            # AD transitive membership (LDAP_MATCHING_RULE_IN_CHAIN).
            $f = '(&(objectClass=group)(member:1.2.840.113556.1.4.1941:={0}))' -f (ConvertTo-PortalLdapFilterValue $dn)
            return @(Get-PortalLdapEntry -Connection $Connection -BaseDn $groupBase -Filter $f -Attributes @('cn') -SizeLimit 1000 |
                     ForEach-Object { @(Get-PortalLdapValue $_ 'cn')[0] })
        }
        default {
            $f = ([string]$Provider.groupFilter).Replace('{dn}', (ConvertTo-PortalLdapFilterValue $dn)).Replace('{uid}', (ConvertTo-PortalLdapFilterValue $Uid))
            return @(Get-PortalLdapEntry -Connection $Connection -BaseDn $groupBase -Filter $f -Attributes @('cn') -SizeLimit 1000 |
                     ForEach-Object { @(Get-PortalLdapValue $_ 'cn')[0] })
        }
    }
}

function Invoke-PortalLdapAuthentication {
    <#
    .SYNOPSIS Authenticates a user against an LDAP provider and returns the portal identity with its groups.
    .OUTPUTS  @{ ok; code; message; user = @{ Username; Name; Email; Domain; Groups; Provider; Dn } }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Provider, [Parameter(Mandatory)] [string] $Login, [string] $Password, [string] $Upn)
    if ([string]::IsNullOrEmpty($Password)) { return [ordered]@{ ok = $false; code = 'invalid'; message = 'Invalid username or password.' } }
    $conn = $null; $svc = $null
    try {
        if ($Provider.bindMode -eq 'direct') {
            $bindName = if ($Upn) { $Upn } elseif ($Provider.security -eq 'negotiate') { $Login }
                        elseif (Get-IV $Provider 'upnSuffix') { "$Login@$($Provider.upnSuffix)" }
                        else { throw "Provider '$($Provider.id)': bindMode=direct needs upnSuffix (or use bindMode=search)." }
            $conn = New-PortalLdapConnection -Provider $Provider
            Invoke-PortalLdapBind -Connection $conn -Provider $Provider -User $bindName -Password $Password
            $entry = Find-PortalLdapUser -Connection $conn -Provider $Provider -Login $Login
            if (-not $entry) { return [ordered]@{ ok = $false; code = 'invalid'; message = 'Invalid username or password.' } }
            $lookup = $conn
        }
        else {
            $svc = Get-PortalLdapServiceConnection -Provider $Provider
            $entry = Find-PortalLdapUser -Connection $svc -Provider $Provider -Login $Login
            if (-not $entry) { Start-Sleep -Milliseconds 300; return [ordered]@{ ok = $false; code = 'invalid'; message = 'Invalid username or password.' } }
            $conn = New-PortalLdapConnection -Provider $Provider
            Invoke-PortalLdapBind -Connection $conn -Provider $Provider -User $entry.DistinguishedName -Password $Password   # proves the password
            $lookup = $svc
        }
        $a = $Provider.attributes
        $uid = @(Get-PortalLdapValue $entry $a.username)[0]
        if (-not $uid) { $uid = $Login }
        $groups = @(Get-PortalLdapGroups -Connection $lookup -Provider $Provider -Entry $entry -Uid $uid | Where-Object { $_ } | Sort-Object -Unique)
        return [ordered]@{
            ok = $true; code = 'ok'; message = $null
            user = [ordered]@{
                Username = [string]$uid
                Name     = [string]$(if (@(Get-PortalLdapValue $entry $a.displayName)[0]) { @(Get-PortalLdapValue $entry $a.displayName)[0] } else { $uid })
                Email    = [string]@(Get-PortalLdapValue $entry $a.mail)[0]
                Domain   = [string]$Provider.usernamePrefix
                Groups   = $groups
                Provider = [string]$Provider.id
                Dn       = [string]$entry.DistinguishedName
            }
        }
    }
    catch {
        $e = Get-PortalLdapErrorMessage -Exception $_.Exception
        if ($e.code -notin 'invalid', 'locked', 'expired', 'mustchange', 'disabled') {
            try { Write-PortalLog -Level WARN -Message "LDAP provider $($Provider.id): $($e.message)" } catch { }
        }
        return [ordered]@{ ok = $false; code = $e.code; message = $e.message }
    }
    finally {
        foreach ($c in $conn, $svc) { if ($c) { try { $c.Dispose() } catch { } } }
    }
}

function Test-PortalIdentityProvider {
    <#
    .SYNOPSIS Admin "Test connection": TLS/bind with the service account (or anonymous rootDSE read for direct-bind
              providers) and, optionally, a user lookup without password (service account required).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Id, [string] $LookupUser)
    $p = Get-PortalIdentityProvider -Id $Id
    if (-not $p) { throw "Identity provider '$Id' not found." }
    $steps = [System.Collections.Generic.List[object]]::new()
    $conn = $null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if (Get-IV $p 'bindCredential') {
            $conn = Get-PortalLdapServiceConnection -Provider $p
            $steps.Add([ordered]@{ step = "Connected to $(@($p.hosts) -join ', '):$($p.port) ($($p.security)) and bound with the service account"; ok = $true })
            $base = @(Get-PortalLdapEntry -Connection $conn -BaseDn ([string]$p.baseDn) -Filter '(objectClass=*)' -Attributes @('objectClass') -SizeLimit 1 -Scope Base)
            $steps.Add([ordered]@{ step = "Base DN $($p.baseDn) readable"; ok = [bool]$base.Count })
            if ($LookupUser) {
                $e = Find-PortalLdapUser -Connection $conn -Provider $p -Login $LookupUser
                if ($e) {
                    $g = @(Get-PortalLdapGroups -Connection $conn -Provider $p -Entry $e -Uid $LookupUser)
                    $steps.Add([ordered]@{ step = "User '$LookupUser' found: $($e.DistinguishedName)"; ok = $true; groups = @($g | Sort-Object -Unique) })
                }
                else { $steps.Add([ordered]@{ step = "User '$LookupUser' not found with filter $($p.userFilter)"; ok = $false }) }
            }
        }
        else {
            $conn = New-PortalLdapConnection -Provider $p
            $conn.AuthType = [System.DirectoryServices.Protocols.AuthType]::Anonymous
            $conn.Bind()
            $root = @(Get-PortalLdapEntry -Connection $conn -BaseDn '' -Filter '(objectClass=*)' -Attributes @('namingContexts', 'defaultNamingContext') -SizeLimit 1 -Scope Base)
            $steps.Add([ordered]@{ step = "Connected to $(@($p.hosts) -join ', '):$($p.port) ($($p.security)); rootDSE readable (no service account configured - user lookups are done with the user's own credentials at sign-in)"; ok = [bool]$root.Count })
        }
        return [ordered]@{ ok = -not ($steps | Where-Object { -not $_.ok }); elapsedMs = $sw.ElapsedMilliseconds; steps = $steps.ToArray() }
    }
    catch {
        $e = Get-PortalLdapErrorMessage -Exception $_.Exception
        $steps.Add([ordered]@{ step = $e.message; ok = $false })
        return [ordered]@{ ok = $false; elapsedMs = $sw.ElapsedMilliseconds; steps = $steps.ToArray() }
    }
    finally { if ($conn) { try { $conn.Dispose() } catch { } } }
}

function Set-PortalIdentityProvider {
    <# Creates / updates / validates an LDAP provider definition. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Provider, [switch] $New, [Parameter(Mandatory)] [string] $Actor)
    $p = $Provider
    if ([string](Get-IV $p 'id' '') -notmatch '^[a-z][a-z0-9-]{1,31}$') { throw 'Provider id must be 2-32 lowercase letters, digits or hyphen (start with a letter).' }
    if (@('ad', 'openldap') -notcontains (Get-IV $p 'flavor' '')) { throw 'flavor must be ad or openldap.' }
    if (-not @(Get-IV $p 'hosts' @() | Where-Object { $_ })) { throw 'At least one host is required.' }
    foreach ($h in @($p.hosts)) { if ([string]$h -notmatch '^[A-Za-z0-9.-]{1,253}$') { throw "Invalid host '$h'." } }
    if (@('ldaps', 'starttls', 'negotiate', 'none') -notcontains (Get-IV $p 'security' 'ldaps')) { throw 'security must be ldaps, starttls, negotiate or none.' }
    if ((Get-IV $p 'security') -eq 'none' -and -not (Get-IV $p 'allowInsecure' $false)) { throw 'Unencrypted LDAP requires allowInsecure (lab only).' }
    $port = [int](Get-IV $p 'port' 636); if ($port -lt 1 -or $port -gt 65535) { throw 'Invalid port.' }
    if (-not (Get-IV $p 'baseDn')) { throw 'baseDn is required (e.g. DC=corp,DC=example,DC=com).' }
    if (@('direct', 'search') -notcontains (Get-IV $p 'bindMode' 'direct')) { throw 'bindMode must be direct or search.' }
    if ((Get-IV $p 'bindMode') -eq 'search' -and -not (Get-IV $p 'bindCredential')) { throw 'bindMode=search requires a bind credential (vault entry).' }
    if ((Get-IV $p 'bindCredential') -and -not (Get-PortalVaultEntry -Id ([string]$p.bindCredential))) { throw "Vault entry '$($p.bindCredential)' not found." }
    if (@('nested', 'memberOf', 'search', $null, '') -notcontains (Get-IV $p 'groupMode')) { throw 'groupMode must be nested, memberOf or search.' }
    foreach ($k in 'userFilter', 'groupFilter') {
        $f = [string](Get-IV $p $k '')
        if ($f -and -not ($f.StartsWith('(') -and $f.EndsWith(')'))) { throw "$k must be an LDAP filter in parentheses." }
    }
    if ((Get-IV $p 'userFilter') -and ([string]$p.userFilter) -notmatch '\{0\}') { throw 'userFilter must contain {0} (the login name).' }
    foreach ($v in @($p.Values)) { if ($v -is [string] -and $v -match '[<>]') { throw 'Values cannot contain < or >.' } }
    $clean = [ordered]@{}
    foreach ($k in 'id', 'name', 'enabled', 'flavor', 'domains', 'hosts', 'port', 'security', 'allowInsecure', 'baseDn', 'bindMode', 'bindCredential', 'upnSuffix',
                   'usernamePrefix', 'userFilter', 'groupMode', 'groupFilter', 'groupBaseDn', 'attributes', 'tls', 'timeoutSeconds') {
        if ($p.Contains($k)) { $clean[$k] = $p[$k] }
    }
    $clean['port'] = $port
    $clean['enabled'] = [bool](Get-IV $p 'enabled' $false)
    $clean['domains'] = @(@(Get-IV $p 'domains' @()) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    $clean['hosts'] = @(@($p.hosts) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    Update-PortalConfig -Mutate {
        param($cfg)
        if (-not $cfg.auth.Contains('providers')) { $cfg.auth['providers'] = @() }
        $list = [System.Collections.Generic.List[object]]::new()
        @($cfg.auth.providers) | Where-Object { $_ } | ForEach-Object { $list.Add($_) }
        $existing = $list | Where-Object { $_.id -eq $clean.id } | Select-Object -First 1
        if ($New -and $existing) { throw "Provider '$($clean.id)' already exists." }
        if ($existing) { $list[$list.IndexOf($existing)] = $clean } else { $list.Add($clean) }
        $cfg.auth.providers = $list.ToArray()
        if (-not (Get-IV $cfg.auth 'defaultProvider')) { $cfg.auth['defaultProvider'] = $clean.id }
    }
    Write-PortalAudit -Actor $Actor -Action 'identity.provider.save' -Target $clean.id -Details @{ enabled = $clean.enabled; hosts = $clean.hosts; security = $clean['security'] }
}

function Remove-PortalIdentityProvider {
    [CmdletBinding()] param([Parameter(Mandatory)] [string] $Id, [Parameter(Mandatory)] [string] $Actor)
    Update-PortalConfig -Mutate {
        param($cfg)
        $keep = @(@(Get-IV $cfg.auth 'providers' @()) | Where-Object { $_ -and $_.id -ne $Id })
        $cfg.auth['providers'] = $keep
        if ((Get-IV $cfg.auth 'defaultProvider') -eq $Id) { $cfg.auth['defaultProvider'] = $(if ($keep) { $keep[0].id } else { '' }) }
    }
    Write-PortalAudit -Actor $Actor -Action 'identity.provider.delete' -Target $Id
}

Export-ModuleMember -Function Get-PortalIdentityProvider, Resolve-PortalLoginTarget, Invoke-PortalLdapAuthentication, Test-PortalIdentityProvider,
    Set-PortalIdentityProvider, Remove-PortalIdentityProvider, ConvertTo-PortalLdapFilterValue
