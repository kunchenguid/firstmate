---
name: task-lifecycle
description: >-
  Load before resolving a ship or scout request and before spawn, steer, validate, merge, promote, or teardown.
user-invocable: false
metadata:
  internal: true
---

# task-lifecycle

`AGENTS.md` section 7 keeps the safety boundaries and this load trigger.
This skill owns the runbook.
Referenced scripts own exact commands, flags, and data mechanics.

## Resolve and route

Resolve the project independently for every request.
An explicit project wins, a clear follow-up inherits its referent, and otherwise match the request against the registry, work under way, and project code or README.
Proceed on one confident match while naming the project in plain language; ask one concise question when multiple or no projects plausibly match.
Route by the nature of the work against each registered secondmate scope, not by a non-exclusive clone list; keep `local-only` work in the main home.
At intake, classify with `bin/fm-route-domain.sh --task "<description>"` or `bin/fm-route-dispatch.sh` against `data/secondmates.md`.
Never spawn project workers as direct reports in `w1`.
Send in-scope work to the fitting secondmate unless it is blocked or the captain explicitly redirects it.
If no secondmate scope fits, or Jev recommends `create_secondmate`, charter an appropriate persistent secondmate rather than doing that project work in the main home.
`bin/fm-jev-guard.sh` is the primary-console supervisor boundary: it denies hands-on project implementation, remote service mutation, and similar work with `require_delegation`.

## Ship vs scout

**Ship** is the default and produces a project change through the selected delivery mode.
**Scout** produces knowledge in `data/<id>/report.md`, never a PR, when the captain explicitly requests a separate knowledge or design deliverable or unresolved uncertainty could materially change whether or what to build.
If established evidence already answers an informational question, relay it without a design-only scout.
A diagnostic request, report, recommendation, or implementation-ready finding is evidence, not authorization to change code.
Load `diagnostic-reasoning` before scoping a reported bug and before acting on a diagnostic report.

## Delivery mode and yolo

Resolve every ship task's concrete delivery mode and `yolo` merge posture at intake.
Pass the mode explicitly to the brief, and pass both values explicitly to the spawn and any scout promotion; each command refuses to guess the values it consumes.
A current explicit captain instruction wins; otherwise the project's registry entry is the captain's standing posture, and dropping below its rigor needs a reason you can state.
On a `no-mistakes-prod-only` project, internal-only tooling, automation, contributor or operator process, and release or submission work ships `direct-PR`; product-facing, mixed, and uncertain work ships `no-mistakes`; never infer internal-only from file location or project name.
An unregistered project or absent registry resolves to `no-mistakes` with yolo off, and the registration gap goes to the captain.
Record the resulting mode, `yolo` merge posture, and the one-line reason for any deviation in the backlog item note.
Dispatch isolated work immediately when each change can be independently implemented and validated; serialize only for a true semantic dependency or other concrete unsafe overlap.
Write the task-specific brief under `AGENTS.md` section 11 before spawning.
`bin/fm-brief.sh` and its help own scaffold syntax, generated variants, status protocol, delivery-mode definitions of done, and exact safety mechanics.
Fill `## Captain's intent` with the captain's own ask and stated boundary plus the context needed to read it, including the substance of any report, decision, or PR the ask refers to; never widen the ask there.
Fill `## Firstmate spec` with only the build instructions that ask requires, naming what stays out of scope when the ask is narrow.
`bin/fm-dod-lib.sh` owns intent authoring, provenance markers, and the `--intent` self-sufficiency rule.
Every ship brief must retain the worktree-isolation assertion and stop if launched in the primary checkout.
If a ship task touches firstmate's shared tracked material, explicitly require `firstmate-coding-guidelines` before editing.
If a task will drive Herdr lifecycle behavior, scaffold with `--herdr-lab`; if that need appears after an unguarded scaffold, stop and regenerate rather than adding commands by hand.
Load `secondmate-provisioning` before creating or using a charter brief and preserve its idle-by-default and marked-return-channel contracts.
Status appends are sparse supervisor-actionable events; `bin/fm-classify-lib.sh` owns keyed open and resolved semantics.
The scaffold is a safety contract, not a suggestion.

[`docs/architecture.md`](../../../docs/architecture.md) owns delivery-mode mechanism; `bin/fm-project-mode.sh` parses the registry.

## Spawn, steer, control

