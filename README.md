# TeamKpiTool

**Turn a month of pull-request history into evidence you can actually talk about in a 1-1.**

Most engineering 1-1s run on memory. Memory is biased toward the last two weeks, the
loudest incident, and whoever sits closest to you. This tool replaces "I feel like your
PRs have been a bit rough lately" with "here are the four PRs, here is the reviewer's
own comment, here is how it compares to last month."

It is a **coaching-prep tool, not a surveillance tool.** See [Scope and limits](#scope-and-limits).

---

## The interesting bit: deterministic math, AI judgment, kept apart

The design principle is that an LLM should never be asked to count, and a regex should
never be asked to judge tone.

```
   ┌────────────────────┐   1. fetch      ┌──────────────────────┐
   │  AI agent          │ ───────────────>│  Azure DevOps        │
   │  (Copilot CLI /    │ <─────────────── │  PRs, threads,       │
   │   Claude Code)     │    PR data      │  commits, diffs      │
   └─────────┬──────────┘                 └──────────────────────┘
             │ 2. assemble
             v
      kpi-raw/<person>-<month>.json          <- one flat, auditable snapshot
             │
             │ 3. run
             v
   ┌────────────────────────────┐
   │ Get-TeamKpiReport.ps1      │           <- 100% deterministic
   │  counts, rates, medians,   │              same input = same numbers,
   │  trends, quality score,    │              no model, no network, no PAT
   │  heuristic candidate flags │
   └─────────┬──────────────────┘
             │ 4. emit
             v
   kpi-reports/  <person>-<month>.html      <- the report you present
                 <person>-<month>-prs.csv   <- one row per PR
                 kpi-ledger.csv             <- one row per person-month, accumulating
                 <person>-<month>-summary.json
             │
             │ 5. review
             v
   ┌────────────────────┐
   │  AI agent          │  reads each flagged comment/commit *in context*,
   │  second pass       │  confirms, relabels or discards it, and writes
   └─────────┬──────────┘  "Confirmed talking points"
             │
             v
        Human runs the 1-1                   <- the only step that matters
```

**Why the split matters.** The numbers have to be reproducible — if a merge rate changes
because a model was feeling creative, the whole report is worthless in a performance
conversation. So the script owns every number. But keyword matching is hopeless at the
part that actually needs judgment: `"add a null check"` in a review comment might be a
recurring blind spot or a one-off on genuinely subtle code. So the script only ever emits
**candidates**, and the agent's second pass confirms or discards each one with a written
rationale.

The script never calls Azure DevOps and holds no credentials. Data collection rides on
the agent's existing, already-authorized ADO connection — no PAT to mint, rotate, or leak.

---

## What it measures

| Group | Metrics |
|---|---|
| **Throughput** | PRs raised, merged to master, merge rate, abandon rate |
| **Speed** | Avg + median cycle time (creation → close), in hours |
| **Review engagement** | Review threads, thread-resolution rate, comment volume per PR, distinct reviewers engaged |
| **PR hygiene** | Missing work-item link, incomplete/stale description |
| **Size & risk** | Files changed, lines added/deleted, avg churn per PR, large-PR flags (churn ≥ 400 or files ≥ 15, both tunable) |
| **Governance** | Author self-approval detection, merged-to-master-with-zero-approvals detection |
| **Commit hygiene** | Vague commit-message detection (`wip`, `fixed pr comments`, `.`, …), rework commits landed after the first review comment |
| **Comment patterns** | Candidate flags across naming convention, null checks, misleading description, stale/TODO comments |
| **Composite** | 0-100 quality score, plus automatic month-over-month trend deltas once two months exist |

### The composite score

```
score = 0.35 × merge rate
      + 0.25 × thread-resolution rate
      + 0.25 × hygiene   (100 − mean of: no-work-item, stale-description,
      +                    comment-flag, large-PR and vague-commit rates)
      + 0.15 × governance (100 − 2×self-approval rate − no-approval-merge rate)
```

Self-approval is weighted double because it is a process red flag, not a style nit.

**Treat this number as a conversation starter, never as a rating.** It is arbitrary by
construction — the weights are one person's opinion, and every input is gameable by
anyone who knows the formula. It is in the report so that a *trend* is visible, not so
that two people can be ranked against each other.

---

## Quick start

Requirements: **PowerShell 7+** (Windows PowerShell 5.1 also works — no PS7-only syntax),
plus an AI CLI with an Azure DevOps integration for the data-collection step
(built with GitHub Copilot CLI; Claude Code with an ADO MCP server works the same way).

```powershell
git clone https://github.com/AjinkyaCSharp/pr-signals.git
cd pr-signals

# Verify the math works on synthetic data — no ADO access needed:
.\Get-TeamKpiReport.ps1 -InputJsonPath .\samples\sample-input.json -OutputDir .\kpi-reports
```

Expected:

```
HTML report:  .\kpi-reports\jane.doe@example.com-2025-07.html
PR CSV:       .\kpi-reports\jane.doe@example.com-2025-07-prs.csv
Ledger CSV:   .\kpi-reports\kpi-ledger.csv
Summary JSON: .\kpi-reports\jane.doe@example.com-2025-07-summary.json
PRs raised: 3, Merged to master: 2 (66.7%), Quality score: 57.8
```

### The three outputs

Every run writes the same shapes, so reports are comparable across people and months.

| File | Format | For |
|---|---|---|
| `<person>-<month>.html` | self-contained HTML | **the meeting.** Open it or project it. Headline tiles, trend deltas vs the person's own last month, the PR table, and the candidate flags kept visually separate from the confirmed talking points. Prints cleanly if you want a handout. |
| `<person>-<month>-prs.csv` | CSV, one row per PR | **the detail.** Fixed 29 columns, so PRs from any person or month stack in one sheet. |
| `kpi-ledger.csv` | CSV, one row per person-month | **record keeping.** Accumulates across every run and updates in place when a month is re-run, so it's the file to pivot on for history. |
| `<person>-<month>-summary.json` | JSON | machine-readable, and what the next month reads to compute its trend column. Keep it. |

The confirmed talking points from the manual review pass go in via
`-TalkingPointsPath <file>`; re-run the script and they're embedded at the top of
the HTML, above the unconfirmed flags.

---

## A whole team, in one command

A scrum master doesn't want to run this eleven times. Put the roster in
`teams.json` once:

```powershell
copy teams.example.json teams.json    # then fill in your team; it's gitignored
```

```json
{
  "teams": [
    { "name": "alpha", "displayName": "Team Alpha",
      "members": [
        { "email": "first.member@example.com",  "displayName": "First Member" },
        { "email": "second.member@example.com", "displayName": "Second Member" }
      ] }
  ]
}
```

Then name the team and the window:

```powershell
.\Get-TeamRollupReport.ps1 -TeamName alpha -Period quarter -EndMonth 2026-07
```

That runs the individual report for every member and every month in the period,
then aggregates the lot into a team report. `-Period` takes **`month`**,
**`quarter`** (3), **`halfyear`** (6) or **`year`** (12); `-EndMonth` is the last
month of the range, defaulting to the current one. `-SkipMemberReports`
re-aggregates already-collected data instantly, without touching Azure DevOps —
so collect once, then slice the same months as a month, a quarter and a year.

📄 [**See an example team report**](samples/example-team-report.html)

### What the team report adds

- **Team performance** — delivery, review culture, PR and commit hygiene, and
  governance risk, each with a delta against the *previous equal-length period*
  (a quarter compares to the quarter before it)
- **Workload spread** — lowest / median / highest PRs per member, and the share
  held by the busiest member. This is a planning signal: it answers "is everything
  concentrated in one person, and what happens when they're away", not "who is best"
- **Per member** — one row each, listed **alphabetically on purpose**; sorting it
  by PR count would make it a ranking, and PR counts track ticket sizing
- **Governance flags across the team** — every self-approval and no-approval merge
  in one table, which is a process problem to fix rather than a person to blame
- **Coverage** — member-months with no collected data, counted as *missing* rather
  than as zero, because "raised no PRs" and "we never fetched it" are different facts

Team rates are recomputed from pooled counts, never averaged from the members'
own rates — averaging percentages would weight someone with 2 PRs the same as
someone with 20. Cycle-time medians come from the full pooled list of PRs.

Outputs: `<team>-<period>-team.html`, `<team>-<period>-members.csv` (one row per
member per month), `<team>-<period>-prs.csv`, and `team-ledger.csv` accumulating
one row per team-period.

📋 [**PROMPTS.md**](PROMPTS.md) has the copy-paste prompts — team for a month, a
quarter, six months or a year, plus the single-person flow.

Then, for a real run, open your agent CLI in this folder and ask:

> Run the team KPI report for `<email>` for `2026-07`, following RUNBOOK.md in this
> folder — project `<Project>`, repo `<Repo>`, target branch master. Save the raw JSON
> and report into kpi-raw / kpi-reports.

- 📄 [**See a full example report**](samples/example-report.html) — real output, generated from
  [`samples/sample-input.json`](samples/sample-input.json), alongside the matching
  [`example-prs.csv`](samples/example-prs.csv) and [`example-ledger.csv`](samples/example-ledger.csv)
- 🔧 [SETUP-GUIDE.md](SETUP-GUIDE.md) — prerequisites and one-time setup
- 📖 [RUNBOOK.md](RUNBOOK.md) — the exact ADO queries the agent runs, and the manual
  confirmation pass

### Tuning

```powershell
.\Get-TeamKpiReport.ps1 -InputJsonPath .\kpi-raw\in.json -OutputDir .\kpi-reports `
    -DescriptionMinLength 20 `     # below this = "stale/incomplete description"
    -LargeChurnThreshold 400 `     # added+deleted lines that make a PR "large"
    -LargeFileCountThreshold 15 `  # files changed that make a PR "large"
    -VagueCommitMinLength 10       # commit subject shorter than this = vague
```

### Porting to GitHub or GitLab

The script only reads the JSON schema documented in its header comment — it has no idea
what a "PR" is beyond that shape. Point step 1-2 of [RUNBOOK.md](RUNBOOK.md) at
`gh pr list` / `gh api`, map the fields, and everything downstream works unchanged.

---

## Scope and limits

Read this part before you run it on a human being.

- **This is 1-1 preparation, not a performance rating.** Ship dates, on-call load,
  mentoring, design work, incident response, and the entire question of whether the
  person is working on the *right* thing are all invisible here. A report that says
  someone raised 3 PRs says nothing about their month.
- **Every flag is a candidate, not a verdict.** Keyword matching cannot tell a real
  pattern from a coincidence. If you skip the manual confirmation pass, you will walk
  into a 1-1 with false accusations. This is the single most important step in the flow.
- **Never rank people with it.** PR counts across different people measure ticket sizing,
  not ability. The trend column exists so a person can be compared to their own last
  month — nothing else.
- **Show the person the report.** The whole point of gathering evidence is that the other
  person can look at it and disagree. Data used to prosecute rather than discuss is worse
  than the memory-based 1-1 it replaced.
- **The data is sensitive.** `kpi-raw/` and `kpi-reports/` are gitignored wholesale, and
  should stay that way — they contain colleagues' names, real review comments and scores.
  Check your local labor law and works-council rules before collecting this at all; in
  parts of the EU, systematic individual productivity metrics are a co-determination
  matter.

---

## License

MIT — see [LICENSE](LICENSE).
