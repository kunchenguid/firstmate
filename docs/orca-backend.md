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
orca_worktree_id=<orca worktree id>
worktree=<absolute Orca worktree path>
```

`window=` remains the caller-facing Firstmate alias.
`terminal=` and `orca_worktree_id=` are the backend authority used by operation and cleanup paths.
`orca_worktree_id=` holds whatever `orca worktree create` returned, either a plain token or the `<repo id>::<absolute worktree path>` composite that Orca 1.4.197 emits, and `bin/fm-backend.sh` validates both shapes (see [runtime-backends.md](verification/runtime-backends.md) "Orca").

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

The recovery-grade agent state that `fm-control.sh exit` needs comes from the pane's process tree, not from Orca's display fields.
Orca keeps a terminal's `agentIdentity` and agent title after the agent exits back to the shell, so those fields never prove a stop.
`orca terminal show` names the terminal's pty, Orca's own host process sweep (`orca diagnostics memory`) names that pty's root pid, and the shared harness-name classifier reads every process below it: a harness is `alive`, only shells is `dead`, anything else is `ambiguous`, and Orca's stale-handle answer is `missing` (`bin/backends/orca.sh` owns the mechanics).
A terminal Orca itself reports gone is also `missing`: one whose record carries a terminal `exitCause` (an `operator_close`, a signal, or an observed exit code) or reports itself neither connected nor writable, while the pty it names has left the host sweep.
That is the shape a closed Orca tab leaves behind, and reading it as `unreadable` left the endpoint permanently unreplaceable.
A stop Orca could not verify, whether an `unknown` cause or its negative sentinel exit code, stays `unreadable` unless the record also reports itself neither connected nor writable, and a pty the sweep still names keeps the process-tree verdict, because a living process outranks a record.
In-place `relaunch` stays refused on Orca until a replacement launch into the same terminal is proven.
When Orca reports a task's terminal gone (`missing`, as after an Orca or host restart), `bin/fm-spawn.sh <id> --relaunch` launches the replacement in a new terminal in the task's recorded Orca worktree and republishes the record with it; a live or shell-only terminal still refuses.

Cleanup keeps all shared Firstmate safety checks.
A scout still requires its report and completed decision inventory.
A ship still refuses dirty or unlanded work.
Before release, cleanup resolves the release path from how the worktree was created rather than from any single record field: a task recorded as `backend=orca`, a recorded Orca worktree id, or a worktree under an Orca workspace tree - so a record that predates the backend field still routes by provenance - releases through Orca.
When a recorded Orca worktree id exists it must resolve to the recorded worktree path; an unreadable or mismatched id preserves metadata and stops rather than deleting anything.
An Orca-created worktree with no recorded id proves its release path from the current path instead: the path Orca returns must canonicalize to the directory the safety gates inspected, and only a migrated prior-path record additionally requires a non-empty worktree id, because its Orca removal names that id.
These checks run before the endpoint kill, so a worktree with no proven release path leaves the agent alive and the branch intact.
After those checks, Firstmate closes the exact terminal and releases the exact worktree with Orca's worktree command, by recorded id when one exists and otherwise by the worktree's current path; only an explicit `ok:true` envelope counts as a released worktree.
Only a proven registry miss - Orca answering `selector_not_found` for that path - falls back to a guarded plain `git worktree remove`, which refuses a locked, dirty, or submodule-holding worktree and never forces.
Every other Orca failure refuses with the concrete Orca error named, including one the CLI reports only on stderr, because a bare git remove would delete a worktree Orca still owns.
Firstmate never raw-deletes an Orca worktree Orca still names.

A task migrated from the Mac-era Orca backend keeps only `orca_worktree_id_prior=` (a `/Users/<user>/orca/workspaces/...` path) and no `orca_worktree_id=`, so its backend reads as tmux and its worktree is not in Treehouse's pool.
After the same landed-work gates pass, cleanup resolves the worktree Orca still records at that prior path, requires it to canonicalize to the exact directory the gates inspected, and requires Orca's non-empty worktree id before removing it through Orca.
Only Orca's proven `selector_not_found` registry miss falls back to the same guarded plain git release; every other failure, including a registry row that resolves elsewhere, refuses with the concrete error and leaves the worktree, branch, and record intact.
Neither path relaxes the dirty, unlanded, or force gates.

## Active limits

- Orca is macOS-only and explicit-only.
- The app must be running and report ready.
- Secondmate spawns are unsupported.
- Escape is unsupported.
- `fm-control.sh relaunch` is unsupported; exit the worker and respawn the task instead, or use `fm-spawn.sh <id> --relaunch` once Orca no longer has the terminal.
  A closed terminal now reads `missing`, so that respawn is the path the fleet watchdog takes on its own, and any other Orca endpoint still refuses with the concrete reason.
- Firstmate does not gate on the version or capability list Orca reports, so readiness is the compatibility gate rather than a version floor.
- Only the verified terminal-handle and worktree result fields are accepted; speculative response shapes are rejected.
- Orca's worktree shape is unverified against the spawn-time Claude workspace-trust check in `bin/fm-claude-trust.sh`, which refuses any path that is not a linked git worktree sharing the project's git common dir, so a claude spawn on Orca fails loudly at that check rather than launching if Orca clones instead of linking.

## Regression entry points

```sh
tests/fm-backend-orca.test.sh
tests/fm-backend.test.sh
tests/fm-bootstrap.test.sh
tests/fm-teardown-endpoint-safety.test.sh
tests/fm-teardown.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#orca) records the real readiness and response-shape smoke.
