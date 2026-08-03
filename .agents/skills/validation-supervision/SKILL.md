---
name: validation-supervision
description: >-
  Firstmate supervision contract for a worker-owned no-mistakes run.
  Load before starting or interpreting validation, answering findings, handling changed requirements, superseding a run, or deciding CI readiness.
user-invocable: false
metadata:
  internal: true
---

# Validation supervision

Load this only after a no-mistakes ship worker has completed and committed implementation, or when an existing worker-owned validation run needs supervision.
The worker that starts the run owns every `no-mistakes axi run` and `no-mistakes axi respond` call through the next gate or outcome.
Firstmate supervises and decides authority questions but never takes over the worker's response command.

## Starting validation

Trigger `/no-mistakes` on the same worker that implemented the task, using the target harness's invocation form from `harness-adapters`.
The worker's intent must preserve the accepted task contract and every later accepted clarification, constraint, exclusion, and supersession in its current form.
Generic scaffold boilerplate does not belong in intent unless it is task-specific.

Once validation starts, the run owns branch custody and pipeline fixes.
Firstmate and the worker must not hand-edit, commit, restart, or start another run outside the gate response flow.
Never use `--yes`, because it bypasses Firstmate's authority review.

## Current-state authority

Judge validation with `bin/fm-crew-state.sh <id>` against the run and current code head rather than shell liveness or the last status event.
Running, fixing, and CI activity remain work in progress.
An approval or fix-review state requires the worker to follow the active gate's current help.
Passing checks are ready for the delivery outcome.
A failed or cancelled current run is a failure unless its supported recovery path says otherwise.

If the worker edits, commits, aborts, restarts, or starts a second run while the active run owns the branch, steer it back to the gate response flow.
A historical status line never overrides current structured run state.
The worker reports a PR when CI first becomes green rather than waiting for background merge monitoring.

## Findings and authority

An ask-user finding returns as a decision request.
Load `ask-user-authority` before deciding any such finding.
Firstmate may decide only when the configured authority covers the finding inside accepted intent.
Product or engineering contract expansion, destructive action, irreversible action, security-sensitive action, discard, and unauthorized merge choices go to the captain.
The implementation worker never answers its own authority finding.

When a decision is authorized, send the same worker one exact response instruction that names:

- the decision key,
- the active step,
- the chosen action,
- every affected finding identifier,
- any implementation direction required by the choice,
- and the exact `no-mistakes axi respond` command supplied by the current gate help.

Send that instruction with `fm-send`'s `--resolve-key` so the worker's open decision record closes at answer time.
Require the matching durable resolved event.
Require the worker to process every synchronous return until completion or a genuinely new escalation.
Resume fleet supervision immediately after the decision lands.

## Changed requirements during validation

Prefer a follow-up task for requirements introduced after validation begins.
Keep only the smallest downstream correction needed to preserve already accepted behavior, add behavioral tests where an executable contract exists, or keep documentation accurate in the current run.
A difficult correction required by accepted intent is not a new requirement merely because it touches an unanticipated file.

Only a current explicit captain instruction that completely invalidates the work being validated uses the supersession path below.
A partial change, additive requirement, or ordinary finding does not authorize aborting the active run.

## Complete supersession

The same worker performs the supported abort and custody recovery sequence.
Firstmate must not issue those commands itself.

1. The worker aborts through no-mistakes axi's current supported abort command.
2. The worker confirms through structured axi status that the run stopped.
3. The worker follows `branch_sync.next_action` exactly.
4. It uses axi sync's guarded recovery only when the structured code is `recover_custody`.
5. Otherwise it proceeds only when structured status confirms branch custody has already returned and no recovery is required.
6. It replaces obsolete work from the correct pre-invalidation base rather than building on recovered but obsolete content.
7. It keeps obsolete run fixes, scratch commits, and intermediate heads out of the replacement.
8. It validates exactly once against the final replacement head.

Custody recovery settles ownership rather than deciding content.
Do not hand-edit, commit, restart, or start a replacement run until the obsolete run has stopped and structured status confirms custody is settled.
No obsolete or intermediate head may become the delivery authority.

## Completion

For the full no-mistakes path, completion means the current-code-matched run passed and CI is green on the reported PR.
The worker reports `done: PR <full-url> checks green` at that point and stops.
Firstmate then binds the PR through `bin/fm-pr-check.sh` and applies the delivery and merge-authority contract from `primary-runtime`.
Never merge red work, and never treat a passed obsolete head as current success.
