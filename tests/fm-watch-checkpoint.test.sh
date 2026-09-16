#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

wait_for_checkpoint_lock() {
  local home=$1 i=0
  while [ "$i" -lt 100 ]; do
    if [ -s "$home/state/.watch.lock/pid" ] \
      && [ -e "$home/state/.last-watcher-beat" ]; then
      return 0
    fi
    sleep 0.05
    i=$((i + 1))
  done
  return 1
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

test_announced_recovery_is_not_reannounced_by_next_checkpoint() {
  local home out err status marker
  home=$(make_home announced-recovery)
  out="$home/out.txt"
  err="$home/err.txt"
  marker='announced:downtime:reported.1.aaa'
  printf '%s\n' "$marker" > "$home/state/.watcher-down"

  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?

  expect_code 124 "$status" "announced recovery checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" \
    "announced recovery checkpoint did not supervise for its bound"
  assert_not_contains "$(cat "$out")" "check: rearm-resurface" \
    "announced recovery was reannounced by the next checkpoint"
  [ "$(cat "$home/state/.watcher-down")" = "$marker" ] \
    || fail "announced recovery checkpoint changed the outstanding generation"
  pass "an announced recovery is not reannounced by the next foreground checkpoint"
}

test_never_announced_recovery_is_announced_once() {
  local home out err status
  home=$(make_home pending-recovery)
  out="$home/out.txt"
  err="$home/err.txt"
  printf 'pending:downtime:unreported.1.aaa\n' > "$home/state/.watcher-down"

  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?

  expect_code 0 "$status" "pending recovery checkpoint exit"
  [ "$(grep -c '^check: rearm-resurface$' "$out" || true)" -eq 1 ] \
    || fail "never-announced recovery did not surface exactly once: $(cat "$out")"
  [ "$(cat "$home/state/.watcher-down")" = 'announced:downtime:unreported.1.aaa' ] \
    || fail "never-announced recovery did not retain its announced generation"
  pass "a never-announced recovery still surfaces once from a foreground checkpoint"
}

test_queue_append_during_checkpoint_still_resurfaces() {
  local home out err status checkpoint_pid
  home=$(make_home queue-append)
  out="$home/out.txt"
  err="$home/err.txt"

  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" &
  checkpoint_pid=$!
  wait_for_checkpoint_lock "$home" || {
    kill "$checkpoint_pid" 2>/dev/null || true
    wait "$checkpoint_pid" 2>/dev/null || true
    fail "queue-append checkpoint did not take the watcher lock"
  }
  append_wake "$home/state" check concurrent 'check: appended during checkpoint' \
    || fail "could not append a durable wake during the checkpoint"
  status=0
  wait "$checkpoint_pid" || status=$?

  expect_code 0 "$status" "queue-append checkpoint exit"
  assert_contains "$(cat "$out")" "check: rearm-resurface" \
    "queue append during checkpoint did not resurface"
  grep "$(printf '\tcheck\tconcurrent\tcheck: appended during checkpoint')" \
    "$home/state/.wake-queue" >/dev/null \
    || fail "queue append was not retained durably after checkpoint recovery"
  pass "a queue append during a foreground checkpoint still resurfaces"
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
test_announced_recovery_is_not_reannounced_by_next_checkpoint
test_never_announced_recovery_is_announced_once
test_queue_append_during_checkpoint_still_resurfaces
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
