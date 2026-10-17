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

# A re-arm does real work before and during its first poll: it steals the dead
# watcher's lock, publishes and announces the downtime marker, then surfaces the
# recovery wake. That is a long run of short-lived processes, which a contended
# host - a changed-suite run beside three other suites - can slow far more than
# this suite's mostly sleeping poll loops. One re-arm measured about 2s idle, 5-7s
# beside three concurrent copies, and past the arm's default 10s confirmation
# deadline when the case was held to 15% of one CPU. These cases assert recovery,
# not a deadline, so under the CONTRIBUTING.md fixture-budget rule the arm gets an
# explicit confirmation budget with headroom, and each wait on it is an
# iteration-counted ceiling that outlasts that budget. A passing case returns as
# soon as the arm reports or exits, and a watcher that never surfaces its
# recovery still fails once the ceiling is spent.
REARM_CONFIRM_SECONDS=30
# start_rearm_arm polls every 0.05s, so this outlasts the confirmation budget.
REARM_REPORT_POLLS=700
# wait_for_exit polls every 0.1s. The arm can spend its confirmation budget again
# waiting for a successor before it reports a failure, so this outlasts it too.
REARM_EXIT_POLLS=400

# Both starters background a real process the test later waits on, so they set a
# global instead of echoing: a command substitution would make the pid a child of
# a subshell this shell can no longer wait for.
SEED_PID=
ARM_PID=

