<#
.SYNOPSIS
    Shared rendering helpers and the single HTML style template used by both
    Get-TeamKpiReport.ps1 (one person) and Get-TeamRollupReport.ps1 (a whole team).

.DESCRIPTION
    Dot-source this file; it defines functions only and performs no work on load:

        . (Join-Path $PSScriptRoot 'KpiReportCommon.ps1')

    Keeping the stylesheet and the chip/tile/delta helpers in one place is what
    makes every report - individual or team, any month - come out in the same shape.

    Colour choices follow a validated data-visualisation palette. Status colours are
    fixed and always ship alongside a glyph and a word ("better" / "worse" /
    "self-approved"), so meaning is never carried by colour alone - that keeps the
    report readable for colour-blind viewers, in greyscale print, and on a projector
    with washed-out contrast.
#>

# Escapes untrusted text (PR titles, review comments, commit messages, display
# names) before it reaches the HTML. Ampersand must be replaced first.
function ConvertTo-HtmlText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function Format-Metric {
    param($Value, [string]$Suffix = '', [string]$Fallback = 'n/a')
    if ($null -eq $Value -or "$Value" -eq '') { return $Fallback }
    return "$Value$Suffix"
}

# Deltas always carry a glyph AND the words better/worse - the colour never
# carries the meaning on its own.
function New-DeltaHtml {
    param($Current, $Previous, [switch]$HigherIsBetter, [string]$Suffix = '', [string]$PeriodLabel = 'last month')
    if ($null -eq $Previous -or $null -eq $Current) { return '' }
    $delta = [math]::Round([double]$Current - [double]$Previous, 1)
    if ($delta -eq 0) { return '<p class="delta delta-flat">no change vs ' + $PeriodLabel + '</p>' }
    $good  = if ($HigherIsBetter) { $delta -gt 0 } else { $delta -lt 0 }
    $glyph = if ($delta -gt 0) { '&#9650;' } else { '&#9660;' }
    $cls   = if ($good) { 'delta-good' } else { 'delta-bad' }
    $word  = if ($good) { 'better' } else { 'worse' }
    $abs   = [math]::Abs($delta)
    return '<p class="delta ' + $cls + '">' + $glyph + ' ' + $abs + $Suffix + ' vs ' + $PeriodLabel + ' &middot; ' + $word + '</p>'
}

function New-Tile {
    param([string]$Label, [string]$Value, [string]$Note = '', [string]$DeltaHtml = '')
    $out = '<div class="tile"><p class="tile-label">' + (ConvertTo-HtmlText $Label) + '</p>'
    $out += '<p class="tile-value">' + (ConvertTo-HtmlText $Value) + '</p>'
    if ($Note)      { $out += '<p class="tile-note">' + (ConvertTo-HtmlText $Note) + '</p>' }
    if ($DeltaHtml) { $out += $DeltaHtml }
    return $out + '</div>'
}

function New-Chip {
    param([string]$Severity, [string]$Label)
    $glyph = switch ($Severity) {
        'good'     { '&#10003;' }
        'warning'  { '&#9679;' }
        'serious'  { '&#9670;' }
        'critical' { '&#9650;' }
        default    { '&#9679;' }
    }
    return '<span class="chip chip-' + $Severity + '">' + $glyph + ' ' + (ConvertTo-HtmlText $Label) + '</span>'
}

function New-MetricRow {
    param([string]$Label, [string]$Value, [string]$DeltaHtml = '')
    return '<tr><th scope="row">' + (ConvertTo-HtmlText $Label) + '</th><td class="num">' +
           (ConvertTo-HtmlText $Value) + '</td><td class="trend">' + $DeltaHtml + '</td></tr>'
}

function Get-Median {
    param([double[]]$Values)
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $sorted = $Values | Sort-Object
    $n = $sorted.Count
    if ($n % 2 -eq 1) { return [double]$sorted[[math]::Floor($n / 2)] }
    return [double](($sorted[$n / 2 - 1] + $sorted[$n / 2]) / 2)
}

# Expands a period into the list of yyyy-MM months it covers, ending at $EndMonth.
function Get-PeriodMonths {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('month', 'quarter', 'halfyear', 'year')][string]$Period,
        [Parameter(Mandatory = $true)][string]$EndMonth
    )
    $count = switch ($Period) {
        'month'    { 1 }
        'quarter'  { 3 }
        'halfyear' { 6 }
        'year'     { 12 }
    }
    $end = [datetime]::ParseExact($EndMonth, 'yyyy-MM', [System.Globalization.CultureInfo]::InvariantCulture)
    $months = @()
    for ($i = $count - 1; $i -ge 0; $i--) {
        $months += $end.AddMonths(-$i).ToString('yyyy-MM')
    }
    # NOTE: a one-month period returns a single string here, because PowerShell
    # unrolls a one-element array on output. Callers must wrap the call in @(),
    # or $months[0] silently indexes the *string* and yields "2", not "2026-07".
    return $months
}

