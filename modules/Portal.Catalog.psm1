#Requires -Version 7.2
<#
.SYNOPSIS
    Portal.Catalog - JSON-driven service catalog (marketplace).
.DESCRIPTION
    Every *.json file in catalog/items is a marketplace item. Files are read on demand, so a new or updated
    item becomes available as soon as the file is dropped in the folder (no portal restart).
    Items that fail validation are skipped and reported to Admins with the exact reasons.
    The same validator is used by tools/Test-CatalogItem.ps1 before publishing.
#>

Set-StrictMode -Version Latest

$script:ValidInputTypes  = @('text', 'textarea', 'number', 'select', 'boolean', 'ipv4', 'credential')
$script:ValidSourceTypes = @('sites', 'clusters', 'datastores', 'datastoreClusters', 'portgroups', 'templates', 'folders', 'vms',
                            'hosts', 'vdSwitches', 'storageDevices', 'softwareSets', 'backupPolicies',
                            'awsSubnets', 'awsInstanceTypes', 'azureSubnets', 'azureVmSizes')
$script:CloudSources     = @('awsSubnets', 'awsInstanceTypes', 'azureSubnets', 'azureVmSizes')
$script:ValidRoles       = @('Requester', 'Approver', 'Admin', 'CatalogAdmin', 'SecurityAdmin', 'VaultAdmin')
$script:InventorySources = @('clusters', 'datastores', 'datastoreClusters', 'portgroups', 'templates', 'folders', 'vms', 'hosts', 'vdSwitches', 'storageDevices')
$script:DataSources      = @('softwareSets', 'backupPolicies')       # config/<data file>.json (Admin > Data files)

#region Helpers ---------------------------------------------------------------------------------------------

function Get-Prop {
    param($Object, [string] $Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] } else { return $Default }
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function Test-Regex {
    param([string] $Pattern)
    try { [void][regex]::new($Pattern); return $true } catch { return $false }
}

function Get-PortalHandlerInfo {
    <# Parses a handler script (no execution) and describes its parameters. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { throw "Handler has syntax errors: $($errors[0].Message) (line $($errors[0].Extent.StartLineNumber))" }
    if (-not $ast.ParamBlock) { return @() }
    foreach ($p in $ast.ParamBlock.Parameters) {
        $mandatory = $false; $set = @(); $type = 'string'
        foreach ($a in $p.Attributes) {
            if ($a -is [System.Management.Automation.Language.TypeConstraintAst]) { $type = $a.TypeName.Name }
            elseif ($a.TypeName.Name -eq 'Parameter') {
                foreach ($na in $a.NamedArguments) {
                    if ($na.ArgumentName -eq 'Mandatory') { $mandatory = if ($na.ExpressionOmitted) { $true } else { [string]$na.Argument.Extent.Text -notmatch '\$false' } }
                }
            }
            elseif ($a.TypeName.Name -eq 'ValidateSet') { $set = @($a.PositionalArguments | ForEach-Object { $_.Value }) }
        }
        [ordered]@{
            name        = $p.Name.VariablePath.UserPath
            type        = $type
            mandatory   = [bool]$mandatory
            validateSet = $set
            default     = if ($p.DefaultValue) { $p.DefaultValue.Extent.Text } else { $null }
        }
    }
}

function Get-HandlerParameterNames {
    param([string] $Path)
    return @(Get-PortalHandlerInfo -Path $Path | ForEach-Object { $_.name })
}

#endregion

#region Definition validation -------------------------------------------------------------------------------

