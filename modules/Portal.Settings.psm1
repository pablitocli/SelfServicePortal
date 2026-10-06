#Requires -Version 7.2
<#
.SYNOPSIS
    Portal.Settings - Admin > Customization: branding, teams, role mapping, VM notes fields and policies.
.DESCRIPTION
    Everything here lives in portal.config.json and is applied live (no restart), except the TLS endpoint.
    The logo is stored in data/brand (survives upgrades) and served publicly at /brand/logo.
#>

Set-StrictMode -Version Latest

function Get-SV {
    param($Table, [string] $Key, $Default = $null)
    if ($Table -is [System.Collections.IDictionary] -and $Table.Contains($Key) -and $null -ne $Table[$Key]) { return $Table[$Key] }
    return $Default
}

$script:BrandDefaults = [ordered]@{
    productName    = 'Self-Service Portal'
    organization   = 'Your Organization'
    tagline        = 'Infrastructure services on demand'
    primaryColor   = '#0a1f3c'
    accentColor    = '#2f6fb8'
    logoFile       = ''
    loginMessage   = 'Sign in with your corporate account.'
    footerText     = 'Confidential - Internal Use. Access is logged and audited.'
    supportContact = ''
}

function Get-PortalBranding {
    <# Public branding (served unauthenticated to the login page). #>
    [CmdletBinding()] param()
    $cfg = Get-PortalConfig
    $b = Get-SV $cfg 'branding' @{}
    $out = [ordered]@{}
    foreach ($k in $script:BrandDefaults.Keys) { $out[$k] = Get-SV $b $k $script:BrandDefaults[$k] }
    $logo = Get-PortalLogoPath
    $out['logoUrl'] = if ($logo) { '/brand/logo?v=' + (Get-Item -LiteralPath $logo).LastWriteTimeUtc.Ticks } else { '' }
    $out.Remove('logoFile')
    return $out
}

function Get-PortalLogoPath {
    $b = Get-SV (Get-PortalConfig) 'branding' @{}
    $f = [string](Get-SV $b 'logoFile' '')
    if (-not $f -or $f -notmatch '^logo\.(png|jpg|webp)$') { return $null }
    $p = Join-Path (Get-PortalRoot) "data/brand/$f"
    if (Test-Path -LiteralPath $p) { return $p } else { return $null }
}

function Get-PortalSettingsView {
    [CmdletBinding()] param()
    $cfg = Get-PortalConfig
    $auth = $cfg.auth
    return [ordered]@{
        branding    = Get-PortalBranding
        teams       = @(Get-SV $cfg 'teams' @())
        teamRoles   = Get-SV (Get-SV $cfg 'catalog' @{}) 'teamRoles' ([ordered]@{ datacenter = ''; cloud = '' })
        roleMapping = $(
            $rm = Get-SV $auth 'roleMapping' ([ordered]@{}); $o = [ordered]@{}
            foreach ($r in Get-PortalRoleList) { $o[$r] = @(Get-SV $rm $r @()) }; $o)
        roles       = @(Get-PortalRoleList)
        vmNotes     = Get-SV $cfg 'vmNotes' ([ordered]@{ enabled = $true; title = 'VM notes'; fields = @() })
        policies    = [ordered]@{
            allowSelfApproval      = [bool](Get-SV $auth 'allowSelfApproval' $false)
            localUsersEnabled      = [bool](Get-SV (Get-SV $auth 'localUsers' @{}) 'enabled' $true)
        }
        teamUsage   = Get-PortalTeamUsage
    }
}

