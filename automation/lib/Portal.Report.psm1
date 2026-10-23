#Requires -Version 7.2
<#
.SYNOPSIS
    Portal.Report - HTML / CSV reports produced by catalog items (health, versions, hardening, certificates, capacity...).
.DESCRIPTION
    A handler builds sections (title, columns, rows) and calls New-PortalReport. Files are written to the request's
    report folder (Context.ReportDir = data/reports/<REQ-ID>) and listed on the request page. The HTML is fully
    self-contained (inline CSS, no script) and every value is HTML-encoded; the portal serves it with a CSP that
    forbids scripts.
    A column named Status colours its cells: OK / PASS (green), WARN / WARNING (amber), FAIL / CRITICAL / ERROR (red).
#>

Set-StrictMode -Version Latest

function ConvertTo-PortalHtmlText { param($Value) return [System.Net.WebUtility]::HtmlEncode([string]$Value) }

function New-PortalReportSection {
    <# Convenience constructor. Rows: hashtables / pscustomobjects; Columns: ordered list of property names (default: keys of the first row). #>
    param([Parameter(Mandatory)] [string] $Title, $Rows = @(), [string[]] $Columns, [string] $Note)
    $rows = @($Rows | Where-Object { $null -ne $_ })
    if (-not $Columns -and $rows.Count) {
        $first = $rows[0]
        $Columns = if ($first -is [System.Collections.IDictionary]) { @($first.Keys) } else { @($first.PSObject.Properties.Name) }
    }
    return [ordered]@{ title = $Title; columns = @($Columns); rows = $rows; note = $Note }
}

function New-PortalReportChart {
    <#
    .SYNOPSIS Chart section (inline SVG line chart, no script). Series: @( @{ Name; Points = @( @{ Time = [datetime|DateTimeOffset]; Value = [double] } ) } ).
    .PARAMETER Markers    @( @{ Time; Label } ) vertical lines (events).
    .PARAMETER Threshold  Horizontal dashed line.
    #>
    param([Parameter(Mandatory)] [string] $Title, [object[]] $Series = @(), [object[]] $Markers = @(), [string] $Unit = '', [Nullable[double]] $Threshold, [string] $Note)
    return [ordered]@{ title = $Title; chart = [ordered]@{ series = @($Series); markers = @($Markers); unit = $Unit; threshold = $Threshold }; columns = @(); rows = @(); note = $Note }
}

