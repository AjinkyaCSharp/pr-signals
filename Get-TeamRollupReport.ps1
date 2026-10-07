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

.PARAMETER StalePrDaysThreshold
    Business days a PR can stay active before it counts as stuck. Label text only here -
    the actual flag is computed per-person by Get-TeamKpiReport.ps1 and pooled from its
    summary JSON, so keep this in sync with that script's value. Default 5.

.PARAMETER HighCycleTimeDaysThreshold
    Business days threshold for the "PRs with high cycle time" tile label. Same caveat as
    StalePrDaysThreshold - pooled counts come from the per-person summaries. Default 10.

.PARAMETER StaleWorkItemDaysThreshold
    Business days threshold for the "Stuck in queue" tile label. Same caveat as
    StalePrDaysThreshold. Default 5.

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

    [int]$LargeFileCountThreshold = 15,

    [int]$StalePrDaysThreshold = 5,

    [int]$HighCycleTimeDaysThreshold = 10,

    [int]$StaleWorkItemDaysThreshold = 5
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
                totalRaised             = $s.totalRaised
                mergedToMaster          = $s.mergedToMaster
                mergeRatePercent        = $s.mergeRatePercent
                medianCycleTimeDays     = $s.medianCycleTimeDays
                totalComments           = $s.totalComments
                reviewerDiversityCount  = $s.reviewerDiversityCount
                noWorkItemRatePercent   = $s.noWorkItemRatePercent
                largePrCount            = $s.largePrCount
                vagueCommitCount        = $s.vagueCommitCount
                vagueCommitRatePercent  = $s.vagueCommitRatePercent
                reviewedCount           = $s.reviewedCount
                reviewedApprovedCount   = $s.reviewedApprovedCount
                totalWorkItemsAssigned  = $s.totalWorkItemsAssigned
                totalWorkItemsCompleted = $s.totalWorkItemsCompleted
            }) | Out-Null
        }
    }

    # Pooled PR-level aggregation - rates rebuilt from counts, not averaged.
    $raised = $allPrs.Count
    $merged = @($allPrs | Where-Object { $_.pr.mergedToMaster }).Count
    $abandoned = @($allPrs | Where-Object { $_.pr.status -ieq 'abandoned' }).Count
    $cycleTimes = @($allPrs | Where-Object { $_.pr.mergedToMaster -and $null -ne $_.pr.cycleTimeDays } |
                    ForEach-Object { [double]$_.pr.cycleTimeDays })
    $comments  = (@($allPrs | ForEach-Object { [int]$_.pr.commentCount }) | Measure-Object -Sum).Sum
    $added     = (@($allPrs | ForEach-Object { [int]$_.pr.linesAdded }) | Measure-Object -Sum).Sum
    $deleted   = (@($allPrs | ForEach-Object { [int]$_.pr.linesDeleted }) | Measure-Object -Sum).Sum
    $files     = (@($allPrs | ForEach-Object { [int]$_.pr.filesChangedCount }) | Measure-Object -Sum).Sum
    $commits   = (@($allPrs | ForEach-Object { [int]$_.pr.commitCount }) | Measure-Object -Sum).Sum
    $vague     = (@($allPrs | ForEach-Object { [int]$_.pr.vagueCommitCount }) | Measure-Object -Sum).Sum
    $largePrs  = @($allPrs | Where-Object { $_.pr.largePrFlag }).Count
    $noWorkIt  = @($allPrs | Where-Object { $_.pr.noWorkItemFlag }).Count
    $descFlag  = @($allPrs | Where-Object { $_.pr.descriptionFlag }).Count
    $flagged   = @($allPrs | Where-Object { [int]$_.pr.commentFlagCount -gt 0 }).Count

    # Reviewed-PR counts and work-item counts aren't on the pooled PR list, so
    # take them from the member summaries directly.
    $reviewedTotal = 0; $reviewedApprovedTotal = 0
    $workItemsAssignedTotal = 0; $workItemsCompletedTotal = 0
    $activePrCountTotal = 0; $stalePrCountTotal = 0; $highCycleTimePrCountTotal = 0
    $staleBugCountTotal = 0; $staleUserStoryCountTotal = 0; $stuckInQueueCountTotal = 0
    $workItemAgeWeightedSum = 0.0; $workItemsWithAgeDataTotal = 0
    $workItemBucketTotals = [ordered]@{}
    # Richer per-type stats (count/active/code-review/completed) for the colored
    # work-item-type cards - same shape New-WorkItemCard expects in the individual
    # report, just summed across every member instead of one person.
    $workItemTypeStatsTotals = [ordered]@{}
    foreach ($bucket in @('Epic', 'Feature', 'User Story', 'Task', 'Bug')) {
        $workItemTypeStatsTotals[$bucket] = [ordered]@{ count = 0; activeCount = 0; codeReviewCount = 0; completedCount = 0 }
    }
    # Pooled stuck-in-queue items across the whole team, each tagged with who
    # it's assigned to - the team-level equivalent of the individual report's
    # "Stuck in queue" table, just with a Person column added.
    $staleQueueItems = New-Object System.Collections.Generic.List[object]
    # Per-month team rollup - PRs raised/merged/abandoned and work items
    # assigned/completed per bucket, one row per month in the period - feeds the
    # "Team trends over the period" bar charts. Each member-month summary.json
    # is already scoped to exactly one month, so this is a straight re-key of
    # data already being read above, not a new data source.
    $monthlyStats = [ordered]@{}
    foreach ($month in $Months) {
        $monthlyStats[$month] = [ordered]@{
            prRaised = 0; prMerged = 0; prAbandoned = 0
            workItems = [ordered]@{}
        }
        foreach ($bucket in @('Epic', 'Feature', 'User Story', 'Task', 'Bug')) {
            $monthlyStats[$month].workItems[$bucket] = [ordered]@{ assigned = 0; completed = 0 }
        }
    }
    foreach ($member in $Members) {
        $safeEmail = Get-SafeName $member.email
        foreach ($month in $Months) {
            $p = Join-Path $SummaryDir "$safeEmail-$month-summary.json"
            if (-not (Test-Path $p)) { continue }
            $s = Get-Content -Raw -Path $p | ConvertFrom-Json
            $reviewedTotal += [int]$s.reviewedCount
            $reviewedApprovedTotal += [int]$s.reviewedApprovedCount
            $workItemsAssignedTotal += [int]$s.totalWorkItemsAssigned
            $workItemsCompletedTotal += [int]$s.totalWorkItemsCompleted
            $activePrCountTotal += [int]$s.activePrCount
            $stalePrCountTotal += [int]$s.stalePrCount
            $highCycleTimePrCountTotal += [int]$s.highCycleTimePrCount
            $staleBugCountTotal += [int]$s.staleBugCount
            $staleUserStoryCountTotal += [int]$s.staleUserStoryCount
            $stuckInQueueCountTotal += [int]$s.stuckInQueueCount
            if ($null -ne $s.avgWorkItemAgeDays -and [int]$s.workItemsWithAgeData -gt 0) {
                $workItemAgeWeightedSum += [double]$s.avgWorkItemAgeDays * [int]$s.workItemsWithAgeData
                $workItemsWithAgeDataTotal += [int]$s.workItemsWithAgeData
            }
            if ($s.workItemSummary) {
                foreach ($prop in $s.workItemSummary.PSObject.Properties) {
                    if (-not $workItemBucketTotals.Contains($prop.Name)) {
                        $workItemBucketTotals[$prop.Name] = [ordered]@{ assigned = 0; completed = 0 }
                    }
                    $workItemBucketTotals[$prop.Name].assigned += [int]$prop.Value.assigned
                    $workItemBucketTotals[$prop.Name].completed += [int]$prop.Value.completed
                    if ($monthlyStats.Contains($month) -and $monthlyStats[$month].workItems.Contains($prop.Name)) {
                        $monthlyStats[$month].workItems[$prop.Name].assigned += [int]$prop.Value.assigned
                        $monthlyStats[$month].workItems[$prop.Name].completed += [int]$prop.Value.completed
                    }
                }
            }
            if ($s.workItemTypeStats) {
                foreach ($prop in $s.workItemTypeStats.PSObject.Properties) {
                    if (-not $workItemTypeStatsTotals.Contains($prop.Name)) { continue }
                    $workItemTypeStatsTotals[$prop.Name].count += [int]$prop.Value.count
                    $workItemTypeStatsTotals[$prop.Name].activeCount += [int]$prop.Value.activeCount
                    $workItemTypeStatsTotals[$prop.Name].codeReviewCount += [int]$prop.Value.codeReviewCount
                    $workItemTypeStatsTotals[$prop.Name].completedCount += [int]$prop.Value.completedCount
                }
            }
            foreach ($item in @($s.staleBugItems)) {
                if ($null -eq $item) { continue }
                $staleQueueItems.Add([pscustomobject]@{
                    person = $s.person; displayName = $member.displayName; type = 'Bug'
                    id = $item.id; title = $item.title; state = $item.state; ageDays = $item.ageDays
                }) | Out-Null
            }
            foreach ($item in @($s.staleUserStoryItems)) {
                if ($null -eq $item) { continue }
                $staleQueueItems.Add([pscustomobject]@{
                    person = $s.person; displayName = $member.displayName; type = 'User Story'
                    id = $item.id; title = $item.title; state = $item.state; ageDays = $item.ageDays
                }) | Out-Null
            }
            if ($monthlyStats.Contains($month)) {
                $monthlyStats[$month].prRaised += [int]$s.totalRaised
                $monthlyStats[$month].prMerged += [int]$s.mergedToMaster
                $monthlyStats[$month].prAbandoned += [int]$s.abandonedCount
            }
        }
    }
    $staleQueueItems = @($staleQueueItems | Sort-Object -Property ageDays -Descending)

    $pct = { param($n, $d) if ($d -gt 0) { [math]::Round(100 * $n / $d, 1) } else { 0 } }

    $mergeRate       = & $pct $merged $raised
    $abandonRate     = & $pct $abandoned $raised
    $noWorkItemRate  = & $pct $noWorkIt $raised
    $descFlagRate    = & $pct $descFlag $raised
    $commentFlagRate = & $pct $flagged $raised
    $largePrRate     = & $pct $largePrs $raised
    $vagueRate       = & $pct $vague $commits

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
        avgCycleTimeDays        = if ($cycleTimes.Count -gt 0) { [math]::Round(($cycleTimes | Measure-Object -Average).Average, 1) } else { $null }
        medianCycleTimeDays     = Get-Median -Values $cycleTimes
        totalComments           = $comments
        avgCommentsPerPr        = if ($raised -gt 0) { [math]::Round($comments / $raised, 1) } else { 0 }
        noWorkItemCount         = $noWorkIt
        noWorkItemRatePercent   = $noWorkItemRate
        descriptionFlagCount    = $descFlag
        descriptionFlagRatePercent = $descFlagRate
        commentFlagCount        = $flagged
        commentFlagRatePercent  = $commentFlagRate
        totalLinesAdded         = $added
        totalLinesDeleted       = $deleted
        totalFilesChanged       = $files
        avgChurnPerPr           = if ($raised -gt 0) { [math]::Round(($added + $deleted) / $raised, 1) } else { 0 }
        largePrCount            = $largePrs
        largePrRatePercent      = $largePrRate
        totalCommits            = $commits
        vagueCommitCount        = $vague
        vagueCommitRatePercent  = $vagueRate
        reviewedCount           = $reviewedTotal
        reviewedApprovedCount   = $reviewedApprovedTotal
        totalWorkItemsAssigned  = $workItemsAssignedTotal
        totalWorkItemsCompleted = $workItemsCompletedTotal
        workItemBucketTotals    = $workItemBucketTotals
        workItemTypeStatsTotals = $workItemTypeStatsTotals
        staleQueueItems         = $staleQueueItems
        monthlyStats            = $monthlyStats
        activePrCount           = $activePrCountTotal
        stalePrCount            = $stalePrCountTotal
        highCycleTimePrCount    = $highCycleTimePrCountTotal
        staleBugCount           = $staleBugCountTotal
        staleUserStoryCount     = $staleUserStoryCountTotal
        stuckInQueueCount       = $stuckInQueueCountTotal
        avgWorkItemAgeDays      = if ($workItemsWithAgeDataTotal -gt 0) { [math]::Round($workItemAgeWeightedSum / $workItemsWithAgeDataTotal, 1) } else { $null }
        workItemsWithAgeData    = $workItemsWithAgeDataTotal
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
        cycleTimeDays     = $pr.cycleTimeDays
        threadCount       = $pr.threadCount
        commentCount      = $pr.commentCount
        filesChangedCount = $pr.filesChangedCount
        linesAdded        = $pr.linesAdded
        linesDeleted      = $pr.linesDeleted
        churn             = $pr.churn
        largePrFlag       = $pr.largePrFlag
        noWorkItemFlag    = $pr.noWorkItemFlag
        descriptionFlag   = $pr.descriptionFlag
        commitCount       = $pr.commitCount
        vagueCommitCount  = $pr.vagueCommitCount
    }
}
@($teamPrRows) | Export-Csv -Path $teamPrsCsvPath -NoTypeInformation -Encoding UTF8

