#Requires -Version 7.2
<#
.SYNOPSIS
    Portal.Vault - credential vault for the automation (vCenter, guests, LDAP bind accounts, clouds, APIs, arrays...).
.DESCRIPTION
    * Secrets are encrypted with AES-256-GCM (random 96-bit nonce, 128-bit tag, entry id + version as associated data).
    * The 256-bit master key comes from a key provider (vault.keyProvider):
        auto    - SSP_VAULT_KEYFILE if set, else SSP_VAULT_KEY if set, else DPAPI on Windows, else data/vault/master.key
        keyfile - base64 key in a file (Linux / appliance: /etc/ssp/vault.key, 0400, owned by the service account)
        dpapi   - key protected with Windows DPAPI for the service account (data/vault/master.key.dpapi)
        env     - base64 key in the SSP_VAULT_KEY environment variable (containers)
    * Secrets are WRITE-ONLY through the portal: the UI/API can create or replace them, never read them.
      Only job runners (and the identity / connection tests) decrypt them, in memory, and every use is audited.
    * Each entry has a scope (teams, catalog items, or "system" for platform connections) that the runner enforces.
#>

Set-StrictMode -Version Latest

$script:VaultKey   = $null
$script:KeyCheck   = 'ssp-vault-key-check-v1'
$script:EntryTypes = @('UsernamePassword', 'SshKey', 'ApiToken', 'Certificate', 'ServicePrincipal')

function Get-VV { param($T, [string] $K, $D = $null) if ($T -is [System.Collections.IDictionary] -and $T.Contains($K) -and $null -ne $T[$K]) { $T[$K] } else { $D } }

function Get-PortalVaultPath {
    $dir = Join-Path (Get-PortalRoot) 'data/vault'
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    return (Join-Path $dir 'vault.json')
}

function Set-PortalFileOwnerOnly {
    <# chmod 600 on Linux/macOS (ACLs on Windows are inherited from the portal folder, which is restricted at install). #>
    param([string] $Path)
    if (-not $IsWindows) {
        try { [System.IO.File]::SetUnixFileMode($Path, [System.IO.UnixFileMode]'UserRead, UserWrite') } catch { }
    }
}

function Get-PortalVaultKeyInfo {
    <# Which key provider is in use and where the key lives (no key material). #>
    [CmdletBinding()] param()
    $cfg = Get-PortalConfig
    $provider = [string](Get-VV (Get-VV $cfg 'vault' @{}) 'keyProvider' 'auto')
    if ($provider -eq 'auto') {
        $provider = if ($env:SSP_VAULT_KEYFILE) { 'keyfile' } elseif ($env:SSP_VAULT_KEY) { 'env' } elseif ($IsWindows) { 'dpapi' } else { 'keyfile' }
    }
    $location = switch ($provider) {
        'keyfile' { if ($env:SSP_VAULT_KEYFILE) { $env:SSP_VAULT_KEYFILE } else { [string](Get-VV (Get-VV $cfg 'vault' @{}) 'keyFile' (Join-Path (Get-PortalRoot) 'data/vault/master.key')) } }
        'dpapi'   { Join-Path (Get-PortalRoot) 'data/vault/master.key.dpapi' }
        'env'     { 'SSP_VAULT_KEY' }
        default   { throw "Unknown vault.keyProvider '$provider' (auto, keyfile, dpapi, env)." }
    }
    if ($provider -eq 'keyfile' -and -not [System.IO.Path]::IsPathRooted($location)) { $location = Join-Path (Get-PortalRoot) $location }
    return [ordered]@{ provider = $provider; location = $location }
}