function ConvertTo-PortalReportSvg {
    param($Chart)
    $e = { param($v) ConvertTo-PortalHtmlText $v }
    $toTicks = { param($t) if ($t -is [DateTimeOffset]) { $t.UtcTicks } else { ([datetime]$t).ToUniversalTime().Ticks } }
    $series = @($Chart.series | Where-Object { @($_.Points).Count })
    if (-not $series.Count) { return '<div class="empty">No samples in the window.</div>' }
    $pts = @($series | ForEach-Object { @($_.Points) })
    $t0 = ($pts | ForEach-Object { & $toTicks $_.Time } | Measure-Object -Minimum).Minimum
    $t1 = ($pts | ForEach-Object { & $toTicks $_.Time } | Measure-Object -Maximum).Maximum
    foreach ($m in @($Chart.markers)) { $mt = & $toTicks $m.Time; if ($mt -lt $t0) { $t0 = $mt }; if ($mt -gt $t1) { $t1 = $mt } }
    if ($t1 -le $t0) { $t1 = $t0 + [TimeSpan]::TicksPerMinute }
    $vmax = [double](($pts | ForEach-Object { [double]$_.Value } | Measure-Object -Maximum).Maximum)
    if ($null -ne $Chart.threshold -and [double]$Chart.threshold -gt $vmax) { $vmax = [double]$Chart.threshold }
    if ($vmax -le 0) { $vmax = 1 }
    $vmax = $vmax * 1.1
    $W = 1000; $H = 220; $L = 50; $R = 10; $T = 12; $B = 30
    $x = { param($t) [math]::Round($L + ($W - $L - $R) * ((& $toTicks $t) - $t0) / ($t1 - $t0), 1) }
    $y = { param($v) [math]::Round($T + ($H - $T - $B) * (1 - ([double]$v / $vmax)), 1) }
    $colors = '#1f5fa8', '#c2410c', '#0f766e', '#7c3aed', '#b42318', '#475569'
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("<div style=""padding:10px 16px""><svg viewBox=""0 0 $W $H"" width=""100%"" role=""img"" aria-label=""$(& $e $Chart.unit) chart"" style=""max-height:260px"">")
    [void]$sb.Append("<line x1=""$L"" y1=""$($H - $B)"" x2=""$($W - $R)"" y2=""$($H - $B)"" stroke=""#c5ced9""/><line x1=""$L"" y1=""$T"" x2=""$L"" y2=""$($H - $B)"" stroke=""#c5ced9""/>")
    foreach ($f in 0, 0.5, 1) {
        $v = $vmax / 1.1 * $f; $yy = & $y $v
        [void]$sb.Append("<text x=""$($L - 6)"" y=""$($yy + 4)"" font-size=""11"" text-anchor=""end"" fill=""#5b6675"">$([math]::Round($v, 1))</text>")
    }
    if ($null -ne $Chart.threshold) {
        $yy = & $y $Chart.threshold
        [void]$sb.Append("<line x1=""$L"" y1=""$yy"" x2=""$($W - $R)"" y2=""$yy"" stroke=""#d97706"" stroke-dasharray=""4 4""/><text x=""$($W - $R)"" y=""$($yy - 4)"" font-size=""11"" text-anchor=""end"" fill=""#9a6300"">threshold $(& $e $Chart.threshold) $(& $e $Chart.unit)</text>")
    }
    $i = 0
    foreach ($m in @($Chart.markers)) {
        $xx = & $x $m.Time; $i++
        [void]$sb.Append("<line x1=""$xx"" y1=""$T"" x2=""$xx"" y2=""$($H - $B)"" stroke=""#b42318"" stroke-dasharray=""3 3""/><text x=""$($xx + 4)"" y=""$($T + 12 * (($i - 1) % 4) + 10)"" font-size=""10.5"" fill=""#b42318"">$(& $e $m.Label)</text>")
    }
    $ci = 0
    foreach ($s in $series) {
        $c = $colors[$ci % $colors.Count]; $ci++
        $line = (@($s.Points) | Sort-Object { & $toTicks $_.Time } | ForEach-Object { "$(& $x $_.Time),$(& $y $_.Value)" }) -join ' '
        [void]$sb.Append("<polyline fill=""none"" stroke=""$c"" stroke-width=""1.8"" points=""$line""/>")
        [void]$sb.Append("<rect x=""$($L + 10 + 170 * ($ci - 1))"" y=""$($H - 14)"" width=""10"" height=""10"" fill=""$c""/><text x=""$($L + 24 + 170 * ($ci - 1))"" y=""$($H - 5)"" font-size=""11"" fill=""#1f2a37"">$(& $e $s.Name)</text>")
    }
    $fmt = { param($ticks) ([datetime]::new([long]$ticks, [DateTimeKind]::Utc)).ToString('MM-dd HH:mm') }
    [void]$sb.Append("<text x=""$L"" y=""$($H - 18)"" font-size=""10.5"" fill=""#5b6675"">$(& $fmt $t0) UTC</text><text x=""$($W - $R)"" y=""$($H - 18)"" font-size=""10.5"" text-anchor=""end"" fill=""#5b6675"">$(& $fmt $t1) UTC</text>")
    [void]$sb.Append('</svg></div>')
    return $sb.ToString()
}

function Get-PortalReportCell {
    param($Row, [string] $Column)
    if ($Row -is [System.Collections.IDictionary]) { if ($Row.Contains($Column)) { return $Row[$Column] } return $null }
    $p = $Row.PSObject.Properties[$Column]; if ($p) { return $p.Value } return $null
}

