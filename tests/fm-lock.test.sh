#!/usr/bin/env bash
# Behavior tests for the per-home firstmate session lock release command.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOCK_SCRIPT="$ROOT/bin/fm-lock.sh"
TMP_ROOT=$(fm_test_tmproot fm-lock)
# fm_test_tmproot ran in a command substitution, so its registration and EXIT
# trap died with that subshell. Re-register here so the trap below can hand
# teardown to fm_test_cleanup, which owns every registered dir.
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
HOME_DIR="$TMP_ROOT/home"
STATE_DIR="$HOME_DIR/state"
LOCK_FILE="$STATE_DIR/.lock"
SENTINEL_LOCK="$TMP_ROOT/sentinel.lock"
SENTINEL_PID=424242
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
BLOCKED_FAKEBIN=$(fm_fakebin "$TMP_ROOT/blocked")
BACKGROUND_PIDS=()

cleanup() {
  local pid
  for pid in "${BACKGROUND_PIDS[@]:-}"; do
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  fm_test_cleanup
  return 0
}
trap cleanup EXIT

mkdir -p "$STATE_DIR"

cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
set -u

pid=${*: -1}
case "$*" in
  *"comm="*)
    if [ "$pid" = "${FM_TEST_HARNESS_PID:-}" ] || [ "$pid" = "${FM_TEST_OTHER_PID:-}" ]; then
      printf '%s\n' '/usr/local/bin/codex'
    else
      printf '%s\n' '/bin/bash'
    fi
    ;;
  *"args="*)
    if [ "$pid" = "${FM_TEST_HARNESS_PID:-}" ] || [ "$pid" = "${FM_TEST_OTHER_PID:-}" ]; then
      printf '%s\n' 'codex'
    else
      printf '%s\n' 'bash'
    fi
    ;;
  *"ppid="*) printf '%s\n' "${FM_TEST_HARNESS_PID:-1}" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/ps"

cat > "$BLOCKED_FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'ps: Operation not permitted' >&2
exit 1
SH
chmod +x "$BLOCKED_FAKEBIN/ps"

run_lock() {
  FM_HOME="$HOME_DIR" \
    FM_TEST_HARNESS_PID="$$" \
    FM_TEST_OTHER_PID="${FM_TEST_OTHER_PID:-}" \
    PATH="$FAKEBIN:$PATH" \
    "$LOCK_SCRIPT" "$@"
}

run_blocked_lock() {
  FM_HOME="$HOME_DIR" \
    CODEX_SANDBOX=seatbelt \
    PATH="$BLOCKED_FAKEBIN:$PATH" \
    "$LOCK_SCRIPT" "$@"
}

start_sleeper() {
  sleep 60 &
  STARTED_PID=$!
  BACKGROUND_PIDS+=("$STARTED_PID")
}

# Reap a background child so its pid is genuinely gone: the `kill -0` half of
# holder_alive must fail, not just the harness-name half start_sleeper exercises.
# The child must exit on its own - signalling a just-forked job can land before
# it execs, and the still-bash child then runs this file's inherited EXIT trap.
start_reaped() {
  sleep 0 &
  STARTED_PID=$!
  wait "$STARTED_PID" 2>/dev/null || true
}

# Drive one malformed argument shape against a pre-seeded foreign lock and
# assert the parser refuses it before any lock file byte moves.
assert_rejected_without_mutation() {
  local label=$1 out status
  shift
  printf '%s\n' "$SENTINEL_PID" > "$LOCK_FILE"
  cp "$LOCK_FILE" "$SENTINEL_LOCK"
  out=$(run_lock "$@" 2>&1)
  status=$?
  expect_code 2 "$status" "$label"
  assert_contains "$out" "invalid fm-lock arguments" "$label did not report invalid arguments"
  assert_contains "$out" "Usage: fm-lock.sh" "$label did not print usage"
  cmp -s "$SENTINEL_LOCK" "$LOCK_FILE" || fail "$label mutated the session lock file"
}

test_release_absent_lock() {
  local out status
  rm -f "$LOCK_FILE"
  out=$(run_lock release 2>&1)
  status=$?
  expect_code 0 "$status" "absent lock release"
  assert_contains "$out" "lock already free" "absent lock release did not report idempotent success"
  assert_absent "$LOCK_FILE" "absent lock release created a lock"
  pass "release is idempotent when the session lock is absent"
}

test_release_own_lock() {
  local out status
  rm -f "$LOCK_FILE"
  run_lock >/dev/null
  [ "$(cat "$LOCK_FILE")" = "$$" ] || fail "acquire fixture did not record the test harness pid"
  out=$(run_lock release 2>&1)
  status=$?
  expect_code 0 "$status" "own lock release"
  assert_contains "$out" "released" "own lock release did not report success"
  assert_contains "$out" "$$" "own lock release did not name the released pid"
  assert_absent "$LOCK_FILE" "own lock release left the lock file behind"
  pass "release removes this session's harness lock"
}

