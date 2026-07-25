---
name: task-lifecycle
description: >-
  Agent-only procedure for task backlog, briefing, dispatch, validation, landing, cleanup, and scout promotion.
  Load before creating or updating a task work item, briefing, dispatching, steering, validating, landing, cleaning up, or promoting any ship or scout.
user-invocable: false
metadata:
  internal: true
---

# task-lifecycle

This skill is the single owner of Firstmate's conditional ship and scout procedure after the always-loaded intake, delivery-rigor, and authority rules in `AGENTS.md` sections 6 and 7 have classified the work.
Exact command syntax and flags remain with each script's header and current help.

## Backlog intake

`data/backlog.md` is the durable work-item queue, never an agent registry.
A persistent secondmate is represented by `data/secondmates.md` and its runtime record rather than by a backlog row.
Work routed to a secondmate belongs in that secondmate home's backlog and must not also remain in the main backlog.

Use compatible `tasks-axi` when the selected backend enables it and the documented manual path otherwise.
`.tasks.toml`, `docs/configuration.md`, and current `tasks-axi --help` own schema, compatibility, retention, archive behavior, and routine command syntax.
Inspect the current item before replacing its considered body, archive a superseded body when recoverability matters, and avoid append-only note growth.
Keep free-form notes free of temporary paths, moving versions, ephemeral identifiers, and copied current state that will rot.
Verify volatile facts against their authoritative live source before acting, preserve durable ids, dependencies, and artifact links, and route reusable knowledge through `AGENTS.md` section 5.

Record a ship or scout as under way when dispatching it.
Update the item on every task decision and completion.
When a main-home captain decision or relay reminder needs durable tracking, create its own captain-gated work item rather than hiding it in another task's prose.
Use `decision-hold-lifecycle` for unresolved decisions discovered in an investigation or visual review.
Re-evaluate queued work after every cleanup and whole-fleet review, and dispatch only work whose dependencies and time gates have cleared.
Use `secondmate-provisioning` and `bin/fm-backlog-handoff.sh` for cross-home handoff.

## Brief and spawn

Generate the task instructions through `bin/fm-brief.sh` and follow its current help.
Replace every `{TASK}` placeholder with a clear task description, acceptance criteria, constraints, and necessary context.
Keep additions task-specific rather than repeating standard lifecycle instructions, and alter generated sections only when the work genuinely differs from the scaffold.

Every ship brief must retain its path-based isolation assertion and stop when launched in firstmate's primary project copy.
If the task changes Firstmate's shared tracked material, explicitly require `firstmate-coding-guidelines` before editing.
If the task will start, stop, delete, restart, profile, or otherwise control Herdr lifecycle, generate the brief with `--herdr-lab`.
If that need appears after an unguarded scaffold was created, stop and regenerate it rather than adding lifecycle commands by hand.
The generated Herdr contract must use a named non-`default` isolated lab and its guarded helper for every lifecycle action.
Use `secondmate-provisioning` rather than this task procedure for a secondmate charter.

Load `harness-adapters`, resolve the configured profile and backend, and spawn only through `bin/fm-spawn.sh`.
The resolved project worktree must be a genuine isolated disposable copy distinct from the primary clone, and any failed isolation assertion stops dispatch.
After spawning, confirm the worker is processing the instructions and use `harness-adapters` for any trust dialog.
A ship or scout becomes an under-way backlog work item, while a persistent secondmate remains outside the backlog.

Use `FM_HOME=<this-firstmate-home> bin/fm-send.sh` for a short one-line steer unless `FM_HOME` is already set to the active home.
Put long instructions in a file and send only its pointer.
A secondmate's routed reply returns through status or a document pointer, never by firstmate reading its chat.
`bin/fm-pending-reply-lib.sh` owns correlation, delivery, recovery, and escalation for marked secondmate requests.
A failed steer triggers `stuck-crewmate-recovery` rather than an unverified resend loop.
After dispatch, keep the supervision required by `AGENTS.md` section 8 and `fleet-supervision`.

## Delivery-path rigor

The delivery path and authority boundaries in `AGENTS.md` section 7 govern every later step.
No-mistakes alone owns review, fixes, tests, documentation, push, PR creation, and CI for a no-mistakes task.
A direct-PR task follows its faster path without an independent reviewer.
A local-only task stops on a clean ready branch and waits for configured landing authority.
Never park work outside no-mistakes for a manual clean verdict, stack serial manual reviews, or infer a new review gate from security, architecture, or risk language.
If faster-path risk warrants the full pipeline, escalate whether to switch paths rather than inventing another gate.

