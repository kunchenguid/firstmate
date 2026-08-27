# Boot-time reconciliation digest (gate g-boot-digest)

## Problem

The SessionStart hook (`bin/fm-captain-bootstrap.sh`) injects the captain context block (projects, secondmates, tmux windows, backlog head), but the section-5 recovery signals are missing.
A captain session must run several live bash calls (wake drain, status reads, watcher checks) before it can safely act, which makes boot slow.

## Contract

Append a `## Reconciliation digest (boot-time snapshot)` section to the captain context block (role == `captain` only) containing:

1. **Wake queue** — depth of `state/.wake-queue` (0 or absent reads "empty") plus up to the 5 most recent records verbatim.
   The read is lock-free: never touch `.wake-queue.lock` (contending with the live watcher from inside a 10s hook is worse than a stale read).
   Torn-tail rule (mechanical): a record line is valid iff it ends with a newline AND splits into >=5 tab-separated fields (epoch, seq, kind, key, payload); a failing final line is excluded from depth and display and the section carries the literal marker `(tail possibly torn)`.
2. **Watcher health** — the digest shells out to `bin/fm-watch-arm.sh --status` and relays its line verbatim; it never re-derives watcher liveness itself.
   `--status` reuses `healthy_watcher()` (lock pid alive + pid-identity match + beacon fresh within `FM_GUARD_GRACE`), prints exactly one stdout line, and always exits 0:
   - `watcher-status: healthy pid=<pid> beacon-age=<secs>s`
   - `watcher-status: stale pid=<pid|none> beacon-age=<secs|none>` (lock or beacon present but `healthy_watcher` fails)
   - `watcher-status: none` (no lock and no beacon)
   `--status` never arms, restarts, or kills anything and never creates, modifies, or deletes lock/beacon files (sourcing the shared libs may `mkdir -p` the state dir — pre-existing lib behavior, allowed).
3. **Session lock** — shells out to `bin/fm-lock.sh status` (the canonical liveness definition) and relays its line verbatim; lock semantics are never re-implemented and the lock is never acquired.
4. **In-flight tasks** — for each `state/*.meta`: id, `window=`, `kind=`, `mode=`, plus the last line of `state/<id>.status` (or `(no status yet)`).
5. **afk** — whether `state/.afk` exists.
6. **Snapshot disclaimer** — this exact string, always present:
   `Snapshot as of boot — run bin/fm-wake-drain.sh before acting on the fleet.`

## Constraints

- The digest is a snapshot, not reconciliation: the new code never drains the queue, touches suppression markers (`.seen-*`, `.stale-*`, `.last-*`), acquires locks, or archives anything.
  The existing rehydrate block's archive/consume behavior is deliberately unchanged.
- Fast: local file reads plus the two sanctioned cheap execs; no `ps` fan-outs in new Python code.
- Bounded: the digest is capped at ~2000 chars; the in-flight list and queue records truncate with an explicit `… (+N more)` marker, never silently.
- Degrades gracefully: missing state dir, unreadable files, missing helper scripts, or non-captain role never break the hook or emit errors.
- All existing behavior stays byte-compatible: rehydrate block, role logic, inject cap logic, existing captain block content.
- Helper resolution seam: helpers resolve through the bootstrap's own bin dir, overridable via `FM_BOOTSTRAP_BIN` (the test stub seam).

## Verification

`tests/fm-captain-bootstrap-digest.test.sh` (gate `g-boot-digest` in `gates/ledger.json`), covering the populated fixture with stubbed relays, torn tail, empty-state degradation, the ~2000-char overflow cap, the unchanged non-captain path, and the `--status` grammar plus side-effect-freedom against the real helper.
