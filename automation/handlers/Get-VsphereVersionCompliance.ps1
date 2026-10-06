#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - read-only version compliance report (vCenter, ESXi, VMware Tools, VM hardware, advisories).
.DESCRIPTION
    Targets come from the "Version baseline" data file (config/version-baseline.json, Admin > Data files):
      targets.vcenter.minBuild, targets.esxi.minBuild   build numbers (0 = not set)
      targets.vmTools.minVersion                         ToolsVersion number, e.g. 12352 (0 = not set)
      targets.vmHardware.minVersion                      e.g. "vmx-19" or 19 (empty = not set)
      advisories[]                                       { id, product: vcenter|esxi, fixedBuild, [title], [appliesToVersion] }
    An entity below an advisory fixedBuild is NON-COMPLIANT and the advisory id is listed. The optional
    appliesToVersion (e.g. "8.0") limits an advisory to one release line, since build numbers of parallel lines overlap.
    Compliance values: COMPLIANT / NON-COMPLIANT / NOT SET (target not configured).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}

$vi = $Context.VIServer
if (-not $vi) { throw 'No vCenter session (the item requires a vCenter connection).' }

function Get-Val { param($T, [string] $K, $D = $null) if ($T -is [System.Collections.IDictionary] -and $T.Contains($K) -and $null -ne $T[$K]) { $T[$K] } else { $D } }
function ConvertTo-Number { param($V) $n = 0L; if ([long]::TryParse(([string]$V -replace '[^0-9]', ''), [ref]$n)) { $n } else { 0L } }

$baseline = Get-PortalDataFile -Name versionBaseline
$targets  = Get-Val $baseline 'targets' @{}
$vcTarget   = ConvertTo-Number (Get-Val (Get-Val $targets 'vcenter' @{}) 'minBuild' 0)
$esxTarget  = ConvertTo-Number (Get-Val (Get-Val $targets 'esxi' @{}) 'minBuild' 0)
$toolTarget = ConvertTo-Number (Get-Val (Get-Val $targets 'vmTools' @{}) 'minVersion' 0)
$hwRaw      = [string](Get-Val (Get-Val $targets 'vmHardware' @{}) 'minVersion' '')
$hwTarget   = ConvertTo-Number $hwRaw
$advisories = @(Get-Val $baseline 'advisories' @() | Where-Object { $_ })
Write-JobLog "Targets: vCenter $(if ($vcTarget) { $vcTarget } else { 'not set' }), ESXi $(if ($esxTarget) { $esxTarget } else { 'not set' }), Tools $(if ($toolTarget) { $toolTarget } else { 'not set' }), hardware $(if ($hwTarget) { "vmx-$hwTarget" } else { 'not set' }); advisories: $($advisories.Count)"

$advisoryRows = [System.Collections.Generic.List[object]]::new()
function Get-FailedAdvisory {
    <# Advisories of the product whose fixedBuild is above the given build. Adds one row per finding. #>
    param([string] $Product, [string] $Entity, [string] $Version, [long] $Build)
    foreach ($a in $advisories) {
        if ([string](Get-Val $a 'product' '') -ne $Product) { continue }
        $applies = [string](Get-Val $a 'appliesToVersion' '')
        if ($applies -and $Version -and -not $Version.StartsWith($applies)) { continue }
        $fixed = ConvertTo-Number (Get-Val $a 'fixedBuild' 0)
        if ($fixed -gt 0 -and $Build -lt $fixed) {
            $advisoryRows.Add([ordered]@{
                Advisory = [string](Get-Val $a 'id' ''); Title = [string](Get-Val $a 'title' ''); Product = $Product; Entity = $Entity
                Build = $(if ($Build) { $Build } else { 'unknown' }); FixedBuild = $fixed; Compliance = 'NON-COMPLIANT'
            })
            [string](Get-Val $a 'id' '')
        }
    }
}
function Get-Compliance { param([long] $Target, [long] $Value, [string[]] $Failed)
    if ($Failed) { return 'NON-COMPLIANT' }
    if ($Target -le 0) { return 'NOT SET' }
    if ($Value -ge $Target) { 'COMPLIANT' } else { 'NON-COMPLIANT' }
}

# --- vCenter ---------------------------------------------------------------------------------------------------
Write-JobLog -Level STEP 'Checking vCenter'
$vcBuild = ConvertTo-Number $vi.Build
$vcVersion = [string]$vi.Version
if (-not $vcBuild) {
    try { $about = (Get-View -Server $vi -Id 'ServiceInstance').Content.About; $vcBuild = ConvertTo-Number $about.Build; $vcVersion = [string]$about.Version } catch { }
}
$vcFailed = @(Get-FailedAdvisory -Product vcenter -Entity ([string]$vi.Name) -Version $vcVersion -Build $vcBuild)
$vcRows = @([ordered]@{
    vCenter = [string]$vi.Name; Version = $vcVersion; Build = $vcBuild; TargetBuild = $(if ($vcTarget) { $vcTarget } else { '-' })
    Advisories = ($vcFailed -join ', '); Compliance = Get-Compliance -Target $vcTarget -Value $vcBuild -Failed $vcFailed
})

