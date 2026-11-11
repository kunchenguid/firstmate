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
  assert_signal_wake_for "$drained" demo.status "signal wake was not queued durably"
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

test_slow_check_is_logged_and_the_beacon_advances_between_checks() {
  local home out err status age
  home=$(make_home slow-check)
  out="$home/out.txt"
  err="$home/err.txt"
  # Checks run one after another: a slow first check must not leave the beacon
  # unrefreshed for the rest of the sweep, and must leave a timing trace.
  cat > "$home/state/a-slow.check.sh" <<'SH'
#!/usr/bin/env bash
sleep 6
SH
  # GNU first, BSD second. The reverse order is a trap on GNU coreutils, where
  # `-f` is *filesystem* stat: it consumes the format string as a path, prints a
  # "  File: ..." report on stdout, and still exits non-zero, so the fallback
  # runs but the captured value is the report plus the timestamp. The following
  # arithmetic then fails and the check emits nothing at all, which starves the
  # sweep of the very observation this case asserts on. tests/fm-busy-state.test.sh
  # carries the same regression for issue #2625.
  cat > "$home/state/b-beat.check.sh" <<'SH'
#!/usr/bin/env bash
now=$(date +%s)
beat=$(stat -c %Y "$FM_HOME/state/.last-watcher-beat" 2>/dev/null || stat -f %m "$FM_HOME/state/.last-watcher-beat")
printf 'beacon age %ss after the slow check\n' "$((now - beat))"
SH
  chmod 0700 "$home/state/a-slow.check.sh" "$home/state/b-beat.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" a-slow >/dev/null || fail "could not register the slow check"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" b-beat >/dev/null || fail "could not register the beacon check"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=2 FM_CHECK_SLOW_LOG_SECS=2 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 \
    "$CHECKPOINT" --seconds 90 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "slow check checkpoint exit"
  age=$(sed -n 's/.*beacon age \([0-9]*\)s after the slow check.*/\1/p' "$out" | head -1)
  [ -n "$age" ] || fail "the beacon check did not report: $(cat "$out")"
  # The 6-second check ran first; a beacon touched only before the sweep is at
  # least that old, while one refreshed between checks is only as old as the
  # next check's own start-up.
  [ "$age" -lt 6 ] || fail "the beacon was ${age}s old after a 6-second check in the same sweep; it was not refreshed between checks"
  assert_contains "$(cat "$home/state/.watch-triage.log")" "slow check a-slow.check.sh took" "a slow check left no timing trace in the triage log"
  pass "a slow check is triage-logged and the beacon advances between checks"
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
test_registered_check_uses_preserved_watcher_environment
test_slow_check_is_logged_and_the_beacon_advances_between_checks
test_existing_singleton_watcher_is_not_success