$ledgerColumns = @(
    'team', 'period', 'periodStart', 'periodEnd', 'generatedAtUtc',
    'memberCount', 'contributorCount', 'totalRaised', 'mergedToMaster', 'mergeRatePercent',
    'abandonedCount', 'abandonRatePercent', 'avgCycleTimeDays', 'medianCycleTimeDays',
    'totalComments', 'avgCommentsPerPr',
    'noWorkItemRatePercent', 'descriptionFlagRatePercent', 'commentFlagCount', 'commentFlagRatePercent',
    'totalLinesAdded', 'totalLinesDeleted', 'avgChurnPerPr', 'largePrCount', 'largePrRatePercent',
    'totalCommits', 'vagueCommitCount', 'vagueCommitRatePercent',
    'reviewedCount', 'reviewedApprovedCount', 'totalWorkItemsAssigned', 'totalWorkItemsCompleted',
    'activePrCount', 'stalePrCount', 'highCycleTimePrCount',
    'staleBugCount', 'staleUserStoryCount', 'stuckInQueueCount', 'avgWorkItemAgeDays', 'workItemsWithAgeData',
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
    (New-Tile -Label "Active PR's" -Value "$($agg.activePrCount)" -Note $(if ($agg.stalePrCount -gt 0) { "$($agg.stalePrCount) stuck $StalePrDaysThreshold+ business days" } else { 'none stuck open' }) `
        -DeltaHtml (New-DeltaHtml -Current $agg.activePrCount -Previous $prev.activePrCount -PeriodLabel $cmp)),
    (New-Tile -Label 'Median cycle time' -Value (Format-Metric $agg.medianCycleTimeDays ' d') -Note (Format-Metric $agg.avgCycleTimeDays ' d average') `
        -DeltaHtml (New-DeltaHtml -Current $agg.medianCycleTimeDays -Previous $prev.medianCycleTimeDays -Suffix 'd' -PeriodLabel $cmp)),
    (New-Tile -Label "PR's with high cycle time" -Value "$($agg.highCycleTimePrCount)" -Note "> $HighCycleTimeDaysThreshold business days (open or closed)" `
        -DeltaHtml (New-DeltaHtml -Current $agg.highCycleTimePrCount -Previous $prev.highCycleTimePrCount -PeriodLabel $cmp)),
    (New-Tile -Label 'Review comments' -Value "$($agg.totalComments)" -Note "avg $($agg.avgCommentsPerPr) per PR" `
        -DeltaHtml (New-DeltaHtml -Current $agg.avgCommentsPerPr -Previous $prev.avgCommentsPerPr -Suffix '/PR' -PeriodLabel $cmp)),
    (New-Tile -Label 'PRs reviewed' -Value "$($agg.reviewedCount)" -Note "$($agg.reviewedApprovedCount) approved" `
        -DeltaHtml (New-DeltaHtml -Current $agg.reviewedCount -Previous $prev.reviewedCount -HigherIsBetter -PeriodLabel $cmp)),
    (New-Tile -Label 'Work items assigned' -Value "$($agg.totalWorkItemsAssigned)" -Note "$($agg.totalWorkItemsCompleted) completed" `
        -DeltaHtml (New-DeltaHtml -Current $agg.totalWorkItemsAssigned -Previous $prev.totalWorkItemsAssigned -PeriodLabel $cmp)),
    (New-Tile -Label 'Avg work item age' -Value (Format-Metric $agg.avgWorkItemAgeDays ' d') -Note $(if ($agg.workItemsWithAgeData -gt 0) { "assigned to close, $($agg.workItemsWithAgeData) items" } else { 'no assigned date on record' }) `
        -DeltaHtml (New-DeltaHtml -Current $agg.avgWorkItemAgeDays -Previous $prev.avgWorkItemAgeDays -Suffix 'd' -PeriodLabel $cmp)),
    (New-Tile -Label 'Stuck in queue' -Value "$($agg.stuckInQueueCount)" -Note "$($agg.staleBugCount) Bugs, $($agg.staleUserStoryCount) User Stories $StaleWorkItemDaysThreshold+ business days" `
        -DeltaHtml (New-DeltaHtml -Current $agg.stuckInQueueCount -Previous $prev.stuckInQueueCount -PeriodLabel $cmp))
) -join "`n"

