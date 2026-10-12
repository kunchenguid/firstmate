---
name: task-lifecycle
description: Load when taking in a captain request or task, dispatching and handing off to supervision, deciding the delivery path or merge authority, validating, or handling PR landing and scout outcomes.
user-invocable: false
metadata:
  internal: true
---

# Task lifecycle

The delivery lifecycle is an operational contract loaded on demand via the AGENTS.md routing table; referenced scripts own exact commands, flags, and data mechanics.

### Intake and authority

Resolve the project independently for every request.
An explicit project wins, a clear follow-up inherits its referent, and otherwise match the request against the registry, work under way, and project code or README.
Proceed on one confident match while naming the project in plain language; ask one concise question when multiple or no projects plausibly match.

Route by the nature of the work against each registered secondmate scope, not by a non-exclusive clone list.
Keep `local-only` work in the main home.
Send in-scope work to the fitting secondmate unless it is blocked or the captain explicitly redirects it; do not read the secondmate's chat because marked routed replies return through its status or referenced document.
If no secondmate scope fits, use the main home or discuss creating an appropriate persistent secondmate.
For one-off or infrequent operational work, start with the simplest direct end-to-end path.
Do not build wrappers, control planes, policy layers, custom verifiers, or automation unless the direct path exposes a concrete blocker or repeated need that justifies the added machinery.

Before commissioning an investigation, consult existing reports and established evidence.
Classify the deliverable:

- **Ship** is the default and produces a project change through the selected delivery mode; once implementation is authorized, dispatch a ship and keep any remaining bounded research inside it unless unresolved uncertainty could materially change whether or what to build.
- **Scout** produces knowledge in `data/<id>/report.md`, never a PR, and is appropriate for investigation, diagnosis, planning, reproduction, or audit work when the captain explicitly requests a separate knowledge or design deliverable or unresolved uncertainty could materially change whether or what to build.

- If established evidence already answers an informational question, relay it without a design-only scout; when implementation intent is unclear, answer and ask one concise implementation question when useful rather than dispatching speculative design work.
- Never both present a likely-enough solution and launch a parallel design exercise that is not expected to change it.
- A diagnostic request, report, recommendation, or implementation-ready finding is evidence, not authorization to change code.
- Load `diagnostic-reasoning` before scoping a reported bug and before acting on a diagnostic report.

Resolve every ship task's concrete delivery mode and `yolo` merge posture at intake.
Pass the mode explicitly to the brief, and pass both values explicitly to the spawn and any scout promotion; each command refuses to guess the values it consumes.
A current explicit captain instruction wins; otherwise the project's registry entry is the captain's standing posture, and dropping below its rigor needs a reason you can state.
Resolve the project's registered ship-branch prefix the same way, via `bin/fm-project-mode.sh --branch-prefix <project>`, and pass it explicitly to the brief, ship spawn, and scout promotion as `--branch-prefix` (default `fm/` needs no flag).
When the work must start from and target a branch other than the project's default, such as a named feature or release branch, pass it to the ship or scout brief and spawn as `--base-branch <branch>`; any promotion reads it from task meta.
On a `no-mistakes-prod-only` project, classify the task's surface: internal-only tooling, automation, contributor or operator process, and release or submission work ships `direct-PR`, while product-facing, mixed, and uncertain work ships `no-mistakes`; never infer internal-only from file location or project name.
An unregistered project or absent registry resolves to `no-mistakes` with yolo off, and the registration gap goes to the captain.
Record the resulting mode, `yolo` merge posture, and the one-line reason for any deviation in the backlog item note.

Treat file or subsystem overlap as a risk signal rather than an automatic reason to wait, and dispatch isolated work immediately with no concurrency cap when each change can be independently implemented and validated and the selected delivery path can reconcile ordinary rebases or conflicts.
A project's declared machine capacity (`config/project-capacity`) still bounds that dispatch: a spawn beyond it exits 75 without launching, and its item stays queued rather than blocked.
Serialize only for a true semantic dependency, shared mutable external state, incompatible concurrent migration, or another concrete condition that makes independent progress or reconciliation unsafe; same-file editing alone is insufficient, and genuine blockers remain durable.
Write the task-specific brief under the `crewmate-briefs` skill before spawning.
Fill the task subsections according to the `crewmate-briefs` skill.

### Dispatch and supervision handoff

Spawn only through `bin/fm-spawn.sh` after the profile and backend checks in the `harness-dispatch` skill.
The spawn must resolve a genuine isolated task worktree distinct from the primary checkout; a failed isolation assertion stops the task.
When the configured tasks-axi backlog gate applies, the spawn itself moves the work item to In flight and refuses rather than dispatching work this home has no item for, so recording the dispatch is never a separate step to remember; a manual-backend home retains the hand-editing contract in `docs/configuration.md`.
After spawning, confirm the worker is processing the brief and handle any trust dialog through `harness-adapters`.
A persistent secondmate is recorded in the secondmate registry and runtime state, never as a backlog work item.

