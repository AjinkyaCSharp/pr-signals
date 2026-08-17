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
          // --- optional fields enabling size/churn, self-approval and commit-hygiene metrics ---
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

    [int]$VagueCommitMinLength = 10
)

$ErrorActionPreference = 'Stop'

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
$cycleTimeHoursList = New-Object System.Collections.Generic.List[double]
$reviewerSet = New-Object System.Collections.Generic.HashSet[string]
$totalComments = 0
$totalThreads = 0
$resolvedThreads = 0
$categoryTotals = [ordered]@{}
foreach ($cat in $keywordCategories.Keys) { $categoryTotals[$cat] = 0 }
$totalLinesAdded = 0
$totalLinesDeleted = 0
$totalFilesChanged = 0
$largePrCount = 0
$selfApprovalCount = 0
$noApprovalMergedCount = 0
$totalCommits = 0
$vagueCommitCount = 0
$reworkCommitTotal = 0
$prsWithReworkData = 0
$vagueCommitHits = New-Object System.Collections.Generic.List[object]

function Get-Median {
    param([double[]]$Values)
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $sorted = $Values | Sort-Object
    $n = $sorted.Count
    if ($n % 2 -eq 1) { return [double]$sorted[[math]::Floor($n / 2)] }
    return [double](($sorted[$n / 2 - 1] + $sorted[$n / 2]) / 2)
}

foreach ($pr in $pullRequests) {
    $totalRaised++

    $isMergedToMaster = ($pr.status -ieq 'completed') -and
                         ($pr.targetRefName -ieq $targetMasterBranch)
    if ($isMergedToMaster) { $mergedToMaster++ }
    if ($pr.status -ieq 'abandoned') { $abandonedCount++ }

    # Cycle time: creation -> closed, in hours (any closed PR, not just merged-to-master)
    $cycleTimeHours = $null
    if ($pr.creationDate -and $pr.closedDate) {
        try {
            $created = [datetime]$pr.creationDate
            $closed = [datetime]$pr.closedDate
            $cycleTimeHours = [math]::Round(($closed - $created).TotalHours, 1)
            if ($isMergedToMaster) { $cycleTimeHoursList.Add($cycleTimeHours) }
        } catch { $cycleTimeHours = $null }
    }

    $descriptionFlag = Test-DescriptionFlag -Description $pr.description -MinLength $DescriptionMinLength
    $workItemCount = if ($pr.workItemRefs) { @($pr.workItemRefs).Count } else { 0 }
    $noWorkItemFlag = ($workItemCount -eq 0)

    $commentHits = New-Object System.Collections.Generic.List[object]
    $prCommentCount = 0
    $prThreads = @()
    if ($pr.threads) { $prThreads = @($pr.threads) }
    $prThreadCount = $prThreads.Count
    $totalThreads += $prThreadCount
    $firstCommentDate = $null
    foreach ($thread in $prThreads) {
        if ($thread.status -in @('closed', 'fixed')) { $resolvedThreads++ }
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
    $totalFilesChanged += $filesChangedCount
    if ($largePrFlag) { $largePrCount++ }

    # ---- Reviewer self-approval detection ----
    $reviewers = @()
    if ($pr.reviewers) { $reviewers = @($pr.reviewers) }
    $reviewersCount = $reviewers.Count
    $approvedCount = @($reviewers | Where-Object { $_.vote -ge 5 }).Count
    $selfApprovalFlag = $false
    foreach ($rev in $reviewers) {
        $revId = @($rev.uniqueName, $rev.displayName) | Where-Object { $_ } | Select-Object -First 1
        if ($revId -and $person -and ($revId -ieq $person -or $revId -like "*$person*") -and $rev.vote -ge 5) {
            $selfApprovalFlag = $true
        }
    }
    if ($selfApprovalFlag) { $selfApprovalCount++ }
    if ($isMergedToMaster -and $reviewersCount -gt 0 -and $approvedCount -eq 0) { $noApprovalMergedCount++ }

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
        cycleTimeHours      = $cycleTimeHours
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
        selfApprovalFlag    = $selfApprovalFlag
        noApprovalMergedFlag = ($isMergedToMaster -and $reviewersCount -gt 0 -and $approvedCount -eq 0)
        commitCount         = $prCommitCount
        vagueCommitCount    = $prVagueCommits.Count
        vagueCommits        = $prVagueCommits
        reworkCommitCount   = $prReworkCommitCount
    }) | Out-Null
}