# Start the real watcher as the singleton holder.
start_seed_watcher() {  # <state> <fakebin> <watch-out> [poll-seconds]
  local state=$1 fakebin=$2 out=$3 poll=${4:-5} i
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL="$poll" FM_SIGNAL_GRACE=1 \
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

sha256_file() {  # <path>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

write_remote_delta() {  # <result-path> <status-line>
  local result=$1 line=$2 payload empty payload_bytes payload_hash empty_hash
  payload="$result.payload"
  empty="$result.empty"
  printf '%s\n' "$line" > "$payload"
  : > "$empty"
  payload_bytes=$(LC_ALL=C wc -c < "$payload" | tr -d '[:space:]')
  payload_hash=$(sha256_file "$payload") || fail "could not hash remote delta payload"
  empty_hash=$(sha256_file "$empty") || fail "could not hash empty remote delta prefix"
  {
    printf 'schema=fm-remote-delta.v1\n'
    printf 'status=delta\n'
    printf 'path=state/parent-replies.status\n'
    printf 'from_offset=0\n'
    printf 'to_offset=%s\n' "$payload_bytes"
    printf 'from_prefix_sha256=%s\n' "$empty_hash"
    printf 'to_prefix_sha256=%s\n' "$payload_hash"
    printf 'payload_sha256=%s\n' "$payload_hash"
    printf 'payload_bytes=%s\n' "$payload_bytes"
    printf 'reason=fixture\n\n'
    cat "$payload"
  } > "$result"
  rm -f "$payload" "$empty"
}

status_signature() {  # <status-path>
  bash -c '
    . "$1"
    reported=$(status_observed_signature "$2") || exit 1
    size=$(_fm_status_file_size "$2") || exit 1
    ident=$(_fm_open_decisions_file_ident "$2") || exit 1
    printf "v2\t%s\t%s@%s" "$reported" "$size" "$ident"
  ' _ "$ROOT/bin/fm-classify-lib.sh" "$1"
}

wait_for_file_text() {  # <file> <fixed-text>
  local file=$1 expected=$2 i=0
  while [ "$i" -lt 100 ]; do
    grep -F "$expected" "$file" >/dev/null 2>&1 && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

ack_wakes() {  # <state>
  local state=$1 sequence generation err
  err="$state/.test-ack.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  if [ -z "$sequence" ] || [ -z "$generation" ]; then
    [ ! -s "$state/.wake-queue" ] || return 1
    case "$(cat "$state/.watcher-down" 2>/dev/null || true)" in pending:*|announced:*) return 1 ;; esac
    return 0
  fi
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

# Print "<sequence>\t<generation>" from the acknowledgement command a drain
# printed, so a case can replay that exact pair later.
drain_ack_pair() {  # <drain-stderr>
  local err=$1 sequence generation
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  printf '%s\t%s\n' "$sequence" "$generation"
}

start_rearm_arm() {  # <home> <state> <fakebin> <arm-out> [predecessor-arm-pid]
  local home=$1 state=$2 fakebin=$3 armout=$4 predecessor=${5:-} i
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_CONFIRM_TIMEOUT="$REARM_CONFIRM_SECONDS" \
    FM_WATCH_PREDECESSOR_ARM_PID="$predecessor" \
    "$WATCH_ARM" --restart > "$armout" &
  ARM_PID=$!
  # Wait for the arm to confirm its watcher or exit, within a ceiling that
  # outlasts its confirmation budget. A fixed short count let a slow start fall
  # through mid-confirmation, so the caller's next liveness check or exit wait
  # began from an unknown point in the cycle.
  i=0
  while [ "$i" -lt "$REARM_REPORT_POLLS" ]; do
    grep -q '^watcher: started ' "$armout" 2>/dev/null && return 0
    is_live_non_zombie "$ARM_PID" || return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 0
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
  ack_wakes "$state" || fail "handling acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledgement left records behind"

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

# A slow cycle is not an ended cycle. The holder is frozen past the grace plus
# the successor confirmation window, which is where an attached arm used to
# declare the cycle over and fail while the holder was alive and still held the
# lock; the owner's retry then hit that live holder's refusal (the auto-arm
# FAILED notice), or, if the holder beat again first, nothing followed it at all.
test_attached_arm_follows_a_slow_live_holder() {
  local dir state fakebin out armout status i arm_followed armout_frozen ledger_frozen
  dir=$(make_case attached-slow-holder)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_watcher "$state" "$fakebin" "$out" 1
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 \
    FM_ARM_CONFIRM_TIMEOUT=1 FM_GUARD_GRACE=4 FM_WATCHER_STALL_BOUND=600 "$WATCH_ARM" > "$armout" &
  ARM_PID=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$SEED_PID" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$SEED_PID" "$armout" \
    || fail "arm did not attach to the live watcher: $(cat "$armout")"

  kill -STOP "$SEED_PID"
  # Grace 4s plus the 1s confirmation window plus its rounding second is where
  # the old arm gave up; hold the holder well past that. Observe while frozen,
  # but resume before asserting so a failure never strands a stopped watcher.
  i=0
  while [ "$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_path_age "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$state/.last-watcher-beat")" -lt 10 ] \
    && [ "$i" -lt 300 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  arm_followed=0
  is_live_non_zombie "$ARM_PID" && arm_followed=1
  armout_frozen=$(cat "$armout")
  ledger_frozen=$(cat "$state/.watch-cycle-exits.log" 2>/dev/null || true)
  kill -CONT "$SEED_PID"
  [ "$arm_followed" = 1 ] || fail "attached arm ended while its holder was alive: $armout_frozen"
  assert_not_contains "$armout_frozen" 'watcher: FAILED' \
    "attached arm failed a live holder's slow cycle"
  assert_not_contains "$ledger_frozen" 'reason=attached-cycle-ended' \
    "attached arm closed a cycle that had not ended"

  # The holder resumes and delivers a wake: the arm that kept following it
  # reports that wake, so nothing is lost.
  printf 'needs-decision: which export format?\n' > "$state/demo.status"
  wait_for_exit "$SEED_PID" 150
  grep -q '^signal:' "$out" || fail "resumed holder did not surface the signal wake: $(cat "$out")"
  wait_for_exit "$ARM_PID" 150
  status=$?
  ! grep -qF 'watcher: FAILED' "$armout" \
    || fail "attached arm failed after its holder resumed: $(cat "$armout")"
  grep -q '^signal:' "$armout" \
    || fail "attached arm did not report the resumed holder's wake: $(cat "$armout")"
  expect_code 0 "$status" "an attached arm that followed a slow holder must close with its wake"
  pass "watch-arm: an attached arm keeps following a slow live holder and reports its wake"
}

# The stall bound is where following ends. A live holder whose beacon reaches it
# is what the watcher's own re-arm evicts, so the attached arm stops there with
# the typed stalled-holder line, and its owner's retry replaces the holder
# instead of being refused.
test_attached_arm_hands_a_stalled_holder_to_its_replacement() {
  local dir state fakebin armout rearmout holder identity status
  dir=$(make_case attached-stalled-holder)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  rearmout="$dir/rearm.out"
  # A live process the lock records under its real identity, which never beats:
  # the shape of a watcher wedged mid-cycle that still answers TERM.
  sleep 300 &
  holder=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$holder") \
    || fail "could not identify the fake holder"
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$holder" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  : > "$state/.last-watcher-beat"

  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 \
    FM_ARM_CONFIRM_TIMEOUT=1 FM_GUARD_GRACE=5 FM_WATCHER_STALL_BOUND=12 "$WATCH_ARM" > "$armout" &
  ARM_PID=$!
  wait_for_exit "$ARM_PID" 300
  status=$?
  grep -qF "watcher: attached pid=$holder" "$armout" \
    || fail "arm did not attach to the fresh holder: $(cat "$armout")"
  grep -E "^watcher: FAILED - attached watcher pid=$holder stalled \(beacon [0-9]+s at or past hard bound 12s\)\$" "$armout" >/dev/null \
    || fail "attached arm did not report the stalled holder: $(cat "$armout")"
  ! grep -qF 'cycle ended without an actionable reason' "$armout" \
    || fail "attached arm gave up on the live holder before the stall bound: $(cat "$armout")"
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] \
    || fail "stalled-holder close did not exit nonzero (status $status)"
  grep -q 'reason=attached-holder-stalled' "$state/.watch-cycle-exits.log" \
    || fail "the stalled-holder close was not classified in the lifecycle ledger"
  is_live_non_zombie "$holder" || fail "the attached arm signalled the holder it follows"

  # The owner's retry: a fresh arm reaches the watcher's eviction path, and the
  # replacement surfaces an ordinary wake instead of the refusal that used to
  # end in the auto-arm FAILED notice.
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_CONFIRM_TIMEOUT=10 FM_GUARD_GRACE=5 FM_WATCHER_STALL_BOUND=12 "$WATCH_ARM" > "$rearmout" 2>&1 &
  ARM_PID=$!
  wait_for_exit "$ARM_PID" 300
  status=$?
  grep -qF "watcher: replaced stalled pid $holder " "$rearmout" \
    || fail "the retry did not replace the stalled holder: $(cat "$rearmout")"
  ! grep -qF 'watcher: FAILED' "$rearmout" \
    || fail "the retry failed instead of replacing the stalled holder: $(cat "$rearmout")"
  grep -Eq '^(signal|stale|check):' "$rearmout" \
    || fail "the replacement surfaced no ordinary wake: $(cat "$rearmout")"
  expect_code 0 "$status" "the retry that replaced a stalled holder must close with an ordinary wake"
  wait_for_pid_gone "$holder" 50 || fail "the stalled holder survived its replacement"
  wait "$holder" 2>/dev/null || true
  pass "watch-arm: an attached arm hands a holder stalled past the bound to its owner's replacement"
}

test_rearm_resurfaces_durable_queue_and_remote_open_decision() {
  local dir home state fakebin result armout drainout status watcher_pid sequence generation decision_recovery_arm decision_successor
  dir=$(make_case rearm-resurface)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  result="$dir/remote.result"
  armout="$dir/arm.out"
  drainout="$dir/drain.out"
  mkdir -p "$home/data"

  # This is the real remote parent-reply ingest boundary. It writes the remote
  # secondmate's decision onto the parent status surface the shared fold owns.
  write_remote_delta "$result" \
    'needs-decision [key=remote-signoff]: remote secondmate is held for captain sign-off'
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-procevent-remote-reply.sh" ingest ios "$result" >/dev/null \
    || fail "remote parent-reply ingest failed"

  # Drain once before the outage to establish the incremental cursor and the
  # signal suppressor that a watcher had already observed. The decision remains
  # intentionally open across the watcher-down interval.
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/baseline-drain.out" \
    || fail "baseline drain failed"
  ack_wakes "$state" || fail "baseline handling acknowledgement failed"
  grep -F 'remote secondmate is held for captain sign-off' "$dir/baseline-drain.out" >/dev/null \
    || fail "baseline fold did not expose the remote decision"
  printf '%s' "$(status_signature "$state/ios.status")" > "$state/.seen-ios_status"

  # A real watcher is then interrupted before the next two durable updates.
  # This is the accepted blocking-tool shape: no watcher runs during the gap.
  start_rearm_arm "$home" "$state" "$fakebin" "$dir/down-arm.out"
  is_live_non_zombie "$ARM_PID" || fail "pre-outage watcher did not stay live"
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  kill -KILL "$watcher_pid" 2>/dev/null || fail "could not abruptly stop pre-outage watcher"
  wait "$ARM_PID" 2>/dev/null || true
  [ ! -e "$state/.watcher-down" ] || fail "abrupt watcher exit unexpectedly ran cleanup"

  # Two independent durable wakes arrive while no watcher exists. Neither gets
  # a later status change to rescue it, which is the down-window loss shape.
  append_wake "$state" check remote-reply-ios \
    'check: process-event result captured: remote-reply-ios:7'
  append_wake "$state" check startup-network 'check: startup-network'

  start_rearm_arm "$home" "$state" "$fakebin" "$armout"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS"
  status=$?
  [ "$status" -ne 124 ] \
    || fail "re-arm stayed live instead of surfacing durable wakes and the still-open remote decision"
  expect_code 0 "$status" "re-arm re-surface wake must close successfully"
  grep -F 'check: rearm-resurface' "$armout" >/dev/null \
    || fail "re-arm did not report the durable recovery wake: $(cat "$armout")"

  # The normal wake-handling drain is the one owner of both queue consumption
  # and the cursor-backed fold. It must expose every queued record and the
  # already-open remote decision without relying on another user message.
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drainout" \
    || fail "drain after re-arm recovery failed"
  grep "$(printf '\tcheck\tremote-reply-ios\t')" "$drainout" >/dev/null \
    || fail "remote-reply wake queued during downtime was not drained"
  grep "$(printf '\tcheck\tstartup-network\t')" "$drainout" >/dev/null \
    || fail "second durable wake queued during downtime was not drained"
  grep -F 'ios [key=remote-signoff] needs-decision: remote secondmate is held for captain sign-off' "$drainout" >/dev/null \
    || fail "remote parent-reply decision was not re-folded after watcher re-arm"
  ack_wakes "$state" || fail "recovery handling acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "re-arm recovery acknowledgement left durable wakes behind"

  # Persistent adapters establish a successor after the handling drain. Once
  # the durable wake is acknowledged, that successor must remain live instead
  # of replaying the completed recovery cycle.
  start_rearm_arm "$home" "$state" "$fakebin" "$dir/recovery-successor-arm.out"
  is_live_non_zombie "$ARM_PID" || fail "recovery successor did not stay live after the drain"

  # A later down interval can have no new queue rows at all. The unchanged
  # remote decision must still trigger a recovery wake and be folded again.
  kill "$ARM_PID" 2>/dev/null || true
  wait "$ARM_PID" 2>/dev/null || true
  start_rearm_arm "$home" "$state" "$fakebin" "$dir/decision-only-arm.out"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS" || fail "decision-only re-arm did not surface the open decision"
  decision_recovery_arm=$ARM_PID
  start_rearm_arm "$home" "$state" "$fakebin" "$dir/decision-handling-successor.out" "$decision_recovery_arm"
  is_live_non_zombie "$ARM_PID" || fail "decision handling successor re-triggered before the drain"
  decision_successor=$ARM_PID
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/decision-only-drain.out" \
    2> "$dir/decision-only-drain.err" || fail "decision-only drain after re-arm recovery failed"
  grep -F 'ios [key=remote-signoff] needs-decision: remote secondmate is held for captain sign-off' \
    "$dir/decision-only-drain.out" >/dev/null \
    || fail "unchanged remote decision was not re-folded after a later down interval"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/decision-only-drain.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/decision-only-drain.err")
  [ "$sequence" = 0 ] && [ -n "$generation" ] \
    || fail "decision-only recovery did not require generation-bound post-handling acknowledgement"
  is_live_non_zombie "$decision_successor" \
    || fail "decision-only drain spuriously re-triggered its live handling successor"
  ! grep -F 'check: rearm-resurface' "$dir/decision-handling-successor.out" >/dev/null \
    || fail "decision-only handling successor emitted recursive recovery"

  kill -TERM "$decision_successor" 2>/dev/null || fail "could not interrupt decision handling successor"
  wait "$decision_successor" 2>/dev/null || true
  start_rearm_arm "$home" "$state" "$fakebin" "$dir/interrupted-decision-arm.out"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS" || fail "interrupted decision handling was not recovered on successor re-arm"
  grep -F 'check: rearm-resurface' "$dir/interrupted-decision-arm.out" >/dev/null \
    || fail "successor did not re-surface the unacknowledged decision recovery"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/replayed-decision-drain.out" \
    2> "$dir/replayed-decision-drain.err" || fail "replayed decision recovery drain failed"
  grep -F 'ios [key=remote-signoff] needs-decision: remote secondmate is held for captain sign-off' \
    "$dir/replayed-decision-drain.out" >/dev/null \
    || fail "interrupted decision recovery did not re-fold the open decision"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/replayed-decision-drain.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/replayed-decision-drain.err")
  [ "$sequence" = 0 ] && [ -n "$generation" ] \
    || fail "replayed decision recovery omitted its current acknowledgement generation"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "completed decision handling could not acknowledge current recovery"
  start_rearm_arm "$home" "$state" "$fakebin" "$dir/decision-successor-arm.out"
  is_live_non_zombie "$ARM_PID" || fail "acknowledged decision recovery did not leave a live successor"
  kill "$ARM_PID" 2>/dev/null || true
  wait "$ARM_PID" 2>/dev/null || true
  pass "watch-arm: re-arm surfaces every queued wake and an open remote decision after downtime"
}

# A contended host starves the short-lived processes a recovery cycle runs while
# this suite's own poll loops, which mostly sleep, keep their pace, so a re-arm
# that is still surfacing its recovery can look like one that stayed live.
# Reproduce that on any host: once the re-armed watcher has published its
# liveness beacon, every mktemp and readlink it runs - the lock and marker steps
# of its first poll and its exit - is delayed, so the cycle outlasts the roughly
# 8s that a fixed 80-poll wait allows on an idle host.
test_slow_rearm_recovery_is_still_surfaced() {
  local dir home state fakebin armout first_arm watcher_pid tool real started status
  dir=$(make_case slow-rearm-recovery)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  mkdir -p "$home/data"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/first-arm.out"
  first_arm=$ARM_PID
  is_live_non_zombie "$first_arm" || fail "slow-recovery fixture watcher did not stay live"
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  kill -KILL "$watcher_pid" 2>/dev/null || fail "could not abruptly stop slow-recovery fixture watcher"
  wait "$first_arm" 2>/dev/null || true
  append_wake "$state" check startup-network 'check: startup-network before a slow re-arm'

  # Removing the dead watcher's beacon makes the delay start exactly when the
  # re-armed watcher publishes its own, so its startup and the arm's confirmation
  # stay at full speed and only the work after confirmation is slowed.
  rm -f "$state/.last-watcher-beat"
  for tool in mktemp readlink; do
    real=$(command -v "$tool") || fail "no $tool to delay"
    cat > "$fakebin/$tool" <<SH
#!/bin/sh
[ -e "$state/.last-watcher-beat" ] && sleep 0.6
exec "$real" "\$@"
SH
    chmod +x "$fakebin/$tool"
  done

  started=$(date +%s)
  start_rearm_arm "$home" "$state" "$fakebin" "$armout"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS"
  status=$?
  [ "$status" -ne 124 ] \
    || fail "slow re-arm stayed live instead of surfacing its recovery"
  expect_code 0 "$status" "slow re-arm recovery must close successfully"
  grep -F 'check: rearm-resurface' "$armout" >/dev/null \
    || fail "slow re-arm did not report the durable recovery wake: $(cat "$armout")"
  # Without this, a change that stopped the delay from applying would pass here
  # while no longer testing a slow cycle at all.
  [ $(( $(date +%s) - started )) -ge 12 ] \
    || fail "the delayed tools did not hold the re-arm past the old fixed wait"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" \
    || fail "slow re-arm recovery drain failed"
  grep "$(printf '\tcheck\tstartup-network\t')" "$dir/drain.out" >/dev/null \
    || fail "wake queued before the slow re-arm was not drained"
  ack_wakes "$state" || fail "slow re-arm handling acknowledgement failed"
  pass "watch-arm: a re-arm whose recovery cycle runs slowly still surfaces it"
}

test_marker_publish_failure_retains_recovery_evidence() {
  local dir home state fakebin first_arm watcher_pid armout
  dir=$(make_case downtime-marker-publish-failure)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/first-arm.out"
  first_arm=$ARM_PID
  is_live_non_zombie "$first_arm" || fail "marker-failure fixture watcher did not stay live"
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  mkdir "$state/.watcher-down"
  kill -TERM "$watcher_pid" 2>/dev/null || fail "could not stop marker-failure fixture watcher"
  wait "$first_arm" 2>/dev/null || true

  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$watcher_pid" ] \
    || fail "marker publication failure discarded stale-lock recovery evidence"
  ! is_live_non_zombie "$watcher_pid" \
    || fail "marker-failure fixture watcher remained live"

  rmdir "$state/.watcher-down"
  armout="$dir/recovery-arm.out"
  start_rearm_arm "$home" "$state" "$fakebin" "$armout"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS" || fail "stale-lock recovery did not surface downtime"
  grep -F 'check: rearm-resurface' "$armout" >/dev/null \
    || fail "stale-lock recovery did not emit the recovery wake: $(cat "$armout")"
  pass "watch-arm: marker publication failure retains stale-lock recovery evidence"
}

test_delivery_gap_wake_is_recovered_once() {
  local dir home state fakebin first_arm
  dir=$(make_case delivery-gap-recovery)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/first-arm.out"
  first_arm=$ARM_PID
  is_live_non_zombie "$first_arm" || fail "delivery-gap fixture watcher did not stay live"
  printf 'done: first delivered wake\n' > "$state/first.status"
  wait_for_exit "$first_arm" "$REARM_EXIT_POLLS" || fail "first watcher did not deliver its status wake"
  grep -q '^signal:' "$dir/first-arm.out" \
    || fail "first watcher did not report its delivered wake"

  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/first-drain.out" \
    || fail "first handling drain failed"
  ack_wakes "$state" || fail "first handling acknowledgement failed"
  append_wake "$state" check startup-network 'check: startup-network during handling gap'

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/gap-arm.out"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS" || fail "successor missed the wake queued in the delivery gap"
  grep -F 'check: rearm-resurface' "$dir/gap-arm.out" >/dev/null \
    || fail "delivery-gap successor did not emit one recovery wake: $(cat "$dir/gap-arm.out")"

  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/gap-drain.out" \
    || fail "delivery-gap recovery drain failed"
  grep "$(printf '\tcheck\tstartup-network\t')" "$dir/gap-drain.out" >/dev/null \
    || fail "wake queued in the delivery gap was not drained"
  ack_wakes "$state" || fail "delivery-gap handling acknowledgement failed"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/stable-successor.out"
  is_live_non_zombie "$ARM_PID" || fail "successor looped after the delivery gap was drained"
  kill "$ARM_PID" 2>/dev/null || true
  wait "$ARM_PID" 2>/dev/null || true
  pass "watch-arm: a wake queued after handling drain is recovered once at successor arm"
}

test_interrupted_handling_is_redrained_on_rearm() {
  local dir home state fakebin first_arm recovery_arm sequence generation handling_watcher_pid handling_generation generation_replay
  dir=$(make_case interrupted-handling-redrain)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/first-arm.out"
  first_arm=$ARM_PID
  is_live_non_zombie "$first_arm" || fail "interrupted-handling fixture watcher did not stay live"
  printf 'done: wake whose handling is interrupted\n' > "$state/interrupted.status"
  wait_for_exit "$first_arm" "$REARM_EXIT_POLLS" || fail "fixture watcher did not deliver its wake"
  grep "$(printf '\tsignal\tinterrupted.status\t')" "$state/.wake-queue" >/dev/null \
    || fail "delivered wake was not durable before handling"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/crash-gap-recovery-arm.out"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS" || fail "re-arm after a pre-successor crash stranded the durable wake"
  recovery_arm=$ARM_PID
  grep -F 'check: rearm-resurface' "$dir/crash-gap-recovery-arm.out" >/dev/null \
    || fail "re-arm after a pre-successor crash did not re-surface the durable wake"
  grep "$(printf '\tsignal\tinterrupted.status\t')" "$state/.wake-queue" >/dev/null \
    || fail "pre-successor crash recovery removed the unacknowledged durable wake"
  case "$(cat "$state/.watcher-down" 2>/dev/null || true)" in
    pending:downtime:*|announced:downtime:*) ;;
    *) fail "reason emission marked recovery handled before a successor was established" ;;
  esac
  generation_before=$(recovery_marker_generation "$state/.watcher-down")
  [ -n "$generation_before" ] || fail "crash-gap recovery left no recovery generation"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/reason-emit-crash-replay.out"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS" || fail "a crash after reason emission stranded the durable wake"
  recovery_arm=$ARM_PID
  grep -F 'check: rearm-resurface' "$dir/reason-emit-crash-replay.out" >/dev/null \
    || fail "a crash after reason emission did not re-drain recovery"
  generation_replay=$(recovery_marker_generation "$state/.watcher-down")
  [ -n "$generation_replay" ] \
    || fail "reason-emission replay left no recovery generation"
  grep "$(printf '\tsignal\tinterrupted.status\t')" "$state/.wake-queue" >/dev/null \
    || fail "reason-emission replay removed the unacknowledged durable wake"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/handling-successor-arm.out" "$recovery_arm"
  is_live_non_zombie "$ARM_PID" \
    || fail "expected handling successor looped on the pending durable wake"
  case "$(cat "$state/.watcher-down" 2>/dev/null || true)" in
    announced:downtime:*|pending:downtime:*) ;;
    *) fail "successor launch marked recovery handled before prompt delivery" ;;
  esac
  handling_generation=$(recovery_marker_generation "$state/.watcher-down")
  handling_watcher_pid=$(sed -n 's/^watcher: started pid=\([0-9][0-9]*\).* recovery-generation=.*$/\1/p' "$dir/handling-successor-arm.out")
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WATCH_ARM" --handling-delivered "$handling_generation" \
    --watcher-pid "$handling_watcher_pid" \
    || fail "confirmed prompt delivery did not begin handling"
  case "$(cat "$state/.watcher-down" 2>/dev/null || true)" in
    pending:handling:"$handling_generation"|announced:handling:"$handling_generation") ;;
    *) fail "confirmed prompt delivery did not transition its recovery generation" ;;
  esac
  ! grep -F 'check: rearm-resurface' "$dir/handling-successor-arm.out" >/dev/null \
    || fail "expected handling successor emitted a recursive recovery wake"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/interrupted-drain.out" \
    2> "$dir/interrupted-drain.err" || fail "handling drain did not expose the durable wake"
  grep "$(printf '\tsignal\tinterrupted.status\t')" "$dir/interrupted-drain.out" >/dev/null \
    || fail "handling drain did not present the durable wake"
  grep "$(printf '\tsignal\tinterrupted.status\t')" "$state/.wake-queue" >/dev/null \
    || fail "interrupted handling removed the unacknowledged durable wake"
  is_live_non_zombie "$ARM_PID" || fail "handling drain stopped its live successor"

  kill -TERM "$ARM_PID" 2>/dev/null || fail "could not interrupt the handling successor"
  wait "$ARM_PID" 2>/dev/null || true
  case "$(cat "$state/.watcher-down" 2>/dev/null || true)" in
    pending:downtime:*|announced:downtime:*) ;;
    *) fail "interrupted pre-handling successor did not persist downtime recovery" ;;
  esac

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/recovery-arm.out"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS" || fail "successor after interruption did not re-surface the pending wake"
  grep -F 'check: rearm-resurface' "$dir/recovery-arm.out" >/dev/null \
    || fail "successor after interruption did not emit durable recovery"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/replay-drain.out" \
    2> "$dir/replay-drain.err" || fail "successor could not re-drain the interrupted wake"
  grep "$(printf '\tsignal\tinterrupted.status\t')" "$dir/replay-drain.out" >/dev/null \
    || fail "successor did not re-drain the still-durable wake"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/replay-drain.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/replay-drain.err")
  [ -n "$sequence" ] && [ -n "$generation" ] \
    || fail "re-drain did not emit a generation-bound post-handling acknowledgement command"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation" \
    || fail "completed replay could not acknowledge the handled wake"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledged replay remained in the durable queue"
  pass "watch-arm: interrupted handling leaves its wake durable for successor re-drain"
}