function Get-PortalTeamUsage {
    <# team id -> catalog item ids that reference it. #>
    $usage = [ordered]@{}
    foreach ($f in Get-ChildItem -LiteralPath (Get-PortalPath -Name CatalogItems) -Filter '*.json' -File) {
        try { $i = Read-PortalJson -Path $f.FullName } catch { continue }
        foreach ($t0 in @(Get-SV (Get-SV $i 'access' @{}) 'teams' @())) {
            $t = Resolve-PortalTeamToken -Team ([string]$t0)      # team roles (@datacenter / @cloud) count for the mapped team
            if (-not $t) { continue }
            if (-not $usage.Contains($t)) { $usage[$t] = @() }
            $usage[$t] = @($usage[$t]) + $i.id
        }
    }
    return $usage
}

function Set-PortalSettings {
    <#
    .SYNOPSIS Validates and saves the Customization settings (any subset of branding/teams/roleMapping/vmNotes/policies/directory).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Settings, [Parameter(Mandatory)] [string] $Actor)

    $hex = '^#[0-9A-Fa-f]{6}$'
    if ($Settings.Contains('branding')) {
        $b = $Settings.branding
        foreach ($k in 'primaryColor', 'accentColor') { if ($b.Contains($k) -and $b[$k] -notmatch $hex) { throw "$k must be a hex color like #1a2b3c." } }
        foreach ($k in 'productName', 'organization') { if ($b.Contains($k) -and ([string]$b[$k]).Trim().Length -lt 2) { throw "$k is required." } }
        foreach ($k in $b.Keys) { if ([string]$b[$k] -match '<|>') { throw "Branding text cannot contain < or >." } }
    }
    if ($Settings.Contains('teams')) {
        $ids = @{}
        foreach ($t in @($Settings.teams)) {
            if ([string]$t.id -notmatch '^[A-Za-z][A-Za-z0-9_-]{1,31}$') { throw "Team id '$($t.id)' must be 2-32 letters, digits, _ or -." }
            if ($ids.ContainsKey($t.id)) { throw "Duplicate team id '$($t.id)'." }
            $ids[$t.id] = $true
            if (-not ([string]$t.name).Trim()) { throw "Team '$($t.id)' needs a name." }
        }
        $usage = Get-PortalTeamUsage
        foreach ($used in $usage.Keys) {
            if (-not $ids.ContainsKey($used)) { throw "Team '$used' is still used by catalog items: $(@($usage[$used]) -join ', '). Update those items first." }
        }
    }
    if ($Settings.Contains('teamRoles')) {
        $teamIds = if ($Settings.Contains('teams')) { @($Settings.teams | ForEach-Object { [string]$_.id }) } else { @(@(Get-SV (Get-PortalConfig) 'teams' @()) | ForEach-Object { [string]$_.id }) }
        foreach ($r in $Settings.teamRoles.Keys) {
            if ([string]$r -notmatch '^[a-z][a-z0-9-]{1,31}$') { throw "Team role '$r' is not valid." }
            if ($teamIds -notcontains [string]$Settings.teamRoles[$r]) { throw "Team role @$r must map to an existing team." }
        }
    }
    if ($Settings.Contains('vmNotes')) {
        $keys = @{}
        foreach ($f in @($Settings.vmNotes.fields)) {
            if ([string]$f.key -notmatch '^[A-Za-z][A-Za-z0-9]{0,30}$') { throw "VM note key '$($f.key)' must be alphanumeric (start with a letter)." }
            if ($keys.ContainsKey($f.key)) { throw "Duplicate VM note key '$($f.key)'." }
            $keys[$f.key] = $true
            if (@('text', 'textarea', 'select') -notcontains $f.type) { throw "VM note '$($f.key)': type must be text, textarea or select." }
            if ($f.type -eq 'select' -and -not @($f.options | Where-Object { $_ })) { throw "VM note '$($f.key)': a select needs options." }
            if ($f.Contains('pattern') -and $f.pattern) { try { [void][regex]::new($f.pattern) } catch { throw "VM note '$($f.key)': invalid regex." } }
        }
    }

    Update-PortalConfig -Mutate {
        param($cfg)
        if ($Settings.Contains('branding')) {
            if (-not $cfg.Contains('branding')) { $cfg['branding'] = [ordered]@{} }
            foreach ($k in $script:BrandDefaults.Keys) { if ($k -ne 'logoFile' -and $Settings.branding.Contains($k)) { $cfg.branding[$k] = ([string]$Settings.branding[$k]).Trim() } }
            $cfg.portal['name'] = $cfg.branding['productName']
            $cfg.portal['organization'] = $cfg.branding['organization']
        }
        if ($Settings.Contains('teams')) {
            $cfg['teams'] = @($Settings.teams | ForEach-Object {
                [ordered]@{ id = [string]$_.id; name = ([string]$_.name).Trim(); adGroups = @(@($_.adGroups) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) } })
        }
        if ($Settings.Contains('teamRoles')) {
            if (-not $cfg.Contains('catalog')) { $cfg['catalog'] = [ordered]@{ teamRoles = [ordered]@{}; siteValues = @() } }
            $roles = [ordered]@{}; foreach ($r in $Settings.teamRoles.Keys) { $roles[[string]$r] = [string]$Settings.teamRoles[$r] }
            $cfg.catalog['teamRoles'] = $roles
        }
        if ($Settings.Contains('roleMapping')) {
            $rm = [ordered]@{}
            foreach ($r in Get-PortalRoleList) { $rm[$r] = @(@(Get-SV $Settings.roleMapping $r @()) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) }
            $cfg.auth['roleMapping'] = $rm
        }
        if ($Settings.Contains('vmNotes')) {
            $cfg['vmNotes'] = [ordered]@{
                enabled = [bool](Get-SV $Settings.vmNotes 'enabled' $true)
                title   = [string](Get-SV $Settings.vmNotes 'title' 'VM notes')
                fields  = @(@($Settings.vmNotes.fields) | ForEach-Object {
                    $f = [ordered]@{ key = [string]$_.key; label = ([string](Get-SV $_ 'label' $_.key)).Trim(); type = [string]$_.type; required = [bool](Get-SV $_ 'required' $false) }
                    if ($_.type -eq 'select') { $f['options'] = @(@($_.options) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) }
                    if (Get-SV $_ 'help')    { $f['help'] = [string]$_.help }
                    if (Get-SV $_ 'pattern') { $f['pattern'] = [string]$_.pattern }
                    $f })
            }
        }
        if ($Settings.Contains('policies')) {
            $p = $Settings.policies
            if ($p.Contains('allowSelfApproval')) { $cfg.auth['allowSelfApproval'] = [bool]$p.allowSelfApproval }
            if ($p.Contains('localUsersEnabled')) {
                if (-not $cfg.auth.Contains('localUsers')) { $cfg.auth['localUsers'] = [ordered]@{ file = 'config/local-users.json' } }
                $cfg.auth.localUsers['enabled'] = [bool]$p.localUsersEnabled
            }
        }
    }
    Write-PortalAudit -Actor $Actor -Action 'settings.update' -Details @{ sections = @($Settings.Keys) }
}

