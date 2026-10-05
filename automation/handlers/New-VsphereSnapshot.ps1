#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - creates a pre-change snapshot with an expiry stamp.
.DESCRIPTION
    The description carries "Expires: yyyy-MM-dd" so a scheduled cleanup job can remove expired
    portal snapshots (Get-Snapshot | Where Description -match 'Expires: (\d{4}-\d{2}-\d{2})').
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] [string] $VMName,
    [Parameter(Mandatory)] [string] $ChangeTicket,
    [ValidateRange(1, 7)] [int] $RetentionDays = 3,
    [bool] $IncludeMemory = $false,
    [bool] $Quiesce = $true,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}

$vi = $Context.VIServer
$vm = Get-VM -Name $VMName -Server $vi

$existing = @(Get-Snapshot -VM $vm -ErrorAction SilentlyContinue)
if ($existing.Count -ge 3) { throw "$VMName already has $($existing.Count) snapshots. Consolidate before taking a new one." }

$expires = (Get-Date).AddDays($RetentionDays).ToString('yyyy-MM-dd')
$name    = 'PORTAL-{0}-{1:yyyyMMdd-HHmm}' -f $ChangeTicket, (Get-Date)
$desc    = "Portal request $($Context.RequestId) by $($Context.Requester.username). Change: $ChangeTicket. Expires: $expires"

if ($IncludeMemory -and $Quiesce) {
    Write-JobLog -Level WARN 'Memory snapshots cannot be quiesced; quiesce disabled.'
    $Quiesce = $false
}
if ($vm.PowerState -ne 'PoweredOn') { $IncludeMemory = $false; $Quiesce = $false }

Write-JobLog -Level STEP "Creating snapshot '$name' on $VMName (memory=$IncludeMemory, quiesce=$Quiesce)"
$snap = New-Snapshot -VM $vm -Name $name -Description $desc -Memory:$IncludeMemory -Quiesce:$Quiesce -Confirm:$false
Write-JobLog -Level OK "Snapshot created: $($snap.Name) ($([math]::Round($snap.SizeGB, 2)) GB)"

return [ordered]@{
    VMName       = $VMName
    Snapshot     = $snap.Name
    Created      = $snap.Created.ToString('yyyy-MM-dd HH:mm')
    Expires      = $expires
    ChangeTicket = $ChangeTicket
    NextSteps    = @("Snapshot will be flagged for removal after $expires. Delete it earlier once the change is validated.")
}