test_malformed_marker_is_quarantined_once() {
  local dir home state fakebin invalid_count
  dir=$(make_case malformed-downtime-marker)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data" "$state/.watcher-down"
  printf 'foreign state\n' > "$state/.watcher-down/payload"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/recovery-arm.out"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS" || fail "malformed marker did not produce a bounded recovery wake"
  grep -F 'check: rearm-resurface' "$dir/recovery-arm.out" >/dev/null \
    || fail "malformed marker did not emit the recovery wake"
  invalid_count=$(find "$state" -maxdepth 1 -type d -name '.watcher-down.invalid.*' | wc -l | tr -d '[:space:]')
  [ "$invalid_count" -eq 1 ] || fail "malformed marker was not quarantined exactly once"

  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/recovery-drain.out" \
    || fail "malformed-marker recovery drain failed"
  ack_wakes "$state" || fail "malformed-marker handling acknowledgement failed"
  start_rearm_arm "$home" "$state" "$fakebin" "$dir/stable-successor.out"
  is_live_non_zombie "$ARM_PID" || fail "malformed marker caused a persistent recovery loop"
  kill "$ARM_PID" 2>/dev/null || true
  wait "$ARM_PID" 2>/dev/null || true
  pass "watch-arm: malformed recovery state is quarantined without a successor loop"
}

