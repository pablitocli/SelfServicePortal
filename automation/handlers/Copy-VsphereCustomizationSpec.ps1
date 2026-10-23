#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - copies an OS customization spec from one site's vCenter to another and sets the passwords
    vCenter does not export (local Administrator, optional domain join account) from the vault.
.DESCRIPTION
    vCenter never returns the stored passwords of a spec, so the copy gets them from vault entries chosen in the
    request. An existing spec with the same name on the target is replaced only when Overwrite is set (its previous
    definition is exported to the request folder first, without passwords).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SourceSite,
    [Parameter(Mandatory)] [string] $TargetSite,
    [Parameter(Mandatory)] [string] $SpecName,
    [string] $NewName,
    [Parameter(Mandatory)] [pscredential] $AdminPassword,
    [pscredential] $DomainJoinCredential,
    [bool] $Overwrite = $false,
    [string] $ChangeTicket,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}
if ($SourceSite -eq $TargetSite) { throw 'Source and target sites must be different.' }
foreach ($n in @($SpecName, $NewName) | Where-Object { $_ }) { if ($n -notmatch '^[A-Za-z0-9][A-Za-z0-9 ._()-]{0,79}$') { throw "Spec name '$n' is not valid." } }
$name = if ($NewName) { $NewName } else { $SpecName }
$src = $Context.VIServer
$spec = Get-OSCustomizationSpec -Name $SpecName -Server $src -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $spec) { throw "Customization spec '$SpecName' was not found in $SourceSite." }
if ([string]$spec.OSType -ne 'Windows' -and $DomainJoinCredential) { throw 'A domain join account only applies to Windows specs.' }

$tgt = $null
try {
    Write-JobLog -Level STEP "Connecting to $TargetSite"
    $tgt = Connect-PortalVIServer -SiteCode $TargetSite
    $existing = Get-OSCustomizationSpec -Name $name -Server $tgt -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existing) {
        if (-not $Overwrite) { throw "A spec named '$name' already exists in $TargetSite (set Overwrite to replace it)." }
        $null = New-Item -ItemType Directory -Path $Context.ReportDir -Force
        $existing | Select-Object Name, Description, OSType, Type, FullName, OrgName, NamingScheme, NamingPrefix, Domain, Workgroup, TimeZone, ChangeSid, AutoLogonCount |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Context.ReportDir ("previous-spec-" + ($name -replace '[^A-Za-z0-9_-]', '_') + '.json')) -Encoding utf8
        Remove-OSCustomizationSpec -OSCustomizationSpec $existing -Server $tgt -Confirm:$false
        Write-JobLog -Level WARN "Existing spec '$name' in $TargetSite replaced (previous settings saved to the request)."
    }
    $new = New-OSCustomizationSpec -OSCustomizationSpec $spec -Name $name -Server $tgt
    $set = @{ OSCustomizationSpec = $new; Server = $tgt; Confirm = $false }
    if ([string]$spec.OSType -eq 'Windows') {
        $set['AdminPassword'] = $AdminPassword.GetNetworkCredential().Password
        if ($DomainJoinCredential) { $set['DomainUsername'] = $DomainJoinCredential.UserName; $set['DomainPassword'] = $DomainJoinCredential.GetNetworkCredential().Password }
    }
    $null = Set-OSCustomizationSpec @set
    Write-JobLog -Level OK "Spec '$name' created in $TargetSite with the passwords from the vault."
}
catch {
    $m = $_.Exception.Message
    foreach ($s in @($AdminPassword.GetNetworkCredential().Password, $(if ($DomainJoinCredential) { $DomainJoinCredential.GetNetworkCredential().Password }))) { if ($s -and $s.Length -ge 4) { $m = $m.Replace($s, '********') } }
    throw $m
}
finally { if ($tgt) { Disconnect-PortalVIServer -Server $tgt } }
return [ordered]@{ Spec = $name; From = "$SourceSite / $SpecName"; To = $TargetSite; OSType = [string]$spec.OSType; Replaced = [bool]$existing; DomainAccountSet = [bool]$DomainJoinCredential; ChangeTicket = $ChangeTicket }
