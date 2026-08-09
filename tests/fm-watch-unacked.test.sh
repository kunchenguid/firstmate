#!/usr/bin/env bash
# tests/fm-watch-unacked.test.sh - the watcher must distinguish a cycle that
# reconnects on a signal nobody has read from one that lands on a fresh signal.
#
# These are the three acceptance tests specified by issue 2028:
#   1. a second cycle on the same signal set is classified as actionable-signal-unacked
#   2. N consecutive unacked exits raise a supervision alarm naming the unread task ids
#   3. an arm with a drained queue holds its lock beyond one cycle
#
# Every assertion runs through the executable interface (real processes, real
# state files, real banner output) and never inspects script source.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
GUARD="$ROOT/bin/fm-guard.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-unacked-tests)

mark_pr_check_migration_complete() {
  local state=$1
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$state/.pr-check-migration-v1"
  chmod 0600 "$state/.pr-check-migration-scan-v1" "$state/.pr-check-migration-v1"
}

# Run one full arm cycle. The arm forks the watcher, blocks until the watcher
# exits with a wake, records the cycle in the ledger, and exits. The test
# signals the watcher by writing the status file BEFORE the arm starts; the
# watcher's first scan picks it up. The arm's stdout/stderr is captured in
# <armout>. The function returns once the arm has exited.
run_arm_cycle() {  # <state> <fakebin> <armout>
  local state=$1 fakebin=$2 armout=$3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=10 \
    FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$armout" 2>&1
}

# --- Test 1: a second cycle on the same signal set is recorded as unacked ---

test_second_cycle_on_same_signal_set_is_unacked() {
  local dir state fakebin armout1 armout2 initial_count unacked_count
  dir=$(make_case unacked-second-cycle)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout1="$dir/arm1.out"
  armout2="$dir/arm2.out"
  mark_pr_check_migration_complete "$state"

  # Cycle 1: a fresh status file. The arm forks a watcher, the watcher queues
  # the signal, the arm records reason=actionable-signal, and the cursor
  # records the key.
  printf 'done: fixture finished\n' > "$state/task1.status"
  run_arm_cycle "$state" "$fakebin" "$armout1"
  grep -q 'reason=actionable-signal' "$state/.watch-cycle-exits.log" \
    || fail "cycle 1 close was not classified as actionable-signal: $(cat "$state/.watch-cycle-exits.log")"
  ! grep -q 'reason=actionable-signal-unacked' "$state/.watch-cycle-exits.log" \
    || fail "cycle 1 prematurely classified as unacked"
  grep -q 'task1.status' "$state/.wake-queue" \
    || fail "cycle 1 did not durably queue the signal"
  grep -q 'task1.status' "$state/.wake-acked-cursor" \
    || fail "cycle 1 did not add the key to the acknowledgement cursor"

  # Cycle 2: leave the queue untouched and append a new status line so the file
  # signature changes. The watcher will queue the same basename again because the
  # file changed since the last seen-* update. The cursor still holds the key
  # from cycle 1, so the arm must record this as actionable-signal-unacked.
  printf 'done: fixture still finished\n' >> "$state/task1.status"
  run_arm_cycle "$state" "$fakebin" "$armout2"
  grep -q 'reason=actionable-signal-unacked' "$state/.watch-cycle-exits.log" \
    || fail "cycle 2 close was not classified as actionable-signal-unacked: $(cat "$state/.watch-cycle-exits.log")"
  initial_count=$(grep -c 'reason=actionable-signal' "$state/.watch-cycle-exits.log" || true)
  unacked_count=$(grep -c 'reason=actionable-signal-unacked' "$state/.watch-cycle-exits.log" || true)
  [ "$initial_count" -ge 1 ] || fail "expected the first cycle to keep its actionable-signal classification"
  [ "$unacked_count" -ge 1 ] || fail "expected the second cycle to be classified as actionable-signal-unacked"
  pass "a second cycle on the same signal set is recorded as actionable-signal-unacked"
}

# --- Test 2: N consecutive unacked exits raise the supervision alarm ---

