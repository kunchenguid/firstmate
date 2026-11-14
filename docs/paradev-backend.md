# Paradev runtime backend

Paradev is an experimental macOS backend in which the Paradev desktop app owns both the task worktree and the terminal endpoint.
Each task is one Paradev workspace, so crewmates appear in Paradev's sidebar, diff viewer, and pull request pane instead of in a separate multiplexer.
The crewmate harness remains the agent process Firstmate launches inside that workspace's terminal.
Firstmate agents load [`firstmate-paradev`](../.agents/skills/firstmate-paradev/SKILL.md) before operating or recovering this backend.

## Setup

Pick Paradev when you already work in the Paradev desktop app and want each crewmate to be a Paradev workspace instead of a Treehouse worktree plus a multiplexer window.
Paradev is macOS-only, explicit-only, and does not support secondmate spawns.

Prerequisites:

- The Paradev desktop app installed and its host service running; opening the app starts it, and `superset start --daemon` starts it without the window.
- The `superset` CLI, which ships with the app, and `jq`.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain); Treehouse is not needed for this backend.
- The project clone Firstmate spawns from registered as a Paradev project at that exact path, once, with `superset projects create --import <clone path> --local`.
  Spawn looks the project up by path and refuses with that command when it is missing or registered twice; it never registers a project on its own.
- Paradev's agent hooks loading in each harness Firstmate launches, for native busy state (see [Native agent state](#native-agent-state)).

Select Paradev with local `config/backend` containing `paradev`, `FM_BACKEND=paradev` for one launch, or an explicit request to Firstmate.
It is never auto-detected: Paradev exports `SUPERSET_WORKSPACE_ID` into every terminal it opens and every descendant process inherits it, so the marker cannot stand for a selection.

Before any spawn mutates repository state, Firstmate requires `superset projects list --local --json` to succeed and return a project list.
`superset status` is deliberately not the readiness probe, because it can report a stale host service while every other call works.

Every workspace Firstmate creates carries the tag `firstmate`, which files the crew into one sidebar folder.
The tag is display only.
You may give your own captain workspace the same tag to keep it beside the crew; Firstmate never lists, steers, or archives a workspace by its tag, only by the ids recorded in task metadata.

Open the Paradev app to watch a task's terminal.
Routine supervision uses the recorded endpoint through `bin/fm-peek.sh <id>` and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'`.
Enter, Escape, Ctrl-C, and Ctrl-U are supported.

`config/launch-env-allowlist` names resolve from the Paradev terminal's own environment, which is the Paradev host service's rather than this home's, and spawn prints a warning when the allowlist is set.

## Task shape and metadata

Each task has one Paradev workspace, which is one Paradev-managed git worktree on the task branch, and one plain shell terminal in it.
`fm-spawn.sh` does not call Treehouse for Paradev tasks.
The normal isolation and unlanded-work refusal rules still apply.

```text
backend=paradev
window=fm-<id>
endpoint_task_id=<id>
terminal=<paradev workspace id>:<paradev terminal id>
paradev_workspace_id=<paradev workspace id>
paradev_project_id=<paradev project id>
worktree=<absolute Paradev worktree path>
```

`window=` remains the caller-facing Firstmate alias.
`terminal=` and `paradev_workspace_id=` are the backend authority used by operation and cleanup paths.
`terminal=` carries both ids because every Paradev terminal call needs both, and cleanup validation refuses a record whose `terminal=` names a different workspace than `paradev_workspace_id=`.

## Current lifecycle and safety

Spawn resolves the Paradev project id from the clone path, creates a tagged workspace on the task branch with Paradev's own branch prefix skipped, and refuses a branch whose workspace already exists rather than adopting or archiving it.
It then reads the worktree path back by workspace id, runs the isolated-worktree assertion, opens one plain shell terminal, records metadata, and types the selected harness launch into that shell, so every supported harness and Firstmate's own harness hooks work unchanged.
If spawn fails after the workspace exists, it archives that workspace; when that archive also fails, it leaves a recovery record naming the workspace.
Exact command flags and response parsing are owned by `bin/backends/paradev.sh`.

