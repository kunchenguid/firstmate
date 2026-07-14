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
- A hang cannot gate the flow either: the hook always runs under a time budget of `FM_HOOK_TIMEOUT` seconds (default 120), enforced by `timeout` or `gtimeout` when either is on `PATH` and otherwise by a shell-native watchdog that needs no external binary, so the bound holds on a stock macOS home too.
  Both paths run the hook in its own process group and signal that whole group with `SIGTERM` and then `SIGKILL` after a 5-second grace, so even a hook that traps or ignores `SIGTERM`, or one blocked in a descendant it spawned, is stopped rather than orphaned, and a timed-out hook is warned and skipped exactly like a failing one.
- `FM_HOOK_TIMEOUT=0` is the one opt-out: it runs the hook with no time limit.
- A hook cannot stall firstmate through its output either, because a hook never inherits firstmate's stdout or stderr.
  A hook may exit cleanly and still leave a background descendant alive - a `&`-ed notifier, a `nohup`-ed sync - which no time budget and no process-group kill can reach, and that orphan would hold whichever of firstmate's pipes it inherited open for as long as it lives, stalling any firstmate script that reads the calling script's output through a command substitution.
  So every path runs the hook with its stdout discarded and its stderr captured, and firstmate relays that captured stderr to its own stderr once the hook is done: diagnostics still reach the operator, and an orphan can hold nothing that firstmate waits on.
  That capture is a private file (mode 0600) which firstmate unlinks as soon as it holds the descriptors, so hook stderr is never readable by another user and nothing is left behind in `TMPDIR` even if firstmate is interrupted mid-hook.
- A hook cannot delay the work either: every hook point fires last in its script, after the calling flow's own work and its caller-visible output are complete, so a slow hook holds up nothing and an interrupt mid-hook can never leave a half-finished record behind.

Each hook receives its values both as positional arguments and as `FM_HOOK_*` environment variables, so a hook can read whichever is convenient.
The first positional argument is always the task id.

## Hook points

| hook | fires from | moment | args | environment |
| --- | --- | --- | --- | --- |
| `post-spawn` | `bin/fm-spawn.sh` | a task (any kind: `ship`, `scout`, `secondmate`) is fully launched and its `state/<id>.meta` is written; once per task in a batch, and also on an automatic secondmate liveness respawn (see below) | `$1` task id, `$2` absolute meta path | `FM_HOOK_TASK_ID`, `FM_HOOK_META`, `FM_HOOK_KIND` |
| `pr-ready` | `bin/fm-pr-check.sh` | a PR URL is first recorded (`pr=` newly appended) for the task; re-runs, including `bin/fm-pr-merge.sh`'s internal recording re-run, never re-fire it | `$1` task id, `$2` PR URL | `FM_HOOK_TASK_ID`, `FM_HOOK_PR_URL` |
| `post-merge` | `bin/fm-pr-merge.sh`, `bin/fm-merge-local.sh` | firstmate itself merged the task's work: it merged the PR (ref = PR URL) or fast-forwarded the local-only branch into the local default branch (ref = branch name) | `$1` task id, `$2` ref | `FM_HOOK_TASK_ID`, `FM_HOOK_REF` |
| `post-teardown` | `bin/fm-teardown.sh` | the task's worktree, endpoint, and state files are gone; only id and kind remain as identifiers | `$1` task id, `$2` kind | `FM_HOOK_TASK_ID`, `FM_HOOK_KIND` |

This set is deliberately small: a hook point is added only where the lifecycle moment has clear personal-automation value and a single clean insertion, not scattered through every script.
A `pr-ready` hook may fire from `bin/fm-pr-merge.sh` instead of `bin/fm-pr-check.sh` when the merge is the first time the PR is recorded (the yolo-merge-on-no-CI-repo flow); the once-per-(task, PR URL) guarantee is what a hook should rely on, not which script fired it.
`post-merge` fires only for a merge firstmate performed through those two scripts.
A PR merged outside firstmate - the captain clicking Merge in the GitHub UI, say, which the watcher's merge poll only detects afterwards - does not fire it, so a `post-merge` hook must not be relied on as a universal merge notification.
`post-spawn` fires on every launch of a task, not only on a newly dispatched one: firstmate respawns a dead secondmate through the same `bin/fm-spawn.sh --secondmate` path during the session-start liveness sweep, so a recovery fires the hook exactly like a fresh dispatch.
A `post-spawn` hook must therefore treat "this task is now running" rather than "this is new work" as its trigger, and stay idempotent for a task id it has already seen.

Hooks run with the invoking script's working directory, and with its stdin, but never with its stdout or stderr: a hook's stdout is discarded, and its stderr is captured and relayed once it finishes, so a hook that produces output for the operator should write to its own log or a display surface.
A bounded hook runs in its own process group, so it must take its input from its arguments and environment rather than reading the terminal.
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
