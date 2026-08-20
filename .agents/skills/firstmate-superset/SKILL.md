---
name: firstmate-superset
description: Agent-only operator checklist for Firstmate's Superset runtime backend. Use when switching to Superset, spawning or supervising Superset-backed work, smoke-testing Superset backend behavior, debugging Superset task state, or reconciling Superset-backed task metadata.
user-invocable: false
metadata:
  internal: true
---

# firstmate-superset

Use this as the operator checklist for Firstmate's experimental Superset runtime backend.
It does not replace `AGENTS.md`, `docs/superset-backend.md`, or `harness-adapters`.

Superset is a runtime backend, not an agent harness.
The runtime backend owns the task endpoint and, for Superset, the task workspace (its git worktree).
The harness is the agent process launched inside that terminal, such as `claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, or `kimi`.
Load `harness-adapters` for harness-specific launch, interrupt, resume, trust-dialog, and skill-invocation facts.

Implementation details, metadata fields, teardown guarantees, and limitations live in `docs/superset-backend.md`.
`docs/verification/runtime-backends.md` "Superset" owns active smoke evidence.
Prefer the `bin/fm-*` helpers over raw `superset` commands.
Use raw `superset` only when the helper surface cannot answer the inspection question, and keep the recorded firstmate metadata as the task identity.

## Preflight

Work from the current firstmate home or repo root.
If `FM_HOME` is set, remember that operational state lives under `$FM_HOME` while the helper scripts still run from this repo's `bin/`.

Before switching or spawning against Superset:

- Confirm Superset is intentionally selected through `--backend superset`, `FM_BACKEND=superset`, or local `config/backend`.
- Confirm `superset status --json` reports a running, healthy host service before expecting spawn to work.
- Confirm the target project is already registered with Superset (`superset projects list --json`); this adapter refuses loudly rather than auto-registering an unregistered one.
- Inspect active `state/*.meta` records before changing backend selection.
- Treat a backend switch as affecting future spawns only; existing tasks keep their recorded backend.
- Reconcile watcher wakes before unrelated work, especially if Superset tasks are already in flight.

## Spawn

Use `bin/fm-spawn.sh` so firstmate creates the brief, workspace, terminal, metadata, status file, and watcher surface together.
Pass `--backend superset` for a one-off Superset task, or rely on the already-selected Superset backend when that selection is intentional.

After spawn, check the task with firstmate helpers:

- `bin/fm-peek.sh fm-<id>` for launch failures, trust dialogs, or first output.
- `state/<id>.meta` for `backend=superset`, `superset_workspace_id=`, `superset_terminal_id=`, and `worktree=`.
- `bin/fm-crew-state.sh <id>` when the current run state matters.
- `bin/fm-watch.sh` whenever there are tasks in flight and this session owns supervision.

Do not manually create the Superset workspace or terminal for a normal firstmate task.
Do not manually patch metadata to make an externally-created Superset terminal look like a firstmate task.

## Supervision

Use `bin/fm-peek.sh`, `bin/fm-send.sh`, `bin/fm-crew-state.sh`, and `bin/fm-teardown.sh` for routine operation.
For steer messages, send short lines through `bin/fm-send.sh <id> '...'`; the stable `fm-<id>` alias also works.
Put long instructions in the task brief or a temporary file and point the crewmate at that file.

When supervising, treat `state/<id>.meta` as the routing record and Superset's own ids as backend implementation details.
The stable firstmate alias is `fm-<id>`.
The recorded `superset_workspace_id=` and `superset_terminal_id=` fields are what backend helpers use under the hood, reconstructed into the live `<workspace_id>:<terminal_id>` target by `fm_backend_target_of_meta`.
