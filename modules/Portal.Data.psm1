#Requires -Version 7.2
<#
.SYNOPSIS
    Portal.Data - editable data files used by catalog items (Admin > Data files).
.DESCRIPTION
    config/<file>.json is created from config/<file>.default.json at first start and is never overwritten by upgrades.
      software          software.json           software repository: packages (Approved / Pending / Retired) and baseline sets
      versionBaseline   version-baseline.json   target builds for vCenter / ESXi / VMware Tools / VM hardware + advisories
      hardeningBaseline hardening-baseline.json security configuration checks (ESXi advanced settings, services, VM settings)
      backup            backup.json             backup policies and connector (default: vSphere tag, vendor-agnostic)
    Only Core is required, so job runners can import this module.
#>

Set-StrictMode -Version Latest

$script:Files = [ordered]@{
    software          = 'software'
    versionBaseline   = 'version-baseline'
    hardeningBaseline = 'hardening-baseline'
    backup            = 'backup'
}
$script:Titles = @{
    software          = 'Software repository'
    versionBaseline   = 'Version baseline'
    hardeningBaseline = 'Hardening baseline'
    backup            = 'Backup policies'
}

function Get-DV { param($T, [string] $K, $D = $null) if ($T -is [System.Collections.IDictionary] -and $T.Contains($K) -and $null -ne $T[$K]) { $T[$K] } else { $D } }

function Get-PortalDataFilePath {
    param([Parameter(Mandatory)] [string] $Name, [switch] $Default)
    if (-not $script:Files.Contains($Name)) { throw "Unknown data file '$Name' ($($script:Files.Keys -join ', '))." }
    $dir = Join-Path (Get-PortalRoot) 'config'
    return (Join-Path $dir ($script:Files[$Name] + $(if ($Default) { '.default.json' } else { '.json' })))
}

function Initialize-PortalDataFiles {
    <# Creates missing config/<file>.json from the shipped defaults (first start / upgrade). #>
    [CmdletBinding()] param()
    foreach ($n in $script:Files.Keys) {
        $dst = Get-PortalDataFilePath -Name $n; $src = Get-PortalDataFilePath -Name $n -Default
        if (-not (Test-Path -LiteralPath $dst) -and (Test-Path -LiteralPath $src)) {
            Copy-Item -LiteralPath $src -Destination $dst
            Write-Host "Created config/$(Split-Path -Leaf $dst) from defaults." -ForegroundColor Yellow
        }
    }
}

function Get-PortalDataFile {
    <# Parsed content of a data file (falls back to the shipped default). #>
    [CmdletBinding()] param([Parameter(Mandatory)] [string] $Name)
    $p = Get-PortalDataFilePath -Name $Name
    if (-not (Test-Path -LiteralPath $p)) { $p = Get-PortalDataFilePath -Name $Name -Default }
    if (-not (Test-Path -LiteralPath $p)) { return [ordered]@{} }
    return (Read-PortalJson -Path $p)
}

function Test-PortalDataFile {
    <# Validation per file type. Returns a list of errors (empty = valid). #>
    [CmdletBinding()] param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] $Content)
    $err = [System.Collections.Generic.List[string]]::new()
    if ($Content -isnot [System.Collections.IDictionary]) { $err.Add('The file must contain a JSON object.'); return $err.ToArray() }
    $idRx = '^[a-z0-9][a-z0-9._-]{1,62}$'
    switch ($Name) {
        'software' {
            $ids = @{}
            foreach ($p in @(Get-DV $Content 'packages' @())) {
                $id = [string](Get-DV $p 'id' '')
                if ($id -notmatch $idRx) { $err.Add("Package id '$id' must be lowercase letters, digits, dot, underscore or hyphen."); continue }
                if ($ids.ContainsKey($id)) { $err.Add("Duplicate package id '$id'.") }; $ids[$id] = $p
                if (@('windows', 'linux') -notcontains (Get-DV $p 'os' '')) { $err.Add("Package '$id': os must be windows or linux.") }
                if (@('Approved', 'Pending', 'Retired') -notcontains (Get-DV $p 'status' '')) { $err.Add("Package '$id': status must be Approved, Pending or Retired.") }
                if (-not (Get-DV $p 'installer')) { $err.Add("Package '$id': installer is required (path relative to the repository base, UNC path or URL).") }
                $v = Get-DV $p 'verify' @{}
                if (@('service', 'file', 'command', 'package') -notcontains (Get-DV $v 'type' '')) { $err.Add("Package '$id': verify.type must be service, file, command or package.") }
            }
            foreach ($s in @(Get-DV $Content 'sets' @())) {
                $sid = [string](Get-DV $s 'id' '')
                if ($sid -notmatch $idRx) { $err.Add("Set id '$sid' is not valid.") }
                foreach ($pkgId in @(Get-DV $s 'packages' @())) {
                    if (-not $ids.ContainsKey($pkgId)) { $err.Add("Set '$sid' references unknown package '$pkgId'.") }
                    elseif ($ids[$pkgId].os -ne (Get-DV $s 'os' '')) { $err.Add("Set '$sid' ($($s.os)) contains package '$pkgId' for $($ids[$pkgId].os).") }
                }
            }
        }
        'versionBaseline' {
            $t = Get-DV $Content 'targets' @{}
            foreach ($k in 'vcenter', 'esxi') { if (-not ((Get-DV (Get-DV $t $k @{}) 'minBuild' $null) -is [ValueType])) { $err.Add("targets.$k.minBuild must be a number (0 = not set).") } }
            foreach ($a in @(Get-DV $Content 'advisories' @())) {
                if ([string](Get-DV $a 'id' '') -notmatch '^[A-Za-z0-9._-]+$') { $err.Add("Advisory id '$(Get-DV $a 'id')' is not valid.") }
                if (@('vcenter', 'esxi') -notcontains (Get-DV $a 'product' '')) { $err.Add("Advisory $(Get-DV $a 'id'): product must be vcenter or esxi.") }
                if (-not ((Get-DV $a 'fixedBuild' $null) -is [ValueType])) { $err.Add("Advisory $(Get-DV $a 'id'): fixedBuild must be a number.") }
            }
        }
        'hardeningBaseline' {
            $ops = 'eq', 'ne', 'le', 'ge', 'range', 'nonEmpty'
            foreach ($section in 'esxiAdvancedSettings', 'vmAdvancedSettings') {
                foreach ($c in @(Get-DV $Content $section @())) {
                    if (-not (Get-DV $c 'id') -or -not (Get-DV $c 'name')) { $err.Add("$section entries need id and name.") }
                    if ($ops -notcontains (Get-DV $c 'operator' 'eq')) { $err.Add("$section $(Get-DV $c 'id'): operator must be one of $($ops -join ', ').") }
                    if ((Get-DV $c 'operator') -eq 'range' -and @(Get-DV $c 'expected' @()).Count -ne 2) { $err.Add("$section $(Get-DV $c 'id'): range needs expected [min, max].") }
                }
            }
            foreach ($s in @(Get-DV $Content 'esxiServices' @())) {
                if (-not (Get-DV $s 'key')) { $err.Add('esxiServices entries need key (e.g. TSM-SSH).') }
            }
        }
        'backup' {
            if (@('vsphereTag') -notcontains (Get-DV $Content 'connector' '')) { $err.Add("connector must be 'vsphereTag' (other connectors are templates until a backup product is approved).") }
            if (-not (Get-DV $Content 'tagCategory')) { $err.Add('tagCategory is required.') }
            $policyIds = @{}
            foreach ($p in @(Get-DV $Content 'policies' @())) {
                $id = [string](Get-DV $p 'id' '')
                if ($id -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,31}$') { $err.Add("Policy id '$id' must be 1-32 letters, digits, _ or - (start with a letter).") }
                if ($policyIds.ContainsKey($id)) { $err.Add("Duplicate policy '$id'.") }; $policyIds[$id] = $true
            }
            if (-not $policyIds.Count) { $err.Add('Define at least one policy.') }
        }
    }
    return $err.ToArray()
}