# --- ESXi hosts ------------------------------------------------------------------------------------------------
Write-JobLog -Level STEP 'Checking ESXi hosts'
$clusterName = @{}
foreach ($c in @(Get-View -Server $vi -ViewType ClusterComputeResource -Property Name)) { $clusterName[[string]$c.MoRef] = $c.Name }
$hostRows = foreach ($h in (@(Get-View -Server $vi -ViewType HostSystem -Property Name, Parent, Runtime.ConnectionState, Config.Product.Version, Config.Product.Build) | Sort-Object Name)) {
    $build = ConvertTo-Number $h.Config.Product.Build
    $ver = [string]$h.Config.Product.Version
    $failed = @(Get-FailedAdvisory -Product esxi -Entity $h.Name -Version $ver -Build $build)
    $comp = if (-not $build) { 'NON-COMPLIANT' } else { Get-Compliance -Target $esxTarget -Value $build -Failed $failed }
    [ordered]@{
        Host = $h.Name; Cluster = $(if ($clusterName.ContainsKey([string]$h.Parent)) { $clusterName[[string]$h.Parent] } else { '(standalone)' })
        Version = $ver; Build = $(if ($build) { $build } else { 'unknown' }); TargetBuild = $(if ($esxTarget) { $esxTarget } else { '-' })
        Advisories = ($failed -join ', '); Compliance = $comp
        Detail = $(if (-not $build) { "Build unknown (connection state $($h.Runtime.ConnectionState))" } else { '' })
    }
}

# --- Virtual machines ------------------------------------------------------------------------------------------
Write-JobLog -Level STEP 'Checking VMware Tools and VM hardware versions'
$toolRows = [System.Collections.Generic.List[object]]::new()
$hwRows = [System.Collections.Generic.List[object]]::new()
foreach ($v in (@(Get-View -Server $vi -ViewType VirtualMachine -Property Name, Config.Template, Config.Version, Runtime.PowerState, Guest.ToolsVersion) | Sort-Object Name)) {
    if ($v.Config.Template) { continue }
    $tv = ConvertTo-Number $v.Guest.ToolsVersion
    $toolRows.Add([ordered]@{
        VM = $v.Name; PowerState = [string]$v.Runtime.PowerState; ToolsVersion = $(if ($tv) { $tv } else { 'not installed' })
        TargetVersion = $(if ($toolTarget) { $toolTarget } else { '-' })
        Compliance = $(if ($toolTarget -le 0) { 'NOT SET' } elseif ($tv -ge $toolTarget) { 'COMPLIANT' } else { 'NON-COMPLIANT' })
    })
    $hv = ConvertTo-Number $v.Config.Version
    $hwRows.Add([ordered]@{
        VM = $v.Name; Hardware = [string]$v.Config.Version; Target = $(if ($hwTarget) { "vmx-$hwTarget" } else { '-' })
        Compliance = $(if ($hwTarget -le 0) { 'NOT SET' } elseif ($hv -ge $hwTarget) { 'COMPLIANT' } else { 'NON-COMPLIANT' })
    })
}

# --- Report ----------------------------------------------------------------------------------------------------
function Get-AreaSummary { param($Rows)
    $r = @($Rows)
    if (-not $r.Count) { return '0' }
    if (-not @($r | Where-Object { $_.Compliance -ne 'NOT SET' }).Count) { return 'NOT SET' }
    '{0} / {1} compliant' -f @($r | Where-Object { $_.Compliance -eq 'COMPLIANT' }).Count, $r.Count
}
$nc = { param($Rows) @($Rows | Where-Object { $_.Compliance -eq 'NON-COMPLIANT' }).Count }
$summary = [ordered]@{
    'vCenter'             = $vcRows[0].Compliance
    'ESXi hosts'          = Get-AreaSummary $hostRows
    'VMware Tools'        = Get-AreaSummary $toolRows
    'VM hardware'         = Get-AreaSummary $hwRows
    'Advisory findings'   = $advisoryRows.Count
}
$sections = @(
    New-PortalReportSection -Title 'vCenter' -Rows $vcRows -Columns vCenter, Version, Build, TargetBuild, Advisories, Compliance
    New-PortalReportSection -Title 'ESXi hosts' -Rows $hostRows -Columns Host, Cluster, Version, Build, TargetBuild, Advisories, Compliance, Detail
    New-PortalReportSection -Title 'Advisories' -Rows $advisoryRows -Columns Advisory, Title, Product, Entity, Build, FixedBuild, Compliance -Note 'Entities below the first fixed build of a security advisory.'
    New-PortalReportSection -Title 'VMware Tools' -Rows $toolRows -Columns VM, PowerState, ToolsVersion, TargetVersion, Compliance
    New-PortalReportSection -Title 'VM hardware' -Rows $hwRows -Columns VM, Hardware, Target, Compliance
)
$files = New-PortalReport -Title "Version compliance - $Site" -Subtitle 'Targets: Admin > Data files > Version baseline' -Context $Context -Sections $sections -Summary $summary -FileName 'version-compliance'
Write-JobLog -Level OK "Report written: $($files[0].name)"

return [ordered]@{
    Site                     = $Site
    VCenter                  = $vcRows[0].Compliance
    EsxiNonCompliant         = (& $nc $hostRows)
    ToolsNonCompliant        = (& $nc $toolRows)
    HardwareNonCompliant     = (& $nc $hwRows)
    AdvisoryFindings         = $advisoryRows.Count
    Report                   = $files[0].name
}
