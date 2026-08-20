#!/usr/bin/env bash
# tests/fm-captain-report-timer.test.sh - the repeating captain-report timer
# behind the `updatethecaptain` skill (bin/fm-captain-report-timer.sh).
#
# The timer has no daemon of its own: it is an authenticated custom check that
# the existing watcher dispatches. So the contract worth pinning is the one a
# report loop actually depends on - it stays silent before its interval, it
# produces exactly one line per elapsed interval, re-arming resets the wait, a
# tampered check stops being trusted, and a due timer really does reach the
# durable wake queue through a real bin/fm-watch.sh rather than only through
# this suite's own idea of what the watcher does.
#
# The last case drives a real watcher subprocess for that reason; every other
# case runs the generated check directly, exactly as the watcher runs it.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"

TIMER="$ROOT/bin/fm-captain-report-timer.sh"
WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-captain-report-timer-tests)

# A home with only a state directory: the timer needs nothing else.
make_home() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state"
  printf '%s\n' "$dir"
}

timer() {  # <state> <args...>
  local state=$1
  shift
  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$TIMER" "$@"
}

# Run the generated check the way the watcher does: `bash <file>`, capturing
# only stdout, since stdout alone is what becomes a wake.
run_check() {  # <state>
  bash "$1/captain-report.check.sh" 2>/dev/null
}

# Backdate the stamp by <seconds> so an interval can elapse without waiting.
age_stamp() {  # <state> <seconds>
  local state=$1 seconds=$2 last
  last=$(cat "$state/.captain-report-timer") || return 1
  printf '%s\n' "$((last - seconds))" > "$state/.captain-report-timer"
}

test_arm_publishes_a_registered_check() {
  local dir state out
  dir=$(make_home arm); state="$dir/state"
  out=$(timer "$state" arm --interval 60) || fail "arm failed"
  assert_contains "$out" "armed: state/captain-report.check.sh interval=60s" \
    "arm did not confirm the armed interval"
  assert_present "$state/captain-report.check.sh" "arm did not publish the timer check"
  assert_present "$state/captain-report.check-trust" "arm did not bind the timer check"
  assert_present "$state/.captain-report-timer" "arm did not publish the timer stamp"
  [ "$(fm_pr_file_mode "$state/captain-report.check.sh")" = 700 ] \
    || fail "the timer check is not mode 0700, so the watcher will reject it"
  pass "arm publishes a registered, watcher-dispatchable timer check"
}

test_status_reports_the_armed_cadence_then_disarm() {
  local dir state out due
  dir=$(make_home status); state="$dir/state"
  out=$(timer "$state" status) || fail "status failed before arming"
  assert_contains "$out" "not armed" "status did not report an unarmed timer"
  timer "$state" arm --interval 120 >/dev/null || fail "arm failed"
  out=$(timer "$state" status) || fail "status failed while armed"
  assert_contains "$out" "armed interval=120s" "status did not report the armed interval"
  due=$(printf '%s\n' "$out" | sed -n 's/.*due-in=\([0-9][0-9]*\)s.*/\1/p')
  [ -n "$due" ] || fail "status did not report a remaining wait at all: $out"
  # A freshly armed timer owes very nearly a whole interval; the exact second
  # depends on how long arm and status took, so bound it rather than pin it.
  { [ "$due" -gt 110 ] && [ "$due" -le 120 ]; } \
    || fail "status reported an implausible remaining wait of ${due}s for a fresh 120s timer"
  out=$(timer "$state" disarm) || fail "disarm failed"
  assert_contains "$out" "disarmed" "disarm did not confirm removal"
  assert_absent "$state/captain-report.check.sh" "disarm left the timer check behind"
  assert_absent "$state/captain-report.check-trust" "disarm left the trust binding behind"
  assert_absent "$state/.captain-report-timer" "disarm left the stamp behind"
  out=$(timer "$state" status) || fail "status failed after disarming"
  assert_contains "$out" "not armed" "status did not report the timer as gone"
  pass "status reports the armed cadence and disarm removes every artifact"
}

