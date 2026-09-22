# Orca runtime backend

Orca is an experimental macOS backend in which the Orca app owns both the task worktree and terminal endpoint.
The crewmate harness remains the agent process launched inside that endpoint.
Firstmate agents load [`firstmate-orca`](../.agents/skills/firstmate-orca/SKILL.md) before operating or recovering this backend.

## Setup

Pick Orca when you already use the Orca macOS app and want Orca-managed worktrees and terminals instead of Treehouse plus a session multiplexer.
Orca is macOS-only and explicit-only.
Ordinary ships and scouts use terminal mode by default; persistent Secondmates use capability-gated native supervision.

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
Ordinary ships and scouts may opt into native supervision with `--orca-mode supervised`.
The native mode is capability-gated. The live evidence covers the Claude and Codex capability probe; Cursor is unavailable in this environment and is skipped. Pi is intentionally not in the native set, so ordinary Pi ships and scouts stay on the tested terminal adapter (and a persistent Pi Secondmate refuses rather than claiming native support).
Orca binds a native Run to the coordinator's own Orca terminal, so native mode also requires running Firstmate inside a live Orca terminal (`ORCA_TERMINAL_HANDLE` set and accepted by `orca orchestration run-current`). Outside one, or with a stale inherited handle, ordinary ships and scouts fall back to the terminal adapter before launch, and a persistent Secondmate refuses.
Native mode never asks Orca to launch its own agent. Firstmate runs its complete launch in the task's Orca terminal first, exactly as terminal mode does, and only then attaches supervision to that terminal. Canonical and raw/custom launches keep every argument and environment assignment.
Persistent Secondmates require native supervision and reuse their exact existing Firstmate home workspace.
Firstmate remains authoritative for the Secondmate home, backlog, idle-by-default behavior, child routing, restart, and explicit retirement.

## Task shape and metadata

Each ordinary task has one Orca-managed git worktree and one Orca terminal.
A native Secondmate binds to one exact pre-existing Orca workspace instead of creating a replacement worktree.
Native supervision additionally records the Orca Run, Task, Dispatch, and worker identities.
Those durable native identities are authoritative; terminal handles, PTY/incarnation ids, and pane keys are rebindable routing evidence.
Native metadata routes state and reads through `dispatch:<orca_dispatch_id>`; direct PTY attachment is used only after exact Dispatch, worktree, pane, and incarnation rebind checks.
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
With `--orca-mode supervised`, the full launch runs in the terminal first. Spawn then creates a Run, attaches the running agent with `orchestration worker-start --terminal <handle> --worktree id:<worktree-id>`, verifies that the returned Run/Task/Dispatch/worker/worktree identities and terminal handle match, and requires a complete exact transcript observation from `worker-read` before it treats launch consumption as proven.
Exact command flags and response parsing are owned by `bin/backends/orca.sh`, `bin/backends/orca-supervised.sh`, and script help.

`fm-peek.sh` reads native workers with transcript-first `worker-read` source/cursor/clipping semantics and marks terminal fallback or clipped output as incomplete evidence.
A native worker read or state projection refuses an identity mismatch instead of following a stale terminal handle.
An ordinary metadata-routed `fm-send.sh` text steer becomes a durable steering-inbox record, and native supervision sends only its constant doorbell through the Dispatch mailbox; a mailbox failure falls back to the terminal doorbell while retaining that durable record.
The control plane uses a rebound terminal interrupt, native `worker-stop` for a positively live worker, `worker-abandon` only for an unknown process state, and `worker-release` only after exact ownership and settlement.
Recovery uses `worker-abandon` only when process state is unknown.
Cleanup uses `worker-release` only after exact worker identity, coordinator ownership, and settled state are proven.
Firstmate's durable inbox, status events, captain decisions, validation, delivery, and unlanded-work contracts remain authoritative.
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
After those checks, terminal mode closes the exact terminal. Native mode settles and releases the exact Dispatch, then closes the terminal Firstmate launched, because Orca keeps attached terminals open on release.
Ordinary tasks then release the exact worktree with Orca's worktree command.
Secondmate retirement releases its native Dispatch and removes the Firstmate-owned home; it never removes a persistent home as a side effect of a worker-stop.
It never raw-deletes an Orca worktree.
A close the CLI never attempted, because `orca` is not on the path, stops cleanup with the metadata intact even under `--force`: removing those records would leave nothing on disk naming a terminal that may still be live.
Reinstall the CLI and rerun; [`verification/runtime-backends.md`](verification/runtime-backends.md) "Endpoint close" owns what this arm can and cannot prove about its own close.

## Active limits

- Orca is macOS-only and explicit-only.
- The app must be running and report ready.
- Native Secondmate launch requires an exact existing workspace row from `orca worktree ps`; missing or ambiguous workspace identity refuses launch.
- Native relaunch, including Secondmate restart, runs the full launch in a fresh terminal in the recorded workspace, attaches it with `--task` and `--retry-of`, and closes the settled prior terminal only after the replacement is attached. A recorded native task never falls back to terminal mode: if the capability probe fails, relaunch refuses and keeps the record.
- If a fresh attach fails after the launch, spawn closes the launched terminal so no agent runs outside task control, then releases the worktree along with the unpublished record. A failed relaunch attach keeps the recorded worktree.
- If a fresh native spawn cannot settle a Dispatch it was given, including one from a partial receipt with no worker or pane identity, spawn writes a `cleanup_recovery=orca` record. It does this for Secondmates too. That record only needs a Dispatch id. When the Run, Task, worker, incarnation, or pane identity is missing, teardown proves the Dispatch belongs to the recorded workspace, abandons it, releases it only when full ownership is proven, and closes its terminal. A record with complete identity goes through the ordinary stop, poll, and release settlement instead. For a ship, teardown then removes the worktree. For a Secondmate it removes only the record, the task temp root, and the launch namespace, and keeps the persistent home. Spawn and relaunch refuse to write over a recovery record. The session-start liveness sweep and the Secondmate restart gate skip it. Ordinary supervised records still need every native identity.
- Escape is unsupported.
- Native supervision requires agent-context schema 1 and the required command shapes, while terminal supervision continues to use runtime readiness as its compatibility gate.
- Pi native supervision is unverified and deliberately excluded; ordinary Pi tasks use terminal fallback and persistent Pi Secondmates refuse launch.
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