test_release_stale_lock() {
  local out status stale_pid
  start_sleeper
  stale_pid=$STARTED_PID
  printf '%s\n' "$stale_pid" > "$LOCK_FILE"
  out=$(run_lock release 2>&1)
  status=$?
  expect_code 0 "$status" "stale lock release"
  assert_contains "$out" "stale lock" "stale lock release did not identify the stale lock"
  assert_contains "$out" "$stale_pid" "stale lock release did not name the cleared pid"
  assert_absent "$LOCK_FILE" "stale lock release left the lock file behind"
  pass "release clears a live non-harness pid as stale"
}

# The reaped pid is presented to the fake ps as a harness, so the name half of
# holder_alive passes and only its `kill -0` liveness half can call this stale.
test_release_dead_pid_lock() {
  local out status dead_pid
  start_reaped
  dead_pid=$STARTED_PID
  printf '%s\n' "$dead_pid" > "$LOCK_FILE"
  out=$(FM_TEST_OTHER_PID="$dead_pid" run_lock release 2>&1)
  status=$?
  expect_code 0 "$status" "dead-pid lock release"
  assert_contains "$out" "stale lock" "dead-pid release did not identify the stale lock"
  assert_contains "$out" "$dead_pid" "dead-pid release did not name the cleared pid"
  assert_absent "$LOCK_FILE" "dead-pid release left the lock file behind"
  pass "release clears a reaped dead pid as stale"
}

test_release_refuses_live_other() {
  local out status other_pid snapshot stderr_file
  start_sleeper
  other_pid=$STARTED_PID
  snapshot="$TMP_ROOT/live-other.lock"
  stderr_file="$TMP_ROOT/live-other.stderr"
  printf '%s\n' "$other_pid" > "$LOCK_FILE"
  cp "$LOCK_FILE" "$snapshot"
  FM_TEST_OTHER_PID="$other_pid" run_lock release >"$TMP_ROOT/live-other.stdout" 2>"$stderr_file"
  status=$?
  out=$(cat "$stderr_file")
  expect_code 1 "$status" "live-other release refusal"
  assert_contains "$out" "$other_pid" "live-other refusal did not name the holder pid"
  assert_contains "$out" "--force" "live-other refusal did not provide the force hint"
  cmp -s "$snapshot" "$LOCK_FILE" || fail "live-other refusal changed the lock file bytes"
  pass "release refuses a different live harness and preserves the lock byte-for-byte"
}

test_force_release_live_other() {
  local out status other_pid stderr_file
  start_sleeper
  other_pid=$STARTED_PID
  stderr_file="$TMP_ROOT/force.stderr"
  printf '%s\n' "$other_pid" > "$LOCK_FILE"
  FM_TEST_OTHER_PID="$other_pid" run_lock release --force >"$TMP_ROOT/force.stdout" 2>"$stderr_file"
  status=$?
  out=$(cat "$stderr_file")
  expect_code 0 "$status" "forced live-other release"
  assert_contains "$out" "$other_pid" "forced release did not name the displaced holder pid"
  assert_contains "$out" "forced" "forced release did not report a loud forced action"
  assert_absent "$LOCK_FILE" "forced release left the lock file behind"
  pass "release --force clears a different live harness lock"
}

test_blocked_inspection_refuses_acquire() {
  local out status
  rm -f "$LOCK_FILE"
  out=$(run_blocked_lock 2>&1)
  status=$?
  expect_code 1 "$status" "blocked-inspection acquire"
  assert_contains "$out" "process inspection is blocked" "blocked acquire hid the shell sandbox cause"
  assert_contains "$out" "CODEX_SANDBOX=seatbelt" "blocked acquire omitted the present Codex sandbox marker"
  assert_contains "$out" "codex --dangerously-bypass-approvals-and-sandbox" "blocked acquire omitted the actionable Codex remedy"
  assert_absent "$LOCK_FILE" "blocked acquire created a session lock"
  pass "acquire refuses with the actionable Codex sandbox cause when process inspection is blocked"
}

test_blocked_inspection_status_never_reports_stale() {
  local out status
  printf '%s\n' "$SENTINEL_PID" > "$LOCK_FILE"
  out=$(run_blocked_lock status 2>&1)
  status=$?
  expect_code 0 "$status" "blocked-inspection status"
  assert_contains "$out" "liveness cannot be evaluated from this session" "blocked status did not report unknown liveness"
  assert_not_contains "$out" "stale" "blocked status falsely classified the lock as stale"
  [ "$(cat "$LOCK_FILE")" = "$SENTINEL_PID" ] || fail "blocked status changed the lock"
  pass "status reports unknown liveness and never stale when process inspection is blocked"
}

