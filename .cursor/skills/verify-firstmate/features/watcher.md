# Watcher

Firstmate's event-driven supervisor sleeps on one home and prints one reason line when something needs a wake, without spending model tokens while it waits.

## Sub-features

- `arm` - start or attach one home-scoped watcher and print `watcher: started pid=<n> (beacon fresh)` or `watcher: attached pid=<n> (beacon <age>s)`
- `actionable-exit` - a seeded status line ends the cycle with a reason instead of a silent empty completion
- `home-lock` - the pid lives only in this home's `state/.watch.lock`

## How to get to it (user POV)

- Leave a healthy Firstmate session running so the harness stop-hook or supervision block re-arms the watcher
- Ask Firstmate to watch the fleet
- Operators may arm one cycle by hand with `bin/fm-watch-arm.sh` from the home they intend to supervise

## Driving it with bin/fm-watch-arm.sh

Preconditions: scratch home launched and doctor-passed; `FM_HOME` already exported to that home; do not arm the live code-root home.

On a Firstmate primary the arm seatbelt allows only the blessed tree: `export` setup lines, then a standalone `bin/fm-watch-arm.sh` with no inline env, redirection, pipeline, or extra commands.

- Seed one actionable status in a prior command: `printf 'done: verify-smoke\n' > "$FM_HOME/state/verify-smoke.status"`.
- Arm a short cycle as its own call:

```sh
export FM_HOME=/tmp/verify-firstmate-home-<run-id>
export FM_SIGNAL_GRACE=1
export FM_POLL=1
export FM_HEARTBEAT=999999
export FM_CHECK_INTERVAL=999999
bin/fm-watch-arm.sh
```

Use the scratch path printed by `init`, not an inline assignment on the arm line.

- Observe a first line `watcher: started pid=<n> (beacon fresh)` or `watcher: attached pid=<n> (beacon <age>s)`.
- Observe the cycle end: the same command prints `signal: $FM_HOME/state/verify-smoke.status` and exits 0.
- Confirm isolation after the cycle: this home's `state/.watch.lock/pid` is the started pid or is gone after exit, and the live code-root `state/.watch.lock/pid` is unchanged.

## Gotchas

Never `pkill -f bin/fm-watch.sh`; that pattern matches every home.

`bin/fm-watch-arm.sh --restart` stops only the pid in this home's lock.

Do not background the arm with shell `&` inside another command; the child is reaped and no watcher remains.

A live watcher already present on this home is attached, not doubled.

A Firstmate Cursor, Claude, Codex, Grok, or OpenCode primary denies inline `FM_*=… bin/fm-watch-arm.sh`, evidence redirection, and bundled command lists; use the export-then-arm tree above.

A live Pi primary must use `fm_watch_arm_pi`; use the export-then-arm tree above only for an isolated scratch-home proof, never by running `bin/fm-watch-arm.sh` through Pi's bash tool.
