#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - read-only TLS certificate expiry report (vCenter, every ESXi host, additional endpoints).
.DESCRIPTION
    The certificate of each endpoint is read by a TLS handshake from the portal server (TcpClient + SslStream, the
    validation callback accepts any certificate so self-signed / expired ones can still be inspected; 5 s timeout).
    Status: EXPIRED (past NotAfter), CRITICAL (<= operations.certificates.criticalDays), EXPIRING (<= WarningDays),
    OK, or ERROR (unreachable / handshake failed).
    Get-PortalTlsCertificate is only defined here when no command with that name exists, so tests (or a future shared
    module) can provide their own.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [string] $AdditionalEndpoints,
    [ValidateRange(0, 3650)] [int] $WarningDays = 0,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}

if (-not (Get-Command Get-PortalTlsCertificate -ErrorAction SilentlyContinue)) {
    function Get-PortalTlsCertificate {
        <# Returns the X509Certificate2 presented by HostName:Port. Throws when unreachable. #>
        param([Parameter(Mandatory)] [string] $HostName, [int] $Port = 443, [int] $TimeoutMs = 5000)
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $ssl = $null
        try {
            $connect = $tcp.ConnectAsync($HostName, $Port)
            try { $done = $connect.Wait($TimeoutMs) } catch { throw ($_.Exception.GetBaseException()) }
            if (-not $done) { throw "Connection to ${HostName}:$Port timed out after $TimeoutMs ms." }
            $tcp.ReceiveTimeout = $TimeoutMs; $tcp.SendTimeout = $TimeoutMs
            # Accept every certificate: this is an inventory of certificates, not a trust decision. The synchronous
            # handshake runs the callback on this thread; the certificate is read from RemoteCertificate afterwards.
            $accept = [System.Net.Security.RemoteCertificateValidationCallback] { param($s, $c, $ch, $e) $true }
            $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false, $accept)
            $ssl.ReadTimeout = $TimeoutMs; $ssl.WriteTimeout = $TimeoutMs
            $ssl.AuthenticateAsClient($HostName)
            if (-not $ssl.RemoteCertificate) { throw 'No certificate presented.' }
            return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($ssl.RemoteCertificate)
        }
        finally {
            if ($ssl) { $ssl.Dispose() }
            $tcp.Dispose()
        }
    }
}

$certCfg = if ($Context.Operations -and $Context.Operations.certificates) { $Context.Operations.certificates } else { @{} }
if ($WarningDays -le 0) { $WarningDays = if ($certCfg.warningDays) { [int]$certCfg.warningDays } else { 60 } }
$criticalDays = if ($certCfg.criticalDays) { [int]$certCfg.criticalDays } else { 30 }

