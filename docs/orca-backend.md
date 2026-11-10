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

`config/launch-env-allowlist` alone cannot scope worker credentials on Orca, because allowlisted values resolve from the Orca terminal's own environment.
When scoped worker credentials live in a tmux session, configure the [Orca environment source](configuration.md#orca-environment-source-configlaunch-env-tmux-session).

## Remote workers

Pair the supervisor's Orca CLI with the target's full runtime-environment pairing offer using `orca environment add`, then configure [Orca machines](configuration.md#orca-machines-configorca-machines).
Use the current CLI help for pairing flags and keep the pairing code out of tracked files and task reports.
A mobile-scoped pairing link cannot authorize worktree operations.
The remote project must already exist at the same absolute path and base commit; unavailable or stale copies are skipped.
Firstmate does not administer the remote Orca service.

Orca remains the worktree and terminal provider.
SSH stages task files and runs the existing filesystem-dependent spawn, state, control, and cleanup checks on the host that owns the worktree.
The staged workspace contains a private code snapshot, selected worker policy files, the brief, and task state; it is not a secondmate home and runs no supervisor.
For publishing tasks, that snapshot includes full HEAD history and its origin before applying the current script overlay.
Publishing tasks require a full-history project mirror with the same origin as the coordinator and working git-crypt filters when used.
Provision and unlock that mirror on the target machine before dispatch; staging never repairs a shared mirror or transfers encryption keys.
Harness credentials remain on the target machine, and a local tmux launch-environment source refuses remote placement.
`bin/fm-orca-worker.py` owns the transport protocol and the policy-file allowlist.

The parent home keeps the authoritative task record, backlog, decisions, and merge authority.
The watcher imports remote status, reports, and inbox acknowledgements, and `fm-send.sh` transfers an immutable queued message before ringing the remote endpoint.
A failed transfer retains the queued message and reports delivery as unconfirmed; do not enqueue another copy.
Handled message records are checked against the original content and are never recreated as pending messages.
A lost spawn reply retains its route for reconciliation instead of launching another worker.
Transport failures report unknown remote state and preserve the task.

For local-only work, readiness imports a Git bundle into the parent's named task branch without forcing a ref and records the accepted head through the ordinary readiness gate.
The usual approved fast-forward landing remains on the parent machine.
Cleanup sends evidence from the parent's landed default branch back to the worker host and runs the ordinary dirty-worktree, landed-work, report, and decision checks there.
A durable remote cleanup receipt lets a lost reply be retried before the parent retires its task record and backlog item.
The staged workspace remains as recovery evidence after the Orca worktree is released.

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

A remote worker also records `orca_environment=`, `orca_runtime_id=`, `orca_machine_host=`, and `orca_machine_workspace=`.
Its private `state/<id>.orca-route.json` binds the transport workspace to the same task and runtime.
Terminal routing includes the saved environment and verifies the recorded runtime identity, so reused terminal ids on different machines cannot collide.
An environment change affects future placement; existing tasks retain their recorded route.

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

## Active limits

- Runtime selection is explicit; live verification currently covers macOS.
- The selected runtime must report ready.
- Secondmate spawns are unsupported.
- Remote scouts cannot be promoted in place; preserve their report and dispatch a new ship.
- Remote scout cleanup currently requires a reviewed empty captain-call inventory in the parent home; a non-empty inventory preserves the task for explicit reconciliation.
- Remote placement requires an existing matching project and existing harness authentication on the target.
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
