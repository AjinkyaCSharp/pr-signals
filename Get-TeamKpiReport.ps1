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
$htmlPath    = Join-Path $OutputDir "$safePerson-$monthYear.html"
$prsCsvPath  = Join-Path $OutputDir "$safePerson-$monthYear-prs.csv"
$ledgerPath  = Join-Path $OutputDir 'kpi-ledger.csv'

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

$selfApprovalPrs = @($prResults | Where-Object { $_.selfApprovalFlag })
$noApprovalPrs = @($prResults | Where-Object { $_.noApprovalMergedFlag })

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
        cycleTimeHours     = $pr.cycleTimeHours
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
        selfApprovalFlag   = $pr.selfApprovalFlag
        noApprovalMergedFlag = $pr.noApprovalMergedFlag
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
    'person', 'monthYear', 'generatedAtUtc', 'qualityScore',
    'totalRaised', 'mergedToMaster', 'mergeRatePercent', 'abandonedCount', 'abandonRatePercent',
    'avgCycleTimeHours', 'medianCycleTimeHours',
    'totalThreads', 'resolvedThreads', 'threadResolutionPercent',
    'totalComments', 'avgCommentsPerPr', 'reviewerDiversityCount',
    'noWorkItemCount', 'noWorkItemRatePercent',
    'descriptionFlagCount', 'descriptionFlagRatePercent', 'commentFlagRatePercent',
    'totalLinesAdded', 'totalLinesDeleted', 'totalFilesChanged', 'avgChurnPerPr',
    'largePrCount', 'largePrRatePercent',
    'selfApprovalCount', 'selfApprovalRatePercent',
    'noApprovalMergedCount', 'noApprovalMergedRatePercent',
    'totalCommits', 'vagueCommitCount', 'vagueCommitRatePercent', 'avgReworkCommitsPerPr'
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

