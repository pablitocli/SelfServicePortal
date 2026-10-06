#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - installs the APPROVED packages of a software baseline set (config/software.json) in a VM.
.DESCRIPTION
    Runs inside the guest through VMware Tools guest operations (automation/lib/Portal.Guest.psm1); no WinRM / SSH.
    Also called directly by the three-tier blueprint, so the parameter names are a contract.

    Only packages with status Approved are installed. Pending / Retired packages are skipped and listed in the result
    as "Not installed: <name> (<status>)" - this keeps e.g. the backup agent out until a product is approved.
    A set with no approved package succeeds with a warning.

    Per package (idempotent): verify -> skip when already present -> install -> verify again.
      Source     installer relative to repository.windowsBase / linuxBase, or an absolute UNC path / URL / path.
                 Windows reads UNC sources as the guest credential user (domain account with read access);
                 URLs are downloaded to a guest temp folder first.
      Install    .msi  msiexec /i <src> <installArgs> /l*v <temp log>   (0, 1641, 3010 = success; 3010/1641 = reboot)
                 .exe  Start-Process <src> <installArgs> -Wait            (0, 3010 = success)
                 .rpm  dnf install -y <src> <installArgs>                 (URL or path)
                 .sh   bash <src> <installArgs>                           (downloaded with curl when it is a URL)
      Verify     service (exists and running), file (exists), command (exit code 0), package (Get-Package / rpm -q).
    installArgs and verify values come from the software data file (Admin > Data files), maintained by admins.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] [string] $VMName,
    [Parameter(Mandatory)] [string] $BaselineSet,
    [Parameter(Mandatory)] [pscredential] $GuestCredential,
    [string] $ChangeTicket,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}
Import-Module (Join-Path $Context.PortalRoot 'automation/lib/Portal.Guest.psm1') -Force -DisableNameChecking

$vi = $Context.VIServer
function Q([string] $v) { ConvertTo-PortalGuestLiteral -Value $v }
function BQ([string] $v) { ConvertTo-PortalBashLiteral -Value $v }
function P($o, [string] $k, $d = '') { if ($o -is [System.Collections.IDictionary] -and $o.Contains($k) -and $null -ne $o[$k]) { $o[$k] } else { $d } }

#region Pre-checks ---------------------------------------------------------------------------------------------
Write-JobLog -Level STEP "Loading baseline set '$BaselineSet'"
$set = @(Get-PortalSoftwareSet -Id $BaselineSet) | Select-Object -First 1
if (-not $set) { throw "Baseline set '$BaselineSet' does not exist in the software repository (Admin > Data files > software)." }
$skipped  = @(@($set.skipped) | ForEach-Object { "Not installed: $($_.name) ($($_.status))" })
$packages = @($set.packages)
$skipped | ForEach-Object { Write-JobLog -Level WARN $_ }
Write-JobLog "Set '$($set.name)' ($($set.os)): $($packages.Count) approved, $($skipped.Count) skipped"

$g = Resolve-PortalGuestVM -Name $VMName -Server $vi -ExpectedFamily any
if (-not $g.Family) { throw "Cannot determine the guest OS family of $VMName from VMware Tools." }
if ($g.Family -ne $set.os) { throw "Baseline set '$BaselineSet' is for $($set.os) but $VMName runs $($g.Family) ($($g.OSFullName))." }
$vm = $g.VM

if (-not $packages.Count) {
    Write-JobLog -Level WARN "Set '$BaselineSet' has no approved package: nothing to install."
    return [ordered]@{ VMName = $VMName; BaselineSet = $BaselineSet; Installed = @(); AlreadyPresent = @(); Skipped = $skipped
                       NextSteps = @('No package of this set is approved yet. Approve packages in Admin > Data files > software, then run the item again.') }
}