Steer a worker with ordinary text through fail-closed `fm-send`: the message becomes a durable record in the task's steering inbox (multi-line text is legal, local and remote alike) and the worker's terminal receives only a constant doorbell line, with the watcher re-ringing an unacknowledged local message and escalating a stuck one (`bin/fm-task-inbox-lib.sh`; `bin/fm-send.sh` owns the typed-plane carve-outs).
A remote secondmate steer rides the same durable-inbox model through the remote transport; after an unconfirmed delivery, only the exact `FM_PENDING_REPLY_EXISTING_CORR=<id>` resend command printed by `fm-send` is safe because it preserves the request body for remote enqueue deduplication (`bin/fm-send.sh` header).
When a steer answers an open keyed decision or blocker, pass `fm-send`'s `--resolve-key` so the answer itself closes that decision record at answer time, identically for local and remote workers (contract: `bin/fm-send.sh` header).
`fm-send` is the data plane for text the worker should read; never use its key or text paths for interrupt, exit, or other lifecycle control, because routing-marked lifecycle text becomes chat the worker reasons about instead of executing.
Drive a worker's lifecycle through `bin/fm-control.sh <task-id> interrupt|exit|relaunch`, which owns the per-runtime mechanics, verifies each action, and never tears down or discards anything ([`docs/agent-control.md`](../../../docs/agent-control.md)).
A secondmate's routed reply returns through status or a document pointer, not by firstmate peeking into its chat.
For the parent-owned correlation, recovery, and escalation contract on marked secondmate requests, see `bin/fm-pending-reply-lib.sh`.
When the captain adds or changes an ask mid-task, append the captain's words without added speaker labels or direct address to that brief's `## Captain's intent` and relay those words to the worker; Firstmate build constraints stay in `## Firstmate spec` or the steer.
Supervise all live work under the `supervision-protocol` skill.

### Selected delivery path and merge authority

The selected delivery path owns its own rigor.
When no-mistakes is selected, no-mistakes alone owns review, fixes, tests, documentation, push, PR, and CI; otherwise follow the faster path without adding an independent reviewer.
Never hold work outside no-mistakes for a manual clean verdict, stack serial manual reviews, or infer authority for one from security, architecture, or risk alone.
A separate review or audit is allowed only when the captain explicitly requests that deliverable or the authorized task is a knowledge-only review; one named question remains scoped to that question.
If fast-path risk needs more rigor, escalate whether to use no-mistakes instead of inventing a manual gate.
The path's worker, automated gates, and captain approval remain authoritative:

- **no-mistakes** runs the full pipeline through a PR, then waits for the configured merge authority.
- **direct-PR** has the worker push and open a PR without the no-mistakes pipeline, then waits for the configured merge authority.
- **local-only** has the worker stop with a clean ready branch, then waits for the configured merge authority before firstmate uses the guarded fast-forward merge path.

Delivery mode and `yolo` are orthogonal.
`yolo` governs merge authority only: with it off, the captain approves every PR merge and every local-only landing; with it on, firstmate merges green, in-scope work itself.
Never merge a red PR, or one with a required check that has not reported, under either setting unless a current explicit captain instruction names the GitHub check to waive; `bin/fm-pr-merge.sh`'s header owns the attended-only waiver mechanics and remaining guards.
Destructive, irreversible, and security-sensitive merges still escalate.
Without a current explicit captain instruction that states the concrete merge, the green default stands, and standing `yolo` cannot authorize a red merge; section 1 owns when such an instruction overrides a Firstmate-written standing rule within its exact scope.
Load `ask-user-authority` and `validation-supervision` before deciding or answering any ask-user finding; the implementation worker never answers its own finding.
Use `bin/fm-pr-merge.sh` for every task PR merge so merge metadata is recorded and an unproved merge is refused instead of reported as landed, and use `bin/fm-merge-local.sh` for approved local-only landing; never call a lower-level merge command around their guards.
After an autonomous merge, give the captain a one-line full-URL or local-main outcome.

### Validate

Load `validation-supervision` when a ship starts or already has an active no-mistakes validation run, including a mid-run requirement change or finding.

### PR ready, landing, and teardown

Load `ship-landing` when a ship reports a PR or ready branch, when deciding or monitoring landing, and before task cleanup.

### Scout outcome and promotion

Load `scout-completion` when a scout reports completion, presents a visual artifact for iteration, or is being considered for promotion to implementation.