function Set-PortalSecurityPolicy {
    <#
    .SYNOPSIS Validates and saves security.* (session timeouts, password policy, lockout, MFA, admin networks, SoD).
    .PARAMETER ActorIp  Current client IP: an admin network list that would lock the caller out is rejected.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Policy, [Parameter(Mandatory)] [string] $Actor, [string] $ActorIp)
    $range = { param($section, $key, $min, $max)
        if ($Policy.Contains($section) -and $Policy[$section].Contains($key)) {
            $v = [int]$Policy[$section][$key]
            if ($v -lt $min -or $v -gt $max) { throw "$section.$key must be between $min and $max." }
        } }
    & $range 'session' 'idleTimeoutMinutes' 5 120
    & $range 'session' 'absoluteTimeoutMinutes' 30 1440
    & $range 'session' 'warningSeconds' 30 600
    & $range 'session' 'reauthWindowMinutes' 1 60
    & $range 'password' 'minLength' 8 128
    & $range 'password' 'requireClasses' 1 4
    & $range 'password' 'history' 0 24
    & $range 'password' 'maxAgeDays' 0 3650
    & $range 'lockout' 'threshold' 3 50
    & $range 'lockout' 'windowMinutes' 1 1440
    & $range 'lockout' 'durationMinutes' 1 1440
    if ($Policy.Contains('mfa')) {
        foreach ($r in @(Get-SV $Policy.mfa 'requiredRoles' @())) { if ((Get-PortalRoleList) -notcontains $r) { throw "Unknown role '$r' in MFA required roles." } }
        if ([string](Get-SV $Policy.mfa 'issuer' '') -match '[<>:]') { throw 'MFA issuer cannot contain < > or :.' }
    }
    foreach ($k in 'adminAllowedCidrs', 'trustedProxies') {
        foreach ($c in @(Get-SV $Policy $k @() | Where-Object { $_ })) {
            $parts = ([string]$c).Trim() -split '/'
            $ip = $null
            if ($parts.Count -gt 2 -or -not [System.Net.IPAddress]::TryParse($parts[0], [ref]$ip) -or ($parts.Count -eq 2 -and $parts[1] -notmatch '^\d{1,3}$')) { throw "$k : '$c' is not a valid IP or CIDR." }
        }
    }
    $cidrs = @(Get-SV $Policy 'adminAllowedCidrs' @() | Where-Object { $_ })
    if ($Policy.Contains('adminAllowedCidrs') -and $cidrs -and $ActorIp -and -not (Test-PortalIpInCidr -Ip $ActorIp -Cidr $cidrs)) {
        throw "Your current address ($ActorIp) is not inside the admin networks - saving would lock you out of administration."
    }
    Update-PortalConfig -Mutate {
        param($cfg)
        if (-not $cfg.Contains('security')) { $cfg['security'] = [ordered]@{} }
        foreach ($section in 'session', 'password', 'lockout', 'mfa', 'separationOfDuties') {
            if (-not $Policy.Contains($section)) { continue }
            if (-not $cfg.security.Contains($section)) { $cfg.security[$section] = [ordered]@{} }
            foreach ($k in $Policy[$section].Keys) {
                $v = $Policy[$section][$k]
                $cfg.security[$section][$k] = if ($k -eq 'requiredRoles') { @($v | Where-Object { $_ }) } elseif ($k -in 'issuer') { [string]$v } elseif ($v -is [bool]) { $v } else { [int]$v }
            }
        }
        foreach ($k in 'adminAllowedCidrs', 'trustedProxies') {
            if ($Policy.Contains($k)) { $cfg.security[$k] = @(@($Policy[$k]) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) }
        }
    }
    Write-PortalAudit -Actor $Actor -Action 'security.policy.update' -Details @{ sections = @($Policy.Keys) }
}

