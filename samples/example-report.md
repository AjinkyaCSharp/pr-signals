# PR / KPI Report - jane.doe@example.com (2025-07)

Generated: 2025-08-01T05:01:23.6871152Z

> This is the real output of `Get-TeamKpiReport.ps1` run against
> [`sample-input.json`](sample-input.json). All names, PRs and comments are synthetic.

## Summary

| Metric | Value | Trend |
|---|---|---|
| PRs raised | 3 |  |
| PRs merged to master | 2 |  |
| Merge rate | 66.7% | |
| Abandoned PRs | 0 (0%) | |
| Avg cycle time (create -> merge) | 71 h | |
| Median cycle time | 71 h | |
| Review threads (resolved/total) | 1/2 (50%) | |
| Total review comments | 4 (avg 1.3 / PR) | |
| Distinct reviewers engaged | 2 | |
| Missing work item link | 1 (33.3%) | |
| Incomplete/stale description | 1 (33.3%) | |
| PRs with any comment flag | (33.3%) | |
| **Composite quality score (0-100)** | **57.8** | |

_No prior month summary found in this output folder - trend column will populate once a previous month's report exists._

### PR size / churn

| Metric | Value | Trend |
|---|---|---|
| Total lines added / deleted | +240 / -95 | |
| Total files changed | 8 | |
| Avg churn per PR (added+deleted) | 111.7 | |
| Large / risky-to-review PRs (churn >= 400 or files >= 15) | 0 (0%) | |

### Review governance

| Metric | Value | Trend |
|---|---|---|
| Self-approval flags (author approved own PR) | 1 (33.3%) | |
| Merged to master with no approving reviewer | 0 (0% of merges) | |

### Commit hygiene

| Metric | Value | Trend |
|---|---|---|
| Total commits | 5 | |
| Vague / non-descriptive commit messages | 3 (60%) | |
| Avg rework commits after first review comment | 1 | |

### Comment-flag category breakdown

| Category | Count |
|---|---|
| Naming convention | 1 |
| Null check | 1 |
| Misleading description | 0 |
| Stale/incomplete comment | 0 |

## Pull Requests

| # | Title | Status | Target | Merged | Cycle time (h) | Threads | Comments | Desc flag | No work item | Comment flags |
|---|---|---|---|---|---|---|---|---|---|---|
| 101 | [Fix order export bug](https://dev.azure.com/your-org/YourProject/_git/YourRepo/pullrequest/101) | completed | refs/heads/master | True | 23 | 1 | 1 | False | False | 0 |
| 102 | [wip](https://dev.azure.com/your-org/YourProject/_git/YourRepo/pullrequest/102) | completed | refs/heads/master | True | 119 | 1 | 3 | True | True | 2 |
| 103 | [Add report caching](https://dev.azure.com/your-org/YourProject/_git/YourRepo/pullrequest/103) | active | refs/heads/feature/report-caching | False | n/a | 0 | 0 | False | False | 0 |

### Pull Requests - size, governance & commit hygiene

| # | Files | +Lines | -Lines | Large PR | Reviewers | Approved | Self-approved | Commits | Vague commits | Rework commits |
|---|---|---|---|---|---|---|---|---|---|---|
| 101 | 2 | +30 | -5 | False | 1 | 1 | False | 2 | 0 | 0 |
| 102 | 6 | +210 | -90 | False | 2 | 2 | True | 3 | 3 | 2 |
| 103 | 0 | +0 | -0 | False | 0 | 0 | False | 0 | 0 | n/a |

## Candidate comment flags (heuristic - needs manual confirmation)

### PR #102 - wip
- **Null check** (thread 2, by John Reviewer): "Please add a null check here before dereferencing customer.Address"
- **Naming convention** (thread 2, by John Reviewer): "Also this variable name is confusing, please rename it per naming convention."


## Vague / non-descriptive commit messages (heuristic - needs manual confirmation)

| PR | Commit | Message |
|---|---|---|
| #102 - wip | c3d4e5f6 | "wip" |
| #102 - wip | d4e5f6a7 | "fixed pr comments" |
| #102 - wip | e5f6a7b8 | "fixed unit tests" |

## Self-approval / no-approval-merge flags (needs manual confirmation)

- **Self-approved**: PR #102 - wip - jane.doe@example.com appears among the reviewers with an approving vote on their own PR.

## Confirmed talking points

_Filled in by the agent after manually reviewing the candidate flags above, per RUNBOOK.md Step 4. Illustrative content below._

**Strengths to open with**
- PR #101 shipped in under a day with a regression test the reviewer explicitly praised — that is the pattern worth repeating.

**One thing to work on: PR framing**
- PR #102 went out titled `wip` with a one-word description and no linked work item, and took 119 h to merge vs 23 h for #101. The reviewer had to ask what the change was doing before reviewing it. Concrete ask: title + 2-line description + work item link before adding reviewers.

**Worth a question, not an accusation**
- PR #102 shows an approving vote from the author. Confirm whether this was a branch-policy bypass for a deadline or a habit — the fix differs.

**Not raised**
- The "null check" comment on #102 was a one-off on a genuinely non-obvious path, not a pattern. Discarded as a talking point.
