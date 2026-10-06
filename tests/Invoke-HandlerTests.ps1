#Requires -Version 7.2
<#
.SYNOPSIS
    Offline tests of the catalog handlers (tests/handlers/*.Tests.ps1) against PowerCLI / cloud stubs, plus validation
    of every catalog item (structure, lookups, handler parameter matching).
.EXAMPLE
    pwsh -File ./tests/Invoke-HandlerTests.ps1
    pwsh -File ./tests/Invoke-HandlerTests.ps1 -Filter Reports
#>
[CmdletBinding()] param([string] $Filter)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'handlers/_TestHelpers.ps1')

Start-TestGroup 'Catalog items'
Import-Module (Join-Path $global:SspHandlerTestRoot 'modules/Portal.Catalog.psm1') -Force -Global
foreach ($f in Get-ChildItem (Join-Path $repo 'catalog/items') -Filter *.json) {
    $item = Read-PortalJson -Path $f.FullName
    $errs = @(Test-PortalCatalogDefinition -Item $item)
    Assert-Test -Name "valid: $($f.Name)" -Condition (-not $errs.Count) -Detail ($errs -join '; ')
}

foreach ($t in Get-ChildItem (Join-Path $PSScriptRoot 'handlers') -Filter '*.Tests.ps1' | Sort-Object Name) {
    if ($Filter -and $t.Name -notmatch $Filter) { continue }
    try { & $t.FullName }
    catch { Assert-Test -Name "$($t.Name) ran to completion" -Condition $false -Detail $_.Exception.Message }
}

$fail = @($global:SspTestResults | Where-Object { -not $_.Passed })
Write-Host ("`nResult: {0} passed, {1} failed  (temp root: {2})" -f ($global:SspTestResults.Count - $fail.Count), $fail.Count, $global:SspHandlerTestRoot) -ForegroundColor $(if ($fail.Count) { 'Red' } else { 'Green' })
if ($fail.Count) { $fail | ForEach-Object { Write-Host "  FAILED [$($_.Group)] $($_.Name) $($_.Detail)" -ForegroundColor Red } }
Remove-Item -Recurse -Force $global:SspHandlerTestRoot -ErrorAction SilentlyContinue
exit $fail.Count
