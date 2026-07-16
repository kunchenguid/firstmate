#!/usr/bin/env bash
# Subprocess tests for the per-home firstmate session lock owner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock)
LOCK_SCRIPT="$ROOT/bin/fm-lock.sh"
LIVE_PIDS=()

cleanup() {
  local pid
  for pid in "${LIVE_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup EXIT

start_live_process() {
  sleep 300 &
  LIVE_PID=$!
  LIVE_PIDS+=("$LIVE_PID")
}

install_fake_ps() {
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
pid=
previous=
for argument in "$@"; do
  if [ "$previous" = "-p" ]; then
    pid=$argument
    break
  fi
  previous=$argument
done

comm_for_pid() {
  if [ "$1" = "${FM_FAKE_ME_PID:-}" ]; then
    printf '%s\n' "${FM_FAKE_ME_COMM:-/usr/local/bin/pi}"
  elif [ "$1" = "${FM_FAKE_OTHER_PID:-}" ]; then
    printf '%s\n' "${FM_FAKE_OTHER_COMM:-/usr/local/bin/pi}"
  else
    printf '/bin/bash\n'
  fi
}

args_for_pid() {
  if [ "$1" = "${FM_FAKE_ME_PID:-}" ]; then
    printf '%s\n' "${FM_FAKE_ME_ARGS:-pi}"
  elif [ "$1" = "${FM_FAKE_OTHER_PID:-}" ]; then
    printf '%s\n' "${FM_FAKE_OTHER_ARGS:-pi}"
  else
    printf 'bash fm-lock.sh\n'
  fi
}

case "$*" in
  *"comm="*)
    if [ -n "${FM_FAKE_BARRIER_DIR:-}" ] && [ "$pid" = "${FM_FAKE_ME_PID:-}" ]; then
      : > "$FM_FAKE_BARRIER_DIR/$pid"
      attempts=0
      while [ "$(find "$FM_FAKE_BARRIER_DIR" -type f | wc -l | tr -d ' ')" -lt 2 ]; do
        sleep 0.01
        attempts=$((attempts + 1))
        [ "$attempts" -lt 500 ] || exit 8
      done
    fi
    comm_for_pid "$pid"
    ;;
  *"args="*) args_for_pid "$pid" ;;
  *"ppid="*)
    if [ "$pid" = "${FM_FAKE_ME_PID:-}" ] || [ "$pid" = "${FM_FAKE_OTHER_PID:-}" ]; then
      printf '1\n'
    else
      printf '%s\n' "${FM_FAKE_ME_PID:-1}"
    fi
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
}

new_home() {
  TEST_HOME="$TMP_ROOT/$1"
  TEST_FAKEBIN="$TEST_HOME/fakebin"
  mkdir -p "$TEST_HOME/state"
  install_fake_ps "$TEST_FAKEBIN"
}

run_lock() {
  env \
    FM_HOME="$TEST_HOME" \
    FM_FAKE_ME_PID="$1" \
    FM_FAKE_OTHER_PID="${2:-}" \
    PATH="$TEST_FAKEBIN:$PATH" \
    "$LOCK_SCRIPT" "${3:-}"
}

test_live_native_pi_holder_is_protected() {
  local out
  new_home live-native-pi
  start_live_process
  printf '%s\n' "$LIVE_PID" > "$TEST_HOME/state/.lock"
  out=$(FM_HOME="$TEST_HOME" FM_FAKE_OTHER_PID="$LIVE_PID" PATH="$TEST_FAKEBIN:$PATH" "$LOCK_SCRIPT" status)
  assert_contains "$out" "lock: held by live harness pid $LIVE_PID" "native Pi holder was not classified as live"
  pass "native Pi comm and argv are classified as a live holder"
}