# ---- "Needs attention" roll-up: team-level equivalent of the individual
# report's risk list, built entirely from the pooled counts already computed
# above - no new data, just the same signals surfaced in one place instead of
# five tables further down the page. ----
$attentionItems = New-Object System.Collections.Generic.List[string]
if ($agg.stalePrCount -gt 0) {
    $attentionItems.Add((New-AttentionItem -Severity 'critical' `
        -Html "<strong>$($agg.stalePrCount)</strong> PR$(if ($agg.stalePrCount -ne 1) {'s'}) stuck open $StalePrDaysThreshold+ business days" `
        -Sub "out of $($agg.activePrCount) currently active across the team")) | Out-Null
}
if ($agg.staleBugCount -gt 0) {
    $attentionItems.Add((New-AttentionItem -Severity 'critical' `
        -Html "<strong>$($agg.staleBugCount)</strong> Bug$(if ($agg.staleBugCount -ne 1) {'s'}) sitting untouched $StaleWorkItemDaysThreshold+ business days" `
        -Sub 'no state change recorded - see Stuck in queue below')) | Out-Null
}
if ($agg.staleUserStoryCount -gt 0) {
    $usWord = if ($agg.staleUserStoryCount -eq 1) { 'User Story' } else { 'User Stories' }
    $attentionItems.Add((New-AttentionItem -Severity 'critical' `
        -Html "<strong>$($agg.staleUserStoryCount)</strong> $usWord sitting untouched $StaleWorkItemDaysThreshold+ business days" `
        -Sub 'no state change recorded - see Stuck in queue below')) | Out-Null
}
if ($agg.abandonedCount -gt 0) {
    $attentionItems.Add((New-AttentionItem -Severity 'warning' `
        -Html "<strong>$($agg.abandonedCount)</strong> PR$(if ($agg.abandonedCount -ne 1) {'s'}) abandoned across the team this period")) | Out-Null
}
if ($agg.noWorkItemCount -gt 0) {
    $attentionItems.Add((New-AttentionItem -Severity 'warning' `
        -Html "<strong>$($agg.noWorkItemCount)</strong> out of $($agg.totalRaised) PR$(if ($agg.totalRaised -ne 1) {'s'}) raised with no linked work item")) | Out-Null
}
if ($agg.largePrCount -gt 0) {
    $attentionItems.Add((New-AttentionItem -Severity 'warning' `
        -Html "<strong>$($agg.largePrCount)</strong> out of $($agg.totalRaised) PR$(if ($agg.totalRaised -ne 1) {'s'}) flagged large / risky to review")) | Out-Null
}
if ($agg.vagueCommitCount -gt 0) {
    $attentionItems.Add((New-AttentionItem -Severity 'warning' `
        -Html "<strong>$($agg.vagueCommitCount)</strong> vague / non-descriptive commit message$(if ($agg.vagueCommitCount -ne 1) {'s'}) across the team")) | Out-Null
}
$attentionSection = if ($attentionItems.Count -eq 0) {
    '<div class="all-clear"><span class="dot"></span>No risk signals this period &mdash; PRs, bugs, and user stories are all moving across the team.</div>'
} else {
    '<ul class="attention-list">' + ($attentionItems -join "`n") + '</ul>'
}

