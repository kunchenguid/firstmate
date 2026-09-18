# Orca runtime backend

Orca is an experimental backend in which the Orca app owns both the task worktree and terminal endpoint.
The crewmate harness remains the agent process launched inside that endpoint.
Firstmate agents load [`firstmate-orca`](../.agents/skills/firstmate-orca/SKILL.md) before operating or recovering this backend.

## Setup

Pick Orca when you already use the Orca app and want Orca-managed worktrees and terminals instead of Treehouse plus a session multiplexer.
Orca is explicit-only: nothing in the code gates this backend to macOS, and it is confirmed working on Linux, but it is never auto-detected regardless of platform.

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
orca_worktree_id=<orca repo id>::<absolute worktree path>
worktree=<absolute Orca worktree path>
```

`window=` remains the caller-facing Firstmate alias.
`terminal=` and `orca_worktree_id=` are the backend authority used by operation and cleanup paths.
Orca returns `orca_worktree_id=` as that composite of the Orca repo id and the worktree path, and cleanup validation requires both halves rather than treating the value as a simple name.

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
A close the CLI never attempted, because `orca` is not on the path, stops cleanup with the metadata intact even under `--force`: removing those records would leave nothing on disk naming a terminal that may still be live.
Reinstall the CLI and rerun; [`verification/runtime-backends.md`](verification/runtime-backends.md) "Endpoint close" owns what this arm can and cannot prove about its own close.

## Recovery

`orca terminal show --terminal <handle> --json` reports the terminal's own `connected` and `agentIdentity` fields, and the recovery-grade classifier in `bin/backends/orca.sh` (`fm_backend_orca_agent_state`) reads those directly rather than scraping the composer.
`connected=true` is `alive`, optionally downgraded to `ambiguous` when Orca reports an `agentIdentity` that the shared harness-process vocabulary (`bin/fm-agent-process-lib.sh`) does not recognize as a verified agent.
`connected=false` is `dead`.
A failed or unparseable read falls back to `orca status --json`: a separately confirmed ready runtime means the terminal is authoritatively gone (`missing`), while an unreachable runtime proves nothing either way (`unreadable`).
Only `dead` and `missing` license unattended recovery, so this classifier is what makes secondmate spawns on this backend safe to auto-recover.

## Active limits

- The app must be running and report ready.
- Escape is unsupported.
- Orca exposes no stable CLI version or protocol marker, so readiness is the compatibility gate rather than a version floor.
- Only the verified terminal-handle and worktree result fields are accepted; speculative response shapes are rejected.
- Orca's worktree shape is unverified against the spawn-time Claude workspace-trust check in `bin/fm-claude-trust.sh`, which refuses any path that is not a linked git worktree sharing the project's git common dir, so a claude spawn on Orca fails loudly at that check rather than launching if Orca clones instead of linking.

## Regression entry points

```sh
tests/fm-backend-orca.test.sh
tests/fm-backend.test.sh
tests/fm-bootstrap.test.sh
tests/fm-teardown-endpoint-safety.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#orca) records the real readiness and response-shape smoke.
