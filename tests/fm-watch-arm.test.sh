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
if [ "${FM_WATCH_ARM_TEST_ANCESTRY_NOISE:-0}" != 1 ]; then
  FM_WATCH_ARM_TEST_ANCESTRY_NOISE=1 exec bash "$0" fm-watch-arm.sh
fi
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

# Start the real watcher as the singleton holder. The test shell's trailing
# fm-watch-arm.sh argument pins the public ancestry classifier: a prompt,
# wrapper, or controller that merely names the arm script is not its owner.
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

test_redundant_arm_exits_when_live_owner_arm_waits() {
  local dir state fakebin owner_out rearm_out owner_pid rearm_pid watcher_pid status i
  dir=$(make_case redundant-owner-arm)
  state="$dir/state"
  fakebin="$dir/fakebin"
  owner_out="$dir/owner-arm.out"
  rearm_out="$dir/rearm.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$owner_out" &
  owner_pid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$owner_out" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$owner_out" || fail "owner arm did not start a watcher: $(cat "$owner_out")"
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  is_live_non_zombie "$owner_pid" || fail "owner arm did not remain live with its watcher"

  # A redundant call observes no cycle, so it must not link a supplied prior
  # arm record as though it had become the watcher's successor.
  printf 'arm_pid=4242\twatcher_pid=none\torigin=started\tstarted_at=0\tended_at=0\texit_code=0\tsignal=none\treason=actionable-check\tbeacon_age=0\tlock_before=none\tlock_after=none\tsuccessor=none\n' \
    > "$state/.watch-cycle-exits.log"
  # A second public arm call must acknowledge the healthy cycle without becoming
  # another long-lived waiter, while leaving the original owner and watcher alone.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 \
    FM_ARM_CONFIRM_TIMEOUT=1 FM_WATCH_PREDECESSOR_ARM_PID=4242 "$WATCH_ARM" > "$rearm_out" &
  rearm_pid=$!
  wait_for_exit "$rearm_pid" 80
  status=$?
  expect_code 0 "$status" "redundant arm must exit successfully"
  grep -qF "watcher: attached pid=$watcher_pid" "$rearm_out" \
    || fail "redundant arm did not report the healthy watcher: $(cat "$rearm_out")"
  is_live_non_zombie "$owner_pid" || fail "redundant arm disturbed the live owner arm"
  is_live_non_zombie "$watcher_pid" || fail "redundant arm disturbed the live watcher"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$watcher_pid" ] \
    || fail "redundant arm changed the healthy watcher's lock"
  grep -qF 'arm_pid=4242' "$state/.watch-cycle-exits.log" \
    || fail "redundant arm rewrote the predecessor ledger row"
  grep -qF 'successor=none' "$state/.watch-cycle-exits.log" \
    || fail "redundant arm linked a predecessor without observing a cycle"
  kill "$owner_pid" 2>/dev/null || true
  wait "$owner_pid" 2>/dev/null || true
  pass "watch-arm: redundant arm exits after attached while the live owner waits"
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

test_redundant_arm_exits_when_live_owner_arm_waits
test_attached_arm_reports_the_delivered_wake
test_attached_arm_reports_the_delivered_wake_after_drain
test_attached_arm_still_fails_on_a_wake_it_did_not_deliver
