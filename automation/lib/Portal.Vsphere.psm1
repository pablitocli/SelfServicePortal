#Requires -Version 7.2
<#
.SYNOPSIS
    Portal.Vsphere - credential retrieval and vCenter connection helpers for job runners and handlers.
.NOTES
    Credentials are never stored in the portal configuration. Supported credential types:
      - Vault            : portal vault entry (default; Admin > vCenter connections or Admin > Vault)
      - SecretManagement : Microsoft.PowerShell.SecretManagement vault (recommended; e.g. SecretStore or CyberArk/HashiCorp extension)
      - CliXml           : Export-Clixml file encrypted with DPAPI for the portal service account (Windows only)
    Use tools/Register-PortalCredential.ps1 to provision them.
#>

Set-StrictMode -Version Latest

function Get-PortalCredential {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Site)

    $c = $Site.credential
    switch ($c.type) {
        'Vault' {
            if (-not (Get-Command Get-PortalVaultCredential -ErrorAction SilentlyContinue)) { Import-Module (Join-Path (Get-PortalRoot) 'modules/Portal.Vault.psm1') -Force -Global }
            try { return (Get-PortalVaultCredential -Id ([string]$c.id) -Purpose site -Actor "site:$($Site.code)") }
            catch { throw "vCenter credential for site $($Site.code): $($_.Exception.Message) Admin > vCenter connections: enter the service account and password, then Save." }
        }
        'SecretManagement' {
            $hint = "Or store the account in the portal: Admin > vCenter connections > $($Site.code) > Service account + Password > Save."
            if (-not (Get-Module -ListAvailable Microsoft.PowerShell.SecretManagement)) { throw "SecretManagement module is not installed. $hint" }
            Import-Module Microsoft.PowerShell.SecretManagement -ErrorAction Stop
            if (-not (Get-SecretVault -Name $c.vault -ErrorAction SilentlyContinue)) { throw "Vault '$($c.vault)' is not registered on this server. $hint" }
            $secret = Get-Secret -Vault $c.vault -Name $c.secret -ErrorAction Stop
            if ($secret -isnot [pscredential]) { throw "Secret '$($c.secret)' in vault '$($c.vault)' is not a PSCredential." }
            return $secret
        }
        'CliXml' {
            $path = $c.path
            if (-not [System.IO.Path]::IsPathRooted($path)) { $path = Join-Path (Get-PortalRoot) $path }
            if (-not (Test-Path -LiteralPath $path)) {
                throw "No vCenter credential stored for site $($Site.code). Admin > vCenter connections: enter the service account and password, then Save."
            }
            try { return (Import-Clixml -LiteralPath $path) }
            catch { throw "The stored credential for $($Site.code) cannot be decrypted by account '$([Environment]::UserName)'. Credentials are bound to the Windows account that runs the portal - save it again from Admin > vCenter connections." }
        }
        default { throw "Unsupported credential type '$($c.type)' for site $($Site.code)." }
    }
}

function Connect-PortalVIServer {
    <#
    .SYNOPSIS Connects to the vCenter of a site in a job-private PowerCLI session. Returns the VIServer object.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $SiteCode)

    $site = Get-PortalSite -Code $SiteCode
    if (-not $site)         { throw "Site '$SiteCode' is not defined in portal.config.json." }
    if (-not $site.enabled) { throw "Site '$SiteCode' is disabled." }

    if (-not (Get-Module -ListAvailable -Name VMware.VimAutomation.Core)) {
        throw 'VMware PowerCLI is not installed for PowerShell 7 on the portal server. Run tools\Install-PortalPrerequisites.ps1 (elevated pwsh) once.'
    }
    Import-Module VMware.VimAutomation.Core -ErrorAction Stop
    # Session-scoped settings: no CEIP prompt, single default server, no interactive prompts.
    # Certificates: "Ignore" (default) accepts self-signed / VMCA certificates without prompting.
    #               Set the site to "Fail" once the VMCA root CA is trusted on the portal server.
    # Proxy: vCenter is reached directly (NoProxy) unless the site sets "useSystemProxy": true.
    $certAction = if ($site.Contains('invalidCertificateAction') -and $site.invalidCertificateAction) { $site.invalidCertificateAction } else { 'Ignore' }
    $proxy      = if ($site.Contains('useSystemProxy') -and $site.useSystemProxy) { 'UseSystemProxy' } else { 'NoProxy' }
    $null = Set-PowerCLIConfiguration -Scope Session -ParticipateInCEIP $false -DefaultVIServerMode Single `
                                      -InvalidCertificateAction $certAction -ProxyPolicy $proxy `
                                      -WebOperationTimeoutSeconds 300 -Confirm:$false

    $cred = Get-PortalCredential -Site $site
    try {
        return (Connect-VIServer -Server $site.vcenter -Credential $cred -Force -ErrorAction Stop)
    }
    catch {
        $detail = Get-PortalErrorDetail -ErrorRecord $_
        $hint = switch -Regex ($detail) {
            'SSL|certificate|TLS|trust relationship' { "Certificate/TLS negotiation failed (policy: $certAction, proxy: $proxy). Check that $($site.vcenter) resolves and port 443 is reachable from the portal server; set Certificate validation = Ignore for self-signed certificates." }
            'incorrect user name or password|InvalidLogin|Cannot complete login' { "Authentication failed for '$($cred.UserName)'. Use the SSO format (svc-account@vsphere.local) or DOMAIN\user, and check the account is not locked and has a vCenter role." }
            'No such host|could not be resolved|NameResolution' { "DNS: $($site.vcenter) cannot be resolved from the portal server." }
            'timed out|timeout|actively refused|unreachable' { "Network: $($site.vcenter):443 is not reachable from the portal server (firewall / routing)." }
            default { $null }
        }
        throw ($(if ($hint) { "$hint Detail: $detail" } else { $detail }))
    }
}

function Disconnect-PortalVIServer {
    [CmdletBinding()]
    param($Server)
    if ($Server) { Disconnect-VIServer -Server $Server -Confirm:$false -Force -ErrorAction SilentlyContinue }
}

Export-ModuleMember -Function Get-PortalCredential, Connect-PortalVIServer, Disconnect-PortalVIServer
