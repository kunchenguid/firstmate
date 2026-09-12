#!/usr/bin/env bash
# Characterization tests for the durable wake queue drain entry point.
set -u

# shellcheck source=tests/wake-helpers.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
# shellcheck disable=SC2034 # consumed by make_case from wake-helpers.sh
TMP_ROOT=$(fm_test_tmproot fm-wake-drain)

test_drain_consumes_and_deduplicates_wakes() {
  local dir state out err count
  dir=$(make_case basic)
  state="$dir/state"
  out="$dir/drain.out"
  err="$dir/drain.err"
  append_wake "$state" signal task.status "signal: first" || fail "first wake append failed"
  append_wake "$state" signal task.status "signal: second" || fail "second wake append failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || fail "wake drain failed"
  count=$(awk 'NF { count++ } END { print count + 0 }' "$out")
  [ "$count" -eq 1 ] || fail "duplicate wake was not collapsed: $(cat "$out")"
  grep -F "signal: second" "$out" >/dev/null || fail "latest duplicate payload was not retained"
  [ -s "$state/.wake-queue" ] || fail "wake drain consumed rows before handling acknowledgement"
  ack_drain_err "$state" "$err" >/dev/null || fail "wake acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "wake queue was not emptied after acknowledgement"
  pass "drain presents the latest duplicate payload and consumes it after acknowledgement"
}

test_empty_drain_is_silent() {
  local dir state out
  dir=$(make_case empty)
  state="$dir/state"
  out="$dir/drain.out"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "empty wake drain failed"
  [ ! -s "$out" ] || fail "empty wake drain emitted unexpected output: $(cat "$out")"
  [ -f "$state/.wake-queue" ] || fail "empty drain did not materialize the wake queue"
  pass "empty drain succeeds silently"
}

test_acknowledgement_rearms_an_unheld_watcher_without_waiting() {
  local dir home state fakebin out err ackout ackerr ackpid watcher_pid rearmed
  dir=$(make_case ack-rearm-unheld)
  home="$dir/home"
  state="$home/state"
  fakebin="$dir/fakebin"
  out="$dir/drain.out"
  err="$dir/drain.err"
  ackout="$dir/ack.out"
  ackerr="$dir/ack.err"
  mkdir -p "$home/data"
  append_wake "$state" check fixture "check: fixture wake" || fail "fixture wake append failed"

  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" \
    || fail "wake drain failed before acknowledgement"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_POLL=1 \
    FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$DRAIN" --ack-through "$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")" \
    --recovery-generation "$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")" \
    > "$ackout" 2> "$ackerr" &
  ackpid=$!

  i=0
  while [ "$i" -lt 40 ]; do
    watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    is_live_non_zombie "$watcher_pid" && break
    sleep 0.1
    i=$((i + 1))
  done
  is_live_non_zombie "$watcher_pid" || {
    wait "$ackpid" 2>/dev/null || true
    fail "acknowledgement left no live watcher: $(cat "$ackout") $(cat "$ackerr")"
  }

  sleep 0.2
  ack_waited=false
  is_live_non_zombie "$ackpid" && ack_waited=true

  printf 'done: ends the detached watcher cycle\n' > "$state/after-ack.status"
  wait_for_exit "$ackpid" 120 >/dev/null || fail "acknowledgement did not finish after the watcher wake"
  i=0
  while [ "$i" -lt 40 ] && [ ! -e "$state/.watch-cycle-exits.log" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ "$ack_waited" = false ] || fail "acknowledgement waited for its re-armed watcher instead of returning"
  rearmed=$(rg -c -F -- 'origin=ack-rearm' "$state/.watch-cycle-exits.log")
  [ "$rearmed" -eq 1 ] || fail "acknowledgement re-arm ledger count was $rearmed, expected one"
  pass "wake drain: acknowledgement returns after starting one unheld watcher"
}

test_acknowledgement_does_not_rearm_a_live_watcher() {
  local dir home state out err watcher_pid holder identity
  dir=$(make_case ack-rearm-live)
  home="$dir/home"
  state="$home/state"
  out="$dir/drain.out"
  err="$dir/drain.err"
  mkdir -p "$home/data" "$state/.watch.lock"
  sleep 30 &
  holder=$!
  identity=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$holder") \
    || { kill "$holder" 2>/dev/null || true; fail "could not identify live watcher fixture"; }
  printf '%s\n' "$holder" > "$state/.watch.lock/pid"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  printf '%s\n' "$home" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$state/.watch.lock/watcher-path"
  : > "$state/.last-watcher-beat"
  append_wake "$state" check fixture "check: fixture wake" || fail "fixture wake append failed"

  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" \
    || fail "wake drain failed before live-watcher acknowledgement"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" \
    --ack-through "$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")" \
    --recovery-generation "$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")" \
    || fail "acknowledgement failed with a live watcher"
  [ ! -e "$state/.watch-cycle-exits.log" ] \
    || fail "acknowledgement started a watcher despite the live cycle"
  is_live_non_zombie "$holder" || fail "live watcher fixture was disturbed by acknowledgement"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "wake drain: acknowledgement does not re-arm while a watcher is live"
}

test_drain_consumes_and_deduplicates_wakes
test_empty_drain_is_silent
test_acknowledgement_rearms_an_unheld_watcher_without_waiting
test_acknowledgement_does_not_rearm_a_live_watcher