# ---- headline tiles ----
$tiles = @(
    (New-Tile -Label 'PRs raised' -Value "$totalRaised" `
        -DeltaHtml (New-DeltaHtml -Current $totalRaised -Previous $previousSummary.totalRaised -HigherIsBetter)),
    (New-Tile -Label 'Merged to master' -Value "$mergedToMaster" -Note "$($summary.mergeRatePercent)% of PRs raised" `
        -DeltaHtml (New-DeltaHtml -Current $summary.mergeRatePercent -Previous $previousSummary.mergeRatePercent -HigherIsBetter -Suffix 'pp')),
    (New-Tile -Label 'Median cycle time' -Value (Format-Metric $medianCycleTimeHours ' h') -Note (Format-Metric $avgCycleTimeHours ' h average' 'n/a') `
        -DeltaHtml (New-DeltaHtml -Current $avgCycleTimeHours -Previous $previousSummary.avgCycleTimeHours -Suffix 'h')),
    (New-Tile -Label 'Threads resolved' -Value (Format-Metric $threadResolutionPercent '%') -Note "$resolvedThreads of $totalThreads threads" `
        -DeltaHtml (New-DeltaHtml -Current $threadResolutionPercent -Previous $previousSummary.threadResolutionPercent -HigherIsBetter -Suffix 'pp')),
    (New-Tile -Label 'Review comments' -Value "$totalComments" -Note "avg $avgCommentsPerPr per PR" `
        -DeltaHtml (New-DeltaHtml -Current $avgCommentsPerPr -Previous $previousSummary.avgCommentsPerPr -Suffix '/PR')),
    (New-Tile -Label 'Reviewers engaged' -Value "$reviewerDiversityCount" -Note 'distinct people who commented')
) -join "`n"

# ---- grouped metric tables ----
$hygieneRows = @(
    (New-MetricRow 'Missing work item link' "$noWorkItemCount ($noWorkItemRatePercent%)" (New-DeltaHtml -Current $noWorkItemRatePercent -Previous $previousSummary.noWorkItemRatePercent -Suffix 'pp')),
    (New-MetricRow 'Incomplete / stale description' "$descriptionFlagCount ($descriptionFlagRatePercent%)" (New-DeltaHtml -Current $descriptionFlagRatePercent -Previous $previousSummary.descriptionFlagRatePercent -Suffix 'pp')),
    (New-MetricRow 'PRs with any comment flag' "$anyCommentFlagCount ($commentFlagRatePercent%)" (New-DeltaHtml -Current $commentFlagRatePercent -Previous $previousSummary.commentFlagRatePercent -Suffix 'pp')),
    (New-MetricRow 'Abandoned PRs' "$abandonedCount ($abandonRatePercent%)" '')
) -join "`n"

$sizeRows = @(
    (New-MetricRow 'Lines added / deleted' "+$totalLinesAdded / -$totalLinesDeleted" ''),
    (New-MetricRow 'Files changed' "$totalFilesChanged" ''),
    (New-MetricRow 'Avg churn per PR' "$avgChurnPerPr" (New-DeltaHtml -Current $avgChurnPerPr -Previous $previousSummary.avgChurnPerPr)),
    (New-MetricRow "Large PRs (churn >= $LargeChurnThreshold or files >= $LargeFileCountThreshold)" "$largePrCount ($largePrRatePercent%)" (New-DeltaHtml -Current $largePrRatePercent -Previous $previousSummary.largePrRatePercent -Suffix 'pp'))
) -join "`n"

$govRows = @(
    (New-MetricRow 'Author approved their own PR' "$selfApprovalCount ($selfApprovalRatePercent%)" (New-DeltaHtml -Current $selfApprovalRatePercent -Previous $previousSummary.selfApprovalRatePercent -Suffix 'pp')),
    (New-MetricRow 'Merged to master with no approving reviewer' "$noApprovalMergedCount ($noApprovalMergedRatePercent% of merges)" (New-DeltaHtml -Current $noApprovalMergedRatePercent -Previous $previousSummary.noApprovalMergedRatePercent -Suffix 'pp'))
) -join "`n"

$commitRows = @(
    (New-MetricRow 'Total commits' "$totalCommits" ''),
    (New-MetricRow 'Vague / non-descriptive messages' "$vagueCommitCount ($vagueCommitRatePercent%)" (New-DeltaHtml -Current $vagueCommitRatePercent -Previous $previousSummary.vagueCommitRatePercent -Suffix 'pp')),
    (New-MetricRow 'Avg rework commits after first review comment' (Format-Metric $avgReworkCommitsPerPr '' 'n/a (no comment timestamps supplied)') (New-DeltaHtml -Current $avgReworkCommitsPerPr -Previous $previousSummary.avgReworkCommitsPerPr))
) -join "`n"

$categoryRows = (@(foreach ($cat in $categoryTotals.Keys) {
    New-MetricRow $cat "$($categoryTotals[$cat])" ''
}) -join "`n")

# ---- per-PR table ----
$prRows = (@(foreach ($pr in $prResults) {
    $titleText = ConvertTo-HtmlText $pr.title
    $titleCell = if ($pr.url) { '<a href="' + (ConvertTo-HtmlText $pr.url) + '">' + $titleText + '</a>' } else { $titleText }
    $chips = ''
    if ($pr.descriptionFlag)      { $chips += (New-Chip 'warning'  'stale description') }
    if ($pr.noWorkItemFlag)       { $chips += (New-Chip 'warning'  'no work item') }
    if ($pr.largePrFlag)          { $chips += (New-Chip 'warning'  'large PR') }
    if ($pr.vagueCommitCount -gt 0) { $chips += (New-Chip 'serious' "$($pr.vagueCommitCount) vague commits") }
    if ($pr.selfApprovalFlag)     { $chips += (New-Chip 'critical' 'self-approved') }
    if ($pr.noApprovalMergedFlag) { $chips += (New-Chip 'critical' 'no approval') }
    # Flags ride under the title rather than in a far-right column: in a wide table
    # that column lands off-screen, which hides the one thing worth reading.
    $chipLine = if ($chips) { '<span class="chips">' + $chips + '</span>' } else { '' }

    $cycle  = if ($null -ne $pr.cycleTimeHours) { "$($pr.cycleTimeHours)" } else { 'n/a' }
    $rework = if ($null -ne $pr.reworkCommitCount) { "$($pr.reworkCommitCount)" } else { 'n/a' }
    $merged = if ($pr.mergedToMaster) { 'yes' } else { 'no' }

    '<tr>' +
    '<td class="num">' + $pr.pullRequestId + '</td>' +
    '<td class="title">' + $titleCell + '<span class="sub">' + (ConvertTo-HtmlText $pr.targetRefName) + '</span>' + $chipLine + '</td>' +
    '<td>' + (ConvertTo-HtmlText $pr.status) + '</td>' +
    '<td>' + $merged + '</td>' +
    '<td class="num">' + $cycle + '</td>' +
    '<td class="num">' + $pr.commentCount + ' / ' + $pr.threadCount + '</td>' +
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
    $card = '<article class="card"><h3>PR #' + $pr.pullRequestId + ' &mdash; ' + (ConvertTo-HtmlText $pr.title) + '</h3><ul>'
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

# ---- governance flags ----
$govFlags = (@(
    foreach ($pr in $selfApprovalPrs) {
        '<li>' + (New-Chip 'critical' 'self-approved') + ' PR #' + $pr.pullRequestId + ' &mdash; ' +
        (ConvertTo-HtmlText $pr.title) + '. ' + (ConvertTo-HtmlText $person) +
        ' appears among the reviewers with an approving vote on their own PR.</li>'
    }
    foreach ($pr in $noApprovalPrs) {
        '<li>' + (New-Chip 'critical' 'no approval') + ' PR #' + $pr.pullRequestId + ' &mdash; ' +
        (ConvertTo-HtmlText $pr.title) + '. Merged to master with ' + $pr.reviewersCount +
        ' reviewer(s) assigned but 0 approvals.</li>'
    }
) -join "`n")
$govSection = if (-not $govFlags) {
    '<p class="empty">No self-approval or no-approval-merge flags detected.</p>'
} else {
    '<ul class="flag-list">' + $govFlags + '</ul>'
}

# ---- confirmed talking points (written by the agent, per RUNBOOK Step 4) ----
$talkingPoints = '<p class="empty">Not yet written. After the manual review pass (RUNBOOK.md Step 4), save the confirmed points to a text file and re-run with <code>-TalkingPointsPath</code>.</p>'
if ($TalkingPointsPath -and (Test-Path $TalkingPointsPath)) {
    $tpRaw = Get-Content -Raw -Path $TalkingPointsPath
    $talkingPoints = '<pre class="talking-points">' + (ConvertTo-HtmlText $tpRaw) + '</pre>'
}

$trendNote = if ($previousSummary) {
    'Trends compare against ' + (ConvertTo-HtmlText "$($previousSummary.monthYear)") + ', the same person.'
} else {
    'No prior month found in this folder, so no trends yet. They appear once a second month has been generated for this person.'
}

$generatedLocal = (Get-Date).ToString('yyyy-MM-dd HH:mm')

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
    <p class="eyebrow">PR / KPI report</p>
    <h1>{{PERSON}}</h1>
    <p class="subject">{{MONTH}} &middot; pull requests raised in this month</p>
    <p class="stamp">Generated {{GENERATED}} &middot; {{TREND_NOTE}}</p>
  </header>

  <div class="hero">
    <p class="hero-value">{{SCORE}}</p>
    <div>
      <p class="hero-label">Composite quality score, out of 100</p>
      {{SCORE_DELTA}}
    </div>
    <p class="hero-note">A conversation starter, not a rating. The weights are one team's opinion and every input is gameable by anyone who knows the formula. Read the trend against this person's own last month; never rank two people with it.</p>
  </div>

  <section>
    <h2>Headline</h2>
    <div class="tiles">
      {{TILES}}
    </div>
  </section>

  <section class="grid-2">
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
      <h2>Review governance</h2>
      <table class="metrics"><tbody>
        {{GOV_ROWS}}
      </tbody></table>
    </div>
    <div>
      <h2>Commit hygiene</h2>
      <table class="metrics"><tbody>
        {{COMMIT_ROWS}}
      </tbody></table>
    </div>
  </section>

  <section>
    <h2>Pull requests</h2>
    <div class="scroll">
      <table>
        <thead><tr>
          <th>PR</th><th>Title &amp; flags</th><th>Status</th><th>Merged</th><th>Cycle h</th>
          <th>Comments / threads</th><th>Files</th><th>Lines</th><th>Approvals</th>
          <th>Commits</th><th>Rework</th>
        </tr></thead>
        <tbody>
          {{PR_ROWS}}
        </tbody>
      </table>
    </div>
  </section>

  <section>
    <h2>Confirmed talking points</h2>
    {{TALKING_POINTS}}
  </section>

  <section>
    <h2>Candidate flags &mdash; not yet confirmed</h2>
    <p class="callout">Everything below this line is keyword matching, not judgment. Read each one in its original context before raising it: a comment saying "add a null check" may be a recurring blind spot or a one-off on genuinely subtle code, and the script cannot tell those apart. Discard the false positives before the meeting.</p>

    <h3>Review comments</h3>
    {{FLAG_CARDS}}

    <h3>Vague / non-descriptive commit messages</h3>
    {{VAGUE_SECTION}}

    <h3>Self-approval and no-approval merges</h3>
    {{GOV_SECTION}}
  </section>

  <section>
    <h2>Comment-flag categories</h2>
    <table class="metrics"><tbody>
      {{CATEGORY_ROWS}}
    </tbody></table>
  </section>

  <footer class="report">
    <p><strong>Scope.</strong> This covers pull requests only. Mentoring, design work, on-call, incident response, and whether the person was working on the right thing at all are invisible here. A month with 3 PRs says nothing on its own.</p>
    <p><strong>Thresholds used.</strong> Large PR at churn &ge; {{LARGE_CHURN}} lines or &ge; {{LARGE_FILES}} files. Description flagged under {{DESC_MIN}} characters. Commit subject flagged as vague under {{VAGUE_MIN}} characters or matching the known-phrase list.</p>
    <p><strong>Handling.</strong> Contains real review comments about an identifiable person. Keep it out of shared drives and version control, and show the report to the person it describes.</p>
  </footer>

</div>
</body>
</html>
'@

$html = $htmlTemplate.
    Replace('{{STYLE}}',         (Get-KpiReportCss)).
    Replace('{{PERSON}}',        (ConvertTo-HtmlText $person)).
    Replace('{{MONTH}}',         (ConvertTo-HtmlText $monthYear)).
    Replace('{{GENERATED}}',     (ConvertTo-HtmlText $generatedLocal)).
    Replace('{{TREND_NOTE}}',    $trendNote).
    Replace('{{SCORE}}',         "$qualityScore").
    Replace('{{SCORE_DELTA}}',   (New-DeltaHtml -Current $qualityScore -Previous $previousSummary.qualityScore -HigherIsBetter)).
    Replace('{{TILES}}',         $tiles).
    Replace('{{HYGIENE_ROWS}}',  $hygieneRows).
    Replace('{{SIZE_ROWS}}',     $sizeRows).
    Replace('{{GOV_ROWS}}',      $govRows).
    Replace('{{COMMIT_ROWS}}',   $commitRows).
    Replace('{{PR_ROWS}}',       $prRows).
    Replace('{{TALKING_POINTS}}', $talkingPoints).
    Replace('{{FLAG_CARDS}}',    $flagCards).
    Replace('{{VAGUE_SECTION}}', $vagueSection).
    Replace('{{GOV_SECTION}}',   $govSection).
    Replace('{{CATEGORY_ROWS}}', $categoryRows).
    Replace('{{LARGE_CHURN}}',   "$LargeChurnThreshold").
    Replace('{{LARGE_FILES}}',   "$LargeFileCountThreshold").
    Replace('{{DESC_MIN}}',      "$DescriptionMinLength").
    Replace('{{VAGUE_MIN}}',     "$VagueCommitMinLength")

$html | Set-Content -Path $htmlPath -Encoding UTF8

Write-Host "HTML report:  $htmlPath"
Write-Host "PR CSV:       $prsCsvPath"
Write-Host "Ledger CSV:   $ledgerPath"
Write-Host "Summary JSON: $summaryPath"
Write-Host ("PRs raised: {0}, Merged to master: {1} ({2}%), Quality score: {3}" -f $totalRaised, $mergedToMaster, $summary.mergeRatePercent, $qualityScore)
