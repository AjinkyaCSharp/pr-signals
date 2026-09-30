<#
.SYNOPSIS
    Computes monthly PR-based KPIs and candidate "silly mistake" comment flags for
    one teammate, from pre-fetched Azure DevOps PR/thread data.

.DESCRIPTION
    This script does NOT call Azure DevOps itself (no PAT / auth is configured here).
    It expects a JSON file already assembled by the agent (see RUNBOOK.md) using the
    azure-devops-* MCP tools available in the Copilot CLI session.

    Expected input JSON schema:
    {
      "person": "jane.doe@company.com",
      "monthYear": "2025-07",
      "targetMasterBranch": "refs/heads/master",   // optional, defaults to refs/heads/master
      "pullRequests": [
        {
          "pullRequestId": 123,
          "title": "Fix null ref in order export",
          "url": "https://dev.azure.com/.../pullrequest/123",
          "status": "completed",                   // active | completed | abandoned
          "targetRefName": "refs/heads/master",
          "creationDate": "2025-07-05T10:11:12Z",
          "closedDate": "2025-07-06T09:00:00Z",
          "description": "Fixes the null ref ...",
          "workItemRefs": [ { "id": 456, "url": "..." } ],
          "threads": [
            {
              "threadId": 1,
              "status": "active",
              "comments": [
                {
                  "id": 1,
                  "author": "John Reviewer",
                  "content": "Please add a null check here",
                  "publishedDate": "2025-07-05T12:00:00Z"   // optional, needed for rework-commit detection
                }
              ]
            }
          ],
          // --- optional fields enabling size/churn and commit-hygiene metrics ---
          "filesChangedCount": 3,          // from azure-devops-repo_pull_request action=get_changes
          "linesAdded": 45,                // sum of added lines across get_changes files
          "linesDeleted": 12,              // sum of deleted lines across get_changes files
          "reviewers": [                   // from the "reviewers" array on the raw PR object (action=get)
            { "displayName": "John Reviewer", "uniqueName": "john.reviewer@company.com", "vote": 10 }
            // vote: 10=Approved, 5=Approved with suggestions, 0=No vote, -5=Waiting for author, -10=Rejected
          ],
          "commits": [                     // from azure-devops-repo_search_commits scoped to the PR's
                                            // sourceRefName + author + [creationDate, closedDate] window
            {
              "commitId": "abc1234",
              "author": "Jane Doe",
              "date": "2025-07-05T09:00:00Z",
              "comment": "Add null check for missing shipping address"
            }
          ]
        }
      ],
      // --- optional: PRs authored by OTHERS where this person acted as a reviewer ---
      "reviewedPullRequests": [
        {
          "pullRequestId": 789,
          "title": "Add retry to payment webhook",
          "url": "https://dev.azure.com/.../pullrequest/789",
          "author": "John Author",
          "vote": 10,          // 10=Approved, 5=Approved with suggestions, 0=No vote, -5=Waiting, -10=Rejected
          "filesChangedCount": 4,   // optional, shows in "Files" column; omit if unavailable
          "linesAdded": 60,         // optional, shows in "Lines" column with linesDeleted
          "linesDeleted": 10        // optional
        }
      ],
      // --- optional: work items (of any type) assigned to this person during the month ---
      "workItems": [
        {
          "id": 456,
          "type": "Bug",       // Bug | User Story | Task | Epic | Feature | (anything else -> "Other")
          "state": "Closed",   // any ADO state string; Closed/Done/Resolved/Completed count as completed,
                               // Code Review/In Review/Ready for Review count as "in code review",
                               // Removed/Cancelled are excluded from every count entirely
          "title": "Null ref in order export",
          // --- optional fields enabling Epic/Feature activity gating and stale-in-queue detection ---
          "changedDate": "2025-07-20T09:00:00Z",   // last time state/fields changed; needed to flag Bugs/
                                                     // User Stories sitting untouched (see StaleWorkItemDaysThreshold)
          "assignedDate": "2025-07-10T09:00:00Z",   // when the item was assigned to this person; needed for
                                                     // the "avg work item age" metric (assigned -> closed).
                                                     // Omit if unknown - that item is simply excluded from the average.
          "childUserStoryCount": 3                  // Epic/Feature only: count of User Stories under this item
                                                     // (Epic: rolled up across its Features; Feature: direct
                                                     // children). An Epic/Feature with 0 (or omitted) is never
                                                     // counted as active, regardless of its ADO state.
        }
      ]
    }

.PARAMETER InputJsonPath
    Path to the raw JSON document described above.

.PARAMETER OutputDir
    Directory where the summary JSON and Markdown report will be written.

.PARAMETER DescriptionMinLength
    Minimum non-whitespace character count for a PR description to NOT be flagged
    as "incomplete / stale". Default 20.

.PARAMETER LargeChurnThreshold
    Total lines changed (added + deleted) above which a PR is flagged "large / risky
    to review". Default 400.

.PARAMETER LargeFileCountThreshold
    Number of files changed above which a PR is flagged "large / risky to review".
    Default 15.

.PARAMETER VagueCommitMinLength
    Commit messages (first line) with fewer non-whitespace characters than this are
    flagged as vague, in addition to the known-phrase pattern list. Default 10.

.PARAMETER StalePrDaysThreshold
    Business days (Mon-Fri) a still-active (not closed) PR can sit open before it
    is flagged as "stuck" - both in the per-PR table chip and the PR hygiene count.
    Default 5.

.PARAMETER HighCycleTimeDaysThreshold
    Business days (Mon-Fri) above which a PR's cycle time (closed) or age (still
    active) counts toward the "PRs with high cycle time" headline tile. Default 10.

.PARAMETER StaleWorkItemDaysThreshold
    Business days (Mon-Fri) a Bug or User Story assigned to the person can sit
    with no state change before it's flagged as "stuck in queue". Requires the
    optional "changedDate" field on each work item. Default 5.

.PARAMETER TalkingPointsPath
    Optional path to a plain-text/Markdown file holding the confirmed talking points
    written by the agent during the manual review pass (RUNBOOK.md Step 4). When
    supplied, its contents are embedded in the HTML report's "Confirmed talking
    points" section. Re-run the script after writing the file to fold it in.

.OUTPUTS
    Three files per run, all using a fixed template so every report is identical
    in shape:
      <person>-<month>.html          presentation report (open in a browser / project it)
      <person>-<month>-prs.csv       one row per PR, fixed columns
      <person>-<month>-summary.json  machine-readable metrics (also drives the trend column)
    Plus one shared, accumulating file:
      kpi-ledger.csv                 one row per person-month, re-runs update in place

.EXAMPLE
    .\Get-TeamKpiReport.ps1 -InputJsonPath .\kpi-raw\jane.doe-2025-07.json -OutputDir .\kpi-reports
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputJsonPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputDir,

    [int]$DescriptionMinLength = 20,

    [int]$LargeChurnThreshold = 400,

    [int]$LargeFileCountThreshold = 15,

    [int]$VagueCommitMinLength = 10,

    [int]$StalePrDaysThreshold = 5,

    [int]$HighCycleTimeDaysThreshold = 10,

    [int]$StaleWorkItemDaysThreshold = 5,

    [string]$TalkingPointsPath
)

$ErrorActionPreference = 'Stop'

# Force invariant formatting so numbers render as "66.7" in every locale - a
# decimal comma would corrupt the CSV columns and the HTML figures alike.
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture

# Shared HTML helpers + the one stylesheet every report renders with.
. (Join-Path $PSScriptRoot 'KpiReportCommon.ps1')

if (-not (Test-Path $InputJsonPath)) {
    throw "Input JSON not found: $InputJsonPath"
}
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
}

$data = Get-Content -Raw -Path $InputJsonPath | ConvertFrom-Json