test_blocked_inspection_refuses_nonforced_release() {
  local out status snapshot
  snapshot="$TMP_ROOT/blocked-release.lock"
  printf '%s\n' "$SENTINEL_PID" > "$LOCK_FILE"
  cp "$LOCK_FILE" "$snapshot"
  out=$(run_blocked_lock release 2>&1)
  status=$?
  expect_code 1 "$status" "blocked-inspection release"
  assert_contains "$out" "process inspection is blocked" "blocked release hid the shell sandbox cause"
  assert_contains "$out" "codex --dangerously-bypass-approvals-and-sandbox" "blocked release omitted the actionable Codex remedy"
  cmp -s "$snapshot" "$LOCK_FILE" || fail "blocked non-forced release changed the lock file bytes"
  pass "non-forced release preserves the lock when process inspection is blocked"
}

test_blocked_inspection_force_release_still_works() {
  local out status
  printf '%s\n' "$SENTINEL_PID" > "$LOCK_FILE"
  out=$(run_blocked_lock release --force 2>&1)
  status=$?
  expect_code 0 "$status" "blocked-inspection forced release"
  assert_contains "$out" "forced" "blocked forced release did not report the explicit override"
  assert_absent "$LOCK_FILE" "blocked forced release left the lock file behind"
  pass "release --force remains an explicit override when process inspection is blocked"
}

test_working_inspection_status_remains_live() {
  local out status
  printf '%s\n' "$$" > "$LOCK_FILE"
  out=$(run_lock status 2>&1)
  status=$?
  expect_code 0 "$status" "working-inspection status"
  assert_contains "$out" "held by live harness pid $$" "working process inspection no longer reports a live holder"
  pass "working process inspection keeps the existing live-holder behavior"
}

test_acquire_fails_closed_on_unwritable_state() {
  local out status
  rm -f "$LOCK_FILE"
  chmod u-w "$STATE_DIR"
  out=$(run_lock 2>&1)
  status=$?
  chmod u+w "$STATE_DIR"
  expect_code 1 "$status" "unwritable-state acquire"
  assert_contains "$out" "cannot write session lock" "failed lock write did not report the cause"
  assert_not_contains "$out" "lock acquired" "failed lock write still reported success"
  assert_absent "$LOCK_FILE" "failed lock write left a lock file behind"
  pass "acquire fails closed when the lock file cannot be written"
}

test_release_fails_closed_on_unremovable_lock() {
  local out status
  printf '%s\n' "$$" > "$LOCK_FILE"
  chmod u-w "$STATE_DIR"
  out=$(run_lock release 2>&1)
  status=$?
  chmod u+w "$STATE_DIR"
  expect_code 1 "$status" "unremovable-lock release"
  assert_contains "$out" "cannot remove session lock" "failed lock removal did not report the cause"
  assert_not_contains "$out" "lock released" "failed lock removal still reported success"
  assert_present "$LOCK_FILE" "failed lock removal deleted the lock anyway"
  rm -f "$LOCK_FILE"
  pass "release fails closed when the lock file cannot be removed"
}

test_unknown_subcommand_rejected() {
  local out status
  rm -f "$LOCK_FILE"
  out=$(run_lock relase 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unknown subcommand unexpectedly succeeded"
  assert_contains "$out" "unknown" "unknown subcommand rejection was not explicit"
  assert_contains "$out" "relase" "unknown subcommand rejection did not echo the bad command"
  assert_absent "$LOCK_FILE" "unknown subcommand acquired the session lock"
  pass "unknown subcommands fail loudly without acquiring the lock"
}

test_invalid_argument_shapes_rejected() {
  assert_rejected_without_mutation "status with a stray flag" status --force
  assert_rejected_without_mutation "release with a misspelled flag" release --frce
  assert_rejected_without_mutation "flag before the subcommand" --force release
  assert_rejected_without_mutation "too many arguments" release --force extra
  rm -f "$LOCK_FILE"
  pass "invalid argument shapes exit 2 with usage and leave the lock untouched"
}

test_release_absent_lock
test_release_own_lock
test_release_stale_lock
test_release_dead_pid_lock
test_release_refuses_live_other
test_force_release_live_other
test_blocked_inspection_refuses_acquire
test_blocked_inspection_status_never_reports_stale
test_blocked_inspection_refuses_nonforced_release
test_blocked_inspection_force_release_still_works
test_working_inspection_status_remains_live
test_acquire_fails_closed_on_unwritable_state
test_release_fails_closed_on_unremovable_lock
test_unknown_subcommand_rejected
test_invalid_argument_shapes_rejected
