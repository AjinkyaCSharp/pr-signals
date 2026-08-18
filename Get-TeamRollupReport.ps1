<#
.SYNOPSIS
    Produces one report covering a whole team over a month, quarter, 6 months or year -
    plus the individual report for every member in that period.

.DESCRIPTION
    Reads the roster from teams.json, works out which months the requested period
    covers, and for each member+month:

      1. runs Get-TeamKpiReport.ps1 against kpi-raw\<email>-<month>.json, if that
         raw file exists (skip with -SkipMemberReports to only re-aggregate)
      2. loads the resulting <email>-<month>-summary.json
      3. aggregates every PR across every member into team-level metrics

    Team rates are recomputed from the underlying counts, never averaged from the
    members' own rates - averaging percentages weights a person with 2 PRs the same
    as a person with 20. Cycle-time medians come from the full pooled list of PRs
    for the same reason.

    Months with no raw data are reported as coverage gaps rather than being silently
    treated as zero, because "no PRs" and "we never collected it" mean very different
    things in a review conversation.

.PARAMETER TeamName
    Team to report on, matched case-insensitively against name / displayName in the
    roster file.

.PARAMETER Period
    month (1), quarter (3), halfyear (6) or year (12). Default month.

.PARAMETER EndMonth
    Last month of the period, yyyy-MM. Defaults to the current month. A quarter
    ending 2026-07 covers 2026-05, 2026-06 and 2026-07.

.PARAMETER TeamsConfigPath
    Roster file. Default .\teams.json (copy teams.example.json to create it).

.PARAMETER RawDir
    Where the per-person raw JSON lives. Default .\kpi-raw

.PARAMETER OutputDir
    Where reports are written and per-person summaries are read from. Default .\kpi-reports

.PARAMETER SkipMemberReports
    Don't re-run the per-person script; only aggregate the summary JSON already present.

.OUTPUTS
    <team>-<period>-team.html      the team report to present
    <team>-<period>-members.csv    one row per member per month
    <team>-<period>-prs.csv        every PR across the team in the period
    team-ledger.csv                one row per team-period, updated in place on re-runs

.EXAMPLE
    .\Get-TeamRollupReport.ps1 -TeamName alpha -Period quarter -EndMonth 2026-07

.EXAMPLE
    .\Get-TeamRollupReport.ps1 -TeamName alpha -Period year -EndMonth 2026-12 -SkipMemberReports
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TeamName,

    [ValidateSet('month', 'quarter', 'halfyear', 'year')]
    [string]$Period = 'month',

    [string]$EndMonth = (Get-Date).ToString('yyyy-MM'),

    [string]$TeamsConfigPath = (Join-Path $PSScriptRoot 'teams.json'),

    [string]$RawDir = (Join-Path $PSScriptRoot 'kpi-raw'),

    [string]$OutputDir = (Join-Path $PSScriptRoot 'kpi-reports'),

    [switch]$SkipMemberReports,

    [int]$LargeChurnThreshold = 400,

    [int]$LargeFileCountThreshold = 15
)

$ErrorActionPreference = 'Stop'
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture

. (Join-Path $PSScriptRoot 'KpiReportCommon.ps1')

if (-not (Test-Path $TeamsConfigPath)) {
    throw "Roster not found: $TeamsConfigPath. Copy teams.example.json to teams.json and add your team."
}
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }

$config = Get-Content -Raw -Path $TeamsConfigPath | ConvertFrom-Json
$team = @($config.teams | Where-Object {
    $_.name -ieq $TeamName -or $_.displayName -ieq $TeamName
}) | Select-Object -First 1

if (-not $team) {
    $known = (@($config.teams | ForEach-Object { $_.name }) -join ', ')
    throw "Team '$TeamName' not found in $TeamsConfigPath. Teams defined: $known"
}

$members = @($team.members | Where-Object { $_.email })
if ($members.Count -eq 0) { throw "Team '$TeamName' has no members with an email in $TeamsConfigPath." }

$teamLabel   = if ($team.displayName) { $team.displayName } else { $team.name }
$months      = @(Get-PeriodMonths -Period $Period -EndMonth $EndMonth)
$periodLabel = Get-PeriodLabel -Period $Period -Months $months
$safeTeam    = Get-SafeName $team.name
$periodSlug  = if ($Period -eq 'month') { $months[-1] } else { "$($months[0])_$($months[-1])" }

# The immediately preceding period of equal length, for the trend column.
$prevEnd    = ([datetime]::ParseExact($months[0], 'yyyy-MM', [System.Globalization.CultureInfo]::InvariantCulture)).AddMonths(-1).ToString('yyyy-MM')
$prevMonths = @(Get-PeriodMonths -Period $Period -EndMonth $prevEnd)

Write-Host "Team: $teamLabel  |  Period: $periodLabel  |  Members: $($members.Count)"