function Test-PortalCatalogDefinition {
    <#
    .SYNOPSIS Validates a catalog item definition. Returns an array of error strings (empty = valid).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Item)

    $err = [System.Collections.Generic.List[string]]::new()

    foreach ($req in 'id', 'version', 'name', 'category', 'summary', 'execution', 'inputs') {
        if (-not $Item.Contains($req) -or $null -eq $Item[$req] -or ($Item[$req] -is [string] -and -not $Item[$req])) {
            $err.Add("Missing required property '$req'.")
        }
    }
    if ($err.Count) { return $err.ToArray() }

    if ($Item.id -notmatch '^[a-z0-9][a-z0-9-]{2,62}$') { $err.Add("id '$($Item.id)' must be lowercase alphanumeric/hyphen, 3-63 chars.") }
    if ($Item.version -notmatch '^\d+\.\d+\.\d+$')       { $err.Add("version '$($Item.version)' must be semantic (x.y.z).") }

    # Access / approval
    foreach ($r in @(Get-Prop (Get-Prop $Item 'access') 'roles' @())) {
        if ($script:ValidRoles -notcontains $r) { $err.Add("access.roles contains unknown role '$r'.") }
    }
    $knownTeams = @(Get-PortalTeamList | ForEach-Object { $_.id })
    foreach ($t in @(Get-Prop (Get-Prop $Item 'access') 'teams' @())) {
        if ($knownTeams -notcontains $t) { $err.Add("access.teams contains unknown team '$t' (Admin > Customization > Teams).") }
    }
    foreach ($r in @(Get-Prop (Get-Prop $Item 'approval') 'approverRoles' @())) {
        if ($script:ValidRoles -notcontains $r) { $err.Add("approval.approverRoles contains unknown role '$r'.") }
    }

    # Sites
    $knownSites = @(Get-PortalSite | ForEach-Object { $_.code })
    foreach ($s in @(Get-Prop $Item 'sites' @())) {
        if ($knownSites -notcontains $s) { $err.Add("sites contains '$s', which is not defined in portal.config.json.") }
    }

    # Handler
    $exec = $Item.execution
    $handler = Get-Prop $exec 'handler'
    $handlerParams = @(); $handlerInfo = @()
    if (-not $handler) {
        $err.Add('execution.handler is required.')
    }
    else {
        try {
            $hPath = Resolve-PortalHandlerPath -Handler $handler -MustExist
            $handlerInfo = @(Get-PortalHandlerInfo -Path $hPath)
            $handlerParams = @($handlerInfo | ForEach-Object { $_.name })
        }
        catch { $err.Add($_.Exception.Message) }
    }
    $fixedKeys = @((Get-Prop $exec 'fixedParameters' @{}).Keys)
    foreach ($k in $fixedKeys) {
        if ($handlerParams -and $handlerParams -notcontains $k) { $err.Add("fixedParameters.$k is not a parameter of $handler.") }
    }
    # Vault credentials bound to handler parameters: { "GuestCredential": "vault-entry-id" } -> [pscredential] at run time.
    $credMap = Get-Prop $exec 'credentials' @{}
    if ($credMap -isnot [System.Collections.IDictionary]) { $err.Add('execution.credentials must be an object { "Parameter": "vault-id" }.'); $credMap = @{} }
    foreach ($k in @($credMap.Keys)) {
        if ($handlerParams -and $handlerParams -notcontains $k) { $err.Add("execution.credentials.$k is not a parameter of $handler.") }
        if ([string]$credMap[$k] -notmatch '^[a-z0-9][a-z0-9._-]{1,62}$') { $err.Add("execution.credentials.${k}: '$($credMap[$k])' is not a valid vault id.") }
        $fixedKeys += $k
    }

    # Inputs
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($in in @($Item.inputs)) {
        $n = Get-Prop $in 'name'
        if (-not $n) { $err.Add('An input is missing "name".'); continue }
        if ($n -notmatch '^[A-Za-z][A-Za-z0-9]{0,40}$') { $err.Add("Input '$n': name must be alphanumeric and start with a letter.") }
        if (-not $seen.Add($n)) { $err.Add("Input '$n' is defined more than once.") }
        if (-not (Get-Prop $in 'label')) { $err.Add("Input '$n': label is required.") }

        $type = Get-Prop $in 'type'
        if ($script:ValidInputTypes -notcontains $type) { $err.Add("Input '$n': unknown type '$type'.") }

        if ((Get-Prop $in 'isNote' $false)) { continue }   # VM notes are delivered to the handler as -VmNotes
        if ($handlerParams -and $handlerParams -notcontains $n) { $err.Add("Input '$n' has no matching parameter in handler $handler.") }

        $src = Get-Prop $in 'source'
        $opts = Get-Prop $in 'options'
        if ($type -eq 'select' -and -not $src -and -not $opts) { $err.Add("Input '$n': select requires 'options' or 'source'.") }
        if ($src) {
            $st = Get-Prop $src 'type'
            if ($script:ValidSourceTypes -notcontains $st) { $err.Add("Input '$n': unknown source type '$st'.") }
            foreach ($d in @(Get-Prop $src 'dependsOn' @())) {
                if (-not $seen.Contains($d)) { $err.Add("Input '$n': dependsOn '$d' must reference an input declared earlier.") }
            }
            if ($script:InventorySources -contains $st -and @(Get-Prop $src 'dependsOn' @()) -notcontains (Get-Prop $exec 'siteInput' 'Site')) {
                $err.Add("Input '$n': source '$st' must depend on the site input '$(Get-Prop $exec 'siteInput' 'Site')'.")
            }
            $f = Get-Prop $src 'filter'
            if ($f -and -not (Test-Regex $f)) { $err.Add("Input '$n': source.filter is not a valid regular expression.") }
        }
        $val = Get-Prop $in 'validation'
        $pat = Get-Prop $val 'pattern'
        if ($pat -and -not (Test-Regex $pat)) { $err.Add("Input '$n': validation.pattern is not a valid regular expression.") }

        $vw = Get-Prop $in 'visibleWhen'
        if ($vw -and -not $seen.Contains((Get-Prop $vw 'field'))) { $err.Add("Input '$n': visibleWhen.field must reference an input declared earlier.") }
    }

    # Every mandatory handler parameter must be fed by an input, a fixed parameter or the runner (-Context).
    if ($handlerParams) {
        foreach ($hp in @($handlerInfo | Where-Object { $_.mandatory })) {
            if ($hp.name -eq 'Context') { continue }
            if (-not $seen.Contains($hp.name) -and $fixedKeys -notcontains $hp.name) {
                $err.Add("Mandatory handler parameter '$($hp.name)' is not provided by any input or fixedParameters entry.")
            }
        }
    }

    if ((Get-Prop $Item 'vmNotes' $false) -and $handlerParams -and $handlerParams -notcontains 'VmNotes') {
        $err.Add("vmNotes is enabled but handler $handler has no -VmNotes parameter.")
    }

    $cloud = Get-Prop $exec 'cloud'
    if ($cloud -and @('aws', 'azure') -notcontains $cloud) { $err.Add("execution.cloud must be 'aws' or 'azure'.") }
    if ($cloud -and (Get-Prop $exec 'requiresVCenter' $true)) { $err.Add('Cloud items must set execution.requiresVCenter = false.') }

    if ((Get-Prop $exec 'requiresVCenter' $true)) {
        $siteInput = Get-Prop $exec 'siteInput' 'Site'
        if (-not $seen.Contains($siteInput)) { $err.Add("execution.requiresVCenter is true but site input '$siteInput' is not defined.") }
    }

    return $err.ToArray()
}