$person = $data.person
$monthYear = $data.monthYear
$targetMasterBranch = if ($data.targetMasterBranch) { $data.targetMasterBranch } else { 'refs/heads/master' }
$pullRequests = @($data.pullRequests)
$reviewedPullRequests = @($data.reviewedPullRequests)
$workItems = @($data.workItems)

# ---- Keyword sets for candidate comment flagging (heuristics only, not final judgment) ----
$keywordCategories = [ordered]@{
    'Naming convention'        = @('naming convention', 'rename this', 'variable name', 'method name', 'misnamed', 'poor naming', 'better name', 'naming standard')
    'Null check'               = @('null check', 'null reference', 'nullreferenceexception', 'npe', 'could be null', 'null-check', 'nullpointer', 'ispresent', 'isblank', 'add a null')
    'Misleading description'   = @('description is misleading', "doesn't match description", 'does not match the description', 'description does not reflect', 'pr description is wrong', 'description out of date')
    'Stale/incomplete comment' = @('todo', 'fixme', 'placeholder', 'lorem ipsum', 'fill in description', 'wip')
}

function Test-DescriptionFlag {
    param([string]$Description, [int]$MinLength)
    if ([string]::IsNullOrWhiteSpace($Description)) { return $true }
    $trimmed = $Description.Trim()
    if ($trimmed.Length -lt $MinLength) { return $true }
    $lower = $trimmed.ToLowerInvariant()
    foreach ($stub in @('todo', 'fill in description', 'lorem ipsum', 'placeholder', 'wip', 'tbd')) {
        if ($lower -eq $stub -or $lower.StartsWith($stub)) { return $true }
    }
    return $false
}

# ---- Vague / non-descriptive commit-message detection (heuristics only) ----
# Matched against the trimmed first line ("subject") of the commit message, case-insensitive,
# using full-line regex anchors so e.g. "fixed pr comments" matches but
# "fixed pr comments about null handling in order export" does not (that's descriptive).
$vagueCommitPatterns = @(
    '^wip$',
    '^fix(ed|es|ing)?$',
    '^bug\s?fix(es)?$',
    '^fix(ed|es|ing)?\s+(the\s+)?(unit\s+)?tests?$',
    '^fix(ed|es|ing)?\s+(pr\s+|review\s+)?comments?$',
    '^address(ed|ing)?\s+(pr\s+|review\s+)?comments?$',
    '^(code\s+)?review\s+(comments?|feedback)$',
    '^update(d|s|ing)?$',
    '^change(d|s)?$',
    '^minor\s+(fix(es)?|change(s)?|update(s)?)$',
    '^misc(ellaneous)?(\s+fixes?)?$',
    '^clean\s?up$',
    '^small\s+fix(es)?$',
    '^test(s|ing)?$',
    '^merge$',
    '^temp(orary)?$',
    '^done$',
    '^\.+$',
    '^asdf+$'
)

function Test-VagueCommitMessage {
    param([string]$Message, [int]$MinLength)
    if ([string]::IsNullOrWhiteSpace($Message)) { return $true }
    # Use only the first line (subject) - body detail doesn't rescue a vague subject line.
    $subject = ($Message -split "`n")[0].Trim()
    if ($subject.Length -lt $MinLength) { return $true }
    $lower = $subject.ToLowerInvariant()
    foreach ($pattern in $vagueCommitPatterns) {
        if ($lower -match $pattern) { return $true }
    }
    return $false
}

$prResults = New-Object System.Collections.Generic.List[object]
$totalRaised = 0
$mergedToMaster = 0
$abandonedCount = 0
$cycleTimeDaysList = New-Object System.Collections.Generic.List[double]
$reviewerSet = New-Object System.Collections.Generic.HashSet[string]
$totalComments = 0
$categoryTotals = [ordered]@{}
foreach ($cat in $keywordCategories.Keys) { $categoryTotals[$cat] = 0 }
$totalLinesAdded = 0
$totalLinesDeleted = 0
$largePrCount = 0
$activePrCount = 0
$stalePrCount = 0
$highCycleTimePrCount = 0
$totalCommits = 0
$vagueCommitCount = 0
$reworkCommitTotal = 0
$prsWithReworkData = 0
$vagueCommitHits = New-Object System.Collections.Generic.List[object]