# ---------------------------------------------------------------------------
# Step 1 - make sure every member+month has an individual report
# ---------------------------------------------------------------------------
$memberScript = Join-Path $PSScriptRoot 'Get-TeamKpiReport.ps1'
if (-not $SkipMemberReports) {
    foreach ($member in $members) {
        $safeEmail = Get-SafeName $member.email
        foreach ($month in $months) {
            $rawPath = Join-Path $RawDir "$safeEmail-$month.json"
            if (-not (Test-Path $rawPath)) { continue }
            Write-Host "  running $($member.email) $month"
            # 6>$null swallows the child script's Write-Host banner; real errors still surface.
            & $memberScript -InputJsonPath $rawPath -OutputDir $OutputDir `
                -LargeChurnThreshold $LargeChurnThreshold `
                -LargeFileCountThreshold $LargeFileCountThreshold 6>$null
        }
    }
}

# ---------------------------------------------------------------------------
# Step 2 - aggregate. Called once for the period and once for the previous one.
# ---------------------------------------------------------------------------
function Get-TeamAggregate {
    param([array]$Members, [string[]]$Months, [string]$SummaryDir)

    $allPrs      = New-Object System.Collections.Generic.List[object]
    $memberRows  = New-Object System.Collections.Generic.List[object]
    $gaps        = New-Object System.Collections.Generic.List[object]
    $prCountByMember = @{}

    foreach ($member in $Members) {
        $safeEmail = Get-SafeName $member.email
        $prCountByMember[$member.email] = 0
        foreach ($month in $Months) {
            $summaryPath = Join-Path $SummaryDir "$safeEmail-$month-summary.json"
            if (-not (Test-Path $summaryPath)) {
                $gaps.Add([pscustomobject]@{ email = $member.email; month = $month }) | Out-Null
                continue
            }
            $s = Get-Content -Raw -Path $summaryPath | ConvertFrom-Json
            foreach ($pr in @($s.pullRequests)) {
                $allPrs.Add([pscustomobject]@{ person = $s.person; monthYear = $s.monthYear; pr = $pr }) | Out-Null
            }
            $prCountByMember[$member.email] += [int]$s.totalRaised
            $memberRows.Add([pscustomobject][ordered]@{
                person                  = $s.person
                displayName             = $member.displayName
                monthYear               = $s.monthYear
                qualityScore            = $s.qualityScore
                totalRaised             = $s.totalRaised
                mergedToMaster          = $s.mergedToMaster
                mergeRatePercent        = $s.mergeRatePercent
                medianCycleTimeHours    = $s.medianCycleTimeHours
                threadResolutionPercent = $s.threadResolutionPercent
                totalComments           = $s.totalComments
                reviewerDiversityCount  = $s.reviewerDiversityCount
                noWorkItemRatePercent   = $s.noWorkItemRatePercent
                largePrCount            = $s.largePrCount
                selfApprovalCount       = $s.selfApprovalCount
                noApprovalMergedCount   = $s.noApprovalMergedCount
                vagueCommitCount        = $s.vagueCommitCount
                vagueCommitRatePercent  = $s.vagueCommitRatePercent
            }) | Out-Null
        }
    }

    # Pooled PR-level aggregation - rates rebuilt from counts, not averaged.
    $raised = $allPrs.Count
    $merged = @($allPrs | Where-Object { $_.pr.mergedToMaster }).Count
    $abandoned = @($allPrs | Where-Object { $_.pr.status -ieq 'abandoned' }).Count
    $cycleTimes = @($allPrs | Where-Object { $_.pr.mergedToMaster -and $null -ne $_.pr.cycleTimeHours } |
                    ForEach-Object { [double]$_.pr.cycleTimeHours })
    $threads   = (@($allPrs | ForEach-Object { [int]$_.pr.threadCount }) | Measure-Object -Sum).Sum
    $comments  = (@($allPrs | ForEach-Object { [int]$_.pr.commentCount }) | Measure-Object -Sum).Sum
    $added     = (@($allPrs | ForEach-Object { [int]$_.pr.linesAdded }) | Measure-Object -Sum).Sum
    $deleted   = (@($allPrs | ForEach-Object { [int]$_.pr.linesDeleted }) | Measure-Object -Sum).Sum
    $files     = (@($allPrs | ForEach-Object { [int]$_.pr.filesChangedCount }) | Measure-Object -Sum).Sum
    $commits   = (@($allPrs | ForEach-Object { [int]$_.pr.commitCount }) | Measure-Object -Sum).Sum
    $vague     = (@($allPrs | ForEach-Object { [int]$_.pr.vagueCommitCount }) | Measure-Object -Sum).Sum
    $largePrs  = @($allPrs | Where-Object { $_.pr.largePrFlag }).Count
    $selfApp   = @($allPrs | Where-Object { $_.pr.selfApprovalFlag }).Count
    $noAppr    = @($allPrs | Where-Object { $_.pr.noApprovalMergedFlag }).Count
    $noWorkIt  = @($allPrs | Where-Object { $_.pr.noWorkItemFlag }).Count
    $descFlag  = @($allPrs | Where-Object { $_.pr.descriptionFlag }).Count
    $flagged   = @($allPrs | Where-Object { [int]$_.pr.commentFlagCount -gt 0 }).Count

    # Resolved threads aren't on the PR object, so take them from the member summaries.
    $resolved = 0; $threadTotalFromSummaries = 0
    foreach ($member in $Members) {
        $safeEmail = Get-SafeName $member.email
        foreach ($month in $Months) {
            $p = Join-Path $SummaryDir "$safeEmail-$month-summary.json"
            if (-not (Test-Path $p)) { continue }
            $s = Get-Content -Raw -Path $p | ConvertFrom-Json
            $resolved += [int]$s.resolvedThreads
            $threadTotalFromSummaries += [int]$s.totalThreads
        }
    }

    $pct = { param($n, $d) if ($d -gt 0) { [math]::Round(100 * $n / $d, 1) } else { 0 } }

    $mergeRate       = & $pct $merged $raised
    $abandonRate     = & $pct $abandoned $raised
    $threadResPct    = if ($threadTotalFromSummaries -gt 0) { [math]::Round(100 * $resolved / $threadTotalFromSummaries, 1) } else { $null }
    $noWorkItemRate  = & $pct $noWorkIt $raised
    $descFlagRate    = & $pct $descFlag $raised
    $commentFlagRate = & $pct $flagged $raised
    $largePrRate     = & $pct $largePrs $raised
    $selfApprovalRate= & $pct $selfApp $raised
    $noApprovalRate  = if ($merged -gt 0) { [math]::Round(100 * $noAppr / $merged, 1) } else { 0 }
    $vagueRate       = & $pct $vague $commits

    # Same composite formula as the individual report, fed team-level totals.
    $hygiene = 100 - (($noWorkItemRate + $descFlagRate + $commentFlagRate + $largePrRate + $vagueRate) / 5)
    if ($hygiene -lt 0) { $hygiene = 0 }
    $governance = 100 - (($selfApprovalRate * 2) + $noApprovalRate)
    if ($governance -lt 0) { $governance = 0 }
    $threadResForScore = if ($null -ne $threadResPct) { $threadResPct } else { 100 }
    $score = [math]::Round((0.35 * $mergeRate) + (0.25 * $threadResForScore) + (0.25 * $hygiene) + (0.15 * $governance), 1)

    # Workload spread. Reported as a distribution, never as a ranking - PR counts
    # track ticket sizing far more than they track ability.
    $counts = @($Members | ForEach-Object { [int]$prCountByMember[$_.email] })
    $contributors = @($counts | Where-Object { $_ -gt 0 }).Count
    $busiest = if ($counts.Count -gt 0) { ($counts | Measure-Object -Maximum).Maximum } else { 0 }
    $quietest = if ($counts.Count -gt 0) { ($counts | Measure-Object -Minimum).Minimum } else { 0 }
    $concentration = & $pct $busiest $raised

    return [pscustomobject]@{
        months                  = $Months
        memberCount             = $Members.Count
        contributorCount        = $contributors
        totalRaised             = $raised
        mergedToMaster          = $merged
        mergeRatePercent        = $mergeRate
        abandonedCount          = $abandoned
        abandonRatePercent      = $abandonRate
        avgCycleTimeHours       = if ($cycleTimes.Count -gt 0) { [math]::Round(($cycleTimes | Measure-Object -Average).Average, 1) } else { $null }
        medianCycleTimeHours    = Get-Median -Values $cycleTimes
        totalThreads            = $threadTotalFromSummaries
        resolvedThreads         = $resolved
        threadResolutionPercent = $threadResPct
        totalComments           = $comments
        avgCommentsPerPr        = if ($raised -gt 0) { [math]::Round($comments / $raised, 1) } else { 0 }
        noWorkItemCount         = $noWorkIt
        noWorkItemRatePercent   = $noWorkItemRate
        descriptionFlagCount    = $descFlag
        descriptionFlagRatePercent = $descFlagRate
        commentFlagRatePercent  = $commentFlagRate
        totalLinesAdded         = $added
        totalLinesDeleted       = $deleted
        totalFilesChanged       = $files
        avgChurnPerPr           = if ($raised -gt 0) { [math]::Round(($added + $deleted) / $raised, 1) } else { 0 }
        largePrCount            = $largePrs
        largePrRatePercent      = $largePrRate
        selfApprovalCount       = $selfApp
        selfApprovalRatePercent = $selfApprovalRate
        noApprovalMergedCount   = $noAppr
        noApprovalMergedRatePercent = $noApprovalRate
        totalCommits            = $commits
        vagueCommitCount        = $vague
        vagueCommitRatePercent  = $vagueRate
        teamQualityScore        = $score
        prsPerMemberMax         = $busiest
        prsPerMemberMin         = $quietest
        prsPerMemberMedian      = Get-Median -Values @($counts | ForEach-Object { [double]$_ })
        busiestSharePercent     = $concentration
        prCountByMember         = $prCountByMember
        allPrs                  = $allPrs
        memberRows              = $memberRows
        gaps                    = $gaps
    }
}