test_n_consecutive_unacked_exits_raise_alarm() {
  local dir state fakebin armout i streak guard_err
  dir=$(make_case unacked-alarm)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  guard_err="$dir/guard.err"
  mark_pr_check_migration_complete "$state"
  export FM_WATCH_UNACKED_THRESHOLD=3
  printf 'project=unacked-alarm\n' > "$state/task1.meta"

  printf 'done: stale fixture\n' > "$state/task1.status"
  printf '%s\n' task1.status > "$state/.wake-acked-cursor"

  for i in 1 2 3 4; do
    printf '%s\n' "done: stale fixture iteration $i" >> "$state/task1.status"
    run_arm_cycle "$state" "$fakebin" "$armout"
    grep -q 'reason=actionable-signal-unacked' "$state/.watch-cycle-exits.log" \
      || fail "iteration $i was not recorded as unacked: $(cat "$state/.watch-cycle-exits.log")"
  done

  streak=$(cat "$state/.wake-unacked-streak" 2>/dev/null || echo 0)
  [ "$streak" -ge 3 ] || fail "unacked streak was not at least 3 after four unacked cycles (got $streak)"
  [ -s "$state/.guard-watcher-unacked-banner" ] \
    || fail "alarm episode marker was not written after crossing the threshold"
  grep -q 'task1.status' "$state/.guard-watcher-unacked-banner" \
    || fail "alarm marker did not name the unread task ids (got: $(cat "$state/.guard-watcher-unacked-banner"))"

  CLAUDECODE=1 PI_CODING_AGENT='' GROK_AGENT='' \
    FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 \
    "$GUARD" 2> "$guard_err" >/dev/null || fail "guard failed"
  grep -F 'WATCHER THRASHING ON UNREAD SIGNAL' "$guard_err" >/dev/null \
    || fail "guard did not print the unacked-exit alarm banner: $(cat "$guard_err")"
  grep -F 'task1.status' "$guard_err" >/dev/null \
    || fail "guard banner did not name the unread task ids: $(cat "$guard_err")"

  pass "N consecutive unacked exits raise the supervision alarm naming the unread task ids"
}

# --- Test 3: an arm with a drained queue holds its lock beyond one cycle ---

test_arm_with_drained_queue_holds_lock() {
  local dir state fakebin armout drainout armpid i lock_pid held
  dir=$(make_case drained-holds-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  drainout="$dir/drain.out"
  mark_pr_check_migration_complete "$state"

  # First cycle: a real signal lands via the arm, queue and cursor both populate.
  printf 'done: pre-drain fixture\n' > "$state/task1.status"
  run_arm_cycle "$state" "$fakebin" "$armout"
  grep -q 'task1.status' "$state/.wake-queue" || fail "seed cycle did not queue"
  grep -q 'task1.status' "$state/.wake-acked-cursor" || fail "seed cycle did not update cursor"

  # Drain the queue. The cursor must drop the consumed key - the next arm
  # should not see any pending signal keys.
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drainout" || fail "drain failed"
  [ ! -s "$state/.wake-queue" ] || fail "drain left records behind"
  ! grep -q '^task1.status$' "$state/.wake-acked-cursor" \
    || fail "drain did not drop the key from the acknowledgement cursor"

  # Now the queue is drained. A fresh arm should hold the lock (the watcher
  # sees no changed signal, sleeps in its main loop, and does not exit
  # immediately).
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=10 \
    FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$armout" 2>&1 &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$armout" \
    || fail "second arm did not report a started watcher: $(cat "$armout")"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$lock_pid" ] || fail "second arm did not acquire a fresh watch lock"
  is_live_non_zombie "$lock_pid" || fail "second arm's watcher is not alive (pid $lock_pid)"

  # Hold assertion: the watcher must outlive more than one POLL cycle and still
  # hold the lock. With FM_POLL=5, six seconds covers at least one full poll,
  # so any immediate re-detection (the bug from the issue) would have shown up
  # by then.
  held=1
  for i in 1 2 3 4 5 6; do
    sleep 1
    is_live_non_zombie "$lock_pid" || { held=0; break; }
  done
  [ "$held" -eq 1 ] || fail "watcher exited within 6 seconds of a drained queue (lock pid $lock_pid)"
  ! grep -q 'reason=actionable-signal-unacked' "$state/.watch-cycle-exits.log" \
    || fail "drained-queue cycle was unexpectedly classified as unacked"

  kill "$armpid" "$lock_pid" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  wait "$lock_pid" 2>/dev/null || true
  pass "an arm with a drained queue holds its lock beyond one cycle"
}

test_second_cycle_on_same_signal_set_is_unacked
test_n_consecutive_unacked_exits_raise_alarm
test_arm_with_drained_queue_holds_lock
