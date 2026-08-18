# Team PR/KPI Report Tool — Setup Guide

This tool helps produce monthly, data-backed PR metrics for 1-1s: PRs raised, PRs
merged to `master`, flagged review-comment patterns (missing work item, stale
description, null-check nitpicks, naming-convention comments, misleading description,
etc.), plus deeper quantitative signals — PR cycle time (avg/median hours from
creation to close), review-thread resolution rate, comment volume and reviewer
diversity, PR size/churn (files/lines changed, large-PR flags), reviewer
self-approval and no-approval-merge detection, commit hygiene (vague/non-descriptive
commit message detection, rework-commit counts after the first review comment),
per-category flag-rate percentages, a composite 0-100 quality score, and automatic
month-over-month trend deltas (once two or more months exist in the same
`kpi-reports` folder) — for a given teammate + month.

## What's in this folder

| File | Purpose |
|---|---|
| `Get-TeamKpiReport.ps1` | PowerShell script that computes the KPIs/flags from a JSON data file, for **one person, one month**. Does the actual math/report-building. |
| `Get-TeamRollupReport.ps1` | Runs the above for **every member of a team** across a month/quarter/6 months/year, then aggregates it into a team report. |
| `KpiReportCommon.ps1` | Shared HTML helpers and the single stylesheet both reports render with. Not run directly. |
| `teams.example.json` | Placeholder roster. **Copy it to `teams.json`** and put your team's emails in that copy — `teams.json` is gitignored. |
| `PROMPTS.md` | Copy-paste prompts for the agent: one person, or a whole team over any period. |
| `RUNBOOK.md` | Step-by-step instructions for **how the data gets collected** from Azure DevOps and fed into the script. |
| `samples/sample-input.json` | A worked example input file — use it to sanity-check the script works on your machine before doing a real run. |
| `samples/example-report.html` | What the script produces from that sample input — open it in a browser. |
| `samples/example-prs.csv` | The per-PR CSV from the same run. |
| `samples/example-ledger.csv` | The accumulating person-month ledger from the same run. |
| `kpi-raw/` | Where collected raw data lands. **Gitignored** — real PR text and colleague identities. |
| `kpi-reports/` | Where reports land after you run the script. **Gitignored** — same reason. |

## Important — how this actually works

**This is not a fully self-running app.** `Get-TeamKpiReport.ps1` only does the
number-crunching; it does **not** call Azure DevOps itself. The data collection
(pulling PR lists, PR details, and comment threads from ADO) is done through
**GitHub Copilot CLI**, using its built-in Azure DevOps integration — because that's
what already has your ADO access wired up, without needing to manage a Personal
Access Token by hand.

So the real workflow each month is:
1. Open GitHub Copilot CLI (in this folder, or point it at this folder).
2. Ask it to run the KPI report for a specific person + month (see prompt below).
3. Copilot CLI fetches the ADO data, assembles the JSON, runs the script, and hands
   you back the HTML report — then you review the "candidate comment flags" it
   found and add your own judgment on anything more subtle before your 1-1.

## Prerequisites

1. **GitHub Copilot CLI** installed and signed in with access to your repository/org
   (the same access you already use day-to-day). Claude Code with an Azure DevOps MCP
   server works identically.
2. **Azure DevOps access** — Copilot CLI needs its Azure DevOps MCP integration
   configured so it can query PRs/threads. If you already use Copilot CLI against
   this ADO org for other tasks, this is already set up; if not, ask whoever
   administers your Copilot CLI setup to enable the Azure DevOps MCP server for
   your account.
3. **PowerShell 7+** (or Windows PowerShell 5.1 also works, the script uses no
   PS7-only syntax) — needed to run `Get-TeamKpiReport.ps1`.
4. Read access to the Azure DevOps project / repository you want to report on
   (`https://dev.azure.com/<your-org>/<project>`).

## One-time setup