$agg  = Get-TeamAggregate -Members $members -Months $months -SummaryDir $OutputDir
$prev = Get-TeamAggregate -Members $members -Months $prevMonths -SummaryDir $OutputDir
# Only treat the previous period as comparable if it actually holds data.
if ($prev.totalRaised -eq 0) { $prev = $null }

if ($agg.totalRaised -eq 0) {
    Write-Warning "No data found for $teamLabel in $periodLabel. Expected files like $OutputDir\<email>-<month>-summary.json, or raw input at $RawDir\<email>-<month>.json."
}

# ---------------------------------------------------------------------------
# Step 3 - CSV outputs
# ---------------------------------------------------------------------------
$membersCsvPath = Join-Path $OutputDir "$safeTeam-$periodSlug-members.csv"
$teamPrsCsvPath = Join-Path $OutputDir "$safeTeam-$periodSlug-prs.csv"
$teamLedgerPath = Join-Path $OutputDir 'team-ledger.csv'

# .ToArray() rather than @(...): piping a generic List straight into Export-Csv
# fails parameter binding with "Argument types do not match" on PowerShell 7.
$agg.memberRows.ToArray() | Export-Csv -Path $membersCsvPath -NoTypeInformation -Encoding UTF8

$teamPrRows = foreach ($entry in $agg.allPrs) {
    $pr = $entry.pr
    [pscustomobject][ordered]@{
        team              = $team.name
        person            = $entry.person
        monthYear         = $entry.monthYear
        pullRequestId     = $pr.pullRequestId
        title             = $pr.title
        url               = $pr.url
        status            = $pr.status
        mergedToMaster    = $pr.mergedToMaster
        cycleTimeHours    = $pr.cycleTimeHours
        threadCount       = $pr.threadCount
        commentCount      = $pr.commentCount
        filesChangedCount = $pr.filesChangedCount
        linesAdded        = $pr.linesAdded
        linesDeleted      = $pr.linesDeleted
        churn             = $pr.churn
        largePrFlag       = $pr.largePrFlag
        noWorkItemFlag    = $pr.noWorkItemFlag
        descriptionFlag   = $pr.descriptionFlag
        selfApprovalFlag  = $pr.selfApprovalFlag
        noApprovalMergedFlag = $pr.noApprovalMergedFlag
        commitCount       = $pr.commitCount
        vagueCommitCount  = $pr.vagueCommitCount
    }
}
@($teamPrRows) | Export-Csv -Path $teamPrsCsvPath -NoTypeInformation -Encoding UTF8

