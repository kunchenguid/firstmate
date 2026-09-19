---
name: task-lifecycle
description: >-
  Agent-only procedure for the full Firstmate delivery lifecycle.
  Use before dispatching, steering, validating, landing, tearing down, or promoting a task, and when filing backlog items or authoring crewmate briefs.
  AGENTS.md section 7 retains only the guarded-path, isolation, authority, red-merge, and unlanded-work invariants that must hold before this skill loads.
user-invocable: false
metadata:
  internal: true
---

# task-lifecycle

`AGENTS.md` section 7 retains only the guarded-path, isolation, authority, red-merge, and unlanded-work invariants that must hold before this skill loads.
This skill owns task intake, project and secondmate routing, task shape, delivery resolution, backlog and brief procedure, dispatch, validation, landing, and cleanup.
Referenced scripts own exact commands, flags, and data mechanics; read their headers and `--help` rather than restating them.

## Intake and authority

Resolve the project independently for every request.
An explicit project wins, a clear follow-up inherits its referent, and otherwise match the request against the project registry, work under way, and project code.
Proceed on one confident match while naming the project plainly, and ask one concise question when multiple or no projects plausibly match.
Route by the nature of the work against each registered secondmate's natural-language scope, not by its non-exclusive clone list.
Keep `local-only` work in the main home.
For one-off or infrequent operational work, begin with the simplest direct end-to-end path and add wrappers, control planes, policy layers, or automation only after that path exposes a concrete blocker.

A ship is the default deliverable and produces a project change through one selected delivery mode.
A scout produces knowledge in `data/<id>/report.md`, never a PR, and fits only when the captain explicitly requests a separate knowledge or design deliverable or unresolved uncertainty could materially change whether or what to build.
A diagnostic request, report, recommendation, or implementation-ready finding is evidence rather than implementation authority.

Before commissioning an investigation, consult existing reports and established evidence.
If established evidence already answers an informational question, relay it without a design-only scout.
Delegation covers pure research with zero code: having no project repo is not a reason to do it inline.
A scout can anchor to any registered repo purely for worktree infrastructure, and when none fits, create a minimal repo rather than working inline.
When implementation intent is unclear, answer and ask one concise implementation question when useful rather than dispatching speculative design work.
Never both present a likely-enough solution and launch a parallel design exercise that is not expected to change it.
Once implementation is authorized, dispatch a ship and keep any remaining bounded research inside it unless unresolved uncertainty could materially change whether or what to build.

Route in-scope work to the fitting secondmate unless it is blocked or the captain explicitly redirects it; do not read the secondmate's chat, because marked routed replies return through its status or a referenced document.
If no secondmate scope fits, use the main home or discuss creating an appropriate persistent secondmate.

Resolve every ship's concrete delivery mode and `yolo` posture at intake, and pass both explicitly to its brief, spawn, and any scout promotion.
A current explicit captain instruction wins; otherwise use the project's registered posture, and default an unregistered project or absent registry to `no-mistakes` with `yolo` off.
Dropping below the registered rigor requires a reason that can be stated.
On a `no-mistakes-prod-only` project, classify the task's surface: internal-only tooling, automation, contributor or operator process, and release or submission work ships `direct-PR`, while product-facing, mixed, and uncertain work ships `no-mistakes`.
Never infer internal-only from file location or project name.
Record the resulting mode, `yolo` merge posture, and the one-line reason for any deviation in the backlog item note.

Treat file or subsystem overlap as a risk signal rather than an automatic reason to wait.
Dispatch isolated work immediately with no concurrency cap when each change can be independently implemented and validated and the selected delivery path can reconcile ordinary rebases or conflicts.
Serialize only for a true semantic dependency, shared mutable external state, incompatible concurrent migration, or another concrete condition that makes independent progress or reconciliation unsafe; same-file editing alone is insufficient, and genuine blockers remain durable.

## Dispatch and supervision handoff

Spawn only through `bin/fm-spawn.sh` after applying the dispatch owners named in the `AGENTS.md` skill map.
The spawn must resolve a genuine isolated task worktree distinct from the primary checkout; a failed isolation assertion stops the task.
When the configured tasks-axi backlog gate applies, the spawn itself moves the work item to In flight and refuses rather than dispatching work this home has no item for, so recording the dispatch is never a separate step to remember.
A manual-backend home retains the hand-editing contract in `docs/configuration.md`.
After spawning, confirm the worker is processing the brief and handle any trust dialog through `harness-adapters`.