# ---- work-item-type cards: same colored-card styling as the individual
# report, summed across the whole team for the period. ----
$wiStats = $agg.workItemTypeStatsTotals
$workItemCardsHtml = (@(
    (New-WorkItemCard -Bucket 'Epic' -Count $wiStats['Epic'].count -ActiveCount $wiStats['Epic'].activeCount -CodeReviewCount 0 -CompletedCount $wiStats['Epic'].completedCount),
    (New-WorkItemCard -Bucket 'Feature' -Count $wiStats['Feature'].count -ActiveCount $wiStats['Feature'].activeCount -CodeReviewCount 0 -CompletedCount $wiStats['Feature'].completedCount),
    (New-WorkItemCard -Bucket 'User Story' -Count $wiStats['User Story'].count -ActiveCount $wiStats['User Story'].activeCount -CodeReviewCount $wiStats['User Story'].codeReviewCount -CompletedCount $wiStats['User Story'].completedCount -ShowCodeReview),
    (New-WorkItemCard -Bucket 'Task' -Count $wiStats['Task'].count -ActiveCount $wiStats['Task'].activeCount -CodeReviewCount $wiStats['Task'].codeReviewCount -CompletedCount $wiStats['Task'].completedCount -ShowCodeReview),
    (New-WorkItemCard -Bucket 'Bug' -Count $wiStats['Bug'].count -ActiveCount $wiStats['Bug'].activeCount -CodeReviewCount $wiStats['Bug'].codeReviewCount -CompletedCount $wiStats['Bug'].completedCount -ShowCodeReview)
) -join "`n")

