# Brief task-field trial verification

Audience: maintainer verification.

This record supports the four required task fields a ship or scout brief carries, owned by [`bin/fm-brief.sh`](../../bin/fm-brief.sh) (scaffold) and [`bin/fm-brief-heading-lib.sh`](../../bin/fm-brief-heading-lib.sh) (the field list and the unfilled-field reader).
It records the before-baseline and the re-measurement procedure for one project, so a later reader can re-run the comparison and see for themselves whether the change moved the signal.

## What changed

A ship or scout brief's `# Task` section now carries four required fields, each scaffolded as its own section with a fill placeholder.

| Field | Placeholder | States |
| --- | --- | --- |
| `## Acceptance criteria` | `{ACCEPTANCE_CRITERIA}` | what "done" means |
| `## Verification path` | `{VERIFICATION_PATH}` | the exact command or check that proves it |
| `## Required artifact` | `{REQUIRED_ARTIFACT}` | what the task produces |
| `## Out of scope` | `{OUT_OF_SCOPE}` | what the task does not cover |

`bin/fm-spawn.sh` and `bin/fm-promote.sh` refuse a brief whose field is absent, empty, or still its placeholder, and the refusal names the field to write.
A brief that carries none of the four sections predates the contract and stays dispatchable, so a task already in flight can still be relaunched.

## The baseline this is measured against

The evidence is `20-Tools/agentsview-quality-report-2026-10-12.md` in the `ai_lab_vault` vault, whose two WARNING-severity prompt-maturity rows are `missing success criteria` (124 of 523 sessions, reported 1.8x incomplete lift) and `repeated prompts` (278 signals across 46 sessions, reported 10.9x incomplete lift).

That report is a signal generator, not a measurement, and two of its own caveats bind this trial.

- The report lists four `0.0x` incomplete-lift multipliers, among them `missing targeted verification path` (49 signals). A `0.0x` multiplier means the cohort had zero incomplete sessions or a divide-by-zero, so it is **unmeasured, not safe**. The verification-path row this change targets therefore has no trustworthy baseline multiplier at all.
- The report's grade, ratios, and multipliers are computed by a methodology the fleet has not inspected (bead `woka`).

## Measured before-state

Measured 2026-10-19 against the agentsview SQLite archive at `~/.agentsview/sessions.db` (agentsview v0.45.0, the live server on `127.0.0.1:50901`).
The session store is the authority; the UI is not a durable record.

The cohort is the firstmate-dispatched sessions of the one project `ai_lab_vault`: a session whose first user message carries the `FIRSTMATE_OP: v1 launch-brief` marker, which is how a dispatched worker is identified in the store.

```sh
sqlite3 -readonly ~/.agentsview/sessions.db "
with d as (
  select s.id, s.agent, s.started_at, s.outcome, s.missing_success_criteria_count msc,
         s.missing_verification_count mv, s.duplicate_prompt_count dup, m.content
  from sessions s join messages m on m.session_id=s.id and m.ordinal=0
  where s.project='ai_lab_vault' and s.deleted_at is null
    and m.content like '%FIRSTMATE_OP: v1 launch-brief%'
)
select count(*) sessions,
  sum(case when content like '%## Acceptance criteria%' then 1 else 0 end) with_acceptance_section,
  sum(case when msc>0 then 1 else 0 end) sess_msc,
  sum(case when mv>0 then 1 else 0 end) sess_mv,
  sum(case when dup>0 then 1 else 0 end) sess_dup,
  sum(dup) dup_signals,
  sum(case when outcome='completed' then 1 else 0 end) completed,
  min(started_at), max(started_at)
from d;
"
```

Result on 2026-10-19:

| Measure | Value |
| --- | --- |
| Dispatched sessions in `ai_lab_vault` | 6 |
| Carrying an `## Acceptance criteria` section | 0 |
| Sessions with `missing success criteria` | 1 |
| Sessions with `missing targeted verification path` | 0 |
| Sessions with `repeated prompts` | 2 |
| `repeated prompts` signals | 2 |
| Sessions with outcome `completed` | 5 |
| `quality_signal_version` | 5 |
| Window | 2026-09-15 to 2026-10-19 |

For contrast, the same project's non-dispatched sessions (a worker's own interactive session, not a dispatched worker) carry 107 sessions with `missing success criteria` and 10 with `repeated prompts` across 308 sessions.
That contrast is the reason the cohort is defined by the launch-brief marker rather than by project alone: the change lands in the brief, so only the dispatched cohort can move.

## Procedure

1. Land the change on `main`, so newly dispatched briefs carry the four fields.
2. Dispatch at least 20 ship or scout tasks against the `ai_lab_vault` project clone, each with a filled `## Acceptance criteria`, `## Verification path`, `## Required artifact`, and `## Out of scope`.
   A task whose fields are not filled is refused at dispatch, so a refused dispatch is the generator working, not a missing sample.
3. Re-run the query above, unchanged, and read the same rows.
4. Record the dated output in this file.

## What counts as improvement

The mechanism claim is narrow and structural: a dispatched brief that carries the four fields, and a dispatched brief whose first user message carries an `## Acceptance criteria` section, is the observable that the generator change reached the worker.
That claim is true by construction and is proven by the scaffold and refusal tests.

The behavioral claim is separate and weaker: sessions in the dispatched cohort should carry `missing success criteria` and `repeated prompts` signals at a lower rate than the before-state above.
Three conditions must all hold for a lift to be claimed.

- `sess_msc` and `sess_dup` in the re-measured cohort must be below the before-state.
- The `with_acceptance_section` count must equal the cohort size, which proves the sample actually ran under the new generator rather than under a mix of old and new briefs.
- The cohort must be large enough that a difference is not noise: with 6 sessions in the before-state, one session flipping is a 16-point swing, so a single-run comparison on a small cohort is not evidence.

**No lift figure is trusted until a sibling method bead confirms it.**
The report's `0.0x` multipliers are degenerate, its lift methodology is uninspected, and the before-state cohort here is 6 sessions.
A measured change in this cohort is a signal to investigate, not a result to publish.

## Re-measurement notes

- The archive is SQLite at `~/.agentsview/sessions.db` and is written by a live daemon, so a re-measurement should read with `sqlite3 -readonly` and accept that the newest session may not have been ingested yet.
- The server on `127.0.0.1:50901` serves the same archive; the UI is a view of it, not the record.
- A session is dispatched when its first user message carries the `FIRSTMATE_OP: v1 launch-brief` marker.
  A session that lacks the marker was not dispatched through this generator, whatever its project.
- `missing_success_criteria_count`, `missing_verification_count`, and `duplicate_prompt_count` are per-session counters on the `sessions` table; the report's "sessions" and "signals" columns count different things, and a session can carry more than one signal.
- The `quality_signal_version` column on `sessions` records which signal computation produced the counters.
  A version change invalidates a comparison with an earlier one, and the version must be recorded with any result.