$ledgerColumns = @(
    'team', 'period', 'periodStart', 'periodEnd', 'generatedAtUtc', 'teamQualityScore',
    'memberCount', 'contributorCount', 'totalRaised', 'mergedToMaster', 'mergeRatePercent',
    'abandonedCount', 'abandonRatePercent', 'avgCycleTimeHours', 'medianCycleTimeHours',
    'totalThreads', 'resolvedThreads', 'threadResolutionPercent', 'totalComments', 'avgCommentsPerPr',
    'noWorkItemRatePercent', 'descriptionFlagRatePercent', 'commentFlagRatePercent',
    'totalLinesAdded', 'totalLinesDeleted', 'avgChurnPerPr', 'largePrCount', 'largePrRatePercent',
    'selfApprovalCount', 'selfApprovalRatePercent', 'noApprovalMergedCount', 'noApprovalMergedRatePercent',
    'totalCommits', 'vagueCommitCount', 'vagueCommitRatePercent',
    'prsPerMemberMin', 'prsPerMemberMedian', 'prsPerMemberMax', 'busiestSharePercent', 'coverageGaps'
)
$ledgerRow = [pscustomobject][ordered]@{}
Add-Member -InputObject $ledgerRow -MemberType NoteProperty -Name 'team' -Value $team.name
Add-Member -InputObject $ledgerRow -MemberType NoteProperty -Name 'period' -Value $Period
Add-Member -InputObject $ledgerRow -MemberType NoteProperty -Name 'periodStart' -Value $months[0]
Add-Member -InputObject $ledgerRow -MemberType NoteProperty -Name 'periodEnd' -Value $months[-1]
Add-Member -InputObject $ledgerRow -MemberType NoteProperty -Name 'generatedAtUtc' -Value ((Get-Date).ToUniversalTime().ToString('o'))
Add-Member -InputObject $ledgerRow -MemberType NoteProperty -Name 'coverageGaps' -Value $agg.gaps.Count
foreach ($col in $ledgerColumns) {
    if ($ledgerRow.PSObject.Properties.Name -contains $col) { continue }
    Add-Member -InputObject $ledgerRow -MemberType NoteProperty -Name $col -Value $agg.$col
}