Prefer steering an idle crewmate over spawning a fresh one.
When the next task is a direct follow-up in a repo a just-finished, not-yet-torn-down crewmate already worked in, steer that one with `bin/fm-send.sh` instead of spawning.
Spawn fresh only when no idle crewmate fits or the work is unrelated enough to be confusing, and tear down promptly once a crewmate is truly done.
This is a standing captain correction: a run of small sequential same-repo fixes each got a brand-new crewmate, and the captain asked for reuse instead.
A persistent secondmate is recorded in the secondmate registry and runtime state, never as a backlog work item.

Steer a worker with ordinary text through fail-closed `fm-send`: the message becomes a durable record in the task's steering inbox (multi-line text is legal, local and remote alike) and the worker's terminal receives only a constant doorbell line.
The watcher re-rings an unacknowledged local message and escalates a stuck one (`bin/fm-task-inbox-lib.sh`; `bin/fm-send.sh` owns the typed-plane carve-outs).
A remote secondmate steer rides the same durable-inbox model through the remote transport; after an unconfirmed delivery, only the exact `FM_PENDING_REPLY_EXISTING_CORR=<id>` resend command printed by `fm-send` is safe, because it preserves the request body for remote enqueue deduplication.
When a steer answers an open keyed decision or blocker, pass `fm-send`'s `--resolve-key` so the answer itself closes that decision record at answer time, identically for local and remote workers.
`fm-send` is the data plane for text the worker should read; never use its key or text paths for interrupt, exit, or other lifecycle control, because routing-marked lifecycle text becomes chat the worker reasons about instead of executing.
Drive a worker's lifecycle through `bin/fm-control.sh <task-id> interrupt|exit|relaunch`, which owns the per-runtime mechanics, verifies each action, and never tears down or discards anything ([`docs/agent-control.md`](../../../docs/agent-control.md)).
For the parent-owned correlation, recovery, and escalation contract on marked secondmate requests, see `bin/fm-pending-reply-lib.sh`.

## Selected delivery path and merge authority

The selected delivery path owns its own rigor.
When no-mistakes is selected, no-mistakes alone owns review, fixes, tests, documentation, push, PR, and CI; otherwise follow the faster path without adding an independent reviewer.
Never hold work outside no-mistakes for a manual clean verdict, stack serial manual reviews, or infer authority for one from security, architecture, or risk alone.
A separate review or audit is allowed only when the captain explicitly requests that deliverable or the authorized task is a knowledge-only review; one named question remains scoped to that question.
If fast-path risk needs more rigor, escalate whether to use no-mistakes instead of inventing a manual gate.

- **no-mistakes** runs the full pipeline through a PR, then waits for the configured merge authority.
- **direct-PR** has the worker push and open a PR without the no-mistakes pipeline, then waits for the configured merge authority.
- **local-only** has the worker stop with a clean ready branch, then waits for the configured merge authority before firstmate uses the guarded fast-forward merge path.

With `yolo` off, the captain approves every PR merge and every local-only landing; with it on, firstmate merges green, in-scope work itself.
Never merge a red PR under either setting, and destructive, irreversible, and security-sensitive merges still escalate.
Without a current explicit captain instruction that states the concrete merge, that default stands, and standing `yolo` cannot authorize a red merge.
Use `bin/fm-pr-merge.sh` for every task PR merge so merge metadata is recorded and an unproved merge is refused instead of reported as landed, and `bin/fm-merge-local.sh` for approved local-only landing; never call a lower-level merge command around their guards.
After an autonomous merge, give the captain a one-line full-URL or local-main outcome.

## Validate

For a no-mistakes ship, trigger validation on the same worker after its implementation commit, using the harness invocation owned by `harness-adapters`.
The task worker that starts a no-mistakes run drives the pipeline and owns every `no-mistakes axi run` and `no-mistakes axi respond` call through the next gate or outcome.
Firstmate never invokes `no-mistakes axi respond` for a crew-owned run.
When the captain adds or changes an ask mid-task, append their words without a speaker label or direct address to the brief's `## Captain's intent` and relay those words to the worker; keep Firstmate build constraints in `## Firstmate spec` or the steer.
`bin/fm-dod-lib.sh` owns the worker-side no-mistakes intent contract.

