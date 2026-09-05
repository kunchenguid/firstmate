# thurbox runtime backend

thurbox is an experimental session-provider backend.
It provides task sessions while Treehouse continues to provide git worktrees.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared selection and metadata semantics.

thurbox differs from the other experimental backends in one way that shapes the whole adapter: its event stream, its agent state, and its per-session key/value store are all first-class CLI verbs.
Three things the other adapters synthesize are read directly here.

## Setup

Pick thurbox when you already run your agents inside it and want Firstmate's tasks to appear as ordinary thurbox sessions.
thurbox is cross-platform and works headless, so unlike cmux it is usable over SSH.

Prerequisites:

- thurbox 2.11.1 or newer.
  2.11.0 introduced every verb this backend calls - `watch`, `session create --command/--arg/--env`, `--on-existing`, `session meta`, `session exec`, `session stop` - but reported a parked session identically to a running one, so readiness and recovery could not tell them apart.
  2.11.1 is the first release on which every read this adapter makes answers correctly.
- `jq` for JSON responses.
- Treehouse, which remains the worktree provider.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

The adapter requires no thurbox configuration at all.
It launches each task pane with `session create --command <shell> --arg -i`, so no `agents.toml` entry has to exist for Firstmate's harness and no Firstmate-side agent-name setting is needed.

## Runtime auto-detection

thurbox is selected automatically when Firstmate is itself running inside a thurbox pane and nothing else is configured.
The detection arm runs **before** the tmux arm, which is the one ordering exception in `fm_backend_detect`.

thurbox runs its sessions on its own tmux server, so every process inside a thurbox pane has both `THURBOX_SESSION` and `$TMUX` set.
Checking `$TMUX` first would classify every thurbox pane as plain tmux.
Checking `THURBOX_SESSION` alone would misclassify a nested plain tmux started inside a thurbox pane, which inherits the variable but is genuinely a tmux runtime.

The discriminator is the socket.
`$TMUX`'s first comma-separated field is the socket path of the server the process is attached to, and it matches the `tmux_socket` name `thurbox-cli version` reports only when the innermost multiplexer is thurbox's own server.

| Situation | `THURBOX_SESSION` | `$TMUX` socket | Detected |
| --- | --- | --- | --- |
| A thurbox pane | set | `thurbox` | thurbox |
| A plain tmux nested inside a thurbox pane | set (inherited) | anything else | tmux |
| A plain tmux elsewhere | unset | anything | tmux |
| No multiplexer | unset | unset | nothing detected, default tmux |

Auto-detection prints one loud notice because the backend is experimental.
`config/backend` or `--backend tmux` opts out.

## Driving the CLI

Two contracts govern every call the adapter makes, and both fail silently when they are got wrong.

### Errors arrive on stdout

`thurbox-cli` prints its failures as a JSON object on **stdout**, leaves stderr empty, and exits non-zero.

```
$ thurbox-cli session get 00000000-0000-0000-0000-000000000000 --json
{"error":"Session not found: 00000000-0000-0000-0000-000000000000","suggestion":"..."}
$ echo $?
1
```

A pipeline that parses that output therefore reports success for a failed call, because `jq` parses the error object happily and the pipeline carries `jq`'s status rather than the CLI's:

```
$ thurbox-cli session get <missing> --json | jq -r '.state // empty'
$ echo $?
0
```

Every read in the adapter goes through one function that captures the CLI's own exit status before anything parses and additionally rejects a payload carrying an `error` key.
No adapter function pipes `thurbox-cli` into `jq` directly.

### Piped output is TOON, not JSON

`thurbox-cli` emits TOON whenever stdout is not a terminal, which is always under command substitution.
Every adapter call passes `--json` explicitly.

`session meta get` is the sharpest instance.
Its help says it prints one key's value, or nothing when the key is unset.
Captured without `--json` it prints a three-line `id:` / `key:` / `value:` block instead, and an unset key prints the literal string `value: null` rather than nothing.

## Native event push

thurbox is the second push-capable backend after herdr, and by far the cheapest to wire.
herdr needs a sidecar raw-socket subscriber because its events ride a protocol socket; `thurbox-cli watch --json` is itself the subscriber, emitting one newline-delimited JSON object per transition.
The adapter therefore has no Python dependency and no schema probe, and its capability gate is the version floor alone.

The verified event vocabulary is:

| `event` | Meaning |
| --- | --- |
| `present` | Baseline row, emitted only under `--initial` |
| `created` | A session appeared |
| `changed` | A session's state or `stopped` flag changed |
| `gone` | A session was removed |

The `state` field carries `working`, `blocked`, `done`, `idle`, or `null`, which map straight onto the shared policy table in `bin/fm-transition-lib.sh`.
Nothing thurbox-specific reaches that policy.

