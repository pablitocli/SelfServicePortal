#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - orphaned virtual disk assessment across one or every enabled site (read-only).
.DESCRIPTION
    1. Builds the set of files referenced by every registered VM and template (file layout, including snapshot base
       disks) in all vCenters in scope - a disk used by a VM of another vCenter that shares the datastore is not
       reported.
    2. Scans each accessible datastore once (deduplicated by datastore URL) for *.vmdk / *.vmx.
    3. Groups each descriptor with its -flat / -delta / -sesparse / -ctk / -rdm files; sizes count data files.
    4. Classifies: Unregistered VM, Detached disk, Orphaned snapshot, CBT leftover, RDM mapping file.
    5. Skips known non-orphan locations (operations.orphanedDisks.pathExcludePattern: Content Library, First Class
       Disks, vSphere Replication, system folders).
    Items not modified for AgeThresholdDays are reclaimable candidates. Nothing is deleted or modified.
    Known limitation: disks of VMs registered in a vCenter outside the scope, and replica disks kept unregistered by
    third-party replication products, appear as orphaned - validate before any deletion.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [bool] $AllSites = $true,
    [ValidateRange(1, 3650)] [int] $AgeThresholdDays = 90,
    [string] $DatastoreExcludePattern,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}
$opsOd = if ($Context.Operations -and $Context.Operations.Contains('orphanedDisks')) { $Context.Operations.orphanedDisks } else { @{} }
$pathExclude = if ($opsOd -and $opsOd['pathExcludePattern']) { [string]$opsOd['pathExcludePattern'] } else { 'contentlib-|/fcd/|hbrdisk\.|hbrgrp\.|/\.sdd\.sf/|/\.vSphere-HA/|/\.dvsData/|/\.naa\.' }
$topN = if ($opsOd -and $opsOd['topItems']) { [int]$opsOd['topItems'] } else { 20 }
foreach ($rx in @($pathExclude, $DatastoreExcludePattern) | Where-Object { $_ }) { try { [void][regex]::new($rx) } catch { throw "Pattern '$rx' is not a valid regular expression." } }

# ---- Connections (the runner already holds the site's session) ----------------------------------
$sessions = [System.Collections.Generic.List[object]]::new()
$connRows = [System.Collections.Generic.List[object]]::new()
$own = [System.Collections.Generic.List[object]]::new()
$sessions.Add([pscustomobject]@{ Site = $Site; VI = $Context.VIServer })
$connRows.Add([ordered]@{ Site = $Site; vCenter = [string]$Context.VIServer.Name; Status = 'OK connected'; Detail = "vCenter $($Context.VIServer.Version)" })
if ($AllSites) {
    foreach ($s in @(Get-PortalSite -EnabledOnly | Where-Object { $_.code -ne $Site })) {
        try {
            $v = Connect-PortalVIServer -SiteCode $s.code
            $own.Add($v); $sessions.Add([pscustomobject]@{ Site = $s.code; VI = $v })
            $connRows.Add([ordered]@{ Site = $s.code; vCenter = [string]$v.Name; Status = 'OK connected'; Detail = "vCenter $($v.Version)" })
        }
        catch {
            $connRows.Add([ordered]@{ Site = $s.code; vCenter = [string]$s.vcenter; Status = "FAIL $($_.Exception.Message)"; Detail = 'Disks of VMs registered there may appear as orphaned.' })
            Write-JobLog -Level WARN "Site $($s.code): $($_.Exception.Message)"
        }
    }
}