$ledgerRows = New-Object System.Collections.Generic.List[object]
if (Test-Path $teamLedgerPath) {
    foreach ($existing in @(Import-Csv -Path $teamLedgerPath)) {
        if ($existing.team -eq $team.name -and $existing.periodStart -eq $months[0] -and $existing.periodEnd -eq $months[-1]) { continue }
        $ledgerRows.Add($existing) | Out-Null
    }
}
$ledgerRows.Add($ledgerRow) | Out-Null
$ledgerRows | Select-Object $ledgerColumns | Sort-Object team, periodEnd |
    Export-Csv -Path $teamLedgerPath -NoTypeInformation -Encoding UTF8

# ---------------------------------------------------------------------------
# Step 4 - HTML
# ---------------------------------------------------------------------------
$cmp = if ($Period -eq 'month') { 'previous month' } else { "previous $Period" }

$tiles = @(
    (New-Tile -Label 'PRs raised' -Value "$($agg.totalRaised)" -Note "across $($agg.contributorCount) of $($agg.memberCount) members" `
        -DeltaHtml (New-DeltaHtml -Current $agg.totalRaised -Previous $prev.totalRaised -HigherIsBetter -PeriodLabel $cmp)),
    (New-Tile -Label 'Merged to master' -Value "$($agg.mergedToMaster)" -Note "$($agg.mergeRatePercent)% of PRs raised" `
        -DeltaHtml (New-DeltaHtml -Current $agg.mergeRatePercent -Previous $prev.mergeRatePercent -HigherIsBetter -Suffix 'pp' -PeriodLabel $cmp)),
    (New-Tile -Label 'Median cycle time' -Value (Format-Metric $agg.medianCycleTimeHours ' h') -Note (Format-Metric $agg.avgCycleTimeHours ' h average') `
        -DeltaHtml (New-DeltaHtml -Current $agg.medianCycleTimeHours -Previous $prev.medianCycleTimeHours -Suffix 'h' -PeriodLabel $cmp)),
    (New-Tile -Label 'Threads resolved' -Value (Format-Metric $agg.threadResolutionPercent '%') -Note "$($agg.resolvedThreads) of $($agg.totalThreads) threads" `
        -DeltaHtml (New-DeltaHtml -Current $agg.threadResolutionPercent -Previous $prev.threadResolutionPercent -HigherIsBetter -Suffix 'pp' -PeriodLabel $cmp)),
    (New-Tile -Label 'Review comments' -Value "$($agg.totalComments)" -Note "avg $($agg.avgCommentsPerPr) per PR" `
        -DeltaHtml (New-DeltaHtml -Current $agg.avgCommentsPerPr -Previous $prev.avgCommentsPerPr -Suffix '/PR' -PeriodLabel $cmp)),
    (New-Tile -Label 'Governance flags' -Value "$($agg.selfApprovalCount + $agg.noApprovalMergedCount)" -Note 'self-approvals + no-approval merges' `
        -DeltaHtml (New-DeltaHtml -Current ($agg.selfApprovalCount + $agg.noApprovalMergedCount) -Previous ($prev.selfApprovalCount + $prev.noApprovalMergedCount) -PeriodLabel $cmp))
) -join "`n"

$deliveryRows = @(
    (New-MetricRow 'PRs raised' "$($agg.totalRaised)" (New-DeltaHtml -Current $agg.totalRaised -Previous $prev.totalRaised -HigherIsBetter -PeriodLabel $cmp)),
    (New-MetricRow 'Merged to master' "$($agg.mergedToMaster) ($($agg.mergeRatePercent)%)" (New-DeltaHtml -Current $agg.mergeRatePercent -Previous $prev.mergeRatePercent -HigherIsBetter -Suffix 'pp' -PeriodLabel $cmp)),
    (New-MetricRow 'Abandoned' "$($agg.abandonedCount) ($($agg.abandonRatePercent)%)" (New-DeltaHtml -Current $agg.abandonRatePercent -Previous $prev.abandonRatePercent -Suffix 'pp' -PeriodLabel $cmp)),
    (New-MetricRow 'Avg cycle time' (Format-Metric $agg.avgCycleTimeHours ' h') (New-DeltaHtml -Current $agg.avgCycleTimeHours -Previous $prev.avgCycleTimeHours -Suffix 'h' -PeriodLabel $cmp))
) -join "`n"

$reviewRows = @(
    (New-MetricRow 'Review threads' "$($agg.totalThreads)" ''),
    (New-MetricRow 'Threads resolved' "$($agg.resolvedThreads) ($(Format-Metric $agg.threadResolutionPercent '%'))" (New-DeltaHtml -Current $agg.threadResolutionPercent -Previous $prev.threadResolutionPercent -HigherIsBetter -Suffix 'pp' -PeriodLabel $cmp)),
    (New-MetricRow 'Comments per PR' "$($agg.avgCommentsPerPr)" (New-DeltaHtml -Current $agg.avgCommentsPerPr -Previous $prev.avgCommentsPerPr -Suffix '/PR' -PeriodLabel $cmp)),
    (New-MetricRow 'PRs with a comment flag' "$($agg.commentFlagRatePercent)%" (New-DeltaHtml -Current $agg.commentFlagRatePercent -Previous $prev.commentFlagRatePercent -Suffix 'pp' -PeriodLabel $cmp))
) -join "`n"