function Set-PortalBrandLogo {
    <# Stores a PNG / JPEG / WebP logo (max 512 KB) from a data: URL. Pass an empty value to remove it. #>
    [CmdletBinding()]
    param([string] $DataUrl, [Parameter(Mandatory)] [string] $Actor)
    $dir = Join-Path (Get-PortalRoot) 'data/brand'
    $null = New-Item -ItemType Directory -Path $dir -Force
    Get-ChildItem -LiteralPath $dir -Filter 'logo.*' -File | Remove-Item -Force
    $file = ''
    if ($DataUrl) {
        if ($DataUrl -notmatch '^data:image/(png|jpeg|webp);base64,([A-Za-z0-9+/=]+)$') { throw 'Logo must be a PNG, JPEG or WebP image (SVG is not accepted).' }
        $ext = @{ png = 'png'; jpeg = 'jpg'; webp = 'webp' }[$Matches[1]]
        $bytes = [Convert]::FromBase64String($Matches[2])
        if ($bytes.Length -gt 512KB) { throw 'Logo must be 512 KB or smaller.' }
        $file = "logo.$ext"
        [System.IO.File]::WriteAllBytes((Join-Path $dir $file), $bytes)
    }
    Update-PortalConfig -Mutate { param($cfg) if (-not $cfg.Contains('branding')) { $cfg['branding'] = [ordered]@{} }; $cfg.branding['logoFile'] = $file }
    Write-PortalAudit -Actor $Actor -Action 'settings.logo' -Details @{ file = $file }
}