function Get-FileKey {
    param([string] $DsPath, $LocalMap, $GlobalMap)
    if ($DsPath -notmatch '^\[(.+?)\]\s*(.*)$') { return $null }
    $dsName = $Matches[1]; $rel = $Matches[2].TrimStart('/')
    $url = if ($LocalMap -and $LocalMap.ContainsKey($dsName)) { $LocalMap[$dsName] } elseif ($GlobalMap.ContainsKey($dsName)) { $GlobalMap[$dsName] } else { 'name:' + $dsName }
    return ($url.TrimEnd('/') + '/' + $rel)
}
function Join-Rel { param([string] $A, [string] $B) if ($A) { $A.TrimEnd('/') + '/' + $B } else { $B } }
function New-SearchSpec {
    try {
        $spec = New-Object VMware.Vim.HostDatastoreBrowserSearchSpec
        $spec.MatchPattern = @('*.vmdk', '*.vmx')
        $spec.Details = New-Object VMware.Vim.FileQueryFlags
        $spec.Details.FileSize = $true; $spec.Details.Modification = $true; $spec.Details.FileType = $true; $spec.Details.FileOwner = $false
        return $spec
    }
    catch { return [pscustomobject]@{ MatchPattern = @('*.vmdk', '*.vmx'); Details = [pscustomobject]@{ FileSize = $true; Modification = $true; FileType = $true; FileOwner = $false } } }
}
function Get-AgeBucket { param([int] $Days) if ($Days -lt 0) { '5|Unknown' } elseif ($Days -le 30) { '0|0-30 days' } elseif ($Days -le 90) { '1|31-90 days' } elseif ($Days -le 180) { '2|91-180 days' } elseif ($Days -le 365) { '3|181-365 days' } else { '4|Over 1 year' } }
function Format-TB { param([double] $Bytes, [int] $Dec = 2) [math]::Round($Bytes / 1TB, $Dec) }

