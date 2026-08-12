# Orca runtime backend

Orca is an experimental backend in which the Orca app owns both the task worktree and terminal endpoint.
The crewmate harness remains the agent process launched inside that endpoint.
Firstmate agents load [`firstmate-orca`](../.agents/skills/firstmate-orca/SKILL.md) before operating or recovering this backend.

## Setup

Pick Orca when you already use the Orca app and want Orca-managed worktrees and terminals instead of Treehouse plus a session multiplexer.
Orca is explicit-only and does not support secondmate spawns.
macOS remains the best-proven host; WSL is supported only for in-distro worktrees whose paths Firstmate can normalize (see Active limits).

Prerequisites:

- Orca app installed, running, and ready (macOS `/Applications/Orca.app`, or the Windows Orca EDA install with a WSL-managed terminal).
- An `orca` CLI on `PATH` that talks to that app (`brew install orca` on macOS; on WSL the managed launcher is often `orca-ide`, so a `~/.local/bin/orca` shim to that launcher is typical).
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

Select Orca with local `config/backend` containing `orca`, `FM_BACKEND=orca` for one launch, or an explicit request to Firstmate.
It is never auto-detected.

Before any spawn mutates repository state, Firstmate requires `orca status --json` to report `reachable=true` and `state="ready"`.
The first task for a project registers that repository with `orca repo add --path` when needed.
No manual repository registration is required.
When Orca returns a WSL UNC worktree path (`\\wsl.localhost\<Distro>\...`, `//wsl.localhost/...`, or `\\wsl$\...`), Firstmate normalizes it to the Linux absolute path before isolation checks and metadata; the opaque `orca_worktree_id` is left unchanged for Orca API calls.

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
`fm-send.sh` types and verifies composer clearance through the fleet-wide classifier in `bin/fm-composer-lib.sh`, retrying Enter without retyping when a slash popup first fills an argument placeholder.
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

- Orca is explicit-only; it is never auto-detected.
- The app must be running and report ready.
- Secondmate spawns are unsupported.
- Escape is unsupported.
- Orca exposes no stable CLI version or protocol marker, so readiness is the compatibility gate rather than a version floor.
- Only the verified terminal-handle and worktree result fields are accepted; speculative response shapes are rejected.
- Worktree filesystem paths must resolve on the host that runs Firstmate.
  WSL UNC forms for in-distro paths are normalized; true Windows drive paths are not rewritten and still fail isolation closed.
- End-to-end WSL spawn, send, and teardown remain experimental relative to the macOS evidence in [`verification/runtime-backends.md`](verification/runtime-backends.md#orca).

## Regression entry points

```sh
tests/fm-backend-orca.test.sh
tests/fm-backend.test.sh
tests/fm-bootstrap.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#orca) records the real readiness and response-shape smoke.
