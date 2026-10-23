#Requires -Version 7.2
<#
.SYNOPSIS
    Portal.AriaOps - read-only client for VMware Aria Operations / VCF Operations (suite-api) used by job runners and handlers.
.DESCRIPTION
    One connection per site, configured in portal.config.json -> sites[].aria (Admin > vCenter connections > Aria Operations):
        enabled, endpoint (FQDN), authSource ('local' or the name of an AD / vIDM source), credential { type: Vault, id },
        invalidCertificateAction (Ignore | Fail), useSystemProxy, objectUrlTemplate, reports [ { id, name, subject } ] (definitions offered in forms).
    The password stays in the portal vault. Connect-PortalAria acquires a short-lived token (POST /auth/token/acquire);
    Disconnect-PortalAria releases it. The token is added to the job's secret list so it is never written to a log.

    Every call goes through Invoke-PortalAriaRequest. A connection object may carry a 'Transport' scriptblock
    (param($Method, $Path, $Body, $OutFile)) that replaces the HTTP call - the offline tests use it.

    Times: the API uses epoch milliseconds (UTC). Functions take and return [DateTimeOffset].
#>

Set-StrictMode -Version Latest

function Get-AriaVal {
    param($Object, [string] $Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] } return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function Get-PortalAriaSettings {
    <# The aria section of a site (or $null when not configured / disabled). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Site, [switch] $IncludeDisabled)
    $a = Get-AriaVal $Site 'aria'
    if (-not $a) { return $null }
    if (-not $IncludeDisabled -and -not (Get-AriaVal $a 'enabled' $false)) { return $null }
    if (-not [string](Get-AriaVal $a 'endpoint' '')) { return $null }
    return $a
}

function ConvertTo-AriaEpoch { param([DateTimeOffset] $Time) return $Time.ToUnixTimeMilliseconds() }
function ConvertFrom-AriaEpoch { param($Ms) return [DateTimeOffset]::FromUnixTimeMilliseconds([long]$Ms) }

function Invoke-PortalAriaRequest {
    <#
    .SYNOPSIS Calls suite-api. Path is relative to /suite-api/api (e.g. '/resources?name=x'). Returns the parsed JSON.
    .PARAMETER OutFile  Binary download (report files); returns the file path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Aria,
        [ValidateSet('Get', 'Post', 'Put', 'Delete')] [string] $Method = 'Get',
        [Parameter(Mandatory)] [string] $Path,
        $Body,
        [string] $OutFile
    )
    $transport = Get-AriaVal $Aria 'Transport'
    if ($transport) { return (& $transport $Method $Path $Body $OutFile) }

    $uri = $Aria.BaseUri + $Path
    $headers = @{ Accept = 'application/json' }
    if ($Aria.Token) { $headers['Authorization'] = "OpsToken $($Aria.Token)" }
    $p = @{ Method = $Method; Uri = $uri; Headers = $headers; TimeoutSec = [int]$Aria.TimeoutSec; ErrorAction = 'Stop' }
    if ($Aria.SkipCertificateCheck) { $p['SkipCertificateCheck'] = $true }
    if ($Aria.NoProxy) { $p['NoProxy'] = $true }
    if ($null -ne $Body) { $p['Body'] = ($Body | ConvertTo-Json -Depth 10 -Compress); $p['ContentType'] = 'application/json' }
    try {
        if ($OutFile) {
            $headers['Accept'] = '*/*'
            $null = Invoke-WebRequest @p -OutFile $OutFile
            return $OutFile
        }
        return (Invoke-RestMethod @p)
    }
    catch {
        $code = $null
        try { $code = [int]$_.Exception.Response.StatusCode } catch { $code = $null }
        $msg = $_.Exception.Message
        if ($Aria.Token) { $msg = $msg.Replace([string]$Aria.Token, '********') }
        $hint = switch ($code) {
            401 { ' Authentication failed: check the account, its auth source and that the token is still valid.' }
            403 { ' The account has no permission for this call (read-only role + Reports permission are needed).' }
            404 { ' Not found (object or API path; check the Aria Operations version).' }
            default { '' }
        }
        throw "Aria Operations $Method $Path failed$(if ($code) { " (HTTP $code)" }): $msg$hint"
    }
}

