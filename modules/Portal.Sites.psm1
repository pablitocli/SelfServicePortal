#Requires -Version 7.2
<#
.SYNOPSIS
    Portal.Sites - vCenter connection management for the Admin UI (settings, credentials, connection test).
.DESCRIPTION
    Service-account credentials entered in the portal are stored in the portal vault (Portal.Vault, entry
    vcenter-<site>, system scope). Sites still using a legacy CliXml file or a SecretManagement vault keep working;
    saving a credential from the UI moves the site to the portal vault.
#>

Set-StrictMode -Version Latest

function Get-SiteVal {
    param($Table, [string] $Key, $Default = $null)
    if ($Table -is [System.Collections.IDictionary] -and $Table.Contains($Key) -and $null -ne $Table[$Key]) { return $Table[$Key] }
    return $Default
}

function Update-PortalConfig {
    <# Locked read-modify-write of portal.config.json (keeps a timestamped backup). #>
    param([Parameter(Mandatory)] [scriptblock] $Mutate)
    $path = Get-PortalPath -Name Config
    Invoke-PortalLock -Name 'config' -ScriptBlock {
        $cfg = Read-PortalJson -Path $path
        & $Mutate $cfg
        $bak = Join-Path (Split-Path -Parent $path) ('_backup/portal.config.{0:yyyyMMddHHmmss}.json' -f (Get-Date))
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $bak) -Force
        Copy-Item -LiteralPath $path -Destination $bak
        Write-PortalJson -Path $path -Value $cfg
    } | Out-Null
}

function Get-PortalSiteView {
    <# Site list for the Admin UI (no secrets). #>
    [CmdletBinding()] param()
    $invDir = Get-PortalPath -Name Inventory
    foreach ($s in Get-PortalSite) {
        $cred = Get-SiteVal $s 'credential' @{}
        $type = Get-SiteVal $cred 'type' ''
        $configured = switch ($type) {
            'CliXml' {
                $p = [string](Get-SiteVal $cred 'path' '')
                if ($p -and -not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path (Get-PortalRoot) $p }
                [bool]($p -and (Test-Path -LiteralPath $p))
            }
            'Vault'            { [bool](Get-PortalVaultEntry -Id ([string](Get-SiteVal $cred 'id' ''))) }
            'SecretManagement' { $false }   # vault reference only; cannot be verified without reading the secret
            default { $false }
        }
        $defaults = Get-SiteVal $s 'defaults' @{}
        [ordered]@{
            code                     = $s.code
            name                     = Get-SiteVal $s 'name' $s.code
            enabled                  = [bool](Get-SiteVal $s 'enabled' $false)
            vcenter                  = Get-SiteVal $s 'vcenter' ''
            invalidCertificateAction = Get-SiteVal $s 'invalidCertificateAction' 'Ignore'
            credential               = [ordered]@{
                type       = $type
                configured = $configured
                username   = $(if ($type -eq 'Vault') { $ve = Get-PortalVaultEntry -Id ([string](Get-SiteVal $cred 'id' '')); if ($ve) { $ve.username } else { '' } } else { Get-SiteVal $cred 'username' '' })
                vaultId    = Get-SiteVal $cred 'id' ''
                updatedAt  = Get-SiteVal $cred 'updatedAt' $null
                vault      = Get-SiteVal $cred 'vault' ''
                secret     = Get-SiteVal $cred 'secret' ''
            }
            workloadClusters         = Get-SiteVal $defaults 'workloadClusters' ([ordered]@{ App = ''; DB = '' })
            vmFolder                 = Get-SiteVal $defaults 'vmFolder' ''
            dnsDomain                = Get-SiteVal $defaults 'dnsDomain' ''
            dnsServers               = @(Get-SiteVal $defaults 'dnsServers' @())
            lastTest                 = Read-PortalJson -Path (Join-Path $invDir "$($s.code).conn.json")
        }
    }
}