#endregion

#region VM notes ---------------------------------------------------------------------------------------------

function Get-PortalVmNoteInputs {
    <#
    .SYNOPSIS Builds the "VM notes" form section from portal.config.json -> vmNotes.fields (Admin > Customization).
    .NOTES    Input names are "Note<key>"; the runner hands them to the handler as one -VmNotes dictionary.
    #>
    [CmdletBinding()] param()
    $cfg = Get-PortalConfig
    if (-not $cfg.Contains('vmNotes') -or -not (Get-Prop $cfg.vmNotes 'enabled' $true)) { return @() }
    $group = [string](Get-Prop $cfg.vmNotes 'title' 'VM notes')
    foreach ($f in @(Get-Prop $cfg.vmNotes 'fields' @())) {
        $key = [string](Get-Prop $f 'key' '')
        if ($key -notmatch '^[A-Za-z][A-Za-z0-9]{0,30}$') { continue }
        $in = [ordered]@{ name = "Note$key"; label = [string](Get-Prop $f 'label' $key); type = 'text'; group = $group
                          required = [bool](Get-Prop $f 'required' $false); isNote = $true; noteKey = $key }
        $help = Get-Prop $f 'help'; if ($help) { $in['help'] = $help }
        $type = [string](Get-Prop $f 'type' 'text')
        if ($type -eq 'select' -and @(Get-Prop $f 'options' @())) {
            $in.type = 'select'
            $in['options'] = @(@(Get-Prop $f 'options' @()) | ForEach-Object { [ordered]@{ value = [string]$_; label = [string]$_ } })
        }
        elseif ($type -eq 'textarea') { $in.type = 'textarea' }
        $v = [ordered]@{ maxLength = 250 }
        $pat = Get-Prop $f 'pattern'; if ($pat) { $v['pattern'] = $pat; $v['patternMessage'] = "$($in.label): invalid format." }
        $in['validation'] = $v
        $in
    }
}

#endregion

#region Catalog loading -------------------------------------------------------------------------------------

function Get-PortalCatalog {
    <#
    .SYNOPSIS Loads every catalog item. Returns @{ items = [...]; errors = [...] }.
    #>
    [CmdletBinding()] param()

    $items  = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[object]]::new()
    $ids    = @{}

    $folder = Get-PortalPath -Name CatalogItems
    foreach ($file in Get-ChildItem -LiteralPath $folder -Filter '*.json' -File | Sort-Object Name) {
        try {
            $item = Read-PortalJson -Path $file.FullName
            if ($null -eq $item) { throw 'File is empty.' }
            $problems = @(Test-PortalCatalogDefinition -Item $item)
            if (-not $problems -and $ids.ContainsKey($item.id)) { $problems = @("Duplicate id '$($item.id)' (also in $($ids[$item.id])).") }
            if ($problems) {
                $errors.Add([ordered]@{ file = $file.Name; id = (Get-Prop $item 'id'); errors = $problems })
                continue
            }
            $ids[$item.id] = $file.Name
            if (Get-Prop $item 'vmNotes' $false) { $item.inputs = @($item.inputs) + @(Get-PortalVmNoteInputs) }
            $item['_file'] = $file.Name
            $item['_updated'] = $file.LastWriteTimeUtc.ToString('o')
            $items.Add($item)
        }
        catch {
            $errors.Add([ordered]@{ file = $file.Name; id = $null; errors = @("Invalid JSON or unreadable file: $($_.Exception.Message)") })
        }
    }
    return [ordered]@{ items = $items.ToArray(); errors = $errors.ToArray() }
}

