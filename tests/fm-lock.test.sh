#!/usr/bin/env bash
# Session-lock identity tests for bin/fm-lock.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOCK="$ROOT/bin/fm-lock.sh"
fm_test_tmproot_into TMP_ROOT fm-lock
FM_LOCK_TEST_PIDS=()

cleanup_lock_tests() {
  local pid
  for pid in "${FM_LOCK_TEST_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup_lock_tests EXIT

make_fake_ps() {
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
pid=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-p" ]; then
    pid="$arg"
    break
  fi
  prev="$arg"
done
[ -n "$pid" ] || exit 1

if [ "$pid" = "${FM_FAKE_HOLDER_PID:-}" ]; then
  start=${FM_FAKE_HOLDER_START:-Mon Jan  1 00:00:00 2024}
  comm=${FM_FAKE_HOLDER_COMM:-/usr/local/bin/codex}
  args=${FM_FAKE_HOLDER_ARGS:-codex}
  ppid=${FM_FAKE_HOLDER_PPID:-1}
else
  start=${FM_FAKE_OTHER_START:-Tue Jan  2 00:00:00 2024}
  comm=${FM_FAKE_OTHER_COMM:-/usr/local/bin/codex}
  args=${FM_FAKE_OTHER_ARGS:-codex}
  ppid=${FM_FAKE_OTHER_PPID:-${FM_FAKE_HOLDER_PID:-1}}
fi

case "$*" in
  *"lstart="*) printf '%s\n' "$start"; exit 0 ;;
  *"comm="*) printf '%s\n' "$comm"; exit 0 ;;
  *"args="*) printf '%s\n' "$args"; exit 0 ;;
  *"ppid="*) printf '%s\n' "$ppid"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
[ "$1" = display-message ] || exit 1
printf '%s\n' "${FM_FAKE_TMUX_PANE_PID:?}"
SH
  chmod +x "$fakebin/tmux"
}

start_live_holder() {
  sleep 300 >/dev/null 2>&1 &
  FM_LOCK_TEST_HOLDER=$!
  FM_LOCK_TEST_PIDS+=("$FM_LOCK_TEST_HOLDER")
}

test_pid_reuse_with_mismatched_start_time_acquires() {
  local home fakebin holder out status written_pid
  home="$TMP_ROOT/reuse-home"
  fakebin="$TMP_ROOT/reuse-fakebin"
  mkdir -p "$home/state"
  make_fake_ps "$fakebin"

  start_live_holder
  holder=$FM_LOCK_TEST_HOLDER
  printf '%s\n%s\n' "$holder" 'Sun Dec 31 23:59:59 2023' > "$home/state/.lock"

  status=0
  out=$(FM_HOME="$home" \
    FM_FAKE_HOLDER_PID="$holder" \
    FM_FAKE_HOLDER_START='Mon Jan  1 00:00:00 2024' \
    PATH="$fakebin:$PATH" \
    "$LOCK" 2>&1) || status=$?

  expect_code 0 "$status" "PID-reuse lock should be treated as stale and acquired"
  assert_contains "$out" "lock acquired: harness pid" "PID-reuse lock did not acquire"
  written_pid=$(sed -n '1p' "$home/state/.lock")
  [ "$written_pid" != "$holder" ] || fail "PID-reuse acquisition kept the recycled holder pid"
  pass "fm-lock treats a live harness-named PID with mismatched start time as stale"
}

test_live_same_identity_blocks_another_session() {
  local home fakebin holder out status
  home="$TMP_ROOT/live-block-home"
  fakebin="$TMP_ROOT/live-block-fakebin"
  mkdir -p "$home/state"
  make_fake_ps "$fakebin"

  start_live_holder
  holder=$FM_LOCK_TEST_HOLDER
  printf '%s\n%s\n' "$holder" 'Mon Jan  1 00:00:00 2024' > "$home/state/.lock"

  status=0
  out=$(FM_HOME="$home" \
    FM_FAKE_HOLDER_PID="$holder" \
    FM_FAKE_HOLDER_START='Mon Jan  1 00:00:00 2024' \
    PATH="$fakebin:$PATH" \
    "$LOCK" 2>&1) || status=$?

  expect_code 1 "$status" "live same-identity lock should block another session"
  assert_contains "$out" "another live firstmate session holds the lock" "live same-identity lock did not block"
  pass "fm-lock blocks a genuinely live same-identity holder"
}

