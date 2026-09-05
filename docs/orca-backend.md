# Orca runtime backend

Orca is an experimental macOS backend in which the Orca app owns both the task worktree and terminal endpoint.
The crewmate harness remains the agent process launched inside that endpoint.
Firstmate agents load [`firstmate-orca`](../.agents/skills/firstmate-orca/SKILL.md) before operating or recovering this backend.

## Setup

Pick Orca when you already use the Orca macOS app and want Orca-managed worktrees and terminals instead of Treehouse plus a session multiplexer.
Orca is macOS-only and explicit-only.

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
Enter, Ctrl-C, Escape, and Ctrl-U are all supported; Orca has no dedicated key primitive beyond `--interrupt` (Ctrl-C) and `--enter`, so Escape and Ctrl-U are delivered as their raw control bytes through `terminal send --text` (verified live).

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

`fm-peek.sh` reads with `orca terminal read --screen`, the rendered-screen mode: Orca's default stream mode stacks TUI repaints into fragments and is unsuitable for verifying rendered output, so every capture and composer read uses `--screen`.
An ordinary metadata-routed `fm-send.sh` text steer becomes a durable steering-inbox record, and only its best-effort constant doorbell passes through Orca's submit machinery.
On the typed plane, `fm-send.sh` verifies composer clearance through the fleet-wide classifier in `bin/fm-composer-lib.sh`, retrying Enter without retyping when a slash popup first fills an argument placeholder.
The composer read is one bounded rendered-screen tail of the live terminal and never pages backward into scrollback, so a stale startup banner cannot compete with the bottom-anchored composer.
A bare shell row is `unknown`, not an empty agent composer, and plain-text captures degrade a glyph row carrying trailing text to `unknown` rather than a false `pending`.
The watcher reads a native busy/idle signal from Orca's agent status (`worktree ps agents[].state`: `working` is busy, `done`/`blocked` are idle), correlated to the task's terminal; when Orca cannot attribute an agent it returns unknown and each harness adapter's semantic lifecycle supplies worker state.
Grok alone retains its isolated rendered-tail fallback.

Cleanup keeps all shared Firstmate safety checks.
A scout still requires its report and completed decision inventory.
A ship still refuses dirty or unlanded work.
Before release, cleanup resolves the recorded Orca worktree id and verifies its path matches the recorded worktree path.
A missing, unreadable, or mismatched identity preserves metadata and stops rather than deleting anything.
After those checks, Firstmate closes the exact terminal and releases the exact worktree with Orca's worktree command.
It never raw-deletes an Orca worktree.

## Secondmate homes

Orca supports secondmate spawns. Because Orca can only open a terminal inside an Orca-managed worktree, a secondmate home is itself created as an Orca-managed worktree of the firstmate repo, not a Treehouse lease.
To keep the home-isolation invariant (a secondmate home may not live inside the firstmate repo), Firstmate points the firstmate project setup's worktree base path outside the repo with `orca project setup-update --worktree-base-path`, so Orca places the home there.
`bin/fm-home-seed.sh` therefore requires the leased form (`-`) on the Orca backend and creates the home with `orca worktree create`; an explicit home path is refused because Orca cannot adopt an arbitrary existing checkout.
`bin/fm-spawn.sh --secondmate` reuses that seeded home worktree: it resolves the home's worktree id from its path and creates the agent terminal inside it with `orca terminal create --worktree path:<home>`, never a second worktree.
Teardown releases the home with `orca worktree rm --worktree path:<home>` under the same landed-work and in-flight-work guards as any other secondmate, after resolving that the home is an Orca-managed worktree.
The secondmate's own crewmates run on its inherited backend and take ordinary Orca task worktrees of their project repos.
Orca has a recovery-grade agent-state classifier (terminal `orphaned`/`connected`/`agentIdentity` plus `worktree ps` state), so a dead or missing Orca secondmate is auto-respawned at session start and `bin/fm-control.sh <id> exit|relaunch` is supported; a connected terminal with no attributable agent stays `ambiguous` and never licenses recovery.

## Active limits

- Orca is macOS-only and explicit-only.
- The app must be running and report ready.
- Secondmate homes require the leased (`-`) form and an external worktree base path; Orca cannot host a terminal in an arbitrary existing checkout.
- Native busy/idle and a recovery-grade agent-state come from Orca's agent status; there is no native terminal push-event stream, so the watcher polls (the same fallback as tmux/zellij/cmux) rather than waiting on a pushed transition.
- Orca exposes no stable CLI version or protocol marker, so readiness is the compatibility gate rather than a version floor.
- Only the verified terminal-handle and worktree result fields are accepted; speculative response shapes are rejected.
- Orca's worktree shape is unverified against the spawn-time Claude workspace-trust check in `bin/fm-claude-trust.sh`, which refuses any path that is not a linked git worktree sharing the project's git common dir, so a claude spawn on Orca fails loudly at that check rather than launching if Orca clones instead of linking.

## Regression entry points

```sh
tests/fm-backend-orca.test.sh
tests/fm-backend.test.sh
tests/fm-bootstrap.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#orca) records the real readiness and response-shape smoke.
