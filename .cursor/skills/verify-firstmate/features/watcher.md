# Watcher

Firstmate's event-driven supervisor sleeps on one home and prints one reason line when something needs a wake, without spending model tokens while it waits.

## Sub-features

- `arm` - start or attach one home-scoped watcher and print `watcher: started pid=<n>` or `watcher: attached pid=<n>`
- `actionable-exit` - a seeded status line ends the cycle with a reason instead of a silent empty completion
- `home-lock` - the pid lives only in this home's `state/.watch.lock`

## How to get to it (user POV)

- Leave a healthy Firstmate session running so the harness stop-hook or supervision block re-arms the watcher
- Ask Firstmate to watch the fleet
- Operators may arm one cycle by hand with `bin/fm-watch-arm.sh` from the home they intend to supervise

## Driving it with bin/fm-watch-arm.sh

Preconditions: scratch home launched and doctor-passed; `FM_HOME` exported to that home; do not arm the live code-root home.

- Seed one actionable status: `printf 'done: verify-smoke\n' > "$FM_HOME/state/verify-smoke.status"`.
- Arm a short cycle: run `FM_SIGNAL_GRACE=1 FM_POLL=1 FM_HEARTBEAT=999999 bin/fm-watch-arm.sh` and observe a `watcher: started pid=<n> (beacon fresh)` or `watcher: attached pid=<n>` line.
- Observe the cycle end: the same command prints an actionable reason that names the seeded status, then exits.
- Confirm isolation: `cat "$FM_HOME/state/.watch.lock/pid"` is the pid just started, and the live code-root `state/.watch.lock/pid` is unchanged.

## Gotchas

Never `pkill -f bin/fm-watch.sh`; that pattern matches every home.

`bin/fm-watch-arm.sh --restart` stops only the pid in this home's lock.

Do not background the arm with shell `&` inside another command; the child is reaped and no watcher remains.

A live watcher already present on this home is attached, not doubled.