test_disarm_is_harmless_when_nothing_is_armed() {
  local dir state out code=0
  dir=$(make_home disarm-idle); state="$dir/state"
  out=$(timer "$state" disarm) || code=$?
  expect_code 0 "$code" "disarm with no timer armed"
  assert_contains "$out" "not armed" "disarm did not say plainly that no loop was running"
  out=$(timer "$state" disarm) || fail "a repeat disarm failed"
  assert_contains "$out" "not armed" "a repeat disarm did not stay harmless"
  pass "disarm is harmless and idempotent when no report loop is running"
}

test_timer_is_silent_before_its_interval() {
  local dir state out
  dir=$(make_home silent); state="$dir/state"
  timer "$state" arm --interval 600 >/dev/null || fail "arm failed"
  out=$(run_check "$state")
  [ -z "$out" ] || fail "the timer printed before its interval elapsed: $out"
  age_stamp "$state" 599 || fail "could not age the stamp"
  out=$(run_check "$state")
  [ -z "$out" ] || fail "the timer printed one second early: $out"
  pass "the timer prints nothing until its full interval has elapsed"
}

test_elapsed_interval_produces_exactly_one_line() {
  local dir state first second
  dir=$(make_home one-line); state="$dir/state"
  timer "$state" arm --interval 600 >/dev/null || fail "arm failed"
  age_stamp "$state" 601 || fail "could not age the stamp"
  first=$(run_check "$state")
  assert_contains "$first" "captain report due" "an elapsed interval did not wake firstmate"
  [ "$(printf '%s\n' "$first" | wc -l | tr -d ' ')" = 1 ] \
    || fail "the timer printed more than one line: $first"
  second=$(run_check "$state")
  [ -z "$second" ] || fail "the timer repeated its line without a fresh interval: $second"
  age_stamp "$state" 601 || fail "could not age the stamp again"
  second=$(run_check "$state")
  assert_contains "$second" "captain report due" "the second interval did not wake firstmate"
  pass "each elapsed interval produces exactly one wake line"
}

test_rearming_restarts_the_wait() {
  local dir state out
  dir=$(make_home rearm); state="$dir/state"
  timer "$state" arm --interval 600 >/dev/null || fail "arm failed"
  age_stamp "$state" 601 || fail "could not age the stamp"
  timer "$state" arm --interval 600 >/dev/null || fail "re-arm failed"
  out=$(run_check "$state")
  [ -z "$out" ] || fail "re-arming did not restart the wait: $out"
  out=$(timer "$state" status) || fail "status failed after re-arming"
  assert_contains "$out" "armed interval=600s" "re-arming lost the interval"
  pass "re-arming restarts the wait so an immediate report is not repeated"
}

test_rearming_at_a_new_interval_is_what_the_watcher_runs() {
  local dir state out
  dir=$(make_home reinterval); state="$dir/state"
  timer "$state" arm --interval 600 >/dev/null || fail "arm failed"
  timer "$state" arm --interval 60 >/dev/null || fail "re-arm at a new interval failed"
  out=$(timer "$state" status) || fail "status failed after the new interval"
  assert_contains "$out" "armed interval=60s" "status reported a cadence the check does not run"
  age_stamp "$state" 61 || fail "could not age the stamp"
  out=$(run_check "$state")
  assert_contains "$out" "captain report due" "the new interval was not the one actually armed"
  pass "re-arming at a new interval rewrites the check the watcher actually runs"
}