function Get-PortalCatalogItem {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Id)
    return ((Get-PortalCatalog).items | Where-Object { $_.id -eq $Id } | Select-Object -First 1)
}

function Test-PortalItemRequiresReauth {
    <# True when the item, or any of its inputs, asks for a recent re-authentication (submission and approval). #>
    param([Parameter(Mandatory)] $Item)
    $sec = Get-Prop $Item 'security' @{}
    if ((Get-Prop $sec 'requireReauth' $false)) { return $true }
    return [bool](@($Item.inputs) | Where-Object { Get-Prop $_ 'requireReauth' $false })
}

function Test-PortalItemAccess {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Item, [Parameter(Mandatory)] $User)
    if (-not (Get-Prop $Item 'enabled' $true)) { return $false }
    $roles = @(Get-Prop (Get-Prop $Item 'access') 'roles' @('Requester', 'Approver', 'Admin'))
    if (-not (Test-PortalRole -User $User -Role $roles)) { return $false }
    # Team scoping: Infrastructure items for Infrastructure, Cloud items for Cloud (Admins see all).
    return (Test-PortalTeamAccess -User $User -Teams @(Get-Prop (Get-Prop $Item 'access') 'teams' @()))
}

function ConvertTo-PortalPublicItem {
    <# Projection sent to the browser: no handler names or fixed parameters. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Item)
    return [ordered]@{
        id                = $Item.id
        version           = $Item.version
        name              = $Item.name
        category          = $Item.category
        icon              = Get-Prop $Item 'icon' 'generic'
        summary           = $Item.summary
        description       = Get-Prop $Item 'description' ''
        owner             = Get-Prop $Item 'owner' ''
        tags              = @(Get-Prop $Item 'tags' @())
        estimatedDuration = Get-Prop $Item 'estimatedDuration' ''
        approvalRequired  = [bool](Get-Prop (Get-Prop $Item 'approval') 'required' $false)
        teams             = @(Get-Prop (Get-Prop $Item 'access') 'teams' @())
        inputs            = @($Item.inputs)
    }
}

function Get-PortalCatalogForUser {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $User)
    return @((Get-PortalCatalog).items |
        Where-Object { Test-PortalItemAccess -Item $_ -User $User } |
        ForEach-Object { ConvertTo-PortalPublicItem -Item $_ })
}

#endregion

#region Inventory lookups -----------------------------------------------------------------------------------

function Get-PortalInventory {
    <# Returns the cached vCenter inventory for a site (written by automation/Update-VsphereInventory.ps1). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Site)
    if ($Site -notmatch '^[A-Za-z0-9_-]+$') { throw 'Invalid site code.' }
    $path = Join-Path (Get-PortalPath -Name Inventory) "$($Site.ToUpper()).json"
    return (Read-PortalJson -Path $path)
}

