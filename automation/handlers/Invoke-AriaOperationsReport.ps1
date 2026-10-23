#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - generates an Aria Operations report for a VM, host, cluster or datastore and attaches it to the
    request (read-only in vSphere; Aria creates a report instance).
.DESCRIPTION
    The report definition is chosen from the definitions an Admin offered for the site (Admin > vCenter connections >
    Aria Operations > Test and sync reports). The object is looked up in Aria Operations by name and kind; the report
    is generated (POST /reports), polled until COMPLETED and downloaded in the requested formats.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] [ValidateSet('VirtualMachine', 'HostSystem', 'ClusterComputeResource', 'Datastore')] [string] $ObjectType,
    [string] $VMName,
    [string] $HostName,
    [string] $ClusterName,
    [string] $DatastoreName,
    [Parameter(Mandatory)] [string] $ReportDefinition,
    [ValidateSet('PDF', 'CSV', 'Both')] [string] $Format = 'PDF',
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}
Import-Module (Join-Path $Context.PortalRoot 'automation/lib/Portal.AriaOps.psm1') -Force -DisableNameChecking

if (-not $Context.Aria) { throw "Aria Operations is not available for site $Site." }
$name = switch ($ObjectType) { 'VirtualMachine' { $VMName } 'HostSystem' { $HostName } 'ClusterComputeResource' { $ClusterName } 'Datastore' { $DatastoreName } }
if (-not $name) { throw "Choose the $ObjectType to report on." }

$offered = @($Context.Site.aria.reports | Where-Object { $_.id -eq $ReportDefinition })
if (-not $offered) { throw "Report definition '$ReportDefinition' is not offered for site $Site." }
$defName = [string]$offered[0].name

$res = Find-PortalAriaResource -Aria $Context.Aria -Name $name -ResourceKind $ObjectType
if (-not $res) { throw "$ObjectType '$name' was not found in Aria Operations ($($Context.Aria.Endpoint))." }
Write-JobLog -Level STEP "Generating '$defName' for $ObjectType $name"

$formats = if ($Format -eq 'Both') { @('PDF', 'CSV') } else { @($Format) }
$base = ('aria-' + ($defName -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLowerInvariant() + '-' + ($name -replace '[^A-Za-z0-9_-]', '_'))
if ($base.Length -gt 120) { $base = $base.Substring(0, 120) }
$timeout = if ($Context.Operations -and $Context.Operations.Contains('reports') -and $Context.Operations.reports.Contains('ariaTimeoutSeconds')) { [int]$Context.Operations.reports.ariaTimeoutSeconds } else { 600 }
$poll = if ($Context.Aria.PSObject.Properties['Transport'] -and $Context.Aria.Transport) { 0 } else { 10 }
$rep = Invoke-PortalAriaReport -Aria $Context.Aria -DefinitionId $ReportDefinition -ResourceId $res.Id -OutDir $Context.ReportDir -BaseName $base -Format $formats -TimeoutSeconds $timeout -PollSeconds $poll
Write-JobLog -Level OK "Report $($rep.ReportId) downloaded: $(@($rep.Files | ForEach-Object { Split-Path -Leaf $_ }) -join ', ')"

return [ordered]@{
    Object     = "$ObjectType $name"
    Report     = $defName
    Files      = @($rep.Files | ForEach-Object { Split-Path -Leaf $_ })
    AriaReport = $rep.ReportId
    AriaLink   = Get-PortalAriaResourceUrl -Aria $Context.Aria -ResourceId $res.Id
}