`--initial` is deliberately not passed: its baseline `present` rows would replay an already-handled blocked state as a fresh edge on every poll.
`watch --for-secs` bounds the stream inside thurbox, so the wait needs no external timeout wrapper.

Transitions are observed at roughly one-second granularity.
The stream removes Firstmate's poll, but thurbox samples its own state internally rather than being driven by the agent's hook synchronously.

## Agent state and hook coverage

A thurbox session row carries a `state` of `working`, `blocked`, `done`, or `idle`, reported by the agent's own hooks through `thurbox-cli session signal`.
That is a semantic signal rather than a rendering, so it is strictly better than reading a pane with a regular expression.

Getting it requires one thing Firstmate has to do deliberately.
thurbox installs those hooks by appending an agent's `args` from `agents.toml` when **thurbox** launches the agent, for example `--settings <hooks>.json` for Claude.
Firstmate's spawn contract is uniform across every backend: create a shell endpoint, type exports into it, then type the harness launch command, so nothing appends them on its own.

`thurbox-cli agent launch-args <agent>` closes that.
`fm_backend_thurbox_agent_launch_args` asks it what thurbox would launch the harness with, and `bin/fm-spawn.sh` types those arguments into the launch command through the `__THURBOXARGS__` slot in each harness template.
Only the `args` are taken: the `env` the verb also reports names this thurbox instance, and the pane already carries it, since thurbox injects `THURBOX_SESSION` into every pane it creates and that is the identity `session signal` resolves.
`--session` is deliberately not passed, because it would additionally pin the agent's conversation id and make thurbox a second owner of resume alongside Firstmate's own relaunch path.

Verified 2026-09-02 on a real `fm-spawn.sh --backend thurbox` task: the session reports `state_source: hook`, `busy_state` answers `busy` during a turn and `idle` between them, and the session's transitions appear in `watch`.

Two outcomes are not the same and only one is worth a notice.
An agent thurbox does not know at all (grok, kimi, cursor, muse) has no arguments to pass, so that session reports no native state and the spawn says so once.
An agent thurbox knows but ships no launch arguments still reports state normally, because thurbox installs those hooks by writing the agent's own config instead - opencode and pi both report full hook coverage with an empty `args`.

The adapter therefore gates the signal rather than trusting the row:

- The state is used only when `state_source` is `hook`.
- A state thurbox itself marks `hook_state_contradicted` is refused.
- Everything else reports `unknown`, which every caller already understands as the cue to fall back to the harness-scoped pane read.

A busy verdict from this backend is consequently never a stale row.
`thurbox-cli session doctor <id>` reports whether hooks are wired and firing for a given session.

One more reason the adapter treats `blocked` as idle rather than as an actionable state: for Claude the blocked signal comes from its `Notification` hook, which also fires for advisories an auto-mode agent resolves by itself, so the state can appear and clear within seconds with no decision pending.
thurbox reports this honestly as `hook_blocked_is_heuristic` on the session row.
A supervisor that escalates on the first `blocked` edge will raise false alarms.
Persistence is not the fix: the state also stays set for the whole of a long foreground command, so a blocked read that is still blocked a minute later may simply be a test run.
Corroborate against the pane instead - a screen that is still changing means the agent is working whatever the hook says - which is what the row's own `hook_corroboration` field points at.

## Current path

thurbox is the only backend whose current-path read is genuinely live.

`session capture --json` returns `foreground_cwd`, the working directory of the process running in the pane's tty right now.
Every other session provider answers from a creation-time or top-level-shell-scoped field and needs a pwd-marker probe to see through a foreground subshell, which is exactly what `treehouse get` is.
The session row's own `cwd` is the creation-time launch directory and is used only as a fallback when no foreground process can be attributed.

The same capture returns `foreground_process` and `foreground_command`, which give the adapter a native identity probe.
tmux reconstructs those facts with a process-table walk and the other backends have no answer at all, so thurbox is the only non-tmux backend that can offer the composer classifier a real identity signal.

## Capture

`session capture --lines N` prepends up to N scrollback rows to the whole visible screen, which is the same contract as tmux's `capture-pane -p -S -N`.
Verified on a 63-row pane: `--lines 50` returned 113 rows, and `--lines 500` returned 403, capped by the scrollback actually available.

The response is therefore returned whole and never trimmed locally.
A `tail -n N` would discard every requested scrollback row plus the top of the screen.

The composer capture uses `--lines 0` deliberately.
`cursor_row` is 0-based relative to the **visible pane**, so any positive `--lines` desynchronizes it from the returned text.

Panes running an alternate-screen agent have no scrollback, so every `--lines` value returns the same visible screen there.
That is correct behavior, not a bound being ignored.

## Session names