foreach ($pr in $pullRequests) {
    $totalRaised++

    $isMergedToMaster = ($pr.status -ieq 'completed') -and
                         ($pr.targetRefName -ieq $targetMasterBranch)
    if ($isMergedToMaster) { $mergedToMaster++ }
    if ($pr.status -ieq 'abandoned') { $abandonedCount++ }

    # Cycle time: creation -> closed, in business days (Mon-Fri only; weekend time
    # is excluded rather than counted, so a PR idle over a weekend isn't scored
    # as if it moved faster). Any closed PR, not just merged-to-master.
    $cycleTimeDays = $null
    if ($pr.creationDate -and $pr.closedDate) {
        try {
            $created = [datetime]$pr.creationDate
            $closed = [datetime]$pr.closedDate
            $cycleTimeDays = [math]::Round((Get-BusinessDaysBetween -Start $created -End $closed), 1)
            if ($isMergedToMaster) { $cycleTimeDaysList.Add($cycleTimeDays) }
        } catch { $cycleTimeDays = $null }
    }

    # Age of still-open PRs: creation -> now, in business days. This is the number
    # a reviewer actually needs in a 1-1 - "it's been sitting for N days, why?" -
    # cycle time only exists once a PR closes, so an open PR needs its own clock.
    $isActive = ($pr.status -ieq 'active')
    $ageDays = $null
    $stalePrFlag = $false
    if ($isActive -and $pr.creationDate) {
        try {
            $created = [datetime]$pr.creationDate
            $ageDays = [math]::Round((Get-BusinessDaysBetween -Start $created -End (Get-Date)), 1)
            $stalePrFlag = ($ageDays -ge $StalePrDaysThreshold)
        } catch { $ageDays = $null }
    }
    if ($isActive) { $activePrCount++ }
    if ($stalePrFlag) { $stalePrCount++ }

    # High cycle time: use cycle time once closed, or current age while still
    # open - either way, this is "has this PR been slow", not just "is it stuck
    # right now" (stalePrFlag/StalePrDaysThreshold is about active PRs only).
    $effectiveDurationDays = if ($null -ne $cycleTimeDays) { $cycleTimeDays } else { $ageDays }
    $highCycleTimeFlag = ($null -ne $effectiveDurationDays) -and ($effectiveDurationDays -gt $HighCycleTimeDaysThreshold)
    if ($highCycleTimeFlag) { $highCycleTimePrCount++ }

    $descriptionFlag = Test-DescriptionFlag -Description $pr.description -MinLength $DescriptionMinLength
    $workItemCount = if ($pr.workItemRefs) { @($pr.workItemRefs).Count } else { 0 }
    $noWorkItemFlag = ($workItemCount -eq 0)

    $commentHits = New-Object System.Collections.Generic.List[object]
    $prCommentCount = 0
    $prThreads = @()
    if ($pr.threads) { $prThreads = @($pr.threads) }
    $prThreadCount = $prThreads.Count
    $firstCommentDate = $null
    foreach ($thread in $prThreads) {
        foreach ($comment in @($thread.comments)) {
            $content = [string]$comment.content
            if ([string]::IsNullOrWhiteSpace($content)) { continue }
            $prCommentCount++
            $totalComments++
            if ($comment.author -and $comment.author -ne $person) { [void]$reviewerSet.Add($comment.author) }
            if ($comment.publishedDate) {
                try {
                    $commentDate = [datetime]$comment.publishedDate
                    if (-not $firstCommentDate -or $commentDate -lt $firstCommentDate) { $firstCommentDate = $commentDate }
                } catch { }
            }
            $lowerContent = $content.ToLowerInvariant()
            foreach ($category in $keywordCategories.Keys) {
                foreach ($kw in $keywordCategories[$category]) {
                    if ($lowerContent.Contains($kw)) {
                        $commentHits.Add([pscustomobject]@{
                            threadId = $thread.threadId
                            commentId = $comment.id
                            author = $comment.author
                            category = $category
                            matchedKeyword = $kw
                            snippet = if ($content.Length -gt 200) { $content.Substring(0, 200) + '...' } else { $content }
                        }) | Out-Null
                        $categoryTotals[$category]++
                        break
                    }
                }
            }
        }
    }

    # ---- PR size / churn ----
    $filesChangedCount = if ($null -ne $pr.filesChangedCount) { [int]$pr.filesChangedCount } else { 0 }
    $linesAdded = if ($null -ne $pr.linesAdded) { [int]$pr.linesAdded } else { 0 }
    $linesDeleted = if ($null -ne $pr.linesDeleted) { [int]$pr.linesDeleted } else { 0 }
    $churn = $linesAdded + $linesDeleted
    $largePrFlag = ($churn -ge $LargeChurnThreshold) -or ($filesChangedCount -ge $LargeFileCountThreshold)
    $totalLinesAdded += $linesAdded
    $totalLinesDeleted += $linesDeleted
    if ($largePrFlag) { $largePrCount++ }

    # ---- Reviewers (approvals shown in the per-PR table; no self/no-approval flags) ----
    $reviewers = @()
    if ($pr.reviewers) { $reviewers = @($pr.reviewers) }
    $reviewersCount = $reviewers.Count
    $approvedCount = @($reviewers | Where-Object { $_.vote -ge 5 }).Count

    # ---- Commits: vague-message detection + rework-after-first-comment count ----
    $commits = @()
    if ($pr.commits) { $commits = @($pr.commits) }
    $prCommitCount = $commits.Count
    $totalCommits += $prCommitCount
    $prVagueCommits = New-Object System.Collections.Generic.List[object]
    $prReworkCommitCount = $null
    if ($firstCommentDate -and $prCommitCount -gt 0) {
        $prReworkCommitCount = 0
    }
    foreach ($commit in $commits) {
        $msg = [string]$commit.comment
        if (Test-VagueCommitMessage -Message $msg -MinLength $VagueCommitMinLength) {
            $vagueCommitCount++
            $hit = [pscustomobject]@{
                pullRequestId = $pr.pullRequestId
                title         = $pr.title
                commitId      = $commit.commitId
                author        = $commit.author
                message       = $msg
            }
            $prVagueCommits.Add($hit) | Out-Null
            $vagueCommitHits.Add($hit) | Out-Null
        }
        if ($firstCommentDate -and $commit.date) {
            try {
                $commitDate = [datetime]$commit.date
                if ($commitDate -gt $firstCommentDate) {
                    $prReworkCommitCount++
                    $reworkCommitTotal++
                }
            } catch { }
        }
    }
    if ($firstCommentDate -and $prCommitCount -gt 0) { $prsWithReworkData++ }

    $prResults.Add([pscustomobject]@{
        pullRequestId       = $pr.pullRequestId
        title               = $pr.title
        url                 = $pr.url
        status              = $pr.status
        targetRefName       = $pr.targetRefName
        creationDate        = $pr.creationDate
        closedDate          = $pr.closedDate
        cycleTimeDays       = $cycleTimeDays
        isActive            = $isActive
        ageDays             = $ageDays
        stalePrFlag         = $stalePrFlag
        highCycleTimeFlag   = $highCycleTimeFlag
        mergedToMaster      = $isMergedToMaster
        descriptionFlag     = $descriptionFlag
        noWorkItemFlag      = $noWorkItemFlag
        workItemCount       = $workItemCount
        threadCount         = $prThreadCount
        commentCount        = $prCommentCount
        commentFlagCount    = $commentHits.Count
        commentFlags        = $commentHits
        filesChangedCount   = $filesChangedCount
        linesAdded          = $linesAdded
        linesDeleted        = $linesDeleted
        churn               = $churn
        largePrFlag         = $largePrFlag
        reviewersCount      = $reviewersCount
        approvedCount       = $approvedCount
        commitCount         = $prCommitCount
        vagueCommitCount    = $prVagueCommits.Count
        vagueCommits        = $prVagueCommits
        reworkCommitCount   = $prReworkCommitCount
    }) | Out-Null
}

# ---- Aggregate quantitative metrics ----
$avgCycleTimeDays = if ($cycleTimeDaysList.Count -gt 0) { [math]::Round(($cycleTimeDaysList | Measure-Object -Average).Average, 1) } else { $null }
$medianCycleTimeDays = Get-Median -Values @($cycleTimeDaysList)
$abandonRatePercent = if ($totalRaised -gt 0) { [math]::Round(100 * $abandonedCount / $totalRaised, 1) } else { 0 }
$avgCommentsPerPr = if ($totalRaised -gt 0) { [math]::Round($totalComments / $totalRaised, 1) } else { 0 }
$noWorkItemCount = @($prResults | Where-Object { $_.noWorkItemFlag }).Count
$descriptionFlagCount = @($prResults | Where-Object { $_.descriptionFlag }).Count
$anyCommentFlagCount = @($prResults | Where-Object { $_.commentFlagCount -gt 0 }).Count
$noWorkItemRatePercent = if ($totalRaised -gt 0) { [math]::Round(100 * $noWorkItemCount / $totalRaised, 1) } else { 0 }
$descriptionFlagRatePercent = if ($totalRaised -gt 0) { [math]::Round(100 * $descriptionFlagCount / $totalRaised, 1) } else { 0 }
$commentFlagRatePercent = if ($totalRaised -gt 0) { [math]::Round(100 * $anyCommentFlagCount / $totalRaised, 1) } else { 0 }
$reviewerDiversityCount = $reviewerSet.Count

# ---- PR size/churn and commit-hygiene aggregates ----
$largePrRatePercent = if ($totalRaised -gt 0) { [math]::Round(100 * $largePrCount / $totalRaised, 1) } else { 0 }
$vagueCommitRatePercent = if ($totalCommits -gt 0) { [math]::Round(100 * $vagueCommitCount / $totalCommits, 1) } else { 0 }
$avgReworkCommitsPerPr = if ($prsWithReworkData -gt 0) {
    [math]::Round((@($prResults | Where-Object { $null -ne $_.reworkCommitCount } | ForEach-Object { $_.reworkCommitCount }) | Measure-Object -Sum).Sum / $prsWithReworkData, 1)
} else { $null }

# ---- PRs reviewed by this person (authored by someone else) ----
$reviewedCount = $reviewedPullRequests.Count
$reviewedApprovedCount = @($reviewedPullRequests | Where-Object { $_.vote -ge 5 }).Count

# ---- Work items assigned to this person, by type, with completed count ----
$workItemSummary = Get-WorkItemSummary -WorkItems $workItems
$totalWorkItemsAssigned = (@($workItemSummary.Values | ForEach-Object { $_.assigned }) | Measure-Object -Sum).Sum
$totalWorkItemsCompleted = (@($workItemSummary.Values | ForEach-Object { $_.completed }) | Measure-Object -Sum).Sum

# ---- Richer per-type breakdown (count / active / code review / completed), plus
# Bugs and User Stories sitting untouched in the queue for too long. JSON-only for
# now - not yet wired into the HTML report pending the SM's redesign of that section. ----
$workItemTypeStats = Get-WorkItemTypeStats -WorkItems $workItems
$staleBugItems = @(Get-StaleWorkItems -WorkItems $workItems -Bucket 'Bug' -ThresholdDays $StaleWorkItemDaysThreshold)
$staleUserStoryItems = @(Get-StaleWorkItems -WorkItems $workItems -Bucket 'User Story' -ThresholdDays $StaleWorkItemDaysThreshold)
$staleBugCount = $staleBugItems.Count
$staleUserStoryCount = $staleUserStoryItems.Count
$stuckInQueueCount = $staleBugCount + $staleUserStoryCount

