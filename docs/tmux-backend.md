# tmux runtime backend (reference)

tmux is firstmate's verified reference runtime backend: the session provider every other backend is compared against, and the fully verified baseline for secondmate support.
This is the setup guide; for the shared runtime-backend abstraction and selection order, see [`docs/architecture.md`](architecture.md) ("Runtime session backends") and [`docs/configuration.md`](configuration.md) ("Runtime backend").

## What it is and when to pick it

tmux is a terminal multiplexer.
Firstmate gives each crewmate its own tmux window inside a session, so you can attach and watch a task work, or type into its window to intervene directly.
Pick tmux unless you have a specific reason to try an experimental backend (herdr, zellij, Orca, or cmux) - it is the fully verified reference path for secondmate homes, while Orca and cmux are the backends that do not support secondmate spawns.

## Prerequisites

- tmux itself: `brew install tmux` (or your platform's package manager).
- The universal firstmate prerequisites: a verified crew harness plus the required toolchain, detected at session start and installed only after you approve; [`docs/configuration.md`](configuration.md) owns both lists ("Harness support", "Toolchain").

## Selecting it

tmux is the hard default: it needs no explicit selection.
It is also what firstmate falls back to when nothing else is set - no local `config/backend` file, no `FM_BACKEND`, no explicit `--backend` flag firstmate passes internally when it spawns a task - and runtime auto-detection (see below) does not pick anything either.
You can still select it explicitly by putting `tmux` in a local `config/backend` file - the durable way to pick it - or by exporting `FM_BACKEND=tmux` when you launch your harness for a one-off session; telling the first mate in chat to use tmux also works.
This mainly matters as an opt-out of herdr or cmux runtime auto-detection (see [`docs/herdr-backend.md`](herdr-backend.md) and [`docs/cmux-backend.md`](cmux-backend.md)).

## First run

Nothing to provision up front.
The first crewmate spawn creates whatever tmux session and window it needs.

## Session per firstmate home

Every firstmate home uses the tmux session named after that home's directory basename, whether the harness runs inside or outside tmux.
For example, `~/orca/firstmate` uses `firstmate`, while `~/orca/firstmate-life` uses `firstmate-life`.
Each session carries an `@firstmate-home` option containing the physical `FM_HOME` path.
If another home with the same basename tries to reuse that session, firstmate reports the conflicting owner and refuses the spawn.
An existing unstamped session is stamped on its first reuse so the historical `firstmate` session and all of its existing windows and task records remain valid.

## Crew panes cannot reach the fleet's tmux server

Firstmate runs its own tmux server and every crewmate window is a window on it, so one `tmux kill-server` ends the entire fleet.
That is not hypothetical: on 2026-07-27 20:16 and again on 2026-07-28 00:47 this fleet vanished in about two seconds.
The second time, `atop` process accounting (`atop -P PRG -r /var/log/atop/atop_20260728 -b 00:45 -e 00:50`) showed the tmux server (pid 588148) exiting with code **0** - a clean, voluntary exit, not a signal - and five agents exiting 0 right behind it after their SIGHUP.
The last tmux command on the machine came from a crewmate pane at 00:47:18.
Cgroup memory (`memory.failcnt=0`, `oom_kill=0`), logind (`KillUserProcesses=false`), and the Orca daemon log all cleared.
The cause was structural, not one agent's mistake: every pane inherited `$TMUX`, so a bare `tmux` typed anywhere inside the fleet operated on the fleet's own server, and a crewmate that had been sent to study tmux behavior had no way to tell its own sandbox from the fleet's lifeline.

Each spawned pane now gets a private tmux namespace, applied when the window is created:

```sh
tmux new-window -e TMUX_TMPDIR=/tmp/fm-<id>/tmux -e TMUX= ...
```

Emptying `$TMUX` detaches the pane from the fleet's server, and `TMUX_TMPDIR` moves tmux's socket directory, so a bare `tmux`, a `tmux -L <anything>`, and `tmux kill-server` all land on a throwaway per-task server.
`bin/fm-teardown.sh` stops any server left in that directory and removes it with the rest of `/tmp/fm-<id>/`.
Verified against a real server (`tests/fm-tmux-fleet-isolation.test.sh`): `tmux ls` inside the pane lists only the pane's own sessions, `tmux kill-server` returns 0, and the fleet's windows are all still there afterwards.

Setting it at creation rather than typing `unset TMUX; export TMUX_TMPDIR=...` into the pane is deliberate.
A shell-startup prompt can swallow the leading character of a sent line - the hazard `bin/fm-spawn.sh` already guards `treehouse get` against - and a sandbox that silently failed to apply would leave the pane holding the fleet's own server with nothing to show for it.
`new-window -e` needs tmux 3.0 or newer; on an older tmux, firstmate warns and falls back to typing the same environment in.
`-e TMUX=` sets the variable EMPTY rather than truly unsetting it (tmux's `-e` has no unset form), which is equivalent everywhere it matters: tmux itself treats the empty value as "not inside a server" - a nested `tmux new-session` inside such a pane succeeds instead of refusing - and every firstmate reader tests `$TMUX` for non-empty.

`$TMUX_PANE` is deliberately left in place.
It names a pane, not a server, so it cannot reach the fleet on its own, and a secondmate - a firstmate primary that lives in one of these panes - finds its own supervisor pane through it.
A secondmate also needs to dispatch its own crew onto the shared server, so its pane (and only its pane) is additionally given `FM_TMUX_SOCKET=<fleet socket>`.

This closes the accident, not every possible act: an agent that deliberately runs `tmux -S <absolute path to the fleet socket>` still reaches the server.
A PATH-prefixed `tmux` wrapper was considered as a second layer and rejected - it is bypassed by an absolute path, so it buys no boundary, while adding an exec to every tmux call in every pane.
The refusal that does hold is inside firstmate's own code: `fm_tmux` (`bin/fm-tmux-lib.sh`) rejects `kill-server` outright, so no future edit to a fleet-side script can reach it.

## Which tmux server the fleet uses

The fleet is always ONE tmux server, and by default it is the one firstmate is already running in - so `tmux attach` is unchanged and every crewmate stays in the same session and the same window list.
`bin/fm-tmux-lib.sh` resolves it in this order:

1. `FM_TMUX_SOCKET` - an explicit binding: a task's recorded socket, the value handed to a secondmate pane, or an operator override.
2. `$TMUX`'s socket path - the server firstmate itself is running in.
3. `${TMUX_TMPDIR:-/tmp}/tmux-<uid>/default` - tmux's own default socket, where a firstmate launched outside tmux has always put its fleet.

A dedicated socket is available but is an operator choice, not a default.
Start the primary inside `tmux -L firstmate` and rule 2 puts the whole fleet - crew windows, the away-mode daemon, everything - on that server.
Attaching then becomes:

```sh
tmux -L firstmate attach -t <home-basename>
```

Each tmux task records `tmux_socket=` in `state/<id>.meta`, and every reader - peek, send, crew state, the watcher, teardown - addresses the server that field names.
A meta written before the field existed has no `tmux_socket=` line; it resolves to the ambient fleet socket, which is exactly what every reader did before, so tasks spawned earlier keep resolving to the server they are actually on.

## Watching crew in tmux

Attach to the session named after the active firstmate home:

```sh
tmux attach -t <home-basename>
```

## Watching and typing into crew windows

Once attached, each crewmate is its own window named `fm-<id>`:

```sh
tmux list-windows -t <session-name>          # see every crew window
tmux select-window -t <session-name>:fm-<id> # jump to one, or use ctrl-b <n>
```

Use the firstmate home basename as the session name.
Typing directly into an attached window is authoritative direct intervention - the first mate treats it the same as any other captain instruction and reconciles at the next heartbeat.
You do not need to attach at all for routine supervision: from an active firstmate session, the first mate reads crew windows itself with `bin/fm-peek.sh fm-<id>` (a bounded, read-only capture) and steers a crew with `FM_HOME=<this-firstmate-home> bin/fm-send.sh fm-<id> "<text>"` unless `FM_HOME` is already set to the active firstmate home.

## Verifying it works

Ask the first mate for any small piece of work, or spawn a trivial scout task, and confirm a new window shows up:

```sh
tmux list-windows -t <home-basename>
```

You should see a `fm-<id>` window for the task, live and updating as the crewmate works.

### Home-isolation verification, 2026-07-22

Verified empirically with tmux 3.6a on macOS (Darwin 25.5.0 arm64) by `tests/fm-backend-tmux-smoke.test.sh` on a private tmux socket:

```text
ok - real tmux: two FM_HOME basenames create separate stamped sessions and task windows
ok - real tmux: a basename collision with a mismatched ownership stamp errors and stops
ok - real tmux: an existing unstamped basename session is claimed without disturbing its windows
```

The test creates `firstmate` and `firstmate-life`, creates one task window in each, reads both ownership stamps, attempts a conflicting second `firstmate` home, and confirms a legacy unstamped session keeps its existing window while being claimed.

## Endpoint existence: why `display-message` cannot answer it

`display-message` never reports a missing target as an error, so it cannot be used to ask whether a window still exists.
Verified on tmux 3.3a, 2026-07-28, against a private socket:

```sh
$ tmux -S "$S" display-message -p -t 'totally:bogus' '#{pane_id}'
rc=0 out=[]
# session `sess` live, its window `fm-x` killed:
$ tmux -S "$S" display-message -p -t 'sess:fm-x' '#{pane_id}'
rc=0 out=[%0]        # the session's CURRENT pane, not the window asked for
```

tmux resolves an unresolvable target against the current client/session instead of failing.
The exit code is always 0, and the output is either empty or *some other window's* pane id.
`fm_backend_target_exists` used to test only that exit code, so while any tmux server was reachable every long-dead window read back as `endpoint: alive` - which is what the session-start fleet digest reported for the entire fleet right after the 2026-07-28 incident wiped it (issue #1130).
Checking that the output is non-empty is not enough either, because of the second case above.

`fm_backend_tmux_target_exists` (`bin/backends/tmux.sh`) enumerates instead: one `list-panes -a` listing every live pane in each addressable form (`%id`, `@id`, session name, `session:window` by name or index, with or without a `.pane` suffix), and requires an exact match.
It never starts a server - with none running, tmux exits non-zero with `error connecting to <socket>`.

## Agent liveness probe

`fm_backend_target_exists` (`bin/fm-backend.sh`) only checks that a window's pane still exists.
A secondmate agent that exits leaves its pane alive as a bare idle shell, which passes that check as "alive" - the gap `bin/fm-bootstrap.sh`'s session-start secondmate-liveness sweep exists to close (evidence 2026-07-07: every secondmate in one fleet was found sitting at a dead `zsh` shell, invisible to that check).

`fm_backend_tmux_agent_alive` (`bin/backends/tmux.sh`) answers a deeper question: is a real harness-agent *process* running in the pane right now, not just whether the pane exists?
It reads tmux's own `#{pane_current_command}`, which reports the pane's live foreground process name - already resolved by tmux from the pty's controlling process group, not something this adapter derives itself.

Agent liveness and composer safety are separate checks.
During away-mode escalation delivery, `fm_tmux_composer_state` sends a bare shell glyph on an unbordered row to the shared composer classifier as `unknown`, and the daemon injects only into an affirmatively `empty` composer; see [Composer-emptiness safety](herdr-backend.md#composer-emptiness-safety-2026-07-10-fleet-wide-across-all-four-backends).

## Submit acknowledgement: "landed" is empty (with one busy-queue exception)

The shared `fm_tmux_submit_enter_core` (`bin/fm-tmux-lib.sh`) types the message once, then retries Enter (Enter only, never a retype) until the composer clears.
The submit is reported `empty` iff the composer cleared, which is the same corrected, border-aware detector the composer guard uses, so a bordered-but-empty composer is correctly seen as the positive acknowledgement of a delivered submit.
A genuine swallowed Enter leaves the typed text in the composer and the function reports `pending`; `fm-send` fails on `pending` so the captain learns the steer did not land instead of leaving it unsubmitted.

**Exception (opencode 1.18.4, on the tmux backend):** while the agent is mid-turn, opencode accepts Enter as a "send when the turn ends" keystroke but does not clear the composer until then, so the typed text stays visible the whole time.
After the Enter-retry budget is spent and the composer still reads `pending`, the submit core falls back to `fm_pane_is_busy`:
a busy pane means the harness accepted and queued the Enter (reported as `empty`, so the caller does not re-send), and an idle pane keeps `pending` as a genuine swallow.
This is the only place that exception lives; the herdr adapter observes the same opencode behavior but needs a separate fix (see the opencode note in [harness-adapters](../.agents/skills/harness-adapters/SKILL.md) and the opencode-busy gap recorded in [herdr-backend.md](herdr-backend.md)).
Regression coverage: `tests/fm-tmux-submit-busy.test.sh` covers the four scenarios (busy pane + pending composer -> `empty`, idle pane + pending composer -> `pending`, busy pane + cleared composer -> `empty`, idle pane + cleared composer -> `empty`).

Verified empirically with real tmux 3.6a on macOS (Darwin 25.5.0), 2026-07-07:

```sh
$ tmux new-session -d -s fmtest -n testwin
$ tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
zsh
$ tmux send-keys -t fmtest:testwin 'sleep 30' Enter
$ tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
sleep
$ tmux send-keys -t fmtest:testwin C-c
$ tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
zsh
```

An idle pane reports the shell's own name; a live foreground process reports its own name; the pane reverts to the shell's name the moment that process exits - exactly the alive/dead signal the probe needs.

A second case matters for a harness that shells out to subcommands while it runs (git, npm, no-mistakes, ...): does `pane_current_command` report the harness or the subcommand?
Verified the same session: a persisting parent process running a child command (`bash -c 'echo start; sleep 30; echo end'`, where the parent bash stays alive waiting on its own child) reports the PARENT's own name (`bash`) throughout, not the child's (`sleep`) - so a harness that survives while it shells out stays correctly classified as alive.
(A single-simple-command `bash -c "sleep 30"` is a different, unrelated case: bash execs directly into `sleep`, replacing itself, so the reported name changes because the process itself became `sleep` - not because tmux "saw through" to a child.)

The classifier (`fm_backend_tmux_agent_alive`) maps the observed name to `alive`, `dead`, or `unknown`:

- `alive` - the name contains `claude`, `codex`, `opencode`, or `grok`. All four were confirmed to run as their own literal process name (`ps -ef`, 2026-07-07): `claude` and `codex` and `opencode` are each a native compiled binary (`file` reports Mach-O), so their `comm` is their own binary name with no interpreter wrapper to hide behind.
- `dead` - the name is a bare shell (`zsh`, `bash`, `sh`, `dash`, `ash`, `ksh`, `mksh`, `tcsh`, `csh`, `fish`).
- `unknown` - anything else, including an unreadable pane.

### Known gap: `pi` cannot be confidently classified

`pi` is a `#!/usr/bin/env node` script (confirmed via its shebang and installed path, 2026-07-07), so a live `pi` agent's pane reports `node` as its `pane_current_command`, not `pi` - verified by running a long-lived `node -e` script in a pane and confirming its foreground process is a genuine child reachable via `pgrep -P <pane_pid>` with an inspectable `ps -o args=` (the same technique `bin/fm-harness.sh`'s own self-detection uses when walking UP its ancestry), while `pi --version` itself was observed to exit too quickly under the same pane to reliably capture its live foreground state - real `pi` invocations were not available to test.
Since `node` is also the generic name for a plain interpreter session, any future JS-based harness, or someone's unrelated node script, there is no way to attribute a bare `node` foreground process back to `pi` specifically from outside the pane without deeper (and fragile) argument introspection.
The classifier deliberately reports `unknown` for `node`/`python`/`python3` rather than guess - per the secondmate-liveness sweep's correctness bar, a wrong `alive` is harmless but a wrong `dead` spins up a duplicate agent, so an unresolvable case must never be treated as confidently dead.
Practical effect: a dead `pi` secondmate is not auto-healed by the liveness sweep today; it is reported as `skipped: liveness probe inconclusive` instead, which still surfaces it for a human to act on.
Resolving this would need either a `pi`-specific env marker inspectable from outside the process (mirroring `PI_CODING_AGENT=true`, which `bin/fm-harness.sh` already uses for self-detection but which is not readable from a different process without deeper introspection) or accepting the argument-inspection fragility - not attempted here.

## Limitations

None specific to tmux for the reference path itself - it is the fully verified reference backend, while Orca and cmux are the backends without secondmate support.
The agent-liveness probe above has one known gap (`pi`'s generic `node` process name, see above).
