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

- thurbox 2.11.0 or newer, providing `watch`, `session create --command/--arg/--env`, `--on-existing`, `session meta`, `session exec`, and `session stop`.
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

It is not always present, and the reason matters.
thurbox installs those hooks by appending an agent's `args` from `agents.toml` when **thurbox** launches the agent, for example `--settings <hooks>.json` for Claude.
Firstmate's spawn contract is uniform across every backend: create a shell endpoint, type exports into it, then type the harness launch command.
An agent Firstmate launched that way carries no thurbox hook wiring and reports no state.

The adapter therefore gates the signal rather than trusting the row:

- The state is used only when `state_source` is `hook`.
- A state thurbox itself marks `hook_state_contradicted` is refused.
- Everything else reports `unknown`, which every caller already understands as the cue to fall back to the harness-scoped pane read.

A busy verdict from this backend is consequently never a stale row.
`thurbox-cli session doctor <id>` reports whether hooks are wired and firing for a given session.

One more reason the adapter treats `blocked` as idle rather than as an actionable state: for Claude the blocked signal comes from its `Notification` hook, which also fires for advisories an auto-mode agent resolves by itself, so the state can appear and clear within seconds with no decision pending.
thurbox reports this honestly as `hook_blocked_is_heuristic` on the session row.
A supervisor that escalates on the first `blocked` edge will raise false alarms; confirm the state persists, or corroborate it, before treating it as a decision waiting.

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
A bare `session delete` only soft-deletes the row and leaves the pane running until the TUI's next sync, so a headless Firstmate teardown would report success while the agent kept running.

Firstmate's tasks are created with `--repo-path` against an already-built Treehouse worktree, never with `--worktree-branch`, so thurbox owns no worktree for them and `--force` removes none.

### Parked sessions are not visible to the read verbs

A parked session (`session stop`) keeps its row, checkout and conversation but loses its pane.
thurbox 2.11.0 reports that session through `session get` and `session list` **identically to a running one**: same `state`, same `backend_id` still naming the window that no longer exists, and no `stopped` field on either read.
Only `watch` carries the parked flag.

That shapes two adapter reads.

`fm_backend_thurbox_target_ready` probes the pane with `session capture`, which fails on a parked session, rather than trusting the row.
Gating on the row would call every parked session ready and let every write silently address nothing.

`fm_backend_thurbox_agent_state` takes the authoritative answer from `watch --initial --session <uuid> --for-secs 1`, the only read that reports the flag.
It reports a parked session as `dead` rather than `missing`, so recovery relaunches into it instead of treating the endpoint as gone.
That read costs about a second, which is why only this recovery-grade caller pays for it.

## Known gaps

- **No secondmate spawns.** `--secondmate` is refused on this backend, matching cmux. The path is not verified.
- **`session exec` does not carry the session's environment.** It sets the cwd and host but inherits the *caller's* environment, so `--env` values from `session create` are absent and the caller's own `THURBOX_SESSION` leaks into the child. A `thurbox-cli session signal` run through `session exec` would report state for the caller's session rather than the target's. The adapter does not use `session exec`; the pane's own environment is correct, and a pane created for a task carries that task's `THURBOX_SESSION`, not its parent's.
- **Hook coverage requires thurbox to launch the agent.** See "Agent state and hook coverage" above. Native busy state is unavailable for Firstmate-launched agents until the hook payload can be applied to an externally launched one.
- **A parked session is unreadable from `session get` and `session list`.** See "Parked sessions are not visible to the read verbs" above. The adapter works around it with a pane probe and a `watch` read; a cheap authoritative field on the ordinary read verbs would remove both.

## Verification

The dated per-backend result lives in [`verification/runtime-backends.md`](verification/runtime-backends.md).

`tests/fm-backend-thurbox.test.sh` is the portable regression suite.
It drives a fake `thurbox-cli` with a real `jq`, so it needs no thurbox installation and runs everywhere CI does.
