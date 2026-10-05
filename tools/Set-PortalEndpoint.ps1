#Requires -Version 7.2
<#
.SYNOPSIS
    Sets the portal HTTPS endpoint (port and certificate files). Creates the configuration from the defaults when needed.
.DESCRIPTION
    Non-interactive and idempotent; used by packaging/linux/install.sh and the appliance first-boot script.
    Exit code 0 on success, 1 on failure.
.EXAMPLE
    pwsh -File /opt/ssp/tools/Set-PortalEndpoint.ps1 -Port 443 -CertificateFile /etc/ssp/tls/portal.crt -CertificateKeyFile /etc/ssp/tls/portal.key
.EXAMPLE
    pwsh -File .\tools\Set-PortalEndpoint.ps1 -Port 8443 -CertificateThumbprint 0123...    # Windows certificate store
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 65535)] [int] $Port,
    [string] $CertificateFile,
    [string] $CertificateKeyFile,
    [string] $CertificatePasswordEnvVar,
    [string] $CertificateThumbprint,
    [string] $Address
)
$ErrorActionPreference = 'Stop'
try {
    $root = Split-Path -Parent $PSScriptRoot
    if (-not $env:SSP_PORTAL_ROOT) { $env:SSP_PORTAL_ROOT = $root }
    foreach ($m in 'Portal.Core', 'Portal.Security', 'Portal.Vault', 'Portal.Catalog', 'Portal.Jobs', 'Portal.Sites', 'Portal.Cloud', 'Portal.Settings') {
        Import-Module (Join-Path $root "modules/$m.psm1") -Force
    }
    Initialize-PortalConfiguration | Out-Null      # creates config/portal.config.json + config/local-users.json from the defaults
    foreach ($f in $CertificateFile, $CertificateKeyFile) {
        if ($f -and -not (Test-Path -LiteralPath $f)) { throw "File not found: $f" }
    }
    $setPort = $PSBoundParameters.ContainsKey('Port')
    Update-PortalConfig -Mutate {
        param($cfg)
        if ($setPort) { $cfg.portal['port'] = $Port }
        if ($Address) { $cfg.portal['address'] = $Address }
        if ($CertificateFile) {
            $cfg.portal['protocol'] = 'Https'
            $cfg.portal['certificateFile'] = $CertificateFile
            $cfg.portal['certificateKeyFile'] = [string]$CertificateKeyFile
            $cfg.portal['certificatePasswordEnvVar'] = [string]$CertificatePasswordEnvVar
            $cfg.portal['certificateThumbprint'] = ''
        }
        elseif ($CertificateThumbprint) {
            $cfg.portal['protocol'] = 'Https'
            $cfg.portal['certificateThumbprint'] = $CertificateThumbprint
            $cfg.portal['certificateFile'] = ''
        }
    }.GetNewClosure()
    Write-PortalAudit -Actor "CLI\$([Environment]::UserName)" -Action 'portal.endpoint' -Details @{ port = $Port; certificateFile = $CertificateFile }
    $c = (Get-PortalConfig).portal
    Write-Host "Endpoint: $($c.protocol) port $($c.port) certificate $(if ($c.certificateFile) { $c.certificateFile } elseif ($c.certificateThumbprint) { "thumbprint $($c.certificateThumbprint)" } else { 'self-signed (lab)' })"
    exit 0
}
catch {
    Write-Error "Set-PortalEndpoint failed: $($_.Exception.Message)"
    exit 1
}
