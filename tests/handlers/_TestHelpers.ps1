#Requires -Version 7.2
<#
.SYNOPSIS
    Shared helpers for the offline handler tests (tests/handlers/*.Tests.ps1). Dot-sourced by each test file.
.DESCRIPTION
    Handlers are executed for real against PowerCLI / AWS / Azure STUBS: each test file defines global functions with
    the names of the cmdlets the handler calls (Get-VM, New-VDPortgroup, ...) returning fake objects, then runs the
    handler with Invoke-TestHandler. No vCenter or cloud account is needed.
    The portal root is a temporary copy (config defaults, data files), so reports and state files never touch the repo.
#>

$ErrorActionPreference = 'Stop'
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $global:SspHandlerTestRoot) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("ssp-handlers-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Path $tmp -Force
    foreach ($d in 'modules', 'automation', 'catalog', 'config', 'web') { Copy-Item -Recurse -LiteralPath (Join-Path $script:RepoRoot $d) -Destination $tmp }
    foreach ($d in 'data/requests', 'data/inventory', 'data/reports', 'logs/jobs') { $null = New-Item -ItemType Directory -Path (Join-Path $tmp $d) -Force }
    Get-ChildItem (Join-Path $tmp 'config') -Filter '*.default.json' | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $_.DirectoryName ($_.Name -replace '\.default\.json$', '.json'))
    }
    $global:SspHandlerTestRoot = $tmp
}
$env:SSP_PORTAL_ROOT = $global:SspHandlerTestRoot
foreach ($m in 'modules/Portal.Core.psm1', 'modules/Portal.Security.psm1', 'modules/Portal.Data.psm1', 'modules/Portal.Storage.psm1', 'automation/lib/Portal.Report.psm1') {
    Import-Module (Join-Path $global:SspHandlerTestRoot $m) -Force -Global -DisableNameChecking
}
if (Test-Path (Join-Path $global:SspHandlerTestRoot 'automation/lib/Portal.Guest.psm1')) {
    Import-Module (Join-Path $global:SspHandlerTestRoot 'automation/lib/Portal.Guest.psm1') -Force -Global -DisableNameChecking
}
if (-not $global:SspTestResults) { $global:SspTestResults = [System.Collections.Generic.List[object]]::new() }
$global:JobLog = [System.Collections.Generic.List[string]]::new()

function global:Write-JobLog {
    param([Parameter(Mandatory, Position = 0)] [string] $Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'STEP', 'OK')] [string] $Level = 'INFO')
    $global:JobLog.Add("[$Level] $Message")
}

function global:Assert-Test {
    <# Records one check. #>
    param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [bool] $Condition, [string] $Detail)
    $global:SspTestResults.Add([pscustomobject]@{ Group = $global:SspTestGroup; Name = $Name; Passed = $Condition; Detail = $Detail })
    if ($Condition) { Write-Host "  [PASS] $Name" -ForegroundColor Green } else { Write-Host "  [FAIL] $Name $(if ($Detail) { "- $Detail" })" -ForegroundColor Red }
}

function global:Start-TestGroup { param([string] $Name) $global:SspTestGroup = $Name; Write-Host "`n$Name" -ForegroundColor Cyan }

function global:New-TestSite {
    param([string] $Code = 'DC1')
    [ordered]@{ code = $Code; name = "Test $Code"; enabled = $true; vcenter = "vc-$($Code.ToLower()).test.local"
                defaults = [ordered]@{ vmFolder = 'Portal-Provisioned'; dnsDomain = 'test.local'; dnsServers = @('10.0.0.53'); minDatastoreFreePercent = 15
                                      allowedClusters = @('CL-APP-01', 'CL-DB-01'); portgroupFilter = '.*'; workloadClusters = [ordered]@{ App = 'CL-APP-01'; DB = 'CL-DB-01' } } }
}

function global:New-TestContext {
    <# A job context like Invoke-CatalogJob.ps1 builds (VIServer is a fake object). #>
    param([string] $Site = 'DC1', [string] $ItemId = 'test-item', $Cloud, [switch] $NoVCenter, [bool] $Rollback = $true)
    $id = 'REQ-20261005-' + ([guid]::NewGuid().ToString('N').Substring(0, 6).ToUpper())
    $cfg = Get-PortalConfig
    [pscustomobject]@{
        Cloud             = $Cloud
        RequestId         = $id
        Requester         = [ordered]@{ username = 'jdoe'; name = 'John Doe'; email = 'jdoe@test.local' }
        Site              = $(if ($NoVCenter) { $null } else { New-TestSite -Code $Site })
        VIServer          = $(if ($NoVCenter) { $null } else { [pscustomobject]@{ Name = "vc-$($Site.ToLower()).test.local"; Version = '8.0.3'; Build = 24022515 } })
        RollbackOnFailure = $Rollback
        PortalRoot        = $global:SspHandlerTestRoot
        ReportDir         = (Join-Path $global:SspHandlerTestRoot "data/reports/$id")
        Teams             = @('Infrastructure')
        ItemId            = $ItemId
        Approval          = [ordered]@{ required = $true; decision = 'Approved'; decidedBy = 'approver1'; decidedAt = (Get-PortalTimestamp) }
        Authorization     = [ordered]@{ by = 'jdoe'; at = (Get-PortalTimestamp); ip = '10.1.1.10'; reauthenticated = $true }
        Operations        = $(if ($cfg.Contains('operations')) { $cfg.operations } else { [ordered]@{} })
    }
}

function global:Invoke-TestHandler {
    <# Runs automation/handlers/<Name> with the given parameters. Returns @{ Result; Error; Log }. #>
    param([Parameter(Mandatory)] [string] $Handler, [Parameter(Mandatory)] [hashtable] $Parameters)
    $global:JobLog.Clear()
    $path = Join-Path $global:SspHandlerTestRoot "automation/handlers/$Handler"
    if (-not (Test-Path $path)) { $path = Join-Path $script:RepoRoot "automation/handlers/$Handler" }
    $out = $null; $err = $null
    try { $out = @(& $path @Parameters 3>$null 6>$null) | Where-Object { $_ -is [System.Collections.IDictionary] } | Select-Object -Last 1 }
    catch { $err = $_.Exception.Message }
    return [pscustomobject]@{ Result = $out; Error = $err; Log = @($global:JobLog) }
}

function global:Get-TestReportFiles { param($Context) if (Test-Path $Context.ReportDir) { @(Get-ChildItem $Context.ReportDir -File | ForEach-Object Name) } else { @() } }