test_recovery_consumption_serializes_queue_publication() {
  local dir home state fakebin
  dir=$(make_case recovery-consumption-race)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"
  printf 'acked:handling:fixture\n' > "$state/.watcher-down"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/arm.out"
  is_live_non_zombie "$ARM_PID" || fail "acknowledged recovery fixture did not remain live"
  append_wake "$state" check startup-network 'check: concurrent startup-network' \
    || fail "concurrent queue publication failed"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS" \
    || fail "watcher missed publication after an acknowledged recovery handoff"
  grep -F 'check: rearm-resurface' "$dir/arm.out" >/dev/null \
    || fail "publisher did not restore recovery evidence"
  grep "$(printf '\tcheck\tstartup-network\t')" "$state/.wake-queue" >/dev/null \
    || fail "publisher did not durably append its wake"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" \
    || fail "publisher recovery drain failed"
  grep "$(printf '\tcheck\tstartup-network\t')" "$dir/drain.out" >/dev/null \
    || fail "publisher wake was not surfaced and drained"
  ack_wakes "$state" || fail "publisher handling acknowledgement failed"
  pass "watch-arm: publication after recovery handoff is surfaced"
}

test_restart_preserves_recovery_across_reused_pid_lock() {
  local dir home state fakebin armout unrelated owner
  dir=$(make_case restart-reused-pid-recovery)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  owner="$state/.watch.lock.owner.fixture"
  mkdir -p "$home/data" "$owner"

  sleep 300 &
  unrelated=$!
  printf '%s\n' "$unrelated" > "$owner/pid"
  printf '%s\n' "$home" > "$owner/fm-home"
  printf '%s\n' "$WATCH" > "$owner/watcher-path"
  printf '%s\n' 'reused-pid-does-not-match' > "$owner/pid-identity"
  ln -s "$owner" "$state/.watch.lock"

  start_rearm_arm "$home" "$state" "$fakebin" "$armout"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS" || fail "restart did not surface recovery after clearing a reused-pid lock"
  grep -F 'check: rearm-resurface' "$armout" >/dev/null \
    || fail "restart cleared reused-pid lock evidence without a recovery wake: $(cat "$armout")"
  is_live_non_zombie "$unrelated" || fail "restart signaled the unrelated process whose pid was reused"
  kill "$unrelated" 2>/dev/null || true
  wait "$unrelated" 2>/dev/null || true
  pass "watch-arm: restart publishes recovery before clearing a reused-pid watcher lock"
}

test_markerless_legacy_queue_is_recovered_on_arm() {
  local dir home state fakebin row
  dir=$(make_case markerless-legacy-arm)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"
  row=$(printf '1700000000\t7\tcheck\tlegacy-process-event\tcheck: legacy process-event')
  printf '%s\n' "$row" > "$state/.wake-queue"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/arm.out"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS" || fail "markerless legacy queue was stranded at re-arm"
  grep -F 'check: rearm-resurface' "$dir/arm.out" >/dev/null \
    || fail "markerless legacy queue did not trigger recovery"
  case "$(cat "$state/.watcher-down" 2>/dev/null || true)" in
    pending:downtime:*|announced:downtime:*) ;;
    *) fail "markerless legacy queue was not adopted into downtime recovery" ;;
  esac
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" \
    || fail "adopted legacy queue could not be drained"
  grep -F "$row" "$dir/drain.out" >/dev/null \
    || fail "adopted legacy wake was not presented"
  ack_wakes "$state" || fail "adopted legacy wake could not be acknowledged"
  pass "watch-arm: markerless legacy queues are adopted and recovered"
}

test_idle_lavish_source_stays_quiet_until_result() {
  local dir home state fakebin source trigger first_out idle_out i
  dir=$(make_case idle-lavish-source)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  source="$dir/lavish-source.sh"
  trigger="$dir/result-ready"
  first_out="$dir/first-arm.out"
  idle_out="$dir/idle-arm.out"
  mkdir -p "$home/data"
  cat > "$source" <<'SH'
#!/usr/bin/env bash
set -u
trigger=$1
i=0
while [ ! -e "$trigger" ] && [ "$i" -lt 400 ]; do
  sleep 0.05
  i=$((i + 1))
done
[ -e "$trigger" ] || exit 1
cat <<'RESULT'
session:
  status: feedback
  session_ended: true
prompts[1]{tag,prompt}:
  feedback,"real review result"
RESULT
SH
  chmod +x "$source"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    "$ROOT/bin/fm-procevent.sh" register lavish idle-lavish -- "$source" "$trigger" \
    >/dev/null || fail "could not register the Lavish fixture source"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=1 \
    "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null \
    || fail "could not start the Lavish fixture source"
  printf 'pending:downtime:idle-lavish.1.fixture\n' > "$state/.watcher-down"

  FM_ROOT_OVERRIDE="$ROOT" start_rearm_arm "$home" "$state" "$fakebin" "$first_out"
  wait_for_exit "$ARM_PID" 80 || fail "the first recovery arm did not surface"
  grep -F 'check: rearm-resurface' "$first_out" >/dev/null \
    || fail "the pending recovery generation did not get its first announcement"
  [ ! -s "$state/.wake-queue" ] \
    || fail "the idle Lavish source produced a wake before any result"

  FM_ROOT_OVERRIDE="$ROOT" start_rearm_arm "$home" "$state" "$fakebin" "$idle_out"
  i=0
  while [ "$i" -lt 30 ] && is_live_non_zombie "$ARM_PID"; do
    sleep 0.1
    i=$((i + 1))
  done
  if ! is_live_non_zombie "$ARM_PID"; then
    : > "$trigger"
    wait "$ARM_PID" 2>/dev/null || true
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
      "$ROOT/bin/fm-procevent.sh" retire idle-lavish >/dev/null 2>&1 || true
    fail "an idle live Lavish source re-fired recovery with an empty queue: $(cat "$idle_out")"
  fi
  ! grep -F 'check: rearm-resurface' "$idle_out" >/dev/null \
    || fail "the idle live Lavish source emitted a repeated recovery wake"

  : > "$trigger"
  wait_for_exit "$ARM_PID" 120 \
    || fail "the live Lavish result did not wake the supervising arm"
  grep -F 'check: process-event result captured: procevent:idle-lavish:1' "$idle_out" >/dev/null \
    || fail "the live Lavish result did not surface promptly: $(cat "$idle_out")"
  grep "$(printf '\tcheck\tprocevent:idle-lavish:1\t')" "$state/.wake-queue" >/dev/null \
    || fail "the live Lavish result was not durable before its wake"
  pass "watch-arm: an idle Lavish source stays quiet and its real result wakes promptly"
}

test_append_wakes_live_announced_watcher() {
  local dir home state fakebin first_out idle_out
  dir=$(make_case append-after-empty-recovery)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  first_out="$dir/first-arm.out"
  idle_out="$dir/idle-arm.out"
  mkdir -p "$home/data"
  printf 'pending:downtime:append-after-empty.fixture\n' > "$state/.watcher-down"

  start_rearm_arm "$home" "$state" "$fakebin" "$first_out"
  wait_for_exit "$ARM_PID" 80 || fail "the initial empty recovery did not surface"
  grep -F 'check: rearm-resurface' "$first_out" >/dev/null \
    || fail "the initial empty recovery was not announced"
  [ ! -s "$state/.wake-queue" ] \
    || fail "the empty recovery unexpectedly queued durable work"

  start_rearm_arm "$home" "$state" "$fakebin" "$idle_out"
  is_live_non_zombie "$ARM_PID" \
    || fail "the announced empty recovery did not leave a live watcher"
  append_wake "$state" check inbox:fixture 'check: captain inbox note fixture' \
    || fail "the generic producer could not append its wake"
  wait_for_exit "$ARM_PID" 80 \
    || fail "the live watcher stranded work appended after an empty recovery"
  grep -F 'check: rearm-resurface' "$idle_out" >/dev/null \
    || fail "the appended wake did not reopen recovery: $(cat "$idle_out")"
  grep "$(printf '\tcheck\tinbox:fixture\t')" "$state/.wake-queue" >/dev/null \
    || fail "the appended wake was not durable when recovery surfaced"
  pass "watch-arm: appending work reopens an announced empty recovery"
}

# Exercise the handling-window recovery invariant owned by
# docs/watcher-continuity.md through real watcher processes.
test_handling_window_close_keeps_the_acknowledgement_valid() {
  local dir home state fakebin pair sequence generation
  dir=$(make_case handling-window-close-acknowledgement)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/first-arm.out"
  is_live_non_zombie "$ARM_PID" || fail "handling-window fixture watcher did not stay live"
  printf 'done: wake handled while a watcher cycle closes\n' > "$state/handled.status"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS" || fail "fixture watcher did not deliver its wake"
  grep "$(printf '\tsignal\thandled.status\t')" "$state/.wake-queue" >/dev/null \
    || fail "delivered wake was not durable before handling"

  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err" \
    || fail "handling drain did not present the durable wake"
  pair=$(drain_ack_pair "$dir/drain.err") \
    || fail "drain did not print a generation-bound acknowledgement command"
  sequence=${pair%%$'\t'*}
  generation=${pair##*$'\t'}

  # One full watcher cycle appends a wake and then closes inside the handling window.
  start_rearm_arm "$home" "$state" "$fakebin" "$dir/handling-window-arm.out"
  is_live_non_zombie "$ARM_PID" || fail "handling-window watcher did not stay live"
  printf 'done: wake published during handling\n' > "$state/during-handling.status"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS" || fail "handling-window watcher did not deliver its wake"
  grep "$(printf '\tsignal\tduring-handling.status\t')" "$state/.wake-queue" >/dev/null \
    || fail "handling-window watcher did not durably append its wake"

  [ "$(cat "$state/.watcher-down" 2>/dev/null || true)" = "pending:downtime:$generation" ] \
    || fail "repeated publications during handling replaced the outstanding recovery generation"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation" 2> "$dir/ack.err" \
    || fail "the printed acknowledgement was rejected after repeated publications: $(cat "$dir/ack.err")"
  ! grep "$(printf '\tsignal\thandled.status\t')" "$state/.wake-queue" >/dev/null \
    || fail "the acknowledged wake was not consumed"
  grep "$(printf '\tsignal\tduring-handling.status\t')" "$state/.wake-queue" >/dev/null \
    || fail "the newer handling-window wake was over-consumed"

  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/remaining-drain.out" \
    2> "$dir/remaining-drain.err" || fail "remaining wake could not be re-drained"
  pair=$(drain_ack_pair "$dir/remaining-drain.err") \
    || fail "remaining drain did not print an acknowledgement command"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "${pair%%$'\t'*}" \
    --recovery-generation "${pair##*$'\t'}" \
    || fail "remaining handling-window wake could not be acknowledged"
  [ ! -s "$state/.wake-queue" ] || fail "remaining wake was not consumed"
  case "$(cat "$state/.watcher-down" 2>/dev/null || true)" in
    acked:*) ;;
    *) fail "the handled recovery episode was not retired" ;;
  esac

  # The next arm must supervise rather than spend its whole cycle on recovery.
  start_rearm_arm "$home" "$state" "$fakebin" "$dir/next-arm.out"
  is_live_non_zombie "$ARM_PID" \
    || fail "the watcher armed after acknowledgement died inside its first cycle"
  ! grep -F 'check: rearm-resurface' "$dir/next-arm.out" >/dev/null \
    || fail "the watcher armed after acknowledgement re-announced a retired recovery"
  printf 'blocked: a later wake the live watcher must still surface\n' > "$state/later.status"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS" || fail "the live watcher did not surface a later wake"
  grep -q '^signal:' "$dir/next-arm.out" \
    || fail "the watcher armed after acknowledgement never reached real supervision work: $(cat "$dir/next-arm.out")"
  pass "watch-arm: a watcher close during handling keeps the printed acknowledgement valid"
}

