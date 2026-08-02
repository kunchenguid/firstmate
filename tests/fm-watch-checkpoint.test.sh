#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
GUARD="$ROOT/bin/fm-turnend-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)
fm_git_identity fmtest fmtest@example.invalid

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

wait_for_checkpoint_lock() {
  local home=$1 i=0
  while [ "$i" -lt 100 ]; do
    if [ "$(cat "$home/state/.watch.lock/supervision-owner" 2>/dev/null || true)" = bounded-checkpoint ]; then
      return 0
    fi
    sleep 0.02
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
  assert_absent "$home/state/.watch.lock/supervision-owner" "watch ownership survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_two_quiet_checkpoints_reacquire_and_release_cleanly() {
  local home cycle out err status
  home=$(make_home quiet-twice)
  cycle=1
  while [ "$cycle" -le 2 ]; do
    out="$home/out-$cycle.txt"
    err="$home/err-$cycle.txt"
    status=0
    FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
    expect_code 124 "$status" "quiet checkpoint cycle $cycle exit"
    assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint cycle $cycle line missing"
    assert_absent "$home/state/.watch.lock/pid" "watch lock survived quiet checkpoint cycle $cycle"
    assert_absent "$home/state/.watch.lock/supervision-owner" "watch ownership survived quiet checkpoint cycle $cycle"
    cycle=$((cycle + 1))
  done
  pass "two consecutive quiet checkpoints each reacquire and release the watcher lock"
}

test_registered_check_fires_after_two_quiet_boundaries() {
  local home cycle out err status drained check_count
  home=$(make_home check-after-quiet)
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  cat > "$home/state/after-quiet.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'registered check survived quiet boundaries\n'
SH
  chmod 0700 "$home/state/after-quiet.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" after-quiet >/dev/null \
    || fail "could not register post-boundary custom check"
  touch "$home/state/.last-check"

  cycle=1
  while [ "$cycle" -le 2 ]; do
    out="$home/quiet-$cycle.out"
    err="$home/quiet-$cycle.err"
    status=0
    FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
    expect_code 124 "$status" "pre-check quiet boundary $cycle exit"
    cycle=$((cycle + 1))
  done

  touch -t 202001010000 "$home/state/.last-check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$home/check.out" 2>"$home/check.err" || status=$?
  expect_code 0 "$status" "registered check after quiet boundaries exit"
  assert_contains "$(cat "$home/check.out")" "check:" "registered check did not surface after quiet boundaries"
  assert_contains "$(cat "$home/check.out")" "registered check survived quiet boundaries" "registered check output missing after quiet boundaries"
  drained=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  check_count=$(printf '%s\n' "$drained" | awk -F '\t' '$3 == "check" { count++ } END { print count + 0 }')
  [ "$check_count" -eq 1 ] || fail "registered check wake surfaced $check_count times after quiet boundaries"
  pass "registered checks continue after two consecutive quiet checkpoint boundaries"
}

test_stop_guard_rejects_live_bounded_checkpoint() {
  local home out err guard_out status checkpoint_pid
  home=$(make_home stop-live)
  out="$home/out.txt"
  err="$home/err.txt"
  git init -q "$home"
  git -C "$home" commit -q --allow-empty -m init
  : > "$home/AGENTS.md"
  mkdir -p "$home/bin"
  : > "$home/state/task.meta"

  FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 3 >"$out" 2>"$err" &
  checkpoint_pid=$!
  wait_for_checkpoint_lock "$home" || {
    kill "$checkpoint_pid" 2>/dev/null || true
    wait "$checkpoint_pid" 2>/dev/null || true
    fail "bounded checkpoint did not publish its watcher ownership"
  }

  guard_out=$(printf '{"stop_hook_active":false}' \
    | FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_GUARD_GRACE=300 bash "$GUARD" 2>&1)
  status=$?
  wait "$checkpoint_pid" 2>/dev/null || true

  expect_code 2 "$status" "turn-end guard must block while a bounded checkpoint is the only owner"
  assert_contains "$guard_out" "bounded Codex checkpoint" "bounded checkpoint block reason missing"
  assert_absent "$home/state/.watch.lock/pid" "watch lock survived bounded checkpoint expiry"
  pass "turn-end guard blocks the unsafe stop-while-checkpoint-live sequence"
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
  drained=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
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

test_quiet_checkpoint_exits_124_cleanly
test_two_quiet_checkpoints_reacquire_and_release_cleanly
test_registered_check_fires_after_two_quiet_boundaries
test_stop_guard_rejects_live_bounded_checkpoint
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
