#!/usr/bin/env bash
# tests/fm-watch-arm.test.sh - the arm layer's cycle-close contract when the arm
# did not own the cycle.
#
# The watcher prints its one reason line to its OWN stdout, so only the arm that
# forked it ever reads that line. An arm that ATTACHED to an existing cycle holds
# no handle on it and can observe only a released lock, which is why a completely
# successful cycle used to be reported as
# "watcher: FAILED - cycle ended without an actionable reason" on every harness
# whose protocol reads that line. These are real-process tests: a real
# bin/fm-watch.sh holds the singleton, a real bin/fm-watch-arm.sh attaches to it,
# and a real status change drives a real wake through the watcher-bound delivery
# record and durable queue.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-arm-tests)

# Both starters background a real process the test later waits on, so they set a
# global instead of echoing: a command substitution would make the pid a child of
# a subshell this shell can no longer wait for.
SEED_PID=
ARM_PID=

# Start the real watcher as the singleton holder.
start_seed_watcher() {  # <state> <fakebin> <watch-out>
  local state=$1 fakebin=$2 out=$3 i
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  SEED_PID=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$SEED_PID" ] \
      && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$SEED_PID" ] \
    || fail "seed watcher did not take the lock"
}

# Attach a real arm to the live cycle.
start_attached_arm() {  # <state> <fakebin> <arm-out> <confirm-timeout>
  local state=$1 fakebin=$2 armout=$3 confirm=$4 i
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 \
    FM_ARM_CONFIRM_TIMEOUT="$confirm" "$WATCH_ARM" > "$armout" &
  ARM_PID=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$SEED_PID" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$SEED_PID" "$armout" \
    || fail "arm did not attach to the live watcher: $(cat "$armout")"
}