## No-mistakes validation

After a no-mistakes worker creates its implementation commit, invoke validation on that same worker using the runtime-specific skill form from `harness-adapters`.
The task worker that starts a no-mistakes run drives the pipeline and owns every `no-mistakes axi run` and `no-mistakes axi respond` call through the next gate or outcome.
Firstmate never invokes `no-mistakes axi respond` for a crew-owned run.
Firstmate never starts a duplicate run.

An ask-user finding appears as a worker decision request.
Firstmate loads `ask-user-authority`, decides only within configured authority, and otherwise escalates to the captain.
Return one exact decision to the same worker, naming the decision key, step, action, affected finding ids, any required instructions, and the exact response command.
Require a matching `resolved` event, forbid `--yes`, and require the worker to process every synchronous return until completion or a genuinely new escalation.
Resume fleet supervision immediately after the decision lands.

Judge validation through the current-code-matched run step returned by `bin/fm-crew-state.sh <id>`, not shell liveness or the latest status event.
A running, fixing, or CI result remains working.
A parked approval or fix-review result requires the worker to follow the active gate help.
A passed or checks-passed result is complete, and a failed or cancelled result is a failure.
If the worker hand-edits, commits, aborts, or restarts while the run is active, steer it back to the pipeline response flow because the active run owns those changes.
The worker reports its PR when CI first becomes green rather than waiting for merge monitoring to finish.

## PR readiness and landing

For a no-mistakes ship, the ready event is `done: PR <url> checks green` after CI is green.
For a direct-PR ship, the ready event is `done: PR <url>` after the PR opens.
Run `bin/fm-pr-check.sh <id> <PR url>` so canonical PR and forge-head identity are recorded and merge monitoring is registered.
Tell the captain the complete `https://...` URL, a concise outcome, and the no-mistakes risk level when applicable.
A captain instruction to merge supplies explicit authority, and `yolo` is the only standing routine merge authority.
Never merge red work.

Use `bin/fm-pr-merge.sh` for every authorized task PR merge and `bin/fm-merge-local.sh` for every authorized local-only landing.
Never call a lower-level merge command around those guards.
After an autonomous landing, give the captain a one-line full-URL or local-main outcome.

A custom `state/<id>.check.sh` written by firstmate must be an ordinary single-link mode-`0700` file, print exactly one line only when firstmate should be notified, print nothing otherwise, and finish before `FM_CHECK_TIMEOUT`.
Bind its current bytes with `bin/fm-check-register.sh <id>` before monitoring may execute it.
Authenticated PR polling and X polling use their trusted generated owners rather than custom executable state.

## Ship cleanup

Clean up a ship only after landing is confirmed.
Run `bin/fm-teardown.sh <id>` and treat any uncommitted or unlanded-work refusal as a stop-and-investigate result.
Never bypass the refusal or use `--force` without the captain's explicit authority to discard that exact work.
After successful cleanup, record completion with the durable PR or local-main artifact, retain only the configured recent Done history, and re-evaluate ready queued work.

A persistent secondmate is not an ordinary ship and an empty queue is healthy.
Load `secondmate-provisioning` and require an explicit captain or main-firstmate retirement decision before retiring it.
Its home must contain no work under way, and forced discard still requires the captain.

## Scout completion and promotion

A scout completes only after it leaves a self-contained `data/<id>/report.md`.
Read the complete report and relay its findings to the captain rather than sending only a completion notice.
Use plain chat for a focused finding and `lavish-axi` only when multiple findings, options, or a structured plan benefit from a visual report.
Record the report as the Done artifact and re-evaluate the queue.

Before treating any investigation or visual review as complete, load `decision-hold-lifecycle` and complete its full unresolved-decision inventory.
A report may recommend implementation but does not authorize it.
Only after separate implementation authority exists may a scout become a ship.

Promote the existing scout through `bin/fm-promote.sh <id>` rather than creating a duplicate task.
Have the same worker inventory scratch state, return to a clean default-branch base, carry over only intended fix changes, create the ship branch, and then follow the project's selected delivery path.
Scratch commits and debugging edits never ride onto the ship branch, and a reproduced bug becomes the regression test.
After promotion, apply the ordinary ship validation, landing, and cleanup procedure above.

A scout's scratch worktree may be discarded only after the report exists and `decision-hold-lifecycle` permits completion.
A cleanup refusal means the deliverable or decision inventory is incomplete and must not be bypassed.
