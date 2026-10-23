#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - ensures accounts / groups are members of the local Administrators and / or Remote Desktop
    Users groups on one or more Windows VMs (through VMware Tools, vault credential).
.DESCRIPTION
    Groups are addressed by their well-known SID (S-1-5-32-544 Administrators, S-1-5-32-555 Remote Desktop Users),
    so localized Windows editions work. Membership is read with ADSI (works with orphaned SIDs). Missing accounts
    are added; nothing is ever removed. ReportOnly lists what is present / missing without changing anything.
    Accounts: DOMAIN\name (user or group) or a local account name.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] [string] $VMNames,
    [Parameter(Mandatory)] [ValidateSet('Administrators', 'RemoteDesktopUsers', 'Both')] [string] $Group,
    [Parameter(Mandatory)] [string] $Accounts,
    [Parameter(Mandatory)] [pscredential] $GuestCredential,
    [bool] $ReportOnly = $false,
    [string] $ChangeTicket,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}
Import-Module (Join-Path $Context.PortalRoot 'automation/lib/Portal.Guest.psm1') -Force -DisableNameChecking
$vi = $Context.VIServer

$vmList = @($VMNames -split '[,;\s]+' | Where-Object { $_ } | Select-Object -Unique)
if (-not $vmList.Count) { throw 'List at least one VM.' }
if ($vmList.Count -gt 50) { throw "At most 50 VMs per request ($($vmList.Count) given)." }
$acctList = @($Accounts -split '[,;\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
if (-not $acctList.Count) { throw 'List at least one account or group.' }
foreach ($a in $acctList) {
    if ($a -notmatch '^([A-Za-z0-9][A-Za-z0-9._-]{0,63}\\)?[A-Za-z0-9][A-Za-z0-9 ._$-]{0,103}$') { throw "Account '$a' is not valid (use DOMAIN\name or a local name)." }
}
$sids = switch ($Group) { 'Administrators' { @('S-1-5-32-544') } 'RemoteDesktopUsers' { @('S-1-5-32-555') } default { @('S-1-5-32-544', 'S-1-5-32-555') } }

# One guest script per VM: report (and add) membership for each group SID.
$lit = { param($s) ConvertTo-PortalGuestLiteral $s }
$script = @"
`$accounts = @($((@($acctList) | ForEach-Object { & $lit $_ }) -join ', '))
`$sids = @($((@($sids) | ForEach-Object { & $lit $_ }) -join ', '))
`$reportOnly = `$$($ReportOnly.ToString().ToLower())
`$cn = `$env:COMPUTERNAME
foreach (`$sid in `$sids) {
    `$gname = (New-Object System.Security.Principal.SecurityIdentifier(`$sid)).Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]
    `$g = [ADSI]("WinNT://`$cn/`$gname,group")
    `$members = @(`$g.psbase.Invoke('Members') | ForEach-Object {
        `$p = [string]`$_.GetType().InvokeMember('ADsPath', 'GetProperty', `$null, `$_, `$null)
        `$seg = @((`$p -replace '^WinNT://', '') -split '/')
        if (`$seg.Count -ge 2) { (`$seg[-2] + '\' + `$seg[-1]).ToLower() } else { `$seg[-1].ToLower() }
    })
    foreach (`$a in `$accounts) {
        `$full = if (`$a -match '\\') { `$a } else { "`$cn\`$a" }
        if (`$members -contains `$full.ToLower()) { Write-Output "RES|`$gname|`$a|PRESENT|"; continue }
        if (`$reportOnly) { Write-Output "RES|`$gname|`$a|MISSING|"; continue }
        try { `$g.Add('WinNT://' + (`$full -replace '\\', '/')); Write-Output "RES|`$gname|`$a|ADDED|" }
        catch { Write-Output ("RES|`$gname|`$a|FAILED|" + (`$_.Exception.InnerException.Message, `$_.Exception.Message | Where-Object { `$_ } | Select-Object -First 1)) }
    }
}
"@

$rows = [System.Collections.Generic.List[object]]::new()
$failedVms = [System.Collections.Generic.List[string]]::new()
foreach ($name in $vmList) {
    Write-JobLog -Level STEP "$name"
    try {
        $g = Resolve-PortalGuestVM -Name $name -Server $vi -ExpectedFamily windows -TimeoutSeconds 120
        $out = Invoke-PortalGuestScript -VM $g.VM -Credential $GuestCredential -ScriptText $script -Server $vi -TimeoutSeconds 300 -Description "local groups ($Group)"
        foreach ($l in @($out -split "\r?\n" | Where-Object { $_ -like 'RES|*' })) {
            $f = $l.Split('|', 6)
            $st = switch ($f[3]) { 'PRESENT' { 'OK present' } 'ADDED' { 'OK added' } 'MISSING' { 'WARN missing' } default { "FAIL $($f[4])" } }
            $rows.Add([ordered]@{ VM = $name; Group = $f[1]; Account = $f[2]; Status = $st })
            if ($f[3] -eq 'FAILED') { Write-JobLog -Level WARN "${name}: $($f[2]) -> $($f[1]) failed: $($f[4])" }
        }
        Write-JobLog -Level OK "${name}: $(@($rows | Where-Object { $_.VM -eq $name -and $_.Status -eq 'OK added' }).Count) added"
    }
    catch {
        $failedVms.Add($name)
        $rows.Add([ordered]@{ VM = $name; Group = $Group; Account = ''; Status = "FAIL $($_.Exception.Message)" })
        Write-JobLog -Level ERROR "${name}: $($_.Exception.Message)"
    }
}

$added = @($rows | Where-Object { $_.Status -eq 'OK added' }).Count
$failed = @($rows | Where-Object { $_.Status -like 'FAIL*' }).Count
$files = New-PortalReport -Title "Local group membership$(if ($ReportOnly) { ' (report only)' })" -Subtitle "$Site - $Group" -Context $Context -FileName 'local-groups' -Sections @(
    New-PortalReportSection -Title 'Membership' -Columns 'VM', 'Group', 'Account', 'Status' -Rows $rows) -Summary ([ordered]@{ VMs = $vmList.Count; Added = $added; Missing = @($rows | Where-Object Status -eq 'WARN missing').Count; Failed = $failed })
if ($failed -and $failed -eq $rows.Count) { throw "No VM could be updated: $(@($rows | Select-Object -First 1).Status)" }
$r = [ordered]@{ VMs = $vmList.Count; Group = $Group; Added = $added; AlreadyPresent = @($rows | Where-Object Status -eq 'OK present').Count; Failed = $failed; Report = $files[0].name; ChangeTicket = $ChangeTicket }
if ($ReportOnly) { $r['Missing'] = @($rows | Where-Object Status -eq 'WARN missing' | ForEach-Object { "$($_.VM): $($_.Account) -> $($_.Group)" }) }
if ($failed) { $r['FailedItems'] = @($rows | Where-Object { $_.Status -like 'FAIL*' } | ForEach-Object { "$($_.VM) $($_.Account): $($_.Status)" }) }
return $r
