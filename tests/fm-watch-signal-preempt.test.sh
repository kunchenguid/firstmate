#!/usr/bin/env bash
# A pending status signal pre-empts the watcher's per-cycle maintenance, within
# a bound, through the real watcher process.
# No endpoint, harness process, model call, or remote host is needed.
#
# Maintenance (the reminder ticks and the slow-check sweep) runs ahead of the
# signal scan so a chatty fleet cannot starve it. That order made every status
# line wait for the whole pass. These tests pin the two halves of the repair:
#   1. With a recent complete maintenance pass on record, a pending signal
#      surfaces before a due slow check runs at all.
#   2. Without one - never recorded, older than FM_MAINTENANCE_DEFER_MAX, or
#      with pre-emption switched off - the slow check still goes first, so
#      maintenance cannot be starved.
#   3. A quiet cycle records its complete pass, which is what arms 1.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-signal-preempt)

# A home with one pending captain-relevant status line and one due slow check
# that leaves a trace when it runs.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf 'done: synthetic wake\n' > "$home/state/demo.status"
  cat > "$home/state/slow.check.sh" <<SH
#!/usr/bin/env bash
: > "$home/check-ran"
printf 'slow check fired\n'
SH
  chmod 0700 "$home/state/slow.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" slow >/dev/null \
    || fail "could not register the slow check"
  printf '%s\n' "$home"
}

run_cycle() {  # <home> [extra env assignments...]
  local home=$1
  shift
  CYCLE_STATUS=0
  env FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 "$@" \
    "$CHECKPOINT" --seconds 12 >"$home/out.txt" 2>"$home/err.txt" || CYCLE_STATUS=$?
}

test_recent_pass_lets_a_signal_go_first() {
  local home
  home=$(make_home recent)
  touch "$home/state/.last-maintenance-pass"
  run_cycle "$home"
  expect_code 0 "$CYCLE_STATUS" "pre-empting cycle exit: $(cat "$home/err.txt")"
  assert_contains "$(cat "$home/out.txt")" "signal:" "the pending signal did not surface first"
  assert_not_contains "$(cat "$home/out.txt")" "check:" "the slow check surfaced ahead of the signal"
  assert_absent "$home/check-ran" "the slow check ran before the pending signal surfaced"
  pass "a pending signal surfaces before a due slow check when a recent pass is on record"
}

test_no_recorded_pass_runs_maintenance_first() {
  local home
  home=$(make_home unrecorded)
  run_cycle "$home"
  expect_code 0 "$CYCLE_STATUS" "unrecorded-pass cycle exit: $(cat "$home/err.txt")"
  assert_contains "$(cat "$home/out.txt")" "check:" "the slow check did not go first with no pass on record"
  assert_present "$home/check-ran" "the slow check never ran"
  pass "with no complete pass on record the slow check runs before the signal"
}

test_overdue_pass_runs_maintenance_first() {
  local home
  home=$(make_home overdue)
  touch -t 200001010000 "$home/state/.last-maintenance-pass"
  run_cycle "$home"
  expect_code 0 "$CYCLE_STATUS" "overdue-pass cycle exit: $(cat "$home/err.txt")"
  assert_contains "$(cat "$home/out.txt")" "check:" "an overdue pass let the signal starve the slow check"
  assert_present "$home/check-ran" "the slow check never ran"
  pass "a pass older than the bound runs the slow check before the signal"
}

test_zero_bound_disables_preemption() {
  local home
  home=$(make_home disabled)
  touch "$home/state/.last-maintenance-pass"
  run_cycle "$home" FM_MAINTENANCE_DEFER_MAX=0
  expect_code 0 "$CYCLE_STATUS" "disabled cycle exit: $(cat "$home/err.txt")"
  assert_contains "$(cat "$home/out.txt")" "check:" "a zero bound still let the signal go first"
  assert_present "$home/check-ran" "the slow check never ran"
  pass "FM_MAINTENANCE_DEFER_MAX=0 keeps the slow check ahead of the signal"
}

test_quiet_cycle_records_its_pass() {
  local home="$TMP_ROOT/quiet" status=0
  mkdir -p "$home/state" "$home/data" "$home/config"
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$CHECKPOINT" --seconds 2 >"$home/out.txt" 2>"$home/err.txt" || status=$?
  expect_code 124 "$status" "quiet cycle exit: $(cat "$home/err.txt")"
  assert_present "$home/state/.last-maintenance-pass" "a quiet cycle did not record its complete pass"
  pass "a quiet cycle records its complete maintenance pass"
}

test_recent_pass_lets_a_signal_go_first
test_no_recorded_pass_runs_maintenance_first
test_overdue_pass_runs_maintenance_first
test_zero_bound_disables_preemption
test_quiet_cycle_records_its_pass