function Get-PortalLookupOptions {
    <#
    .SYNOPSIS Resolves the options of a 'source'-driven select input.
    .PARAMETER Values  Current form values (used for dependsOn: Site, Cluster, ...).
    .OUTPUTS   Array of @{ value; label }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Item,
        [Parameter(Mandatory)] [string] $InputName,
        [System.Collections.IDictionary] $Values = @{}
    )

    $in = @($Item.inputs) | Where-Object { $_.name -eq $InputName } | Select-Object -First 1
    if (-not $in) { throw "Input '$InputName' not found in item '$($Item.id)'." }

    # Fixed parameters (resolved for the selected site) behave like pre-filled form values, e.g. a pinned Workload.
    $siteKey = Get-Prop $Item.execution 'siteInput' 'Site'
    $merged = [ordered]@{}
    $fixed = Get-Prop $Item.execution 'fixedParameters' @{}
    foreach ($k in $fixed.Keys) { $merged[$k] = Resolve-PortalSiteValue -Value $fixed[$k] -Site ([string](Get-Prop $Values $siteKey)) }
    foreach ($k in $Values.Keys) { if ($null -ne $Values[$k] -and "$($Values[$k])" -ne '') { $merged[$k] = $Values[$k] } }
    $Values = $merged

    if ($in.type -eq 'credential') {
        # Vault entries this item may use (scope: items + teams), optionally narrowed by "vaultTags".
        $teams = @(Get-Prop (Get-Prop $Item 'access' @{}) 'teams' @())
        return @(Get-PortalVaultOption -ItemId $Item.id -Teams $teams -Tags @(Get-Prop $in 'vaultTags' @()))
    }

    $static = Get-Prop $in 'options'
    if ($static) { return @($static | ForEach-Object { [ordered]@{ value = [string]$_.value; label = [string]$_.label } }) }

    $src = Get-Prop $in 'source'
    if (-not $src) { return @() }
    $type   = $src.type
    $filter = Get-Prop $src 'filter'

    foreach ($d in @(Get-Prop $src 'dependsOn' @())) {
        if ([string]::IsNullOrWhiteSpace([string](Get-Prop $Values $d))) { return @() }   # parent not selected yet
    }

    if ($script:CloudSources -contains $type) {
        $rows = @(Get-PortalCloudLookup -Source $type)
        if ($filter) { $rows = @($rows | Where-Object { $_.value -match $filter }) }
        return $rows
    }

    if ($script:DataSources -contains $type) {
        $rows = switch ($type) {
            'softwareSets' {
                @(Get-PortalSoftwareSet -Os ([string](Get-Prop $src 'os' ''))) | ForEach-Object {
                    $pend = @($_.skipped).Count
                    [ordered]@{ value = $_.id; label = ('{0} ({1} approved package(s){2})' -f $_.name, @($_.packages).Count, $(if ($pend) { ", $pend not approved yet" } else { '' })) }
                }
            }
            'backupPolicies' {
                @((Get-PortalDataFile -Name backup).policies) | Where-Object { Get-Prop $_ 'enabled' $true } |
                    ForEach-Object { [ordered]@{ value = [string]$_.id; label = $(if (Get-Prop $_ 'description') { "$($_.id) - $($_.description)" } else { [string]$_.id }) } }
            }
        }
        $rows = @($rows)
        if ($filter) { $rows = @($rows | Where-Object { $_.value -match $filter }) }
        return $rows
    }

    if ($type -eq 'sites') {
        $allowed = @(Get-Prop $Item 'sites' @())
        return @(Get-PortalSite -EnabledOnly |
            Where-Object { -not $allowed -or $allowed -contains $_.code } |
            ForEach-Object { [ordered]@{ value = $_.code; label = "$($_.code) - $($_.name)" } })
    }

    $siteInput = Get-Prop $Item.execution 'siteInput' 'Site'
    $siteCode  = [string](Get-Prop $Values $siteInput)
    $site      = Get-PortalSite -Code $siteCode
    if (-not $site) { return @() }
    $inv = Get-PortalInventory -Site $siteCode
    if (-not $inv) { throw "Inventory for site $siteCode is not available yet. An Admin must run an inventory refresh." }
    $defaults = Get-Prop $site 'defaults' @{}

    $rows = switch ($type) {
        'clusters' {
            $allowedClusters = @(Get-Prop $defaults 'allowedClusters' @())
            @($inv.clusters) | Where-Object { -not $allowedClusters -or $allowedClusters -contains $_.name } |
                ForEach-Object { [ordered]@{ value = $_.name; label = ('{0} ({1} hosts)' -f $_.name, (Get-Prop $_ 'hosts' '?')) } }
        }
        'datastores' {
            $cluster = [string](Get-Prop $Values 'Cluster')
            if (-not $cluster) { $cluster = [string](Get-PortalWorkloadCluster -Site $siteCode -Workload ([string](Get-Prop $Values 'Workload'))) }
            if (-not $cluster -and (Get-Prop $Values 'Workload')) { return @() }
            $minFree = [double](Get-Prop $src 'minFreeGB' 0)
            @($inv.datastores) |
                Where-Object { -not (Get-Prop $_ 'maintenance' $false) -and (Get-Prop $_ 'accessible' $true) } |
                Where-Object { -not $cluster -or @(Get-Prop $_ 'clusters' @()) -contains $cluster } |
                Where-Object { [double](Get-Prop $_ 'freeGB' 0) -ge $minFree } |
                Sort-Object { [double](Get-Prop $_ 'freeGB' 0) } -Descending |
                ForEach-Object {
                    $free = [double](Get-Prop $_ 'freeGB' 0); $cap = [double](Get-Prop $_ 'capacityGB' 0)
                    $pct = if ($cap -gt 0) { [math]::Round(100 * $free / $cap) } else { 0 }
                    [ordered]@{ value = $_.name; label = ('{0} - {1:N0} GB free ({2}%)' -f $_.name, $free, $pct) }
                }
        }
        'datastoreClusters' {
            @($inv.datastoreClusters) | ForEach-Object { [ordered]@{ value = $_.name; label = ('{0} - {1:N0} GB free' -f $_.name, [double](Get-Prop $_ 'freeGB' 0)) } }
        }
        'portgroups' {
            $siteFilter = Get-Prop $defaults 'portgroupFilter'
            @($inv.portgroups) | Where-Object { -not $siteFilter -or $_.name -match $siteFilter } |
                ForEach-Object { $vl = Get-Prop $_ 'vlanId'; [ordered]@{ value = $_.name; label = if ($null -ne $vl) { "$($_.name) (VLAN $vl)" } else { $_.name } } }
        }
        'templates' { @($inv.templates) | ForEach-Object { [ordered]@{ value = $_.name; label = $_.name } } }
        'folders'   { @($inv.folders)   | ForEach-Object { [ordered]@{ value = $_.path; label = $_.path } } }
        'vms' {
            $ps = Get-Prop $src 'powerState'
            $cl = if ((Get-Prop $src 'byCluster' $false)) { [string](Get-Prop $Values (Get-Prop $src 'clusterInput' 'Cluster')) } else { '' }
            @($inv.vms) | Where-Object { (-not $ps -or (Get-Prop $_ 'powerState') -eq $ps) -and (-not $cl -or (Get-Prop $_ 'cluster') -eq $cl) } |
                ForEach-Object { [ordered]@{ value = $_.name; label = ('{0} ({1})' -f $_.name, (Get-Prop $_ 'cluster' '-')) } }
        }
        'hosts' {
            if (-not $inv.Contains('hosts')) { throw "The inventory of $siteCode predates host collection. An Admin must run an inventory refresh." }
            $cl = [string](Get-Prop $Values (Get-Prop $src 'clusterInput' 'Cluster'))
            $allowedClusters = @(Get-Prop $defaults 'allowedClusters' @())
            $want = Get-Prop $src 'state'        # connected | maintenance (optional)
            @($inv.hosts) | Where-Object { -not $cl -or $_.cluster -eq $cl } |
                Where-Object { -not $allowedClusters -or $allowedClusters -contains $_.cluster } |
                Where-Object { -not $want -or ($want -eq 'maintenance' -and $_.maintenance) -or ($want -eq 'connected' -and -not $_.maintenance -and $_.connectionState -eq 'Connected') } |
                ForEach-Object {
                    $st = if ($_.maintenance) { 'maintenance' } else { [string]$_.connectionState }
                    [ordered]@{ value = $_.name; label = ('{0} - {1} - ESXi {2} build {3} - {4}' -f $_.name, (Get-Prop $_ 'cluster' '-'), $_.version, $_.build, $st) }
                }
        }
        'vdSwitches' {
            if (-not $inv.Contains('vdSwitches')) { throw "The inventory of $siteCode predates switch collection. An Admin must run an inventory refresh." }
            @($inv.vdSwitches) | ForEach-Object { [ordered]@{ value = $_.name; label = ('{0} (v{1}, {2} hosts)' -f $_.name, $_.version, $_.hosts) } }
        }
        'storageDevices' {
            $cl = [string](Get-Prop $Values (Get-Prop $src 'clusterInput' 'Cluster'))
            if (-not $cl) { return @() }
            @(Get-PortalStorageDeviceOption -Site $siteCode -Cluster $cl)
        }
    }

    $rows = @($rows)
    if ($filter) { $rows = @($rows | Where-Object { $_.value -match $filter }) }
    if ($type -in 'datastores', 'storageDevices') { return $rows }        # already ordered
    return @($rows | Sort-Object { $_.label })
}