# ---- team-wide stuck-in-queue table: every member's stale Bug/User Story
# items pooled together with a Person column, sorted oldest-first. Items
# already come pre-sorted by age from Get-TeamAggregate. ----
$staleQueueRows = (@(foreach ($item in $agg.staleQueueItems) {
    $personLabel = if ($item.displayName) { $item.displayName } else { $item.person }
    '<tr><td>' + (ConvertTo-HtmlText $personLabel) + '</td><td>' + (New-TypeBadge $item.type) + '</td><td class="num">#' + $item.id + '</td>' +
    '<td class="title">' + (ConvertTo-HtmlText $item.title) + '</td><td>' + (ConvertTo-HtmlText $item.state) + '</td>' +
    '<td class="num">' + $item.ageDays + '</td></tr>'
}) -join "`n")
$staleQueueSection = if ($agg.staleQueueItems.Count -eq 0) {
    '<p class="empty">No Bugs or User Stories stuck in queue across the team this period.</p>'
} else {
    '<div class="scroll"><table><thead><tr><th>Person</th><th>Type</th><th>ID</th><th>Title</th><th>State</th><th>Business days untouched</th></tr></thead><tbody>' +
    $staleQueueRows + '</tbody></table></div>'
}

# ---- month-over-month trend bar charts: pure CSS bars, no chart library, so
# the report stays a single self-contained HTML file. Only meaningful once the
# period covers more than one month; for -Period month there's nothing to
# trend against, so the section is replaced with a short note instead. ----
function New-TrendBarGroup {
    param([string]$Title, [hashtable[]]$Series, [string[]]$Months)
    # $Series is an array of @{ Label; Color; Values = @(per-month numbers) }
    $allValues = @($Series | ForEach-Object { $_.Values }) | Where-Object { $null -ne $_ }
    $max = if ($allValues.Count -gt 0) { [math]::Max(1, ($allValues | Measure-Object -Maximum).Maximum) } else { 1 }
    $legend = (@($Series | ForEach-Object {
        '<span class="bar-legend-item"><span class="bar-swatch" style="background:' + $_.Color + '"></span>' + (ConvertTo-HtmlText $_.Label) + '</span>'
    }) -join '')
    $columns = (@(for ($i = 0; $i -lt $Months.Count; $i++) {
        $bars = (@($Series | ForEach-Object {
            $v = [double]$_.Values[$i]
            $pct = [math]::Round((100 * $v / $max), 1)
            '<div class="bar" style="height:' + $pct + '%; background:' + $_.Color + '" title="' + (ConvertTo-HtmlText "$($_.Label): $v") + '"><span class="bar-value">' + $v + '</span></div>'
        }) -join '')
        '<div class="bar-col"><div class="bar-group">' + $bars + '</div><span class="bar-month">' + (ConvertTo-HtmlText $Months[$i]) + '</span></div>'
    }) -join "`n")
    return '<div class="bar-chart"><h3>' + (ConvertTo-HtmlText $Title) + '</h3><div class="bar-legend">' + $legend + '</div>' +
           '<div class="bar-chart-body">' + $columns + '</div></div>'
}