1. Copy this whole folder to your machine, e.g. `C:\Tools\TeamKpiTool`.
2. Open a terminal in that folder and verify the script runs against the sample data:
   ```powershell
   .\Get-TeamKpiReport.ps1 -InputJsonPath ".\samples\sample-input.json" -OutputDir ".\kpi-reports"
   ```
   You should see output like:
   ```
   HTML report:  .\kpi-reports\jane.doe@example.com-2025-07.html
   PR CSV:       .\kpi-reports\jane.doe@example.com-2025-07-prs.csv
   Ledger CSV:   .\kpi-reports\kpi-ledger.csv
   Summary JSON: .\kpi-reports\jane.doe@example.com-2025-07-summary.json
   PRs raised: 3, Merged to master: 2 (66.7%), Quality score: 57.8
   ```
   Open the HTML file in a browser — that's the one you bring to the meeting.
   If that works, the script side is good to go.
3. Open `RUNBOOK.md` and skim it once so you know what Copilot CLI will be doing
   under the hood.
4. If you're a scrum master reporting on a whole team, copy the roster placeholder
   and fill in your team:
   ```powershell
   copy teams.example.json teams.json
   ```
   Add one entry per member (`email` is the only required field). `teams.json` is
   gitignored because it holds colleague email addresses — keep it that way.
   Then a whole team, for any period, is one command:
   ```powershell
   .\Get-TeamRollupReport.ps1 -TeamName alpha -Period quarter -EndMonth 2026-07
   ```
   `-Period` accepts `month`, `quarter`, `halfyear` or `year`. See `PROMPTS.md`
   for the agent prompts that collect the data first.

## Running it for a real teammate/month

Open GitHub Copilot CLI in this folder and ask something like:

> "Run the team KPI report for `<email>` for `<month-year>` (e.g. 2026-07), following
> RUNBOOK.md in this folder — project `<project>`, repo `<repo>`, target branch master.
> Save the raw JSON and report in this folder's kpi-raw / kpi-reports subfolders."

Copilot CLI will then:
- List that person's PRs created in that month (any target branch) via Azure DevOps.
- Pull full PR details (description, linked work items, target branch, status,
  reviewers + vote), all comment threads (with timestamps), file-change/line-churn
  summaries, and commits (author + message) for each PR.
- Save the collected data as `kpi-raw/<email>-<month-year>.json`.
- Run `Get-TeamKpiReport.ps1` against it to get the KPI counts, size/churn, commit
  hygiene, and self-approval metrics, plus heuristic flags.
- Manually read the flagged/candidate comments and commit messages, and produce a
  final "Confirmed talking points" section with reviewer quotes and links, appended
  into the HTML report via `-TalkingPointsPath` — this last step needs the AI's
  judgment, not just the script, since real comment/commit-message classification
  isn't reliable from keyword matching alone.

Your report will be at `kpi-reports/<email>-<month-year>.html`, ready to bring to the
1-1. The matching `-prs.csv` and the accumulating `kpi-ledger.csv` land beside it for
record keeping.

## Notes

- No data leaves your machine except normal ADO API calls that Copilot CLI already
  makes on your behalf — nothing is sent to third parties beyond that.
- `kpi-raw/*.json` and `kpi-reports/*` contain real PR/comment text and per-person
  scores for teammates. Both folders are in `.gitignore` for exactly that reason —
  keep them there, and treat the contents like any other performance-review-adjacent
  data (never push them anywhere public, never share outside the team). See the
  "Scope and limits" section of `README.md` before running this on a colleague.
- The categories `Get-TeamKpiReport.ps1` heuristically pre-tags (naming convention,
  null check, misleading description, stale/incomplete comment, vague commit message,
  self-approval, no-approval-merge) are just a first pass — expect most real flags to
  come from Copilot CLI's manual read-through of comments and commits, not the
  script's keyword/pattern matches.
- To adjust what counts as "raised" or "merged to master" (e.g. a different branch
  name), edit the `-InputJsonPath`/`targetMasterBranch` field in the JSON, or ask
  Copilot CLI to scope it to a different repo/branch.