#endregion

#region Request input validation ----------------------------------------------------------------------------

function Test-PortalInputVisible {
    param($InputDef, [System.Collections.IDictionary] $Values)
    $vw = Get-Prop $InputDef 'visibleWhen'
    if (-not $vw) { return $true }
    return ([string](Get-Prop $Values (Get-Prop $vw 'field')) -eq [string](Get-Prop $vw 'equals'))
}

function Test-PortalRequestInput {
    <#
    .SYNOPSIS Server-side validation and normalisation of submitted form values against the item definition.
    .OUTPUTS  @{ valid = bool; errors = @{ field = message }; values = ordered hashtable }
    .NOTES    Never trust the browser: every select value is checked against its option list (static or inventory).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Item,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Submitted
    )

    $errors = [ordered]@{}
    $values = [ordered]@{}

    foreach ($in in @($Item.inputs)) {
        $name = $in.name
        $type = $in.type
        if (-not (Test-PortalInputVisible -InputDef $in -Values $values)) { continue }

        $raw = Get-Prop $Submitted $name
        if ($null -eq $raw -or ($raw -is [string] -and [string]::IsNullOrWhiteSpace($raw))) {
            $raw = Get-Prop $in 'default'
        }
        $isEmpty = ($null -eq $raw -or ($raw -is [string] -and [string]::IsNullOrWhiteSpace($raw)))
        $required = [bool](Get-Prop $in 'required' $false)

        if ($type -eq 'boolean') {
            $values[$name] = if ($isEmpty) { $false } else { [System.Convert]::ToBoolean(([string]$raw).Trim()) }
            continue
        }
        if ($isEmpty) {
            if ($required) { $errors[$name] = "$($in.label) is required." }
            continue
        }

        $v = ([string]$raw).Trim()
        switch (Get-Prop $in 'transform') {
            'upper' { $v = $v.ToUpperInvariant() }
            'lower' { $v = $v.ToLowerInvariant() }
        }
        $rules = Get-Prop $in 'validation' @{}

        switch ($type) {
            'number' {
                $num = 0.0
                if (-not [double]::TryParse($v, [System.Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$num)) {
                    $errors[$name] = "$($in.label) must be a number."; break
                }
                $min = Get-Prop $rules 'min'; $max = Get-Prop $rules 'max'
                if ($null -ne $min -and $num -lt [double]$min) { $errors[$name] = "$($in.label) must be >= $min."; break }
                if ($null -ne $max -and $num -gt [double]$max) { $errors[$name] = "$($in.label) must be <= $max."; break }
                $values[$name] = if ($num -eq [math]::Floor($num)) { [int64]$num } else { $num }
            }
            'ipv4' {
                $ip = $null
                if ($v -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or -not [System.Net.IPAddress]::TryParse($v, [ref]$ip)) {
                    $errors[$name] = "$($in.label) must be a valid IPv4 address."; break
                }
                $values[$name] = $v
            }
            { $_ -in 'select', 'credential' } {
                try {
                    $opts = @(Get-PortalLookupOptions -Item $Item -InputName $name -Values $values)
                    if (@($opts | ForEach-Object { [string]$_.value }) -cnotcontains $v) {
                        $errors[$name] = "$($in.label): '$v' is not an allowed value."; break
                    }
                    $values[$name] = $v
                }
                catch { $errors[$name] = "$($in.label): $($_.Exception.Message)" }
            }
            default {
                # text / textarea
                $minL = Get-Prop $rules 'minLength'; $maxL = Get-Prop $rules 'maxLength'; $pat = Get-Prop $rules 'pattern'
                if ($null -ne $minL -and $v.Length -lt [int]$minL) { $errors[$name] = "$($in.label) must have at least $minL characters."; break }
                if ($null -ne $maxL -and $v.Length -gt [int]$maxL) { $errors[$name] = "$($in.label) must have at most $maxL characters."; break }
                if ($pat -and $v -notmatch $pat) { $errors[$name] = (Get-Prop $rules 'patternMessage' "$($in.label) has an invalid format."); break }
                $values[$name] = $v
            }
        }
    }

    return [ordered]@{ valid = ($errors.Count -eq 0); errors = $errors; values = $values }
}

