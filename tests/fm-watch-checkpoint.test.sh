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
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
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

test_checkpoint_normalizes_and_caps_codex_duration() {
  local home tool_dir out err status observed
  home=$(make_home codex-duration)
  tool_dir="$home/test-bin"
  out="$home/out.txt"
  err="$home/err.txt"
  mkdir -p "$tool_dir"
  cat > "$tool_dir/timeout" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" > "${FM_CHECKPOINT_TEST_SECONDS:?}"
exit 124
SH
  chmod 0700 "$tool_dir/timeout"

  status=0
  FM_HOME="$home" FM_CODEX_WATCH_CHECKPOINT=600 FM_CHECKPOINT_TEST_SECONDS="$home/seconds" \
    PATH="$tool_dir:$PATH" "$CHECKPOINT" >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "capped Codex checkpoint exit"
  observed=$(cat "$home/seconds")
  [ "$observed" = 540 ] || fail "Codex checkpoint must cap an initial cycle at 540 seconds, got $observed"
  assert_contains "$(cat "$out")" "within 540s" "capped checkpoint line must report the effective duration"

  status=0
  FM_HOME="$home" FM_CODEX_WATCH_CHECKPOINT=invalid FM_CHECKPOINT_TEST_SECONDS="$home/seconds" \
    PATH="$tool_dir:$PATH" "$CHECKPOINT" >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "normalized Codex checkpoint exit"
  observed=$(cat "$home/seconds")
  [ "$observed" = 180 ] || fail "invalid Codex checkpoint duration must use the 180-second default, got $observed"
  assert_contains "$(cat "$out")" "within 180s" "normalized checkpoint line must report the default duration"
  pass "checkpoint normalizes and caps Codex durations for direct and Stop-owned cycles"
}

test_codex_stop_recovers_terminal_signal_after_quiet_checkpoint() {
  local home fake_state checkpoint_out checkpoint_err quiet_hook_out quiet_hook_status hook_out hook_status drained
  home=$(make_home terminal-after-checkpoint)
  fake_state="$home/fm-crew-state.sh"
  checkpoint_out="$home/checkpoint.out"
  checkpoint_err="$home/checkpoint.err"
  mkdir -p "$home/bin"
  : > "$home/AGENTS.md"
  git init -q "$home"
  cat > "$fake_state" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_FAKE_CREW_STATE:?}"
SH
  chmod +x "$fake_state"
  printf 'kind=ship\n' > "$home/state/task.meta"
  printf 'working: validation is still running\n' > "$home/state/task.status"

  hook_status=0
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_CREW_STATE_BIN="$fake_state" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$CHECKPOINT" --seconds 20 > "$checkpoint_out" 2> "$checkpoint_err" || hook_status=$?
  expect_code 124 "$hook_status" "initial quiet checkpoint exit"
  assert_absent "$home/state/.wake-queue" "active working signal was queued instead of absorbed"
  assert_present "$home/state/.seen-task_status" "active working signal suppressor was not advanced"

  quiet_hook_status=0
  quiet_hook_out=$(printf '%s' '{"stop_hook_active":false,"session_id":"codex-continuity"}' \
    | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_CREW_STATE_BIN="$fake_state" \
      FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
      FM_CODEX_WATCH_CHECKPOINT=20 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      "$ROOT/bin/fm-turnend-guard.sh" --codex 2>&1) || quiet_hook_status=$?
  expect_code 2 "$quiet_hook_status" "quiet Codex Stop checkpoint continuation"
  assert_not_contains "$quiet_hook_out" "signal:" "quiet Codex Stop checkpoint fabricated a terminal wake"
  assert_absent "$home/state/.wake-queue" "quiet Codex Stop checkpoint queued active progress"

  printf 'blocked: validation requires a credential\n' >> "$home/state/task.status"
  touch "$home/state/task.turn-ended"
  hook_status=0
  hook_out=$(printf '%s' '{"stop_hook_active":true,"session_id":"codex-continuity"}' \
    | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_CREW_STATE_BIN="$fake_state" \
      FM_FAKE_CREW_STATE='state: blocked · source: status-log · validation requires a credential' \
      FM_CODEX_WATCH_CHECKPOINT=20 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      "$ROOT/bin/fm-turnend-guard.sh" --codex 2>&1) || hook_status=$?
  expect_code 2 "$hook_status" "Codex Stop recovery exit"
  case "$hook_out" in
    *"signal:"*|*"check: rearm-resurface"*) ;;
    *) fail "Codex Stop recovery did not surface the waiting watcher boundary: $hook_out" ;;
  esac
  drained=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null)
  assert_contains "$drained" "blocked: validation requires a credential" \
    "Codex Stop recovery did not leave the real terminal result for the primary"
  pass "Codex Stop recovers a terminal status written after an absorbed working signal and quiet checkpoint"
}

test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_checkpoint_normalizes_and_caps_codex_duration
test_codex_stop_recovers_terminal_signal_after_quiet_checkpoint