test_all_supported_native_harness_names_are_exact() {
  local holder harness out
  new_home supported-native
  start_live_process
  holder=$LIVE_PID
  printf '%s\n' "$holder" > "$TEST_HOME/state/.lock"
  for harness in claude codex opencode pi grok; do
    out=$(FM_HOME="$TEST_HOME" FM_FAKE_OTHER_PID="$holder" FM_FAKE_OTHER_COMM="/usr/local/bin/$harness" FM_FAKE_OTHER_ARGS="$harness" PATH="$TEST_FAKEBIN:$PATH" "$LOCK_SCRIPT" status)
    assert_contains "$out" "lock: held by live harness pid $holder" "$harness was not classified as a supported native harness"
  done
  out=$(FM_HOME="$TEST_HOME" FM_FAKE_OTHER_PID="$holder" FM_FAKE_OTHER_COMM=/usr/local/bin/notcodex FM_FAKE_OTHER_ARGS=notcodex PATH="$TEST_FAKEBIN:$PATH" "$LOCK_SCRIPT" status)
  assert_contains "$out" "lock: stale" "a native command containing a harness substring was accepted"
  pass "all supported native harness names match exactly and substrings do not"
}

test_live_other_refuses_without_mutation() {
  local holder contender before after out status
  new_home live-other
  start_live_process
  holder=$LIVE_PID
  start_live_process
  contender=$LIVE_PID
  printf '%s\n' "$holder" > "$TEST_HOME/state/.lock"
  before=$(shasum -a 256 "$TEST_HOME/state/.lock")
  status=0
  out=$(run_lock "$contender" "$holder" 2>&1) || status=$?
  expect_code 1 "$status" "a live other holder must refuse acquisition"
  assert_contains "$out" "another live firstmate session holds the lock" "live-other refusal did not identify the competitor"
  after=$(shasum -a 256 "$TEST_HOME/state/.lock")
  [ "$before" = "$after" ] || fail "live-other refusal changed the lock bytes"
  pass "a verified live other holder remains byte-for-byte unchanged"
}

test_same_holder_is_idempotent() {
  local holder out ownership
  new_home same-holder
  start_live_process
  holder=$LIVE_PID
  printf '%s\n' "$holder" > "$TEST_HOME/state/.lock"
  out=$(run_lock "$holder")
  assert_contains "$out" "lock acquired: harness pid $holder" "same-holder acquisition did not remain successful"
  [ "$(cat "$TEST_HOME/state/.lock")" = "$holder" ] || fail "same-holder acquisition changed ownership"
  ownership=$(run_lock "$holder" "" ownership)
  [ "$ownership" = "owned" ] || fail "same-holder ownership reported '$ownership'"
  pass "same-holder acquisition and ownership inspection are idempotent"
}

test_dead_holder_is_reclaimed() {
  local contender ownership
  new_home dead-holder
  start_live_process
  contender=$LIVE_PID
  printf '999999\n' > "$TEST_HOME/state/.lock"
  run_lock "$contender" >/dev/null
  [ "$(cat "$TEST_HOME/state/.lock")" = "$contender" ] || fail "dead holder was not replaced by the contender"
  ownership=$(run_lock "$contender" "" ownership)
  [ "$ownership" = "owned" ] || fail "reclaimed lock reported '$ownership'"
  pass "a dead holder is reclaimed through the production owner"
}

test_malformed_lock_fails_closed() {
  local contender before after out status ownership
  new_home malformed
  start_live_process
  contender=$LIVE_PID
  printf '123\n456\n' > "$TEST_HOME/state/.lock"
  before=$(shasum -a 256 "$TEST_HOME/state/.lock")
  status=0
  out=$(run_lock "$contender" 2>&1) || status=$?
  expect_code 1 "$status" "malformed lock must refuse acquisition"
  assert_contains "$out" "malformed" "malformed lock refusal was not explicit"
  after=$(shasum -a 256 "$TEST_HOME/state/.lock")
  [ "$before" = "$after" ] || fail "malformed lock refusal changed the lock bytes"
  ownership=$(run_lock "$contender" "" ownership)
  [ "$ownership" = "malformed" ] || fail "malformed ownership reported '$ownership'"
  pass "malformed lock content fails closed without mutation"
}