$trendChartsHtml = if ($months.Count -le 1) {
    '<p class="empty">Trend charts need more than one month in the period to show a trend. Run with <code>-Period quarter</code> (or wider) to see them.</p>'
} else {
    $prSeries = @(
        @{ Label = 'Raised';    Color = 'var(--accent)'; Values = @($months | ForEach-Object { $agg.monthlyStats[$_].prRaised }) },
        @{ Label = 'Merged';    Color = 'var(--good)';   Values = @($months | ForEach-Object { $agg.monthlyStats[$_].prMerged }) },
        @{ Label = 'Abandoned'; Color = 'var(--muted)';  Values = @($months | ForEach-Object { $agg.monthlyStats[$_].prAbandoned }) }
    )
    $prChart = New-TrendBarGroup -Title 'PRs created, merged & abandoned' -Series $prSeries -Months $months

    $workItemCharts = (@(foreach ($bucket in @('User Story', 'Bug', 'Task', 'Feature', 'Epic')) {
        $assigned = @($months | ForEach-Object { $agg.monthlyStats[$_].workItems[$bucket].assigned })
        $completed = @($months | ForEach-Object { $agg.monthlyStats[$_].workItems[$bucket].completed })
        if ((($assigned | Measure-Object -Sum).Sum -eq 0) -and (($completed | Measure-Object -Sum).Sum -eq 0)) { continue }
        $series = @(
            @{ Label = 'Assigned';  Color = 'var(--accent)'; Values = $assigned },
            @{ Label = 'Completed'; Color = 'var(--good)';   Values = $completed }
        )
        New-TrendBarGroup -Title "$bucket - assigned vs completed" -Series $series -Months $months
    }) -join "`n")

    $prChart + "`n" + $workItemCharts
}

$deliveryRows = @(
    (New-MetricRow 'PRs raised' "$($agg.totalRaised)" (New-DeltaHtml -Current $agg.totalRaised -Previous $prev.totalRaised -HigherIsBetter -PeriodLabel $cmp)),
    (New-MetricRow 'Merged to master' "$($agg.mergedToMaster) ($($agg.mergeRatePercent)%)" (New-DeltaHtml -Current $agg.mergeRatePercent -Previous $prev.mergeRatePercent -HigherIsBetter -Suffix 'pp' -PeriodLabel $cmp)),
    (New-MetricRow 'Abandoned' "$($agg.abandonedCount) out of $($agg.totalRaised)" (New-DeltaHtml -Current $agg.abandonRatePercent -Previous $prev.abandonRatePercent -Suffix 'pp' -PeriodLabel $cmp)),
    (New-MetricRow 'Avg cycle time' (Format-Metric $agg.avgCycleTimeDays ' d') (New-DeltaHtml -Current $agg.avgCycleTimeDays -Previous $prev.avgCycleTimeDays -Suffix 'd' -PeriodLabel $cmp))
) -join "`n"

