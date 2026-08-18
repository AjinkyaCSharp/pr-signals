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
- `kpi-reports/<email>-<month-year>.html` — the report to present in the 1-1
- `kpi-reports/<email>-<month-year>-prs.csv` — one row per PR, fixed columns
- `kpi-reports/kpi-ledger.csv` — one row per person-month, updated in place on re-runs
- `kpi-reports/<email>-<month-year>-summary.json` — machine-readable metrics + flags,
  and the file next month reads to compute its trend column

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

Write this final pass to `kpi-reports/<email>-<month-year>-talking-points.md` as plain
text, then re-run Step 3 with `-TalkingPointsPath` pointing at it:

```powershell
.\Get-TeamKpiReport.ps1 -InputJsonPath ".\kpi-raw\<email>-<month-year>.json" `
    -OutputDir ".\kpi-reports" `
    -TalkingPointsPath ".\kpi-reports\<email>-<month-year>-talking-points.md"
```

The text is embedded in the HTML report's "Confirmed talking points" section, which
sits **above** the unconfirmed candidate flags — so the thing that was actually
verified is what the reader meets first.

## Step 5 — A whole team, over a month / quarter / 6 months / year

Steps 1-2 are per person, per month. To cover a team, repeat them for every member
on the roster and every month in the period, then let the rollup script do the rest.

1. Read the member list from `teams.json` (copy `teams.example.json` if it doesn't
   exist yet). Match `-TeamName` case-insensitively against `name` / `displayName`.
2. Work out the months in the period: `month` = 1, `quarter` = 3, `halfyear` = 6,
   `year` = 12, counting back from and including `-EndMonth`.
3. For each member × month, run steps 1-2 above and save to
   `kpi-raw/<email>-<month>.json`. **Skip any that already exist** — the ADO fetch
   is the slow part, and past months don't change.
4. Run the rollup, which invokes `Get-TeamKpiReport.ps1` for every member+month
   that has raw data and then aggregates:

```powershell
.\Get-TeamRollupReport.ps1 -TeamName <team> -Period quarter -EndMonth 2026-07
```

Add `-SkipMemberReports` to re-aggregate existing data without re-running the
per-person reports. Member-months with no raw data are reported as **coverage
gaps**, not as zero — report those back to the user rather than letting a missing
fetch read as "this person raised nothing".

Then do Step 4 above for each member individually; the team report deliberately
carries no candidate flags, because confirming them is per-person work.

See `PROMPTS.md` for the ready-made prompts.