test_no_harness_ancestry_refuses() {
  local out status
  new_home no-harness
  status=0
  out=$(FM_HOME="$TEST_HOME" FM_FAKE_ME_PID="" PATH="$TEST_FAKEBIN:$PATH" "$LOCK_SCRIPT" 2>&1) || status=$?
  expect_code 1 "$status" "missing harness ancestry must refuse acquisition"
  assert_contains "$out" "cannot locate harness process in ancestry" "missing ancestry refusal was not explicit"
  assert_absent "$TEST_HOME/state/.lock" "missing ancestry created a lock"
  pass "acquisition without a verified harness ancestor fails closed"
}

test_bare_interpreter_requires_exact_script_basename() {
  local holder out
  new_home bare-interpreter
  start_live_process
  holder=$LIVE_PID
  printf '%s\n' "$holder" > "$TEST_HOME/state/.lock"
  out=$(FM_HOME="$TEST_HOME" FM_FAKE_OTHER_PID="$holder" FM_FAKE_OTHER_COMM=/usr/bin/node FM_FAKE_OTHER_ARGS='node /opt/homebrew/bin/pi --print' PATH="$TEST_FAKEBIN:$PATH" "$LOCK_SCRIPT" status)
  assert_contains "$out" "lock: held by live harness pid $holder" "exact interpreter script basename was not recognized"
  out=$(FM_HOME="$TEST_HOME" FM_FAKE_OTHER_PID="$holder" FM_FAKE_OTHER_COMM=/usr/bin/node FM_FAKE_OTHER_ARGS='node /tmp/notcodex-helper.js pi' PATH="$TEST_FAKEBIN:$PATH" "$LOCK_SCRIPT" status)
  assert_contains "$out" "lock: stale" "an arbitrary argv substring or later token matched as a harness"
  pass "bare interpreter classification uses only the exact script basename"
}

test_concurrent_contenders_have_one_winner() {
  local first second barrier rc_one rc_two winners lock_pid
  new_home concurrent
  start_live_process
  first=$LIVE_PID
  start_live_process
  second=$LIVE_PID
  barrier="$TEST_HOME/barrier"
  mkdir -p "$barrier"
  (
    status=0
    FM_HOME="$TEST_HOME" FM_FAKE_ME_PID="$first" FM_FAKE_OTHER_PID="$second" FM_FAKE_BARRIER_DIR="$barrier" PATH="$TEST_FAKEBIN:$PATH" "$LOCK_SCRIPT" > "$TEST_HOME/one.out" 2>&1 || status=$?
    printf '%s\n' "$status" > "$TEST_HOME/one.rc"
  ) &
  one_job=$!
  (
    status=0
    FM_HOME="$TEST_HOME" FM_FAKE_ME_PID="$second" FM_FAKE_OTHER_PID="$first" FM_FAKE_BARRIER_DIR="$barrier" PATH="$TEST_FAKEBIN:$PATH" "$LOCK_SCRIPT" > "$TEST_HOME/two.out" 2>&1 || status=$?
    printf '%s\n' "$status" > "$TEST_HOME/two.rc"
  ) &
  two_job=$!
  wait "$one_job"
  wait "$two_job"
  rc_one=$(cat "$TEST_HOME/one.rc")
  rc_two=$(cat "$TEST_HOME/two.rc")
  winners=0
  [ "$rc_one" -eq 0 ] && winners=$((winners + 1))
  [ "$rc_two" -eq 0 ] && winners=$((winners + 1))
  [ "$winners" -eq 1 ] || fail "concurrent contenders produced $winners winners (rcs $rc_one/$rc_two)"
  lock_pid=$(cat "$TEST_HOME/state/.lock")
  [ "$lock_pid" = "$first" ] || [ "$lock_pid" = "$second" ] || fail "concurrent winner wrote unexpected pid '$lock_pid'"
  pass "serialized concurrent contenders produce exactly one winner"
}

test_live_native_pi_holder_is_protected
test_all_supported_native_harness_names_are_exact
test_live_other_refuses_without_mutation
test_same_holder_is_idempotent
test_dead_holder_is_reclaimed
test_malformed_lock_fails_closed
test_no_harness_ancestry_refuses
test_bare_interpreter_requires_exact_script_basename
test_concurrent_contenders_have_one_winner
