# Orca runtime backend

Orca is an experimental macOS backend in which the Orca app owns both the task worktree and terminal endpoint.
The crewmate harness remains the agent process launched inside that endpoint.
The operator checklist below is part of this document; there is no separate Orca skill.

## Setup

Pick Orca when you already use the Orca macOS app and want Orca-managed worktrees and terminals instead of Treehouse plus a session multiplexer.
Orca is macOS-only, explicit-only, and does not support secondmate spawns.

Prerequisites:

- `/Applications/Orca.app` installed, running, and ready.
- The `orca` CLI, installed with `brew install orca`.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

Select Orca with local `config/backend` containing `orca`, `FM_BACKEND=orca` for one launch, or an explicit request to Firstmate.
It is never auto-detected.

Before any spawn mutates repository state, Firstmate requires `orca status --json` to report `reachable=true` and `state="ready"`.
The first task for a project registers that repository with `orca repo add --path` when needed.
No manual repository registration is required.

Open the Orca app to watch a task's terminal.
Routine supervision uses the recorded endpoint through `bin/fm-peek.sh <id>` and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'`.
Enter and Ctrl-C are supported; Escape is not.

## Task shape and metadata

Each task has one Orca-managed git worktree and one Orca terminal.
`fm-spawn.sh` does not call Treehouse for Orca tasks.
The normal isolation and unlanded-work refusal rules still apply.

```text
backend=orca
window=fm-<id>
terminal=<orca terminal handle>
orca_worktree_id=<orca worktree id>
worktree=<absolute Orca worktree path>
```

`window=` remains the caller-facing Firstmate alias.
`terminal=` and `orca_worktree_id=` are the backend authority used by operation and cleanup paths.

## Current lifecycle and safety

Spawn registers the repository, creates an independent worktree, reuses only the verified `result.terminal.handle` returned by Orca or creates a terminal explicitly, installs harness hooks, records metadata, and launches the selected harness.
Exact command flags and response parsing are owned by `bin/backends/orca.sh` and script help.

`fm-peek.sh` reads with `orca terminal read`.
An ordinary metadata-routed `fm-send.sh` text steer becomes a durable steering-inbox record, and only its best-effort constant doorbell passes through Orca's submit machinery.
On the typed plane, `fm-send.sh` verifies composer clearance through the fleet-wide classifier in `bin/fm-composer-lib.sh`, retrying Enter without retyping when a slash popup first fills an argument placeholder.
The composer read is one bounded tail of the live terminal and never pages backward into scrollback, so a stale startup banner cannot compete with the bottom-anchored composer.
A bare shell row is `unknown`, not an empty agent composer, and plain-text captures degrade a glyph row carrying trailing text to `unknown` rather than a false `pending`.
The watcher has no native Orca busy signal, so each harness adapter's semantic lifecycle supplies worker state.
Grok alone retains its isolated rendered-tail fallback.

Cleanup keeps all shared Firstmate safety checks.
A scout still requires its report and completed decision inventory.
A ship still refuses dirty or unlanded work.
Before release, cleanup resolves the recorded Orca worktree id and verifies its path matches the recorded worktree path.
A missing, unreadable, or mismatched identity preserves metadata and stops rather than deleting anything.
After those checks, Firstmate closes the exact terminal and releases the exact worktree with Orca's worktree command.
It never raw-deletes an Orca worktree.

## Active limits

- Orca is macOS-only and explicit-only.
- The app must be running and report ready.
- Secondmate spawns are unsupported.
- Escape is unsupported.
- Orca exposes no stable CLI version or protocol marker, so readiness is the compatibility gate rather than a version floor.
- Only the verified terminal-handle and worktree result fields are accepted; speculative response shapes are rejected.

## Regression entry points

```sh
tests/fm-backend-orca.test.sh
tests/fm-backend.test.sh
tests/fm-bootstrap.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#orca) records the real readiness and response-shape smoke.

## Operator checklist (Stand 2026-08-26)

Transferred here from the retired `firstmate-orca` skill.
Orca is a runtime backend, not an agent harness: it owns the task endpoint and, for Orca, the task worktree, while the harness is the agent process launched inside that endpoint.
Load `harness-adapters` for harness-specific launch, interrupt, resume, trust-dialog, and skill-invocation facts.
Prefer the `bin/fm-*` helpers over raw `orca` commands, and use raw `orca` only when the helper surface cannot answer an inspection question - the recorded firstmate metadata stays the task identity.

**Preflight.**
Work from the current firstmate home or repo root; when `FM_HOME` is set, operational state lives under `$FM_HOME` while the helpers still run from this repo's `bin/`.
Confirm Orca is intentionally selected (`--backend orca`, `FM_BACKEND=orca`, or local `config/backend`), that the app is running and its readiness checks pass, and inspect active `state/*.meta` before changing the selection.
A backend switch affects future spawns only; existing tasks keep their recorded backend.
Reconcile watcher wakes before unrelated work whenever Orca tasks are already in flight.

**Spawn.**
Use `bin/fm-spawn.sh` so the brief, worktree, terminal, metadata, status file, and watcher surface are created together, passing `--backend orca` for a one-off.
Then check `bin/fm-peek.sh fm-<id>` for launch failures or trust dialogs, `state/<id>.meta` for `backend=orca`, `terminal=`, `orca_worktree_id=`, and `worktree=`, `bin/fm-crew-state.sh <id>` when the run state matters, and `bin/fm-watch.sh` while this session owns supervision.
Never hand-create an Orca worktree or terminal for a normal task, and never patch metadata to make an externally created Orca terminal look like a firstmate task.

**Supervision.**
Use `bin/fm-peek.sh`, `bin/fm-send.sh <id> '...'`, `bin/fm-crew-state.sh`, and `bin/fm-teardown.sh`; the stable alias is `fm-<id>` and ordinary local text steers may contain newlines because they ride the durable inbox.
Treat `state/<id>.meta` as the routing record and Orca's own ids as backend implementation detail.
If a steer fails to enqueue or a typed-plane send fails to submit, read the reported failure and peek before repeating anything.

**Recovery.**
Read `state/<id>.meta` and the status tail first, confirm the task really is Orca-backed, and use the recorded `terminal=`, `orca_worktree_id=`, and `worktree=` as its identity.
Avoid raw deletion of Orca worktrees and manual branch cleanup, and stop to inspect whenever a recorded path or worktree id no longer matches expectations.
Teardown follows the normal landing rules: a scout after its report exists and the `captain-hold-lifecycle` completion gate passes, a ship only after the work is landed by its project mode.

**Smoke test.**
Keep it to lifecycle plumbing: select Orca intentionally for a disposable task, spawn through `bin/fm-spawn.sh`, confirm the metadata records backend, terminal, Orca worktree id, and isolated worktree path, verify peek, a short steer, watcher wake behavior, and crew state, tear down through `bin/fm-teardown.sh`, and restore the previous backend selection.
Never mix a backend smoke test with unrelated feature work.
