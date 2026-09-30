# Restricted Pi supervision

Restricted supervision is an opt-in way to run a Pi primary whose model never holds a general shell tool, so it cannot run arbitrary commands or read host credentials.
The model gets exactly three tools, none of which accepts free-form input: `fm_drain`, `fm_deliver`, and the watcher extension's `fm_watch_arm_pi`.
It cannot dispatch, steer, merge, edit files, or run commands; it supervises delivery of work that is already under way.
Ordinary Pi sessions and every other harness are unchanged.

## Launch

Run this from the firstmate home, or set `FM_HOME` as for any other primary:

```sh
FM_PI_RESTRICTED_SUPERVISION=1 pi --no-builtin-tools --no-extensions \
  -e .pi/extensions/restricted/fm-restricted-supervision.ts \
  -e .pi/extensions/fm-primary-pi-watch.ts
```

Keep the restricted extension first.
It takes the session lock in its `session_start` handler, and the watcher extension arms in its own `session_start` only when the lock is already held.
Selection is explicit twice: Pi never discovers the restricted extension on its own, and it registers nothing unless `FM_PI_RESTRICTED_SUPERVISION` is exactly `1`.
The restriction is verified rather than assumed.
If any other tool is active, for example Pi's built-in `bash` or an extension that re-registers the built-in tools, the extension takes no lock, drains nothing, runs no delivery pass, and says why on screen.
Leave the turn-end guard and the supervision branch out of this launch, because both assume a supervisor with a shell.

## What the supervisor can do

- The session lock is taken by `bin/fm-lock.sh` at session start and names the Pi process itself; no lock tool is exposed, and no other startup work runs.
- `fm_drain` presents queued wakes through `bin/fm-wake-drain.sh`, and `fm_drain` with `acknowledge: true` runs exactly the acknowledgement that its previous presentation printed.
  A presentation too large to show whole stores no acknowledgement, so no wake is ever consumed unseen.
- `fm_deliver` runs one pass of `bin/fm-deliver-cycle.sh`, which also runs every three minutes and after each agent run, one pass at a time.
  A pass arms merge monitoring for a task whose record shows exactly one ready change, and cleans up a task whose change the merge monitor confirmed merged, never with `--force`.
  The script's header owns the exact rules.
- Both tools act only while this Pi process holds the session lock.

## What stays with the captain

The restricted supervisor never merges, approves, or pushes.
The captain merges on the forge, the merge monitor notices, and the next delivery pass cleans up.
Automatic pass results appear as notifications on the captain's screen rather than in the model's context.
A refused cleanup is reported there and retried on later passes, and is never forced.

## Limits

- Engine commands receive only forwarded environment names, listed in the extension's header; model-provider keys in Pi's own environment are not forwarded, while forge credentials such as `GH_TOKEN` are.
- Each engine command runs with a bounded time that stops its whole process group.
- `FM_PI_RESTRICTED_DELIVER_INTERVAL_MS` overrides the three-minute interval.
- Wake handling beyond reading and relaying, such as answering a decision or recovering a stuck worker, needs a supervisor with a shell.

Behavior is pinned by `tests/fm-pi-restricted-supervision.test.sh` and `tests/fm-deliver-cycle.test.sh`, and `tests/fm-pi-restricted-supervision-live-e2e.test.sh` proves it against the installed Pi; the dated result lives in [supervision verification](verification/supervision.md#restricted-pi-supervision).
