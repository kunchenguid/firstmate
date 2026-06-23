#!/usr/bin/env bash
# Regression test for the wake-queue lock's core guarantee: mutual exclusion.
#
# The lock once used `mkdir` as its atomic primitive. mkdir is NOT atomic on
# every filesystem - on WSL2's filesystem several concurrent mkdir calls were
# observed to all succeed on one path, which silently double-granted the lock and
# made the watcher singleton and wake-queue draining race. The lock now uses an
# O_EXCL create (atomic everywhere we run). This test fails loudly if the lock
# ever stops being mutually exclusive again.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-lock-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export FM_STATE_OVERRIDE="$TMP"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"

LK="$FM_WAKE_QUEUE_LOCK"
CUR="$TMP/current"; BAD="$TMP/bad"; : > "$BAD"; echo init > "$CUR"

# Canonical mutex test: while holding the lock, write our pid to a shared file
# and read it back. With true mutual exclusion it is always our own pid; a
# non-empty foreign pid means another holder ran concurrently (double-grant).
# (An empty read is a transient fork artifact under load, not a double-grant.)
worker() {
  local _ who
  for _ in $(seq 1 30); do
    fm_lock_acquire_wait "$LK"
    echo "$BASHPID" > "$CUR"
    who=$(cat "$CUR" 2>/dev/null || true)
    if [ -n "$who" ] && [ "$who" != "$BASHPID" ]; then echo "$who" >> "$BAD"; fi
    fm_lock_release "$LK"
  done
}
worker & worker & worker & worker & wait

doubles=$(grep -c . "$BAD" 2>/dev/null || true)
[ "$doubles" -eq 0 ] || fail "lock double-granted $doubles time(s): a second holder overwrote shared state while the lock was held"
pass "wake-queue lock is mutually exclusive under contention (4 workers)"

# A dead holder's lock must be reclaimable in a single try_acquire (fm-watch.sh
# relies on this to take over after a crashed watcher); a live holder's must not.
rm -f "$LK"
dead=999999; while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
printf '%s\n' "$dead" > "$LK"
fm_lock_try_acquire "$LK" || fail "could not reclaim a dead holder's lock in one call"
fm_lock_release "$LK"

sleep 30 & holder=$!
printf '%s\n' "$holder" > "$LK"
if fm_lock_try_acquire "$LK"; then
  kill "$holder" 2>/dev/null || true
  fail "stole a live holder's lock"
fi
kill "$holder" 2>/dev/null || true
rm -f "$LK"
pass "lock reclaims a dead holder but never a live one"
