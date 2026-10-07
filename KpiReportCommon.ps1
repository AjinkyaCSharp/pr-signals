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
    "flagged"), so meaning is never carried by colour alone - that keeps the
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

function ConvertTo-InlineMarkdownHtml {
    # Minimal inline-markdown support: **bold** and [text](url) links.
    param([string]$Text)
    $escaped = ConvertTo-HtmlText $Text
    $escaped = [regex]::Replace($escaped, '\*\*(.+?)\*\*', '<strong>$1</strong>')
    $escaped = [regex]::Replace($escaped, '\[([^\]]+)\]\((https?://[^\s\)]+)\)', '<a href="$2" target="_blank" rel="noopener">$1</a>')
    return $escaped
}

# Parses the talking-points markdown into per-PR sections, tagging each bullet
# as "Actionable" (a concrete action someone needs to take) or "General" (a
# statement/observation with no clear next step) so a manager can tell the two
# apart at a glance. Tag a bullet by starting it with "[Actionable]" or
# "[General]" - untagged bullets default to "General" rather than guessing.
# Expected input shape (see RUNBOOK.md Step 4):
#   ## [#123 Short PR title](https://.../pullrequest/123)
#   - [Actionable] Concrete point, with a number where possible
#   - [General] An observation with no specific action attached
#   ## General notes
#   - [General] a note not tied to one specific PR
# Any text before the first "## " heading, or a heading with no bullets, is
# still captured so nothing written by the agent is silently dropped.
function Get-TalkingPointsParsed {
    param([string]$RawText)

    $result = [pscustomobject]@{
        Sections    = New-Object System.Collections.Generic.List[object]
        Preamble    = New-Object System.Collections.Generic.List[string]
        HasHeadings = $false
    }
    if ([string]::IsNullOrWhiteSpace($RawText)) { return $result }

    $lines = $RawText -split "`r?`n"
    $current = $null

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^#{1,3}\s+(.+)$') {
            if ($null -ne $current) { $result.Sections.Add($current) }
            $headingText = $Matches[1].Trim()
            $prId = $null
            if ($headingText -match '#(\d+)') { $prId = [int]$Matches[1] }
            $current = [pscustomobject]@{
                Heading       = $headingText
                PullRequestId = $prId
                Bullets       = New-Object System.Collections.Generic.List[object]
            }
        } elseif ($trimmed -match '^[-*]\s+(.+)$') {
            $bulletText = $Matches[1].Trim()
            $category = 'General'
            if ($bulletText -match '^\[(?:Actionable|Action)\]\s*(.+)$') {
                $category = 'Actionable'
                $bulletText = $Matches[1].Trim()
            } elseif ($bulletText -match '^\[(?:General|Note)\]\s*(.+)$') {
                $category = 'General'
                $bulletText = $Matches[1].Trim()
            }
            $bullet = [pscustomobject]@{ Text = $bulletText; Category = $category }
            if ($null -ne $current) { $current.Bullets.Add($bullet) }
            else { $result.Preamble.Add('- ' + $bulletText) }
        } elseif ($trimmed -ne '') {
            if ($null -ne $current) {
                # Non-bullet prose under a heading - keep as its own bullet-like line
                # rather than dropping it, in case the agent wrote a plain sentence.
                $current.Bullets.Add([pscustomobject]@{ Text = $trimmed; Category = 'General' })
            } else {
                $result.Preamble.Add($trimmed)
            }
        }
    }
    if ($null -ne $current) { $result.Sections.Add($current) }
    $result.HasHeadings = ($result.Sections.Count -gt 0)
    return $result
}