Once validation starts, prefer routing new requirements to follow-up work rather than expanding the current task, unless a new requirement completely invalidates the work being validated.
The smallest downstream changes needed to keep already accepted product or engineering behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within the current task even when they touch files not named at intake, and corrections required to satisfy already accepted intent are not new requirements.

Only a current, explicit captain instruction that completely invalidates the work being validated keeps the task with the same worker instead of routing it to follow-up work or handing it to a replacement.
That worker cancels the active run through no-mistakes axi's supported abort command and confirms through axi status that the run has stopped before changing any code.
The worker then follows `branch_sync.next_action` from structured axi status: use axi sync's supported guarded recovery only when its code is `recover_custody`, and otherwise proceed only when structured status confirms that branch ownership is already returned and no recovery is required.
Custody recovery settles branch ownership, not content: the worker must replace the obsolete work from the correct pre-invalidation base rather than building on the recovered-but-obsolete head, keeping the obsolete run's own pipeline-fix commits out of what gets validated and shipped.
Apart from that single supported abort, do not hand-edit, commit, restart, or start a second validation run while the obsolete run still owns the branch.
Once ownership is settled, validate exactly once against that final head so no obsolete or intermediate head is ever treated as authoritative.

An ask-user finding returns as `needs-decision`; load `ask-user-authority` and either decide or escalate per that skill.
Send the same worker one exact decision naming the decision key, step, action, affected finding IDs, instructions where needed, and exact response command, passing `--resolve-key` so the worker's open decision record closes at answer time.
Require the matching `resolved` event, forbid `--yes`, and require the worker to process every synchronous return until completion or a genuinely new escalation.
Resume fleet supervision immediately after the decision lands.

Judge validation by the currently attributed run step through `bin/fm-crew-state.sh`, not by shell liveness or the last status event.
Running, fixing, or CI states remain working; parked approval or fix-review states require the worker to follow the active gate help; passed or checks-passed is done; failed or cancelled is failed exactly as `bin/fm-crew-state.sh` prints it.
Only that owner may reclassify an orphaned green CI monitor as held-for-merge done or a terminal failed record with an unreachable daemon as unknown.
A worker hand-editing, committing, aborting, or restarting during an active validation run duplicates pipeline ownership outside the supersession sequence above; steer it back to the gate response flow.
The worker reports the PR when CI first becomes green rather than waiting for merge monitoring to finish.

## PR ready, landing, and teardown

For PR-based ship tasks the ready signal depends on mode: `no-mistakes` reports `done: PR <url> checks green` after CI is green, while `direct-PR` reports `done: PR <url>` after opening the PR.
Run `bin/fm-pr-check.sh <id> <PR url>` with the URL copied from the ready signal; it records `pr=` and the forge's `pr_head=` when available in the task's meta and arms the watcher's merge poll.
Tell the captain the full URL copied from that ready signal or the recorded `pr=` metadata, a concise outcome summary, and the no-mistakes risk level when applicable.
A captain instruction to merge is explicit authority; `yolo` is the only standing routine merge authority.

For any custom `state/<id>.check.sh` you write yourself, keep it an ordinary single-link mode-`0700` file, print one line only when firstmate should wake, print nothing otherwise, finish before `FM_CHECK_TIMEOUT`, then bind its current bytes with `bin/fm-check-register.sh <id>` before the watcher may execute it.
Retire a custom check only through `bin/fm-check-unregister.sh <id>`, or `bin/fm-teardown.sh` for a spawned task; never hand-compose an `rm` with `$STATE`/`$ID`.

Tear down a ship task only after landing is confirmed.
A teardown refusal for uncommitted or unlanded work is a stop-and-investigate result, never an obstacle to bypass, and never force teardown without explicit discard authority.
After successful teardown, record completion, retain only the configured recent Done history, and re-evaluate queued work whose blockers and time gates have cleared.

A secondmate is persistent and an empty queue is healthy.
Retire one only on an explicit captain or main-firstmate decision, after loading `secondmate-provisioning`; its home must contain no work under way, and forced discard still requires explicit captain authority.

