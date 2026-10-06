#Requires -Version 7.2
<#
.SYNOPSIS
    Validates a catalog item JSON before publishing it to catalog/items.
.DESCRIPTION
    Runs the same validator the portal uses at load time: structure, input types, regexes, dependsOn order,
    handler existence and handler parameter matching (each input must be a parameter of the handler script).
.EXAMPLE
    .\tools\Test-CatalogItem.ps1 -Path .\catalog\items\vm-windows-2022.json
.EXAMPLE
    .\tools\Test-CatalogItem.ps1            # validates every item in catalog/items
#>
[CmdletBinding()]
param([string[]] $Path)

$root = Split-Path -Parent $PSScriptRoot
$env:SSP_PORTAL_ROOT = $root
Import-Module (Join-Path $root 'modules/Portal.Core.psm1') -Force
Import-Module (Join-Path $root 'modules/Portal.Security.psm1') -Force
Import-Module (Join-Path $root 'modules/Portal.Catalog.psm1') -Force

if (-not $Path) { $Path = (Get-ChildItem (Get-PortalPath -Name CatalogItems) -Filter *.json).FullName }

$failed = 0
foreach ($p in $Path) {
    try {
        $item = Read-PortalJson -Path (Resolve-Path $p)
        $errs = @(Test-PortalCatalogDefinition -Item $item)
    }
    catch { $errs = @("Invalid JSON: $($_.Exception.Message)") }

    if ($errs) {
        $failed++
        Write-Host ("[FAIL] {0}" -f (Split-Path -Leaf $p)) -ForegroundColor Red
        $errs | ForEach-Object { Write-Host "       - $_" -ForegroundColor Red }
    }
    else {
        Write-Host ("[ OK ] {0}  ({1} v{2}, {3} inputs, handler {4})" -f (Split-Path -Leaf $p), $item.id, $item.version, @($item.inputs).Count, $item.execution.handler) -ForegroundColor Green
    }
}
exit $failed
