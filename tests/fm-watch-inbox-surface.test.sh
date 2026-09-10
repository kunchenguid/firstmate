#!/usr/bin/env bash
# Focused regression: a queued captain-inbox note wake (check key inbox:<id>)
# closes one watcher cycle for an idle main with the note's own reason, leaves
# exactly one surfaced marker, and never re-closes a later cycle while the row
# stays unhandled. Uses the documented wake-helpers owners and one bounded
# watcher subprocess in an isolated test home; never touches a real home.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-inbox-surface-tests)

dir=$(make_case inbox-note-surface)
state="$dir/state"
append_wake "$state" check "inbox:test-note-1" \
  "check: captain inbox note test-note-1 - Discord workspace / text request: discord:1:2:3"

out="$dir/watch.out"
PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_HOME="$dir" \
  FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$WATCH" > "$out" 2>&1 &
pid=$!

# Bounded exit wait: the first cycle must end with the inbox reason.
i=0
while [ "$i" -lt 100 ]; do
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.1
  i=$((i + 1))
done
if kill -0 "$pid" 2>/dev/null; then
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  fail "the watcher did not surface the queued inbox note within the bound: $(cat "$out")"
fi
wait "$pid" 2>/dev/null
grep -q "captain inbox note test-note-1" "$out" \
  || fail "the surfaced reason lost the note summary: $(cat "$out")"
ls "$state"/.seen-inbox-* >/dev/null 2>&1 \
  || fail "the surfaced inbox wake left no surfaced marker"
pass "a queued inbox-note wake closes the watcher cycle with the note reason and one marker"

# Second cycle: the surfaced row must not re-close a later cycle.
out2="$dir/watch2.out"
PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_HOME="$dir" \
  FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$WATCH" > "$out2" 2>&1 &
pid2=$!
i=0
alive=1
while [ "$i" -lt 40 ]; do
  kill -0 "$pid2" 2>/dev/null || { alive=0; break; }
  sleep 0.1
  i=$((i + 1))
done
if [ "$alive" = 0 ]; then
  wait "$pid2" 2>/dev/null
  grep -q "captain inbox note test-note-1" "$out2" \
    && fail "a surfaced inbox wake re-closed a later cycle: $(cat "$out2")"
  pass "a surfaced inbox row does not re-close later watcher cycles"
else
  kill "$pid2" 2>/dev/null
  wait "$pid2" 2>/dev/null
  grep -q "captain inbox note test-note-1" "$out2" \
    && fail "a surfaced inbox wake re-closed a later cycle"
  pass "a surfaced inbox row does not re-close later watcher cycles"
fi
