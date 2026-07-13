# Local extension points

Firstmate self-updates fast-forward-only (`/updatefirstmate`), so a local commit on tracked files blocks every future update.
That makes forking the wrong way to add personal automation, and most personal automation is too operator-specific to upstream.
The repo already solves this tension for data and configuration: `data/` and `config/` are gitignored, so each home carries its own without touching tracked files.
Local extension points extend the same principle to executables, in two pieces: `config/hooks/` lifecycle hooks and `bin-local/` personal scripts.
Both are gitignored, both are optional, and an installation that uses neither sees zero behavior change.

## Lifecycle hooks (config/hooks/)

A hook is an executable at `config/hooks/<hook-name>` that firstmate's `bin/` scripts run best-effort at a small set of documented lifecycle points.
Firstmate ships no hooks: an absent or non-executable hook is a silent no-op.

Every hook point shares one runner, `fm_hook_run` in `bin/fm-hooks-lib.sh`, whose header owns the exact runner mechanics.
The failure semantics are the contract's core and hold at every hook point:

- A hook never gates the calling flow: a hook that exits non-zero is warned to stderr and the flow continues, so a hook must never be relied on to block anything.
- A hang cannot gate the flow either: the hook runs under a time budget of `FM_HOOK_TIMEOUT` seconds (default 120) via `timeout` or macOS `gtimeout` with a 5-second kill-after grace, and a timed-out hook is warned and skipped exactly like a failing one.
- `FM_HOOK_TIMEOUT=0` is a deliberate opt-out that runs the hook with no time limit; when neither timeout binary is on `PATH`, the hook runs unbounded after a stderr warning.

Each hook receives its values both as positional arguments and as `FM_HOOK_*` environment variables, so a hook can read whichever is convenient.
The first positional argument is always the task id.

## Hook points

| hook | fires from | moment | args | environment |
| --- | --- | --- | --- | --- |
| `post-spawn` | `bin/fm-spawn.sh` | a task (any kind: `ship`, `scout`, `secondmate`) is fully launched and its `state/<id>.meta` is written; once per task in a batch | `$1` task id, `$2` absolute meta path | `FM_HOOK_TASK_ID`, `FM_HOOK_META`, `FM_HOOK_KIND` |
| `pr-ready` | `bin/fm-pr-check.sh` | a PR URL is first recorded (`pr=` newly appended) for the task; re-runs, including `bin/fm-pr-merge.sh`'s internal recording re-run, never re-fire it | `$1` task id, `$2` PR URL | `FM_HOOK_TASK_ID`, `FM_HOOK_PR_URL` |
| `post-merge` | `bin/fm-pr-merge.sh`, `bin/fm-merge-local.sh` | the task's work landed: its PR merged (ref = PR URL) or its local-only branch fast-forwarded into the local default branch (ref = branch name) | `$1` task id, `$2` ref | `FM_HOOK_TASK_ID`, `FM_HOOK_REF` |
| `post-teardown` | `bin/fm-teardown.sh` | the task's worktree, endpoint, and state files are gone; only id and kind remain as identifiers | `$1` task id, `$2` kind | `FM_HOOK_TASK_ID`, `FM_HOOK_KIND` |

This set is deliberately small: a hook point is added only where the lifecycle moment has clear personal-automation value and a single clean insertion, not scattered through every script.
A `pr-ready` hook may fire from `bin/fm-pr-merge.sh` instead of `bin/fm-pr-check.sh` when the merge is the first time the PR is recorded (the yolo-merge-on-no-CI-repo flow); the once-per-(task, PR URL) guarantee is what a hook should rely on, not which script fired it.

Hooks run with the invoking script's working directory and stdio, so a hook that produces output should write to its own log or a display surface rather than polluting the calling script's stdout.
Hooks are per-home local configuration and are not propagated into secondmate homes.

## Personal scripts (bin-local/)

`bin-local/` at the firstmate home root holds an operator's personal helper executables.
It is gitignored, never created or read by tracked code, and nothing in firstmate auto-executes anything in it: the declared hook points above are the only automatic execution surface for local code.
Its purpose is organization: hooks stay thin entry points in `config/hooks/`, and the real logic lives in `bin-local/` scripts that the hooks call by absolute path.
An operator (or firstmate, when explicitly instructed) may also invoke `bin-local/` scripts directly by absolute path, like any other executable on disk.

## Example

A hook is any executable, typically a small shell script.
For instance, a `pr-ready` hook that opens the PR's diff in a personal review tool, delegating to a `bin-local/` helper:

```sh
#!/usr/bin/env sh
# config/hooks/pr-ready - open review tooling when a task's PR is ready.
exec "$(dirname "$0")/../../bin-local/open-review" "$FM_HOOK_TASK_ID" "$FM_HOOK_PR_URL"
```

Install by writing the file and `chmod +x config/hooks/pr-ready`; remove it (or clear the executable bit) to disable.