# --- Endpoints -------------------------------------------------------------------------------------------------
$hostRx = '^(?=.{1,253}(:|$))[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*(?::(?<port>[0-9]{1,5}))?$'
$extra = @()
if ($AdditionalEndpoints) {
    $lines = @($AdditionalEndpoints -split '[\r\n,]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($lines.Count -gt 50) { throw "Too many additional endpoints ($($lines.Count)); the maximum is 50." }
    foreach ($l in $lines) {
        $m = [regex]::Match($l, $hostRx)
        if (-not $m.Success) { throw "Invalid endpoint '$l'. Use host or host:port (letters, digits, dots, hyphens)." }
        $port = if ($m.Groups['port'].Success) { [int]$m.Groups['port'].Value } else { 443 }
        if ($port -lt 1 -or $port -gt 65535) { throw "Invalid port in endpoint '$l' (1-65535)." }
        $extra += [pscustomobject]@{ Host = ($l -replace ':[0-9]+$', '').ToLowerInvariant(); Port = $port; Type = 'Additional' }
    }
}

$vi = $Context.VIServer
if (-not $vi) { throw 'No vCenter session (the item requires a vCenter connection).' }
$vcName = if ($Context.Site -and $Context.Site.vcenter) { [string]$Context.Site.vcenter } else { [string]$vi.Name }
$targets = [System.Collections.Generic.List[object]]::new()
$targets.Add([pscustomobject]@{ Host = $vcName.ToLowerInvariant(); Port = 443; Type = 'vCenter' })
foreach ($h in (@(Get-View -Server $vi -ViewType HostSystem -Property Name) | Sort-Object Name)) {
    $targets.Add([pscustomobject]@{ Host = ([string]$h.Name).ToLowerInvariant(); Port = 443; Type = 'ESXi' })
}
foreach ($e in $extra) { $targets.Add($e) }
$seen = @{}
$targets = @($targets | Where-Object { $k = "$($_.Host):$($_.Port)"; if ($seen.ContainsKey($k)) { $false } else { $seen[$k] = 1; $true } })
Write-JobLog -Level STEP "Probing $($targets.Count) endpoint(s) (warning <= $WarningDays days, critical <= $criticalDays days)"

# --- Probe -----------------------------------------------------------------------------------------------------
$now = (Get-Date).ToUniversalTime()
$rows = foreach ($t in $targets) {
    $endpoint = "$($t.Host):$($t.Port)"
    try {
        $cert = Get-PortalTlsCertificate -HostName $t.Host -Port $t.Port -TimeoutMs 5000
        $notAfter = ([datetime]$cert.NotAfter).ToUniversalTime()
        $days = [math]::Floor(($notAfter - $now).TotalDays)
        $status = if ($notAfter -lt $now) { 'EXPIRED' } elseif ($days -le $criticalDays) { 'CRITICAL' } elseif ($days -le $WarningDays) { 'EXPIRING' } else { 'OK' }
        [ordered]@{ Endpoint = $endpoint; Type = $t.Type; Subject = [string]$cert.Subject; Issuer = [string]$cert.Issuer
                    NotAfter = $notAfter.ToString('yyyy-MM-dd'); DaysLeft = $days; Status = $status; Thumbprint = [string]$cert.Thumbprint; Detail = '' }
    }
    catch {
        $msg = $_.Exception.GetBaseException().Message
        Write-JobLog -Level WARN "${endpoint}: $msg"
        [ordered]@{ Endpoint = $endpoint; Type = $t.Type; Subject = ''; Issuer = ''; NotAfter = ''; DaysLeft = ''; Status = 'ERROR'; Thumbprint = ''; Detail = $msg }
    }
}
$rows = @($rows | Sort-Object @{ Expression = { switch ($_.Status) { 'EXPIRED' { 0 } 'CRITICAL' { 1 } 'ERROR' { 2 } 'EXPIRING' { 3 } default { 4 } } } }, @{ Expression = { $_.Endpoint } })

# --- Report ----------------------------------------------------------------------------------------------------
$count = { param($s) @($rows | Where-Object { $_.Status -eq $s }).Count }
$summary = [ordered]@{
    'Endpoints' = $rows.Count; 'OK' = (& $count 'OK'); 'Expiring' = (& $count 'EXPIRING'); 'Critical' = (& $count 'CRITICAL')
    'Expired' = (& $count 'EXPIRED'); 'Unreachable' = (& $count 'ERROR')
}
$sections = @(
    New-PortalReportSection -Title 'Certificates' -Rows $rows -Columns Endpoint, Type, Subject, Issuer, NotAfter, DaysLeft, Status, Thumbprint, Detail `
        -Note "EXPIRING <= $WarningDays days, CRITICAL <= $criticalDays days. Probed by TLS handshake from the portal server."
)
$files = New-PortalReport -Title "Certificate expiry - $Site" -Subtitle "vCenter $vcName" -Context $Context -Sections $sections -Summary $summary -FileName 'certificate-expiry'
Write-JobLog -Level OK "Report written: $($files[0].name)"

return [ordered]@{
    Site        = $Site
    Endpoints   = $rows.Count
    Ok          = $summary['OK']
    Expiring    = $summary['Expiring']
    Critical    = $summary['Critical']
    Expired     = $summary['Expired']
    Unreachable = $summary['Unreachable']
    Report      = $files[0].name
    NextSteps   = @('Renew EXPIRED / CRITICAL certificates first.', 'Email warnings before expiry are future work (notifications).')
}
