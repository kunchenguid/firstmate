#!/usr/bin/env bash
# Pin the bound on an unacknowledged recovery resurface: a wake nobody
# acknowledges must not re-fire `check: rearm-resurface` on every turn end
# (2026-09-29: one denied drain produced ~700 turns in 45 minutes).
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-resurface-backoff)

# Re-arm the downtime marker the way a fresh watcher finds it after an
# unhandled wake, then start one watcher over it.
resurface_watch_bg() {  # <dir> <out> <backoff-base>
  local dir=$1 out=$2 base=$3
  printf 'pending:downtime:loop.1.aaa\n' > "$dir/state/.watcher-down"
  chmod 600 "$dir/state/.watcher-down"
  : > "$out"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" \
    FM_RESURFACE_STREAK_CAP=3 FM_RESURFACE_BACKOFF_BASE="$base" \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" 2>&1 &
}

assert_keeps_supervising() {  # <pid> <out> <what>
  local pid=$1 out=$2 what=$3
  sleep 3
  is_live_non_zombie "$pid" \
    || { wait "$pid" 2>/dev/null || true; fail "$what: the watcher closed on another resurface instead of supervising: $(cat "$out")"; }
  ! grep -F 'rearm-resurface' "$out" >/dev/null \
    || { kill -TERM "$pid" 2>/dev/null || true; fail "$what: a withheld resurface was still delivered: $(cat "$out")"; }
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

test_unacknowledged_resurface_is_capped() {
  local dir state out pid i sequence generation
  dir=$(make_case resurface-cap); state="$dir/state"
  out="$dir/watch.out"
  append_wake "$state" check seed "check: seed recovery"

  resurface_watch_bg "$dir" "$out" 0
  pid=$!
  wait_for_exit "$pid" 100 || fail "the first cycle did not close on a wake: $(cat "$out")"
  grep -Fx 'check: rearm-resurface' "$out" >/dev/null \
    || fail "the first cycle did not resurface the unacknowledged wake: $(cat "$out")"

  # A second delivery this soon is exactly the loop: it must wait out the
  # growing backoff rather than re-firing on the next turn end.
  resurface_watch_bg "$dir" "$out" 600
  assert_keeps_supervising $! "$out" "backoff"

  for i in 2 3; do
    resurface_watch_bg "$dir" "$out" 0
    pid=$!
    wait_for_exit "$pid" 100 || fail "cycle $i did not close on a wake: $(cat "$out")"
  done
  grep -F 'check: rearm-resurface unacknowledged 3 times' "$out" >/dev/null \
    || fail "the last automatic re-delivery carried no captain-actionable escalation: $(cat "$out")"

  resurface_watch_bg "$dir" "$out" 0
  assert_keeps_supervising $! "$out" "past the cap"
  [ "$(grep -c 'resurface suppressed' "$state/.watch-triage.log" 2>/dev/null)" = 1 ] \
    || fail "the suppression was not logged exactly once per episode: $(cat "$state/.watch-triage.log" 2>/dev/null)"

  # Newly appended work is not the same unanswered wake, so the bound must
  # never silence it: the streak restarts and the next cycle resurfaces at once.
  append_wake "$state" check fresh "check: freshly appended work"
  resurface_watch_bg "$dir" "$out" 600
  pid=$!
  wait_for_exit "$pid" 100 || fail "work appended past the cap was stranded: $(cat "$out")"
  grep -Fx 'check: rearm-resurface' "$out" >/dev/null \
    || fail "work appended past the cap did not restart the streak: $(cat "$out")"

  # Acknowledging a wake clears the streak, so a later recovery resurfaces.
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err" \
    || fail "the drain that clears the loop failed: $(cat "$dir/drain.err")"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/drain.err" | tail -1)
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/drain.err" | tail -1)
  [ -n "$sequence" ] && [ -n "$generation" ] \
    || fail "the drain printed no acknowledgement boundary: $(cat "$dir/drain.err")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" >/dev/null 2>&1 \
    || fail "the acknowledgement that must reset the streak failed"
  [ ! -e "$state/.resurface-streak" ] || fail "the acknowledgement did not reset the resurface streak"

  append_wake "$state" check seed2 "check: second recovery"
  resurface_watch_bg "$dir" "$out" 0
  pid=$!
  wait_for_exit "$pid" 100 || fail "the post-acknowledgement cycle did not close on a wake: $(cat "$out")"
  grep -Fx 'check: rearm-resurface' "$out" >/dev/null \
    || fail "an acknowledged home did not resurface a fresh recovery: $(cat "$out")"

  pass "an unacknowledged resurface backs off, escalates once, and stops re-firing until a wake is acknowledged"
}

test_unacknowledged_resurface_is_capped
