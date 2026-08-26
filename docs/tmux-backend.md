# tmux runtime backend

tmux is Firstmate's verified reference runtime backend and the fully supported baseline for secondmate homes.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared backend selection and metadata semantics.

## Setup

Install tmux with `brew install tmux` or your platform package manager.
The universal harness and toolchain requirements are in [`configuration.md`](configuration.md#toolchain).

tmux is the hard default when no explicit setting or runtime auto-detection selects another backend.
Select it explicitly with local `config/backend` containing `tmux`, with `FM_BACKEND=tmux` for one launch, or by asking Firstmate to use tmux.
An explicit selection is also the opt-out from Herdr or cmux runtime auto-detection.

No provisioning is required before the first task.

## Watching the crew

For the best visible experience, launch the primary harness inside a tmux session:

```sh
tmux new -s firstmate
```

Nothing to provision up front.
The first crewmate spawn creates whatever tmux session and window it needs.
Crew tasks become windows in that session, and `tmux display-message -p '#S'` prints its name.

## Session per firstmate home

Every firstmate home uses the tmux session named after that home's directory basename, whether the harness runs inside or outside tmux.
For example, `~/orca/firstmate` uses `firstmate`, while `~/orca/firstmate-life` uses `firstmate-life`.
Each session carries an `@firstmate-home` option containing the physical `FM_HOME` path.
An existing unstamped session is stamped on its first reuse so the historical `firstmate` session and all of its existing windows and task records remain valid.

### When two homes have the same basename

A home whose basename is already owned by a *different* home falls back to a second session name instead of failing.
The fallback is the shared home tag from [`bin/fm-backend-hometag-lib.sh`](../bin/fm-backend-hometag-lib.sh) - `firstmate-<hash>` for a primary home, `2ndmate-<id>-<hash>` for a secondmate home carrying `.fm-secondmate-home` - hashed over the resolved `FM_HOME`.

This is not a corner case.
A secondmate home leased from the firstmate repo itself always has the basename `firstmate`, the same basename the primary home usually has, so under basename-only naming such a home could never open a session and could never dispatch a single crewmate.

The `@firstmate-home` stamp still decides ownership and still refuses.
A session stamped with a different physical `FM_HOME` is stepped around, never reused, never renamed, and never restamped: the fallback moves the *new* home aside, it does not move the existing home's session.
When both candidate names are owned by other homes, the spawn stops with both owners named rather than inventing a third name.

Resolution is stable rather than per-spawn.
A session already stamped for this home is adopted before any new one is created, so a home that once fell back to the tag name keeps using it even after its basename frees up, and recorded `window=` handles are never stranded in an abandoned session.
The tag hashes `FM_HOME`, not `FM_ROOT`, so the primary home resolves a secondmate's session to the same name the secondmate resolves for itself - the two callers differ in `FM_ROOT` but not in `FM_HOME`.

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

If that home's basename is owned by another home, its session carries the fallback name instead.
List the sessions with their owners to find it:

```sh
tmux list-sessions -F '#{session_name}  #{@firstmate-home}'
```

## Watching and typing into crew windows

Once attached, each crewmate is its own window named `fm-<id>`:

```sh
tmux list-windows -t <session-name>          # see every crew window
tmux select-window -t <session-name>:fm-<id> # jump to one, or use ctrl-b <n>
```

Use the firstmate home basename as the session name, or the fallback name listed above when another home owns that basename.
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

The middle line is superseded by the record below: a basename collision now opens the home's own fallback session instead of stopping.
Refusal is still what happens when *every* candidate name is owned elsewhere.

### Same-basename fallback verification, 2026-08-10

Verified with tmux 3.3a on Linux (`5.15.120.bsk.3-amd64`, x86_64) by the same `tests/fm-backend-tmux-smoke.test.sh` on a private tmux socket:

```text
ok - real tmux: two FM_HOME basenames create separate stamped sessions and task windows
ok - real tmux: a home whose basename is owned by another home opens its own home-tagged session (firstmate-4240bf6b)
ok - real tmux: the foreign-stamped session keeps its name, stamp, and windows - it is stepped around, never reused
ok - real tmux: the fallback session name is stable across repeated container ensures
ok - real tmux: a secondmate-marked colliding home gets a readable 2ndmate-<id> session, identical from either caller's FM_ROOT (2ndmate-upstream-sync-5c4008a5)
ok - real tmux: a secondmate id with '.'/':' resolves to the name tmux really created (2ndmate-up_sync_v2-0917396c)
ok - real tmux: an existing session already stamped for this home is adopted before any new one is created
ok - real tmux: both candidates owned elsewhere still errors and stops, naming both owners and restamping neither
ok - real tmux: an existing unstamped basename session is claimed without disturbing its windows
```

The hashes vary per run because each run builds its homes under a fresh `mktemp -d`; the tag *shape* and the stability/adoption assertions are what the test pins.

#### Session names tmux rewrites

tmux does not refuse a session name containing `.` or `:` - it silently rewrites both to `_`.
Verified on tmux 3.3a, so the fallback applies the same mapping before printing a name and cannot report a session that does not exist:

```text
asked=[a.b] -> got=[a_b]
asked=[a:b] -> got=[a_b]
asked=[a b] -> got=[a b]
asked=[a/b] -> got=[a/b]
asked=[a@b] -> got=[a@b]
asked=[a%b] -> got=[a%b]
```

Nothing validates a secondmate id's character set upstream, so an id like `up.sync:v2` is reachable.
The basename candidate has the same exposure and always has: a home directory literally named `my.home` gets the session `my_home`.
That pre-dates this fallback and is not changed here.

#### Against a real fleet, not only the private socket

The same day, on the live fleet socket `/tmp/tmux-1001/default`, where the session `firstmate` was already owned by `/data00/home/haozhenfei/Documents/firstmate` and held seven live crew windows.

Before the change, a real secondmate home leased from the firstmate repo could not open any session:

```text
$ FM_HOME=/data00/home/haozhenfei/.treehouse/firstmate-fe3465/3/firstmate fm_backend_tmux_container_ensure
error: tmux session 'firstmate' belongs to FM_HOME '/data00/home/haozhenfei/Documents/firstmate', not '/data00/home/haozhenfei/.treehouse/firstmate-fe3465/3/firstmate'; refusing to reuse it
rc=1
```

After the change, the same home resolves a session, and resolves the *same* session whether its own root or the primary's root is on `FM_ROOT`:

```text
$ FM_HOME=<lease> FM_ROOT=<lease>            fm_backend_tmux_container_ensure
2ndmate-upstream-sync-d4279681 rc=0
$ FM_HOME=<lease> FM_ROOT=<primary firstmate> fm_backend_tmux_container_ensure
2ndmate-upstream-sync-d4279681 rc=0
```

The primary's session was unchanged across that run - same name, same stamp, same seven windows with their window ids and live agents:

```text
firstmate  windows=7  @firstmate-home=/data00/home/haozhenfei/Documents/firstmate
0 @87 fm-upstream-sync claude
1 @105 fm-topic-tracker-http-endpoints-live claude
2 @108 fm-fm-tmux-session-name-collision claude
3 @109 fm-coze-plugins-lifecycle-docs claude
4 @43 fm-coze-cr-guard claude
8 @96 fm-panel-gateway-mcp-handlers claude
10 @100 fm-coze-fe-test-skill-scout claude
```

A second live home on the same server gave the disconfirming check.
A scratch `FM_HOME` whose basename was `coze-cr-guard` - the session name a *different*, running home owns - was stepped around rather than reused, and that home's stamp and all four of its crew windows were untouched:

```text
live 'coze-cr-guard' session stamp = /data00/home/haozhenfei/fm-homes/coze-cr-guard
resolved session = firstmate-641268c0   (must NOT be 'coze-cr-guard')
live 'coze-cr-guard' stamp AFTER  = /data00/home/haozhenfei/fm-homes/coze-cr-guard
  1 @55 fm-cr-biz-ctx-rules claude          (before and after, unchanged)
  2 @63 fm-cr-tick-20260731-space claude
  3 @66 fm-cr-tick-20260801-space claude
  4 @65 fm-cr-tick-20260731-rest claude
```

Both scratch sessions this verification created were empty (a bare shell only) and were removed afterwards, leaving the fleet as found.

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

## Current behavior and safety

### Agent liveness probe

A target-existence check proves only that the pane exists.
The deeper tmux agent-liveness probe first verifies exact window membership, then reads process names to distinguish a running harness from a bare idle shell.
It classifies recognized Claude, Codex, OpenCode, Pi, pi-signed, Grok, Kimi, Cursor, and Muse process identities as `alive`, common shells as `dead`, an authoritatively absent window as `missing`, unreadable state as `unreadable`, and every other process as `ambiguous`.
Only `dead` and `missing` authorize recovery because a false dead result could launch a duplicate agent.

For positive attribution, the probe combines two independent name sources rather than making either one load-bearing.
`#{pane_current_command}` and the pane tty foreground process group's kernel `comm` values expose different name fields, and which one retains executable identity is platform-dependent.
The foreground probe also reads argv[0] so an exact harness install-path component can carry the verdict when the other fields expose a rewritten process name.
Either source naming a verified harness is enough for `alive`, because a false `dead` is the one verdict that can start a duplicate agent on a live worktree, while a readable foreground process group settles the negative verdicts.

Scoping the second source to the foreground process group rather than to the pane's descendants is deliberate: a harness-named process left running in the background of an otherwise idle pane must not read as an agent.
The same scoping covers multi-process launchers without a special case, so the Pi Launcher path is attributed through its `pi-signed` wrapper and `pi` engine even though its title is the exact foreground command `pi-launcher`.
Direct executable identities `pi`, `pi-signed`, and `Pi` remain accepted exactly, and similar or prefixed process names are not accepted through those exact Pi-family entries.
Muse is likewise anchored to the exact `muse` launcher identity or the installed `muse-bin-<version>` prefix, so unrelated names such as `musescore` and `amuse` remain ambiguous.
Cursor is identified from its exact `cursor-agent` identity or versioned install tree in the foreground process path or structured argv[0]; a bare `node` or unrelated `agent` remains ambiguous.

The CI-enforced portable regression and opt-in real-harness drift guard follow the split owned by `.agents/skills/firstmate-coding-guidelines/SKILL.md`.
Run the real-harness guard after any harness upgrade and before trusting refreshed evidence.

### Composer, busy state, and delivery

Agent liveness and composer safety are separate checks.
The tmux reader is a thin adapter over the fleet-wide classifier in `bin/fm-composer-lib.sh`: it contributes one styled full-pane capture, the `#{cursor_y}` cursor row, and foreground-process identity probes, and the shape containing the cursor - a complete bordered box (titled bottom borders tolerated), a bare agent-glyph row with its wrapped input, opencode's left bar, or Pi's identity-corroborated separator pair - normally decides the verdict.
Real text in an identified shape is pending, while only positively proven emptiness reads empty.
A blank or otherwise unidentified cursor row is `unknown` and every consumer defers, except that a foreground process proven to be Cursor is re-read cursorlessly because Cursor parks its terminal cursor below its footer.
That identity-gated exception preserves the strict container-proof rule for every other pane, so a modal dialog, a dead shell between stale rules, or a mid-redraw pane is never an injection target.
The shared classifier accepts a shell glyph as an empty agent composer only inside a bordered container.
A bare shell prompt is `unknown`, so away-mode escalation is never injected into a dead shell.

Busy state is not read from rendered text on this backend.
A task's busy, idle, unknown, or dead verdict comes from the semantic busy-state contract owned by `bin/fm-busy-lib.sh`; [architecture](architecture.md#busy-state-is-semantic-per-adapter) owns its boundaries.
The one remaining rendered-tail reader is Grok's isolated fallback inside that contract, which can only classify a Grok task.
The submit acknowledgement and away-mode supervisor-pane busy guard below still consult rendered output, but only to decide whether input can be delivered, never to decide recorded task state.
The supervisor guard selects only the detected primary harness's signature rather than a global union of vendor patterns.

`bin/fm-tmux-lib.sh` owns exact type-and-submit mechanics.
It types a message once and retries Enter only until the composer clears.
Only a proven empty composer is a positive delivery acknowledgement.
Text left in established structure remains `pending`, text in ambiguous structure remains unproven, and unreadable or unsafe state remains unknown.
An ordinary local `fm-send.sh` text steer and every remote text steer no longer ride this verified submit at all: they become durable steering-inbox records plus best-effort constant doorbell lines (`bin/fm-task-inbox-lib.sh`).
The verdicts above are delivery-critical only for the local typed plane - harness-native invocations and explicit backend targets - where `fm-send.sh` still never retypes or assumes a confirmed submit for an unconfirmed verdict; its header owns the distinct delivered-unconfirmed exit status and operator response.

OpenCode 1.18.4 has one busy-queue exception.
While OpenCode is mid-turn, Enter queues the message but leaves its text visible until the turn completes.
After the normal retry budget, only structurally proven pending text in a provably busy pane is accepted as queued, while an idle pane remains `pending` as a genuine swallowed Enter.
Ambiguous pending text never receives the busy-queue conversion.
A second, baseline-gated conversion covers harnesses whose mid-turn screen the classifier cannot identify (Pi replaces its separated composer while working): when and only when the pane was idle before the text was typed, an idle-to-busy transition across the submit's own Enter confirms delivery, the same turn-started signal Herdr reads natively.
Without that baseline, an `unknown` verdict is preserved untouched, so a busy-looking pane can never convert an unread composer into a confirmation.
`tests/fm-tmux-submit-busy.test.sh` covers busy and idle panes with proven, ambiguous, and cleared composers.

## Limits and regression entry points

- tmux is the reference path and supports secondmate homes.

```sh
tests/fm-backend-tmux-smoke.test.sh
tests/fm-tmux-agent-liveness.test.sh
tests/fm-harness-liveness-drift-live-e2e.test.sh
tests/fm-composer-ghost.test.sh
tests/fm-kimi-harness.test.sh
tests/fm-cursor-harness.test.sh
tests/fm-muse-harness.test.sh
tests/fm-tmux-submit-busy.test.sh
tests/fm-bootstrap.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#tmux) records the active foreground-process and submit evidence.
