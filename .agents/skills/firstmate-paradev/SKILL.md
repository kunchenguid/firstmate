---
name: firstmate-paradev
description: >-
  Load when switching to Paradev, spawning or supervising Paradev-backed work, smoke-testing Paradev backend behavior, debugging Paradev task state, reconciling Paradev-backed task metadata, or before running any raw `superset` command that could close, archive, or retag a workspace.
user-invocable: false
metadata:
  internal: true
---

# firstmate-paradev

Use this as the operator checklist for Firstmate's experimental Paradev runtime backend.
It does not replace `AGENTS.md`, `docs/paradev-backend.md`, or `harness-adapters`.

Paradev is a runtime backend, not an agent harness.
The runtime backend owns the task endpoint and, for Paradev, the task worktree: one Paradev workspace per task.
The harness is the agent process Firstmate types into that workspace's shell terminal.
Load `harness-adapters` for harness-specific launch, interrupt, resume, trust-dialog, and skill-invocation facts.

Implementation details, metadata fields, teardown guarantees, and limitations live in `docs/paradev-backend.md`.
`docs/verification/runtime-backends.md` "Paradev" owns active CLI evidence.
Prefer the `bin/fm-*` helpers over raw `superset` commands.
Use raw `superset` only for read-only inspection the helper surface cannot answer, always with `--local --json`, and keep the recorded firstmate metadata as the task identity.

## Hazards that differ from other backends

- `superset workspaces archive` deletes the workspace's worktree folder, uncommitted files included, with no warning and even while a terminal is live.
  Never archive a crewmate workspace by hand; only `bin/fm-teardown.sh` archives, after its landing and identity checks.
- The `firstmate` sidebar tag is display only, and the captain's own workspace may carry it.
  Never list, steer, close, or archive workspaces by tag; a tagged workspace with no task record is not a crewmate.
- `superset workspaces update --tag` replaces a workspace's whole tag set, so do not retag recorded workspaces.
- The captain may run this session inside a Paradev workspace, so `SUPERSET_WORKSPACE_ID` in your own environment names the captain's workspace, never a task's.
- `superset status` can report a stale host service while every real call works; judge readiness by a real call such as `superset projects list --local --json`.

## Preflight

Work from the current firstmate home or repo root.
If `FM_HOME` is set, remember that operational state lives under `$FM_HOME` while the helper scripts still run from this repo's `bin/`.

Before switching or spawning against Paradev:

- Confirm Paradev is intentionally selected through `--backend paradev`, `FM_BACKEND=paradev`, or local `config/backend`; it is never auto-detected.
- Confirm the project's clone path is registered as a Paradev project.
  A spawn refusal naming `superset projects create --import` is a captain setup step: report it, and do not register the project yourself.
- Inspect active `state/*.meta` records before changing backend selection.
- Treat a backend switch as affecting future spawns only; existing tasks keep their recorded backend.
- Reconcile watcher wakes before unrelated work, especially if Paradev tasks are already in flight.

## Spawn

Use `bin/fm-spawn.sh` so firstmate creates the brief, workspace, terminal, metadata, status file, and watcher surface together.
Pass `--backend paradev` for a one-off Paradev task, or rely on the already-selected Paradev backend when that selection is intentional.

After spawn, check the task with firstmate helpers:

- `bin/fm-peek.sh fm-<id>` for launch failures, trust dialogs, or first output.
- `state/<id>.meta` for `backend=paradev`, `terminal=`, `paradev_workspace_id=`, `paradev_project_id=`, and `worktree=`.
- `bin/fm-crew-state.sh <id>` when the current run state matters.
- `bin/fm-watch.sh` whenever there are tasks in flight and this session owns supervision.

If Paradev's native state for a launched Claude task stays `starting` while the worker is plainly running, Paradev's hooks are not loading in Claude's active configuration directory.
Supervision still works through Firstmate's own hooks; report the setup gap to the captain with the fix named in `docs/paradev-backend.md` "Native agent state" rather than editing local Claude or Paradev configuration.

Do not manually create a Paradev workspace or terminal for a normal firstmate task, and do not adopt an existing workspace.
Do not manually patch metadata to make an externally-created workspace look like a firstmate task.

## Supervision

Use `bin/fm-peek.sh`, `bin/fm-send.sh`, `bin/fm-crew-state.sh`, and `bin/fm-teardown.sh` for routine operation.
For steer messages, use `bin/fm-send.sh <id> '...'`; the stable `fm-<id>` alias also works, and ordinary local text steers may contain newlines because they ride the durable inbox.

Treat `state/<id>.meta` as the routing record and Paradev's ids as backend implementation details.
A native idle reading does not prove a free input box, because a harness dialog that is not a permission request also reads as idle; peek before concluding a worker is waiting for input.

If an ordinary steer fails to enqueue, or a typed-plane `fm-send` fails to submit, do not immediately repeat the instruction.
Read the reported failure and peek first, then decide whether the record exists or the target is busy, waiting on a prompt, stuck behind a dialog, or genuinely wedged.
`bin/fm-control.sh` exit and relaunch refuse on Paradev; for harness-specific interrupts, load `harness-adapters`.

## Recovery

For a messy Paradev-backed task:

1. Read `state/<id>.meta` and the relevant status tail first.
2. Confirm the task is actually Paradev-backed before using Paradev-specific assumptions.
3. Use the recorded `terminal=`, `paradev_workspace_id=`, and `worktree=` as the task identity.
4. Prefer firstmate helpers for peek, send, state, and teardown.
5. Never archive a workspace, close a terminal, or delete a branch by hand.
6. Stop and inspect if the recorded worktree path, workspace id, or project registration no longer matches expectations.
   A workspace archived outside Firstmate already took its worktree with it; report that to the captain instead of forcing cleanup.

Teardown remains governed by the normal firstmate landing rules.
Scout work can be torn down after the report exists and the `captain-hold-lifecycle` completion gate passes.
Ship work can be torn down only after the work is landed by its project mode.

## Smoke Test

Keep Paradev smoke tests focused on lifecycle plumbing:

1. Select Paradev intentionally for a disposable task or scout.
2. Spawn through `bin/fm-spawn.sh`.
3. Confirm metadata records the Paradev backend, terminal, workspace id, project id, and isolated worktree path, and that the workspace appears in the sidebar's tag folder.
4. Verify `bin/fm-peek.sh`, a short `bin/fm-send.sh` steer, watcher wake behavior, and `bin/fm-crew-state.sh`.
5. Tear down through `bin/fm-teardown.sh` after the task is safely disposable or landed.
6. Restore the previous backend selection if Paradev was selected only for the smoke test.

Do not mix a backend smoke test with unrelated feature work.