# ---- Aggregate quantitative metrics ----
$avgCycleTimeHours = if ($cycleTimeHoursList.Count -gt 0) { [math]::Round(($cycleTimeHoursList | Measure-Object -Average).Average, 1) } else { $null }
$medianCycleTimeHours = Get-Median -Values @($cycleTimeHoursList)
$abandonRatePercent = if ($totalRaised -gt 0) { [math]::Round(100 * $abandonedCount / $totalRaised, 1) } else { 0 }
$threadResolutionPercent = if ($totalThreads -gt 0) { [math]::Round(100 * $resolvedThreads / $totalThreads, 1) } else { $null }
$avgCommentsPerPr = if ($totalRaised -gt 0) { [math]::Round($totalComments / $totalRaised, 1) } else { 0 }
$noWorkItemCount = @($prResults | Where-Object { $_.noWorkItemFlag }).Count
$descriptionFlagCount = @($prResults | Where-Object { $_.descriptionFlag }).Count
$anyCommentFlagCount = @($prResults | Where-Object { $_.commentFlagCount -gt 0 }).Count
$noWorkItemRatePercent = if ($totalRaised -gt 0) { [math]::Round(100 * $noWorkItemCount / $totalRaised, 1) } else { 0 }
$descriptionFlagRatePercent = if ($totalRaised -gt 0) { [math]::Round(100 * $descriptionFlagCount / $totalRaised, 1) } else { 0 }
$commentFlagRatePercent = if ($totalRaised -gt 0) { [math]::Round(100 * $anyCommentFlagCount / $totalRaised, 1) } else { 0 }
$reviewerDiversityCount = $reviewerSet.Count

# ---- PR size/churn, self-approval and commit-hygiene aggregates ----
$avgChurnPerPr = if ($totalRaised -gt 0) { [math]::Round(($totalLinesAdded + $totalLinesDeleted) / $totalRaised, 1) } else { 0 }
$largePrRatePercent = if ($totalRaised -gt 0) { [math]::Round(100 * $largePrCount / $totalRaised, 1) } else { 0 }
$selfApprovalRatePercent = if ($totalRaised -gt 0) { [math]::Round(100 * $selfApprovalCount / $totalRaised, 1) } else { 0 }
$noApprovalMergedRatePercent = if ($mergedToMaster -gt 0) { [math]::Round(100 * $noApprovalMergedCount / $mergedToMaster, 1) } else { 0 }
$vagueCommitRatePercent = if ($totalCommits -gt 0) { [math]::Round(100 * $vagueCommitCount / $totalCommits, 1) } else { 0 }
$avgReworkCommitsPerPr = if ($prsWithReworkData -gt 0) {
    [math]::Round((@($prResults | Where-Object { $null -ne $_.reworkCommitCount } | ForEach-Object { $_.reworkCommitCount }) | Measure-Object -Sum).Sum / $prsWithReworkData, 1)
} else { $null }