$hygieneRows = @(
    (New-MetricRow 'Missing work item link' "$($agg.noWorkItemCount) ($($agg.noWorkItemRatePercent)%)" (New-DeltaHtml -Current $agg.noWorkItemRatePercent -Previous $prev.noWorkItemRatePercent -Suffix 'pp' -PeriodLabel $cmp)),
    (New-MetricRow 'Incomplete / stale description' "$($agg.descriptionFlagCount) ($($agg.descriptionFlagRatePercent)%)" (New-DeltaHtml -Current $agg.descriptionFlagRatePercent -Previous $prev.descriptionFlagRatePercent -Suffix 'pp' -PeriodLabel $cmp)),
    (New-MetricRow 'Large / risky-to-review PRs' "$($agg.largePrCount) ($($agg.largePrRatePercent)%)" (New-DeltaHtml -Current $agg.largePrRatePercent -Previous $prev.largePrRatePercent -Suffix 'pp' -PeriodLabel $cmp)),
    (New-MetricRow 'Avg churn per PR' "$($agg.avgChurnPerPr)" (New-DeltaHtml -Current $agg.avgChurnPerPr -Previous $prev.avgChurnPerPr -PeriodLabel $cmp)),
    (New-MetricRow 'Vague commit messages' "$($agg.vagueCommitCount) of $($agg.totalCommits) ($($agg.vagueCommitRatePercent)%)" (New-DeltaHtml -Current $agg.vagueCommitRatePercent -Previous $prev.vagueCommitRatePercent -Suffix 'pp' -PeriodLabel $cmp))
) -join "`n"

$govRows = @(
    (New-MetricRow 'Author approved their own PR' "$($agg.selfApprovalCount) ($($agg.selfApprovalRatePercent)%)" (New-DeltaHtml -Current $agg.selfApprovalRatePercent -Previous $prev.selfApprovalRatePercent -Suffix 'pp' -PeriodLabel $cmp)),
    (New-MetricRow 'Merged with no approving reviewer' "$($agg.noApprovalMergedCount) ($($agg.noApprovalMergedRatePercent)% of merges)" (New-DeltaHtml -Current $agg.noApprovalMergedRatePercent -Previous $prev.noApprovalMergedRatePercent -Suffix 'pp' -PeriodLabel $cmp))
) -join "`n"

$distRows = @(
    (New-MetricRow 'Members who raised at least one PR' "$($agg.contributorCount) of $($agg.memberCount)" ''),
    (New-MetricRow 'PRs per member - lowest' "$($agg.prsPerMemberMin)" ''),
    (New-MetricRow 'PRs per member - median' "$($agg.prsPerMemberMedian)" ''),
    (New-MetricRow 'PRs per member - highest' "$($agg.prsPerMemberMax)" ''),
    (New-MetricRow 'Share held by the busiest member' "$($agg.busiestSharePercent)%" '')
) -join "`n"

# Members listed alphabetically on purpose - see the caveat in the section itself.
$memberTableRows = (@(
    foreach ($member in ($members | Sort-Object { $_.email })) {
        $rows = @($agg.memberRows | Where-Object { $_.person -ieq $member.email })
        $name = if ($member.displayName) { $member.displayName } else { $member.email }
        if ($rows.Count -eq 0) {
            '<tr><td class="person">' + (ConvertTo-HtmlText $name) + '<span class="sub">' + (ConvertTo-HtmlText $member.email) + '</span></td>' +
            '<td colspan="8" class="empty">No data collected for this period.</td></tr>'
            continue
        }
        $raised   = (@($rows | ForEach-Object { [int]$_.totalRaised }) | Measure-Object -Sum).Sum
        $merged   = (@($rows | ForEach-Object { [int]$_.mergedToMaster }) | Measure-Object -Sum).Sum
        $comments = (@($rows | ForEach-Object { [int]$_.totalComments }) | Measure-Object -Sum).Sum
        $selfApp  = (@($rows | ForEach-Object { [int]$_.selfApprovalCount }) | Measure-Object -Sum).Sum
        $noAppr   = (@($rows | ForEach-Object { [int]$_.noApprovalMergedCount }) | Measure-Object -Sum).Sum
        $largePr  = (@($rows | ForEach-Object { [int]$_.largePrCount }) | Measure-Object -Sum).Sum
        $vague    = (@($rows | ForEach-Object { [int]$_.vagueCommitCount }) | Measure-Object -Sum).Sum
        $medians  = @($rows | Where-Object { $null -ne $_.medianCycleTimeHours } | ForEach-Object { [double]$_.medianCycleTimeHours })
        $scores   = @($rows | Where-Object { $null -ne $_.qualityScore } | ForEach-Object { [double]$_.qualityScore })
        $chips = ''
        if ($selfApp -gt 0) { $chips += (New-Chip 'critical' "$selfApp self-approved") }
        if ($noAppr -gt 0)  { $chips += (New-Chip 'critical' "$noAppr no-approval merge") }
        if ($largePr -gt 0) { $chips += (New-Chip 'warning' "$largePr large PR") }
        if ($vague -gt 0)   { $chips += (New-Chip 'serious' "$vague vague commits") }

        '<tr><td class="person">' + (ConvertTo-HtmlText $name) + '<span class="sub">' + (ConvertTo-HtmlText $member.email) + '</span></td>' +
        '<td class="num">' + $rows.Count + '</td>' +
        '<td class="num">' + $raised + '</td>' +
        '<td class="num">' + $merged + '</td>' +
        '<td class="num">' + (Format-Metric (Get-Median -Values $medians) ' h') + '</td>' +
        '<td class="num">' + $comments + '</td>' +
        '<td class="num">' + (Format-Metric $(if ($scores.Count -gt 0) { [math]::Round(($scores | Measure-Object -Average).Average, 1) } else { $null })) + '</td>' +
        '<td>' + $chips + '</td></tr>'
    }
) -join "`n")