One thurbox instance owns one session-name namespace for the whole machine, like cmux's app-global workspace list and zellij's shared tab bar.
Two Firstmate homes whose task ids collided would otherwise fight over one name: the second home's create would be refused by the first home's live session, and a name lookup could resolve to the wrong home's endpoint.

Task sessions are therefore named with the shared home tag (`bin/fm-backend-hometag-lib.sh`), the same mechanism cmux and zellij use.
thurbox caps a name at 64 characters and rejects slashes and a leading dot, so an over-long task label is refused loudly rather than truncated into a name that no longer identifies its task.

Creation uses `--on-existing fail`.
The default `allow` would create a second session sharing the name, after which thurbox refuses to resolve that name at all.

## Teardown

`session delete --force` is required, not a convenience.
A bare `session delete` only soft-deletes the row and leaves the pane running, so a headless Firstmate teardown would report success while the agent kept running.

Firstmate's tasks are created with `--repo-path` against an already-built Treehouse worktree, never with `--worktree-branch`, so thurbox owns no worktree for them and `--force` removes none.

### Absence has to be proven, not inferred

Row-absence is not endpoint-absence, and the gap is not a brief reap window.
A soft `session delete` removes the row while the pane keeps running, and thurbox then refuses to force-delete a row it can no longer resolve - `session delete <id> --force` answers `Session not found` - so that pane outlives the session indefinitely.
Reclaiming it needs `session restore` first.

Firstmate's own teardown always passes `--force` and never creates that state, so the exposure is a delete from outside: the TUI's own, or a peer's.

`session list --deleted` carries a `force_deleted` mark, which is the discriminator, verified on 2.18.0: a force-deleted session left no window on thurbox's socket, a soft-deleted one left its window running.
`fm_backend_thurbox_deleted_disposition` reads it, and both teardown-facing reads consult it once the live inventory comes back empty:

- `fm_backend_thurbox_endpoint_confirmed_gone` reports proof only when the session is absent from both inventories, or present in the deleted one as force-deleted.
- `fm_backend_thurbox_agent_state` reports `missing` only in those same cases, and `unreadable` for a soft-deleted session.

That second one is the sharper edge: only `dead` and `missing` license recovery, and recovery starts a replacement agent, so answering `missing` for a session whose agent is still running would invite a second agent into one task.

### Parked sessions

A parked session (`session stop`) keeps its row, checkout and conversation but loses its pane, so no send, key, or capture can land on it.
From 2.11.1 the session row says so directly: `stopped` is on both `session get` and `session list`, and `state` answers `stopped`.

`fm_backend_thurbox_target_ready` reads that flag, so a parked session is never a ready write target.
`fm_backend_thurbox_agent_state` reads it off the inventory row it already holds and reports `dead` rather than `missing`, so recovery relaunches into the session instead of treating the endpoint as gone.

On 2.11.0 neither read could answer, which is what the version floor exists to refuse.

## Sending text

`session send` delivers text as one bracketed paste, so a leading `-`, quote or newline survives intact.
That promise is about delivery; the argument parser is a separate gate.

With the text as a trailing positional, a leading `-` is read as a flag and the call is refused outright with nothing typed - verified on 2.18.0 as `unexpected argument '-x' found`, exit 2.
The adapter therefore sends as `session send --no-enter --json <uuid> -- <text>`.
The order is exact: every flag and the uuid must precede the `--`, because `session send <id> -- <text> --no-enter` instead refuses `--no-enter`.

A steer beginning with a dash is the case this protects; Firstmate's own export lines and harness launch commands never start with one.

## Known gaps

- **No secondmate spawns.** `--secondmate` is refused on this backend, matching cmux. The path is not verified.
- **`session exec` does not carry the session's environment.** It sets the cwd and host but inherits the *caller's* environment, so `--env` values from `session create` are absent and the caller's own `THURBOX_SESSION` leaks into the child. A `thurbox-cli session signal` run through `session exec` would report state for the caller's session rather than the target's. The adapter does not use `session exec`; the pane's own environment is correct, and a pane created for a task carries that task's `THURBOX_SESSION`, not its parent's.
- **Hook coverage requires thurbox to launch the agent.** See "Agent state and hook coverage" above. Native busy state is unavailable for Firstmate-launched agents until the hook payload can be applied to an externally launched one.
- **A harness thurbox does not register reports no native state.** Firstmate passes through whatever `agent launch-args` reports, so an agent absent from `agents.toml` has nothing to pass and its sessions fall back to the pane read. Adding an entry for that agent in `agents.toml` is all it takes; Firstmate needs no change.

## Verification

The dated per-backend result lives in [`verification/runtime-backends.md`](verification/runtime-backends.md).

`tests/fm-backend-thurbox.test.sh` is the portable regression suite.
It drives a fake `thurbox-cli` with a real `jq`, so it needs no thurbox installation and runs everywhere CI does.
