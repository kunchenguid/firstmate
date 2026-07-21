#!/usr/bin/env bash
# Behavior tests for the per-home firstmate session lock release command.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOCK_SCRIPT="$ROOT/bin/fm-lock.sh"
TMP_ROOT=$(fm_test_tmproot fm-lock)
HOME_DIR="$TMP_ROOT/home"
STATE_DIR="$HOME_DIR/state"
LOCK_FILE="$STATE_DIR/.lock"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
BACKGROUND_PIDS=()

cleanup() {
  local pid
  for pid in "${BACKGROUND_PIDS[@]:-}"; do
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  rm -rf "$TMP_ROOT"
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

run_lock() {
  FM_HOME="$HOME_DIR" \
    FM_TEST_HARNESS_PID="$$" \
    FM_TEST_OTHER_PID="${FM_TEST_OTHER_PID:-}" \
    PATH="$FAKEBIN:$PATH" \
    "$LOCK_SCRIPT" "$@"
}

start_sleeper() {
  sleep 60 &
  STARTED_PID=$!
  BACKGROUND_PIDS+=("$STARTED_PID")
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

test_release_absent_lock
test_release_own_lock
test_release_stale_lock
test_release_refuses_live_other
test_force_release_live_other
test_unknown_subcommand_rejected