function Get-PortalVaultKey {
    <# Returns the 32-byte master key, creating it on first use (except for the env provider). #>
    if ($script:VaultKey) { return $script:VaultKey }
    $info = Get-PortalVaultKeyInfo
    $key = $null
    switch ($info.provider) {
        'env' {
            if (-not $env:SSP_VAULT_KEY) { throw 'Vault key provider "env" selected but SSP_VAULT_KEY is not set.' }
            $key = [Convert]::FromBase64String($env:SSP_VAULT_KEY.Trim())
        }
        'keyfile' {
            if (Test-Path -LiteralPath $info.location) {
                $key = [Convert]::FromBase64String((Get-Content -LiteralPath $info.location -Raw).Trim())
            }
            else {
                $key = [byte[]]::new(32); [System.Security.Cryptography.RandomNumberGenerator]::Fill($key)
                $null = New-Item -ItemType Directory -Path (Split-Path -Parent $info.location) -Force
                [System.IO.File]::WriteAllText($info.location, [Convert]::ToBase64String($key))
                Set-PortalFileOwnerOnly -Path $info.location
                try { Write-PortalLog -Level WARN -Message "Vault master key created at $($info.location). Back it up separately: without it stored credentials cannot be recovered." } catch { }
            }
        }
        'dpapi' {
            if (-not $IsWindows) { throw 'The DPAPI vault key provider is only available on Windows. Use keyfile (SSP_VAULT_KEYFILE) on Linux.' }
            if (Test-Path -LiteralPath $info.location) {
                $ss = ConvertTo-SecureString -String (Get-Content -LiteralPath $info.location -Raw).Trim()
                $key = [Convert]::FromBase64String([System.Net.NetworkCredential]::new('', $ss).Password)
            }
            else {
                $key = [byte[]]::new(32); [System.Security.Cryptography.RandomNumberGenerator]::Fill($key)
                $protected = ConvertTo-SecureString -String ([Convert]::ToBase64String($key)) -AsPlainText -Force | ConvertFrom-SecureString
                Set-Content -LiteralPath $info.location -Value $protected -Encoding ascii
            }
        }
    }
    if ($key.Length -ne 32) { throw "Vault master key at $($info.location) is not a 256-bit key." }
    $script:VaultKey = $key
    return $key
}

function Protect-PortalVaultData {
    param([Parameter(Mandatory)] [string] $PlainText, [Parameter(Mandatory)] [string] $Aad)
    $key = Get-PortalVaultKey
    $nonce = [byte[]]::new(12); [System.Security.Cryptography.RandomNumberGenerator]::Fill($nonce)
    $plain = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
    $cipher = [byte[]]::new($plain.Length); $tag = [byte[]]::new(16)
    $gcm = [System.Security.Cryptography.AesGcm]::new($key, 16)
    try { $gcm.Encrypt($nonce, $plain, $cipher, $tag, [System.Text.Encoding]::UTF8.GetBytes($Aad)) } finally { $gcm.Dispose() }
    [Array]::Clear($plain, 0, $plain.Length)
    return [Convert]::ToBase64String($nonce + $tag + $cipher)
}

function Unprotect-PortalVaultData {
    param([Parameter(Mandatory)] [string] $Data, [Parameter(Mandatory)] [string] $Aad)
    $key = Get-PortalVaultKey
    $raw = [Convert]::FromBase64String($Data)
    if ($raw.Length -lt 28) { throw 'Corrupt vault record.' }
    $nonce = $raw[0..11]; $tag = $raw[12..27]
    $cipher = if ($raw.Length -gt 28) { [byte[]]$raw[28..($raw.Length - 1)] } else { [byte[]]::new(0) }
    $plain = [byte[]]::new($cipher.Length)
    $gcm = [System.Security.Cryptography.AesGcm]::new($key, 16)
    try { $gcm.Decrypt([byte[]]$nonce, $cipher, [byte[]]$tag, $plain, [System.Text.Encoding]::UTF8.GetBytes($Aad)) }
    catch { throw 'Vault record cannot be decrypted: the master key does not match or the record was altered.' }
    finally { $gcm.Dispose() }
    return [System.Text.Encoding]::UTF8.GetString($plain)
}