function Connect-PortalAria {
    <#
    .SYNOPSIS Acquires an Aria Operations token for a site. Returns the connection object used by every other function.
    .PARAMETER Site  Site configuration (Get-PortalSite) or site code.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Site,
        [pscredential] $Credential,
        [int] $TimeoutSec = 60
    )
    if ($Site -is [string]) { $code = $Site; $Site = Get-PortalSite -Code $code; if (-not $Site) { throw "Site '$code' is not defined." } }
    $a = Get-PortalAriaSettings -Site $Site -IncludeDisabled
    if (-not $a) { throw "Aria Operations is not configured for site $($Site.code) (Admin > vCenter connections > Aria Operations)." }
    $endpoint = ([string](Get-AriaVal $a 'endpoint' '')).Trim() -replace '^https?://', '' -replace '/.*$', ''
    if ($endpoint -notmatch '^[A-Za-z0-9.-]+(:\d{1,5})?$') { throw "Aria Operations endpoint '$endpoint' is not a valid host name." }

    if (-not $Credential) {
        $c = Get-AriaVal $a 'credential' @{}
        $id = [string](Get-AriaVal $c 'id' '')
        if (-not $id) { throw "No Aria Operations credential stored for site $($Site.code). Admin > vCenter connections > Aria Operations: enter the account and password, then Save." }
        if (-not (Get-Command Get-PortalVaultCredential -ErrorAction SilentlyContinue)) { Import-Module (Join-Path (Get-PortalRoot) 'modules/Portal.Vault.psm1') -Force -Global }
        try { $Credential = Get-PortalVaultCredential -Id $id -Purpose site -Actor "aria:$($Site.code)" }
        catch { throw "Aria Operations credential for site $($Site.code): $($_.Exception.Message)" }
    }
    $conn = [pscustomobject]@{
        Site                 = [string]$Site.code
        Endpoint             = $endpoint
        BaseUri              = "https://$endpoint/suite-api/api"
        UiUri                = "https://$endpoint/ui/"
        AuthSource           = [string](Get-AriaVal $a 'authSource' 'local')
        SkipCertificateCheck = ([string](Get-AriaVal $a 'invalidCertificateAction' 'Ignore') -ne 'Fail')
        NoProxy              = -not [bool](Get-AriaVal $a 'useSystemProxy' $false)
        TimeoutSec           = $TimeoutSec
        Token                = $null
        ValidUntil           = $null
        Version              = ''
        ObjectUrlTemplate    = [string](Get-AriaVal $a 'objectUrlTemplate' '')
        Transport            = $null
    }
    $body = [ordered]@{ username = $Credential.UserName; password = $Credential.GetNetworkCredential().Password }
    if ($conn.AuthSource -and $conn.AuthSource -ne 'local') { $body['authSource'] = $conn.AuthSource }
    $tok = Invoke-PortalAriaRequest -Aria $conn -Method Post -Path '/auth/token/acquire' -Body $body
    if (-not (Get-AriaVal $tok 'token')) { throw "Aria Operations at $endpoint did not return a token." }
    $conn.Token = [string]$tok.token
    if (Get-AriaVal $tok 'validity') { $conn.ValidUntil = ConvertFrom-AriaEpoch $tok.validity }
    if ($global:JobSecrets -is [System.Collections.Generic.List[string]]) { $global:JobSecrets.Add($conn.Token) }
    try { $v = Invoke-PortalAriaRequest -Aria $conn -Path '/versions/current'; $conn.Version = [string](Get-AriaVal $v 'releaseName' (Get-AriaVal $v 'humanlyReadableReleaseDate' '')) } catch { $conn.Version = '' }
    return $conn
}

function Disconnect-PortalAria {
    <# Releases the token (best effort). #>
    [CmdletBinding()] param($Aria)
    if (-not $Aria -or -not $Aria.Token) { return }
    try { $null = Invoke-PortalAriaRequest -Aria $Aria -Method Post -Path '/auth/token/release' } catch { Write-Verbose "Token release failed: $($_.Exception.Message)" }
    $Aria.Token = $null
}