try {
    # ---- Phase 1: registered files ----------------------------------------------------------------
    $registered = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $vmTotal = 0
    foreach ($s in $sessions) {
        $dsViews = @(Get-View -ViewType Datastore -Property Name, Info.Url -Server $s.VI)
        $byMoref = @{}; $nameToUrl = @{}
        foreach ($d in $dsViews) { $byMoref[[string]$d.MoRef.Value] = $d; $nameToUrl[[string]$d.Name] = [string]$d.Info.Url }
        $vmViews = @(Get-View -ViewType VirtualMachine -Property Name, Datastore, LayoutEx.File, Config.Files.VmPathName -Server $s.VI)
        foreach ($vm in $vmViews) {
            $vmTotal++
            $local = @{}
            foreach ($m in @($vm.Datastore)) { if ($m -and $byMoref.ContainsKey([string]$m.Value)) { $local[[string]$byMoref[[string]$m.Value].Name] = [string]$byMoref[[string]$m.Value].Info.Url } }
            foreach ($fl in @($vm.LayoutEx.File)) { if ($fl) { $k = Get-FileKey ([string]$fl.Name) $local $nameToUrl; if ($k) { [void]$registered.Add($k) } } }
            $vmx = $null; try { $vmx = [string]$vm.Config.Files.VmPathName } catch { $vmx = $null }
            if ($vmx) { $k = Get-FileKey $vmx $local $nameToUrl; if ($k) { [void]$registered.Add($k) } }
        }
        Write-JobLog "Phase 1 - $($s.Site): $($vmViews.Count) VMs / templates"
    }

    # ---- Phase 2: datastore scan -------------------------------------------------------------------
    $rows = [System.Collections.Generic.List[object]]::new()
    $dsErrors = [System.Collections.Generic.List[object]]::new()
    $scanned = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $dsCap = @{}; $excluded = 0; $dsScanned = 0
    $now = Get-Date
    foreach ($s in $sessions) {
        $dsViews = @(Get-View -ViewType Datastore -Property Name, Info.Url, Summary.Accessible, Summary.Type, Summary.Capacity, Browser -Server $s.VI | Sort-Object Name)
        foreach ($d in $dsViews) {
            if (-not $d.Summary.Accessible) { $dsErrors.Add([ordered]@{ Site = $s.Site; Datastore = $d.Name; Detail = 'Not accessible - not scanned' }); continue }
            if ($DatastoreExcludePattern -and $d.Name -match $DatastoreExcludePattern) { continue }
            $url = [string]$d.Info.Url
            if (-not $scanned.Add($url)) { continue }
            $dsCap[$url] = [double]$d.Summary.Capacity
            $dsType = [string]$d.Summary.Type
            try {
                $browser = Get-View -Id $d.Browser -Server $s.VI
                $res = @($browser.SearchDatastoreSubFolders("[$($d.Name)]", (New-SearchSpec)))
                $dsScanned++
            }
            catch { $dsErrors.Add([ordered]@{ Site = $s.Site; Datastore = $d.Name; Detail = $_.Exception.Message }); continue }
            foreach ($fr in $res) {
                $files = @($fr.File | Where-Object { $_ })
                if (-not $files.Count) { continue }
                $folderRel = ''
                if ([string]$fr.FolderPath -match '^\[.+?\]\s*(.*)$') { $folderRel = $Matches[1].Trim('/') }
                $unregVmx = ''
                foreach ($fi in $files) { if ($fi.Path -match '\.vmx$' -and -not $registered.Contains($url.TrimEnd('/') + '/' + (Join-Rel $folderRel $fi.Path))) { $unregVmx = $fi.Path } }
                $groups = @{}
                foreach ($fi in $files) {
                    if ($fi.Path -notmatch '\.vmdk$') { continue }
                    $base = $fi.Path -replace '-(flat|delta|sesparse|ctk|rdm|rdmp)\.vmdk$', '.vmdk'
                    if (-not $groups.ContainsKey($base)) { $groups[$base] = [System.Collections.Generic.List[object]]::new() }
                    $groups[$base].Add($fi)
                }
                foreach ($base in @($groups.Keys)) {
                    $members = $groups[$base]
                    $anyReg = $false
                    foreach ($mm in $members) { if ($registered.Contains($url.TrimEnd('/') + '/' + (Join-Rel $folderRel $mm.Path))) { $anyReg = $true; break } }
                    if (-not $anyReg -and $registered.Contains($url.TrimEnd('/') + '/' + (Join-Rel $folderRel $base))) { $anyReg = $true }
                    if ($anyReg) { continue }
                    $display = "[$($d.Name)] " + (Join-Rel $folderRel $base)
                    if ($pathExclude -and $display -match $pathExclude) { $excluded++; continue }
                    $bytes = 0.0; $isRdm = $false; $onlyCtk = $true; $hasData = $false; $hasDesc = $false; $lastMod = $null
                    foreach ($mm in $members) {
                        if ($mm.Path -match '-rdmp?\.vmdk$') { $isRdm = $true } else { $bytes += [double]$mm.FileSize }
                        if ($mm.Path -notmatch '-ctk\.vmdk$') { $onlyCtk = $false }
                        if ($mm.Path -match '-(flat|delta|sesparse)\.vmdk$') { $hasData = $true }
                        if ($mm.Path -eq $base) { $hasDesc = $true }
                        if ($mm.Modification -and ($null -eq $lastMod -or [datetime]$mm.Modification -gt $lastMod)) { $lastMod = [datetime]$mm.Modification }
                    }
                    $cat = if ($isRdm) { 'RDM mapping file' } elseif ($onlyCtk) { 'CBT leftover' } elseif ($unregVmx) { 'Unregistered VM' } elseif ($base -match '-\d{6}\.vmdk$') { 'Orphaned snapshot' } else { 'Detached disk' }
                    $notes = [System.Collections.Generic.List[string]]::new()
                    if ($unregVmx) { $notes.Add($(if ($cat -eq 'Unregistered VM') { "VM config: $unregVmx" } else { "Folder holds unregistered $unregVmx" })) }
                    if (-not $hasDesc -and -not $onlyCtk) { $notes.Add('Descriptor missing') }
                    if ($isRdm) { $notes.Add('Mapping file only - LUN capacity not counted') }
                    if ($dsType -match 'vsan|vvol' -and -not $hasData) { $notes.Add('vSAN / vVol object - size not exposed by the datastore browser') }
                    $age = if ($lastMod) { [int]($now - $lastMod).TotalDays } else { -1 }
                    $bucket = (Get-AgeBucket $age).Split('|')
                    $rows.Add([pscustomobject]@{ Site = $s.Site; vCenter = [string]$s.VI.Name; Datastore = [string]$d.Name; DatastoreUrl = $url; Type = $dsType; Category = $cat; Path = $display
                                                 Files = $members.Count; SizeBytes = $bytes; LastModified = $(if ($lastMod) { $lastMod.ToString('yyyy-MM-dd') } else { '' }); AgeDays = $age
                                                 AgeBucket = $bucket[1]; AgeOrder = [int]$bucket[0]; Note = ($notes -join '; ') })
                }
            }
        }
    }
}
finally {
    foreach ($v in $own) { Disconnect-PortalVIServer -Server $v }
}

