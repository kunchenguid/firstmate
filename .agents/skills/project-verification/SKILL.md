---
name: project-verification
description: >-
  Prove a project change in the real app. Load before dispatching a ship that touches a user-facing app surface, and before writing or maintaining a project-local verification skill.
user-invocable: false
metadata:
  internal: true
---

# Project verification

This skill is the single owner of Firstmate's project-verification procedure: turning "verify it in the app" into a step any agent can execute in a project repo with no setup conversation.
It is a narrow adaptation of the verification practices of the pstack plugin (https://github.com/cursor/plugins/tree/main/pstack) and consumes Firstmate's existing evidence contracts by reference rather than restating them.
Firstmate applies it when dispatching or supervising ships that touch a user-facing app surface, and the implementation worker uses it to build and prove the project's verification slice.
Instance isolation here means separate instances and cleanup, not filesystem or network confinement; sandbox and Orca runtime integration stay separate work.

## Choose reuse, create, or maintain

Reuse an existing recipe for ordinary change validation, create one only when the task needs it inside the accepted scope, and run a full upkeep pass only when Firstmate commissions one or a stale recipe must be repaired.
A documentation-only or unrelated internal change never triggers app verification merely because the repository contains an app.
When the work needs project verification, Firstmate states it in the ship brief: the verify skill path, the project target, the operation (drive, create, or maintain), the coverage boundary, and the evidence destination.
The worker performs that slice directly and never spawns per-feature subagents; any parallel source work is Firstmate's to assign through its normal authority.
Generated content must be discoverable without an oral handoff: a `SKILL.md` with `name` and `description` frontmatter at the repo's skill location, one invocation route that actually resolves, and no unexplained placeholders.

## Create the project-local verify skill

Interview the repo, not the user: the surface, how it runs, how to tell it is ready, how to drive it, what to observe, and how to isolate instances.
Generate the verify skill at the location the target repo's conventions use (`.agents/skills/verify-<app>/` when the repo has none), written for the next agent to read cold.
The generated skill is project content: the worker writes it in its task worktree and it ships through the task's delivery mode like any other project change.
Give it these sections, each grounded in what the interview found:

- **Launch** is the exact start command, how readiness is observed, and teardown.
- **Doctor** is one read-only check answering "is this instance worth driving?".
- **Drive** is the harness recipe with real selectors from this repo.
- **Evidence** is the proof standards below.
- **Cleanup** removes instances and scratch state, never the evidence, and never kills by process name.
- **Helpers**, only when the skill ships helper scripts, are executable helpers whose invocation is shown in the skill body.

Add a feature map beside the skill: a `features/README.md` plus one file per user-facing feature with four required H2s (Sub-features, How to get to it (user POV), Driving it with <harness>, Gotchas).
Every entry point pairs its action with the observable result that proves it worked, so coverage is checkable rather than asserted.
The map is the repo's maintained verification source, and a proof that drives one convenient entry point is incomplete when the map lists others.
The map states its own coverage boundary and any unreachable prerequisite instead of quietly narrowing the denominator.

## Prove the skill, then the map

Two different passes, and the first never substitutes for the second:

- **Smoke pass** - run the generated skill once: launch, doctor, drive one mapped feature, capture evidence, clean up. It proves the recipe executes end to end. It is not coverage.
- **Complete pass** - drive every other path the feature map lists, or record that path as blocked with its unmet prerequisite in the same evidence.

Only the complete pass supports a full-coverage claim, so a handoff that stops at the smoke pass states plainly which mapped paths remain undriven.
The evidence must survive cleanup.
A generated skill that was never executed is a draft, not a deliverable.

## Evidence standards

Match the check to the change: a CLI change runs the real command, a UI change walks the changed flow in the running app, a parser or migration replays a saved input, a performance change compares before and after, and a storage change reads back the written value.

- A claimed fix carries a reproduction in which the defect is demonstrably present before the change and absent after it, exercised through the same path a user would hit; `diagnostic-reasoning` owns the reproduction procedure.
- Every failure-mode row in a validation table carries at least one non-zero pre-change observation or is explicitly marked as not exercised by the sample, with sample size and prevalence stated; an all-zero table is absence of evidence, not verification.
- Hand-run evidence names its execution environment: which local copy, which virtual environment, and what was installed in it, so the count is verifiable and comparable.
- A green check whose path filter matched nothing is stated as such in the same sentence as the count.
- Completion claims are made only after reading the evidence that proves them in the current turn, and unverified facts are labeled unverified in the same sentence; `captain-hold-lifecycle` owns the completion gate for Firstmate-originated work.
- Each mapped path leaves a retained outcome record naming its action or command, observed result, revision and environment, artifact link, and any unmet prerequisite, written to a durable destination outside the instance being cleaned up and confirmed by a read after that cleanup.

Firstmate's own repo records dated per-environment runtime evidence in `docs/verification/runtime-backends.md`; this skill extends that discipline to project work.

## Integrate with delivery, not beside it

The project recipe supplies app-specific driving instructions and artifacts to the selected delivery path, which attaches real-app drive evidence to the ship's done claim: the PR description on `direct-PR`, the validation run on `no-mistakes` (whose drive contract `validation-supervision` owns).
Never configure a deterministic suite-walk `commands.test`; `firstmate-coding-guidelines` owns that rule and the harness-dependent check policy for vendor-emitted verdicts.
Generated verify content is per-project and rots with the app, so additions to a project's committed `AGENTS.md` remain a deliberate human choice.

## Maintain the verify skill

The unit of rigor is the feature, not every sentence.
One worker performs the source pass across the mapped features without nested delegation, then a required live pass drives every mapped feature, holding three invariants: doctor before the first drive and again after any failed drive, evidence captured so far survives every cleanup, and nothing a drive started outlives that drive's usefulness.
Keep source inspection separate from live driving so two agents never drive one instance, and refuse to double-drive an instance another agent may be using.
Reconcile the index against its feature files, and scan the changed routes, commands, and menus for a user surface the map omits, citing the source that proves each addition; a map that lists only what it already knew is not full coverage.
Carry a failed drive past its diagnosis: clean up the failed iteration, reset or relaunch when the instance's health does not explain the bad state, correct the harness, and re-drive it live to prove the correction.
Triage separates doc drift (fix the map), a harness gap (fix the harness), and a product gap (record the regression separately, never paper over it in docs).
The upkeep pass ends in exactly one outcome:

- **clean** means full source and live coverage with nothing to ship.
- **changed** means proven corrections confined to the verify skill's own directory, delivered through the mode already selected for the task: `local-only` stops at the ready branch, while `direct-PR` and `no-mistakes` open at most one PR and never a second one.
- **blocked** names the path, the route attempted, and the unmet prerequisite, rather than counting another path as success.
