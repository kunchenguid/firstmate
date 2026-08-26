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

install_empty_once_ps() {  # <fakebin> <stamp>
  local fakebin=$1 stamp=$2 real_ps
  real_ps=$(command -v ps) || fail "test host has no ps command"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
stamp=${FM_FAKE_PS_EMPTY_ONCE:?FM_FAKE_PS_EMPTY_ONCE unset}
real_ps=${FM_FAKE_REAL_PS:?FM_FAKE_REAL_PS unset}
if [ ! -e "$stamp" ]; then
  : > "$stamp"
  exit 0
fi
exec "$real_ps" "$@"
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$real_ps" > "$fakebin/real-ps"
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
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout; link=$(readlink "$home/state/.watch.lock" 2>/dev/null || true) pid=$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true) token=$(cat "$home/state/.watch.lock/owner-token" 2>/dev/null || true) files=$(find "$home/state" -maxdepth 1 -name '.watch.lock*' -print 2>/dev/null | sort | tr '\n' '|') err=$(tr '\n' '|' < "$err" 2>/dev/null || true)"
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

test_checkpoint_retries_empty_identity_publication() {
  local home fakebin stamp real_ps out err checkpoint_pid watcher_pid identity health health_status status i
  home=$(make_home transient-identity)
  fakebin=$(fm_fakebin "$home")
  stamp="$home/ps-empty-once"
  install_empty_once_ps "$fakebin" "$stamp"
  real_ps=$(cat "$fakebin/real-ps")
  out="$home/out.txt"
  err="$home/err.txt"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_PROC_ROOT_OVERRIDE="$home/no-proc" \
    FM_FAKE_PS_EMPTY_ONCE="$stamp" FM_FAKE_REAL_PS="$real_ps" \
    FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" &
  checkpoint_pid=$!

  i=0
  while [ "$i" -lt 80 ]; do
    watcher_pid=$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)
    [ -n "$watcher_pid" ] && [ -e "$home/state/.watch.lock/pid-identity" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  identity=$(cat "$home/state/.watch.lock/pid-identity" 2>/dev/null || true)
  health=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_PROC_ROOT_OVERRIDE="$home/no-proc" bash -c '
    . "$1"
    if fm_watcher_healthy "$2" "$3" 300 "$4"; then
      printf "healthy pid=%s identity=%s\n" "$FM_WATCHER_HEALTHY_PID" "$FM_WATCHER_HEALTHY_IDENTITY"
    else
      printf "unhealthy\n"
      exit 7
    fi
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$ROOT/bin/fm-watch.sh" "$home" 2>&1); health_status=$?

  printf 'done: synthetic wake\n' > "$home/state/transient.status"
  wait "$checkpoint_pid" 2>/dev/null
  status=$?

  [ -e "$stamp" ] || fail "fixture ps did not force an initial empty identity read"
  [ -n "$watcher_pid" ] || fail "checkpoint watcher never published its pid"
  [ -n "$identity" ] || fail "checkpoint watcher published a blank pid-identity after an initial empty read"
  expect_code 0 "$health_status" "checkpoint watcher with retried identity must pass strict health"
  assert_contains "$health" "healthy pid=$watcher_pid" "strict health did not identify the checkpoint watcher"
  expect_code 0 "$status" "signal checkpoint exit after transient identity publication"
  assert_contains "$(cat "$out")" "signal:" "checkpoint did not pass through the cleanup signal"
  pass "checkpoint watcher retries an initial empty pid identity before publishing the lock"
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
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_checkpoint_retries_empty_identity_publication
test_existing_singleton_watcher_is_not_success
