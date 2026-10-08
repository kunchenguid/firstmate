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

## Attended Codex primary continuation

A verified attended Codex primary in an Orca terminal uses one app-owned foreground continuation process.
It establishes the identity-matched singleton handling successor before notifying Codex, while the primary alone drains and acknowledges durable wakes.
The Codex Stop registration ensures that owner before running the existing generic guard; the second-stop safeguard remains intact.
Workers, other runtimes, away mode and supervision-host homes keep their existing behavior.
The rendered [Orca/Codex protocol](supervision-protocols/codex-orca.md) owns the agent operation, and [`fm-codex-orca-continuation.py`](../bin/fm-codex-orca-continuation.py) owns exact commands, receipt states and cleanup mechanics.

The continuation process requires Python 3.9 or newer and local macOS/Linux process and file-lock support.
Its Linux CLI selection follows Orca's exported command or managed-terminal context; outside a managed Linux terminal the installed Orca CLI is `orca-ide`, because bare `orca` can name the desktop screen reader.
That continuation boundary does not establish Linux support for this backend's separate spawn/teardown implementation.
The adapter accepts no remote-pairing selectors or endpoint-adoption operation.
A changed primary PID/birth/runtime/incarnation fails explicitly without rebinding.
Input acceptance remains distinct from a started model turn, and only the CLI's exact reported retry identity permits a bounded retry of the same payload.
An unconfirmed delivery retains durable work and a protected successor for inspection rather than creating a fresh request on silence.
A confirmed turn-started generation whose handling later reopens without ACK is re-presented exactly once; ensure then refuses until root drains and acknowledges it.

Installation uses the checked-out template's tracked `.codex/hooks.json` and `bin/` files, with the normal Codex hook trust flow.
Keep the hook, adapter and generation-aware watcher libraries from the same checked-out template revision; strict watcher health also binds to the exact code path.
Before attempting a turn end, verify that the Stop hook actually loaded by Codex uses the same installed code root as the continuation owner's watcher.
An owner's ready result does not prove this: a guard loaded from another code root rejects that watcher even when both revisions are identical and the beacon is fresh.
The guard must evaluate the real primary home; pointing its root at an exempt task worktree does not establish Stop integration.
From the actual lock-owning Orca primary, `python3 bin/fm-codex-orca-continuation.py ensure --home "$FM_HOME"` is the smallest update/readiness entry point; it reuses a verified owner and refuses an incompatible live binding, and it also refuses a matching owner while a prior delivery is unresolved or a re-presented generation is unacknowledged.
Installation and Codex hook trust or reload must precede the attended native acceptance test; the readiness command does not install or reload hooks.
Global dotfile distribution is separate from this project-scoped installation.
The [runtime verification record](verification/runtime-backends.md#orca) distinguishes portable behavior tests from live vendor lifecycle evidence.

## Active limits

- Orca spawning is macOS-only and explicit-only.
- The app must be running and report ready.
- Secondmate spawns are unsupported.
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
tests/fm-codex-orca-continuation.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#orca) records the real readiness and response-shape smoke.
