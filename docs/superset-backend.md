# Superset runtime backend

Superset is an experimental backend in which the Superset host service owns both the task workspace (a git worktree) and the terminal endpoint inside it.
The crewmate harness remains the agent process launched inside that terminal.
Firstmate agents load [`firstmate-superset`](../.agents/skills/firstmate-superset/SKILL.md) before operating or recovering this backend.

## Setup

Pick Superset when you already use the Superset app and want Superset-managed workspaces and terminals instead of Treehouse plus a session multiplexer.
Superset is explicit-only and does not support secondmate spawns.

Prerequisites:

- The `superset` CLI, installed and authenticated (see [docs.superset.sh/cli](https://docs.superset.sh/cli)).
- The Superset host service running and healthy (`superset status --json` reporting `running=true` and `healthy=true`).
- The project already registered as a Superset project (`superset projects create --local --name <name> --import <path>`) - this adapter deliberately does not auto-register an unregistered project; see "Active limits" below.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

Select Superset with local `config/backend` containing `superset`, `FM_BACKEND=superset` for one launch, or an explicit request to Firstmate.
It is never auto-detected.

Before any spawn mutates repository state, Firstmate requires `superset status --json` to report a running, healthy host service.

Open the Superset app to watch a task's terminal.
Routine supervision uses the recorded endpoint through `bin/fm-peek.sh <id>` and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'`.
Enter and Ctrl-C are supported; Escape and Ctrl-U are not.

## Task shape and metadata

Each task has one Superset-managed git worktree (a workspace) and one Superset terminal inside it.
Unlike Orca's single terminal handle, a Superset terminal is addressed by two ids - the owning workspace and the terminal within it - so the target string firstmate records has the shape `<workspace_id>:<terminal_id>`, matching cmux's composite target convention.
`fm-spawn.sh` does not call Treehouse for Superset tasks.
The normal isolation and unlanded-work refusal rules still apply.

```text
backend=superset
window=fm-<id>
superset_workspace_id=<superset workspace id>
superset_terminal_id=<superset terminal id>
worktree=<absolute Superset worktree path>
```

`window=` remains the caller-facing Firstmate alias, exactly like Orca's `window=fm-<id>` (not the live composite target - a stable alias survives a partial spawn failure that never reached terminal creation, when no valid composite target yet exists to store).
`superset_workspace_id=` and `superset_terminal_id=` are the backend authority used by operation and cleanup paths; `fm_backend_target_of_meta` reconstructs the live `<workspace_id>:<terminal_id>` target from them.

## Current lifecycle and safety

Spawn resolves the registered Superset project for the task's project path, creates an independent workspace, then always creates its own terminal explicitly - it never reuses the implicit "Workspace Setup" terminal a project-backed `ws create` can return, because that terminal runs the project's configured setup command and is not a general shell.
Exact command flags and response parsing are owned by `bin/backends/superset.sh` and its header's empirical findings.

`fm-peek.sh` reads with `superset terminals read`.
`fm-send.sh` types and verifies composer clearance through the fleet-wide classifier in `bin/fm-composer-lib.sh`, retrying Enter without retyping when a slash popup first fills an argument placeholder.
A bare Enter press sends a single space as `--text`, not an empty string: the CLI rejects an empty `--text` outright, and an embedded newline or carriage-return byte in `--text` is inserted as literal text rather than interpreted as a keypress - both verified live during this backend's authoring.
The watcher has no native Superset busy signal, so each harness adapter's semantic lifecycle supplies worker state, exactly like every backend besides herdr.

Cleanup keeps all shared Firstmate safety checks.
A scout still requires its report and completed decision inventory.
A ship still refuses dirty or unlanded work.
**`superset ws delete` performs no dirty-worktree or unlanded-work check of its own** - verified live: deleting a workspace with an uncommitted tracked file silently discarded it, no warning, no `--force` needed.
Before release, cleanup resolves the recorded Superset workspace id and verifies its path matches the recorded worktree path (`require_superset_worktree_path_match` in `bin/fm-teardown.sh`), the same identity-before-removal proof Orca's adapter uses and for the same reason: it is the only thing standing between a mismatched or stale workspace id and a silently discarded worktree.
A missing, unreadable, or mismatched identity preserves metadata and stops rather than deleting anything.
After those checks, Firstmate closes the exact terminal and releases the exact workspace with `superset ws delete`.

## Active limits

- Superset is explicit-only; it is never auto-detected.
- The host service must be running and report healthy.
- Secondmate spawns are unsupported.
- Escape and Ctrl-U are unsupported: `terminals send --text` recognizes `\x03` (Ctrl-C) as a real interrupt, but an embedded `\x15` (Ctrl-U) was verified live to insert as literal text rather than act as a line-kill, so this adapter claims only what it proved.
- There is no true "press Enter only" primitive: `--text` must be non-empty, so a bare Enter always sends a single space first. A live-verified space+DEL (`0x20 0x7f`) compensation does not neutralize it - `0x7f` inserts as a literal DEL control byte, not a backspace - so it was rejected as strictly worse than the plain space. Because `fm_composer_submit_retry_core` retries Enter without retyping the original text, a retry after a swallowed Enter injects one more stray space into whatever a slash-command popup left staged, rather than being a no-op.
- This adapter does not auto-register an unregistered Superset project the way Orca's adapter auto-registers an unregistered repo.
  `superset projects create`'s exact JSON response shape was not live-verified during authoring (there is no `projects delete` command to clean up a throwaway registration), so a task fails loudly with the exact registration command instead of guessing at that shape.
- `bin/fm-test-run.sh`'s `portable_serial_weight_hints` timing table intentionally carries no entry yet for `tests/fm-backend-superset.test.sh`, pending a real CI run to measure it; an absent hint costs shard balance, not coverage (see that function's own header).

## Regression entry points

```sh
tests/fm-backend-superset.test.sh
tests/fm-backend.test.sh
tests/fm-bootstrap.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#superset) records the real readiness and response-shape smoke.