## Scout outcome and promotion

A completed scout must leave a self-contained report before its scratch worktree can be discarded.
Read and relay its findings, record the report as the Done artifact, and re-evaluate the queue.
A report may recommend implementation but does not authorize it.

When a scout produces implementation-ready but explicitly DEFERRED work with no near-term timeline, file it as a Linear issue pointing back at the report, rather than leaving it queued or held in the firstmate backlog.
The backlog is for work this fleet intends to dispatch; indefinitely-deferred scoped design belongs in the tracker.
Before treating the investigation or any visual review as complete, load `captain-hold-lifecycle`; teardown enforces that shared completion gate.
When a scout's deliverable is a visual artifact the captain will iterate on, prefer keeping that scout alive to host its own Lavish loop rather than tearing it down and mediating from firstmate, so the scout keeps its investigation context and the captain iterates in one continuous session.

When implementation is separately authorized, promote the existing scout through `bin/fm-promote.sh` rather than creating a duplicate task.
The promoted worker must inventory scratch state, return to a clean default-branch base, carry over only intended fix changes, create the ship branch, and follow the project's selected delivery path while leaving scratch commits and debug edits behind and turning a reproduced bug into the regression test.

## Backlog procedure

The backlog tracks work items only.
Persistent secondmates are never backlog items, and work routed to a secondmate belongs in that home's backlog.
A decision is a task held for the captain.
Spawn and teardown own dispatch and completion transitions under the configured gate, and backlog notes must omit temporary paths, moving versions, ephemeral identifiers, and copied state that will rot.

Create a decision task through `bin/fm-tasks-axi.sh add` when needed, then hold it through `bin/fm-captain-hold.sh hold <id> --reason "<reason>"`, with `--until <date>` when the captain defers it.
When a main-side thread such as a pending captain decision or Relay reminder is worth durable tracking, file and hold it through those same owners.
Re-evaluate queued work after every teardown and heartbeat, dispatching items only when dependencies and time gates have cleared.
Use compatible `tasks-axi` through `bin/fm-tasks-axi.sh` when the configured backend selects it and the documented manual path otherwise; keep only the configured recent Done entries.
`secondmate-provisioning` and `bin/fm-backlog-handoff.sh` own cross-home handoff safety.

Inspect the current task note before replacing its considered body, and archive the superseded body when recoverability matters rather than appending by default.
Verify volatile details against their authoritative config, live system, or API before acting, and correct or delete stale prose immediately.
Preserve durable structured identifiers, dependencies, and completion artifact links, and route reusable knowledge to `AGENTS.md` section 6's owners rather than scattering it through task notes.

## Brief authoring

`bin/fm-brief.sh` and its help own scaffold syntax, generated variants, status protocol, delivery-mode definitions of done, and exact safety mechanics.
Fill `## Captain's intent` (`{TASK}`) with the captain's own ask, stated boundaries, and only the context needed to understand its referents; never widen it into a generalized goal or coverage list.
Fill `## Firstmate spec` (`{FIRSTMATE_SPEC}`) with only the build instructions that ask requires, name excluded scope when the ask is narrow, and route unrequested generalization or hardening to follow-up work.
`bin/fm-dod-lib.sh` owns intent provenance, self-sufficiency, and no-mistakes authoring without added speaker labels or direct address.
Keep additions task-specific rather than repeating lifecycle instructions, and alter generated sections only when the task genuinely differs from the standard shape.
Every ship brief must retain the worktree-isolation assertion and stop if launched in the primary checkout.
If a ship task touches firstmate's shared tracked material, explicitly require `firstmate-coding-guidelines` before editing.
If a task will drive Herdr lifecycle behavior, scaffold with `--herdr-lab`; if that need appears after an unguarded scaffold, stop and regenerate rather than adding commands by hand.
The generated Herdr contract must use a named non-`default` isolated lab and its guarded helper for every lifecycle action.
Load `secondmate-provisioning` before creating or using a charter brief and preserve its idle-by-default and marked-return-channel contracts.
Status appends are sparse supervisor-actionable events, not routine progress; `bin/fm-classify-lib.sh` owns keyed open and resolved semantics.