#endregion

#region Catalog administration (Admin UI) ----------------------------------------------------------------------

function Get-PortalCatalogItemFile {
    <# Raw definition of an item by id, including disabled or invalid ones (for the editor). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Id)
    if ($Id -notmatch '^[a-z0-9][a-z0-9-]{2,62}$') { throw 'Invalid item id.' }
    foreach ($f in Get-ChildItem -LiteralPath (Get-PortalPath -Name CatalogItems) -Filter '*.json' -File) {
        try { $i = Read-PortalJson -Path $f.FullName } catch { continue }
        if ($i -and (Get-Prop $i 'id') -eq $Id) { return [ordered]@{ file = $f.FullName; item = $i } }
    }
    return $null
}

function Save-PortalCatalogItem {
    <#
    .SYNOPSIS Validates and writes catalog/items/<id>.json. Returns @{ saved; errors; file }.
    .PARAMETER New  Refuse to overwrite an existing id (create mode).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Item,
        [Parameter(Mandatory)] [string] $Actor,
        [switch] $New,
        [switch] $ValidateOnly
    )
    # Strip runtime-only keys and normalise.
    foreach ($k in @('_file', '_updated')) { if ($Item.Contains($k)) { $Item.Remove($k) } }
    if (-not $Item.Contains('$schema')) {
        $ordered = [ordered]@{ '$schema' = '../schema/catalog-item.schema.json' }
        foreach ($k in $Item.Keys) { $ordered[$k] = $Item[$k] }
        $Item = $ordered
    }
    $errors = @(Test-PortalCatalogDefinition -Item $Item)
    $existing = if ($Item['id'] -match '^[a-z0-9][a-z0-9-]{2,62}$') { Get-PortalCatalogItemFile -Id $Item.id } else { $null }
    if ($New -and $existing) { $errors += "An item with id '$($Item.id)' already exists ($(Split-Path -Leaf $existing.file))." }
    if ($errors -or $ValidateOnly) { return [ordered]@{ saved = $false; errors = $errors; file = $null } }

    $target = if ($existing) { $existing.file } else { Join-Path (Get-PortalPath -Name CatalogItems) "$($Item.id).json" }
    Invoke-PortalLock -Name 'catalog' -ScriptBlock {
        if ($existing) {
            $bak = Join-Path (Get-PortalRoot) ('catalog/_archive/{0}.{1:yyyyMMddHHmmss}.json' -f $Item.id, (Get-Date))
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $bak) -Force
            Copy-Item -LiteralPath $existing.file -Destination $bak
        }
        Write-PortalJson -Path $target -Value $Item
    } | Out-Null
    Write-PortalAudit -Actor $Actor -Action ($(if ($existing) { 'catalog.update' } else { 'catalog.create' })) -Target $Item.id -Details @{ version = $Item.version; file = (Split-Path -Leaf $target) }
    return [ordered]@{ saved = $true; errors = @(); file = (Split-Path -Leaf $target) }
}