# Composite quality score (0-100): rewards merging, resolving threads, complete descriptions/work items,
# reasonable PR size, real self-review approvals, and descriptive commit messages; penalizes flags.
$mergeRateForScore = if ($totalRaised -gt 0) { 100 * $mergedToMaster / $totalRaised } else { 0 }
$threadResForScore = if ($null -ne $threadResolutionPercent) { $threadResolutionPercent } else { 100 }
$hygieneScore = 100 - (($noWorkItemRatePercent + $descriptionFlagRatePercent + $commentFlagRatePercent + $largePrRatePercent + $vagueCommitRatePercent) / 5)
if ($hygieneScore -lt 0) { $hygieneScore = 0 }
$governanceScore = 100 - (($selfApprovalRatePercent * 2) + $noApprovalMergedRatePercent) # self-approval weighted heavier - governance red flag
if ($governanceScore -lt 0) { $governanceScore = 0 }
$qualityScore = [math]::Round((0.35 * $mergeRateForScore) + (0.25 * $threadResForScore) + (0.25 * $hygieneScore) + (0.15 * $governanceScore), 1)

$summary = [pscustomobject]@{
    person                       = $person
    monthYear                    = $monthYear
    totalRaised                  = $totalRaised
    mergedToMaster               = $mergedToMaster
    mergeRatePercent             = if ($totalRaised -gt 0) { [math]::Round(100 * $mergedToMaster / $totalRaised, 1) } else { 0 }
    abandonedCount               = $abandonedCount
    abandonRatePercent           = $abandonRatePercent
    avgCycleTimeHours            = $avgCycleTimeHours
    medianCycleTimeHours         = $medianCycleTimeHours
    totalThreads                 = $totalThreads
    resolvedThreads              = $resolvedThreads
    threadResolutionPercent      = $threadResolutionPercent
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
    totalFilesChanged            = $totalFilesChanged
    avgChurnPerPr                = $avgChurnPerPr
    largePrCount                 = $largePrCount
    largePrRatePercent           = $largePrRatePercent
    selfApprovalCount            = $selfApprovalCount
    selfApprovalRatePercent      = $selfApprovalRatePercent
    noApprovalMergedCount        = $noApprovalMergedCount
    noApprovalMergedRatePercent  = $noApprovalMergedRatePercent
    totalCommits                 = $totalCommits
    vagueCommitCount             = $vagueCommitCount
    vagueCommitRatePercent       = $vagueCommitRatePercent
    avgReworkCommitsPerPr        = $avgReworkCommitsPerPr
    qualityScore                 = $qualityScore
    pullRequests                 = $prResults
    generatedAtUtc               = (Get-Date).ToUniversalTime().ToString('o')
}

$safePerson = ($person -replace '[^a-zA-Z0-9\.\-_@]', '_')
$summaryPath = Join-Path $OutputDir "$safePerson-$monthYear-summary.json"
$mdPath = Join-Path $OutputDir "$safePerson-$monthYear.md"

# ---- Month-over-month trend: look for the immediately preceding month's summary for this person ----
$previousSummary = $null
try {
    $ym = [datetime]::ParseExact($monthYear, 'yyyy-MM', $null)
    $prevYm = $ym.AddMonths(-1).ToString('yyyy-MM')
    $prevPath = Join-Path $OutputDir "$safePerson-$prevYm-summary.json"
    if (Test-Path $prevPath) {
        $previousSummary = Get-Content -Raw -Path $prevPath | ConvertFrom-Json
    }
} catch { $previousSummary = $null }

$summary | ConvertTo-Json -Depth 10 | Set-Content -Path $summaryPath -Encoding UTF8

# ---- Markdown report ----
$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine("# PR / KPI Report - $person ($monthYear)")
[void]$md.AppendLine()
[void]$md.AppendLine("Generated: $($summary.generatedAtUtc)")
[void]$md.AppendLine()
function Format-Trend {
    param($Current, $Previous, [switch]$HigherIsBetter, [string]$Suffix = '')
    if ($null -eq $Previous -or $null -eq $Current) { return '' }
    $delta = [math]::Round($Current - $Previous, 1)
    if ($delta -eq 0) { return ' (no change)' }
    $arrow = if ($delta -gt 0) { '^' } else { 'v' }
    $good = if ($HigherIsBetter) { $delta -gt 0 } else { $delta -lt 0 }
    $tag = if ($good) { 'better' } else { 'worse' }
    return " ($arrow $([math]::Abs($delta))$Suffix vs last month, $tag)"
}