function Set-PortalDataFile {
    <# Validates and saves a data file (previous version kept in config/_backup). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [string] $Json, [Parameter(Mandatory)] [string] $Actor)
    try { $content = $Json | ConvertFrom-Json -AsHashtable -Depth 30 } catch { throw "Invalid JSON: $($_.Exception.Message)" }
    if ($Json -match '<\s*script') { throw 'Data files cannot contain script tags.' }
    $errs = @(Test-PortalDataFile -Name $Name -Content $content)
    if ($errs) { $ex = [System.InvalidOperationException]::new('The file is not valid.'); $ex.Data['errors'] = $errs; throw $ex }
    $path = Get-PortalDataFilePath -Name $Name
    Invoke-PortalLock -Name "datafile-$Name" -ScriptBlock {
        if (Test-Path -LiteralPath $path) {
            $bak = Join-Path (Split-Path -Parent $path) ('_backup/{0}.{1:yyyyMMddHHmmss}.json' -f [IO.Path]::GetFileNameWithoutExtension($path), (Get-Date))
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $bak) -Force
            Copy-Item -LiteralPath $path -Destination $bak
        }
        Write-PortalJson -Path $path -Value $content
    } | Out-Null
    Write-PortalAudit -Actor $Actor -Action 'datafile.save' -Target $Name
}

function Get-PortalDataFileList {
    [CmdletBinding()] param()
    foreach ($n in $script:Files.Keys) {
        $p = Get-PortalDataFilePath -Name $n
        [ordered]@{ name = $n; title = $script:Titles[$n]; file = "config/$($script:Files[$n]).json"
                    updated = $(if (Test-Path -LiteralPath $p) { (Get-Item -LiteralPath $p).LastWriteTimeUtc.ToString('o') } else { $null })
                    content = Get-PortalDataFile -Name $n }
    }
}

function Get-PortalSoftwareSet {
    <#
    .SYNOPSIS Baseline sets with their APPROVED packages only (Pending / Retired are skipped and reported).
    .OUTPUTS  @{ id; name; os; packages = @(approved); skipped = @(@{ id; status; notes }) }
    #>
    [CmdletBinding()] param([string] $Id, [string] $Os)
    $sw = Get-PortalDataFile -Name software
    $pk = @{}; foreach ($p in @(Get-DV $sw 'packages' @())) { $pk[$p.id] = $p }
    foreach ($s in @(Get-DV $sw 'sets' @())) {
        if ($Id -and $s.id -ne $Id) { continue }
        if ($Os -and $s.os -ne $Os) { continue }
        $approved = @(); $skipped = @()
        foreach ($pkgId in @(Get-DV $s 'packages' @())) {
            $p = $pk[$pkgId]; if (-not $p) { continue }
            if ($p.status -eq 'Approved') { $approved += $p } else { $skipped += [ordered]@{ id = $p.id; name = $p.name; status = $p.status; notes = [string](Get-DV $p 'notes' '') } }
        }
        [ordered]@{ id = $s.id; name = $s.name; os = $s.os; packages = $approved; skipped = $skipped; repository = Get-DV $sw 'repository' @{} }
    }
}

Export-ModuleMember -Function Initialize-PortalDataFiles, Get-PortalDataFile, Test-PortalDataFile, Set-PortalDataFile, Get-PortalDataFileList,
    Get-PortalDataFilePath, Get-PortalSoftwareSet
