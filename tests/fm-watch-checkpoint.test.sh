#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

nonexistent_pid() {
  local pid=999999
  while kill -0 "$pid" 2>/dev/null; do pid=$((pid + 1)); done
  printf '%s\n' "$pid"
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  assert_present "$home/state/.watch-checkpoint-rollover" "quiet checkpoint omitted its one-drain rollover marker"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_quiet_rollover_drain_suppresses_only_expected_gap() {
  local home out err drain1_err drain2_err status
  home=$(make_home quiet-rollover)
  out="$home/out.txt"
  err="$home/err.txt"
  drain1_err="$home/drain1.err"
  drain2_err="$home/drain2.err"
  : > "$home/state/task1.meta"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet rollover checkpoint exit"
  FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" > /dev/null 2> "$drain1_err" \
    || fail "required rollover drain failed"
  assert_not_contains "$(cat "$drain1_err")" "WATCHER DOWN" "required quiet-rollover drain emitted a misleading watcher-down alarm"
  assert_absent "$home/state/.watch-checkpoint-rollover" "required drain did not consume the rollover marker"
  FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" > /dev/null 2> "$drain2_err" \
    || fail "post-rollover drain failed"
  assert_contains "$(cat "$drain2_err")" "WATCHER DOWN" "a second drain without a new checkpoint falsely treated rollover as healthy"
  pass "quiet checkpoint rollover suppresses one expected drain gap and no later supervision lapse"
}

test_rollover_marker_validation_fails_closed() {
  local home err old
  home=$(make_home invalid-rollover)
  err="$home/drain.err"
  : > "$home/state/task1.meta"
  printf 'version=1\ncheckpoint_pid=not-a-pid\nended_at=%s\n' "$(date +%s)" > "$home/state/.watch-checkpoint-rollover"
  FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" > /dev/null 2> "$err" \
    || fail "malformed-rollover drain failed"
  assert_contains "$(cat "$err")" "WATCHER DOWN" "a malformed rollover marker suppressed the watcher-down alarm"
  assert_absent "$home/state/.watch-checkpoint-rollover" "malformed rollover marker was not retired"

  home=$(make_home expired-rollover)
  err="$home/drain.err"
  : > "$home/state/task1.meta"
  old=$(( $(date +%s) - 120 ))
  printf 'version=1\ncheckpoint_pid=%s\nended_at=%s\n' "$$" "$old" > "$home/state/.watch-checkpoint-rollover"
  FM_HOME="$home" FM_CHECKPOINT_ROLLOVER_GRACE=60 "$ROOT/bin/fm-wake-drain.sh" > /dev/null 2> "$err" \
    || fail "expired-rollover drain failed"
  assert_contains "$(cat "$err")" "WATCHER DOWN" "an expired rollover marker suppressed the watcher-down alarm"
  assert_absent "$home/state/.watch-checkpoint-rollover" "expired rollover marker was not retired"
  pass "malformed and expired rollover markers fail closed and are single-use"
}

test_parent_disconnect_reaps_watcher_and_lock() {
  local home out err checkpoint_pid watcher_pid wrapper_pid i
  home=$(make_home disconnect)
  out="$home/out.txt"
  err="$home/err.txt"
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 20 >"$out" 2>"$err" &
  checkpoint_pid=$!
  i=0
  while [ "$i" -lt 50 ] && [ ! -s "$home/state/.watch.lock/pid" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$home/state/.watch.lock/pid" ] || {
    kill "$checkpoint_pid" 2>/dev/null || true
    wait "$checkpoint_pid" 2>/dev/null || true
    fail "checkpoint did not publish a watcher lock before disconnect"
  }
  watcher_pid=$(cat "$home/state/.watch.lock/pid")
  wrapper_pid=$(ps -o ppid= -p "$watcher_pid" 2>/dev/null | tr -d '[:space:]')
  kill -KILL "$checkpoint_pid" 2>/dev/null || true
  wait "$checkpoint_pid" 2>/dev/null || true
  i=0
  while [ "$i" -lt 50 ] && { kill -0 "$watcher_pid" 2>/dev/null || [ -e "$home/state/.watch.lock/pid" ]; }; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$watcher_pid" 2>/dev/null || [ -e "$home/state/.watch.lock/pid" ]; then
    kill -TERM "$watcher_pid" 2>/dev/null || true
    [ -z "$wrapper_pid" ] || kill -TERM "$wrapper_pid" 2>/dev/null || true
    fail "disconnected checkpoint left a live watcher or watcher lock"
  fi
  if [ -n "$wrapper_pid" ] && kill -0 "$wrapper_pid" 2>/dev/null; then
    kill -TERM "$wrapper_pid" 2>/dev/null || true
    fail "disconnected checkpoint left its timeout wrapper orphaned"
  fi
  pass "checkpoint parent disconnection reaps the timeout wrapper, watcher, and home lock"
}

test_stale_lock_is_recovered_by_checkpoint() {
  local home out err status dead
  home=$(make_home stale-lock)
  out="$home/out.txt"
  err="$home/err.txt"
  dead=$(nonexistent_pid)
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$dead" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "stale-lock checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake" "checkpoint did not run after stale-lock recovery"
  assert_absent "$home/state/.watch.lock/pid" "checkpoint left the recovered stale watcher lock behind"
  pass "checkpoint recovers an exact dead-pid watcher lock without duplicating the watcher"
}

test_signal_passes_through_and_exits_zero() {
  local home out err drain_err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  drain_err="$home/drain.err"
  : > "$home/state/task1.meta"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  assert_present "$home/state/.watch-checkpoint-rollover" "actionable checkpoint omitted its one-drain rollover marker"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2> "$drain_err")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  assert_not_contains "$(cat "$drain_err")" "WATCHER DOWN" "actionable checkpoint drain emitted a misleading watcher-down alarm"
  assert_absent "$home/state/.watch-checkpoint-rollover" "actionable checkpoint drain did not consume its rollover marker"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_registered_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for registered custom checks"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

test_quiet_checkpoint_exits_124_cleanly
test_quiet_rollover_drain_suppresses_only_expected_gap
test_rollover_marker_validation_fails_closed
test_parent_disconnect_reaps_watcher_and_lock
test_stale_lock_is_recovered_by_checkpoint
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