function Set-PortalSiteSettings {
    <#
    .SYNOPSIS Creates or updates a site (vCenter endpoint, App/DB clusters, defaults).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Code,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Settings,
        [switch] $New,
        [Parameter(Mandatory)] [string] $Actor
    )
    $Code = $Code.ToUpperInvariant()
    if ($Code -notmatch '^[A-Z0-9]{2,8}$') { throw 'Site code must be 2-8 letters/digits.' }
    $vc = [string](Get-SiteVal $Settings 'vcenter' '')
    if ($vc -and $vc -notmatch '^[A-Za-z0-9.-]+$') { throw 'vCenter must be a host name or IP address.' }
    $cert = [string](Get-SiteVal $Settings 'invalidCertificateAction' '')
    if ($cert -and @('Fail', 'Warn', 'Ignore', 'Prompt') -notcontains $cert) { throw 'invalidCertificateAction must be Fail, Warn or Ignore.' }

    Update-PortalConfig -Mutate {
        param($cfg)
        $site = @($cfg.sites) | Where-Object { $_.code -eq $Code } | Select-Object -First 1
        if ($New -and $site) { throw "Site $Code already exists." }
        if (-not $site) {
            if (-not $vc) { throw 'vCenter is required for a new site.' }
            $site = [ordered]@{ code = $Code; name = $Code; enabled = $false; vcenter = $vc
                                credential = [ordered]@{ type = 'Vault'; id = "vcenter-$($Code.ToLower())" }
                                defaults = [ordered]@{ vmFolder = 'Portal-Provisioned'; dnsDomain = ''; dnsServers = @(); minDatastoreFreePercent = 15
                                                       allowedClusters = @(); portgroupFilter = '.*'; workloadClusters = [ordered]@{ App = ''; DB = '' } } }
            $cfg.sites = @($cfg.sites) + $site
        }
        if ($Settings.Contains('name') -and $Settings.name)       { $site.name = [string]$Settings.name }
        if ($vc)                                                   { $site.vcenter = $vc }
        if ($Settings.Contains('enabled'))                         { $site.enabled = [bool]$Settings.enabled }
        if ($cert)                                                 { $site['invalidCertificateAction'] = $cert }
        if (-not $site.Contains('defaults')) { $site['defaults'] = [ordered]@{} }
        $d = $site.defaults
        if ($Settings.Contains('workloadClusters')) {
            $wc = [ordered]@{}
            foreach ($k in $Settings.workloadClusters.Keys) { $wc[$k] = [string]$Settings.workloadClusters[$k] }
            $d['workloadClusters'] = $wc
            # Keep the cluster allow-list aligned with the workload mapping.
            $d['allowedClusters'] = @($wc.Values | Where-Object { $_ } | Select-Object -Unique)
        }
        if ($Settings.Contains('vmFolder'))   { $d['vmFolder']   = [string]$Settings.vmFolder }
        if ($Settings.Contains('dnsDomain'))  { $d['dnsDomain']  = [string]$Settings.dnsDomain }
        if ($Settings.Contains('dnsServers')) { $d['dnsServers'] = @($Settings.dnsServers | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) }
    }
    Write-PortalAudit -Actor $Actor -Action ($(if ($New) { 'site.create' } else { 'site.update' })) -Target $Code -Details @{ vcenter = $vc }
}