function ConvertTo-AriaResource {
    param($R)
    $key = Get-AriaVal $R 'resourceKey' @{}
    $health = Get-AriaVal $R 'resourceHealth' ''
    [pscustomobject]@{
        Id      = [string](Get-AriaVal $R 'identifier' '')
        Name    = [string](Get-AriaVal $key 'name' '')
        Kind    = [string](Get-AriaVal $key 'resourceKindKey' '')
        Adapter = [string](Get-AriaVal $key 'adapterKindKey' '')
        Health  = [string]$health
        Status  = [string](@(Get-AriaVal $R 'resourceStatusStates' @()) | ForEach-Object { Get-AriaVal $_ 'resourceStatus' '' } | Select-Object -First 1)
    }
}

function Find-PortalAriaResource {
    <# Resource by exact name and kind (VirtualMachine, HostSystem, Datastore, ClusterComputeResource). $null when not found. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Aria, [Parameter(Mandatory)] [string] $Name, [string] $ResourceKind = 'VirtualMachine')
    $q = '/resources?name=' + [uri]::EscapeDataString($Name) + '&resourceKind=' + [uri]::EscapeDataString($ResourceKind) + '&adapterKind=VMWARE&pageSize=50'
    $r = Invoke-PortalAriaRequest -Aria $Aria -Path $q
    $list = @(Get-AriaVal $r 'resourceList' @()) | ForEach-Object { ConvertTo-AriaResource $_ } | Where-Object { $_.Name -eq $Name }
    $list = @($list)
    if ($list.Count -gt 1) { Write-Verbose "$($list.Count) $ResourceKind resources are named $Name in Aria; using the first one." }
    return ($list | Select-Object -First 1)
}

function Get-PortalAriaRelated {
    <# Parents (host, datastores, cluster...) or children of a resource. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Aria, [Parameter(Mandatory)] [string] $ResourceId, [ValidateSet('parents', 'children')] [string] $Relation = 'parents')
    $r = Invoke-PortalAriaRequest -Aria $Aria -Path "/resources/$ResourceId/relationships/$Relation"
    return @(@(Get-AriaVal $r 'resourceList' @()) | ForEach-Object { ConvertTo-AriaResource $_ })
}

function Get-PortalAriaStatKey {
    <# Stat keys of a resource matching a regular expression. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Aria, [Parameter(Mandatory)] [string] $ResourceId, [string] $Pattern = '.')
    $r = Invoke-PortalAriaRequest -Aria $Aria -Path "/resources/$ResourceId/statkeys"
    return @(@(Get-AriaVal $r 'stat-key' @()) | ForEach-Object { [string](Get-AriaVal $_ 'key' '') } | Where-Object { $_ -and $_ -match $Pattern } | Sort-Object -Unique)
}

function Get-PortalAriaStats {
    <#
    .SYNOPSIS Time series for one or more resources and stat keys (stats/query).
    .OUTPUTS  [pscustomobject] @{ ResourceId; StatKey; Time ([DateTimeOffset] UTC); Value }
    .PARAMETER RollUp  MAX keeps the peaks (troubleshooting); AVG for trends.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Aria,
        [Parameter(Mandatory)] [string[]] $ResourceId,
        [Parameter(Mandatory)] [string[]] $StatKey,
        [Parameter(Mandatory)] [DateTimeOffset] $Start,
        [Parameter(Mandatory)] [DateTimeOffset] $End,
        [ValidateSet('MAX', 'AVG', 'MIN', 'SUM', 'LATEST')] [string] $RollUp = 'MAX',
        [ValidateRange(1, 1440)] [int] $IntervalMinutes = 5
    )
    if (-not @($StatKey).Count) { return @() }
    $body = [ordered]@{
        resourceId = @($ResourceId); statKey = @($StatKey)
        begin = ConvertTo-AriaEpoch $Start; end = ConvertTo-AriaEpoch $End
        rollUpType = $RollUp; intervalType = 'MINUTES'; intervalQuantifier = $IntervalMinutes
    }
    $r = Invoke-PortalAriaRequest -Aria $Aria -Method Post -Path '/resources/stats/query' -Body $body
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($v in @(Get-AriaVal $r 'values' @())) {
        $rid = [string](Get-AriaVal $v 'resourceId' '')
        foreach ($s in @(Get-AriaVal (Get-AriaVal $v 'stat-list' @{}) 'stat' @())) {
            $key = [string](Get-AriaVal (Get-AriaVal $s 'statKey' @{}) 'key' '')
            $ts = @(Get-AriaVal $s 'timestamps' @()); $data = @(Get-AriaVal $s 'data' @())
            for ($i = 0; $i -lt [math]::Min($ts.Count, $data.Count); $i++) {
                $rows.Add([pscustomobject]@{ ResourceId = $rid; StatKey = $key; Time = (ConvertFrom-AriaEpoch $ts[$i]); Value = [double]$data[$i] })
            }
        }
    }
    return $rows.ToArray()
}