# ---- Avg work item age: assignedDate -> changedDate (closed), business days.
# Only counts items that are actually completed and have both dates supplied -
# an item missing "assignedDate" is excluded rather than guessed at. ----
$workItemAgeDaysList = New-Object System.Collections.Generic.List[double]
foreach ($wi in $workItems) {
    if (-not (Test-WorkItemDone -State $wi.state)) { continue }
    if (-not $wi.assignedDate -or -not $wi.changedDate) { continue }
    try {
        $assigned = [datetime]$wi.assignedDate
        $closedOn = [datetime]$wi.changedDate
        $workItemAgeDaysList.Add((Get-BusinessDaysBetween -Start $assigned -End $closedOn)) | Out-Null
    } catch { }
}
$avgWorkItemAgeDays = if ($workItemAgeDaysList.Count -gt 0) {
    [math]::Round(($workItemAgeDaysList | Measure-Object -Average).Average, 1)
} else { $null }
$workItemsWithAgeData = $workItemAgeDaysList.Count

$summary = [pscustomobject]@{
    person                       = $person
    monthYear                    = $monthYear
    totalRaised                  = $totalRaised
    mergedToMaster               = $mergedToMaster
    mergeRatePercent             = if ($totalRaised -gt 0) { [math]::Round(100 * $mergedToMaster / $totalRaised, 1) } else { 0 }
    abandonedCount               = $abandonedCount
    abandonRatePercent           = $abandonRatePercent
    avgCycleTimeDays             = $avgCycleTimeDays
    medianCycleTimeDays          = $medianCycleTimeDays
    totalComments                = $totalComments
    avgCommentsPerPr             = $avgCommentsPerPr
    reviewerDiversityCount       = $reviewerDiversityCount
    noWorkItemCount              = $noWorkItemCount
    noWorkItemRatePercent        = $noWorkItemRatePercent
    descriptionFlagCount         = $descriptionFlagCount
    descriptionFlagRatePercent   = $descriptionFlagRatePercent
    commentFlagRatePercent       = $commentFlagRatePercent
    commentFlagCategoryTotals    = $categoryTotals
    totalLinesAdded              = $totalLinesAdded
    totalLinesDeleted            = $totalLinesDeleted
    largePrCount                 = $largePrCount
    largePrRatePercent           = $largePrRatePercent
    activePrCount                = $activePrCount
    stalePrCount                 = $stalePrCount
    highCycleTimePrCount         = $highCycleTimePrCount
    totalCommits                 = $totalCommits
    vagueCommitCount             = $vagueCommitCount
    vagueCommitRatePercent       = $vagueCommitRatePercent
    avgReworkCommitsPerPr        = $avgReworkCommitsPerPr
    reviewedCount                 = $reviewedCount
    reviewedApprovedCount         = $reviewedApprovedCount
    totalWorkItemsAssigned        = $totalWorkItemsAssigned
    totalWorkItemsCompleted       = $totalWorkItemsCompleted
    workItemSummary               = $workItemSummary
    workItemTypeStats             = $workItemTypeStats
    staleBugCount                 = $staleBugCount
    staleUserStoryCount           = $staleUserStoryCount
    stuckInQueueCount             = $stuckInQueueCount
    staleBugItems                 = $staleBugItems
    staleUserStoryItems           = $staleUserStoryItems
    avgWorkItemAgeDays            = $avgWorkItemAgeDays
    workItemsWithAgeData          = $workItemsWithAgeData
    pullRequests                 = $prResults
    reviewedPullRequests          = $reviewedPullRequests
    generatedAtUtc               = (Get-Date).ToUniversalTime().ToString('o')
}

$safePerson = ($person -replace '[^a-zA-Z0-9\.\-_@]', '_')
$summaryPath = Join-Path $OutputDir "$safePerson-$monthYear-summary.json"
$htmlPath    = Join-Path $OutputDir "$safePerson-$monthYear.html"
$prsCsvPath  = Join-Path $OutputDir "$safePerson-$monthYear-prs.csv"
$ledgerPath  = Join-Path $OutputDir 'kpi-ledger.csv'

# ---- Month-over-month trend: look for the immediately preceding month's summary for this person ----
$previousSummary = $null
$monthLabel = $monthYear
$periodRangeLabel = $monthYear
try {
    $ym = [datetime]::ParseExact($monthYear, 'yyyy-MM', $null)
    $monthLabel = $ym.ToString('MMMM yyyy', [System.Globalization.CultureInfo]::InvariantCulture)
    $periodStart = $ym
    $periodEnd = $ym.AddMonths(1).AddDays(-1)
    $periodRangeLabel = "$($periodStart.ToString('d MMM')) - $($periodEnd.ToString('d MMM yyyy'))"
    $prevYm = $ym.AddMonths(-1).ToString('yyyy-MM')
    $prevPath = Join-Path $OutputDir "$safePerson-$prevYm-summary.json"
    if (Test-Path $prevPath) {
        $previousSummary = Get-Content -Raw -Path $prevPath | ConvertFrom-Json
    }
} catch { $previousSummary = $null }

$summary | ConvertTo-Json -Depth 10 | Set-Content -Path $summaryPath -Encoding UTF8

# ===========================================================================
#  CSV OUTPUT 1 - per-PR detail. Fixed column template; one row per PR.
# ===========================================================================
$prCsvRows = foreach ($pr in $prResults) {
    [pscustomobject][ordered]@{
        person             = $person
        monthYear          = $monthYear
        pullRequestId      = $pr.pullRequestId
        title              = $pr.title
        url                = $pr.url
        status             = $pr.status
        targetRefName      = $pr.targetRefName
        creationDate       = $pr.creationDate
        closedDate         = $pr.closedDate
        mergedToMaster     = $pr.mergedToMaster
        cycleTimeDays      = $pr.cycleTimeDays
        isActive           = $pr.isActive
        ageDays            = $pr.ageDays
        stalePrFlag        = $pr.stalePrFlag
        workItemCount      = $pr.workItemCount
        noWorkItemFlag     = $pr.noWorkItemFlag
        descriptionFlag    = $pr.descriptionFlag
        threadCount        = $pr.threadCount
        commentCount       = $pr.commentCount
        commentFlagCount   = $pr.commentFlagCount
        filesChangedCount  = $pr.filesChangedCount
        linesAdded         = $pr.linesAdded
        linesDeleted       = $pr.linesDeleted
        churn              = $pr.churn
        largePrFlag        = $pr.largePrFlag
        reviewersCount     = $pr.reviewersCount
        approvedCount      = $pr.approvedCount
        commitCount        = $pr.commitCount
        vagueCommitCount   = $pr.vagueCommitCount
        reworkCommitCount  = $pr.reworkCommitCount
    }
}
@($prCsvRows) | Export-Csv -Path $prsCsvPath -NoTypeInformation -Encoding UTF8

# ===========================================================================
#  CSV OUTPUT 2 - rolling ledger, one row per person-month, for record keeping.
#  Re-running a month replaces that month's row rather than duplicating it.
# ===========================================================================
$ledgerColumns = @(
    'person', 'monthYear', 'generatedAtUtc',
    'totalRaised', 'mergedToMaster', 'mergeRatePercent', 'abandonedCount', 'abandonRatePercent',
    'avgCycleTimeDays', 'medianCycleTimeDays',
    'totalComments', 'avgCommentsPerPr', 'reviewerDiversityCount',
    'noWorkItemCount', 'noWorkItemRatePercent',
    'descriptionFlagCount', 'descriptionFlagRatePercent', 'commentFlagRatePercent',
    'totalLinesAdded', 'totalLinesDeleted',
    'largePrCount', 'largePrRatePercent',
    'activePrCount', 'stalePrCount', 'highCycleTimePrCount',
    'totalCommits', 'vagueCommitCount', 'vagueCommitRatePercent', 'avgReworkCommitsPerPr',
    'reviewedCount', 'reviewedApprovedCount',
    'totalWorkItemsAssigned', 'totalWorkItemsCompleted',
    'staleBugCount', 'staleUserStoryCount', 'stuckInQueueCount',
    'avgWorkItemAgeDays', 'workItemsWithAgeData'
)
$ledgerRow = [pscustomobject][ordered]@{}
foreach ($col in $ledgerColumns) {
    Add-Member -InputObject $ledgerRow -MemberType NoteProperty -Name $col -Value $summary.$col
}