test_invalid_interval_is_refused_without_arming() {
  local dir state code=0 out
  dir=$(make_home bad-interval); state="$dir/state"
  out=$(timer "$state" arm --interval 5 2>&1) || code=$?
  [ "$code" -ne 0 ] || fail "an interval below the floor was accepted"
  assert_contains "$out" "--interval" "the refusal did not name the offending option"
  code=0
  out=$(timer "$state" arm --interval later 2>&1) || code=$?
  [ "$code" -ne 0 ] || fail "a non-numeric interval was accepted"
  assert_absent "$state/captain-report.check.sh" "a refused arm still published a check"
  assert_absent "$state/.captain-report-timer" "a refused arm still published a stamp"
  pass "an out-of-range or non-numeric interval is refused without arming anything"
}

test_tampered_check_stops_being_trusted() {
  local dir state out
  dir=$(make_home tampered); state="$dir/state"
  timer "$state" arm --interval 60 >/dev/null || fail "arm failed"
  printf 'printf "tampered\\n"\n' >> "$state/captain-report.check.sh"
  out=$(timer "$state" status) || fail "status failed on a tampered check"
  assert_contains "$out" "not armed" "a tampered timer check still reported as armed"
  pass "a timer check whose bytes changed is no longer trusted or reported as armed"
}

test_missing_stamp_leaves_the_check_silent() {
  local dir state out
  dir=$(make_home no-stamp); state="$dir/state"
  timer "$state" arm --interval 60 >/dev/null || fail "arm failed"
  rm -f "$state/.captain-report-timer"
  out=$(run_check "$state")
  [ -z "$out" ] || fail "the check spoke with no stamp to measure against: $out"
  pass "a timer check with no stamp stays silent instead of waking on every sweep"
}

test_legacy_pr_check_migration_keeps_the_timer_armed() {
  local dir state
  dir=$(make_home migration); state="$dir/state"
  timer "$state" arm --interval 60 >/dev/null || fail "arm failed"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-pr-check-migrate.sh" >/dev/null 2>&1 \
    || fail "the legacy PR-check migration failed on a home with an armed timer"
  assert_present "$state/captain-report.check.sh" "the migration quarantined the armed timer check"
  assert_absent "$state/.pr-check-quarantine/captain-report.check.sh" \
    "the migration moved the armed timer check into quarantine"
  pass "the legacy PR-check migration leaves a registered timer check armed"
}

# Start a real watcher over <state> with a tight poll and check cadence, and no
# heartbeat, so the only thing it can wake for is the due timer.
watch_bg() {  # <state> <fakebin> <out>
  local state=$1 fakebin=$2 out=$3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
}

# End-to-end: a due timer must reach the durable wake queue through a real
# watcher, not just print when this suite runs it by hand.
test_due_timer_surfaces_as_a_check_wake() {
  local dir state fakebin out drain_out pid
  dir=$(make_case due-timer); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$TIMER" arm --interval 60 >/dev/null \
    || fail "arm failed"
  age_stamp "$state" 61 || fail "could not age the stamp"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "the watcher did not exit for a due captain-report timer"
  grep -F "captain report due" "$out" >/dev/null \
    || fail "the watcher did not print the due timer as a wake reason"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "the drain after the due timer failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "captain-report.check.sh" >/dev/null \
    || fail "the due timer was not durably queued as a check wake"
  [ -z "$(run_check "$state")" ] \
    || fail "the watcher's run did not advance the stamp, so the next sweep would repeat the wake"
  pass "a due timer reaches the durable wake queue through a real watcher, once"
}

test_arm_publishes_a_registered_check
test_status_reports_the_armed_cadence_then_disarm
test_disarm_is_harmless_when_nothing_is_armed
test_timer_is_silent_before_its_interval
test_elapsed_interval_produces_exactly_one_line
test_rearming_restarts_the_wait
test_rearming_at_a_new_interval_is_what_the_watcher_runs
test_invalid_interval_is_refused_without_arming
test_tampered_check_stops_being_trusted
test_missing_stamp_leaves_the_check_silent
test_legacy_pr_check_migration_keeps_the_timer_armed
test_due_timer_surfaces_as_a_check_wake