function Get-PortalAriaLatest {
    <# Latest value of stat keys for one resource: ordered @{ key = value }. Missing keys are omitted. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Aria, [Parameter(Mandatory)] [string] $ResourceId, [Parameter(Mandatory)] [string[]] $StatKey)
    $q = "/resources/$ResourceId/stats/latest?" + ((@($StatKey) | ForEach-Object { 'statKey=' + [uri]::EscapeDataString($_) }) -join '&')
    $r = Invoke-PortalAriaRequest -Aria $Aria -Path $q
    $out = [ordered]@{}
    foreach ($v in @(Get-AriaVal $r 'values' @())) {
        foreach ($s in @(Get-AriaVal (Get-AriaVal $v 'stat-list' @{}) 'stat' @())) {
            $key = [string](Get-AriaVal (Get-AriaVal $s 'statKey' @{}) 'key' '')
            $data = @(Get-AriaVal $s 'data' @())
            if ($key -and $data.Count) { $out[$key] = [double]$data[-1] }
        }
    }
    return $out
}

function Get-PortalAriaBadges {
    <# Health / Risk / Efficiency scores (0-100) of a resource. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Aria, [Parameter(Mandatory)] [string] $ResourceId)
    $l = Get-PortalAriaLatest -Aria $Aria -ResourceId $ResourceId -StatKey 'badge|health', 'badge|risk', 'badge|efficiency'
    return [ordered]@{
        Health     = $(if ($l.Contains('badge|health')) { [math]::Round($l['badge|health']) } else { $null })
        Risk       = $(if ($l.Contains('badge|risk')) { [math]::Round($l['badge|risk']) } else { $null })
        Efficiency = $(if ($l.Contains('badge|efficiency')) { [math]::Round($l['badge|efficiency']) } else { $null })
    }
}

function Get-PortalAriaAlerts {
    <#
    .SYNOPSIS Alerts of resources; with Start/End only alerts that overlap the window.
    .OUTPUTS  @{ ResourceId; Name; Level; Status; Started; Updated; Cancelled }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Aria,
        [Parameter(Mandatory)] [string[]] $ResourceId,
        [Nullable[DateTimeOffset]] $Start,
        [Nullable[DateTimeOffset]] $End,
        [switch] $ActiveOnly
    )
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($id in @($ResourceId | Where-Object { $_ })) {
        $r = Invoke-PortalAriaRequest -Aria $Aria -Path ("/alerts?resourceId=$id&activeOnly=$(([bool]$ActiveOnly).ToString().ToLower())&pageSize=500")
        foreach ($a in @(Get-AriaVal $r 'alerts' @())) {
            $st = [long](Get-AriaVal $a 'startTimeUTC' 0); $up = [long](Get-AriaVal $a 'updateTimeUTC' $st); $ca = [long](Get-AriaVal $a 'cancelTimeUTC' 0)
            if ($End -and $st -gt (ConvertTo-AriaEpoch ([DateTimeOffset]$End))) { continue }
            if ($Start) {
                $last = if ($ca -gt 0) { $ca } else { [math]::Max($up, [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) }
                if ($last -lt (ConvertTo-AriaEpoch ([DateTimeOffset]$Start))) { continue }
            }
            $rows.Add([pscustomobject]@{
                ResourceId = $id
                Name       = [string](Get-AriaVal $a 'alertDefinitionName' '')
                Level      = [string](Get-AriaVal $a 'alertLevel' '')
                Status     = [string](Get-AriaVal $a 'status' '')
                Started    = $(if ($st) { ConvertFrom-AriaEpoch $st } else { $null })
                Updated    = $(if ($up) { ConvertFrom-AriaEpoch $up } else { $null })
                Cancelled  = $(if ($ca) { ConvertFrom-AriaEpoch $ca } else { $null })
            })
        }
    }
    return $rows.ToArray()
}