# Exercise the moved-generation recovery invariant owned by
# docs/watcher-continuity.md through real watcher processes.
test_moved_generation_acknowledgement_is_self_healing() {
  local dir home state fakebin pair first_sequence first_generation second_generation
  dir=$(make_case moved-generation-acknowledgement)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/first-arm.out"
  is_live_non_zombie "$ARM_PID" || fail "moved-generation fixture watcher did not stay live"
  printf 'done: first handled wake\n' > "$state/first.status"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS" || fail "fixture watcher did not deliver its first wake"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/first-drain.out" \
    2> "$dir/first-drain.err" || fail "first drain did not present the durable wake"
  pair=$(drain_ack_pair "$dir/first-drain.err") \
    || fail "first drain did not print a generation-bound acknowledgement command"
  first_sequence=${pair%%$'\t'*}
  first_generation=${pair##*$'\t'}
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$first_sequence" \
    --recovery-generation "$first_generation" \
    || fail "the first handled wake could not be acknowledged"

  # A retired episode does not freeze the generation: the next one is its own.
  start_rearm_arm "$home" "$state" "$fakebin" "$dir/second-arm.out"
  is_live_non_zombie "$ARM_PID" || fail "second fixture watcher did not stay live"
  printf 'done: second wake in a newer recovery episode\n' > "$state/second.status"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS" || fail "second fixture watcher did not deliver its wake"
  second_generation=$(sed -n 's/^pending:downtime:\(.*\)$/\1/p' "$state/.watcher-down")
  [ -n "$second_generation" ] || fail "a wake after acknowledgement did not open a recovery episode"
  [ "$second_generation" != "$first_generation" ] \
    || fail "an acknowledged episode kept its generation instead of opening a new one"

  # Replaying the stale pair must not fail, must not over-consume, and must not
  # retire the newer episode.
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$first_sequence" \
    --recovery-generation "$first_generation" 2> "$dir/stale-ack.err" \
    || fail "a replayed stale acknowledgement was rejected instead of degrading safely"
  if ! grep -F 'WAKE_ACK_REQUIRED' "$dir/stale-ack.err" >/dev/null \
    || ! grep -F 're-run' "$dir/stale-ack.err" >/dev/null; then
    fail "a moved recovery generation did not name its own remedy: $(cat "$dir/stale-ack.err")"
  fi
  grep "$(printf '\tsignal\tsecond.status\t')" "$state/.wake-queue" >/dev/null \
    || fail "a stale acknowledgement consumed a wake above its sequence"
  [ "$(cat "$state/.watcher-down" 2>/dev/null || true)" = "pending:downtime:$second_generation" ] \
    || fail "a stale acknowledgement retired the newer recovery episode"

  # The sequence alone owns consumption, so the handled rows go even while the
  # generation is stale, and only the episode stays pending.
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through 999 \
    --recovery-generation "$first_generation" 2> "$dir/stale-consume.err" \
    || fail "a stale acknowledgement refused to consume the rows it was given"
  [ ! -s "$state/.wake-queue" ] \
    || fail "a stale acknowledgement left its handled rows on the durable queue"
  [ "$(cat "$state/.watcher-down" 2>/dev/null || true)" = "pending:downtime:$second_generation" ] \
    || fail "row consumption under a stale generation retired the pending episode"

  # Following the printed remedy closes the episode, so the loop is self-healing.
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/redrain.out" \
    2> "$dir/redrain.err" || fail "the remedy re-drain did not run"
  pair=$(drain_ack_pair "$dir/redrain.err") \
    || fail "the remedy re-drain did not print the newer acknowledgement command"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "${pair%%$'\t'*}" \
    --recovery-generation "${pair##*$'\t'}" \
    || fail "the newer recovery episode could not be acknowledged"
  case "$(cat "$state/.watcher-down" 2>/dev/null || true)" in
    acked:*) ;;
    *) fail "following the printed remedy did not retire the newer recovery episode" ;;
  esac
  pass "watch-arm: a moved recovery generation consumes handled rows and names its remedy"
}

# The supervision host ends its own cycle on purpose; --stop is the home-scoped
# stop without a re-arm, and the stopped watcher publishes downtime as any
# close does, so the owner's rewake can commit.
test_stop_ends_the_home_watcher_and_publishes_downtime() {
  local dir home state fakebin out status
  dir="$TMP_ROOT/stop-home-watcher"
  home="$dir/home"
  state="$home/state"
  fakebin=$(make_case stop-home-watcher-bin)/fakebin
  mkdir -p "$state"
  FM_HOME="$home" start_seed_watcher "$state" "$fakebin" "$dir/watch.out"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WATCH_ARM" --stop 2>&1); status=$?
  expect_code 0 "$status" "--stop of a live home watcher must succeed"
  assert_contains "$out" "watcher: stopped pid=$SEED_PID" "--stop must name the watcher it stopped"
  wait_for_exit "$SEED_PID" 50 >/dev/null 2>&1 || true
  kill -0 "$SEED_PID" 2>/dev/null && fail "--stop left the home watcher running"
  case "$(cat "$state/.watcher-down" 2>/dev/null)" in
    pending:downtime:*|announced:downtime:*) ;;
    *) fail "--stop did not leave downtime published: $(cat "$state/.watcher-down" 2>/dev/null)" ;;
  esac
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WATCH_ARM" --stop 2>&1); status=$?
  expect_code 0 "$status" "--stop with no watcher must succeed"
  assert_contains "$out" "watcher: none running" "--stop with no watcher must say so"
  pass "watch-arm: --stop ends only this home's watcher, publishes downtime, and reports when none runs"
}

# --take-over stops only a watcher that the named arm itself owns. The seed
# watcher here is this shell's child, so naming any other process leaves it
# running and the arm attaches to it exactly as a plain arm does.
test_take_over_attaches_to_a_cycle_the_named_arm_does_not_own() {
  local dir state fakebin armout other status
  dir=$(make_case take-over-not-owner)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  FM_HOME="$dir" start_seed_watcher "$state" "$fakebin" "$dir/watch.out"
  sleep 60 &
  other=$!
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$WATCH_ARM" --take-over 2>/dev/null
  status=$?
  expect_code 2 "$status" "--take-over without an arm pid must be refused"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 \
    "$WATCH_ARM" --take-over "$other" > "$armout" &
  ARM_PID=$!
  wait_for_file_text "$armout" "watcher: attached pid=$SEED_PID" \
    || fail "--take-over of a cycle the named arm does not own did not attach: $(cat "$armout")"
  sleep 1
  is_live_non_zombie "$SEED_PID" || fail "--take-over stopped a watcher the named arm does not own"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null)" = "$SEED_PID" ] || fail "--take-over moved a lock it does not own"
  kill -TERM "$ARM_PID" "$SEED_PID" "$other" 2>/dev/null || true
  wait_for_exit "$ARM_PID" 50 >/dev/null 2>&1 || true
  wait_for_exit "$SEED_PID" 50 >/dev/null 2>&1 || true
  wait "$other" 2>/dev/null || true
  pass "watch-arm: --take-over attaches to a cycle the named arm does not own and leaves it running"
}

# --take-over stops the named real arm's watcher, as it would a successor
# left for main, and owns a fresh cycle. The stop must not open recovery over an episode
# main already acknowledged, and must not hide work still queued.
test_take_over_owns_a_fresh_cycle_and_keeps_queued_work_surfacing() {
  local dir state fakebin armout status owner
  dir=$(make_case take-over-owner)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"

  # Main acknowledged everything: the fresh cycle stays quiet.
  start_rearm_arm "$dir" "$state" "$fakebin" "$dir/owner.out" "$$"
  owner=$ARM_PID
  SEED_PID=$(cat "$state/.watch.lock/pid")
  append_wake "$state" signal take-over "signal: fixture handled by main"
  ack_wakes "$state" >/dev/null || fail "fixture: main could not acknowledge the handled wake"
  case "$(cat "$state/.watcher-down" 2>/dev/null)" in acked:*) ;; *) fail "fixture: the episode was not acknowledged" ;; esac
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH_ARM" --take-over "$owner" > "$armout" &
  ARM_PID=$!
  wait_for_file_text "$armout" 'watcher: started pid=' \
    || fail "--take-over did not own a fresh cycle: $(cat "$armout")"
  wait_for_exit "$SEED_PID" 50 >/dev/null 2>&1 || true
  ! is_live_non_zombie "$SEED_PID" || fail "--take-over left the watcher it took over running"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null)" != "$SEED_PID" ] || fail "--take-over did not take the lock"
  sleep 3
  is_live_non_zombie "$ARM_PID" || fail "the taken-over cycle closed with no new work: $(cat "$armout")"
  case "$(cat "$state/.watcher-down" 2>/dev/null)" in
    acked:*) ;;
    *) fail "the takeover opened a downtime episode: $(cat "$state/.watcher-down" 2>/dev/null)" ;;
  esac
  grep -q 'reason=taken-over	.*successor=started:' "$state/.watch-cycle-exits.log" \
    || fail "the lifecycle ledger does not link the taken-over cycle to the one it started: $(cat "$state/.watch-cycle-exits.log")"
  kill -TERM "$ARM_PID" 2>/dev/null || true
  wait_for_exit "$ARM_PID" 50 >/dev/null 2>&1 || true

  # A wake still queued for main resurfaces from the cycle the arm took over.
  start_rearm_arm "$dir" "$state" "$fakebin" "$dir/owner2.out" "$$"
  owner=$ARM_PID
  SEED_PID=$(cat "$state/.watch.lock/pid")
  append_wake "$state" signal take-over "signal: fixture still queued for main"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_CONFIRM_TIMEOUT="$REARM_CONFIRM_SECONDS" "$WATCH_ARM" --take-over "$owner" > "$armout" &
  ARM_PID=$!
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS"
  status=$?
  expect_code 0 "$status" "a takeover that resurfaces queued work closes cleanly"
  grep -q '^check: rearm-resurface' "$armout" \
    || fail "work queued for main did not resurface after the takeover: $(cat "$armout")"
  ! is_live_non_zombie "$SEED_PID" || fail "--take-over left the second watcher running"
  pass "watch-arm: --take-over owns a fresh cycle without a recovery wake and still surfaces queued work"
}

