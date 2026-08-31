# Session start

The captain's Firstmate session takes the helm by running one ordered digest: it acquires the per-home lock, prints toolchain and fleet facts, presents queued wakes, and emits the harness supervision block.

## Sub-features

- `lock` - acquire or refuse the per-home session lock before any mutating sweep
- `digest` - print the `SESSION START - <home>` banner plus lock, bootstrap, wake, fleet, and context sections
- `reemit` - reprint the digest after a clear or compact without re-running startup sweeps
- `completion` - write `state/.session-start-complete` with the lock pid when this session owns the lock

## How to get to it (user POV)

- Launch `claude`, `grok --trust`, `pi`, or `cursor-agent --trust` inside the clone so the session-open hook runs the digest
- Ask Firstmate to take the helm, or run `bin/fm-session-start.sh` once at the start of a session that has no digest yet
- After `/clear` or compaction, run `bin/fm-session-start.sh --reemit` when the same session still owns the lock

## Driving it with bin/fm-session-start.sh

Preconditions: scratch home from `scripts/verify-home.sh init`; `FM_HOME` exported from `scripts/verify-home.sh env`; do not run this against the live code-root home.

- Take the helm: run `scripts/verify-home.sh launch` (or `FM_HOME="$VERIFY_HOME" bin/fm-session-start.sh`) and observe `SESSION START - <VERIFY_HOME>` plus `lock acquired: harness pid <n>` on stdout.
- Confirm the lock: run `FM_HOME="$VERIFY_HOME" bin/fm-lock.sh status` and observe `lock: held by live harness pid <n>`.
- Confirm completion: read `$VERIFY_HOME/state/.session-start-complete` and observe that file equals the lock pid.
- Re-emit on the same home: run `FM_HOME="$VERIFY_HOME" bin/fm-session-start.sh --reemit` and observe `SESSION START (CONTEXT RE-EMIT) - <VERIFY_HOME>`.

## Gotchas

The command always exits 0, including on lock refusal; the refusal is a loud banner that tells you to stay read-only.

A second launch against a home another live session already holds will not steal the lock.

`MISSING:` toolchain lines and `TANGLE:` on a feature-branch code root are diagnostics, not a failed scratch-home launch.

The deferred network stage may still be in progress when the digest prints; wait with `FM_HOME="$VERIFY_HOME" bin/fm-startup-network.sh report` if you need those checks.