function Read-PortalVaultStore {
    $path = Get-PortalVaultPath
    $store = if (Test-Path -LiteralPath $path) { Read-PortalJson -Path $path } else { $null }
    if (-not $store) { $store = [ordered]@{ format = 1; keyCheck = ''; entries = @() } }
    if (-not $store.keyCheck) {
        $store.keyCheck = Protect-PortalVaultData -PlainText $script:KeyCheck -Aad 'keycheck'
    }
    else {
        try { $null = Unprotect-PortalVaultData -Data $store.keyCheck -Aad 'keycheck' }
        catch {
            $i = Get-PortalVaultKeyInfo
            throw "The vault master key ($($i.provider): $($i.location)) does not match data/vault/vault.json. Restore the original key file; a new key cannot open existing credentials."
        }
    }
    return $store
}

function Save-PortalVaultStore {
    param($Store)
    $path = Get-PortalVaultPath
    Write-PortalJson -Path $path -Value $Store
    Set-PortalFileOwnerOnly -Path $path
}

function ConvertTo-PortalVaultView {
    param($Entry)
    $exp = Get-VV $Entry 'expiresAt'
    $state = 'ok'
    if ($exp) {
        $days = ([datetime]$exp - (Get-Date)).TotalDays
        if ($days -lt 0) { $state = 'expired' } elseif ($days -lt 30) { $state = 'expiring' }
    }
    $view = [ordered]@{}
    foreach ($k in 'id', 'name', 'type', 'description', 'username', 'target', 'fields', 'scope', 'tags', 'expiresAt',
                   'createdAt', 'createdBy', 'updatedAt', 'updatedBy', 'lastUsedAt', 'lastUsedBy', 'useCount') {
        $view[$k] = Get-VV $Entry $k $(if ($k -in 'fields', 'scope') { [ordered]@{} } elseif ($k -eq 'tags') { @() } else { $null })
    }
    $view['version']       = [int](Get-VV (Get-VV $Entry 'secret' @{}) 'v' 0)
    $view['hasPassphrase'] = [bool](Get-VV $Entry 'hasPassphrase' $false)
    $view['versions']      = @(Get-VV $Entry 'versions' @()).Count
    $view['state']         = $state
    return $view
}

function Get-PortalVaultEntry {
    <# Vault entries without secret material. -Id returns one entry or $null. #>
    [CmdletBinding()] param([string] $Id)
    $store = Invoke-PortalLock -Name 'vault' -ScriptBlock { Read-PortalVaultStore }
    $entries = @(@($store.entries) | Where-Object { $_ })
    if ($Id) { $e = $entries | Where-Object { $_.id -eq $Id } | Select-Object -First 1; if ($e) { return (ConvertTo-PortalVaultView $e) } else { return $null } }
    foreach ($e in $entries | Sort-Object { $_.name }) { ConvertTo-PortalVaultView $e }
}