function Initialize-PortalTeamScopes {
    <#
    .SYNOPSIS Upgrade step (once): scopes pre-existing catalog items and local users to teams.
    .DESCRIPTION
        * Items without access.teams: cloud handlers (New-AwsEc2Instance / New-AzureVm) -> team role @cloud, everything else -> @datacenter
          (mapped to team ids by configuration catalog.teamRoles).
          Build items (New-VsphereVM / New-AwsEc2Instance / New-AzureVm) also get the VM notes section.
        * Local users without a teams list get every configured team (same visibility they had before teams existed).
        Recorded in _migrations as 'team-scopes-2026-10'.
    #>
    [CmdletBinding()] param()
    $cfg = Get-PortalConfig
    $done = @(Get-SV $cfg '_migrations' @())
    if ($done -contains 'team-scopes-2026-10') { return }
    $known = @(@(Get-SV $cfg 'teams' @()) | ForEach-Object { $_.id })
    $changed = [System.Collections.Generic.List[string]]::new()
    $cloudHandlers = 'New-AwsEc2Instance.ps1', 'New-AzureVm.ps1'
    $buildHandlers = @('New-VsphereVM.ps1') + $cloudHandlers
    foreach ($f in Get-ChildItem -LiteralPath (Get-PortalPath -Name CatalogItems) -Filter '*.json' -File) {
        try { $i = Read-PortalJson -Path $f.FullName } catch { continue }
        $h = [System.IO.Path]::GetFileName([string](Get-SV (Get-SV $i 'execution' @{}) 'handler' ''))
        $dirty = $false
        if (-not $i.Contains('access')) { $i['access'] = [ordered]@{} }
        if (-not $i.access.Contains('teams')) {
            $t = if ($cloudHandlers -contains $h) { '@cloud' } else { '@datacenter' }
            $i.access['teams'] = @(if (Resolve-PortalTeamToken -Team $t) { $t })
            $dirty = $true
        }
        if ($buildHandlers -contains $h -and -not $i.Contains('vmNotes')) { $i['vmNotes'] = $true; $dirty = $true }
        if ($dirty) { Write-PortalJson -Path $f.FullName -Value $i; $changed.Add("item $($i.id)") }
    }
    $file = Get-PortalLocalUserFile
    if (Test-Path -LiteralPath $file) {
        Invoke-PortalLock -Name 'local-users' -ScriptBlock {
            $store = Read-PortalJson -Path $file
            $dirty = $false
            foreach ($u in @($store.users)) {
                if (-not $u.Contains('teams')) { $u['teams'] = @($known); $dirty = $true; $changed.Add("user $($u.username)") }
            }
            if ($dirty) { Write-PortalJson -Path $file -Value $store }
        } | Out-Null
    }
    Update-PortalConfig -Mutate { param($c) $c['_migrations'] = @(@(Get-SV $c '_migrations' @()) + 'team-scopes-2026-10') }
    if ($changed.Count) {
        Write-Host "Team scopes applied: $($changed -join ', ')" -ForegroundColor Yellow
        Write-PortalAudit -Actor 'system' -Action 'config.upgrade' -Details @{ teamScopes = @($changed) }
    }
}

Export-ModuleMember -Function Set-PortalSecurityPolicy, Initialize-PortalTeamScopes, Get-PortalBranding, Get-PortalLogoPath, Get-PortalSettingsView, Set-PortalSettings, Set-PortalBrandLogo, Get-PortalTeamUsage