# Pause just after handover releases its snapshot locks, then fail the old
# watcher's secondmate tick write so it exits through cleanup before TERM lands.
# The ledger and recovery wake are public output contracts, not source probes.
test_take_over_preserves_downtime_from_watcher_self_exit() {
  local dir home state fakebin owner watcher armout acknowledged real_rm real_touch status i
  dir=$(make_case take-over-self-exit)
  home="$dir/home"
  mkdir -p "$home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  real_touch=$(command -v touch)
  printf '#!/usr/bin/env bash\nif [ "$*" = "%s/.secondmate-liveness-tick" ] && [ -e "%s/fail-tick" ]; then exit 1; fi\nexec "%s" "$@"\n' \
    "$state" "$dir" "$real_touch" > "$fakebin/touch"
  chmod +x "$fakebin/touch"
  FM_SECONDMATE_LIVENESS_SECS=1 start_rearm_arm "$home" "$state" "$fakebin" "$dir/owner.out" "$$"
  owner=$ARM_PID
  watcher=$(cat "$state/.watch.lock/pid")
  append_wake "$state" signal take-over "signal: fixture handled by main"
  ack_wakes "$state" >/dev/null || fail "fixture: could not acknowledge wake"
  acknowledged=$(cat "$state/.watcher-down")
  real_rm=$(command -v rm)
  # Only the taking arm gets this shim. Release the real queue lock before
  # exposing the barrier: the self-exiting watcher needs it for cleanup.
  mkdir -p "$dir/barrier-bin"
  printf '#!/usr/bin/env bash\n"%s" "$@"\n' "$real_rm" > "$dir/barrier-bin/rm"
  printf 'if [ "$*" = "-f %s/.wake-queue.lock" ]; then\n' "$state" >> "$dir/barrier-bin/rm"
  printf '  touch "%s/snapshot-read"\n  for ((i=0; i<700; i++)); do\n    [ -e "%s/release" ] && break\n    sleep 0.05\n  done\nfi\n' "$dir" "$dir" >> "$dir/barrier-bin/rm"
  chmod +x "$dir/barrier-bin/rm"
  PATH="$dir/barrier-bin:$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_CONFIRM_TIMEOUT="$REARM_CONFIRM_SECONDS" \
    "$WATCH_ARM" --take-over "$owner" > "$armout" &
  ARM_PID=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$dir/snapshot-read" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$dir/snapshot-read" ] || fail "takeover never reached its snapshot"
  touch "$dir/fail-tick"
  wait_for_exit "$owner" "$REARM_EXIT_POLLS"
  status=$?
  expect_code 1 "$status" "old watcher must fail through its own cleanup"
  ! is_live_non_zombie "$watcher" || fail "old watcher did not self-exit"
  grep -q "arm_pid=$owner	watcher_pid=$watcher.*exit_code=1	signal=none" "$state/.watch-cycle-exits.log" \
    || fail "owner did not record its watcher's non-signal failure"
  [ ! -s "$state/.wake-queue" ] || fail "self-exit unexpectedly queued a wake"
  ! grep -q "^$watcher	" "$state/.watch-deliveries.log" 2>/dev/null \
    || fail "self-exit unexpectedly delivered a wake"
  case "$(cat "$state/.watcher-down")" in pending:downtime:*) ;; *) fail "self-exit did not publish downtime" ;; esac
  rm -f "$dir/fail-tick"
  touch "$dir/release"
  i=0
  while [ "$i" -lt "$REARM_REPORT_POLLS" ]; do
    grep -qE '^watcher: started pid=|^check: rearm-resurface' "$armout" && break
    is_live_non_zombie "$ARM_PID" || break
    sleep 0.05
    i=$((i + 1))
  done
  [ "$(cat "$state/.watcher-down")" != "$acknowledged" ] || fail "takeover restored the old acknowledgement"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS"
  status=$?
  expect_code 0 "$status" "fresh takeover must surface recovery cleanly"
  assert_contains "$(cat "$armout")" 'check: rearm-resurface' "self-exit downtime must surface as recovery"
  pass "watch-arm: takeover preserves self-exit downtime and surfaces a recovery wake"
}

# A shell can hold the take-over's TERM past the arm's first wait (stock macOS
# bash 3.2 holds it until a running command substitution exits). SIGSTOP holds
# delivery the same way on every platform: the arm reports the cycle it follows,
# and the TERM lands only on SIGCONT. That stop must still be restored, or the
# next fresh cycle resurfaces an empty recovery on every turn end. A watcher
# that dies of anything else while held is a genuine outage and still resurfaces.
wait_for_arm_line() {  # <arm-out> <fixed-text>
  local i=0
  while [ "$i" -lt 300 ]; do
    grep -qF "$2" "$1" 2>/dev/null && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

test_take_over_restores_a_stop_whose_term_lands_late() {
  local dir state fakebin armout owner status
  dir=$(make_case take-over-late-term)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"

  start_rearm_arm "$dir" "$state" "$fakebin" "$dir/owner.out" "$$"
  owner=$ARM_PID
  SEED_PID=$(cat "$state/.watch.lock/pid")
  append_wake "$state" signal take-over "signal: fixture handled by main"
  ack_wakes "$state" >/dev/null || fail "fixture: main could not acknowledge the handled wake"
  case "$(cat "$state/.watcher-down" 2>/dev/null)" in acked:*) ;; *) fail "fixture: the episode was not acknowledged" ;; esac
  kill -STOP "$SEED_PID"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_CONFIRM_TIMEOUT="$REARM_CONFIRM_SECONDS" "$WATCH_ARM" --take-over "$owner" > "$armout" &
  ARM_PID=$!
  if ! wait_for_arm_line "$armout" "watcher: attached pid=$SEED_PID"; then
    kill -CONT "$SEED_PID" 2>/dev/null || true
    fail "the take-over did not follow a watcher still holding its TERM: $(cat "$armout")"
  fi
  kill -CONT "$SEED_PID"
  wait_for_arm_line "$armout" 'watcher: started pid=' \
    || fail "the take-over did not own a fresh cycle once the held TERM landed: $(cat "$armout")"
  ! is_live_non_zombie "$SEED_PID" || fail "the take-over left the watcher it stopped running"
  grep -q "arm_pid=$owner	watcher_pid=$SEED_PID	.*signal=TERM" "$state/.watch-cycle-exits.log" \
    || fail "fixture: the held TERM did not end the watcher: $(cat "$state/.watch-cycle-exits.log")"
  sleep 3
  is_live_non_zombie "$ARM_PID" || fail "the late take-over resurfaced an empty recovery: $(cat "$armout")"
  case "$(cat "$state/.watcher-down" 2>/dev/null)" in
    acked:*) ;;
    *) fail "the late take-over left downtime: $(cat "$state/.watcher-down" 2>/dev/null)" ;;
  esac
  grep -q "arm_pid=$ARM_PID	watcher_pid=$SEED_PID	.*reason=taken-over	.*successor=started:" "$state/.watch-cycle-exits.log" \
    || fail "the ledger does not record the late stop as taken over: $(cat "$state/.watch-cycle-exits.log")"
  kill -TERM "$ARM_PID" 2>/dev/null || true
  wait_for_exit "$ARM_PID" 50 >/dev/null 2>&1 || true

  # The held watcher dies of something other than the take-over's TERM. Its
  # owner's shell reports that kill on stderr, which is not under test.
  start_rearm_arm "$dir" "$state" "$fakebin" "$dir/owner2.out" "$$" 2>/dev/null
  owner=$ARM_PID
  SEED_PID=$(cat "$state/.watch.lock/pid")
  append_wake "$state" signal take-over "signal: fixture handled by main"
  ack_wakes "$state" >/dev/null || fail "fixture: main could not acknowledge the second wake"
  kill -STOP "$SEED_PID"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_CONFIRM_TIMEOUT="$REARM_CONFIRM_SECONDS" "$WATCH_ARM" --take-over "$owner" > "$armout" &
  ARM_PID=$!
  if ! wait_for_arm_line "$armout" "watcher: attached pid=$SEED_PID"; then
    kill -KILL "$SEED_PID" 2>/dev/null || true
    fail "the take-over did not follow the second held watcher: $(cat "$armout")"
  fi
  kill -KILL "$SEED_PID"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS"
  status=$?
  expect_code 0 "$status" "a held watcher killed by another signal must resurface cleanly"
  grep -q '^check: rearm-resurface' "$armout" \
    || fail "a held watcher killed by another signal did not resurface: $(cat "$armout")"
  pass "watch-arm: --take-over restores a stop whose TERM lands late and still resurfaces a genuine outage"
}

test_downtime_marker_does_not_follow_symlink() {
  local dir home state fakebin armout watcher_pid sentinel
  dir=$(make_case downtime-marker-symlink)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  sentinel="$dir/sentinel"
  mkdir -p "$home/data"

  start_rearm_arm "$home" "$state" "$fakebin" "$armout"
  is_live_non_zombie "$ARM_PID" || fail "symlink fixture watcher did not stay live"
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  printf 'must remain intact\n' > "$sentinel"
  ln -s "$sentinel" "$state/.watcher-down"
  kill -TERM "$watcher_pid" 2>/dev/null || fail "could not stop symlink fixture watcher"
  wait "$ARM_PID" 2>/dev/null || true

  [ "$(cat "$sentinel")" = "must remain intact" ] \
    || fail "downtime marker publication followed and truncated a symlink"
  [ -f "$state/.watcher-down" ] && [ ! -L "$state/.watcher-down" ] \
    || fail "downtime marker was not safely published as a regular file"
  pass "watch-arm: downtime marker publication does not follow symlinks"
}

