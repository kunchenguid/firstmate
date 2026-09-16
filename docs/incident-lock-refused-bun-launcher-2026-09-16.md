# Incident: lock-refused read-only loop after omp launcher shape change (2026-09-16)

## Summary

The primary firstmate session (omp pid 1436, herdr pane `w1F:p1`, started
2026-09-15 12:44) entered a self-sustaining read-only loop: every watcher wake
was answered with "still lock-refused read-only — wake stays durable" for
~10 hours (03:19Z–12:21Z), while wedge escalations climbed past 117.

Two independent causes stacked:

1. **Harness detection miss (the bug, fixed by d88f5bc0).** omp ≥ 18.1.22
   launches as `bun /Users/Morley/.bun/bin/omp` (a `#!/usr/bin/env bun` script)
   instead of a native `omp` binary. `bin/fm-session-lock-lib.sh`'s ancestry
   matcher only recognized the old argv shape, so session-start's ancestry walk
   from the harness found no known harness pid. Result: the session never
   recorded itself as the lock owner and its supervision block rendered
   read-only ("Lock: read-only; do not drain, arm, spawn, steer, merge, or
   repair fleet state here" — `fm-supervision-instructions.sh:223`).
2. **Stale verdict (the persistence).** The fix was cherry-picked at
   2026-09-16 03:47Z, but the running session had already started with the
   broken matcher. Its read-only verdict lived in conversation context, not in
   any live lock check — nothing re-evaluated it. Meanwhile the session
   *actually owned* `state/.lock` (pid 1436) the whole time.

## Why wakes kept flowing to a "refusing" session

The omp extension (`fm-primary-omp-watch.ts`) `lockOwnership()` is a pure
PID-ancestry check running in-process at pid 1436, with the lock file holding
1436 — verdict "owned". So the watcher chain (arm → fm-watch.sh, children of
1436) kept delivering wakes. The session's refusal came only from the stale
read-only instructions, producing the loop:

- watcher detects actionable/stale wake → delivers to session
- session (read-only context) refuses, keeps wake durable
- `home-summary.json` went invalid (`terminal_in_flight`:
  composer-clobber-12 queue row present, child state `done`) because the
  read-only session is exactly the session that must drain that row
- stale detector re-escalates every ~4 min (`.stale-since-term_4f42519c…`,
  escalation counter → 117)

## Diagnosis path (for future reference)

1. `state/.lock` pid alive? → yes, 1436, `bun …/omp` under herdr server.
2. Which pane/session owns it? → `herdr pane list` + `herdr pane process-info
   --pane <id>` maps pid → pane (`w1F:p1`) → omp session jsonl under
   `~/.omp/agent/sessions/-firstmate/`.
3. Watcher healthy? → `state/.watch-cycle-exits.log` shows clean
   `actionable-stale` exits with successors; `.watch.lock.owner.*` fresh.
   Wakes ARE delivered — refusal is on the session side.
4. Where does "read-only" come from? → grep the supervision block renderer
   (`bin/fm-supervision-instructions.sh`) and the omp extension
   (`fm-primary-omp-watch.ts:866` — distinct mechanisms; the extension's
   check was correct).
5. Timeline correlation: session start (Sep 15 12:44, before fix) vs cherry-pick
   (`git log`/`reflog --date=local`: d88f5bc0 committed 03:47Z Sep 16) → the
   verdict predates the fix; `fm-lock.sh status` post-fix correctly reports
   the harness holding the lock.

## Resolution

The re-emit path is the designed mechanism for a live session whose context is
stale: `bin/fm-sessionstart-run.sh --source clear` re-runs
`fm-session-start.sh --reemit` **only when** `state/.session-start-complete`
equals the pid in `state/.lock` (both were 1436). Critically, it must run as a
child of the session's own harness (e.g. via its bash tool) so the fixed
ancestry matcher sees the `bun …/omp` launcher shape.

Executed by steering the idle session through herdr:

```
herdr pane run w1F:p1 "<instructions: re-run sessionstart-run.sh --source clear
via your bash tool, then drain and retire the composer-clobber-12 row>"
```

Verified in the session jsonl:
- 12:21:56 re-emit renders full-helm: "Lock: held by this session; this
  session owns normal supervision"
- 12:22:53 "Lock acquired — this session owns the helm now"
- 12:23–12:24 wake-drain acknowledgement path running
  (inactive-outcome fingerprints, presented records)
- escalation counter frozen at 117, no further increments

## Lessons

- A session's read-only verdict is frozen context. Fixing the detection code
  does not un-refuse an already-running session; it must re-emit
  (`fm-sessionstart-run.sh --source clear|compact`) from inside its own
  harness, or be restarted.
- omp launcher shape is part of the harness contract: any launcher change
  (native binary ↔ bun script) must be matched in
  `fm-session-lock-lib.sh`'s ancestry matcher (`fm_omp_args_are_omp`).
- Read-only + "wake stays durable" + climbing wedge escalations with a live,
  lock-owning harness pid is the signature of this failure class. Check
  `fm-lock.sh status` first: if it reports the live harness holding the lock
  while the session claims read-only, the verdict is stale.
- Steering a wedged firstmate session via `herdr pane run` is effective and
  non-destructive: the session executes recovery with its own authority.
