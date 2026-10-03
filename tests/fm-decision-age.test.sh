#!/usr/bin/env bash
# Behavioral coverage for aged keyed decisions in the ordinary and secondmate watcher homes.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-age-tests)

watch_bg() { # <state> <fakebin> <out> [home]
  local state=$1 fakebin=$2 out=$3 home=${4:-}
  PATH="$fakebin:$PATH" FM_HOME="${home:-$ROOT}" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    FM_DECISION_AGE_SECS=2 "$WATCH" > "$out" &
}

ack_wake() { # <state>
  local state=$1 err="$1/ack.err" seq generation
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$seq" --recovery-generation "$generation"
}

test_rewake_dedup_and_resolution() {
  local dir state fakebin out pid now
  dir=$(make_case rewake); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  now=$(date +%s)
  printf 'needs-decision [key=publication] [at=%s]: approve publication\n' "$((now - 20))" > "$state/docs.status"
  printf 'kind=ship\n' > "$state/docs.meta"
  prime_status_seen "$state" "$state/docs.status"
  watch_bg "$state" "$fakebin" "$out"; pid=$!
  wait_for_exit "$pid" 100 || fail "aged decision did not wake"
  grep -F 'decision unanswered' "$out" | grep -F 'docs publication' >/dev/null \
    || fail "aged decision wake omitted task and key"
  [ "$(grep -c 'decision-age:' "$state/.wake-queue")" = 1 ] || fail "first age wake was duplicated"

  # An unacknowledged row may trigger the existing rearm-resurface wake, but it
  # must not generate another decision row for the same key and generation.
  sleep 2
  watch_bg "$state" "$fakebin" "$out"; pid=$!
  wait_for_exit "$pid" 100 || fail "queued wake was not resurfaced"
  [ "$(grep -c 'decision-age:' "$state/.wake-queue")" = 1 ] || fail "queued decision duplicated its row"

  ack_wake "$state" || fail "first age wake could not be acknowledged"
  watch_bg "$state" "$fakebin" "$out"; pid=$!
  wait_for_exit "$pid" 100 || fail "unanswered decision did not wake after backoff: out=$(cat "$out"); markers=$(cat "$state"/.decision-age-* 2>/dev/null); queue=$(cat "$state/.wake-queue" 2>/dev/null)"
  [ "$(grep -c 'decision-age:' "$state/.wake-queue")" = 1 ] || fail "second age wake was duplicated"
  ack_wake "$state" || fail "second age wake could not be acknowledged"
  printf 'resolved [key=publication] [at=%s]: approved\n' "$(date +%s)" >> "$state/docs.status"
  prime_status_seen "$state" "$state/docs.status"
  watch_bg "$state" "$fakebin" "$out"; pid=$!
  sleep 3
  kill -0 "$pid" 2>/dev/null || fail "resolved decision unexpectedly woke"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  printf 'spawn_gen=new-run\n' >> "$state/docs.meta"
  printf 'needs-decision [key=publication] [at=%s]: new run needs approval\n' "$(( $(date +%s) - 20 ))" >> "$state/docs.status"
  prime_status_seen "$state" "$state/docs.status"
  watch_bg "$state" "$fakebin" "$out"; pid=$!
  wait_for_exit "$pid" 100 || fail "new generation did not cause a wake"
  if grep -F 'check: rearm-resurface' "$out" >/dev/null; then
    ack_wake "$state" || fail "rearm resurface could not be acknowledged"
    watch_bg "$state" "$fakebin" "$out"; pid=$!
    wait_for_exit "$pid" 100 || fail "a new generation reused the old decision throttle"
  fi
  grep -F 'decision unanswered' "$out" | grep -F 'docs publication' >/dev/null \
    || fail "new generation did not receive its own wake: $(cat "$out")"
  pass "aged decisions re-wake with backoff, deduplicate, close, and reset for a new generation"
}

test_secondmate_child_uses_own_queue() {
  local dir mate state fakebin out pid now
  dir=$(make_case secondmate-age); mate="$dir/mate"; state="$mate/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  mkdir -p "$mate"/{state,data,config,projects}
  printf 'mate\n' > "$mate/.fm-secondmate-home"
  now=$(date +%s)
  printf 'needs-decision [key=child-question] [at=%s]: answer child\n' "$((now - 20))" > "$state/child.status"
  printf 'kind=ship\n' > "$state/child.meta"
  prime_status_seen "$state" "$state/child.status"
  watch_bg "$state" "$fakebin" "$out" "$mate"; pid=$!
  wait_for_exit "$pid" 100 || fail "secondmate child decision did not wake its own home"
  grep -F 'decision unanswered' "$state/.wake-queue" | grep -F 'child child-question' >/dev/null \
    || fail "secondmate child decision did not reach its own queue"
  [ ! -e "$dir/state/.wake-queue" ] || fail "secondmate child bypassed its own home"
  pass "a secondmate child decision wakes the secondmate home"
}

test_torn_down_status_does_not_wake() {
  local dir state fakebin out pid now
  dir=$(make_case torn-down); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  now=$(date +%s)
  printf 'needs-decision [key=old-question] [at=%s]: stale status\n' "$((now - 20))" > "$state/old.status"
  prime_status_seen "$state" "$state/old.status"
  watch_bg "$state" "$fakebin" "$out"; pid=$!
  sleep 3
  kill -0 "$pid" 2>/dev/null || fail "torn-down status unexpectedly woke the watcher"
  ! grep -F 'decision-age:' "$state/.wake-queue" >/dev/null 2>&1 \
    || fail "torn-down status entered the age queue"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "a torn-down task's stale decision does not flood the age queue"
}

test_rewake_dedup_and_resolution
test_secondmate_child_uses_own_queue
test_torn_down_status_does_not_wake