[void]$md.AppendLine("## Summary")
[void]$md.AppendLine()
[void]$md.AppendLine("| Metric | Value | Trend |")
[void]$md.AppendLine("|---|---|---|")
[void]$md.AppendLine("| PRs raised | $totalRaised | $(if($previousSummary){"prev: $($previousSummary.totalRaised)"}) |")
[void]$md.AppendLine("| PRs merged to master | $mergedToMaster | $(if($previousSummary){"prev: $($previousSummary.mergedToMaster)"}) |")
[void]$md.AppendLine("| Merge rate | $($summary.mergeRatePercent)%$(Format-Trend -Current $summary.mergeRatePercent -Previous $previousSummary.mergeRatePercent -HigherIsBetter -Suffix 'pp') | |")
[void]$md.AppendLine("| Abandoned PRs | $abandonedCount ($abandonRatePercent%) | |")
[void]$md.AppendLine("| Avg cycle time (create -> merge) | $(if($avgCycleTimeHours){"$avgCycleTimeHours h"}else{'n/a'})$(Format-Trend -Current $avgCycleTimeHours -Previous $previousSummary.avgCycleTimeHours -Suffix 'h') | |")
[void]$md.AppendLine("| Median cycle time | $(if($medianCycleTimeHours){"$medianCycleTimeHours h"}else{'n/a'}) | |")
[void]$md.AppendLine("| Review threads (resolved/total) | $resolvedThreads/$totalThreads ($(if($threadResolutionPercent){"$threadResolutionPercent%"}else{'n/a'})) | |")
[void]$md.AppendLine("| Total review comments | $totalComments (avg $avgCommentsPerPr / PR)$(Format-Trend -Current $avgCommentsPerPr -Previous $previousSummary.avgCommentsPerPr -Suffix '/PR') | |")
[void]$md.AppendLine("| Distinct reviewers engaged | $reviewerDiversityCount | |")
[void]$md.AppendLine("| Missing work item link | $noWorkItemCount ($noWorkItemRatePercent%)$(Format-Trend -Current $noWorkItemRatePercent -Previous $previousSummary.noWorkItemRatePercent -Suffix 'pp') | |")
[void]$md.AppendLine("| Incomplete/stale description | $descriptionFlagCount ($descriptionFlagRatePercent%)$(Format-Trend -Current $descriptionFlagRatePercent -Previous $previousSummary.descriptionFlagRatePercent -Suffix 'pp') | |")
[void]$md.AppendLine("| PRs with any comment flag | ($commentFlagRatePercent%)$(Format-Trend -Current $commentFlagRatePercent -Previous $previousSummary.commentFlagRatePercent -Suffix 'pp') | |")
[void]$md.AppendLine("| **Composite quality score (0-100)** | **$qualityScore**$(Format-Trend -Current $qualityScore -Previous $previousSummary.qualityScore -HigherIsBetter) | |")
if (-not $previousSummary) {
    [void]$md.AppendLine()
    [void]$md.AppendLine("_No prior month summary found in this output folder - trend column will populate once a previous month's report exists._")
}
[void]$md.AppendLine()
[void]$md.AppendLine("### PR size / churn")
[void]$md.AppendLine()
[void]$md.AppendLine("| Metric | Value | Trend |")
[void]$md.AppendLine("|---|---|---|")
[void]$md.AppendLine("| Total lines added / deleted | +$totalLinesAdded / -$totalLinesDeleted | |")
[void]$md.AppendLine("| Total files changed | $totalFilesChanged | |")
[void]$md.AppendLine("| Avg churn per PR (added+deleted) | $avgChurnPerPr$(Format-Trend -Current $avgChurnPerPr -Previous $previousSummary.avgChurnPerPr) | |")
[void]$md.AppendLine("| Large / risky-to-review PRs (churn >= $LargeChurnThreshold or files >= $LargeFileCountThreshold) | $largePrCount ($largePrRatePercent%)$(Format-Trend -Current $largePrRatePercent -Previous $previousSummary.largePrRatePercent -Suffix 'pp') | |")
[void]$md.AppendLine()
[void]$md.AppendLine("### Review governance")
[void]$md.AppendLine()
[void]$md.AppendLine("| Metric | Value | Trend |")
[void]$md.AppendLine("|---|---|---|")
[void]$md.AppendLine("| Self-approval flags (author approved own PR) | $selfApprovalCount ($selfApprovalRatePercent%)$(Format-Trend -Current $selfApprovalRatePercent -Previous $previousSummary.selfApprovalRatePercent -Suffix 'pp') | |")
[void]$md.AppendLine("| Merged to master with no approving reviewer | $noApprovalMergedCount ($noApprovalMergedRatePercent% of merges)$(Format-Trend -Current $noApprovalMergedRatePercent -Previous $previousSummary.noApprovalMergedRatePercent -Suffix 'pp') | |")
[void]$md.AppendLine()
[void]$md.AppendLine("### Commit hygiene")
[void]$md.AppendLine()
[void]$md.AppendLine("| Metric | Value | Trend |")
[void]$md.AppendLine("|---|---|---|")
[void]$md.AppendLine("| Total commits | $totalCommits | |")
[void]$md.AppendLine("| Vague / non-descriptive commit messages | $vagueCommitCount ($vagueCommitRatePercent%)$(Format-Trend -Current $vagueCommitRatePercent -Previous $previousSummary.vagueCommitRatePercent -Suffix 'pp') | |")
[void]$md.AppendLine("| Avg rework commits after first review comment | $(if($null -ne $avgReworkCommitsPerPr){$avgReworkCommitsPerPr}else{'n/a (no comment timestamps supplied)'})$(if($null -ne $avgReworkCommitsPerPr){Format-Trend -Current $avgReworkCommitsPerPr -Previous $previousSummary.avgReworkCommitsPerPr}) | |")
[void]$md.AppendLine()
[void]$md.AppendLine("### Comment-flag category breakdown")
[void]$md.AppendLine()
[void]$md.AppendLine("| Category | Count |")
[void]$md.AppendLine("|---|---|")
foreach ($cat in $categoryTotals.Keys) {
    [void]$md.AppendLine("| $cat | $($categoryTotals[$cat]) |")
}
[void]$md.AppendLine()
[void]$md.AppendLine("## Pull Requests")
[void]$md.AppendLine()
[void]$md.AppendLine("| # | Title | Status | Target | Merged | Cycle time (h) | Threads | Comments | Desc flag | No work item | Comment flags |")
[void]$md.AppendLine("|---|---|---|---|---|---|---|---|---|---|---|")
foreach ($pr in $prResults) {
    $titleLink = if ($pr.url) { "[$($pr.title)]($($pr.url))" } else { $pr.title }
    $ct = if ($null -ne $pr.cycleTimeHours) { $pr.cycleTimeHours } else { 'n/a' }
    [void]$md.AppendLine("| $($pr.pullRequestId) | $titleLink | $($pr.status) | $($pr.targetRefName) | $($pr.mergedToMaster) | $ct | $($pr.threadCount) | $($pr.commentCount) | $($pr.descriptionFlag) | $($pr.noWorkItemFlag) | $($pr.commentFlagCount) |")
}
[void]$md.AppendLine()
[void]$md.AppendLine("### Pull Requests - size, governance & commit hygiene")
[void]$md.AppendLine()
[void]$md.AppendLine("| # | Files | +Lines | -Lines | Large PR | Reviewers | Approved | Self-approved | Commits | Vague commits | Rework commits |")
[void]$md.AppendLine("|---|---|---|---|---|---|---|---|---|---|---|")
foreach ($pr in $prResults) {
    $rework = if ($null -ne $pr.reworkCommitCount) { $pr.reworkCommitCount } else { 'n/a' }
    [void]$md.AppendLine("| $($pr.pullRequestId) | $($pr.filesChangedCount) | +$($pr.linesAdded) | -$($pr.linesDeleted) | $($pr.largePrFlag) | $($pr.reviewersCount) | $($pr.approvedCount) | $($pr.selfApprovalFlag) | $($pr.commitCount) | $($pr.vagueCommitCount) | $rework |")
}
[void]$md.AppendLine()
[void]$md.AppendLine("## Candidate comment flags (heuristic - needs manual confirmation)")
[void]$md.AppendLine()
$anyFlags = $false
foreach ($pr in $prResults) {
    if ($pr.commentFlags.Count -eq 0) { continue }
    $anyFlags = $true
    [void]$md.AppendLine("### PR #$($pr.pullRequestId) - $($pr.title)")
    foreach ($hit in $pr.commentFlags) {
        [void]$md.AppendLine("- **$($hit.category)** (thread $($hit.threadId), by $($hit.author)): `"$($hit.snippet)`"")
    }
    [void]$md.AppendLine()
}
if (-not $anyFlags) {
    [void]$md.AppendLine("_No keyword-based comment flags found._")
}
[void]$md.AppendLine()
[void]$md.AppendLine("## Vague / non-descriptive commit messages (heuristic - needs manual confirmation)")
[void]$md.AppendLine()
if ($vagueCommitHits.Count -eq 0) {
    [void]$md.AppendLine("_No vague commit messages detected._")
} else {
    [void]$md.AppendLine("| PR | Commit | Message |")
    [void]$md.AppendLine("|---|---|---|")
    foreach ($hit in $vagueCommitHits) {
        $shortSha = if ($hit.commitId -and $hit.commitId.Length -gt 8) { $hit.commitId.Substring(0, 8) } else { $hit.commitId }
        [void]$md.AppendLine("| #$($hit.pullRequestId) - $($hit.title) | $shortSha | `"$($hit.message)`" |")
    }
}
[void]$md.AppendLine()
[void]$md.AppendLine("## Self-approval / no-approval-merge flags (needs manual confirmation)")
[void]$md.AppendLine()
$selfApprovalPrs = @($prResults | Where-Object { $_.selfApprovalFlag })
$noApprovalPrs = @($prResults | Where-Object { $_.noApprovalMergedFlag })
if ($selfApprovalPrs.Count -eq 0 -and $noApprovalPrs.Count -eq 0) {
    [void]$md.AppendLine("_No self-approval or no-approval-merge flags detected._")
} else {
    foreach ($pr in $selfApprovalPrs) {
        [void]$md.AppendLine("- **Self-approved**: PR #$($pr.pullRequestId) - $($pr.title) - $person appears among the reviewers with an approving vote on their own PR.")
    }
    foreach ($pr in $noApprovalPrs) {
        [void]$md.AppendLine("- **Merged without approval**: PR #$($pr.pullRequestId) - $($pr.title) - merged to master with $($pr.reviewersCount) reviewer(s) assigned but 0 approvals.")
    }
}
[void]$md.AppendLine()
[void]$md.AppendLine("## Confirmed talking points")
[void]$md.AppendLine()
[void]$md.AppendLine("_To be filled in by the agent after manually reviewing the candidate flags above and the flagged PR descriptions/work-item links, per RUNBOOK.md Step 4._")

$md.ToString() | Set-Content -Path $mdPath -Encoding UTF8

Write-Host "Summary JSON: $summaryPath"
Write-Host "Markdown report: $mdPath"
Write-Host ("PRs raised: {0}, Merged to master: {1} ({2}%), Quality score: {3}" -f $totalRaised, $mergedToMaster, $summary.mergeRatePercent.ToString([System.Globalization.CultureInfo]::InvariantCulture), $qualityScore.ToString([System.Globalization.CultureInfo]::InvariantCulture))