# ---- Aggregates and report ----------------------------------------------------------------------
$total = [double](($rows | Measure-Object SizeBytes -Sum).Sum)
$aged = @($rows | Where-Object { $_.AgeDays -ge $AgeThresholdDays })
$agedBytes = [double](($aged | Measure-Object SizeBytes -Sum).Sum)
$pct = { param($p, $t) if ($t -gt 0) { [math]::Round(100 * $p / $t, 1) } else { 0 } }
$summ = { param($items, $prop) foreach ($g in @($items | Group-Object $prop)) { $b = [double](($g.Group | Measure-Object SizeBytes -Sum).Sum); [ordered]@{ Name = $g.Name; Items = $g.Count; 'Size TB' = (Format-TB $b 3); Share = "$(& $pct $b $total) %"; _b = $b } } }
$byCat = @(& $summ $rows 'Category' | Sort-Object { $_._b } -Descending)
$byAge = @(foreach ($g in @($rows | Group-Object AgeBucket | Sort-Object { $_.Group[0].AgeOrder })) { $b = [double](($g.Group | Measure-Object SizeBytes -Sum).Sum); [ordered]@{ Name = $g.Name; Items = $g.Count; 'Size TB' = (Format-TB $b 3); Share = "$(& $pct $b $total) %" } })
$byDs = @($(foreach ($g in @($rows | Group-Object DatastoreUrl)) {
    $b = [double](($g.Group | Measure-Object SizeBytes -Sum).Sum); $cap = if ($dsCap.ContainsKey($g.Name)) { $dsCap[$g.Name] } else { 0 }
    [ordered]@{ Datastore = $g.Group[0].Datastore; Site = $g.Group[0].Site; Items = $g.Count; 'Orphaned TB' = (Format-TB $b 3); 'Capacity TB' = (Format-TB $cap 2); '% of datastore' = (& $pct $b $cap); _b = $b }
}) | Sort-Object { $_._b } -Descending)
$unregFolders = @($rows | Where-Object Category -eq 'Unregistered VM' | ForEach-Object { $_.Path -replace '/[^/]+$', '' } | Sort-Object -Unique).Count
$ageStatus = { param($d) if ($d -lt 0) { 'unknown' } elseif ($d -gt 365) { 'CRITICAL over 1 year' } elseif ($d -ge $AgeThresholdDays) { 'WARN reclaimable' } else { 'OK recent' } }
$inv = @($rows | Sort-Object SizeBytes -Descending | ForEach-Object { [ordered]@{ Site = $_.Site; Datastore = $_.Datastore; Category = $_.Category; Path = $_.Path; Files = $_.Files; 'Size TB' = (Format-TB $_.SizeBytes 3); 'Last modified' = $_.LastModified; 'Age (days)' = $(if ($_.AgeDays -ge 0) { $_.AgeDays } else { '' }); Status = (& $ageStatus $_.AgeDays); Note = $_.Note } })
$strip = { param($r) $o = [ordered]@{}; foreach ($k in $r.Keys) { if ($k -ne '_b') { $o[$k] = $r[$k] } }; $o }

