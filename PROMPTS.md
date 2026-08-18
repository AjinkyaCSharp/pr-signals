# Prompts

Copy-paste prompts for the agent CLI (GitHub Copilot CLI, or Claude Code with an
Azure DevOps MCP server). Open the agent **in this folder** so it can see
`RUNBOOK.md`, `teams.json` and the scripts.

Replace anything in `<angle brackets>`. Everything else can be pasted as-is.

---

## 1. Whole team, one month

The main one for a scrum master. One command covers every member on the roster.

> Run the team KPI report for team **`<team-name>`** for **`<yyyy-MM>`**.
>
> Read the roster from `teams.json` to get the member list. For every member and
> every month in the period, follow `RUNBOOK.md` steps 1-2 to collect the raw PR
> data from Azure DevOps and save it to `kpi-raw/<email>-<month>.json` — skip any
> member+month whose raw file already exists. Then run:
>
> ```powershell
> .\Get-TeamRollupReport.ps1 -TeamName <team-name> -Period month -EndMonth <yyyy-MM>
> ```
>
> Finally do the RUNBOOK step 4 review pass for each member: read every flagged
> comment and commit in context, discard the false positives, and write the
> confirmed points to `kpi-reports/<email>-<month>-talking-points.md`. Re-run
> `Get-TeamKpiReport.ps1` for those members with `-TalkingPointsPath` so the
> confirmed points land in their HTML report.
>
> Tell me which member+month combinations had no data.

---

## 2. Whole team, longer period

Same as above, with `-Period` swapped. `-EndMonth` is the **last** month of the range.

| I want | Period | Command |
|---|---|---|
| One month | `month` | `-Period month -EndMonth 2026-07` → July only |
| A quarter | `quarter` | `-Period quarter -EndMonth 2026-07` → May, June, July |
| Half a year | `halfyear` | `-Period halfyear -EndMonth 2026-07` → Feb–July |
| A full year | `year` | `-Period year -EndMonth 2026-07` → Aug 2025 – July 2026 |

> Run the **quarterly** team KPI report for team **`<team-name>`**, for the quarter
> ending **`<yyyy-MM>`**.
>
> Read the roster from `teams.json`. For every member and every month in that
> quarter, follow `RUNBOOK.md` steps 1-2 and save the raw data to
> `kpi-raw/<email>-<month>.json`, skipping any that already exist. Then run:
>
> ```powershell
> .\Get-TeamRollupReport.ps1 -TeamName <team-name> -Period quarter -EndMonth <yyyy-MM>
> ```
>
> Summarise for me: what moved versus the previous quarter, which governance flags
> appeared, and where the coverage gaps are. Do not rank the team members.

For a 6-month or annual review, swap `quarter` for `halfyear` or `year` in both the
prompt and the command.

---

## 3. Re-aggregate without re-fetching

Once the raw data is collected, this is instant and hits no APIs — useful for
looking at the same months through a different window.

> Re-run the team rollup for **`<team-name>`** for the last **`<quarter|halfyear|year>`**
> ending **`<yyyy-MM>`** using the data already collected, without fetching anything
> from Azure DevOps:
>
> ```powershell
> .\Get-TeamRollupReport.ps1 -TeamName <team-name> -Period <period> -EndMonth <yyyy-MM> -SkipMemberReports
> ```

---

## 4. One person, one month

The original single-person flow, for a 1-1 with one teammate.

> Run the KPI report for **`<email>`** for **`<yyyy-MM>`**, following `RUNBOOK.md`
> in this folder — project `<project>`, repo `<repo>`, target branch master. Save
> the raw JSON to `kpi-raw/` and the report to `kpi-reports/`.
>
> Then do the step 4 review pass: read each flagged comment and commit in context,
> confirm or discard it with a one-line reason, write the confirmed points to
> `kpi-reports/<email>-<yyyy-MM>-talking-points.md`, and re-run the script with
> `-TalkingPointsPath` pointing at that file.

---

## 5. Prep for a specific 1-1

When the report already exists and you want help using it.

> Read `kpi-reports/<email>-<yyyy-MM>.html` and the same person's previous month.
> Give me three things to open the 1-1 with: one genuine strength backed by a
> specific PR, one pattern worth working on with the evidence for it, and one thing
> that looks odd but that I should ask about rather than assert. Quote the reviewer
> comments verbatim and link the PRs. Skip anything you can't back with a specific PR.

---

## Notes

- **Add the team to `teams.json` first.** Copy `teams.example.json`, fill in the
  member emails, keep it out of version control (it's gitignored).
- **The rollup runs the per-person reports too.** You don't run both scripts —
  `Get-TeamRollupReport.ps1` runs `Get-TeamKpiReport.ps1` for each member+month
  where raw data exists, then aggregates.
- **Missing months are reported as gaps, never as zero.** A member with no data
  reads as "not collected", because "raised no PRs" and "we never fetched it" mean
  very different things in a review.
- **Collect once, re-slice freely.** The raw JSON is the expensive part. After it
  exists, `-SkipMemberReports` re-aggregates any period instantly.