function New-PortalReport {
    <#
    .SYNOPSIS Writes <slug>.html and one CSV per section into the report folder. Returns the list of files written.
    .PARAMETER Summary  Ordered key/value pairs shown as tiles at the top (e.g. Hosts = 12, Failed checks = 3).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Title,
        [string] $Subtitle,
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [object[]] $Sections,
        [System.Collections.IDictionary] $Summary,
        [string] $FileName
    )
    $dir = [string]$Context.ReportDir
    if (-not $dir) { throw 'Context.ReportDir is not set (reports need the portal job runner).' }
    $null = New-Item -ItemType Directory -Path $dir -Force
    $slug = if ($FileName) { $FileName } else { ($Title.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-') }
    $e = { param($v) ConvertTo-PortalHtmlText $v }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append(@"
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(& $e $Title)</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:0;background:#f3f5f8;color:#1f2a37}
header{background:#0a1f3c;color:#fff;padding:18px 28px}h1{margin:0;font-size:20px}header p{margin:4px 0 0;opacity:.8;font-size:13px}
main{padding:20px 28px}.tiles{display:flex;flex-wrap:wrap;gap:12px;margin-bottom:18px}
.tile{background:#fff;border:1px solid #dde3ea;border-radius:8px;padding:10px 16px;min-width:120px}.tile b{display:block;font-size:20px}.tile span{font-size:12px;color:#5b6675}
section{background:#fff;border:1px solid #dde3ea;border-radius:8px;margin-bottom:18px;overflow:auto}
h2{font-size:14px;margin:0;padding:12px 16px;border-bottom:1px solid #dde3ea;text-transform:uppercase;letter-spacing:.04em;color:#334155}
p.note{margin:8px 16px;font-size:12px;color:#5b6675}table{border-collapse:collapse;width:100%;font-size:13px}
th{text-align:left;background:#f7f9fb;padding:7px 10px;border-bottom:1px solid #dde3ea;white-space:nowrap}td{padding:6px 10px;border-bottom:1px solid #eef1f5;vertical-align:top}
.s-ok{color:#11734b;font-weight:600}.s-warn{color:#9a6300;font-weight:600}.s-fail{color:#b42318;font-weight:600}.empty{padding:12px 16px;color:#5b6675;font-size:13px}
footer{font-size:11px;color:#5b6675;padding:0 28px 20px}
</style></head><body>
<header><h1>$(& $e $Title)</h1><p>$(& $e $Subtitle)$(if ($Subtitle) { ' &middot; ' })Request $(& $e $Context.RequestId) &middot; generated $(& $e ((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')))&nbsp;UTC</p></header><main>
"@)
    if ($Summary -and $Summary.Count) {
        [void]$sb.Append('<div class="tiles">')
        foreach ($k in $Summary.Keys) { [void]$sb.Append("<div class=""tile""><b>$(& $e $Summary[$k])</b><span>$(& $e $k)</span></div>") }
        [void]$sb.Append('</div>')
    }
    $files = [System.Collections.Generic.List[object]]::new()
    $i = 0
    foreach ($s in $Sections) {
        $i++
        [void]$sb.Append("<section><h2>$(& $e $s.title)</h2>")
        if ($s.note) { [void]$sb.Append("<p class=""note"">$(& $e $s.note)</p>") }
        if ($s -is [System.Collections.IDictionary] -and $s.Contains('chart') -and $s.chart) { [void]$sb.Append((ConvertTo-PortalReportSvg -Chart $s.chart)); [void]$sb.Append('</section>'); continue }
        if (-not @($s.rows).Count) { [void]$sb.Append('<div class="empty">Nothing to report.</div></section>'); continue }
        [void]$sb.Append('<table><thead><tr>')
        foreach ($c in $s.columns) { [void]$sb.Append("<th>$(& $e $c)</th>") }
        [void]$sb.Append('</tr></thead><tbody>')
        foreach ($r in $s.rows) {
            [void]$sb.Append('<tr>')
            foreach ($c in $s.columns) {
                $v = Get-PortalReportCell -Row $r -Column $c
                $cls = if ($c -match '^(Status|Result|Compliance)$') {
                    switch -Regex ([string]$v) { '^(OK|PASS|COMPLIANT)' { 's-ok' } '^(WARN|WARNING|EXPIRING|NOT SET)' { 's-warn' } '^(FAIL|CRITICAL|ERROR|EXPIRED|NON-COMPLIANT)' { 's-fail' } default { '' } }
                } else { '' }
                $text = if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) { (@($v) -join ', ') } else { $v }
                $attr = if ($cls) { ' class="' + $cls + '"' } else { '' }
                [void]$sb.Append('<td' + $attr + '>' + (& $e $text) + '</td>')
            }
            [void]$sb.Append('</tr>')
        }
        [void]$sb.Append('</tbody></table></section>')
        # CSV per section
        $csvName = '{0}-{1:D2}-{2}.csv' -f $slug, $i, (($s.title.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-'))
        @($s.rows | ForEach-Object {
            $row = $_; $o = [ordered]@{}
            foreach ($c in $s.columns) { $v = Get-PortalReportCell -Row $row -Column $c; $o[$c] = if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) { @($v) -join '; ' } else { $v } }
            [pscustomobject]$o
        }) | Export-Csv -LiteralPath (Join-Path $dir $csvName) -NoTypeInformation -Encoding utf8
        $files.Add([ordered]@{ name = $csvName; type = 'csv'; title = "$($s.title) (CSV)" })
    }
    [void]$sb.Append('</main><footer>Generated by the Self-Service Portal. Values are read-only snapshots at generation time.</footer></body></html>')
    $html = "$slug.html"
    [System.IO.File]::WriteAllText((Join-Path $dir $html), $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
    $files.Insert(0, [ordered]@{ name = $html; type = 'html'; title = $Title })
    return $files.ToArray()
}

Export-ModuleMember -Function New-PortalReport, New-PortalReportSection, New-PortalReportChart, ConvertTo-PortalHtmlText