function Remove-PortalCatalogItem {
    <# Moves the item file to catalog/_archive (never hard-deleted). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Id, [Parameter(Mandatory)] [string] $Actor)
    $existing = Get-PortalCatalogItemFile -Id $Id
    if (-not $existing) { throw "Catalog item '$Id' not found." }
    $dest = Join-Path (Get-PortalRoot) ('catalog/_archive/{0}.deleted.{1:yyyyMMddHHmmss}.json' -f $Id, (Get-Date))
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force
    Move-Item -LiteralPath $existing.file -Destination $dest
    Write-PortalAudit -Actor $Actor -Action 'catalog.delete' -Target $Id -Details @{ archivedAs = (Split-Path -Leaf $dest) }
}

function Get-PortalHandlerList {
    <# Handler scripts available in every allowed root (templates excluded). #>
    [CmdletBinding()] param()
    $handlersDir = [System.IO.Path]::GetFullPath((Get-PortalPath -Name Handlers))
    foreach ($root in Get-PortalHandlerRoot) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($f in Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File -Recurse | Where-Object Name -notlike '_*') {
            $ref = if ($f.DirectoryName -eq $handlersDir.TrimEnd('\', '/')) { $f.Name } else { $f.FullName }
            [ordered]@{ handler = $ref; path = $f.FullName; updated = $f.LastWriteTimeUtc.ToString('o') }
        }
    }
}

function New-PortalHandlerStub {
    <#
    .SYNOPSIS Creates a handler skeleton whose param() block matches the item inputs and fixed parameters.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Handler,
        [string[]] $Parameters = @(),
        [bool] $RequiresVCenter = $true,
        [Parameter(Mandatory)] [string] $Actor
    )
    $path = Resolve-PortalHandlerPath -Handler $Handler
    if (Test-Path -LiteralPath $path) { throw "Handler already exists: $path" }
    $params = @($Parameters | Where-Object { $_ -and $_ -ne 'Context' } | Select-Object -Unique | ForEach-Object { "    `$$_," })
    $vi = if ($RequiresVCenter) { "`$vi = `$Context.VIServer      # open PowerCLI session to the selected site`n" } else { '' }
    $content = @"
#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler generated by the portal on $(Get-Date -Format 'yyyy-MM-dd') - implement the automation below.
.DESCRIPTION
    Contract: one parameter per catalog input / fixed parameter, plus -Context (RequestId, Requester, Site, VIServer).
    Log with Write-JobLog "text" -Level STEP|OK|INFO|WARN|ERROR. Return a hashtable (shown as result). Throw to fail.
#>
[CmdletBinding()]
param(
$($params -join "`n")
    [Parameter(Mandatory)] `$Context
)

`$ErrorActionPreference = 'Stop'
$vi
Write-JobLog -Level STEP "Starting `$(`$Context.RequestId)"

# TODO: automation logic here (always pass -Server `$vi to PowerCLI cmdlets)
throw 'Handler not implemented yet.'

return [ordered]@{
    Status    = 'Done'
    NextSteps = @()
}
"@
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
    Set-Content -LiteralPath $path -Value $content -Encoding utf8
    Write-PortalAudit -Actor $Actor -Action 'handler.create' -Target $path
    return $path
}

#endregion

Export-ModuleMember -Function Test-PortalItemRequiresReauth, Get-PortalVmNoteInputs, Get-PortalHandlerInfo, Get-PortalCatalogItemFile, Save-PortalCatalogItem, Remove-PortalCatalogItem,
    Get-PortalHandlerList, New-PortalHandlerStub,
    Test-PortalCatalogDefinition, Get-PortalCatalog, Get-PortalCatalogItem, Test-PortalItemAccess,
    ConvertTo-PortalPublicItem, Get-PortalCatalogForUser, Get-PortalInventory, Get-PortalLookupOptions, Test-PortalRequestInput
