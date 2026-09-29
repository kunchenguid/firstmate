---
name: project-verification
description: >-
  Agent-only procedure for proving a project change works in the real app before it ships.
  Load before dispatching a ship whose change touches a user-facing app surface (web UI, CLI/TUI, desktop app, or service), and before writing or maintaining a project-local verification skill.
user-invocable: false
metadata:
  internal: true
---

# Project verification

This skill is the single owner of Firstmate's project-verification procedure: turning "verify it in the app" into a step any agent can execute in a project repo with no setup conversation.
It adapts the create-and-maintain verification practices of Cursor's Pstack plugin and consumes Firstmate's existing evidence contracts by reference rather than restating them.
Firstmate applies it when dispatching or supervising ships that touch a user-facing app surface, and the implementation worker uses it to build and prove the project's verification slice.

## Create the project-local verify skill

Interview the repo, not the user: the surface, how it runs, how to tell it is ready, how to drive it, what to observe, and how to isolate instances.
Generate the verify skill at the location the target repo's conventions use (for example `.cursor/skills/verify-<app>/` on a Cursor repo), written for the next agent to read cold.
Give it six sections, each grounded in what the interview found:

- **Launch** is the exact start command, how readiness is observed, and teardown.
- **Doctor** is one read-only check answering "is this instance worth driving?".
- **Drive** is the harness recipe with real selectors from this repo.
- **Evidence** is the proof standards below.
- **Cleanup** removes instances and scratch state, never the evidence, and never kills by process name.
- **Helpers** are executable helpers whose invocation is shown in the skill body.

Add a feature map beside the skill: a `features/README.md` plus one file per user-facing feature with four required H2s (Sub-features, How to get to it (user POV), Driving it with <harness>, Gotchas).
The map is the repo's maintained verification source, and a proof that drives one convenient entry point is incomplete when the map lists others.

## Prove it end to end before handoff

Run the generated skill once before handoff as a smoke test: launch, doctor, drive one mapped feature, capture evidence, clean up.
That single pass proves the skill runs end to end; it is not full coverage, so every other path the feature map lists must also be driven before handoff.
The evidence must survive cleanup.
A generated skill that was never executed is a draft, not a deliverable.

## Evidence standards

Match the check to the change: a CLI change runs the real command, a UI change walks the changed flow in the running app, a parser or migration replays a saved input, a performance change compares before and after, and a storage change reads back the written value.

- A claimed fix carries a reproduction in which the defect is demonstrably present before the change and absent after it, exercised through the same path a user would hit (issue #5893); `diagnostic-reasoning` owns the reproduction procedure.
- Every failure-mode row in a validation table carries at least one non-zero pre-change observation or is explicitly marked as not exercised by the sample, with sample size and prevalence stated; an all-zero table is absence of evidence, not verification (issue #5893).
- Hand-run evidence names its execution environment: which local copy, which virtual environment, and what was installed in it, so the count is verifiable and comparable (issue #5590).
- A green check whose path filter matched nothing is stated as such in the same sentence as the count (issue #5590).
- Completion claims are made only after reading the evidence that proves them in the current turn, and unverified facts are labeled unverified in the same sentence (issue #5689); `captain-hold-lifecycle` owns the completion gate for Firstmate-originated work.

Firstmate's own repo records dated per-environment runtime evidence in `docs/verification/runtime-backends.md`; this skill extends that discipline to project work.

## Integrate with delivery, not beside it

The verify skill supplies what the pipeline cannot: real-app drive evidence attached to the ship's done claim.
`no-mistakes` owns review, tests, lint, docs, push, PR, and CI, and `validation-supervision` owns the validation run's drive contract.
Never configure a deterministic suite-walk `commands.test`; `firstmate-coding-guidelines` owns that rule and the harness-dependent check policy for vendor-emitted verdicts.
Generated verify content is per-project and rots with the app, so additions to a project's committed `AGENTS.md` remain a deliberate human choice.

## Maintain the verify skill

The unit of rigor is the feature, not every sentence.
A source wave of one read-only subagent per feature is followed by a required live pass driving every mapped feature, holding three invariants: doctor before the first drive and again after any failed drive, evidence captured so far survives every cleanup, and nothing a drive started outlives that drive's usefulness.
Refuse to double-drive a shared instance another agent may be using.
Triage separates doc drift (fix the map), a harness gap (fix the harness), and a product gap (report the regression, never paper over it in docs).
The upkeep pass ends in exactly one outcome:

- **clean** means full source and live coverage with nothing to ship and no PR.
- **changed** means one PR of proven corrections confined to the verify skill's own directory.
- **blocked** names what blocked coverage.