# The watcher validates FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS when it arms and
# refuses to arm on an unusable value. Under a running watcher that value would
# make every per-cycle reconcile refuse by name into a discarded stdout, so no
# source would ever start and the home would sit disarmed while presenting as
# supervised; refusing to arm is loud through the liveness guard instead. This
# drives the real arm entry and asserts the arm STOPPED - non-zero exit, no
# started line, no lock holder, no beacon - and that its refusal names the
# variable, so a validator that merely returned false somewhere would not pass.
test_arm_refuses_an_unusable_launch_confirm_window() {
  local dir home state fakebin armout status lock_pid
  dir=$(make_case confirm-window-refusal)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  mkdir -p "$home/data"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_CONFIRM_TIMEOUT=5 FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=5s \
    "$WATCH_ARM" > "$armout" 2>&1 &
  ARM_PID=$!
  wait_for_exit "$ARM_PID" 200
  status=$?
  [ "$status" -ne 124 ] || fail "arm with an unusable confirm window never stopped: $(cat "$armout")"
  [ "$status" -ne 0 ] || fail "arm reported success with an unusable confirm window: $(cat "$armout")"
  grep -q '^watcher: FAILED' "$armout" \
    || fail "arm did not report the typed failure line: $(cat "$armout")"
  grep -qF 'FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS' "$armout" \
    || fail "the refusal did not name the variable: $(cat "$armout")"
  grep -qF "must be whole seconds from 1 to 600" "$armout" \
    || fail "the refusal did not name the accepted range: $(cat "$armout")"
  ! grep -q '^watcher: started' "$armout" \
    || fail "arm reported a started watcher despite the refusal: $(cat "$armout")"
  [ ! -e "$state/.last-watcher-beat" ] \
    || fail "a refused watcher still published a liveness beacon"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ -z "$lock_pid" ] || ! kill -0 "$lock_pid" 2>/dev/null \
    || fail "a refused watcher is still running as pid $lock_pid"
  pass "watch-arm: an unusable launch confirm window refuses to arm by name"
}

# A watcher armed from a disposable no-mistakes validation checkout outlives the
# validation step and keeps writing the real home's state from a path about to be
# deleted (upstream #321). The arm must refuse before touching any state. The
# fixture reaches this checkout's real arm through a symlink whose logical path
# sits under .no-mistakes/worktrees/, with the test harness's own bypass cleared
# for this one launch.
test_arm_refuses_a_disposable_validation_checkout() {
  local dir home state fakebin armout status link
  dir=$(make_case disposable-checkout-refusal)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  link="$dir/.no-mistakes/worktrees/run-1/firstmate"
  mkdir -p "$home/data" "$(dirname "$link")"
  ln -s "$ROOT" "$link"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_GATE_REFUSE_BYPASS='' \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_CONFIRM_TIMEOUT=5 "$link/bin/fm-watch-arm.sh" > "$armout" 2>&1 &
  ARM_PID=$!
  wait_for_exit "$ARM_PID" 200
  status=$?
  [ "$status" -ne 124 ] || fail "arm from a disposable checkout never stopped: $(cat "$armout")"
  [ "$status" -ne 0 ] || fail "arm from a disposable checkout reported success: $(cat "$armout")"
  grep -q '^watcher: FAILED' "$armout" \
    || fail "arm did not report the typed failure line: $(cat "$armout")"
  grep -qF 'disposable validation checkout' "$armout" \
    || fail "the refusal did not name the disposable checkout: $(cat "$armout")"
  ! grep -q '^watcher: started' "$armout" \
    || fail "arm reported a started watcher despite the refusal: $(cat "$armout")"
  [ ! -e "$state/.last-watcher-beat" ] \
    || fail "a refused watcher still published a liveness beacon"
  [ ! -e "$state/.watch.lock" ] \
    || fail "a refused watcher still took the singleton lock"
  pass "watch-arm: a disposable validation checkout refuses to arm"
}

# Start a real watcher through the real arm for a temporary home and set
# WATCH_PID from the arm's started line. Both stdout and stderr land in <arm-out>
# so the watcher's own exit reason, which it logs to stderr, is readable there.
WATCH_PID=
start_owned_watcher() {  # <home> <state> <fakebin> <arm-out>
  local home=$1 state=$2 fakebin=$3 armout=$4 i
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_CONFIRM_TIMEOUT=2 "$WATCH_ARM" > "$armout" 2>&1 &
  ARM_PID=$!
  i=0
  while [ "$i" -lt 100 ]; do
    grep -q '^watcher: started pid=' "$armout" 2>/dev/null && break
    is_live_non_zombie "$ARM_PID" || break
    sleep 0.1
    i=$((i + 1))
  done
  WATCH_PID=$(sed -n 's/^watcher: started pid=\([0-9][0-9]*\).*/\1/p' "$armout" | head -1)
  [ -n "$WATCH_PID" ] || fail "arm did not start a watcher: $(cat "$armout")"
}

# The watcher is the arm's child, not this shell's, so wait on liveness only.
wait_for_pid_gone() {  # <pid> <polls>
  local pid=$1 limit=$2 i=0
  while [ "$i" -lt "$limit" ]; do
    is_live_non_zombie "$pid" || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# A running watcher whose state directory is deleted (a torn-down temporary
# home) must exit after noticing the deletion with a logged reason, not run on
# as an orphan (upstream #4760). Allow for a slow CI runner finishing the cycle
# already in progress before its next FM_POLL=1 tick. A busy poll may spend
# longer than ten seconds in subprocesses on a contended CI runner.
test_watcher_exits_when_its_state_directory_is_removed() {
  local dir home state fakebin armout
  dir=$(make_case state-dir-removed)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  mkdir -p "$home/data"
  start_owned_watcher "$home" "$state" "$fakebin" "$armout"

  rm -rf "$state"
  wait_for_pid_gone "$WATCH_PID" 400 \
    || { kill -TERM "$WATCH_PID" 2>/dev/null; fail "watcher pid $WATCH_PID outlived its deleted state directory"; }
  wait_for_exit "$ARM_PID" 100 >/dev/null 2>&1 || true
  grep -qF 'watcher: exiting - state directory' "$armout" \
    || fail "watcher did not log the state-gone exit reason: $(cat "$armout")"
  ! grep -q '^signal:\|^check:\|^stale:\|^heartbeat' "$armout" \
    || fail "a state-gone exit was reported as an actionable wake: $(cat "$armout")"
  pass "watch-arm: a watcher exits when its state directory is removed"
}

# The same for a deleted home whose state directory still exists elsewhere: the
# lock is released through the ordinary cleanup so nothing stale is left behind.
test_watcher_exits_when_its_home_is_removed() {
  local dir home state fakebin armout
  dir=$(make_case home-removed)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  mkdir -p "$home/data"
  start_owned_watcher "$home" "$state" "$fakebin" "$armout"

  rm -rf "$home"
  wait_for_pid_gone "$WATCH_PID" 400 \
    || { kill -TERM "$WATCH_PID" 2>/dev/null; fail "watcher pid $WATCH_PID outlived its deleted home"; }
  wait_for_exit "$ARM_PID" 100 >/dev/null 2>&1 || true
  grep -qF 'watcher: exiting - home no longer exists' "$armout" \
    || fail "watcher did not log the home-gone exit reason: $(cat "$armout")"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" != "$WATCH_PID" ] \
    || fail "the exited watcher left its lock in place"
  pass "watch-arm: a watcher exits when its home is removed"
}

# tests/lib.sh's exit-time reaper must stop a watcher a suite armed for a
# temporary home, through the home-scoped stop, so no test leaves one behind.
# The reaper is driven with a private registry so this suite's own registry
# keeps covering the other cases.
test_reaper_stops_a_tracked_watcher() {
  local dir state fakebin out
  dir=$(make_case reaper)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  start_seed_watcher "$state" "$fakebin" "$out"
  printf '%s\n' "$state" > "$dir/registry"
  ( FM_TEST_WATCHER_REGISTRY="$dir/registry"; fm_test_reap_watchers )
  wait_for_exit "$SEED_PID" 100 >/dev/null 2>&1 || true
  ! is_live_non_zombie "$SEED_PID" \
    || { kill -TERM "$SEED_PID" 2>/dev/null; fail "reaper left the tracked watcher pid $SEED_PID running"; }
  [ ! -e "$dir/registry" ] || fail "reaper did not consume its registry"
  pass "watch-arm: the test reaper stops a watcher armed for a tracked temporary home"
}

# A handling-delivery confirmation for an episode the drain already
# acknowledged must succeed as a no-op when the generation matches: the pid is
# alive and holds the lock, so the handling is already retired, not rejected.
# A mismatched generation, a dead pid, and a lock mismatch stay rejections.
test_handling_delivered_accepts_already_acked_generation() {
  local dir home state pid identity generation status dead
  dir=$(make_case handling-delivered-acked)
  home="$dir/home"
  state="$dir/state"
  mkdir -p "$home/data" "$state/.watch.lock"
  sleep 60 &
  pid=$!
  identity=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid") \
    || fail "could not read the fixture watcher identity"
  printf '%s' "$home" > "$state/.watch.lock/fm-home"
  printf '%s' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s' "$identity" > "$state/.watch.lock/pid-identity"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_recovery_marker_publish "$2" downtime' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$state/.watcher-down" \
    || fail "could not publish the fixture downtime episode"
  generation=$(recovery_marker_generation "$state/.watcher-down")
  [ -n "$generation" ] || fail "published episode left no recovery generation"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WATCH_ARM" --handling-delivered "$generation" \
    --watcher-pid "$pid" || fail "confirmed prompt delivery did not begin handling"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_recovery_marker_ack "$2" "$3"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$state/.watcher-down" "$generation" \
    || fail "could not acknowledge the fixture handling episode"
  case "$(cat "$state/.watcher-down")" in
    acked:handling:"$generation") ;;
    *) fail "acknowledged episode did not retire: $(cat "$state/.watcher-down")" ;;
  esac
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WATCH_ARM" --handling-delivered "$generation" \
    --watcher-pid "$pid"
  expect_code 0 "$?" "an already-acknowledged confirmation must succeed as a no-op"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WATCH_ARM" --handling-delivered "superseded.0.deadbeef" \
    --watcher-pid "$pid" 2>/dev/null
  expect_code 3 "$?" "a superseded generation must stay rejected"
  sleep 0 &
  dead=$!
  wait "$dead" 2>/dev/null || true
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WATCH_ARM" --handling-delivered "$generation" \
    --watcher-pid "$dead" 2>/dev/null
  expect_code 1 "$?" "a dead watcher pid must stay rejected"
  printf 'foreign-identity\n' > "$state/.watch.lock/pid-identity"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WATCH_ARM" --handling-delivered "$generation" \
    --watcher-pid "$pid" 2>/dev/null
  status=$?
  printf '%s' "$identity" > "$state/.watch.lock/pid-identity"
  expect_code 1 "$status" "a lock mismatch must stay rejected"
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "watch-arm: an already-acknowledged handling confirmation succeeds as a no-op"
}