function Set-PortalVaultEntry {
    <#
    .SYNOPSIS Creates or updates a vault entry. -Secret replaces the secret (previous versions kept, vault.maxVersions).
    .PARAMETER Scope  @{ system = $bool; teams = @(); items = @('item-id' | '*') }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Id,
        [string] $Name,
        [string] $Type,
        [string] $Description,
        [string] $Username,
        [string] $Target,
        [string] $Secret,
        [string] $Passphrase,
        [System.Collections.IDictionary] $Fields,
        [System.Collections.IDictionary] $Scope,
        [string[]] $Tags,
        [string] $ExpiresAt,
        [switch] $New,
        [Parameter(Mandatory)] [string] $Actor
    )
    if ($Id -notmatch '^[a-z0-9][a-z0-9._-]{1,62}$') { throw 'Vault id must be 2-63 lowercase letters, digits, dot, underscore or hyphen.' }
    if ($Type -and $script:EntryTypes -notcontains $Type) { throw "Type must be one of: $($script:EntryTypes -join ', ')." }
    if ($ExpiresAt) { try { $null = [datetime]::Parse($ExpiresAt, [Globalization.CultureInfo]::InvariantCulture) } catch { throw 'ExpiresAt must be a date (YYYY-MM-DD).' } }
    foreach ($v in $Name, $Description, $Username, $Target) { if ([string]$v -match '[<>]') { throw 'Text fields cannot contain < or >.' } }
    $knownTeams = @(Get-PortalTeamList | ForEach-Object { $_.id })
    if ($Scope) { foreach ($t in @(Get-VV $Scope 'teams' @())) { if ($t -and $knownTeams -notcontains $t) { throw "Unknown team '$t'." } } }
    $bound = @{} + $PSBoundParameters
    $max = [int](Get-VV (Get-VV (Get-PortalConfig) 'vault' @{}) 'maxVersions' 5)

    Invoke-PortalLock -Name 'vault' -ScriptBlock {
        $store = Read-PortalVaultStore
        $list = [System.Collections.Generic.List[object]]::new()
        @($store.entries) | Where-Object { $_ } | ForEach-Object { $list.Add($_) }
        $e = $list | Where-Object { $_.id -eq $Id } | Select-Object -First 1
        if ($New -and $e) { throw "Vault entry '$Id' already exists." }
        if (-not $e) {
            if (-not $Type) { throw 'A type is required for a new vault entry.' }
            if (-not $Secret) { throw 'A secret is required for a new vault entry.' }
            $e = [ordered]@{ id = $Id; name = $(if ($Name) { $Name } else { $Id }); type = $Type; description = ''; username = ''; target = ''
                             fields = [ordered]@{}; scope = [ordered]@{ system = $false; teams = @(); items = @() }; tags = @(); expiresAt = $null
                             secret = $null; versions = @(); hasPassphrase = $false
                             createdAt = (Get-PortalTimestamp); createdBy = $Actor; lastUsedAt = $null; lastUsedBy = $null; useCount = 0 }
            $list.Add($e)
        }
        if ($bound.ContainsKey('Name') -and $Name)  { $e.name = $Name }
        if ($bound.ContainsKey('Type') -and $Type)  { $e.type = $Type }
        foreach ($k in 'Description', 'Username', 'Target') { if ($bound.ContainsKey($k)) { $e[$k.ToLower()] = [string]$bound[$k] } }
        if ($bound.ContainsKey('Fields'))    { $e.fields = $Fields }
        if ($bound.ContainsKey('Tags'))      { $e.tags = @($Tags | Where-Object { $_ }) }
        if ($bound.ContainsKey('ExpiresAt')) { $e.expiresAt = $(if ($ExpiresAt) { $ExpiresAt } else { $null }) }
        if ($bound.ContainsKey('Scope')) {
            $e.scope = [ordered]@{ system = [bool](Get-VV $Scope 'system' $false); teams = @(Get-VV $Scope 'teams' @() | Where-Object { $_ }); items = @(Get-VV $Scope 'items' @() | Where-Object { $_ }) }
        }
        if ($Secret) {
            $v = [int](Get-VV (Get-VV $e 'secret' @{}) 'v' 0) + 1
            if ($e.secret) {
                $hist = @(@($e.versions) + [ordered]@{ v = $e.secret.v; data = $e.secret.data; retiredAt = (Get-PortalTimestamp); retiredBy = $Actor })
                $e.versions = @($hist | Select-Object -Last $max)
            }
            $payload = [ordered]@{ secret = $Secret; passphrase = [string]$Passphrase } | ConvertTo-Json -Compress
            $e.secret = [ordered]@{ v = $v; data = (Protect-PortalVaultData -PlainText $payload -Aad "$Id|$v"); createdAt = (Get-PortalTimestamp) }
            $e.hasPassphrase = [bool]$Passphrase
        }
        $e['updatedAt'] = Get-PortalTimestamp; $e['updatedBy'] = $Actor
        $store.entries = $list.ToArray()
        Save-PortalVaultStore -Store $store
    } | Out-Null
    Write-PortalAudit -Actor $Actor -Action 'vault.save' -Target $Id -Details @{ type = $Type; secretChanged = [bool]$Secret; new = [bool]$New }
}