$ledgerRows = New-Object System.Collections.Generic.List[object]
if (Test-Path $ledgerPath) {
    foreach ($existing in @(Import-Csv -Path $ledgerPath)) {
        # Drop any prior row for this same person+month so a re-run updates in place.
        if ($existing.person -eq $person -and $existing.monthYear -eq $monthYear) { continue }
        $ledgerRows.Add($existing) | Out-Null
    }
}
$ledgerRows.Add($ledgerRow) | Out-Null
$ledgerRows |
    Select-Object $ledgerColumns |
    Sort-Object person, monthYear |
    Export-Csv -Path $ledgerPath -NoTypeInformation -Encoding UTF8

# ===========================================================================
#  HTML OUTPUT - the presentation report. One fixed template, tokens replaced,
#  so every report for every person and month has the same shape.
# ===========================================================================

# ---- headline tiles: the numbers a 1-1 opens with ----
$tiles = @(
    (New-Tile -Label 'PRs raised' -Value "$totalRaised" `
        -DeltaHtml (New-DeltaHtml -Current $totalRaised -Previous $previousSummary.totalRaised -HigherIsBetter)),
    (New-Tile -Label 'Merged to master' -Value "$mergedToMaster" -Note "$($summary.mergeRatePercent)% of PRs raised" `
        -DeltaHtml (New-DeltaHtml -Current $summary.mergeRatePercent -Previous $previousSummary.mergeRatePercent -HigherIsBetter -Suffix 'pp')),
    (New-Tile -Label "Active PR's" -Value "$activePrCount" -Note $(if ($stalePrCount -gt 0) { "$stalePrCount stuck $StalePrDaysThreshold+ business days" } else { 'none stuck open' }) `
        -DeltaHtml (New-DeltaHtml -Current $activePrCount -Previous $previousSummary.activePrCount)),
    (New-Tile -Label 'Median cycle time' -Value (Format-Metric $medianCycleTimeDays ' d') -Note (Format-Metric $avgCycleTimeDays ' d average' 'n/a') `
        -DeltaHtml (New-DeltaHtml -Current $avgCycleTimeDays -Previous $previousSummary.avgCycleTimeDays -Suffix 'd')),
    (New-Tile -Label "PR's with high cycle time" -Value "$highCycleTimePrCount" -Note "> $HighCycleTimeDaysThreshold business days (open or closed)" `
        -DeltaHtml (New-DeltaHtml -Current $highCycleTimePrCount -Previous $previousSummary.highCycleTimePrCount)),
    (New-Tile -Label 'Review comments' -Value "$totalComments" -Note "avg $avgCommentsPerPr per PR" `
        -DeltaHtml (New-DeltaHtml -Current $avgCommentsPerPr -Previous $previousSummary.avgCommentsPerPr -Suffix '/PR')),
    (New-Tile -Label "Reviewed PR's" -Value "$reviewedCount" -Note "$reviewedApprovedCount approved" `
        -DeltaHtml (New-DeltaHtml -Current $reviewedCount -Previous $previousSummary.reviewedCount -HigherIsBetter)),
    (New-Tile -Label 'Work items completed' -Value "$totalWorkItemsCompleted" -Note "of $totalWorkItemsAssigned assigned" `
        -DeltaHtml (New-DeltaHtml -Current $totalWorkItemsCompleted -Previous $previousSummary.totalWorkItemsCompleted -HigherIsBetter)),
    (New-Tile -Label 'Avg work item age' -Value (Format-Metric $avgWorkItemAgeDays ' d') -Note $(if ($workItemsWithAgeData -gt 0) { "assigned to close, $workItemsWithAgeData item$(if ($workItemsWithAgeData -ne 1) {'s'})" } else { 'no assigned date on record' }) `
        -DeltaHtml (New-DeltaHtml -Current $avgWorkItemAgeDays -Previous $previousSummary.avgWorkItemAgeDays -Suffix 'd')),
    (New-Tile -Label 'Stuck in queue' -Value "$stuckInQueueCount" -Note "$staleBugCount Bug$(if ($staleBugCount -ne 1) {'s'}), $staleUserStoryCount User Stor$(if ($staleUserStoryCount -ne 1) {'ies'} else {'y'}) $StaleWorkItemDaysThreshold+ business days" `
        -DeltaHtml (New-DeltaHtml -Current $stuckInQueueCount -Previous $previousSummary.stuckInQueueCount))
) -join "`n"