# A non-successor arm start mints a fresh generation, and a confirmation for
# the churned generation reports a mismatch (status 3). The closing arm check
# without a reopen - the marker step a handling successor runs - keeps the
# churned generation. This characterizes existing marker behavior that the Pi
# superseded-delivery path relies on.
test_handling_delivered_rejects_a_superseded_generation() {
  local dir home state pid identity first second status
  dir=$(make_case handling-delivered-superseded)
  home="$dir/home"
  state="$dir/state"
  mkdir -p "$home/data" "$state/.watch.lock"
  sleep 60 &
  pid=$!
  identity=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid") \
    || fail "could not read the fixture watcher identity"
  printf '%s' "$home" > "$state/.watch.lock/fm-home"
  printf '%s' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s' "$identity" > "$state/.watch.lock/pid-identity"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_recovery_marker_publish "$2" downtime && fm_recovery_marker_arm_check "$2"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$state/.watcher-down" \
    || fail "could not announce the fixture downtime episode"
  first=$(recovery_marker_generation "$state/.watcher-down")
  case "$(cat "$state/.watcher-down")" in
    announced:downtime:"$first") ;;
    *) fail "announced episode has the wrong shape: $(cat "$state/.watcher-down")" ;;
  esac
  # Reopening mints a fresh generation only when unrecovered work is queued:
  # an announced episode with an empty queue must survive untouched, so queue
  # one wake and re-announce first. Without this the reopen below is a no-op
  # by design (no idle churn) and the fresh-generation assertion below fails.
  append_wake "$state" check inbox:fixture 'check: manual-restart churn fixture' \
    || fail "could not queue the fixture wake for the manual restart"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_recovery_marker_arm_check "$2"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$state/.watcher-down" \
    || fail "could not re-announce the queued fixture episode"
  first=$(recovery_marker_generation "$state/.watcher-down")
  case "$(cat "$state/.watcher-down")" in
    announced:downtime:"$first") ;;
    *) fail "queued episode has the wrong shape: $(cat "$state/.watcher-down")" ;;
  esac
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_recovery_marker_reopen_announced "$2"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$state/.watcher-down" \
    || fail "a manual arm start could not reopen the announced episode"
  second=$(recovery_marker_generation "$state/.watcher-down")
  [ -n "$second" ] && [ "$second" != "$first" ] \
    || fail "a non-successor arm start did not mint a fresh generation: $(cat "$state/.watcher-down")"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WATCH_ARM" --handling-delivered "$first" \
    --watcher-pid "$pid" 2>/dev/null
  expect_code 3 "$?" "a confirmation for the churned generation must report a mismatch"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_recovery_marker_arm_check "$2"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$state/.watcher-down" \
    || fail "the arm check after the reopen could not run"
  status=$(recovery_marker_generation "$state/.watcher-down")
  [ "$status" = "$second" ] \
    || fail "an arm check without a reopen minted another generation: $(cat "$state/.watcher-down")"
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "watch-arm: a churned generation's handling confirmation reports a mismatch and an arm check keeps it"
}

# The OpenCode arm plugin must decide whether to arm with the shared supervision
# predicate (bin/fm-supervision-lib.sh's fm_supervision_needed), the same
# condition owner bin/fm-turnend-guard.sh decides with, so the plugin and the
# guard can never disagree about whether a watcher is needed. The fixture is a
# minimal primary root carrying the real shared predicate, a home whose state
# directory receives each case's records, and a fake arm that records its own
# run; the plugin is exercised through its public coordinator interface.
make_arm_decision_fixture() {  # <name>
  local name=$1 dir repo home
  dir=$(make_case "$name")
  repo="$dir/repo"
  home="$dir/home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q -b main "$repo"
  : > "$repo/AGENTS.md"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$repo/bin/fm-supervision-lib.sh"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  printf '%s\n' "$dir"
}

test_opencode_arm_plugin_decides_with_the_shared_predicate() {
  command -v node >/dev/null 2>&1 || { printf 'skip: node not found\n'; return 0; }
  local driver case_name dir state config out status
  driver="$TMP_ROOT/arm-decision-driver.mjs"
  cat > "$driver" <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const state = `${process.env.FM_HOME}/state`;
const config = `${process.env.FM_HOME}/config`;
const armLog = process.env.FM_ARM_LOG;

// The shared predicate verdict over the same state directory and the same lib
// copy the delegation in the plugin sources.
const probe = spawnSync(
  "bash",
  [
    "-c",
    '. "$1/bin/fm-supervision-lib.sh"; if fm_supervision_needed "$2"; then printf arm; else printf no-arm; fi',
    "predicate-probe",
    process.env.FM_ROOT_OVERRIDE,
    state,
  ],
  { encoding: "utf8" },
);
const verdict = String(probe.stdout || "").trim();
if (verdict !== "arm" && verdict !== "no-arm") {
  console.error(`predicate probe failed (status ${probe.status}): ${probe.stderr}`);
  process.exit(1);
}

// The two local overrides: an away record declines even when the predicate
// reads needed, because away mode owns supervision through its daemon, and an
// x-mode home arms before its relay poll is registered. Every other state
// directory must match the shared verdict exactly.
let expected;
if (existsSync(`${state}/.afk`)) {
  if (verdict !== "arm") {
    console.error(`afk fixture lost its registered need: predicate said ${verdict}`);
    process.exit(1);
  }
  expected = "no-arm";
} else if (existsSync(`${config}/x-mode.env`)) {
  if (verdict !== "no-arm") {
    console.error(`x-mode fixture unexpectedly reads as needed: predicate said ${verdict}`);
    process.exit(1);
  }
  expected = "arm";
} else {
  expected = verdict;
}

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
await mod.FmPrimaryWatchArm({ client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE });
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const status = await globalThis.__firstmateOpenCodeWatchArm.ensureArmed("session-test", client);
if (expected === "no-arm") {
  if (status !== "not-needed") {
    console.error(`expected a not-needed decline, got ${status}`);
    process.exit(1);
  }
  if (existsSync(armLog)) {
    console.error("the plugin declined but the arm ran");
    process.exit(1);
  }
  process.exit(0);
}
for (let i = 0; i < 250 && !existsSync(armLog); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(armLog)) {
  console.error(`the arm never ran (ensureArmed status ${status})`);
  process.exit(1);
}
process.exit(0);
EOF
  for case_name in source registered-check empty afk-with-source task-meta x-mode; do
    dir=$(make_arm_decision_fixture "opencode-arm-$case_name")
    state="$dir/home/state"
    config="$dir/home/config"
    case "$case_name" in
      source) mkdir -p "$state/procevent"; : > "$state/procevent/fixture.source" ;;
      registered-check) : > "$state/fixture.check.sh"; : > "$state/fixture.check-trust" ;;
      empty) : ;;
      afk-with-source)
        mkdir -p "$state/procevent"
        : > "$state/procevent/fixture.source"
        : > "$state/.afk"
        ;;
      task-meta) : > "$state/fixture.meta" ;;
      x-mode) : > "$config/x-mode.env" ;;
    esac
    out=$(FM_ROOT_OVERRIDE="$dir/repo" WORKTREE="$dir/repo" FM_HOME="$dir/home" \
      FM_ARM_LOG="$dir/arm.log" NODE_NO_WARNINGS=1 \
      PLUGIN="$ROOT/.opencode/plugins/fm-primary-watch-arm.js" node "$driver" 2>&1)
    status=$?
    expect_code 0 "$status" "OpenCode arm plugin must decide with the shared predicate ($case_name): $out"
    [ -z "$out" ] || fail "OpenCode arm predicate case $case_name printed output: $out"
  done
  pass "watch-arm: the OpenCode arm plugin decides with the shared supervision predicate"
}

test_attached_arm_reports_the_delivered_wake
test_attached_arm_reports_the_delivered_wake_after_drain
test_arm_refuses_an_unusable_launch_confirm_window
test_arm_refuses_a_disposable_validation_checkout
test_watcher_exits_when_its_state_directory_is_removed
test_watcher_exits_when_its_home_is_removed
test_reaper_stops_a_tracked_watcher
test_attached_arm_still_fails_on_a_wake_it_did_not_deliver
test_attached_arm_follows_a_slow_live_holder
test_attached_arm_hands_a_stalled_holder_to_its_replacement
test_rearm_resurfaces_durable_queue_and_remote_open_decision
test_slow_rearm_recovery_is_still_surfaced
test_marker_publish_failure_retains_recovery_evidence
test_delivery_gap_wake_is_recovered_once
test_interrupted_handling_is_redrained_on_rearm
test_malformed_marker_is_quarantined_once
test_recovery_consumption_serializes_queue_publication
test_restart_preserves_recovery_across_reused_pid_lock
test_markerless_legacy_queue_is_recovered_on_arm
test_idle_lavish_source_stays_quiet_until_result
test_append_wakes_live_announced_watcher
test_handling_window_close_keeps_the_acknowledgement_valid
test_moved_generation_acknowledgement_is_self_healing
test_downtime_marker_does_not_follow_symlink
test_stop_ends_the_home_watcher_and_publishes_downtime
test_handling_delivered_accepts_already_acked_generation
test_handling_delivered_rejects_a_superseded_generation
test_take_over_attaches_to_a_cycle_the_named_arm_does_not_own
test_take_over_owns_a_fresh_cycle_and_keeps_queued_work_surfacing
test_take_over_preserves_downtime_from_watcher_self_exit
test_take_over_restores_a_stop_whose_term_lands_late
test_opencode_arm_plugin_decides_with_the_shared_predicate