$reviewRows = @(
    (New-MetricRow 'Comments per PR' "$($agg.avgCommentsPerPr)" (New-DeltaHtml -Current $agg.avgCommentsPerPr -Previous $prev.avgCommentsPerPr -Suffix '/PR' -PeriodLabel $cmp)),
    (New-MetricRow 'PRs with a comment flag' "$($agg.commentFlagCount) out of $($agg.totalRaised)" (New-DeltaHtml -Current $agg.commentFlagRatePercent -Previous $prev.commentFlagRatePercent -Suffix 'pp' -PeriodLabel $cmp)),
    (New-MetricRow 'PRs reviewed by team members (for others)' "$($agg.reviewedCount)" (New-DeltaHtml -Current $agg.reviewedCount -Previous $prev.reviewedCount -HigherIsBetter -PeriodLabel $cmp)),
    (New-MetricRow 'Of those, approved' "$($agg.reviewedApprovedCount)" (New-DeltaHtml -Current $agg.reviewedApprovedCount -Previous $prev.reviewedApprovedCount -PeriodLabel $cmp))
) -join "`n"

$hygieneRows = @(
    (New-MetricRow 'Missing work item link' "$($agg.noWorkItemCount) out of $($agg.totalRaised)" (New-DeltaHtml -Current $agg.noWorkItemRatePercent -Previous $prev.noWorkItemRatePercent -Suffix 'pp' -PeriodLabel $cmp)),
    (New-MetricRow 'Incomplete / stale description' "$($agg.descriptionFlagCount) out of $($agg.totalRaised)" (New-DeltaHtml -Current $agg.descriptionFlagRatePercent -Previous $prev.descriptionFlagRatePercent -Suffix 'pp' -PeriodLabel $cmp)),
    (New-MetricRow 'Large / risky-to-review PRs' "$($agg.largePrCount) out of $($agg.totalRaised)" (New-DeltaHtml -Current $agg.largePrRatePercent -Previous $prev.largePrRatePercent -Suffix 'pp' -PeriodLabel $cmp)),
    (New-MetricRow 'Avg churn per PR' "$($agg.avgChurnPerPr)" (New-DeltaHtml -Current $agg.avgChurnPerPr -Previous $prev.avgChurnPerPr -PeriodLabel $cmp)),
    (New-MetricRow 'Vague commit messages' "$($agg.vagueCommitCount) of $($agg.totalCommits) ($($agg.vagueCommitRatePercent)%)" (New-DeltaHtml -Current $agg.vagueCommitRatePercent -Previous $prev.vagueCommitRatePercent -Suffix 'pp' -PeriodLabel $cmp)),
    (New-MetricRow "Stuck active PRs (open >= $StalePrDaysThreshold business days)" "$($agg.stalePrCount) out of $($agg.activePrCount)" (New-DeltaHtml -Current $agg.stalePrCount -Previous $prev.stalePrCount -PeriodLabel $cmp))
) -join "`n"