function Set-PortalSiteCredential {
    <# Stores the vCenter service credential in the portal vault (entry vcenter-<site>, system scope). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Code,
        [Parameter(Mandatory)] [string] $Username,
        [Parameter(Mandatory)] [string] $Password,
        [Parameter(Mandatory)] [string] $Actor
    )
    $site = Get-PortalSite -Code $Code
    if (-not $site) { throw "Site $Code not found." }
    if ($Username -notmatch '^[^\s]{1,128}$') { throw 'Invalid username.' }
    $id = "vcenter-$($site.code.ToLower())"
    Set-PortalVaultEntry -Id $id -Name "vCenter $($site.code) service account" -Type UsernamePassword -Username $Username -Secret $Password `
        -Target ([string]$site.vcenter) -Scope @{ system = $true } -Actor $Actor -New:(-not (Get-PortalVaultEntry -Id $id))
    Update-PortalConfig -Mutate {
        param($cfg)
        $s = @($cfg.sites) | Where-Object { $_.code -eq $site.code } | Select-Object -First 1
        $s['credential'] = [ordered]@{ type = 'Vault'; id = $id; updatedAt = (Get-PortalTimestamp) }
    }
    Write-PortalAudit -Actor $Actor -Action 'site.credential' -Target $site.code -Details @{ username = $Username }
}

function Test-PortalSiteConnection {
    <#
    .SYNOPSIS Runs automation/Test-VCenterConnection.ps1 out-of-process (same identity as the job runners).
    .OUTPUTS  Result hashtable (also persisted to data/inventory/<SITE>.conn.json).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Code, [int] $TimeoutSeconds = 60, [string] $Actor = 'system')
    $site = Get-PortalSite -Code $Code
    if (-not $site) { throw "Site $Code not found." }
    $cfg    = Get-PortalConfig
    $pwsh   = if ($cfg.jobs.pwshPath) { $cfg.jobs.pwshPath } else { 'pwsh' }
    $script = Join-Path (Get-PortalPath -Name Automation) 'Test-VCenterConnection.ps1'
    $out    = Join-Path (Get-PortalPath -Name Inventory) "$($site.code).conn.json"
    $logBase = Join-Path (Get-PortalPath -Name JobLogs) "conntest-$($site.code)"
    $env:SSP_PORTAL_ROOT = Get-PortalRoot
    $sp = @{ FilePath = $pwsh; PassThru = $true; RedirectStandardOutput = "$logBase.stdout.log"; RedirectStandardError = "$logBase.stderr.log"
             ArgumentList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$script`"", '-Site', $site.code) }
    if ($IsWindows) { $sp['WindowStyle'] = 'Hidden' }
    $proc = Start-Process @sp
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        $r = [ordered]@{ ok = $false; testedAt = (Get-PortalTimestamp); error = "Connection test timed out after $TimeoutSeconds s (check DNS, firewall 443 to $($site.vcenter))." }
        Write-PortalJson -Path $out -Value $r
    }
    $r = Read-PortalJson -Path $out
    if (-not $r) {
        $err = if (Test-Path "$logBase.stderr.log") { (Get-Content "$logBase.stderr.log" -Raw) } else { 'No result produced.' }
        $r = [ordered]@{ ok = $false; testedAt = (Get-PortalTimestamp); error = "$err".Trim() }
    }
    Write-PortalAudit -Actor $Actor -Action 'site.test' -Target $site.code -Details @{ ok = [bool]$r.ok }
    return $r
}

function Test-VaultMissing {
    <# True when a site points to a SecretManagement vault that is not registered on this server. #>
    param($Site)
    if (-not $Site.Contains('credential') -or $Site.credential.type -ne 'SecretManagement') { return $false }
    if (-not (Get-Module -ListAvailable Microsoft.PowerShell.SecretManagement)) { return $true }
    try {
        Import-Module Microsoft.PowerShell.SecretManagement -ErrorAction Stop
        return -not (Get-SecretVault -Name $Site.credential.vault -ErrorAction SilentlyContinue)
    } catch { return $true }
}