$repo = $set.repository
$bad = @()
foreach ($p in $packages) {
    $v = P $p 'verify' @{}
    $ext = [IO.Path]::GetExtension([string]$p.installer).ToLowerInvariant()
    $okExt = if ($set.os -eq 'windows') { @('.msi', '.exe') } else { @('.rpm', '.sh') }
    if ($okExt -notcontains $ext) { $bad += "$($p.name): installer type '$ext' is not supported for $($set.os) ($($okExt -join ', '))" }
    if (-not (P $v 'value') -or [string](P $v 'value') -like 'TBD*') { $bad += "$($p.name): verify.value is not set" }
    if ([string]$p.installer -like 'TBD*') { $bad += "$($p.name): installer is not set" }
}
if ($bad) { throw "Approved package(s) are not complete in the software repository: $($bad -join '; ')." }
#endregion

function Resolve-Source($p) {
    $inst = [string]$p.installer
    if ($inst -match '^(\\\\|[A-Za-z]:\\|https?://|/)') { return $inst }
    if ($set.os -eq 'windows') {
        $base = [string](P $repo 'windowsBase')
        if (-not $base -or $base -like 'TBD*') { throw 'repository.windowsBase is not set in the software repository.' }
        if ($base -match '^https?://') { return $base.TrimEnd('/') + '/' + $inst.Replace('\', '/').TrimStart('/') }
        return $base.TrimEnd('\') + '\' + $inst.Replace('/', '\').TrimStart('\')
    }
    $base = [string](P $repo 'linuxBase')
    if (-not $base -or $base -like 'TBD*') { throw 'repository.linuxBase is not set in the software repository.' }
    return $base.TrimEnd('/') + '/' + $inst.TrimStart('/')
}

function New-WindowsPackageScript($p, [string] $src) {
    $v = P $p 'verify' @{}
    $vt = [string](P $v 'type'); $vv = [string](P $v 'value')
    $ext = [IO.Path]::GetExtension([string]$p.installer).ToLowerInvariant()
    @"
function Test-Pkg {
    switch ($(Q $vt)) {
        'service' { `$s = Get-Service -Name $(Q $vv) -ErrorAction SilentlyContinue; return [bool](`$s -and `$s.Status -eq 'Running') }
        'file'    { return [bool](Test-Path -LiteralPath $(Q $vv)) }
        'command' { `$null = & powershell.exe -NoProfile -NonInteractive -Command $(Q $vv) 2>&1; return (`$LASTEXITCODE -eq 0) }
        'package' { return [bool](Get-Package -Name $(Q $vv) -ErrorAction SilentlyContinue) }
    }
    return `$false
}
if (Test-Pkg) { Write-Output '__SSP_KV:State=AlreadyPresent'; return }
`$tmp = Join-Path `$env:TEMP ('ssp-pkg-' + [guid]::NewGuid().ToString('N'))
`$null = New-Item -ItemType Directory -Path `$tmp -Force
`$log = `$null
try {
    `$src = $(Q $src)
    if (`$src -match '^https?://') {
        `$local = Join-Path `$tmp (Split-Path -Leaf ([uri]`$src).AbsolutePath)
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri `$src -OutFile `$local -UseBasicParsing
        `$src = `$local
    }
    elseif (-not (Test-Path -LiteralPath `$src)) { throw ('Installer not reachable from the guest: ' + `$src) }
    `$iargs = $(Q ([string](P $p 'installArgs')))
    if ($(Q $ext) -eq '.msi') {
        `$log = Join-Path `$env:WINDIR ('Temp\ssp-' + $(Q $p.id) + '.log')
        `$p = Start-Process -FilePath 'msiexec.exe' -ArgumentList ('/i "' + `$src + '" ' + `$iargs + ' /l*v "' + `$log + '"') -Wait -PassThru
        `$ok = @(0, 1641, 3010)
    }
    else {
        if (`$iargs) { `$p = Start-Process -FilePath `$src -ArgumentList `$iargs -Wait -PassThru } else { `$p = Start-Process -FilePath `$src -Wait -PassThru }
        `$ok = @(0, 3010)
    }
    Write-Output ('__SSP_KV:ExitCode=' + `$p.ExitCode)
    if (`$ok -notcontains `$p.ExitCode) { throw ('Installer exit code ' + `$p.ExitCode + `$(if (`$log) { ' (log ' + `$log + ')' })) }
    if (@(1641, 3010) -contains `$p.ExitCode) { Write-Output '__SSP_KV:Reboot=True' }
}
finally { Remove-Item -LiteralPath `$tmp -Recurse -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 5
if (-not (Test-Pkg)) { throw ('Installed, but verification failed (' + $(Q $vt) + ' ' + $(Q $vv) + ').') }
Write-Output '__SSP_KV:State=Installed'
"@
}

function New-LinuxPackageScript($p, [string] $src) {
    $v = P $p 'verify' @{}
    $vt = [string](P $v 'type'); $vv = [string](P $v 'value')
    $ext = [IO.Path]::GetExtension([string]$p.installer).ToLowerInvariant()
    $iargs = [string](P $p 'installArgs')
    $verify = switch ($vt) {
        'service' { "systemctl cat $(BQ $vv) >/dev/null 2>&1 && systemctl is-active --quiet $(BQ $vv)" }
        'file'    { "test -e $(BQ $vv)" }
        'command' { "bash -c $(BQ $vv) >/dev/null 2>&1" }
        'package' { "rpm -q $(BQ $vv) >/dev/null 2>&1" }
    }
    $install = if ($ext -eq '.rpm') {
        "dnf install -y $(BQ $src) $iargs"
    }
    else {
        @"
if [[ $(BQ $src) =~ ^https?:// ]]; then curl -fsSL -o "`$tmp/installer.sh" $(BQ $src); else cp $(BQ $src) "`$tmp/installer.sh"; fi
bash "`$tmp/installer.sh" $iargs
"@
    }
    @"
pkg_ok() { $verify; }
if pkg_ok; then echo '__SSP_KV:State=AlreadyPresent'; exit 0; fi
tmp=`$(mktemp -d /tmp/ssp-pkg-XXXXXXXX)
trap 'rm -rf "`$tmp"' EXIT
$install
sleep 5
if ! pkg_ok; then echo 'Installed, but verification failed ($vt)'; exit 3; fi
echo '__SSP_KV:State=Installed'
"@
}

#region Install -------------------------------------------------------------------------------------------------
$installed = @(); $present = @(); $failed = @(); $reboot = $false
foreach ($p in $packages) {
    $label = "$($p.name) $(P $p 'version')".Trim()
    try {
        $src = Resolve-Source $p
        Write-JobLog -Level STEP "Package $label <- $src"
        $gs = if ($set.os -eq 'windows') { New-WindowsPackageScript $p $src } else { New-LinuxPackageScript $p $src }
        $out = Invoke-PortalGuestScript -VM $vm -Server $vi -Credential $GuestCredential -ScriptText $gs `
            -Type $(if ($set.os -eq 'windows') { 'PowerShell' } else { 'Bash' }) -TimeoutSeconds 1800 -Description "install $($p.id)"
        $d = Get-PortalGuestData -Output $out
        if ($d['Reboot'] -eq 'True') { $reboot = $true }
        if ($d['State'] -eq 'AlreadyPresent') { $present += $label; Write-JobLog -Level OK "$label already present" }
        else { $installed += $label; Write-JobLog -Level OK "$label installed" }
    }
    catch {
        $failed += "$label - $($_.Exception.Message -replace '\s+', ' ')"
        Write-JobLog -Level ERROR "$label failed: $($_.Exception.Message)"
    }
}
if ($failed) {
    throw "$($failed.Count) of $($packages.Count) package(s) failed on ${VMName}: $($failed -join ' | '). Installed: $(if ($installed) { $installed -join ', ' } else { 'none' }); already present: $(if ($present) { $present -join ', ' } else { 'none' })."
}
#endregion

$next = @()
if ($reboot) { $next += "Restart $VMName to complete the agent installation (installer requested a reboot)." }
if ($skipped) { $next += 'Skipped packages are installed automatically on a later run once approved in the software repository.' }
return [ordered]@{
    VMName         = $VMName
    BaselineSet    = $BaselineSet
    Installed      = @($installed)
    AlreadyPresent = @($present)
    Skipped        = @($skipped)
    RebootRequired = $reboot
    NextSteps      = @($next)
}
