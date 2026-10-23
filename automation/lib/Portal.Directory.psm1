#Requires -Version 7.2
<#
.SYNOPSIS
    Portal.Directory - Active Directory operations for catalog items (computer objects and OUs) over LDAP
    (System.DirectoryServices.Protocols, same transport security as the sign-in providers: LDAPS / StartTLS /
    Kerberos signing on Windows). No RSAT / ActiveDirectory module needed, works on Linux.
.DESCRIPTION
    The directory is one of the identity providers configured in Admin > Identity (flavor 'ad'): hosts, port,
    security and base DN come from there. The account comes from the request (vault credential with the rights to
    move computer objects), never from the provider's sign-in bind account.
    Connect-PortalDirectory returns an object with Search / Move script methods so tests can replace it.
#>

Set-StrictMode -Version Latest

function Get-PortalDirectoryProvider {
    <# The AD identity provider by id (enabled, flavor ad). #>
    [CmdletBinding()] param([Parameter(Mandatory)] [string] $Id)
    $root = Get-PortalRoot
    if (-not (Get-Command Get-PortalIdentityProvider -ErrorAction SilentlyContinue)) { Import-Module (Join-Path $root 'modules/Portal.Identity.psm1') -Force -Global -DisableNameChecking }
    $p = Get-PortalIdentityProvider -Id $Id -EnabledOnly | Select-Object -First 1
    if (-not $p) { throw "Directory '$Id' is not an enabled identity provider (Admin > Identity)." }
    if ($p.flavor -ne 'ad') { throw "Directory '$Id' is not Active Directory (flavor $($p.flavor))." }
    return $p
}

function Connect-PortalDirectory {
    <#
    .SYNOPSIS Binds to the directory with the given credential. Returns @{ Provider; BaseDn; Search(base, filter, scope, attrs); Move(dn, newParentDn); Close() }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ProviderId, [Parameter(Mandatory)] [pscredential] $Credential)
    $p = Get-PortalDirectoryProvider -Id $ProviderId
    $conn = New-PortalLdapConnection -Provider $p
    try { Invoke-PortalLdapBind -Connection $conn -Provider $p -User $Credential.UserName -Password $Credential.GetNetworkCredential().Password }
    catch { $m = Get-PortalLdapErrorMessage -Exception $_.Exception; throw "Directory $($p.id): $($m.message)" }
    $o = [pscustomobject]@{ Provider = $p; BaseDn = [string]$p.baseDn; Connection = $conn }
    $o | Add-Member ScriptMethod Search {
        param([string] $Base, [string] $Filter, [string] $Scope = 'Subtree', [string[]] $Attributes = @('distinguishedName'), [int] $SizeLimit = 1000)
        @(Get-PortalLdapEntry -Connection $this.Connection -BaseDn $Base -Filter $Filter -Attributes $Attributes -SizeLimit $SizeLimit -Scope $Scope) | ForEach-Object {
            $e = $_; $h = [ordered]@{ dn = [string]$e.DistinguishedName }
            foreach ($a in $Attributes) { $v = @(Get-PortalLdapValue -Entry $e -Name $a); $h[$a] = $(if ($v.Count -eq 1) { $v[0] } else { $v }) }
            [pscustomobject]$h
        }
    }
    $o | Add-Member ScriptMethod Move {
        param([string] $Dn, [string] $NewParentDn)
        $rdn = ($Dn -split '(?<!\\),', 2)[0]
        $req = [System.DirectoryServices.Protocols.ModifyDNRequest]::new($Dn, $NewParentDn, $rdn)
        $req.DeleteOldRdn = $true
        $null = $this.Connection.SendRequest($req)
    }
    $o | Add-Member ScriptMethod Close { try { $this.Connection.Dispose() } catch { } }
    return $o
}

function ConvertTo-PortalDirectoryFilterValue {
    <# RFC 4515 escaping. #>
    param([string] $Value)
    return (($Value -replace '\\', '\5c') -replace '\*', '\2a' -replace '\(', '\28' -replace '\)', '\29' -replace "`0", '\00')
}

function Get-PortalDirectoryParent { param([string] $Dn) return ($Dn -split '(?<!\\),', 2)[1] }

Export-ModuleMember -Function Get-PortalDirectoryProvider, Connect-PortalDirectory, ConvertTo-PortalDirectoryFilterValue, Get-PortalDirectoryParent
