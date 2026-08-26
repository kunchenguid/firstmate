# Orca runtime backend

Orca is a macOS backend in which the Orca app owns both the task worktree and terminal endpoint.
The crewmate harness remains the agent process launched inside that endpoint.
Its spawn, read, send, and cleanup paths are verified against the real app (see [`verification/runtime-backends.md`](verification/runtime-backends.md#orca)), and it additionally supplies a recovery-grade agent-state classifier, a native busy signal, and idle-clean `exit`/`relaunch` for the harnesses Orca hooks (claude and codex); "Active limits" below records where that scope ends.
Firstmate agents load [`firstmate-orca`](../.agents/skills/firstmate-orca/SKILL.md) before operating or recovering this backend.

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
Enter and Ctrl-C (as a real 0x03 byte) are delivered; a raw ESC byte is not a verified turn-cancel on Orca, so Escape is not offered as a control-plane interrupt (see "Active limits").

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
For a claude or codex task Orca exposes a native busy signal from its structured `worktree ps` agent model (`working` -> busy, `done` -> idle), consumed as a busy fallback the same way herdr's native verdict is; for any other harness the watcher falls back to that harness adapter's own semantic lifecycle, and grok retains its isolated rendered-tail fallback.

### Agent state and lifecycle control

`fm_backend_orca_agent_state` correlates a terminal against Orca's `worktree ps` agents[] model (keyed by the pane key `tabId:leafId`).
That model is populated only for the harnesses Orca hooks - claude and codex - so the classifier is recovery grade for those: a live agent reads `alive`, an agent that has exited to a shell reads `dead`, and a stale handle reads `missing`.
For any other harness Orca provides no structured agent signal, so a still-connected terminal with no agent entry reads `unverified`, never a false `dead` (the classifier takes the harness for exactly this reason).

`bin/fm-control.sh` `exit` and `relaunch` are therefore available for claude and codex tasks, and only for an IDLE agent: `/exit` is submitted cleanly with no interrupt, and the agent-state classifier proves the stop.
A BUSY claude or codex agent's `exit` refuses, because it would first need a mid-turn interrupt and a raw ESC is not a verified cancel on Orca.
`exit`/`relaunch` of any other harness on Orca refuses at the tracked-harness gate, since a stop Orca cannot observe cannot be proven.

Cleanup keeps all shared Firstmate safety checks.
A scout still requires its report and completed decision inventory.
A ship still refuses dirty or unlanded work.
Before release, cleanup resolves the recorded Orca worktree id and verifies its path matches the recorded worktree path.
A missing, unreadable, or mismatched identity preserves metadata and stops rather than deleting anything.
After those checks, Firstmate closes the exact terminal and releases the exact worktree with Orca's worktree command.
It never raw-deletes an Orca worktree.

## Active limits

- Orca is macOS-only and explicit-only. Other platforms are not smoke-verified and are not claimed.
- The app must be running and report ready.
- Secondmate spawns are unsupported.
- Recovery-grade agent state, the native busy signal, and `exit`/`relaunch` cover only the harnesses Orca hooks (claude, codex); every other harness reads `unverified` and its `exit`/`relaunch` is refused.
- `exit`/`relaunch` is idle-clean only: a raw ESC is not a verified turn-cancel on Orca and its agent model does not observe an interrupt, so a busy Escape-harness agent cannot be interrupted for exit.
- Orca exposes no stable CLI version or protocol marker, so readiness is the compatibility gate rather than a version floor.
- Only the verified terminal-handle and worktree result fields are accepted; speculative response shapes are rejected.

## Regression entry points

```sh
tests/fm-backend-orca.test.sh
tests/fm-backend.test.sh
tests/fm-bootstrap.test.sh
tests/fm-control.test.sh
FM_ORCA_AGENT_STATE_LIVE=1 tests/fm-orca-agent-state-live-e2e.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#orca) records the real readiness, response-shape, agent-state, and busy-signal smoke; the live guard reproduces the agent-state transitions against the real app.