$gapSection = if ($agg.gaps.Count -eq 0) {
    '<p class="empty">No gaps. Every member has data for every month in this period.</p>'
} else {
    $items = (@($agg.gaps | ForEach-Object {
        '<li>' + (ConvertTo-HtmlText $_.email) + ' &mdash; ' + (ConvertTo-HtmlText $_.month) + '</li>'
    }) -join "`n")
    '<p class="callout"><strong>' + $agg.gaps.Count + ' member-months have no collected data.</strong> These are counted as missing, not as zero. Collect the raw JSON for them before reading anything into the totals below.</p><ul class="flag-list">' + $items + '</ul>'
}

$govFlagRows = (@(
    foreach ($entry in ($agg.allPrs | Where-Object { $_.pr.selfApprovalFlag -or $_.pr.noApprovalMergedFlag })) {
        $pr = $entry.pr
        $chips = ''
        if ($pr.selfApprovalFlag)     { $chips += (New-Chip 'critical' 'self-approved') }
        if ($pr.noApprovalMergedFlag) { $chips += (New-Chip 'critical' 'no approval') }
        $titleCell = if ($pr.url) { '<a href="' + (ConvertTo-HtmlText $pr.url) + '">' + (ConvertTo-HtmlText $pr.title) + '</a>' } else { ConvertTo-HtmlText $pr.title }
        '<tr><td class="num">' + $pr.pullRequestId + '</td><td class="title">' + $titleCell + '</td>' +
        '<td>' + (ConvertTo-HtmlText $entry.person) + '</td><td>' + (ConvertTo-HtmlText $entry.monthYear) + '</td><td>' + $chips + '</td></tr>'
    }
) -join "`n")
$govFlagSection = if (-not $govFlagRows) {
    '<p class="empty">No self-approvals or no-approval merges anywhere in the team this period.</p>'
} else {
    '<div class="scroll"><table><thead><tr><th>PR</th><th>Title</th><th>Author</th><th>Month</th><th>Flag</th></tr></thead><tbody>' + $govFlagRows + '</tbody></table></div>'
}

$monthsCovered = ($months -join ', ')
$trendNote = if ($prev) {
    "Trends compare against the $cmp ($($prevMonths[0]) to $($prevMonths[-1]))."
} else {
    "No comparable data for the $cmp, so no trends yet."
}