Spawn only through `bin/fm-spawn.sh` after the profile and backend checks in `AGENTS.md` section 4.
The spawn must resolve a genuine isolated task worktree distinct from the primary checkout; a failed isolation assertion stops the task.
When the configured tasks-axi backlog gate applies, the spawn itself moves the work item to In flight and refuses rather than dispatching work this home has no item for.
After spawning, confirm the worker is processing the brief and handle any trust dialog through `harness-adapters`.
A persistent secondmate is recorded in the secondmate registry and runtime state, never as a backlog work item.
Steer a worker with ordinary text through fail-closed `fm-send`; `bin/fm-send.sh` owns the durable-inbox, remote-resend, and `--resolve-key` contracts.
Never use `fm-send` for interrupt, exit, or other lifecycle control.
Drive a worker's lifecycle through `bin/fm-control.sh <task-id> interrupt|exit|relaunch` ([`docs/agent-control.md`](../../../docs/agent-control.md)).
Supervise all live work under `AGENTS.md` section 8 and `supervision-protocol`.

## Delivery paths

When no-mistakes is selected, no-mistakes alone owns review, fixes, tests, documentation, push, PR, and CI; otherwise follow the faster path without adding an independent reviewer.
Never hold work outside no-mistakes for a manual clean verdict or infer a review gate from security, architecture, or risk alone.

- **no-mistakes** runs the full pipeline through a PR, then waits for the configured merge authority.
- **direct-PR** has the worker push and open a PR without the no-mistakes pipeline, then waits for the configured merge authority.
- **local-only** has the worker stop with a clean ready branch, then waits for the configured merge authority before firstmate uses the guarded fast-forward merge path.

Delivery mode and `yolo` are orthogonal.
`yolo` governs merge authority only: with it off, the captain approves every PR merge and every local-only landing; with it on, firstmate merges green, in-scope work itself.
Never merge a red PR under either setting unless a current explicit captain instruction names the single GitHub check waived through `fm-pr-merge.sh --allow-red`; that attended-only waiver still requires every other check green.
Destructive, irreversible, and security-sensitive merges still escalate.
Standing `yolo` cannot authorize a red merge.
Load `ask-user-authority` before deciding any ask-user finding; the implementation worker never answers its own finding.
Use `bin/fm-pr-merge.sh` for every task PR merge, and `bin/fm-merge-local.sh` for approved local-only landing.
After an autonomous merge, give the captain a one-line full-URL or local-main outcome.

## No-mistakes validation

For a no-mistakes ship, trigger validation on the same worker after its implementation commit, using the harness invocation owned by `harness-adapters`.
The task worker owns every `no-mistakes axi run` and `no-mistakes axi respond` call; firstmate never invokes `no-mistakes axi respond` for a crew-owned run.
When the captain adds or changes an ask mid-task, append the captain's words without added speaker labels or direct address to that brief's `## Captain's intent` and relay those words to the worker.
`bin/fm-dod-lib.sh` owns the worker-side `--intent` contract.
Once validation starts, prefer routing new requirements to follow-up work unless a current explicit captain instruction completely invalidates the work.
That worker then cancels through no-mistakes axi's supported abort, confirms the run has stopped, follows `branch_sync.next_action` from structured axi status, and validates exactly once against the final non-obsolete head.
An ask-user finding returns as `needs-decision`; send the same worker one exact decision with `--resolve-key`, require the matching `resolved` event, and forbid `--yes`.
Judge validation by the currently attributed run step through `bin/fm-crew-state.sh`, not by shell liveness or the last status event.
The worker reports the PR when CI first becomes green.

## Landing, teardown, scout close

For PR-based ship tasks, `no-mistakes` reports `done [at=<epoch>]: PR <url> checks green` after CI is green, while `direct-PR` reports `done [at=<epoch>]: PR <url>` after opening the PR, each only for a non-draft PR; a lane that deliberately holds a draft declares a wait instead, and `bin/fm-pr-check.sh` refuses to arm merge monitoring on a draft.
Run `bin/fm-pr-check.sh <id> <PR url>` with the URL copied from that ready signal, and tell the captain that same full URL.
A captain instruction to merge is explicit authority; `yolo` is the only standing routine merge authority.
Custom slow polls are owned by `bin/fm-check-register.sh` and `bin/fm-check-unregister.sh`.
Tear down a ship task only after landing is confirmed; a teardown refusal for uncommitted or unlanded work is a stop-and-investigate result.
Never force teardown without explicit discard authority.
Choose cleanup targets from `bin/fm-fleet-view.sh --cleanup-candidates`, which labels every live task with its kind, rather than inferring what a task is from its path, and clean up one target per invocation.
A secondmate is persistent and an empty queue is healthy; retire one only after loading `secondmate-provisioning`, naming that exact home, and only when its home contains no work under way.

A completed scout must leave a self-contained report before its scratch worktree can be discarded.
A report may recommend implementation but does not authorize it.
Before treating the investigation or any visual review as complete, load `captain-hold-lifecycle`.
When a scout's deliverable is a visual artifact the captain will iterate on, keep it alive and follow the crew-hosted Lavish board contract in `docs/configuration.md` rather than arming or polling the board from firstmate.
When implementation is separately authorized, promote the existing scout through `bin/fm-promote.sh` rather than creating a duplicate task.