`fm-peek.sh` reads with `superset terminals read`, which returns the terminal's visible screen rather than scrollback.
An ordinary metadata-routed `fm-send.sh` text steer becomes a durable steering-inbox record, and only its best-effort constant doorbell passes through Paradev's terminal input.
On the typed plane, `fm-send.sh` types the text once without submitting and verifies composer clearance through the fleet-wide classifier in `bin/fm-composer-lib.sh`, retrying Enter without retyping.
A bare shell row is `unknown`, not an empty agent composer.

### Native agent state

Paradev reports a native per-terminal agent state from hooks it installs into the agent harness.
Firstmate trusts Paradev's `working` as busy and nothing else; every other state, including idle, leaves worker state to each harness adapter's semantic lifecycle, as on Orca.
Idle does not prove a free input box: a harness dialog that is not a permission request also reads as idle.

The hooks reach Claude Code only when they sit in the configuration directory Claude actually reads.
Paradev writes them to `~/.claude/settings.json`, so a Claude launched with `CLAUDE_CONFIG_DIR` pointing elsewhere never loads them and Paradev keeps reporting `starting`.
Supervision still works through Firstmate's own hooks, but Paradev's sidebar status and the native busy signal are lost.
Merge the `hooks` object from `~/.claude/settings.json` into that directory's `settings.json` to restore them; the upstream report is [ParadevAI/Paradev#9724](https://github.com/ParadevAI/Paradev/issues/9724).

### Cleanup

Cleanup keeps all shared Firstmate safety checks.
A scout still requires its report and completed decision inventory.
A ship still refuses dirty or unlanded work, and refuses when it has no inspectable worktree.
Before release, cleanup resolves the recorded workspace id to a live, unarchived worktree path and verifies it matches the recorded worktree path.
A missing, unreadable, or mismatched identity preserves metadata and stops rather than deleting anything.

After those checks, Firstmate drops the local task branch on a best-effort basis, closes the exact recorded terminal, re-reads the workspace's terminal inventory to prove it gone, and archives the exact recorded workspace.
The re-read is required because `terminals close` reports success for a terminal that was already closed.
A close that cannot be proven, because the terminal is still listed, the inventory cannot be read, or `superset` is not on the path, stops cleanup with the metadata intact even under `--force`.
[`verification/runtime-backends.md`](verification/runtime-backends.md#endpoint-close) "Endpoint close" owns what this arm can prove about its own close.
The archive must report the workspace as deleted or already unknown, with no failures, or cleanup preserves the record for retry.

Archiving a Paradev workspace deletes its worktree folder, uncommitted files included, with no warning, even while a terminal is still live in it.
Never archive a crewmate workspace from the Paradev app or CLI by hand; let `bin/fm-teardown.sh` do it after the landing checks.
A ship whose workspace was archived outside Firstmate has no inspectable worktree, so cleanup refuses until discarding that task is explicitly authorized.

## Active limits

- Paradev is macOS-only and explicit-only.
- The Paradev host service must answer a real CLI call; the app or `superset start --daemon` provides it.
- Secondmate spawns are unsupported.
- `bin/fm-control.sh` exit and relaunch are unsupported, because the backend has no recovery-grade agent-state probe: Paradev's native state cannot tell a plain shell from an unknown terminal.
- Capture is the visible screen only, and there are no push events; the watcher polls.
- Native busy state needs Paradev's hooks in the harness's active configuration directory, as described above.
- Paradev does not show a captain-above-crew hierarchy; the shared tag folder is the closest view.

## Regression entry points

```sh
tests/fm-backend-paradev.test.sh
tests/fm-backend.test.sh
tests/fm-bootstrap.test.sh
tests/fm-busy-state.test.sh
tests/fm-teardown-endpoint-safety.test.sh
```

The live smoke test `tests/fm-backend-paradev-smoke.test.sh` drives the real Paradev host and runs only when `FM_PARADEV_SMOKE_PROJECT` names a registered Paradev project on this machine; otherwise it records a gate skip:

```sh
FM_PARADEV_SMOKE_PROJECT=<project id> bin/fm-test-run.sh --family paradev
```

It creates two throwaway workspaces tagged `fm-spike` on `spike/` branches and removes them, by exact name and branch, even when it fails or is interrupted.

[`verification/runtime-backends.md`](verification/runtime-backends.md#paradev) records the real CLI readiness, response shapes, and lifecycle facts the adapter relies on.