function Get-PortalVaultReference {
    <# Where a vault entry is referenced: sites, clouds, identity providers, catalog items. #>
    [CmdletBinding()] param([Parameter(Mandatory)] [string] $Id)
    $cfg = Get-PortalConfig
    foreach ($s in @(Get-VV $cfg 'sites' @())) {
        $c = Get-VV $s 'credential' @{}
        if ((Get-VV $c 'type') -eq 'Vault' -and (Get-VV $c 'id') -eq $Id) { "site:$($s.code)" }
    }
    foreach ($p in 'aws', 'azure') {
        if ((Get-VV (Get-VV (Get-VV $cfg 'clouds' @{}) $p @{}) 'credentialRef') -eq $Id) { "cloud:$p" }
    }
    foreach ($p in @(Get-VV (Get-VV $cfg 'auth' @{}) 'providers' @())) {
        if ((Get-VV $p 'bindCredential') -eq $Id) { "identity:$($p.id)" }
    }
    $dir = Get-PortalPath -Name CatalogItems
    if (Test-Path -LiteralPath $dir) {
        foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.json' -File) {
            try { $i = Read-PortalJson -Path $f.FullName } catch { continue }
            $creds = Get-VV (Get-VV $i 'execution' @{}) 'credentials' @{}
            if ($creds -is [System.Collections.IDictionary] -and @($creds.Values) -contains $Id) { "item:$($i.id)" }
        }
    }
}

function Remove-PortalVaultEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Id, [Parameter(Mandatory)] [string] $Actor)
    $refs = @(Get-PortalVaultReference -Id $Id)
    if ($refs) { throw "Vault entry '$Id' is still used by: $($refs -join ', ')." }
    Invoke-PortalLock -Name 'vault' -ScriptBlock {
        $store = Read-PortalVaultStore
        $keep = @(@($store.entries) | Where-Object { $_ -and $_.id -ne $Id })
        if ($keep.Count -eq @($store.entries).Count) { throw "Vault entry '$Id' not found." }
        $store.entries = $keep
        Save-PortalVaultStore -Store $store
    } | Out-Null
    Write-PortalAudit -Actor $Actor -Action 'vault.delete' -Target $Id
}

function Test-PortalVaultScope {
    <# True when an entry may be used for the purpose. System purposes (site/cloud/identity) need scope.system. #>
    param($Entry, [string] $Purpose, [string] $ItemId, [string[]] $Teams)
    $scope = Get-VV $Entry 'scope' @{}
    if ($Purpose -in 'site', 'cloud', 'identity', 'system') { return [bool](Get-VV $scope 'system' $false) }
    $items = @(Get-VV $scope 'items' @())
    if (-not ($items -contains '*' -or ($ItemId -and $items -contains $ItemId))) { return $false }
    $teams = @(Get-VV $scope 'teams' @() | Where-Object { $_ })
    if ($teams -and -not (@($Teams) | Where-Object { $teams -contains $_ })) { return $false }
    return $true
}