$findings = [System.Collections.Generic.List[object]]::new()
if (-not $rows.Count) { $findings.Add([ordered]@{ Finding = 'No orphaned virtual disk was found in the scanned datastores.' }) }
else {
    $findings.Add([ordered]@{ Finding = "$(Format-TB $total 2) TB is held by $($rows.Count) disk item(s) no registered VM or template references." })
    $findings.Add([ordered]@{ Finding = "$(Format-TB $agedBytes 2) TB ($(& $pct $agedBytes $total) %) has not changed in $AgeThresholdDays+ days: primary reclamation target." })
    if ($byCat.Count) { $findings.Add([ordered]@{ Finding = "Largest category: $($byCat[0].Name) with $($byCat[0].'Size TB') TB ($($byCat[0].Share))." }) }
    if ($byDs.Count) { $findings.Add([ordered]@{ Finding = "Most affected datastore: $($byDs[0].Datastore) ($($byDs[0].Site)) with $($byDs[0].'Orphaned TB') TB, $($byDs[0].'% of datastore') % of its capacity." }) }
    if ($unregFolders) { $findings.Add([ordered]@{ Finding = "$unregFolders folder(s) hold a complete VM (.vmx + disks) not registered in any vCenter in scope." }) }
}
if ($dsErrors.Count) { $findings.Add([ordered]@{ Finding = "$($dsErrors.Count) datastore(s) could not be scanned (see 'Datastores not scanned')." }) }
$findings.Add([ordered]@{ Finding = 'Next steps: confirm with backup / replication owners, quarantine (rename or move) approved items for a fixed period, delete under an approved change, then run this report again.' })

$sections = @(
    New-PortalReportSection -Title 'Key findings' -Columns 'Finding' -Rows $findings
    New-PortalReportSection -Title 'By category' -Columns 'Name', 'Items', 'Size TB', 'Share' -Rows @($byCat | ForEach-Object { & $strip $_ })
    New-PortalReportSection -Title 'By age (last modified)' -Columns 'Name', 'Items', 'Size TB', 'Share' -Rows $byAge
    New-PortalReportSection -Title 'Top datastores' -Columns 'Datastore', 'Site', 'Items', 'Orphaned TB', 'Capacity TB', '% of datastore' -Rows @($byDs | Select-Object -First 10 | ForEach-Object { & $strip $_ })
    New-PortalReportSection -Title "Top $topN items" -Columns 'Path', 'Category', 'Site', 'Size TB', 'Last modified', 'Status' -Rows @($inv | Select-Object -First $topN)
    New-PortalReportSection -Title 'Full inventory' -Columns 'Site', 'Datastore', 'Category', 'Path', 'Files', 'Size TB', 'Last modified', 'Age (days)', 'Status', 'Note' -Rows $inv
    New-PortalReportSection -Title 'Scope - vCenter connections' -Columns 'Site', 'vCenter', 'Status', 'Detail' -Rows $connRows -Note "Path exclusions ($excluded item(s) skipped): $pathExclude. Sizes in binary TB (1 TB = 1024 GB), data files only."
)
if ($dsErrors.Count) { $sections += New-PortalReportSection -Title 'Datastores not scanned' -Columns 'Site', 'Datastore', 'Detail' -Rows $dsErrors }

$files = New-PortalReport -Title 'Orphaned virtual disk assessment' -Subtitle ("Scope: " + (@($sessions | ForEach-Object Site) -join ', ')) -Context $Context -Sections $sections -FileName 'orphaned-vmdk' -Summary ([ordered]@{
    'Orphaned TB' = (Format-TB $total 2); "Reclaimable TB ($AgeThresholdDays+ days)" = (Format-TB $agedBytes 2); Items = $rows.Count; 'Datastores affected' = $byDs.Count; 'Datastores scanned' = $dsScanned; 'VMs / templates checked' = $vmTotal })
Write-JobLog -Level OK "Orphaned: $(Format-TB $total 2) TB in $($rows.Count) item(s); reclaimable $(Format-TB $agedBytes 2) TB; $($dsErrors.Count) datastore(s) not scanned."

return [ordered]@{
    Scope            = @($sessions | ForEach-Object Site)
    OrphanedTB       = (Format-TB $total 2)
    ReclaimableTB    = (Format-TB $agedBytes 2)
    Items            = $rows.Count
    DatastoresScanned = $dsScanned
    NotScanned       = $dsErrors.Count
    Report           = $files[0].name
    NextSteps        = @('Validate the items with backup / replication owners before any deletion; this report changes nothing.')
}
