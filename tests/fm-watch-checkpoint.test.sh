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

test_pending_queue_is_drained_before_a_new_checkpoint_starts() {
  local home out err status
  home=$(make_home queued)
  out="$home/out.txt"
  err="$home/err.txt"
  printf '1\t1\tsignal\ttask.status\tsignal: task.status\n' > "$home/state/.wake-queue"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "queued checkpoint exit"
  assert_contains "$(cat "$out")" $'\tsignal\ttask.status\t' "checkpoint did not surface its durable queued wake"
  [ ! -s "$home/state/.wake-queue" ] || fail "checkpoint left the durable wake queued"
  assert_absent "$home/state/.watch.lock/pid" "checkpoint started a duplicate watcher while a wake was pending"
  pass "checkpoint drains a durable queued wake before starting another watcher"
}

test_next_checkpoint_reconciles_a_terminal_status_missed_while_no_watcher_lived() {
  local home out err status signature drained
  home=$(make_home missed-terminal)
  out="$home/out.txt"
  err="$home/err.txt"

  # A bounded checkpoint has ended, so its watcher lock must be gone before the
  # crewmate writes a terminal status in the blind interval.
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "initial quiet checkpoint exit"
  assert_absent "$home/state/.watch.lock/pid" "quiet checkpoint left a watcher alive"

  printf 'done: terminal status during the checkpoint gap\n' > "$home/state/task.status"
  if [ "$(uname)" = Darwin ]; then
    signature=$(stat -f '%z:%Fm' "$home/state/task.status")
  else
    signature=$(stat -c '%s:%Y' "$home/state/task.status")
  fi
  # Reproduce a per-signal miss: the durable .seen marker is current, but the
  # terminal status was never marked surfaced and no wake was queued.
  printf '%s' "$signature" > "$home/state/.seen-task_status"

  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$CHECKPOINT" --seconds 3 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "reconciliation checkpoint exit"
  assert_contains "$(cat "$out")" "heartbeat" "next checkpoint did not surface the missed terminal status"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\theartbeat\theartbeat\theartbeat' "reconciliation wake was not durable"
  assert_absent "$home/state/.watch.lock/pid" "reconciliation checkpoint did not clean up its watcher"
  pass "next checkpoint durably reconciles a terminal status missed between checkpoints"
}

test_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod +x "$home/state/env-check.check.sh"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for the foreground fm-watch.sh"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
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
test_signal_passes_through_and_exits_zero
test_pending_queue_is_drained_before_a_new_checkpoint_starts
test_next_checkpoint_reconciles_a_terminal_status_missed_while_no_watcher_lived
test_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
