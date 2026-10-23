#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - moves Active Directory computer objects to an OU (LDAP, no RSAT needed).
.DESCRIPTION
    Directory = an AD identity provider of the portal (Admin > Identity); the move runs with the vault credential
    chosen in the request (rights to move computer objects). The target OU must exist under the directory base DN.
    Computers are found by sAMAccountName (NAME$); objects already in the OU are skipped. Each move is logged with the
    previous OU so it can be reverted.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Directory,
    [Parameter(Mandatory)] [string] $ComputerNames,
    [Parameter(Mandatory)] [string] $TargetOU,
    [Parameter(Mandatory)] [pscredential] $DirectoryCredential,
    [string] $ChangeTicket,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}
if (-not (Get-Command Connect-PortalDirectory -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $Context.PortalRoot 'modules/Portal.Identity.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $Context.PortalRoot 'automation/lib/Portal.Directory.psm1') -Force -DisableNameChecking
}

$names = @($ComputerNames -split '[,;\s]+' | Where-Object { $_ } | ForEach-Object { ($_ -split '\.')[0].ToUpperInvariant() } | Select-Object -Unique)
if (-not $names.Count) { throw 'List at least one computer name.' }
if ($names.Count -gt 200) { throw "At most 200 computers per request ($($names.Count) given)." }
foreach ($n in $names) { if ($n -notmatch '^[A-Z0-9][A-Z0-9-]{0,14}$') { throw "'$n' is not a valid computer name (NetBIOS, max 15 characters)." } }
if ($TargetOU -notmatch '^(?i)OU=.+,DC=[^,]+') { throw "Target OU '$TargetOU' must be an OU distinguished name (OU=...,DC=...)." }

$d = Connect-PortalDirectory -ProviderId $Directory -Credential $DirectoryCredential
try {
    if ($TargetOU -notmatch ([regex]::Escape($d.BaseDn) + '$')) { throw "Target OU is outside the directory base DN $($d.BaseDn)." }
    $ou = @($d.Search($TargetOU, '(objectClass=organizationalUnit)', 'Base', @('distinguishedName'), 1))
    if (-not $ou.Count) { throw "OU '$TargetOU' was not found in $Directory." }
    Write-JobLog -Level STEP "Moving $($names.Count) computer object(s) to $TargetOU ($Directory)"
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($n in $names) {
        try {
            $f = '(&(objectCategory=computer)(sAMAccountName=' + (ConvertTo-PortalDirectoryFilterValue "$n`$") + '))'
            $obj = @($d.Search($d.BaseDn, $f, 'Subtree', @('distinguishedName'), 2))
            if (-not $obj.Count) { $rows.Add([ordered]@{ Computer = $n; From = ''; Status = 'ERROR not found in the directory' }); continue }
            if ($obj.Count -gt 1) { $rows.Add([ordered]@{ Computer = $n; From = ''; Status = 'ERROR more than one object' }); continue }
            $from = Get-PortalDirectoryParent $obj[0].dn
            if ($from -ieq $TargetOU) { $rows.Add([ordered]@{ Computer = $n; From = $from; Status = 'OK already in the OU' }); continue }
            $d.Move($obj[0].dn, $TargetOU)
            $rows.Add([ordered]@{ Computer = $n; From = $from; Status = 'OK moved' })
            Write-JobLog -Level OK "$n moved from $from"
        }
        catch { $rows.Add([ordered]@{ Computer = $n; From = ''; Status = "ERROR $($_.Exception.Message)" }); Write-JobLog -Level WARN "${n}: $($_.Exception.Message)" }
    }
}
finally { $d.Close() }

$files = New-PortalReport -Title 'Computer objects moved' -Subtitle "$Directory -> $TargetOU" -Context $Context -FileName 'ad-move' -Sections @(
    New-PortalReportSection -Title 'Result' -Columns 'Computer', 'From', 'Status' -Rows $rows -Note 'From = previous OU (to revert, move back to it).')
$errs = @($rows | Where-Object { $_.Status -like 'ERROR*' })
if ($errs.Count -eq $rows.Count) { throw "No object was moved: $(@($errs | ForEach-Object { "$($_.Computer) $($_.Status)" }) -join '; ')" }
return [ordered]@{
    Directory = $Directory; TargetOU = $TargetOU
    Moved = @($rows | Where-Object Status -eq 'OK moved').Count; AlreadyThere = @($rows | Where-Object Status -eq 'OK already in the OU').Count; Failed = $errs.Count
    Details = @($rows | ForEach-Object { "$($_.Computer): $($_.Status)$(if ($_.From) { " (was $($_.From))" })" }); Report = $files[0].name; ChangeTicket = $ChangeTicket
}