$workItemRows = (@(foreach ($bucket in $agg.workItemBucketTotals.Keys) {
    $assigned = $agg.workItemBucketTotals[$bucket].assigned
    if ($assigned -eq 0 -and $bucket -eq 'Other') { continue }
    $completed = $agg.workItemBucketTotals[$bucket].completed
    New-MetricRow $bucket "$completed of $assigned completed" ''
}) -join "`n")
if (-not $workItemRows) { $workItemRows = '<tr><td colspan="2" class="empty">No work-item data supplied for this period.</td></tr>' }

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
        $reviewed = (@($rows | ForEach-Object { [int]$_.reviewedCount }) | Measure-Object -Sum).Sum
        $wiAssigned = (@($rows | ForEach-Object { [int]$_.totalWorkItemsAssigned }) | Measure-Object -Sum).Sum
        $wiCompleted = (@($rows | ForEach-Object { [int]$_.totalWorkItemsCompleted }) | Measure-Object -Sum).Sum
        $largePr  = (@($rows | ForEach-Object { [int]$_.largePrCount }) | Measure-Object -Sum).Sum
        $vague    = (@($rows | ForEach-Object { [int]$_.vagueCommitCount }) | Measure-Object -Sum).Sum
        $medians  = @($rows | Where-Object { $null -ne $_.medianCycleTimeDays } | ForEach-Object { [double]$_.medianCycleTimeDays })
        $chips = ''
        if ($largePr -gt 0) { $chips += (New-Chip 'warning' "$largePr large PR") }
        if ($vague -gt 0)   { $chips += (New-Chip 'serious' "$vague vague commits") }

        '<tr><td class="person">' + (ConvertTo-HtmlText $name) + '<span class="sub">' + (ConvertTo-HtmlText $member.email) + '</span></td>' +
        '<td class="num">' + $rows.Count + '</td>' +
        '<td class="num">' + $raised + '</td>' +
        '<td class="num">' + $merged + '</td>' +
        '<td class="num">' + (Format-Metric (Get-Median -Values $medians) ' d') + '</td>' +
        '<td class="num">' + $comments + '</td>' +
        '<td class="num">' + $reviewed + '</td>' +
        '<td class="num">' + $wiCompleted + ' / ' + $wiAssigned + '</td>' +
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

  <section>
    <h2>Team performance</h2>
    <div class="tiles">
      {{TILES}}
    </div>
  </section>

  <section class="panel">
    <h2>Needs attention</h2>
    {{ATTENTION_SECTION}}
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
      <h2>Work items assigned</h2>
      <table class="metrics"><tbody>{{WORK_ITEM_ROWS}}</tbody></table>
    </div>
  </section>

  <section class="panel">
    <h2>Work items delivered</h2>
    <p class="callout callout-info">Summed across every member for the period. Epic/Feature only count as "Active" once at least one User Story exists under them.</p>
    <div class="wi-grid">
      {{WORK_ITEM_CARDS}}
    </div>
    <h3>Stuck in queue (Bug / User Story, no status change in {{STALE_WI_DAYS}}+ business days)</h3>
    {{STALE_QUEUE_SECTION}}
  </section>

  <section class="panel">
    <h2>Team trends over the period</h2>
    <p class="callout callout-info">One bar group per month covered by this period &mdash; use it to see whether delivery and hygiene are improving or degrading across the quarter, not to compare members against each other.</p>
    {{TREND_CHARTS}}
  </section>

  <section>
    <h2>Workload spread</h2>
    <p class="callout callout-info">Spread is a <strong>planning signal, not a performance one</strong>. A member with few PRs may be on large tickets, on support, mentoring, or on leave. Use this to ask where the work is concentrated and whether that is a risk if someone is away &mdash; not to compare people.</p>
    <table class="metrics"><tbody>{{DIST_ROWS}}</tbody></table>
  </section>

  <section>
    <h2>Per member</h2>
    <p class="callout callout-info">Listed <strong>alphabetically, deliberately</strong>. Sorting this table by PR count turns it into a ranking, and PR counts measure ticket sizing far more than they measure contribution. Each person's own report holds the detail and the review comments behind these numbers.</p>
    <div class="scroll">
      <table>
        <thead><tr>
          <th>Member</th><th>Months with data</th><th>PRs raised</th><th>Merged</th>
          <th>Median cycle d</th><th>Comments</th><th>PRs reviewed</th><th>Work items done/assigned</th><th>Flags</th>
        </tr></thead>
        <tbody>{{MEMBER_ROWS}}</tbody>
      </table>
    </div>
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
    Replace('{{TILES}}',         $tiles).
    Replace('{{ATTENTION_SECTION}}', $attentionSection).
    Replace('{{DELIVERY_ROWS}}', $deliveryRows).
    Replace('{{REVIEW_ROWS}}',   $reviewRows).
    Replace('{{HYGIENE_ROWS}}',  $hygieneRows).
    Replace('{{WORK_ITEM_ROWS}}', $workItemRows).
    Replace('{{WORK_ITEM_CARDS}}', $workItemCardsHtml).
    Replace('{{STALE_QUEUE_SECTION}}', $staleQueueSection).
    Replace('{{STALE_WI_DAYS}}', "$StaleWorkItemDaysThreshold").
    Replace('{{TREND_CHARTS}}', $trendChartsHtml).
    Replace('{{DIST_ROWS}}',     $distRows).
    Replace('{{MEMBER_ROWS}}',   $memberTableRows).
    Replace('{{GAPS}}',          $gapSection)

$htmlPath = Join-Path $OutputDir "$safeTeam-$periodSlug-team.html"
$html | Set-Content -Path $htmlPath -Encoding UTF8

Write-Host ""
Write-Host "Team report:  $htmlPath"
Write-Host "Members CSV:  $membersCsvPath"
Write-Host "Team PRs CSV: $teamPrsCsvPath"
Write-Host "Team ledger:  $teamLedgerPath"
Write-Host ("PRs raised: {0}, Merged: {1} ({2}%), Reviewed: {3}, Work items: {4} ({5} completed), Coverage gaps: {6}" -f `
    $agg.totalRaised, $agg.mergedToMaster, $agg.mergeRatePercent, $agg.reviewedCount, $agg.totalWorkItemsAssigned, $agg.totalWorkItemsCompleted, $agg.gaps.Count)