# Parses the talking-points markdown into per-PR sections so the report can
# render "PR -> bullet points" as a table instead of a wall of prose.
function ConvertTo-TalkingPointsHtml {
    param([string]$RawText)

    if ([string]::IsNullOrWhiteSpace($RawText)) {
        return '<p class="empty">Not yet written. After the manual review pass (RUNBOOK.md Step 4), save the confirmed points to a text file and re-run with <code>-TalkingPointsPath</code>.</p>'
    }

    $parsed = Get-TalkingPointsParsed -RawText $RawText

    # No "## " headings at all -> fall back to the old free-text rendering
    # rather than showing an empty table.
    if (-not $parsed.HasHeadings) {
        return '<pre class="talking-points">' + (ConvertTo-HtmlText $RawText) + '</pre>'
    }

    $rows = New-Object System.Collections.Generic.List[string]
    foreach ($s in $parsed.Sections) {
        $prTitleHtml = ConvertTo-InlineMarkdownHtml $s.Heading
        $actionableCount = @($s.Bullets | Where-Object { $_.Category -eq 'Actionable' }).Count
        $generalCount = @($s.Bullets | Where-Object { $_.Category -eq 'General' }).Count
        $countHtml = '<p class="tp-count">' + $actionableCount + ' actionable &middot; ' + $generalCount + ' general</p>'
        $bulletsHtml = if ($s.Bullets.Count -gt 0) {
            '<ul class="tp-bullets">' + (($s.Bullets | ForEach-Object {
                $badgeCls = if ($_.Category -eq 'Actionable') { 'tp-badge-action' } else { 'tp-badge-general' }
                $badgeText = if ($_.Category -eq 'Actionable') { 'Action' } else { 'Note' }
                '<li><span class="tp-badge ' + $badgeCls + '">' + $badgeText + '</span>' + (ConvertTo-InlineMarkdownHtml $_.Text) + '</li>'
            }) -join '') + '</ul>'
        } else {
            '<span class="empty">No points recorded.</span>'
        }
        $rows.Add('<tr><td class="title">' + $prTitleHtml + $countHtml + '</td><td class="points">' + $bulletsHtml + '</td></tr>')
    }

    $table = '<div class="scroll"><table class="tp-table"><thead><tr><th>Pull request</th><th>Talking points</th></tr></thead><tbody>' +
             ($rows -join "`n") + '</tbody></table></div>'

    $preambleHtml = if ($parsed.Preamble.Count -gt 0) {
        '<div class="callout callout-info">' + (($parsed.Preamble | ForEach-Object { (ConvertTo-InlineMarkdownHtml $_) }) -join '<br>') + '</div>'
    } else { '' }

    return $preambleHtml + $table
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

# Colour-codes a PR's raw status the same way ADO's own PR list does: Active =
# blue, Completed = green, Abandoned = neutral grey.
function New-StatusPill {
    param([string]$Status)
    $lower = ("$Status").Trim().ToLowerInvariant()
    $cls = switch ($lower) {
        'completed' { 'pill-completed' }
        'abandoned' { 'pill-abandoned' }
        default     { 'pill-active' }
    }
    return '<span class="pill ' + $cls + '">' + (ConvertTo-HtmlText $Status) + '</span>'
}

# One risk signal in the "Needs attention" roll-up near the top of the report -
# the single place a Scrum Master/manager can scan for what to ask about,
# instead of hunting for it across five different tables further down.
# $Html may contain simple inline markup (e.g. <strong>), so it is NOT escaped -
# callers must escape any untrusted text themselves before passing it in.
function New-AttentionItem {
    param([ValidateSet('critical', 'warning')][string]$Severity, [string]$Html, [string]$Sub = '')
    $subHtml = if ($Sub) { '<span class="sub">' + (ConvertTo-HtmlText $Sub) + '</span>' } else { '' }
    return '<li class="attention-item sev-' + $Severity + '"><span class="attention-dot"></span><div>' + $Html + $subHtml + '</div></li>'
}

# Maps a work-item bucket name to the CSS class carrying its ADO type colour.
$script:WorkItemTypeCssClass = [ordered]@{
    'Epic'       = 'wi-epic'
    'Feature'    = 'wi-feature'
    'User Story' = 'wi-userstory'
    'Task'       = 'wi-task'
    'Bug'        = 'wi-bug'
}

# One work-item-type delivery card (Epic/Feature/User Story/Task/Bug), coloured
# like its ADO type icon, showing total assigned plus an Active / Code review /
# Completed breakdown. Epic/Feature omit "Code review" (they don't go through it).
function New-WorkItemCard {
    param(
        [string]$Bucket, [int]$Count, [int]$ActiveCount, [int]$CodeReviewCount, [int]$CompletedCount,
        [switch]$ShowCodeReview
    )
    $cssClass = if ($script:WorkItemTypeCssClass.Contains($Bucket)) { $script:WorkItemTypeCssClass[$Bucket] } else { '' }
    $stats = '<div class="wi-stats"><div><b>' + $ActiveCount + '</b>Active</div>'
    if ($ShowCodeReview) { $stats += '<div><b>' + $CodeReviewCount + '</b>Code review</div>' }
    $stats += '<div><b>' + $CompletedCount + '</b>Completed</div></div>'
    return '<div class="wi-card ' + $cssClass + '">' +
           '<div class="wi-head"><span class="wi-swatch"></span><span class="wi-type">' + (ConvertTo-HtmlText $Bucket) + '</span></div>' +
           '<p class="wi-total">' + $Count + '</p>' + $stats + '</div>'
}

# A small inline coloured badge for a work-item type, used in tables (e.g. the
# stuck-in-queue list) where a full card would be too heavy.
function New-TypeBadge {
    param([string]$Bucket)
    $cssClass = if ($script:WorkItemTypeCssClass.Contains($Bucket)) { $script:WorkItemTypeCssClass[$Bucket] } else { '' }
    return '<span class="type-badge ' + $cssClass + '"><span class="wi-swatch"></span>' + (ConvertTo-HtmlText $Bucket) + '</span>'
}

# Elapsed time between two datetimes, expressed in business days (Mon-Fri only).
# Weekend time (Saturday/Sunday) is excluded entirely rather than counted as zero
# duration - a PR sitting open across a weekend should not look faster than one
# that sat open the same number of hours on weekdays.
function Get-BusinessDaysBetween {
    param([datetime]$Start, [datetime]$End)
    if ($End -le $Start) { return 0.0 }
    $totalDays = 0.0
    $cursor = $Start
    while ($cursor.Date -lt $End.Date) {
        $nextMidnight = $cursor.Date.AddDays(1)
        if ($cursor.DayOfWeek -ne [System.DayOfWeek]::Saturday -and $cursor.DayOfWeek -ne [System.DayOfWeek]::Sunday) {
            $totalDays += ($nextMidnight - $cursor).TotalDays
        }
        $cursor = $nextMidnight
    }
    if ($cursor.DayOfWeek -ne [System.DayOfWeek]::Saturday -and $cursor.DayOfWeek -ne [System.DayOfWeek]::Sunday) {
        $totalDays += ($End - $cursor).TotalDays
    }
    return $totalDays
}

# Canonical work-item type buckets, used so any Azure DevOps process template's
# type names (Bug, User Story, Product Backlog Item, Task, Epic, Feature, ...)
# roll up into one fixed, comparable set across every report.
$script:WorkItemTypeBuckets = [ordered]@{
    'Bug'         = @('bug')
    'User Story'  = @('user story', 'product backlog item', 'pbi')
    'Task'        = @('task')
    'Epic'        = @('epic')
    'Feature'     = @('feature')
}
$script:WorkItemDoneStates = @('closed', 'done', 'resolved', 'completed')

# Extra state buckets used by Get-WorkItemTypeStats/Get-StaleWorkItems below.
# Removed/cancelled items are excluded from every count entirely (neither active
# nor completed work). Code-review states are their own bucket, distinct from
# "active", so a card sitting with a reviewer doesn't look like idle in-progress
# work or finished work.
$script:WorkItemRemovedStates = @('removed', 'cancelled', 'canceled')
$script:WorkItemCodeReviewStates = @('code review', 'in review', 'review', 'ready for review', 'pr review')
$script:WorkItemActiveStates = @('active', 'in progress', 'committed', 'approved', 'doing', 'open')

function Get-WorkItemBucket {
    param([string]$Type)
    if ([string]::IsNullOrWhiteSpace($Type)) { return 'Other' }
    $lower = $Type.Trim().ToLowerInvariant()
    foreach ($bucket in $script:WorkItemTypeBuckets.Keys) {
        if ($script:WorkItemTypeBuckets[$bucket] -contains $lower) { return $bucket }
    }
    return 'Other'
}

function Test-WorkItemDone {
    param([string]$State)
    if ([string]::IsNullOrWhiteSpace($State)) { return $false }
    return $script:WorkItemDoneStates -contains $State.Trim().ToLowerInvariant()
}

function Test-WorkItemRemoved {
    param([string]$State)
    if ([string]::IsNullOrWhiteSpace($State)) { return $false }
    return $script:WorkItemRemovedStates -contains $State.Trim().ToLowerInvariant()
}

function Test-WorkItemCodeReview {
    param([string]$State)
    if ([string]::IsNullOrWhiteSpace($State)) { return $false }
    return $script:WorkItemCodeReviewStates -contains $State.Trim().ToLowerInvariant()
}

function Test-WorkItemActiveState {
    param([string]$State)
    if ([string]::IsNullOrWhiteSpace($State)) { return $false }
    return $script:WorkItemActiveStates -contains $State.Trim().ToLowerInvariant()
}

# Summarises a flat list of work-item objects ({ id, type, state, title }) into
# an ordered [type -> @{ assigned; completed }] map, always including the five
# named categories (even at zero) plus an "Other" bucket for anything unmatched.
function Get-WorkItemSummary {
    param([array]$WorkItems)
    $summary = [ordered]@{}
    foreach ($bucket in $script:WorkItemTypeBuckets.Keys) { $summary[$bucket] = [ordered]@{ assigned = 0; completed = 0 } }
    $summary['Other'] = [ordered]@{ assigned = 0; completed = 0 }
    foreach ($wi in @($WorkItems)) {
        $bucket = Get-WorkItemBucket -Type $wi.type
        $summary[$bucket].assigned++
        if (Test-WorkItemDone -State $wi.state) { $summary[$bucket].completed++ }
    }
    return $summary
}

# Richer per-type breakdown: count / active / in-code-review / completed for
# each of the five named buckets (Epic, Feature, User Story, Task, Bug). Removed
# / cancelled items are dropped entirely rather than counted anywhere.
#
# Epics and Features get an extra activity gate on top of the count above: an
# Epic/Feature is only "active" if it actually has User Stories underneath it
# (Epic: rolled up across its Features; Feature: its own direct children, via
# the optional "childUserStoryCount" field on the raw work item). An Epic/Feature
# sitting in an in-progress ADO state with nothing broken down under it is not
# counted as active - that's the whole point of the check: it catches Epics/
# Features that were opened but never actually decomposed into working units.
function Get-WorkItemTypeStats {
    param([array]$WorkItems)
    $stats = [ordered]@{}
    foreach ($bucket in $script:WorkItemTypeBuckets.Keys) {
        $stats[$bucket] = [ordered]@{ count = 0; activeCount = 0; codeReviewCount = 0; completedCount = 0 }
    }
    foreach ($wi in @($WorkItems)) {
        $bucket = Get-WorkItemBucket -Type $wi.type
        if ($bucket -eq 'Other') { continue }
        if (Test-WorkItemRemoved -State $wi.state) { continue }

        $stats[$bucket].count++

        if (Test-WorkItemDone -State $wi.state) {
            $stats[$bucket].completedCount++
            continue
        }
        if (Test-WorkItemCodeReview -State $wi.state) {
            $stats[$bucket].codeReviewCount++
            continue
        }
        if ($bucket -eq 'Epic' -or $bucket -eq 'Feature') {
            $hasChildUserStories = ($null -ne $wi.childUserStoryCount) -and ([int]$wi.childUserStoryCount -gt 0)
            if ($hasChildUserStories) { $stats[$bucket].activeCount++ }
        } elseif (Test-WorkItemActiveState -State $wi.state) {
            $stats[$bucket].activeCount++
        }
    }
    return $stats
}

# Flags work items of one bucket (intended for 'Bug' / 'User Story') that are
# assigned to the person, not yet done/removed, and whose state hasn't changed
# in at least $ThresholdDays business days - i.e. it's sitting untouched in the
# queue rather than actually being worked. Requires the optional "changedDate"
# field on the raw work item; items without it are skipped (can't tell).
function Get-StaleWorkItems {
    param([array]$WorkItems, [string]$Bucket, [int]$ThresholdDays)
    $stale = New-Object System.Collections.Generic.List[object]
    foreach ($wi in @($WorkItems)) {
        if ((Get-WorkItemBucket -Type $wi.type) -ne $Bucket) { continue }
        if (Test-WorkItemDone -State $wi.state) { continue }
        if (Test-WorkItemRemoved -State $wi.state) { continue }
        if (-not $wi.changedDate) { continue }
        try {
            $changed = [datetime]$wi.changedDate
        } catch { continue }
        $ageDays = [math]::Round((Get-BusinessDaysBetween -Start $changed -End (Get-Date)), 1)
        if ($ageDays -ge $ThresholdDays) {
            $stale.Add([pscustomobject]@{
                id          = $wi.id
                title       = $wi.title
                state       = $wi.state
                changedDate = $wi.changedDate
                ageDays     = $ageDays
            }) | Out-Null
        }
    }
    return $stale
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
    The single stylesheet for every report. Palette is deliberately Azure DevOps'
    own: the blue/greys of the ADO chrome, the work-item type icon colours
    (Epic orange, Feature purple, User Story blue-teal, Task gold, Bug red), and
    ADO's state-pill colours for PR status - so a Scrum Master or manager who
    lives in ADO all day recognises the vocabulary instantly, rather than having
    to learn a new one.
      - status hues fixed: good #107c10, warning #ca5010, serious #ca5010, critical #d13438
      - light is the default; dark is redefined for both the OS setting and an
        explicit data-theme stamp, so a viewer's toggle wins either way
      - print forces the light ground so handouts don't come out inverted
#>
function Get-KpiReportCss {
    return @'
  :root {
    color-scheme: light;
    --page:      #faf9f8;
    --surface:   #ffffff;
    --surface-2: #f3f2f1;
    --ink:       #201f1e;
    --ink-2:     #3b3a39;
    --muted:     #605e5c;
    --grid:      #edebe9;
    --baseline:  #d2d0ce;
    --border:    #e1dfdd;
    --accent:    #0078d4;
    --accent-dark: #005a9e;
    --accent-tint: #eff6fc;
    --good:      #107c10;
    --good-tint: #dff6dd;
    --warning:   #ca5010;
    --warning-tint: #fdf2e6;
    --serious:   #ca5010;
    --critical:  #d13438;
    --critical-tint: #fdedee;
    --delta-good: #107c10;
    --delta-bad:  #d13438;
    /* Azure DevOps work-item type colours - kept identical in light and dark */
    --wi-epic:       #ff7b00;
    --wi-feature:    #773b93;
    --wi-userstory:  #0078d4;
    --wi-task:       #a67a00;
    --wi-task-bg:    #fff4ce;
    --wi-bug:        #cc293d;
    --shadow: 0 1px 2px rgba(0,0,0,0.06);
    --shadow-md: 0 2px 8px rgba(0,0,0,0.08);
  }
  @media (prefers-color-scheme: dark) {
    :root:not([data-theme="light"]) {
      color-scheme: dark;
      --page:      #1b1a19;
      --surface:   #252423;
      --surface-2: #2d2c2b;
      --ink:       #f3f2f1;
      --ink-2:     #e1dfdd;
      --muted:     #c8c6c4;
      --grid:      #3b3a39;
      --baseline:  #484644;
      --border:    #3b3a39;
      --accent:    #2899f5;
      --accent-dark: #57a6ec;
      --accent-tint: #26313d;
      --good:      #6bb700;
      --good-tint: #223523;
      --warning:   #e88b3f;
      --warning-tint: #3a2c1c;
      --critical:  #f1707b;
      --critical-tint: #3a2327;
      --delta-good: #6bb700;
      --delta-bad:  #f1707b;
      --shadow: 0 1px 2px rgba(0,0,0,0.4);
      --shadow-md: 0 2px 10px rgba(0,0,0,0.5);
    }
  }
  :root[data-theme="dark"] {
    color-scheme: dark;
    --page:      #1b1a19;
    --surface:   #252423;
    --surface-2: #2d2c2b;
    --ink:       #f3f2f1;
    --ink-2:     #e1dfdd;
    --muted:     #c8c6c4;
    --grid:      #3b3a39;
    --baseline:  #484644;
    --border:    #3b3a39;
    --accent:    #2899f5;
    --accent-dark: #57a6ec;
    --accent-tint: #26313d;
    --good:      #6bb700;
    --good-tint: #223523;
    --warning:   #e88b3f;
    --warning-tint: #3a2c1c;
    --critical:  #f1707b;
    --critical-tint: #3a2327;
    --delta-good: #6bb700;
    --delta-bad:  #f1707b;
    --shadow: 0 1px 2px rgba(0,0,0,0.4);
    --shadow-md: 0 2px 10px rgba(0,0,0,0.5);
  }

  * { box-sizing: border-box; }
  body {
    margin: 0;
    background: var(--page);
    color: var(--ink);
    font-family: "Segoe UI", system-ui, -apple-system, sans-serif;
    line-height: 1.5;
    -webkit-font-smoothing: antialiased;
  }
  .wrap { max-width: 1180px; margin: 0 auto; padding: 32px 28px 80px; }

  /* ---- profile header: identity strip, ADO-blue accent bar on top ---- */
  header.report {
    display: flex; align-items: center; gap: 18px;
    background: var(--surface); border: 1px solid var(--border); border-top: 4px solid var(--accent);
    border-radius: 4px; box-shadow: var(--shadow); padding: 22px 26px; margin-bottom: 24px;
  }
  .avatar {
    flex: 0 0 auto; width: 56px; height: 56px; border-radius: 50%;
    background: var(--accent); color: #fff; display: flex; align-items: center; justify-content: center;
    font-size: 22px; font-weight: 650; letter-spacing: 0.02em;
  }
  .header-text { min-width: 0; }
  .eyebrow {
    font-size: 11px; font-weight: 700; letter-spacing: 0.14em; text-transform: uppercase;
    color: var(--accent); margin: 0 0 4px;
  }
  h1 { font-size: 24px; line-height: 1.25; margin: 0 0 2px; font-weight: 650; }
  .period-badge {
    display: inline-block; font-size: 12px; font-weight: 700; letter-spacing: 0.03em;
    color: var(--accent); background: var(--accent-tint, #eef4fd); border: 1px solid var(--accent);
    border-radius: 999px; padding: 3px 12px; margin: 4px 0 6px;
  }
  .subject { font-size: 14px; color: var(--ink-2); margin: 0; }
  .subject strong { color: var(--ink); }
  .stamp { font-size: 12px; color: var(--muted); margin: 6px 0 0; }

  /* ---- headline scorecard: exactly the numbers a 1-1 opens with ---- */
  .tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(168px, 1fr)); gap: 12px; margin-bottom: 28px; }
  .tile {
    background: var(--surface); border: 1px solid var(--border); border-top: 3px solid var(--accent);
    border-radius: 4px; box-shadow: var(--shadow); padding: 14px 16px 16px;
  }
  .tile-label {
    font-size: 11px; font-weight: 600; letter-spacing: 0.04em; text-transform: uppercase;
    color: var(--muted); margin: 0 0 8px;
  }
  .tile-value { font-size: 28px; font-weight: 650; line-height: 1.1; margin: 0; color: var(--ink); }
  .tile-note { font-size: 12px; color: var(--muted); margin: 4px 0 0; }

  .delta { font-size: 12px; margin: 6px 0 0; font-weight: 600; }
  .delta-good { color: var(--delta-good); }
  .delta-bad  { color: var(--delta-bad); }
  .delta-flat { color: var(--muted); font-weight: 500; }

  h2 {
    font-size: 12px; font-weight: 700; letter-spacing: 0.1em; text-transform: uppercase;
    color: var(--ink-2); margin: 32px 0 12px; padding-bottom: 8px; border-bottom: 2px solid var(--baseline);
    display: flex; align-items: center; gap: 8px;
  }
  h3 { font-size: 15px; margin: 0 0 10px; font-weight: 650; color: var(--ink); }

  /* section wrapper - gives every block of the report the same card treatment
     used by the scorecard, so nothing later on reads as a bolted-on afterthought */
  .panel {
    background: var(--surface); border: 1px solid var(--border); border-radius: 4px;
    box-shadow: var(--shadow); padding: 4px 22px 18px; margin-bottom: 26px;
  }
  .panel h2 { margin-top: 18px; }

  .grid-2 { display: grid; grid-template-columns: repeat(auto-fit, minmax(330px, 1fr)); gap: 24px; }

  /* ---- "needs attention" roll-up: every risk signal, one place, top of report ---- */
  .attention-list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 8px; }
  .attention-item {
    display: flex; align-items: flex-start; gap: 10px; padding: 10px 12px;
    background: var(--surface-2); border-radius: 4px; font-size: 14px;
  }
  .attention-dot { flex: 0 0 auto; width: 10px; height: 10px; border-radius: 50%; margin-top: 4px; }
  .attention-item.sev-critical .attention-dot { background: var(--critical); }
  .attention-item.sev-warning  .attention-dot { background: var(--warning); }
  .attention-item strong { color: var(--ink); }
  .attention-item .sub { display: block; color: var(--muted); font-size: 12px; margin-top: 2px; }
  .all-clear {
    display: flex; align-items: center; gap: 10px; padding: 12px 14px; font-size: 14px;
    background: var(--good-tint); border-radius: 4px; color: var(--ink);
  }
  .all-clear .dot { width: 10px; height: 10px; border-radius: 50%; background: var(--good); flex: 0 0 auto; }

  /* ---- work item delivery cards, coloured like their ADO type icons ---- */
  .wi-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 12px; margin: 4px 0 18px; }
  .wi-card {
    background: var(--surface-2); border-radius: 4px; border-left: 4px solid var(--wi-color, var(--accent));
    padding: 12px 14px;
  }
  .wi-head { display: flex; align-items: center; gap: 8px; margin-bottom: 10px; }
  .wi-swatch { width: 12px; height: 12px; border-radius: 2px; background: var(--wi-color, var(--accent)); flex: 0 0 auto; }
  .wi-type { font-size: 12px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.04em; color: var(--ink-2); }
  .wi-total { font-size: 26px; font-weight: 650; line-height: 1; margin: 0 0 10px; }
  .wi-stats { display: flex; gap: 14px; font-size: 12px; color: var(--muted); }
  .wi-stats b { display: block; font-size: 15px; font-weight: 650; color: var(--ink); }
  .wi-epic       { --wi-color: var(--wi-epic); }
  .wi-feature    { --wi-color: var(--wi-feature); }
  .wi-userstory  { --wi-color: var(--wi-userstory); }
  .wi-task       { --wi-color: var(--wi-task); }
  .wi-bug        { --wi-color: var(--wi-bug); }

  .type-badge {
    display: inline-flex; align-items: center; gap: 6px; font-size: 12px; font-weight: 650;
  }
  .type-badge .wi-swatch { width: 10px; height: 10px; }

  /* ---- month-over-month trend bars: pure CSS, no chart library, so the
     report stays one self-contained HTML file. ---- */
  .bar-chart { margin-bottom: 26px; }
  .bar-chart:last-child { margin-bottom: 0; }
  .bar-legend { display: flex; flex-wrap: wrap; gap: 14px; margin-bottom: 10px; font-size: 12px; color: var(--muted); }
  .bar-legend-item { display: inline-flex; align-items: center; gap: 6px; }
  .bar-swatch { width: 10px; height: 10px; border-radius: 2px; flex: 0 0 auto; }
  .bar-chart-body {
    display: flex; align-items: flex-end; gap: 18px; min-height: 160px;
    padding: 10px 6px 0; border-bottom: 2px solid var(--baseline); overflow-x: auto;
  }
  .bar-col { display: flex; flex-direction: column; align-items: center; flex: 1 0 56px; }
  .bar-group { display: flex; align-items: flex-end; gap: 4px; height: 140px; width: 100%; justify-content: center; }
  .bar {
    width: 16px; min-height: 2px; border-radius: 3px 3px 0 0; position: relative;
    display: flex; align-items: flex-start; justify-content: center;
  }
  .bar-value {
    position: absolute; top: -18px; font-size: 11px; font-weight: 650; color: var(--ink-2); white-space: nowrap;
  }
  .bar-month { margin-top: 8px; font-size: 11px; color: var(--muted); white-space: nowrap; }

  table { width: 100%; border-collapse: collapse; font-size: 13.5px; }
  .scroll { overflow-x: auto; }
  th, td { text-align: left; padding: 9px 12px; border-bottom: 1px solid var(--grid); vertical-align: top; }
  thead th {
    font-size: 11px; letter-spacing: 0.06em; text-transform: uppercase; color: var(--muted);
    font-weight: 700; border-bottom: 2px solid var(--baseline); white-space: nowrap;
    background: var(--surface-2);
  }
  tbody th { font-weight: 500; color: var(--ink-2); }
  td.num, .metrics td { font-variant-numeric: tabular-nums; white-space: nowrap; }
  .metrics td.num { font-weight: 600; }
  td.trend { width: 1%; white-space: nowrap; }
  td.trend .delta { margin: 0; }
  td.title { min-width: 260px; max-width: 380px; }
  td.title a { color: var(--accent); text-decoration: none; }
  td.title a:hover { text-decoration: underline; }
  td.title .sub { display: block; font-size: 11px; color: var(--muted); }
  td.title .chips { display: block; margin-top: 5px; }
  td.mono { font-family: ui-monospace, Menlo, Consolas, monospace; font-size: 12px; }
  td.person { min-width: 210px; font-weight: 600; }
  td.person .sub { display: block; font-size: 11px; color: var(--muted); font-weight: 400; }
  tbody tr:hover { background: var(--surface-2); }

  /* ---- ADO-style state pills for PR status ---- */
  .pill {
    display: inline-block; font-size: 12px; font-weight: 600; line-height: 1.5;
    padding: 1px 10px; border-radius: 10px; white-space: nowrap;
  }
  .pill-active    { background: var(--accent-tint); color: var(--accent-dark); }
  .pill-completed { background: var(--good-tint); color: var(--good); }
  .pill-abandoned { background: var(--surface-2); color: var(--muted); }

  .chip {
    display: inline-block; font-size: 11px; font-weight: 650; line-height: 1.6;
    padding: 1px 8px; margin: 0 4px 4px 0; border-radius: 10px; white-space: nowrap;
  }
  .chip-good     { color: var(--good); background: var(--good-tint); }
  .chip-warning  { color: var(--warning); background: var(--warning-tint); }
  .chip-serious  { color: var(--warning); background: var(--warning-tint); }
  .chip-critical { color: var(--critical); background: var(--critical-tint); }

  .card { background: var(--surface-2); border-radius: 4px; padding: 16px 18px; margin-bottom: 14px; }
  .card h3 a { color: var(--accent); text-decoration: none; }
  .card h3 a:hover { text-decoration: underline; }
  .card ul { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 16px; }
  .cat { font-size: 11px; font-weight: 700; letter-spacing: 0.08em; text-transform: uppercase; color: var(--ink-2); }
  .card blockquote {
    margin: 6px 0 4px; padding: 0 0 0 14px; border-left: 3px solid var(--baseline);
    font-size: 14px; color: var(--ink);
  }
  .attrib { font-size: 12px; color: var(--muted); margin: 0; }

  .flag-list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 10px; font-size: 14px; }
  .empty { color: var(--muted); font-size: 14px; font-style: italic; }

  .talking-points {
    background: var(--surface-2); border-left: 4px solid var(--accent); border-radius: 4px;
    padding: 16px 18px; margin: 0; font: inherit; font-size: 14px; white-space: pre-wrap;
  }

  .tp-table td.title { min-width: 220px; max-width: 320px; font-weight: 600; }
  .tp-table td.points { min-width: 320px; }
  .tp-count { font-size: 11.5px; font-weight: 500; color: var(--muted); margin: 4px 0 0; }
  .tp-bullets { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 8px; }
  .tp-bullets li {
    font-size: 13.5px; color: var(--ink); line-height: 1.5;
  }
  .tp-badge {
    display: inline-block; font-size: 10.5px; font-weight: 700; letter-spacing: 0.03em;
    text-transform: uppercase; border-radius: 3px; padding: 1px 7px; margin-right: 8px;
    vertical-align: 1px; white-space: nowrap;
  }
  .tp-badge-action { background: var(--good-tint); color: var(--good); }
  .tp-badge-general { background: var(--surface-2); color: var(--muted); border: 1px solid var(--border); }

  .callout {
    background: var(--warning-tint); border-radius: 4px; border-left: 4px solid var(--warning);
    padding: 12px 16px; font-size: 13px; color: var(--ink-2); margin: 0 0 18px; max-width: 82ch;
  }
  .callout-info { background: var(--accent-tint); border-left-color: var(--accent); }
  .callout strong { color: var(--ink); }

  details.appendix { margin-top: 8px; }
  details.appendix > summary {
    cursor: pointer; font-size: 12px; font-weight: 700; letter-spacing: 0.1em; text-transform: uppercase;
    color: var(--ink-2); padding-bottom: 8px; border-bottom: 2px solid var(--baseline); margin: 32px 0 12px;
    list-style: none;
  }
  details.appendix > summary::-webkit-details-marker { display: none; }
  details.appendix > summary::before { content: '\25B8\00a0'; color: var(--accent); }
  details.appendix[open] > summary::before { content: '\25BE\00a0'; }

  footer.report { margin-top: 40px; padding-top: 16px; border-top: 1px solid var(--baseline); font-size: 12px; color: var(--muted); max-width: 86ch; }
  footer.report p { margin: 0 0 8px; }

  @media print {
    :root { color-scheme: light; }
    body { background: #fff; }
    .wrap { max-width: none; padding: 0; }
    .card, .tile, .panel, section { break-inside: avoid; }
    tbody tr:hover { background: transparent; }
    details.appendix { display: block; }
  }
'@
}