function Get-PortalVaultSecret {
    <#
    .SYNOPSIS Decrypts an entry for automation. Enforces scope and audits the use.
    .OUTPUTS  [pscustomobject] @{ Id; Type; Username; Credential [pscredential]; Passphrase [securestring]; Fields; Target }
    .NOTES    Only call from job runners, connection tests and the identity layer - never return the result to a browser.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [ValidateSet('site', 'cloud', 'identity', 'system', 'item')] [string] $Purpose,
        [string] $ItemId,
        [string[]] $Teams,
        [string] $RequestId,
        [string] $Actor = 'system'
    )
    $result = Invoke-PortalLock -Name 'vault' -ScriptBlock {
        $store = Read-PortalVaultStore
        $e = @($store.entries) | Where-Object { $_ -and $_.id -eq $Id } | Select-Object -First 1
        if (-not $e) { throw "Vault entry '$Id' not found (Admin > Vault)." }
        if (-not (Test-PortalVaultScope -Entry $e -Purpose $Purpose -ItemId $ItemId -Teams $Teams)) {
            throw "Vault entry '$Id' is not allowed for $Purpose$(if ($ItemId) { " '$ItemId'" }) (check its scope in Admin > Vault)."
        }
        if ((Get-VV $e 'expiresAt') -and [datetime](Get-VV $e 'expiresAt') -lt (Get-Date)) { throw "Vault entry '$Id' expired on $($e.expiresAt)." }
        $payload = Unprotect-PortalVaultData -Data $e.secret.data -Aad "$Id|$($e.secret.v)" | ConvertFrom-Json
        $e['lastUsedAt'] = Get-PortalTimestamp; $e['lastUsedBy'] = $(if ($RequestId) { $RequestId } else { $Actor })
        $e['useCount'] = [int](Get-VV $e 'useCount' 0) + 1
        Save-PortalVaultStore -Store $store
        $user = if ($e.username) { [string]$e.username } else { $Id }
        [pscustomobject]@{
            Id         = $Id
            Type       = [string]$e.type
            Username   = [string]$e.username
            Target     = [string](Get-VV $e 'target' '')
            Fields     = Get-VV $e 'fields' @{}
            Credential = [pscredential]::new($user, (ConvertTo-SecureString -String ([string]$payload.secret) -AsPlainText -Force))
            Passphrase = $(if ($payload.passphrase) { ConvertTo-SecureString -String ([string]$payload.passphrase) -AsPlainText -Force } else { $null })
        }
    }
    Write-PortalAudit -Actor $Actor -Action 'vault.use' -Target $Id -Details @{ purpose = $Purpose; item = $ItemId; request = $RequestId }
    return $result
}

function Get-PortalVaultCredential {
    <# Shortcut: the PSCredential of an entry. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Id, [Parameter(Mandatory)] [string] $Purpose, [string] $ItemId, [string[]] $Teams, [string] $RequestId, [string] $Actor = 'system')
    return (Get-PortalVaultSecret @PSBoundParameters).Credential
}

function Get-PortalVaultStatus {
    <# Health summary for Admin > Vault. #>
    [CmdletBinding()] param()
    $info = Get-PortalVaultKeyInfo
    $ok = $true; $err = $null
    try { $null = Invoke-PortalLock -Name 'vault' -ScriptBlock { Read-PortalVaultStore } } catch { $ok = $false; $err = $_.Exception.Message }
    $entries = if ($ok) { @(Get-PortalVaultEntry) } else { @() }
    return [ordered]@{
        keyProvider = $info.provider
        keyLocation = $info.location
        healthy     = $ok
        error       = $err
        entries     = $entries.Count
        expired     = @($entries | Where-Object { $_.state -eq 'expired' }).Count
        expiring    = @($entries | Where-Object { $_.state -eq 'expiring' }).Count
        types       = $script:EntryTypes
    }
}

function Get-PortalVaultOption {
    <# Entries a catalog item may use (for "credential" inputs): id + name only. #>
    [CmdletBinding()] param([string] $ItemId, [string[]] $Teams, [string[]] $Tags)
    $store = Invoke-PortalLock -Name 'vault' -ScriptBlock { Read-PortalVaultStore }
    foreach ($e in @($store.entries) | Where-Object { $_ }) {
        if (-not (Test-PortalVaultScope -Entry $e -Purpose 'item' -ItemId $ItemId -Teams $Teams)) { continue }
        if ($Tags -and -not (@(Get-VV $e 'tags' @()) | Where-Object { $Tags -contains $_ })) { continue }
        [ordered]@{ value = $e.id; label = $(if ($e.username) { "$($e.name) ($($e.username))" } else { $e.name }) }
    }
}

