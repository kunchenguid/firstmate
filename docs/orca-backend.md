# Orca runtime backend

Orca is an experimental backend in which the Orca runtime owns both worker worktrees and terminal endpoints.
The crewmate harness remains the agent process launched inside that endpoint.
Firstmate agents load [`firstmate-orca`](../.agents/skills/firstmate-orca/SKILL.md) before operating or recovering this backend.

## Setup

Pick Orca when you already use the Orca macOS app and want Orca-managed worktrees and terminals instead of Treehouse plus a session multiplexer.
Orca is explicit-only and supports local secondmates in separately seeded homes.

Prerequisites:

- A running, ready Orca runtime, either the macOS app or `orca serve`.
- The `orca` CLI, installed with `brew install orca`.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

Select Orca with local `config/backend` containing `orca`, `FM_BACKEND=orca` for one launch, or an explicit request to Firstmate.
It is never auto-detected.

Before any spawn mutates repository state, Firstmate requires `orca status --json` to report `reachable=true` and `state="ready"`.
The first task for a project registers that repository with `orca repo add --path` when needed.
No manual repository registration is required.

Open the Orca app and select the runtime's environment to watch a task's terminal.
An Orca client on another machine views the same local Firstmate homes; this does not use Firstmate's SSH remote-secondmate transport.
Routine supervision uses the recorded endpoint through `bin/fm-peek.sh <id>` and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'`.
Enter and Ctrl-C are supported; Escape is not.

`config/launch-env-allowlist` alone cannot scope worker credentials on Orca, because allowlisted values resolve from the Orca terminal's own environment.
When scoped worker credentials live in a tmux session, configure the [Orca environment source](configuration.md#orca-environment-source-configlaunch-env-tmux-session).

## Task shape and metadata

Each ship or scout has one Orca-managed git worktree and one Orca terminal.
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

## Local secondmates

Seed a secondmate with the normal provisioning helper and an explicit home path outside the primary home and code root, then select Orca when launching it.
The seeded Git checkout becomes a registered Orca repository, with a terminal initially titled `2ndmate-<id>` in its root workspace; the harness may replace that automatic title.
The secondmate keeps its own charter, configuration, backlog, project clones, and supervision session.
Its workers stay independent under their own project repositories, with `2ndmate-<id> · fm-<task-id>` on both their worktree display name and custom terminal title.
Grouping is by label only.
Orca 1.4.224 refuses cross-repository lineage with `LINEAGE_PARENT_CONTEXT_CONFLICT`: "Parent worktree must belong to the same repository, execution host, and project."
Spawn verifies the labels and absence of a parent before launching the worker.
Primary-home workers retain their existing names and independent placement.

The adapter records registration ownership in the secondmate's private state.
Retirement closes and confirms the exact terminal before deleting the home, verifies registrations contain no remaining workers or terminals, and removes only registrations it created.
It never invokes worktree removal on the persistent home.
Pre-existing registrations are preserved.
Incomplete inventories, failed closes, uncertain registration results, and identity mismatches retain the home and records for reconciliation.
Existing secondmate metadata or an unfinished launch receipt refuses a second launch.
The shared child-work, pending-reply, and home-removal guards still apply.

Agent-process recovery remains unverified for Orca, including Pi secondmates.
An idle task, a completed turn, a connected terminal, or a stale terminal handle does not establish that an agent has stopped.
The control plane continues to refuse exit and relaunch; guarded retirement is a separate explicit lifecycle operation.

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

## Active limits

- Runtime selection is explicit; live verification currently covers macOS.
- The selected runtime must report ready.
- Local secondmates are supported; Firstmate's SSH remote-secondmate route remains Herdr-only.
- Escape is unsupported.
- Orca exposes no stable CLI version or protocol marker, so readiness is the compatibility gate rather than a version floor.
- Only the verified terminal-handle and worktree result fields are accepted; speculative response shapes are rejected.
- Orca's worktree shape is unverified against the spawn-time Claude workspace-trust check in `bin/fm-claude-trust.sh`, which refuses any path that is not a linked git worktree sharing the project's git common dir, so a claude spawn on Orca fails loudly at that check rather than launching if Orca clones instead of linking.

## Regression entry points

```sh
tests/fm-backend-orca.test.sh
tests/fm-spawn-orca-worktree.test.sh
tests/fm-backend.test.sh
tests/fm-bootstrap.test.sh
tests/fm-teardown-endpoint-safety.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#orca) records the real readiness and response-shape smoke.