test_same_session_reacquire_succeeds() {
  local home home_physical fakebin holder out status
  home="$TMP_ROOT/reacquire-home"
  fakebin="$TMP_ROOT/reacquire-fakebin"
  mkdir -p "$home/state"
  make_fake_ps "$fakebin"

  start_live_holder
  holder=$FM_LOCK_TEST_HOLDER
  printf '%s\n%s\n' "$holder" 'Mon Jan  1 00:00:00 2024' > "$home/state/.lock"

  status=0
  out=$(FM_HOME="$home" \
    FM_FAKE_HOLDER_PID="$holder" \
    FM_FAKE_HOLDER_START='Mon Jan  1 00:00:00 2024' \
    FM_FAKE_OTHER_COMM=/bin/bash \
    FM_FAKE_OTHER_ARGS=bash \
    FM_FAKE_OTHER_PPID="$holder" \
    FM_SUPERVISOR_BACKEND=tmux \
    FM_SUPERVISOR_TARGET=bound:0 \
    FM_FAKE_TMUX_PANE_PID="$holder" \
    PATH="$fakebin:$PATH" \
    "$LOCK" 2>&1) || status=$?

  expect_code 0 "$status" "same-session re-acquire should succeed"
  assert_contains "$out" "lock acquired: harness pid $holder" "same-session re-acquire did not retain the holder pid"
  home_physical=$(cd "$home" && pwd -P)
  assert_grep "home=$home_physical" "$home/state/.lock" "lock did not bind its canonical FM_HOME"
  assert_grep 'backend=tmux' "$home/state/.lock" "lock did not bind the supervisor backend"
  assert_grep 'target=bound:0' "$home/state/.lock" "lock did not bind the supervisor target"
  pass "fm-lock still allows a genuine same-session re-acquire"
}

test_unbound_supervisor_target_is_not_recorded() {
  local home fakebin holder out status
  home="$TMP_ROOT/unbound-home"
  fakebin="$TMP_ROOT/unbound-fakebin"
  mkdir -p "$home/state"
  make_fake_ps "$fakebin"

  start_live_holder
  holder=$FM_LOCK_TEST_HOLDER
  printf '%s\n%s\n' "$holder" 'Mon Jan  1 00:00:00 2024' > "$home/state/.lock"

  status=0
  out=$(FM_HOME="$home" \
    FM_FAKE_HOLDER_PID="$holder" \
    FM_FAKE_HOLDER_START='Mon Jan  1 00:00:00 2024' \
    FM_FAKE_OTHER_COMM=/bin/bash \
    FM_FAKE_OTHER_ARGS=bash \
    FM_FAKE_OTHER_PPID="$holder" \
    FM_SUPERVISOR_BACKEND=tmux \
    FM_SUPERVISOR_TARGET=ambient:0 \
    FM_FAKE_TMUX_PANE_PID=999999 \
    PATH="$fakebin:$PATH" \
    "$LOCK" 2>&1) || status=$?

  expect_code 0 "$status" "same-session acquisition should not depend on visible delivery"
  assert_contains "$out" "lock acquired: harness pid $holder" "same-session lock was not acquired"
  assert_no_grep '^backend=' "$home/state/.lock" "lock recorded an unbound supervisor backend"
  assert_no_grep '^target=' "$home/state/.lock" "lock recorded an unbound supervisor target"
  pass "fm-lock omits supervisor routes not owned by the holder process"
}

test_app_server_holder_is_stale() {
  local home fakebin holder out status
  home="$TMP_ROOT/app-server-home"
  fakebin="$TMP_ROOT/app-server-fakebin"
  mkdir -p "$home/state"
  make_fake_ps "$fakebin"

  start_live_holder
  holder=$FM_LOCK_TEST_HOLDER
  printf '%s\n%s\n' "$holder" 'Mon Jan  1 00:00:00 2024' > "$home/state/.lock"

  status=0
  out=$(FM_HOME="$home" \
    FM_FAKE_HOLDER_PID="$holder" \
    FM_FAKE_HOLDER_START='Mon Jan  1 00:00:00 2024' \
    FM_FAKE_HOLDER_COMM=/Applications/ChatGPT.app/Contents/Resources/codex \
    FM_FAKE_HOLDER_ARGS='/Applications/ChatGPT.app/Contents/Resources/codex app-server --port 0' \
    PATH="$fakebin:$PATH" \
    "$LOCK" 2>&1) || status=$?

  expect_code 0 "$status" "app-server holder should be treated as stale and acquired"
  assert_contains "$out" "lock acquired: harness pid" "app-server holder did not allow acquisition"
  pass "fm-lock rejects Codex app-server as a live session holder"
}

test_legacy_one_line_lock_live_holder_blocks() {
  local home fakebin holder out status
  home="$TMP_ROOT/legacy-home"
  fakebin="$TMP_ROOT/legacy-fakebin"
  mkdir -p "$home/state"
  make_fake_ps "$fakebin"

  start_live_holder
  holder=$FM_LOCK_TEST_HOLDER
  printf '%s\n' "$holder" > "$home/state/.lock"

  status=0
  out=$(FM_HOME="$home" \
    FM_FAKE_HOLDER_PID="$holder" \
    PATH="$fakebin:$PATH" \
    "$LOCK" 2>&1) || status=$?

  expect_code 1 "$status" "legacy one-line lock with a live harness holder should block"
  assert_contains "$out" "another live firstmate session holds the lock" "legacy one-line lock did not block"
  pass "fm-lock falls back to harness liveness for a legacy one-line lock"
}

test_pid_reuse_with_mismatched_start_time_acquires
test_live_same_identity_blocks_another_session
test_same_session_reacquire_succeeds
test_unbound_supervisor_target_is_not_recorded
test_app_server_holder_is_stale
test_legacy_one_line_lock_live_holder_blocks
