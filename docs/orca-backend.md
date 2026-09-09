# Orca runtime backend

Orca is an experimental macOS backend in which the Orca app owns both the task worktree and terminal endpoint.
The crewmate harness remains the agent process launched inside that endpoint.
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
Enter and Ctrl-C are supported; Escape is not.

## Task shape and metadata

Each task has one Orca-managed git worktree and one Orca terminal.
`fm-spawn.sh` does not call Treehouse for Orca tasks.
The normal isolation and unlanded-work refusal rules still apply.

```text
backend=orca
window=fm-<id>
terminal=<orca terminal handle>
orca_worktree_id=<repo id>::<absolute Orca worktree path>
worktree=<absolute Orca worktree path>
```

`window=` remains the caller-facing Firstmate alias.
`terminal=` and `orca_worktree_id=` are the backend authority used by operation and cleanup paths.

Unlike every other backend's opaque endpoint atom, an Orca worktree id is composite: the repository id, then a literal `::`, then the worktree's absolute path.
Both halves come from the same `orca worktree create --json` response that supplies `worktree=`, so the id's path half is the recorded worktree path.
Cleanup validation splits the value on its first `::` and refuses the record unless both halves are non-empty, the repository id half is a plain endpoint atom, and the path half is absolute, free of control characters, and exactly the task's own recorded `worktree=`.
That last check is a cross-record consistency check rather than a character rule: a record whose id names a different directory than the task's own worktree refuses instead of releasing the wrong worktree.
A value that cannot be parsed or does not agree with the record preserves task state and names the concrete reason.

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
Beyond the record-level identity check above, cleanup also asks Orca to resolve the recorded worktree id and verifies the path Orca reports matches the recorded worktree path.
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
- Orca's worktree shape is unverified against the spawn-time Claude workspace-trust check in `bin/fm-claude-trust.sh`, which refuses any path that is not a linked git worktree sharing the project's git common dir, so a claude spawn on Orca fails loudly at that check rather than launching if Orca clones instead of linking.

## Regression entry points

```sh
tests/fm-backend-orca.test.sh
tests/fm-teardown-endpoint-safety.test.sh
tests/fm-backend.test.sh
tests/fm-bootstrap.test.sh
```

`tests/fm-teardown-endpoint-safety.test.sh` pins the composite worktree id rule above: the real `<repo id>::<absolute path>` shape validates, every structural defect refuses with its concrete reason, and the shared endpoint-atom rule the other backends use stays unwidened.

[`verification/runtime-backends.md`](verification/runtime-backends.md#orca) records the real readiness smoke and the dated response-shape observations.
