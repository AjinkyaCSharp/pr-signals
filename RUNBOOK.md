# Runbook: Teammate PR/KPI Report

How to run this each month for a given `<email>` and `<month-year>` (e.g. `2025-07`).
Steps 1-2 are performed by the agent (me) via the `azure-devops-*` MCP tools already
available in this Copilot CLI session (they require ADO access that a standalone
script does not have). Step 3 runs `Get-TeamKpiReport.ps1` against the collected data.

Throughout, `<project>` and `<repo>` are your Azure DevOps project and repository
names — substitute your own (or let the agent take them from your prompt).

## Step 1 — Fetch PRs raised by the person in the month

```
azure-devops-repo_pull_request action=list
  project=<project>
  repositoryId=<repo>
  status=All
  createdByUser=<email>
  top=200 (paginate with skip if more)
```
Filter the returned PRs client-side to `creationDate` within `<month-year>`
(the ADO API has no native date-range filter on `list`).

## Step 2 — Enrich each in-range PR + pull comments, file changes, reviewers, commits

For every PR id found in Step 1:
```
azure-devops-repo_pull_request action=get
  project=<project>
  repositoryId=<repo>
  pullRequestId=<id>
  includeWorkItemRefs=true
```
The raw PR object returned by `action=get` includes a `reviewers` array (each with
`displayName`, `uniqueName`, `vote`) — carry this through as-is into the `reviewers`
field of the PR's JSON entry. Vote codes: `10`=Approved, `5`=Approved with
suggestions, `0`=No vote, `-5`=Waiting for author, `-10`=Rejected.

```
azure-devops-repo_pull_request_thread action=list
  project=<project>
  repositoryId=<repo>
  pullRequestId=<id>
```
For each returned thread:
```
azure-devops-repo_pull_request_thread action=list_comments
  repositoryId=<repo>
  pullRequestId=<id>
  threadId=<threadId>
```
Include each comment's `publishedDate` in the assembled JSON (needed for
rework-commit detection) alongside `id`, `author`, `content`.

For PR size/churn:
```
azure-devops-repo_pull_request action=get_changes
  repositoryId=<repo>
  pullRequestId=<id>
  includeDiffs=false        (file-level counts only are needed, keeps payload small)
```
Aggregate the returned file changes into `filesChangedCount` (number of files),
`linesAdded`, and `linesDeleted` (sum across all files) for the PR's JSON entry.

For commits (needed for vague-commit-message and rework-commit detection):
```
azure-devops-repo_search_commits
  project=<project>
  repository=<repo>
  author=<email>
  version=<PR's sourceRefName>
  versionType=Branch
  fromDate=<PR creationDate>
  toDate=<PR closedDate or now>
  top=100
```
Map each returned commit into `{ commitId, author, date, comment }` for the PR's
`commits` array. If the branch was deleted after merge and commits can't be found
this way, fall back to `azure-devops-repo_search_commits` with `commitIds` using
any commit IDs referenced by the PR's iterations/last-merge-commit, or omit the
`commits` field for that PR (the script treats it as zero commits, which is
noted as a data gap rather than a real KPI in that case).

Assemble everything into one JSON document matching the schema expected by
`Get-TeamKpiReport.ps1` (see header comment in that script) and save it to
`kpi-raw/<email>-<month-year>.json`.

## Step 3 — Run the script

```powershell
.\Get-TeamKpiReport.ps1 -InputJsonPath ".\kpi-raw\<email>-<month-year>.json" `
    -OutputDir ".\kpi-reports"
```

This produces:
- `kpi-reports/<email>-<month-year>-summary.json` — machine-readable metrics + flags
- `kpi-reports/<email>-<month-year>.md` — human-readable draft report

## Step 4 — Final review (agent, not the script)

The script's comment flags, vague-commit-message flags, and self-approval/
no-approval-merge flags are all **heuristics** — candidates only. Before handing
the report to the user, the agent:
- Reads each flagged thread's actual text and confirms/relabels it into one of the
  requested categories (or discards false positives), adding a one-line rationale.
- Reads each flagged commit message in context (diff/PR) and confirms whether it's
  genuinely non-descriptive or a reasonable shorthand for a small, obvious change.
- Confirms self-approval / no-approval-merge flags aren't due to missing reviewer
  data or a legitimate branch-policy bypass (e.g. hotfix process).

This final pass is appended to the Markdown report under "Confirmed talking points".