$htmlTemplate = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Team report - {{TEAM}} - {{PERIOD}}</title>
<style>
{{STYLE}}
</style>
</head>
<body>
<div class="wrap">

  <header class="report">
    <p class="eyebrow">Team PR / KPI report</p>
    <h1>{{TEAM}}</h1>
    <p class="subject">{{PERIOD}} &middot; {{MEMBER_COUNT}} members &middot; months covered: {{MONTHS}}</p>
    <p class="stamp">Generated {{GENERATED}} &middot; {{TREND_NOTE}}</p>
  </header>

  <div class="hero">
    <p class="hero-value">{{SCORE}}</p>
    <div>
      <p class="hero-label">Team composite score, out of 100</p>
      {{SCORE_DELTA}}
    </div>
    <p class="hero-note">Computed from the team's pooled totals, not by averaging individual scores. It is a conversation starter for a retro, not a rating of the team or anyone in it.</p>
  </div>

  <section>
    <h2>Team performance</h2>
    <div class="tiles">
      {{TILES}}
    </div>
  </section>

  <section class="grid-2">
    <div>
      <h2>Delivery</h2>
      <table class="metrics"><tbody>{{DELIVERY_ROWS}}</tbody></table>
    </div>
    <div>
      <h2>Review culture</h2>
      <table class="metrics"><tbody>{{REVIEW_ROWS}}</tbody></table>
    </div>
    <div>
      <h2>PR &amp; commit hygiene</h2>
      <table class="metrics"><tbody>{{HYGIENE_ROWS}}</tbody></table>
    </div>
    <div>
      <h2>Governance risk</h2>
      <table class="metrics"><tbody>{{GOV_ROWS}}</tbody></table>
    </div>
  </section>

  <section>
    <h2>Workload spread</h2>
    <p class="callout callout-info">Spread is a <strong>planning signal, not a performance one</strong>. A member with few PRs may be on large tickets, on support, mentoring, or on leave. Use this to ask where the work is concentrated and whether that is a risk if someone is away &mdash; not to compare people.</p>
    <table class="metrics"><tbody>{{DIST_ROWS}}</tbody></table>
  </section>

  <section>
    <h2>Per member</h2>
    <p class="callout callout-info">Listed <strong>alphabetically, deliberately</strong>. Sorting this table by PR count or score turns it into a ranking, and PR counts measure ticket sizing far more than they measure contribution. Each person's own report holds the detail and the review comments behind these numbers.</p>
    <div class="scroll">
      <table>
        <thead><tr>
          <th>Member</th><th>Months with data</th><th>PRs raised</th><th>Merged</th>
          <th>Median cycle h</th><th>Comments</th><th>Avg score</th><th>Flags</th>
        </tr></thead>
        <tbody>{{MEMBER_ROWS}}</tbody>
      </table>
    </div>
  </section>

  <section>
    <h2>Governance flags across the team</h2>
    {{GOV_FLAGS}}
  </section>

  <section>
    <h2>Coverage</h2>
    {{GAPS}}
  </section>

  <footer class="report">
    <p><strong>Scope.</strong> Pull requests only. Nothing here sees design work, mentoring, on-call, incident response, support load, or whether the team was pointed at the right problem. A quarter's PR count is not a quarter's contribution.</p>
    <p><strong>How team rates are built.</strong> Every rate is recomputed from the pooled counts across all members, never averaged from individual rates &mdash; averaging would weight a member with 2 PRs the same as one with 20. Cycle-time figures come from the full pooled list of merged PRs.</p>
    <p><strong>Handling.</strong> Contains per-person metrics for identifiable colleagues. Keep it out of shared drives and version control. Where you are subject to works-council or co-determination rules, systematic individual productivity data usually needs to be agreed before it is collected.</p>
  </footer>

</div>
</body>
</html>
'@

$html = $htmlTemplate.
    Replace('{{STYLE}}',         (Get-KpiReportCss)).
    Replace('{{TEAM}}',          (ConvertTo-HtmlText $teamLabel)).
    Replace('{{PERIOD}}',        (ConvertTo-HtmlText $periodLabel)).
    Replace('{{MEMBER_COUNT}}',  "$($members.Count)").
    Replace('{{MONTHS}}',        (ConvertTo-HtmlText $monthsCovered)).
    Replace('{{GENERATED}}',     (ConvertTo-HtmlText ((Get-Date).ToString('yyyy-MM-dd HH:mm')))).
    Replace('{{TREND_NOTE}}',    (ConvertTo-HtmlText $trendNote)).
    Replace('{{SCORE}}',         "$($agg.teamQualityScore)").
    Replace('{{SCORE_DELTA}}',   (New-DeltaHtml -Current $agg.teamQualityScore -Previous $prev.teamQualityScore -HigherIsBetter -PeriodLabel $cmp)).
    Replace('{{TILES}}',         $tiles).
    Replace('{{DELIVERY_ROWS}}', $deliveryRows).
    Replace('{{REVIEW_ROWS}}',   $reviewRows).
    Replace('{{HYGIENE_ROWS}}',  $hygieneRows).
    Replace('{{GOV_ROWS}}',      $govRows).
    Replace('{{DIST_ROWS}}',     $distRows).
    Replace('{{MEMBER_ROWS}}',   $memberTableRows).
    Replace('{{GOV_FLAGS}}',     $govFlagSection).
    Replace('{{GAPS}}',          $gapSection)

$htmlPath = Join-Path $OutputDir "$safeTeam-$periodSlug-team.html"
$html | Set-Content -Path $htmlPath -Encoding UTF8

Write-Host ""
Write-Host "Team report:  $htmlPath"
Write-Host "Members CSV:  $membersCsvPath"
Write-Host "Team PRs CSV: $teamPrsCsvPath"
Write-Host "Team ledger:  $teamLedgerPath"
Write-Host ("PRs raised: {0}, Merged: {1} ({2}%), Team score: {3}, Coverage gaps: {4}" -f `
    $agg.totalRaised, $agg.mergedToMaster, $agg.mergeRatePercent, $agg.teamQualityScore, $agg.gaps.Count)