function Get-PortalAriaReportDefinitions {
    <# Report definitions available in Aria: @{ id; name; description; subject }. #>
    [CmdletBinding()] param([Parameter(Mandatory)] $Aria)
    $r = Invoke-PortalAriaRequest -Aria $Aria -Path '/reportdefinitions?pageSize=1000'
    return @(@(Get-AriaVal $r 'reportDefinitions' @()) | ForEach-Object {
        [ordered]@{ id = [string](Get-AriaVal $_ 'id' ''); name = [string](Get-AriaVal $_ 'name' ''); description = [string](Get-AriaVal $_ 'description' '')
                    subject = @(Get-AriaVal $_ 'subject' @()) | ForEach-Object { [string]$_ } }
    } | Where-Object { $_.id } | Sort-Object { $_.name })
}

function Invoke-PortalAriaReport {
    <#
    .SYNOPSIS Generates a report definition for a resource, waits for it and downloads the requested formats.
    .OUTPUTS  @{ ReportId; Status; Files = @(paths) }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Aria,
        [Parameter(Mandatory)] [string] $DefinitionId,
        [Parameter(Mandatory)] [string] $ResourceId,
        [Parameter(Mandatory)] [string] $OutDir,
        [string] $BaseName = 'aria-report',
        [ValidateSet('PDF', 'CSV')] [string[]] $Format = @('PDF'),
        [int] $TimeoutSeconds = 600,
        [int] $PollSeconds = 10
    )
    $null = New-Item -ItemType Directory -Path $OutDir -Force
    $created = Invoke-PortalAriaRequest -Aria $Aria -Method Post -Path '/reports' -Body ([ordered]@{ resourceId = $ResourceId; reportDefinitionId = $DefinitionId })
    $rid = [string](Get-AriaVal $created 'id' '')
    if (-not $rid) { throw 'Aria Operations did not return a report id.' }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $status = [string](Get-AriaVal $created 'status' '')
    while ($status -notin 'COMPLETED', 'FAILED') {
        if ((Get-Date) -ge $deadline) { throw "Aria report $rid is still '$status' after $TimeoutSeconds s." }
        if ($PollSeconds -gt 0) { Start-Sleep -Seconds $PollSeconds }
        $status = [string](Get-AriaVal (Invoke-PortalAriaRequest -Aria $Aria -Path "/reports/$rid") 'status' '')
    }
    if ($status -eq 'FAILED') { throw "Aria Operations could not generate report $rid (status FAILED). Check the definition applies to this object type." }
    $files = foreach ($f in $Format) {
        $path = Join-Path $OutDir ('{0}.{1}' -f $BaseName, $f.ToLowerInvariant())
        $null = Invoke-PortalAriaRequest -Aria $Aria -Path "/reports/$rid/download?format=$f" -OutFile $path
        if (-not (Test-Path -LiteralPath $path)) { throw "Report $rid ($f) was not downloaded." }
        $path
    }
    return [ordered]@{ ReportId = $rid; Status = $status; Files = @($files) }
}

function Get-PortalAriaResourceUrl {
    <# Link to the object in the Aria Operations UI: sites[].aria.objectUrlTemplate ({endpoint}, {id}) or the UI home page. #>
    param([Parameter(Mandatory)] $Aria, [Parameter(Mandatory)] [string] $ResourceId)
    $t = [string](Get-AriaVal $Aria 'ObjectUrlTemplate' '')
    if (-not $t) { return [string]$Aria.UiUri }
    return $t.Replace('{endpoint}', [string]$Aria.Endpoint).Replace('{id}', [uri]::EscapeDataString($ResourceId))
}

Export-ModuleMember -Function Get-PortalAriaSettings, Invoke-PortalAriaRequest, Connect-PortalAria, Disconnect-PortalAria, Find-PortalAriaResource,
    Get-PortalAriaRelated, Get-PortalAriaStatKey, Get-PortalAriaStats, Get-PortalAriaLatest, Get-PortalAriaBadges, Get-PortalAriaAlerts,
    Get-PortalAriaReportDefinitions, Invoke-PortalAriaReport, Get-PortalAriaResourceUrl
