#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - assigns a backup policy to one or more VMs through the vendor-agnostic backup connector.
.DESCRIPTION
    Used by catalog item backup-policy and called directly by the three-tier blueprint handler: keep the parameter
    contract (Site, VMName, Policy, ChangeTicket, Context) stable.

    Policies and the connector come from the 'backup' data file (config/backup.json, Admin > Data files).
    Only the 'vsphereTag' connector is active: the VM gets the vSphere tag <tagCategory>/<policy id> and backup
    products (Veeam, Commvault, Rubrik, Cohesity, NetBackup, PowerProtect...) select their VMs by that tag.
    The other connectors in the file are templates (catalog/_connectors/backup) and are refused.

    The tag category is created when missing (cardinality Single, entity VirtualMachine) and the policy tag is
    created when missing. Any existing assignment in that category is replaced; Policy 'None' removes it.
    Idempotent: a VM that already carries exactly the requested policy is left untouched.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] [string] $VMName,          # one VM, or a comma / new-line separated list
    [Parameter(Mandatory)] [string] $Policy,          # policy id from the backup data file, or 'None' (remove)
    [string] $ChangeTicket,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}

$vi = $Context.VIServer

function Get-BpValue { param($T, [string] $K, $D = $null) if ($T -is [System.Collections.IDictionary] -and $T.Contains($K) -and $null -ne $T[$K]) { $T[$K] } else { $D } }

#region 1. Pre-checks -----------------------------------------------------------------------------------------
Write-JobLog -Level STEP "Pre-checks: backup policy '$Policy' at site $Site"
$cfg = Get-PortalDataFile -Name backup
$connector = [string](Get-BpValue $cfg 'connector' '')
if ($connector -ne 'vsphereTag') {
    throw "Backup connector '$connector' is not active. Only 'vsphereTag' is supported; vendor connectors are templates until a backup product is approved (catalog/_connectors/backup)."
}
$categoryName = [string](Get-BpValue $cfg 'tagCategory' '')
if (-not $categoryName) { throw 'The backup data file has no tagCategory (Admin > Data files > Backup policies).' }

$remove = $Policy -ieq 'None'
$policyDef = $null
if (-not $remove) {
    $policyDef = @(Get-BpValue $cfg 'policies' @()) | Where-Object { [string](Get-BpValue $_ 'id' '') -ceq $Policy } | Select-Object -First 1
    if (-not $policyDef) {
        $known = @(Get-BpValue $cfg 'policies' @()) | ForEach-Object { $_.id }
        throw "Backup policy '$Policy' is not defined in the backup data file (known: $($known -join ', '))."
    }
    if (-not (Get-BpValue $policyDef 'enabled' $true)) { throw "Backup policy '$Policy' is disabled in the backup data file." }
}

$names = @(($VMName -split '[,;\r\n]+') | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
if (-not $names.Count) { throw 'No VM name given.' }
$vms = foreach ($n in $names) {
    $v = Get-VM -Name $n -Server $vi -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $v) { throw "VM '$n' was not found in $($vi.Name)." }
    $v
}
Write-JobLog -Level OK "$(@($vms).Count) VM(s) found; connector $connector, category '$categoryName'."
#endregion

#region 2. Tag category + tag -----------------------------------------------------------------------------------
$category = Get-TagCategory -Name $categoryName -Server $vi -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $category -and -not $remove) {
    Write-JobLog -Level STEP "Creating tag category '$categoryName' (Single, VirtualMachine)"
    $category = New-TagCategory -Name $categoryName -Cardinality Single -EntityType VirtualMachine -Description 'Backup policy (Self-Service Portal). Backup products select VMs by this tag.' -Server $vi
}
elseif ($category -and [string]$category.Cardinality -ne 'Single') {
    Write-JobLog -Level WARN "Tag category '$categoryName' allows multiple tags per VM; the portal still keeps one policy per VM."
}

$tag = $null
if (-not $remove) {
    $tag = Get-Tag -Name $Policy -Category $category -Server $vi -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $tag) {
        Write-JobLog -Level STEP "Creating tag '$categoryName/$Policy'"
        $tag = New-Tag -Name $Policy -Category $category -Description ([string](Get-BpValue $policyDef 'description' $Policy)) -Server $vi
    }
}
#endregion

#region 3. Assign ------------------------------------------------------------------------------------------------
$lines = [System.Collections.Generic.List[string]]::new()
$previous = [System.Collections.Generic.List[string]]::new()
$changed = 0
foreach ($vm in $vms) {
    $current = @()
    if ($category) { $current = @(Get-TagAssignment -Entity $vm -Category $category -Server $vi -ErrorAction SilentlyContinue) }
    $currentNames = @($current | ForEach-Object { [string]$_.Tag.Name } | Where-Object { $_ })
    $prev = if ($currentNames.Count) { $currentNames -join '+' } else { 'None' }
    $previous.Add("$($vm.Name)=$prev")

    $alreadyOk = if ($remove) { -not $current.Count } else { $currentNames.Count -eq 1 -and $currentNames[0] -ceq $Policy }
    if ($alreadyOk) {
        Write-JobLog -Level OK "$($vm.Name): already '$prev' - unchanged."
        $lines.Add("$($vm.Name): $prev (unchanged)")
        continue
    }
    foreach ($a in $current) {
        Write-JobLog "$($vm.Name): removing '$categoryName/$($a.Tag.Name)'"
        Remove-TagAssignment -TagAssignment $a -Confirm:$false
    }
    if (-not $remove) {
        $null = New-TagAssignment -Tag $tag -Entity $vm -Server $vi
        Write-JobLog -Level OK "$($vm.Name): '$prev' -> '$Policy'"
    }
    else { Write-JobLog -Level OK "$($vm.Name): backup policy removed (was '$prev')." }
    $changed++
    $lines.Add("$($vm.Name): $prev -> $(if ($remove) { 'None' } else { $Policy })")
}
#endregion

$next = if ($remove) { @("The VM(s) no longer carry a '$categoryName' tag: backup products that select by this tag exclude them from the next run.") }
        else { @("Backup products select VMs by the tag $categoryName/$Policy. Confirm the backup job's tag selection includes it; the first backup runs in the next policy window.") }

return [ordered]@{
    Site           = $Site
    VMs            = @($vms | ForEach-Object { [string]$_.Name })
    PreviousPolicy = $previous.ToArray()
    NewPolicy      = $(if ($remove) { 'None' } else { $Policy })
    Connector      = $connector
    TagCategory    = $categoryName
    Changed        = $changed
    Changes        = $lines.ToArray()
    ChangeTicket   = $ChangeTicket
    NextSteps      = $next
}