function Import-PortalLegacySecrets {
    <#
    .SYNOPSIS Upgrade step: moves DPAPI CliXml credentials (sites, clouds) into the vault. Windows only; idempotent.
    #>
    [CmdletBinding()] param()
    $cfg = Get-PortalConfig
    $moved = [System.Collections.Generic.List[string]]::new()
    foreach ($s in @(Get-VV $cfg 'sites' @())) {
        $c = Get-VV $s 'credential' @{}
        if ((Get-VV $c 'type') -ne 'CliXml') { continue }
        $path = [string](Get-VV $c 'path' '')
        if ($path -and -not [System.IO.Path]::IsPathRooted($path)) { $path = Join-Path (Get-PortalRoot) $path }
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { continue }
        try { $cred = Import-Clixml -LiteralPath $path } catch { Write-Warning "Site $($s.code): stored credential could not be read for migration ($($_.Exception.Message))."; continue }
        if ($cred -isnot [pscredential]) { continue }
        $id = "vcenter-$($s.code.ToLower())"
        Set-PortalVaultEntry -Id $id -Name "vCenter $($s.code) service account" -Type UsernamePassword -Username $cred.UserName `
            -Secret $cred.GetNetworkCredential().Password -Target ([string]$s.vcenter) -Scope @{ system = $true } -Actor 'system' `
            -New:(-not (Get-PortalVaultEntry -Id $id))
        Update-PortalConfig -Mutate { param($x) ($x.sites | Where-Object { $_.code -eq $s.code }).credential = [ordered]@{ type = 'Vault'; id = $id } }
        Move-Item -LiteralPath $path -Destination "$path.migrated" -Force
        $moved.Add("site $($s.code)")
    }
    foreach ($p in 'aws', 'azure') {
        $c = Get-VV (Get-VV $cfg 'clouds' @{}) $p
        if (-not $c -or (Get-VV $c 'credentialRef')) { continue }
        $path = [string](Get-VV $c 'credentialPath' "data/secrets/$p.cloud.xml")
        if (-not [System.IO.Path]::IsPathRooted($path)) { $path = Join-Path (Get-PortalRoot) $path }
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try { $cred = Import-Clixml -LiteralPath $path } catch { Write-Warning "Cloud $($p): stored secret could not be read for migration."; continue }
        $id = "cloud-$p"
        Set-PortalVaultEntry -Id $id -Name "$($p.ToUpper()) automation identity" -Type ServicePrincipal -Username $cred.UserName `
            -Secret $cred.GetNetworkCredential().Password -Scope @{ system = $true } -Actor 'system' -New:(-not (Get-PortalVaultEntry -Id $id))
        Update-PortalConfig -Mutate { param($x) $x.clouds[$p]['credentialRef'] = $id }
        Move-Item -LiteralPath $path -Destination "$path.migrated" -Force
        $moved.Add("cloud $p")
    }
    if ($moved.Count) {
        Write-Host "Credentials moved to the vault: $($moved -join ', ')" -ForegroundColor Yellow
        Write-PortalAudit -Actor 'system' -Action 'vault.migrate' -Details @{ moved = @($moved) }
    }
}

function Reset-PortalVaultKeyCache { $script:VaultKey = $null }

function Protect-PortalSecretValue {
    <# Encrypts a small value with the vault master key (e.g. MFA seeds). $Context binds the ciphertext to its owner. #>
    param([Parameter(Mandatory)] [string] $Value, [Parameter(Mandatory)] [string] $Context)
    return (Protect-PortalVaultData -PlainText $Value -Aad "value|$Context")
}

function Unprotect-PortalSecretValue {
    param([Parameter(Mandatory)] [string] $Data, [Parameter(Mandatory)] [string] $Context)
    return (Unprotect-PortalVaultData -Data $Data -Aad "value|$Context")
}

Export-ModuleMember -Function Get-PortalVaultKeyInfo, Get-PortalVaultEntry, Set-PortalVaultEntry, Remove-PortalVaultEntry, Get-PortalVaultReference,
    Get-PortalVaultSecret, Get-PortalVaultCredential, Get-PortalVaultStatus, Get-PortalVaultOption, Import-PortalLegacySecrets,
    Test-PortalVaultScope, Reset-PortalVaultKeyCache, Protect-PortalSecretValue, Unprotect-PortalSecretValue