test_attached_arm_reports_the_delivered_wake() {
  local dir state fakebin out armout status
  dir=$(make_case attached-delivered-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_watcher "$state" "$fakebin" "$out"
  start_attached_arm "$state" "$fakebin" "$armout" 1

  # A real captain-relevant status change: the watcher records it in the durable
  # queue, prints its one reason line to its own stdout, and exits.
  printf 'done: fixture finished\n' > "$state/demo.status"
  wait_for_exit "$SEED_PID" 120
  grep -q '^signal:' "$out" || fail "seed watcher did not surface the signal wake: $(cat "$out")"

  wait_for_exit "$ARM_PID" 120
  status=$?
  grep -q 'demo.status' "$state/.wake-queue" \
    || fail "the wake was not durably recorded, so this case proves nothing"
  ! grep -qF 'watcher: FAILED' "$armout" \
    || fail "attached arm reported a delivered wake as a failed cycle: $(cat "$armout")"
  grep -q '^signal:' "$armout" \
    || fail "attached arm did not report the durably recorded wake reason: $(cat "$armout")"
  expect_code 0 "$status" "an attached arm whose cycle delivered a wake must close successfully"
  grep -q 'reason=attached-delivered-wake' "$state/.watch-cycle-exits.log" \
    || fail "the delivered-wake close was not classified in the lifecycle ledger"
  pass "watch-arm: an attached arm reports the wake its cycle delivered instead of a false failure"
}

test_attached_arm_reports_the_delivered_wake_after_drain() {
  local dir state fakebin out armout status
  dir=$(make_case attached-drained-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_watcher "$state" "$fakebin" "$out"
  # A wider confirmation budget keeps the arm in its successor wait while the
  # handling turn drains, which is the ordering this case exists to cover.
  start_attached_arm "$state" "$fakebin" "$armout" 5

  printf 'done: fixture finished\n' > "$state/demo.status"
  wait_for_exit "$SEED_PID" 120
  # The handling turn consumes the records before the attached arm closes: the
  # queue is empty again, while the watcher's identity-bound terminal record
  # still proves which cycle delivered the reason.
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "drain failed"
  [ ! -s "$state/.wake-queue" ] || fail "drain left records behind"

  wait_for_exit "$ARM_PID" 200
  status=$?
  ! grep -qF 'watcher: FAILED' "$armout" \
    || fail "attached arm reported an already-handled wake as a failed cycle: $(cat "$armout")"
  grep -q '^signal:' "$armout" \
    || fail "attached arm did not report the delivered reason after the queue drain: $(cat "$armout")"
  expect_code 0 "$status" "an attached arm whose wake was already drained must close successfully"
  pass "watch-arm: a delivered wake consumed by the handling turn still closes the attached arm cleanly"
}

test_attached_arm_still_fails_on_a_wake_it_did_not_deliver() {
  local dir state fakebin out armout status
  dir=$(make_case attached-no-delivery)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_watcher "$state" "$fakebin" "$out"
  start_attached_arm "$state" "$fakebin" "$armout" 1

  # A process-event producer advances the same home-wide queue while the
  # observed watcher remains uninvolved, so only watcher-bound evidence can
  # distinguish this from a delivered watcher cycle.
  append_wake "$state" check process-event "check: process-event result captured: fixture"
  kill "$SEED_PID" 2>/dev/null || true
  wait "$SEED_PID" 2>/dev/null || true
  wait_for_exit "$ARM_PID" 120
  status=$?
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" \
    || fail "a cycle that delivered nothing must still fail loudly: $(cat "$armout")"
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] \
    || fail "arm did not exit nonzero for a cycle that delivered nothing (status $status)"
  pass "watch-arm: a cycle that delivered no wake of its own still fails loudly"
}

# A second arm's own forked watcher child can lose the PID-check migration's
# pre-lock ownership check to a real sibling watcher that already holds the
# singleton, and exit nonzero before ever printing a wake of its own. Before
# this fix that nonzero close skipped straight to FAILED without ever
# checking whether a live sibling already held (or was about to hold) the
# singleton - the exact false alarm this suite exists to catch, just reached
# through a startup race instead of a clean attach.
test_arm_reports_sibling_delivered_wake_after_losing_a_startup_race() {
  local dir state fakebin out armout status fm_home_file real_home co i
  dir=$(make_case migration-race)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_watcher "$state" "$fakebin" "$out"

  # Unsettle the sibling's recorded home so fm_watcher_lock_matches_pid fails
  # for both this arm's own top-level health check (forcing it down the fork
  # path instead of a clean attach) and its forked child's PR-check migration
  # guard (bin/fm-pr-check-migrate.sh), which runs that same identity check
  # against the live lock before a fresh watcher may acquire it. The sibling
  # itself only re-checks the bare pid file for self-eviction, so it keeps
  # running unaffected while its recorded home is unsettled.
  fm_home_file="$state/.watch.lock/fm-home"
  real_home=$(cat "$fm_home_file")
  printf 'not-a-real-home\n' > "$fm_home_file"
  # The seed's own startup already completed PR-check migration and left a
  # valid marker, which would otherwise let the arm's forked child skip
  # straight past the ownership check this case targets.
  rm -f "$state/.pr-check-migration-v1" "$state/.pr-check-migration-scan-v1"

  # The migration guard's ambiguity message is the child watcher's own stderr,
  # inherited straight through from this arm rather than captured on its
  # tracked stdout (bin/fm-watch-arm.sh only redirects the child's stdout), so
  # give the arm its own stderr file to poll as the race-lost signal.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 \
    FM_ARM_CONFIRM_TIMEOUT=3 "$WATCH_ARM" > "$armout" 2> "$armout.err" &
  ARM_PID=$!

  # Wait for the arm's own child to actually lose the race before restoring
  # the sibling's real home, so this proves the exact failure path instead of
  # a no-op that never exercised it.
  co=
  i=0
  while [ "$i" -lt 100 ]; do
    grep -q 'PR_CHECK_MIGRATION: watcher ownership is ambiguous' "$armout.err" 2>/dev/null && { co=1; break; }
    sleep 0.05
    i=$((i + 1))
  done
  [ -n "$co" ] || fail "arm's own child never lost the migration race; this case proves nothing"
  printf '%s\n' "$real_home" > "$fm_home_file"

  printf 'done: fixture finished\n' > "$state/demo.status"
  wait_for_exit "$SEED_PID" 120
  grep -q '^signal:' "$out" || fail "seed watcher did not surface the signal wake: $(cat "$out")"

  wait_for_exit "$ARM_PID" 120
  status=$?
  ! grep -qF 'watcher: FAILED' "$armout" \
    || fail "arm reported a live sibling's delivered wake as a failed cycle after losing a startup race: $(cat "$armout")"
  grep -q '^signal:' "$armout" \
    || fail "arm did not report the sibling's delivered wake reason: $(cat "$armout")"
  expect_code 0 "$status" "an arm that loses a startup race to a live sibling must still close successfully once that sibling delivers"
  grep -q 'reason=nonzero-exit' "$state/.watch-cycle-exits.log" \
    || fail "the lost-race close was not classified in the lifecycle ledger"
  pass "watch-arm: an arm whose own child loses a startup race to a live sibling reports that sibling's delivered wake instead of a false failure"
}

test_attached_arm_reports_the_delivered_wake
test_attached_arm_reports_the_delivered_wake_after_drain
test_attached_arm_still_fails_on_a_wake_it_did_not_deliver
test_arm_reports_sibling_delivered_wake_after_losing_a_startup_race