function Get-PeriodLabel {
    param([string]$Period, [string[]]$Months)
    $first = $Months[0]
    $last  = $Months[-1]
    switch ($Period) {
        'month'    { return $last }
        'quarter'  { return "$first to $last (quarter)" }
        'halfyear' { return "$first to $last (6 months)" }
        'year'     { return "$first to $last (12 months)" }
    }
}

# A filesystem-safe slug shared by every output filename.
function Get-SafeName {
    param([string]$Name)
    return ($Name -replace '[^a-zA-Z0-9\.\-_@]', '_')
}

<#
    The single stylesheet for every report. Palette notes:
      - neutral ink / surfaces from a validated chart palette
      - status hues fixed: good #0ca30c, warning #fab219, serious #ec835a, critical #d03b3b
      - light is the default; dark is redefined for both the OS setting and an
        explicit data-theme stamp, so a viewer's toggle wins either way
      - print forces the light ground so handouts don't come out inverted
#>
function Get-KpiReportCss {
    return @'
  :root {
    color-scheme: light;
    --page:      #f9f9f7;
    --surface:   #fcfcfb;
    --ink:       #0b0b0b;
    --ink-2:     #52514e;
    --muted:     #898781;
    --grid:      #e1e0d9;
    --baseline:  #c3c2b7;
    --border:    rgba(11,11,11,0.10);
    --accent:    #2a78d6;
    --good:      #0ca30c;
    --warning:   #fab219;
    --serious:   #ec835a;
    --critical:  #d03b3b;
    --delta-good: #006300;
    --delta-bad:  #d03b3b;
  }
  @media (prefers-color-scheme: dark) {
    :root:not([data-theme="light"]) {
      color-scheme: dark;
      --page:      #0d0d0d;
      --surface:   #1a1a19;
      --ink:       #ffffff;
      --ink-2:     #c3c2b7;
      --muted:     #898781;
      --grid:      #2c2c2a;
      --baseline:  #383835;
      --border:    rgba(255,255,255,0.10);
      --accent:    #3987e5;
      --delta-good: #0ca30c;
      --delta-bad:  #e66767;
    }
  }
  :root[data-theme="dark"] {
    color-scheme: dark;
    --page:      #0d0d0d;
    --surface:   #1a1a19;
    --ink:       #ffffff;
    --ink-2:     #c3c2b7;
    --muted:     #898781;
    --grid:      #2c2c2a;
    --baseline:  #383835;
    --border:    rgba(255,255,255,0.10);
    --accent:    #3987e5;
    --delta-good: #0ca30c;
    --delta-bad:  #e66767;
  }

  * { box-sizing: border-box; }
  body {
    margin: 0;
    background: var(--page);
    color: var(--ink);
    font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
    line-height: 1.5;
    -webkit-font-smoothing: antialiased;
  }
  .wrap { max-width: 1140px; margin: 0 auto; padding: 40px 28px 80px; }

  header.report { border-bottom: 2px solid var(--ink); padding-bottom: 22px; margin-bottom: 32px; }
  .eyebrow {
    font-size: 12px; font-weight: 700; letter-spacing: 0.16em; text-transform: uppercase;
    color: var(--accent); margin: 0 0 10px;
  }
  h1 { font-size: 30px; line-height: 1.2; margin: 0 0 6px; font-weight: 650; }
  .subject { font-size: 17px; color: var(--ink-2); margin: 0; }
  .stamp { font-size: 13px; color: var(--muted); margin: 8px 0 0; }

  /* hero - exactly one per report */
  .hero {
    display: flex; flex-wrap: wrap; align-items: baseline; gap: 10px 22px;
    background: var(--surface); border: 1px solid var(--border);
    padding: 24px 26px; margin-bottom: 28px;
  }
  .hero-value { font-size: 56px; font-weight: 650; line-height: 1; margin: 0; }
  .hero-label { font-size: 15px; color: var(--ink-2); margin: 0; }
  .hero-note { flex-basis: 100%; font-size: 13px; color: var(--muted); margin: 4px 0 0; max-width: 74ch; }

  .tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 14px; margin-bottom: 34px; }
  .tile { background: var(--surface); border: 1px solid var(--border); padding: 16px 18px; }
  .tile-label { font-size: 13px; color: var(--ink-2); margin: 0 0 6px; }
  .tile-value { font-size: 30px; font-weight: 650; line-height: 1.1; margin: 0; }
  .tile-note { font-size: 12px; color: var(--muted); margin: 4px 0 0; }

  .delta { font-size: 12px; margin: 6px 0 0; font-weight: 600; }
  .delta-good { color: var(--delta-good); }
  .delta-bad  { color: var(--delta-bad); }
  .delta-flat { color: var(--muted); font-weight: 500; }

  h2 {
    font-size: 13px; font-weight: 700; letter-spacing: 0.14em; text-transform: uppercase;
    color: var(--ink-2); margin: 38px 0 12px; padding-bottom: 8px; border-bottom: 1px solid var(--baseline);
  }
  h3 { font-size: 16px; margin: 0 0 10px; font-weight: 650; }

  .grid-2 { display: grid; grid-template-columns: repeat(auto-fit, minmax(330px, 1fr)); gap: 20px; }

  table { width: 100%; border-collapse: collapse; font-size: 14px; }
  .scroll { overflow-x: auto; }
  th, td { text-align: left; padding: 9px 12px; border-bottom: 1px solid var(--grid); vertical-align: top; }
  thead th {
    font-size: 11px; letter-spacing: 0.08em; text-transform: uppercase; color: var(--muted);
    font-weight: 700; border-bottom: 1px solid var(--baseline); white-space: nowrap;
  }
  tbody th { font-weight: 500; color: var(--ink-2); }
  td.num, .metrics td { font-variant-numeric: tabular-nums; white-space: nowrap; }
  .metrics td.num { font-weight: 600; }
  td.trend { width: 1%; white-space: nowrap; }
  td.trend .delta { margin: 0; }
  td.title { min-width: 260px; max-width: 380px; }
  td.title a { color: var(--ink); text-decoration: underline; text-underline-offset: 2px; }
  td.title .sub { display: block; font-size: 11px; color: var(--muted); }
  td.title .chips { display: block; margin-top: 5px; }
  td.mono { font-family: ui-monospace, Menlo, Consolas, monospace; font-size: 12px; }
  td.person { min-width: 210px; font-weight: 600; }
  td.person .sub { display: block; font-size: 11px; color: var(--muted); font-weight: 400; }
  tbody tr:hover { background: var(--surface); }

  .chip {
    display: inline-block; font-size: 11px; font-weight: 650; line-height: 1.6;
    padding: 1px 8px; margin: 0 4px 4px 0; border: 1px solid; border-radius: 2px; white-space: nowrap;
  }
  .chip-good     { color: var(--ink); border-color: var(--good); }
  .chip-warning  { color: var(--ink); border-color: var(--warning); }
  .chip-serious  { color: var(--ink); border-color: var(--serious); }
  .chip-critical { color: var(--ink); border-color: var(--critical); }

  .card { background: var(--surface); border: 1px solid var(--border); padding: 18px 20px; margin-bottom: 14px; }
  .card ul { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 16px; }
  .cat { font-size: 11px; font-weight: 700; letter-spacing: 0.08em; text-transform: uppercase; color: var(--ink-2); }
  .card blockquote {
    margin: 6px 0 4px; padding: 0 0 0 14px; border-left: 3px solid var(--baseline);
    font-size: 15px; color: var(--ink);
  }
  .attrib { font-size: 12px; color: var(--muted); margin: 0; }

  .flag-list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 10px; font-size: 14px; }
  .empty { color: var(--muted); font-size: 14px; font-style: italic; }

  .talking-points {
    background: var(--surface); border: 1px solid var(--border); border-left: 4px solid var(--accent);
    padding: 18px 20px; margin: 0; font: inherit; font-size: 15px; white-space: pre-wrap;
  }

  .callout {
    background: var(--surface); border: 1px solid var(--border); border-left: 4px solid var(--warning);
    padding: 14px 18px; font-size: 13px; color: var(--ink-2); margin: 0 0 24px; max-width: 82ch;
  }
  .callout-info { border-left-color: var(--accent); }
  .callout strong { color: var(--ink); }

  footer.report { margin-top: 46px; padding-top: 18px; border-top: 1px solid var(--baseline); font-size: 12px; color: var(--muted); max-width: 82ch; }
  footer.report p { margin: 0 0 8px; }

  @media print {
    :root { color-scheme: light; }
    body { background: #fff; }
    .wrap { max-width: none; padding: 0; }
    .card, .tile, .hero, section { break-inside: avoid; }
    tbody tr:hover { background: transparent; }
  }
'@
}