function Initialize-PortalConfiguration {
    <#
    .SYNOPSIS First-run / upgrade bootstrap, executed by Start-Portal.ps1 before the server starts.
    .DESCRIPTION
        * Creates config/portal.config.json and config/local-users.json from the *.default.json files when missing
          (the release zip ships only defaults, so extracting it over an existing install never overwrites your settings).
        * Adds settings introduced by newer versions to an existing configuration (non-destructive).
    #>
    [CmdletBinding()] param()
    $cfgDir = Split-Path -Parent (Get-PortalPath -Name Config)
    foreach ($pair in @(@('portal.config.default.json', 'portal.config.json'), @('local-users.default.json', 'local-users.json'))) {
        $src = Join-Path $cfgDir $pair[0]; $dst = Join-Path $cfgDir $pair[1]
        if (-not (Test-Path -LiteralPath $dst) -and (Test-Path -LiteralPath $src)) {
            Copy-Item -LiteralPath $src -Destination $dst
            Write-Host "Created config/$($pair[1]) from defaults." -ForegroundColor Yellow
        }
    }
    $changes = [System.Collections.Generic.List[string]]::new()
    $cfg = Read-PortalJson -Path (Get-PortalPath -Name Config)
    if (-not $cfg.Contains('automation')) { $changes.Add('automation.allowedHandlerRoots') }
    if (-not $cfg.auth.Contains('localUsers')) { $changes.Add('auth.localUsers') }
    foreach ($s in @($cfg.sites)) {
        if (-not $s.Contains('defaults') -or -not $s.defaults.Contains('workloadClusters')) { $changes.Add("sites[$($s.code)].defaults.workloadClusters") }
        if ((Test-VaultMissing -Site $s)) { $changes.Add("sites[$($s.code)].credential -> portal-managed (vault '$($s.credential.vault)' not registered)") }
    }
    $done = @($(if ($cfg.Contains('_migrations')) { $cfg._migrations } else { @() }))
    if ($done -notcontains 'cert-ignore-2026-09') { $changes.Add('vCenter certificate policy -> Ignore (accept self-signed/VMCA)') }
    if ($done -notcontains 'clouds-2026-09' -and -not $cfg.Contains('clouds')) { $changes.Add('clouds (AWS / Azure connections)') }
    if (-not $cfg.Contains('teams'))    { $changes.Add('teams (Infrastructure / Cloud)') }
    if (-not $cfg.Contains('branding')) { $changes.Add('branding') }
    if (-not $cfg.Contains('vmNotes'))  { $changes.Add('vmNotes (VM notes section)') }
    if (-not $cfg.auth.Contains('providers')) { $changes.Add('auth.providers (identity: AD / OpenLDAP over LDAPS)') }
    if (-not $cfg.Contains('security')) { $changes.Add('security (session timeout, password policy, lockout, MFA)') }
    if (-not $cfg.Contains('vault'))    { $changes.Add('vault (credential vault)') }
    $itemsDir = Get-PortalPath -Name CatalogItems
    $retired = @('vm-windows-2022.json', 'vm-rhel-9.json') | Where-Object { Test-Path -LiteralPath (Join-Path $itemsDir $_) }
    if ($done -notcontains 'examples-2025' -and $retired) { $changes.Add("retired example items: $($retired -join ', ')") }
    if (-not $changes.Count) { return }

    # Retire the previous example items (replaced by Windows Server 2025 / AlmaLinux). Archived, not deleted.
    if ($done -notcontains 'examples-2025') {
        foreach ($f in $retired) {
            $arch = Join-Path (Get-PortalRoot) ('catalog/_archive/{0}.retired.{1:yyyyMMddHHmmss}.json' -f [IO.Path]::GetFileNameWithoutExtension($f), (Get-Date))
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $arch) -Force
            Move-Item -LiteralPath (Join-Path $itemsDir $f) -Destination $arch
        }
    }
    Update-PortalConfig -Mutate {
        param($c)
        if (-not $c.Contains('automation')) { $c['automation'] = [ordered]@{ allowedHandlerRoots = @() } }
        if (-not $c.auth.Contains('localUsers')) { $c.auth['localUsers'] = [ordered]@{ enabled = $true; file = 'config/local-users.json' } }
        $mig = [System.Collections.Generic.List[string]]::new()
        if ($c.Contains('_migrations')) { @($c._migrations) | ForEach-Object { $mig.Add($_) } }
        if (-not $mig.Contains('cert-ignore-2026-09')) {
            foreach ($s in @($c.sites)) { $s['invalidCertificateAction'] = 'Ignore' }
            $mig.Add('cert-ignore-2026-09')
        }
        if (-not $c.Contains('clouds')) { $c['clouds'] = New-PortalCloudDefaults }
        # New sections come from portal.config.default.json (shipped with the release) so every edition upgrades with its own defaults.
        $defPath = Join-Path (Split-Path -Parent (Get-PortalPath -Name Config)) 'portal.config.default.json'
        $def = if (Test-Path -LiteralPath $defPath) { Read-PortalJson -Path $defPath } else { [ordered]@{} }
        if (-not $c.Contains('teams')) {
            $c['teams'] = if ($def.Contains('teams')) { $def.teams } else {
                @([ordered]@{ id = 'Infrastructure'; name = 'Infrastructure Operations'; adGroups = @() }, [ordered]@{ id = 'Cloud'; name = 'Cloud Operations'; adGroups = @() }) }
        }
        if (-not $c.Contains('branding')) {
            $b = if ($def.Contains('branding')) { $def.branding } else { [ordered]@{} }
            $b['productName'] = [string]$c.portal.name; $b['organization'] = [string]$c.portal.organization; $b['logoFile'] = ''
            $c['branding'] = $b
        }
        if (-not $c.Contains('vmNotes') -and $def.Contains('vmNotes')) { $c['vmNotes'] = $def.vmNotes }
        foreach ($m in 'teams-2026-10', 'vmnotes-2026-10') { if (-not $mig.Contains($m)) { $mig.Add($m) } }

        # Identity: the former Windows-AD form login (auth.fqdn / auth.domain) becomes an LDAP provider.
        if (-not $c.auth.Contains('providers')) {
            $prov = @()
            $fqdn = [string](Get-SiteVal $c.auth 'fqdn' '')
            if ($fqdn) {
                $netbios = [string](Get-SiteVal $c.auth 'domain' ($fqdn.Split('.')[0].ToUpperInvariant()))
                $prov += [ordered]@{
                    id = 'ad'; name = 'Active Directory'; enabled = $true; flavor = 'ad'
                    domains = @($fqdn, $netbios); hosts = @($fqdn)
                    # Windows keeps the previous behaviour (Kerberos/NTLM signed + sealed on 389); Linux requires LDAPS.
                    port = $(if ($IsWindows) { 389 } else { 636 }); security = $(if ($IsWindows) { 'negotiate' } else { 'ldaps' })
                    baseDn = (($fqdn.Split('.') | ForEach-Object { "DC=$_" }) -join ',')
                    bindMode = 'direct'; upnSuffix = $fqdn; usernamePrefix = $netbios
                    groupMode = $(if (Get-SiteVal $c.auth 'directGroupsOnly' $false) { 'memberOf' } else { 'nested' })
                    tls = [ordered]@{ verify = $true }
                }
            }
            $c.auth['providers'] = $prov
            $c.auth['defaultProvider'] = $(if ($prov) { 'ad' } else { '' })
            foreach ($k in 'provider', 'fqdn', 'domain', 'directGroupsOnly') { if ($c.auth.Contains($k)) { $c.auth.Remove($k) } }
        }
        foreach ($r in 'CatalogAdmin', 'SecurityAdmin', 'VaultAdmin') { if (-not $c.auth.roleMapping.Contains($r)) { $c.auth.roleMapping[$r] = @() } }
        if (-not $c.Contains('security')) {
            $c['security'] = if ($def.Contains('security')) { $def.security } else { [ordered]@{} }
            if ($c.portal.Contains('sessionDurationMinutes')) {
                if (-not $c.security.Contains('session')) { $c.security['session'] = [ordered]@{} }
                $c.security.session['absoluteTimeoutMinutes'] = [int]$c.portal.sessionDurationMinutes
                $c.portal.Remove('sessionDurationMinutes')
            }
        }
        if (-not $c.Contains('vault')) { $c['vault'] = if ($def.Contains('vault')) { $def.vault } else { [ordered]@{ keyProvider = 'auto'; maxVersions = 5 } } }
        if (-not $mig.Contains('identity-2026-10')) { $mig.Add('identity-2026-10') }
        if (-not $mig.Contains('clouds-2026-09')) { $mig.Add('clouds-2026-09') }
        if (-not $mig.Contains('examples-2025')) { $mig.Add('examples-2025') }
        $c['_migrations'] = $mig.ToArray()
        foreach ($s in @($c.sites)) {
            if (Test-VaultMissing -Site $s) {
                $s['credential'] = [ordered]@{ type = 'Vault'; id = "vcenter-$($s.code.ToLower())" }
            }
            if (-not $s.Contains('defaults')) { $s['defaults'] = [ordered]@{} }
            if (-not $s.defaults.Contains('workloadClusters')) {
                # Derive from allowedClusters: a name containing "DB" is the database cluster, the first other one is APP.
                $allowed = @($s.defaults['allowedClusters'])
                $db  = $allowed | Where-Object { $_ -match 'DB' } | Select-Object -First 1
                $app = $allowed | Where-Object { $_ -and $_ -ne $db } | Select-Object -First 1
                $s.defaults['workloadClusters'] = [ordered]@{ App = [string]$app; DB = [string]$db }
            }
        }
    }
    Write-Host "Configuration upgraded: $($changes -join ', ')" -ForegroundColor Yellow
    Write-PortalAudit -Actor 'system' -Action 'config.upgrade' -Details @{ added = @($changes) }
}

Export-ModuleMember -Function Initialize-PortalConfiguration, Get-PortalSiteView, Set-PortalSiteSettings, Set-PortalSiteCredential, Test-PortalSiteConnection, Update-PortalConfig