# ---- "Needs attention" roll-up: every risk signal collected in one place, right
# after the headline, so a Scrum Master/manager gets the "what should I ask
# about" list on first glance instead of piecing it together from five tables
# further down the page. ----
$attentionItems = New-Object System.Collections.Generic.List[string]
if ($stalePrCount -gt 0) {
    $attentionItems.Add((New-AttentionItem -Severity 'critical' `
        -Html "<strong>$stalePrCount</strong> PR$(if ($stalePrCount -ne 1) {'s'}) stuck open $StalePrDaysThreshold+ business days" `
        -Sub "out of $activePrCount currently active")) | Out-Null
}
if ($staleBugCount -gt 0) {
    $attentionItems.Add((New-AttentionItem -Severity 'critical' `
        -Html "<strong>$staleBugCount</strong> Bug$(if ($staleBugCount -ne 1) {'s'}) sitting untouched $StaleWorkItemDaysThreshold+ business days" `
        -Sub 'no state change recorded - see Stuck in queue below')) | Out-Null
}
if ($staleUserStoryCount -gt 0) {
    $usWord = if ($staleUserStoryCount -eq 1) { 'User Story' } else { 'User Stories' }
    $attentionItems.Add((New-AttentionItem -Severity 'critical' `
        -Html "<strong>$staleUserStoryCount</strong> $usWord sitting untouched $StaleWorkItemDaysThreshold+ business days" `
        -Sub 'no state change recorded - see Stuck in queue below')) | Out-Null
}
if ($abandonedCount -gt 0) {
    $attentionItems.Add((New-AttentionItem -Severity 'warning' `
        -Html "<strong>$abandonedCount</strong> PR$(if ($abandonedCount -ne 1) {'s'}) abandoned this month")) | Out-Null
}
if ($noWorkItemCount -gt 0) {
    $attentionItems.Add((New-AttentionItem -Severity 'warning' `
        -Html "<strong>$noWorkItemCount</strong> out of $totalRaised PR$(if ($totalRaised -ne 1) {'s'}) raised with no linked work item")) | Out-Null
}
if ($largePrCount -gt 0) {
    $attentionItems.Add((New-AttentionItem -Severity 'warning' `
        -Html "<strong>$largePrCount</strong> out of $totalRaised PR$(if ($totalRaised -ne 1) {'s'}) flagged large / risky to review" `
        -Sub "churn >= $LargeChurnThreshold lines or files >= $LargeFileCountThreshold")) | Out-Null
}
if ($vagueCommitCount -gt 0) {
    $attentionItems.Add((New-AttentionItem -Severity 'warning' `
        -Html "<strong>$vagueCommitCount</strong> vague / non-descriptive commit message$(if ($vagueCommitCount -ne 1) {'s'})")) | Out-Null
}
$attentionSection = if ($attentionItems.Count -eq 0) {
    '<div class="all-clear"><span class="dot"></span>No risk signals this month &mdash; PRs, bugs, and user stories are all moving.</div>'
} else {
    '<ul class="attention-list">' + ($attentionItems -join "`n") + '</ul>'
}

# ---- work items delivered: one coloured card per ADO type, matching the icon
# colours in Azure DevOps itself. Epic/Feature "active" already accounts for the
# no-user-stories-underneath gate applied in Get-WorkItemTypeStats. ----
$wiStats = $workItemTypeStats
$wiAgeCalloutHtml = if ($null -ne $avgWorkItemAgeDays) {
    '<p class="callout callout-info"><strong>Avg work item age:</strong> ' + $avgWorkItemAgeDays +
    ' business days from assignment to close (based on ' + $workItemsWithAgeData + ' completed item' +
    $(if ($workItemsWithAgeData -ne 1) { 's' }) + ' with an assigned date on record).</p>'
} else {
    '<p class="callout callout-info"><strong>Avg work item age:</strong> n/a &mdash; no work items have an "assignedDate" on record yet.</p>'
}
$workItemCardsHtml = (@(
    (New-WorkItemCard -Bucket 'Epic' -Count $wiStats['Epic'].count -ActiveCount $wiStats['Epic'].activeCount -CodeReviewCount 0 -CompletedCount $wiStats['Epic'].completedCount),
    (New-WorkItemCard -Bucket 'Feature' -Count $wiStats['Feature'].count -ActiveCount $wiStats['Feature'].activeCount -CodeReviewCount 0 -CompletedCount $wiStats['Feature'].completedCount),
    (New-WorkItemCard -Bucket 'User Story' -Count $wiStats['User Story'].count -ActiveCount $wiStats['User Story'].activeCount -CodeReviewCount $wiStats['User Story'].codeReviewCount -CompletedCount $wiStats['User Story'].completedCount -ShowCodeReview),
    (New-WorkItemCard -Bucket 'Task' -Count $wiStats['Task'].count -ActiveCount $wiStats['Task'].activeCount -CodeReviewCount $wiStats['Task'].codeReviewCount -CompletedCount $wiStats['Task'].completedCount -ShowCodeReview),
    (New-WorkItemCard -Bucket 'Bug' -Count $wiStats['Bug'].count -ActiveCount $wiStats['Bug'].activeCount -CodeReviewCount $wiStats['Bug'].codeReviewCount -CompletedCount $wiStats['Bug'].completedCount -ShowCodeReview)
) -join "`n")

# ---- stuck-in-queue: Bugs/User Stories assigned to this person with no state
# change in StaleWorkItemDaysThreshold+ business days ----
$staleQueueItems = @(
    @($staleBugItems | ForEach-Object { [pscustomobject]@{ type = 'Bug'; id = $_.id; title = $_.title; state = $_.state; ageDays = $_.ageDays } }) +
    @($staleUserStoryItems | ForEach-Object { [pscustomobject]@{ type = 'User Story'; id = $_.id; title = $_.title; state = $_.state; ageDays = $_.ageDays } })
) | Sort-Object -Property ageDays -Descending
$staleQueueRows = (@(foreach ($item in $staleQueueItems) {
    '<tr><td>' + (New-TypeBadge $item.type) + '</td><td class="num">#' + $item.id + '</td>' +
    '<td class="title">' + (ConvertTo-HtmlText $item.title) + '</td><td>' + (ConvertTo-HtmlText $item.state) + '</td>' +
    '<td class="num">' + $item.ageDays + '</td></tr>'
}) -join "`n")
$staleQueueSection = if ($staleQueueItems.Count -eq 0) {
    '<p class="empty">No Bugs or User Stories stuck in queue this month.</p>'
} else {
    '<div class="scroll"><table><thead><tr><th>Type</th><th>ID</th><th>Title</th><th>State</th><th>Business days untouched</th></tr></thead><tbody>' +
    $staleQueueRows + '</tbody></table></div>'
}

# ---- grouped metric tables ----
$hygieneRows = @(
    (New-MetricRow 'Missing work item link' "$noWorkItemCount out of $totalRaised" (New-DeltaHtml -Current $noWorkItemCount -Previous $previousSummary.noWorkItemCount)),
    (New-MetricRow 'Incomplete / stale description' "$descriptionFlagCount out of $totalRaised" (New-DeltaHtml -Current $descriptionFlagCount -Previous $previousSummary.descriptionFlagCount)),
    (New-MetricRow 'PRs with any comment flag' "$anyCommentFlagCount out of $totalRaised" (New-DeltaHtml -Current $anyCommentFlagCount -Previous $previousSummary.anyCommentFlagCount)),
    (New-MetricRow 'Abandoned PRs' "$abandonedCount out of $totalRaised" ''),
    (New-MetricRow "Stuck active PRs (open >= $StalePrDaysThreshold business days)" "$stalePrCount out of $activePrCount" (New-DeltaHtml -Current $stalePrCount -Previous $previousSummary.stalePrCount))
) -join "`n"

$sizeRows = @(
    (New-MetricRow 'Lines added / deleted' "+$totalLinesAdded / -$totalLinesDeleted" ''),
    (New-MetricRow "Large PRs (churn >= $LargeChurnThreshold or files >= $LargeFileCountThreshold)" "$largePrCount out of $totalRaised" (New-DeltaHtml -Current $largePrCount -Previous $previousSummary.largePrCount))
) -join "`n"

$reviewingRows = @(
    (New-MetricRow "PRs reviewed by $person" "$reviewedCount" (New-DeltaHtml -Current $reviewedCount -Previous $previousSummary.reviewedCount -HigherIsBetter)),
    (New-MetricRow 'Of those, approved' "$reviewedApprovedCount" (New-DeltaHtml -Current $reviewedApprovedCount -Previous $previousSummary.reviewedApprovedCount))
) -join "`n"

$commitRows = @(
    (New-MetricRow 'Total commits' "$totalCommits" ''),
    (New-MetricRow 'Vague / non-descriptive messages' "$vagueCommitCount ($vagueCommitRatePercent%)" (New-DeltaHtml -Current $vagueCommitRatePercent -Previous $previousSummary.vagueCommitRatePercent -Suffix 'pp')),
    (New-MetricRow 'Avg rework commits after first review comment' (Format-Metric $avgReworkCommitsPerPr '' 'n/a (no comment timestamps supplied)') (New-DeltaHtml -Current $avgReworkCommitsPerPr -Previous $previousSummary.avgReworkCommitsPerPr))
) -join "`n"

$categoryRows = (@(foreach ($cat in $categoryTotals.Keys) {
    New-MetricRow $cat "$($categoryTotals[$cat])" ''
}) -join "`n")

# ---- confirmed talking points (written by the agent, per RUNBOOK Step 4) - parsed
# early so the per-PR table below can show each PR's actionable vs general point
# count right alongside its other numbers. ----
$tpRaw = $null
$tpParsed = $null
if ($TalkingPointsPath -and (Test-Path $TalkingPointsPath)) {
    $tpRaw = Get-Content -Raw -Encoding UTF8 -Path $TalkingPointsPath
    $tpParsed = Get-TalkingPointsParsed -RawText $tpRaw
}
$prTalkingPointCounts = @{}
if ($tpParsed) {
    foreach ($s in $tpParsed.Sections) {
        if ($null -eq $s.PullRequestId) { continue }
        $actionable = @($s.Bullets | Where-Object { $_.Category -eq 'Actionable' }).Count
        $general = @($s.Bullets | Where-Object { $_.Category -eq 'General' }).Count
        $prTalkingPointCounts[$s.PullRequestId] = @{ Actionable = $actionable; General = $general }
    }
}

# ---- per-PR table ----
$prRows = (@(foreach ($pr in $prResults) {
    $titleText = ConvertTo-HtmlText $pr.title
    $titleCell = if ($pr.url) { '<a href="' + (ConvertTo-HtmlText $pr.url) + '">' + $titleText + '</a>' } else { $titleText }
    $chips = ''
    if ($pr.descriptionFlag)      { $chips += (New-Chip 'warning'  'stale description') }
    if ($pr.noWorkItemFlag)       { $chips += (New-Chip 'warning'  'no work item') }
    if ($pr.largePrFlag)          { $chips += (New-Chip 'warning'  'large PR') }
    if ($pr.stalePrFlag)          { $chips += (New-Chip 'critical' "stuck $($pr.ageDays)d open") }
    if ($pr.vagueCommitCount -gt 0) { $chips += (New-Chip 'serious' "$($pr.vagueCommitCount) vague commits") }
    # Flags ride under the title rather than in a far-right column: in a wide table
    # that column lands off-screen, which hides the one thing worth reading.
    $chipLine = if ($chips) { '<span class="chips">' + $chips + '</span>' } else { '' }

    # Cycle time only exists for closed PRs; a still-open PR shows its age
    # instead (days since creation, business days only) so it's obvious how
    # long it's been sitting rather than a blank/misleading "n/a".
    $cycle  = if ($null -ne $pr.cycleTimeDays) { "$($pr.cycleTimeDays)" } `
              elseif ($pr.isActive -and $null -ne $pr.ageDays) { "$($pr.ageDays) (open)" } `
              else { 'n/a' }
    $rework = if ($null -ne $pr.reworkCommitCount) { "$($pr.reworkCommitCount)" } else { 'n/a' }
    $merged = if ($pr.mergedToMaster) { 'yes' } else { 'no' }
    $tpCounts = $prTalkingPointCounts[[int]$pr.pullRequestId]
    $tpCell = if ($tpCounts) { "$($tpCounts.Actionable) / $($tpCounts.General)" } else { 'n/a' }

    '<tr>' +
    '<td class="num">' + $pr.pullRequestId + '</td>' +
    '<td class="title">' + $titleCell + '<span class="sub">' + (ConvertTo-HtmlText $pr.targetRefName) + '</span>' + $chipLine + '</td>' +
    '<td>' + (New-StatusPill $pr.status) + '</td>' +
    '<td>' + $merged + '</td>' +
    '<td class="num">' + $cycle + '</td>' +
    '<td class="num">' + $pr.commentCount + ' / ' + $pr.threadCount + '</td>' +
    '<td class="num">' + $tpCell + '</td>' +
    '<td class="num">' + $pr.filesChangedCount + '</td>' +
    '<td class="num">+' + $pr.linesAdded + ' / -' + $pr.linesDeleted + '</td>' +
    '<td class="num">' + $pr.approvedCount + ' / ' + $pr.reviewersCount + '</td>' +
    '<td class="num">' + $pr.commitCount + '</td>' +
    '<td class="num">' + $rework + '</td>' +
    '</tr>'
}) -join "`n")

# ---- candidate comment flags ----
$flagCards = (@(foreach ($pr in $prResults) {
    if ($pr.commentFlags.Count -eq 0) { continue }
    $prHeading = if ($pr.url) {
        '<a href="' + (ConvertTo-HtmlText $pr.url) + '" target="_blank" rel="noopener">#' + $pr.pullRequestId + '</a>'
    } else { '#' + $pr.pullRequestId }
    $card = '<article class="card"><h3>PR ' + $prHeading + ' &mdash; ' + (ConvertTo-HtmlText $pr.title) + '</h3><ul>'
    foreach ($hit in $pr.commentFlags) {
        $card += '<li><span class="cat">' + (ConvertTo-HtmlText $hit.category) + '</span>' +
                 '<blockquote>' + (ConvertTo-HtmlText $hit.snippet) + '</blockquote>' +
                 '<p class="attrib">thread ' + (ConvertTo-HtmlText "$($hit.threadId)") + ', by ' + (ConvertTo-HtmlText $hit.author) + '</p></li>'
    }
    $card + '</ul></article>'
}) -join "`n")
if (-not $flagCards) { $flagCards = '<p class="empty">No keyword-based comment flags found.</p>' }

# ---- vague commits ----
$vagueRows = (@(foreach ($hit in $vagueCommitHits) {
    $shortSha = if ($hit.commitId -and $hit.commitId.Length -gt 8) { $hit.commitId.Substring(0, 8) } else { $hit.commitId }
    '<tr><td class="num">#' + $hit.pullRequestId + '</td><td>' + (ConvertTo-HtmlText $hit.title) + '</td>' +
    '<td class="mono">' + (ConvertTo-HtmlText $shortSha) + '</td><td>' + (ConvertTo-HtmlText $hit.message) + '</td></tr>'
}) -join "`n")
$vagueSection = if ($vagueCommitHits.Count -eq 0) {
    '<p class="empty">No vague commit messages detected.</p>'
} else {
    '<div class="scroll"><table><thead><tr><th>PR</th><th>Title</th><th>Commit</th><th>Message</th></tr></thead><tbody>' +
    $vagueRows + '</tbody></table></div>'
}

# ---- PRs reviewed by this person (authored by someone else) ----
$reviewedRows = (@(foreach ($rpr in $reviewedPullRequests) {
    $titleText = ConvertTo-HtmlText $rpr.title
    $titleCell = if ($rpr.url) { '<a href="' + (ConvertTo-HtmlText $rpr.url) + '">' + $titleText + '</a>' } else { $titleText }
    $voteText = switch ([int]$rpr.vote) {
        10  { 'Approved' }
        5   { 'Approved with suggestions' }
        0   { 'No vote' }
        -5  { 'Waiting for author' }
        -10 { 'Rejected' }
        default { 'n/a' }
    }
    # Files/lines are optional on reviewedPullRequests - older raw data won't have
    # them, so fall back to "n/a" rather than showing a misleading 0.
    $rFiles = if ($null -ne $rpr.filesChangedCount) { "$($rpr.filesChangedCount)" } else { 'n/a' }
    $rLines = if ($null -ne $rpr.linesAdded -or $null -ne $rpr.linesDeleted) {
        $rAdded = if ($null -ne $rpr.linesAdded) { [int]$rpr.linesAdded } else { 0 }
        $rDeleted = if ($null -ne $rpr.linesDeleted) { [int]$rpr.linesDeleted } else { 0 }
        "+$rAdded / -$rDeleted"
    } else { 'n/a' }
    '<tr><td class="num">#' + $rpr.pullRequestId + '</td><td class="title">' + $titleCell + '</td>' +
    '<td>' + (ConvertTo-HtmlText $rpr.author) + '</td><td>' + (ConvertTo-HtmlText $voteText) + '</td>' +
    '<td class="num">' + $rFiles + '</td><td class="num">' + $rLines + '</td></tr>'
}) -join "`n")
$reviewedSection = if ($reviewedPullRequests.Count -eq 0) {
    '<p class="empty">No reviewed-PR data supplied for this month.</p>'
} else {
    '<div class="scroll"><table><thead><tr><th>PR</th><th>Title</th><th>Author</th><th>Vote</th><th>Files</th><th>Lines</th></tr></thead><tbody>' +
    $reviewedRows + '</tbody></table></div>'
}

# ---- confirmed talking points HTML (parsing already done above, before the PR table) ----
$talkingPoints = if ($tpRaw) { ConvertTo-TalkingPointsHtml $tpRaw } `
    else { '<p class="empty">Not yet written. After the manual review pass (RUNBOOK.md Step 4), save the confirmed points to a text file and re-run with <code>-TalkingPointsPath</code>.</p>' }

$trendNote = if ($previousSummary) {
    'Trends compare against ' + (ConvertTo-HtmlText "$($previousSummary.monthYear)") + ', the same person.'
} else {
    'No prior month found in this folder, so no trends yet. They appear once a second month has been generated for this person.'
}

$generatedLocal = (Get-Date).ToString('yyyy-MM-dd HH:mm')

# ---- avatar initials for the profile header ----
$nameTokens = @(($person -split '[@\.\s_]+') | Where-Object { $_ })
$initials = if ($nameTokens.Count -ge 2) {
    ($nameTokens[0].Substring(0, 1) + $nameTokens[1].Substring(0, 1)).ToUpperInvariant()
} elseif ($nameTokens.Count -eq 1) {
    $nameTokens[0].Substring(0, [Math]::Min(2, $nameTokens[0].Length)).ToUpperInvariant()
} else {
    '??'
}

# ---- the template. Colours are the validated data-viz reference palette:
#      status hues are fixed and always ship with a glyph + word, never colour alone.
$htmlTemplate = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PR / KPI report - {{PERSON}} - {{MONTH}}</title>
<style>
{{STYLE}}
</style>
</head>
<body>
<div class="wrap">

  <header class="report">
    <div class="avatar">{{INITIALS}}</div>
    <div class="header-text">
      <p class="eyebrow">PR / KPI report</p>
      <h1>{{PERSON}}</h1>
      <p class="period-badge">{{PERIOD_RANGE}}</p>
      <p class="subject">Reporting period: <strong>{{MONTH_LABEL}}</strong> &middot; pull requests raised in this month</p>
      <p class="stamp">Generated {{GENERATED}} &middot; {{TREND_NOTE}}</p>
    </div>
  </header>

  <section>
    <h2>Headline</h2>
    <div class="tiles">
      {{TILES}}
    </div>
  </section>

  <section class="panel">
    <h2>Needs attention</h2>
    {{ATTENTION_SECTION}}
  </section>

  <section class="panel">
    <h2>Work items delivered</h2>
    <p class="callout callout-info">Epic/Feature only count as "Active" once at least one User Story exists under them &mdash; an Epic or Feature with no User Stories is not counted as active work.</p>
    {{WI_AGE_CALLOUT}}
    <div class="wi-grid">
      {{WORK_ITEM_CARDS}}
    </div>
    <h3>Stuck in queue (Bug / User Story, no status change in {{STALE_WI_DAYS}}+ business days)</h3>
    {{STALE_QUEUE_SECTION}}
  </section>

  <section class="panel">
    <h2>Pull requests</h2>
    <div class="scroll">
      <table>
        <thead><tr>
          <th>PR</th><th>Title &amp; flags</th><th>Status</th><th>Merged</th><th>Cycle d / age</th>
          <th>Comments / threads</th><th>Talking pts (action / note)</th><th>Files</th><th>Lines</th><th>Approvals</th>
          <th>Commits</th><th>Rework</th>
        </tr></thead>
        <tbody>
          {{PR_ROWS}}
        </tbody>
      </table>
    </div>
  </section>

  <section class="panel grid-2">
    <div>
      <h2>PR hygiene</h2>
      <table class="metrics"><tbody>
        {{HYGIENE_ROWS}}
      </tbody></table>
    </div>
    <div>
      <h2>Size &amp; risk</h2>
      <table class="metrics"><tbody>
        {{SIZE_ROWS}}
      </tbody></table>
    </div>
    <div>
      <h2>Reviewing others' work</h2>
      <table class="metrics"><tbody>
        {{REVIEWING_ROWS}}
      </tbody></table>
    </div>
    <div>
      <h2>Commit hygiene</h2>
      <table class="metrics"><tbody>
        {{COMMIT_ROWS}}
      </tbody></table>
    </div>
  </section>

  <section class="panel">
    <h2>PRs reviewed by {{PERSON}}</h2>
    {{REVIEWED_SECTION}}
  </section>

  <section class="panel">
    <h2>Confirmed talking points</h2>
    {{TALKING_POINTS}}
  </section>

  <details class="appendix">
    <summary>Candidate flags &mdash; not yet confirmed, keyword matches only</summary>
    <section>
      <p class="callout">Everything below this line is keyword matching, not judgment. Read each one in its original context before raising it: a comment saying "add a null check" may be a recurring blind spot or a one-off on genuinely subtle code, and the script cannot tell those apart. Discard the false positives before the meeting.</p>

      <h3>Review comments</h3>
      {{FLAG_CARDS}}

      <h3>Vague / non-descriptive commit messages</h3>
      {{VAGUE_SECTION}}

      <h3>Comment-flag categories</h3>
      <table class="metrics"><tbody>
        {{CATEGORY_ROWS}}
      </tbody></table>
    </section>
  </details>

  <footer class="report">
    <p><strong>Scope.</strong> This covers pull requests only. Mentoring, design work, on-call, incident response, and whether the person was working on the right thing at all are invisible here. A month with 3 PRs says nothing on its own.</p>
    <p><strong>Thresholds used.</strong> Large PR at churn &ge; {{LARGE_CHURN}} lines or &ge; {{LARGE_FILES}} files. Description flagged under {{DESC_MIN}} characters. Commit subject flagged as vague under {{VAGUE_MIN}} characters or matching the known-phrase list. Active PR flagged "stuck" at &ge; {{STALE_DAYS}} business days open. Bug/User Story flagged "stuck in queue" at &ge; {{STALE_WI_DAYS}} business days with no status change.</p>
    <p><strong>Handling.</strong> Contains real review comments about an identifiable person. Keep it out of shared drives and version control, and show the report to the person it describes.</p>
  </footer>

</div>
</body>
</html>
'@

$html = $htmlTemplate.
    Replace('{{STYLE}}',         (Get-KpiReportCss)).
    Replace('{{PERSON}}',        (ConvertTo-HtmlText $person)).
    Replace('{{INITIALS}}',      (ConvertTo-HtmlText $initials)).
    Replace('{{MONTH}}',         (ConvertTo-HtmlText $monthYear)).
    Replace('{{MONTH_LABEL}}',   (ConvertTo-HtmlText $monthLabel)).
    Replace('{{PERIOD_RANGE}}',  (ConvertTo-HtmlText $periodRangeLabel)).
    Replace('{{GENERATED}}',     (ConvertTo-HtmlText $generatedLocal)).
    Replace('{{TREND_NOTE}}',    $trendNote).
    Replace('{{TILES}}',         $tiles).
    Replace('{{ATTENTION_SECTION}}', $attentionSection).
    Replace('{{WORK_ITEM_CARDS}}', $workItemCardsHtml).
    Replace('{{WI_AGE_CALLOUT}}', $wiAgeCalloutHtml).
    Replace('{{STALE_QUEUE_SECTION}}', $staleQueueSection).
    Replace('{{HYGIENE_ROWS}}',  $hygieneRows).
    Replace('{{SIZE_ROWS}}',     $sizeRows).
    Replace('{{REVIEWING_ROWS}}', $reviewingRows).
    Replace('{{COMMIT_ROWS}}',   $commitRows).
    Replace('{{PR_ROWS}}',       $prRows).
    Replace('{{REVIEWED_SECTION}}', $reviewedSection).
    Replace('{{TALKING_POINTS}}', $talkingPoints).
    Replace('{{FLAG_CARDS}}',    $flagCards).
    Replace('{{VAGUE_SECTION}}', $vagueSection).
    Replace('{{CATEGORY_ROWS}}', $categoryRows).
    Replace('{{LARGE_CHURN}}',   "$LargeChurnThreshold").
    Replace('{{LARGE_FILES}}',   "$LargeFileCountThreshold").
    Replace('{{DESC_MIN}}',      "$DescriptionMinLength").
    Replace('{{VAGUE_MIN}}',     "$VagueCommitMinLength").
    Replace('{{STALE_DAYS}}',    "$StalePrDaysThreshold").
    Replace('{{STALE_WI_DAYS}}', "$StaleWorkItemDaysThreshold")

$html | Set-Content -Path $htmlPath -Encoding UTF8

Write-Host "HTML report:  $htmlPath"
Write-Host "PR CSV:       $prsCsvPath"
Write-Host "Ledger CSV:   $ledgerPath"
Write-Host "Summary JSON: $summaryPath"
Write-Host ("PRs raised: {0}, Merged to master: {1} ({2}%), Reviewed for others: {3}, Work items assigned: {4} ({5} completed)" -f `
    $totalRaised, $mergedToMaster, $summary.mergeRatePercent, $reviewedCount, $totalWorkItemsAssigned, $totalWorkItemsCompleted)
