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

# A home opted into the supervision host whose checkpoint runs a stub host in
# a fixture code root: the stub records the bound it was given, then closes
# the way $FM_HOME/host-kind says.
make_host_home() {  # <name>
  local home
  home=$(make_home "$1")
  mkdir -p "$home/root/bin"
  cp "$CHECKPOINT" "$home/root/bin/fm-watch-checkpoint.sh"
  cp "$ROOT/bin/fm-supervision-engine-lib.sh" "$home/root/bin/fm-supervision-engine-lib.sh"
  cat > "$home/root/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'args=%s\nprimary=%s\npark=%s\nlimit=%s\n' "$*" "${FM_SUPERVISION_HOST_PRIMARY:-}" \
  "${FM_SUPERVISION_HOST_PARK_SECONDS:-}" "${FM_SUPERVISION_HOST_PARK_LIMIT:-}" > "$FM_HOME/host-env"
case "$(cat "$FM_HOME/host-kind")" in
  boundary) printf 'supervision-host: cycle boundary - fixture\n' ;;
  handback)
    printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
    printf 'signal: demo.status\nsupervision-host: the away session could not take this wake: fixture; this wake is yours\n'
    ;;
  stood-down) printf 'supervision-host stood down: this session no longer owns supervision\n' ;;
esac
SH
  chmod +x "$home/root/bin/fm-watch-checkpoint.sh" "$home/root/bin/fm-supervision-host.sh"
  : > "$home/config/supervision-host"
  printf '%s\n' "$home"
}

run_host_checkpoint() {  # <home> <kind> [checkpoint args...]; sets STATUS
  local home=$1
  printf '%s\n' "$2" > "$home/host-kind"
  shift 2
  STATUS=0
  FM_HOME="$home" "$home/root/bin/fm-watch-checkpoint.sh" "$@" >"$home/out.txt" 2>"$home/err.txt" || STATUS=$?
}

test_host_checkpoint_bounds_the_park_by_posture() {
  local home f
  home=$(make_host_home host-bound)
  run_host_checkpoint "$home" boundary --seconds 5
  expect_code 124 "$STATUS" "a host park that reached its bound is a quiet checkpoint"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 5s" "the boundary must read as the ordinary quiet line"
  assert_contains "$(cat "$home/host-env")" $'args=park\nprimary=codex\npark=5\nlimit=1235' \
    "attended, the host must park for the checkpoint's own bound with the codex pin and a turn limit past it"
  : > "$home/state/.afk-contract"
  run_host_checkpoint "$home" boundary --seconds 5
  expect_code 124 "$STATUS" "an away park that reached its bound is a quiet checkpoint"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 3600s" "away, the bound must be raised"
  assert_contains "$(cat "$home/host-env")" 'park=3600' "away, the host must park for the away bound"
  FM_CODEX_WATCH_CHECKPOINT_AWAY=900 run_host_checkpoint "$home" boundary --seconds 5
  assert_contains "$(cat "$home/host-env")" 'park=900' "the away bound must be configurable"
  FM_CODEX_WATCH_CHECKPOINT_AWAY=900 run_host_checkpoint "$home" boundary --seconds 1000
  assert_contains "$(cat "$home/host-env")" 'park=1000' "the away bound must never shorten a longer checkpoint"
  # Quiet mode's record is a present captain (bin/fm-afk-contract.sh AWAY OR
  # QUIET), so the checkpoint keeps its attended bound beside it.
  for f in fm-afk-contract.sh fm-classify-lib.sh fm-timeout-lib.sh; do cp "$ROOT/bin/$f" "$home/root/bin/$f"; done
  rm -f "$home/state/.afk-contract"
  FM_HOME="$home" FM_AFK_MODE=quiet "$ROOT/bin/fm-afk-contract.sh" enter --words 'keep routine wakes off my main' >/dev/null 2>&1 \
    || fail "fixture: could not record quiet mode"
  run_host_checkpoint "$home" boundary --seconds 5
  expect_code 124 "$STATUS" "a park beside a quiet record that reached its bound is a quiet checkpoint"
  assert_contains "$(cat "$home/host-env")" 'park=5' "beside a quiet record the host must park for the attended bound"
  pass "checkpoint: an opted-in home runs the host for the checkpoint's bound, raised only while away"
}

test_host_checkpoint_passes_a_handback_and_reports_a_stand_down() {
  local home
  home=$(make_host_home host-handback)
  run_host_checkpoint "$home" handback --seconds 5
  expect_code 0 "$STATUS" "a handed-back wake is an actionable checkpoint"
  assert_contains "$(cat "$home/out.txt")" $'signal: demo.status\nsupervision-host: the away session could not take this wake' \
    "the wake and its host line must pass through"
  assert_not_contains "$(cat "$home/out.txt")" "watcher: started" "the host's cycle status is not part of the wake"
  run_host_checkpoint "$home" stood-down --seconds 5
  expect_code 1 "$STATUS" "a host that stood down is a failed checkpoint"
  assert_contains "$(cat "$home/out.txt")" "supervision-host stood down" "the stand-down must be shown"
  pass "checkpoint: a handed-back wake passes through, and a host stand-down is a failure"
}

# The Codex owner stays file-gated: without config/supervision-host, or with
# config/supervision-host-off, the checkpoint never runs the host.
test_host_checkpoint_needs_the_file_and_honors_off() {
  local home line
  home=$(make_host_home host-gate)
  for line in - off; do
    rm -f "$home/config/supervision-host" "$home/config/supervision-host-off" "$home/host-env"
    [ "$line" = - ] || : > "$home/config/supervision-host-off"
    run_host_checkpoint "$home" boundary --seconds 1
    [ ! -e "$home/host-env" ] || fail "a Codex home whose config/supervision-host is ${line/-/absent} ran the supervision host"
  done
  pass "checkpoint: a Codex home without config/supervision-host, or with an off file, never runs the host"
}

# The real host under a fake Codex harness that holds the home's session lock.
# shellcheck disable=SC2016 # the fake harness's script expands in its own shell
test_real_host_checkpoint_ends_quietly_at_its_bound() {
  local home fakebin status
  home=$(make_home host-real)
  : > "$home/config/supervision-host"
  fakebin="$TMP_ROOT/host-real-bin"
  mkdir -p "$fakebin"
  ln -s /bin/bash "$fakebin/codex"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$fakebin/codex" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    "$0" --seconds 4
  ' "$CHECKPOINT" >"$home/out.txt" 2>"$home/err.txt" || status=$?
  expect_code 124 "$status" "a quiet host checkpoint: $(cat "$home/out.txt" "$home/err.txt")"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 4s" "the real host's boundary must read as the quiet line"
  assert_grep '	boundary	' "$home/state/.supervision-host.log" "the host must have ended its own park"
  if [ -e "$home/state/.watch.lock/pid" ] && kill -0 "$(cat "$home/state/.watch.lock/pid")" 2>/dev/null; then
    fail "a host checkpoint left its watcher running"
  fi
  pass "checkpoint: the real host ends its park at the checkpoint bound as a quiet checkpoint"
}

pid_running() {  # <pid>
  local stat
  kill -0 "$1" 2>/dev/null || return 1
  stat=$(ps -p "$1" -o stat= 2>/dev/null || true)
  case "$stat" in Z*) return 1 ;; esac
}

wait_until_gone() {  # <pid> <polls>
  local i=0
  while [ "$i" -lt "$2" ] && pid_running "$1"; do
    sleep 0.1
    i=$((i + 1))
  done
  ! pid_running "$1"
}

# Acknowledge every queued wake through the attended drain.
ack_wakes() {  # <home>
  local err="$1/ack.err" sequence generation
  FM_HOME="$1" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>"$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$err" | tail -1)
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err" | tail -1)
  [ -n "$sequence" ] && [ -n "$generation" ] || return 0
  FM_HOME="$1" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$sequence" --recovery-generation "$generation" >/dev/null 2>&1
}

# A stand-in for an away daemon from before the presence-gated exit: it runs
# this home's real watcher as its child, then drains and acknowledges every
# queued wake whatever state/.afk says. The watcher sees it only as its parent
# process running fm-supervise-daemon.sh.
LEFTOVER_PID=
start_leftover_daemon() {  # <home>
  local home=$1 i watcher
  mkdir -p "$home/old-bin"
  cat > "$home/old-bin/fm-supervise-daemon.sh" <<'SH'
#!/usr/bin/env bash
w=
trap 'kill "$w" 2>/dev/null; wait "$w" 2>/dev/null; exit 0' TERM
end=$(( $(date +%s) + ${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120} ))
while [ "$(date +%s)" -lt "$end" ]; do
  "$FM_TEST_WATCH" >/dev/null 2>&1 &
  w=$!
  wait "$w"
  err=$("$FM_TEST_DRAIN" 2>&1 >/dev/null)
  seq=$(printf '%s\n' "$err" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' | tail -1)
  gen=$(printf '%s\n' "$err" | sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' | tail -1)
  [ -z "$seq" ] || [ -z "$gen" ] || "$FM_TEST_DRAIN" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
  sleep 0.2
done
SH
  chmod +x "$home/old-bin/fm-supervise-daemon.sh"
  fm_test_track_watcher_state "$home/state"
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_TEST_WATCH="$ROOT/bin/fm-watch.sh" FM_TEST_DRAIN="$ROOT/bin/fm-wake-drain.sh" \
    "$home/old-bin/fm-supervise-daemon.sh" &
  LEFTOVER_PID=$!
  i=0
  while [ "$i" -lt 80 ]; do
    watcher=$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)
    if [ -n "$watcher" ] && [ -e "$home/state/.last-watcher-beat" ] \
      && [ "$(ps -o ppid= -p "$watcher" 2>/dev/null | tr -d ' ')" = "$LEFTOVER_PID" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  kill -TERM "$LEFTOVER_PID" 2>/dev/null || true
  fail "the leftover daemon's watcher never took the lock"
}

test_checkpoint_takes_over_a_watcher_owned_by_a_leftover_away_daemon() {
  local home out old_watcher watcher drained status checkpoint i
  home=$(make_home leftover-daemon)
  out="$home/out.txt"
  [ ! -e "$home/state/.afk" ] || fail "fixture must run with away mode off"
  start_leftover_daemon "$home"
  old_watcher=$(cat "$home/state/.watch.lock/pid")

  # The stopped watcher recorded its downtime, so the fresh watcher always
  # announces that gap; the attended firstmate drains that wake and runs the
  # checkpoint again. The bound is headroom over a loaded takeover, not a
  # deadline: the run returns as soon as the gap wake arrives.
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$CHECKPOINT" --seconds 30 >"$out" 2>"$home/checkpoint.err" || status=$?
  expect_code 0 "$status" "the takeover checkpoint: $(cat "$out" "$home/checkpoint.err")"
  assert_contains "$(cat "$out")" "check: rearm-resurface" "the checkpoint did not announce the gap the takeover left"
  wait_until_gone "$LEFTOVER_PID" 50 || { kill -TERM "$LEFTOVER_PID" 2>/dev/null; fail "the leftover away daemon is still running after the checkpoint"; }
  ! pid_running "$old_watcher" || fail "the leftover daemon's watcher is still running after the checkpoint"
  ack_wakes "$home" || fail "the attended drain could not acknowledge the takeover wake"

  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$CHECKPOINT" --seconds 30 >"$out" 2>"$home/checkpoint.err" &
  checkpoint=$!
  i=0
  while [ "$i" -lt 100 ]; do
    watcher=$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)
    [ -z "$watcher" ] || ! pid_running "$watcher" || break
    pid_running "$checkpoint" || break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(ps -o ppid= -p "$watcher" 2>/dev/null | tr -d ' ')" != "$LEFTOVER_PID" ] \
    || fail "the home watcher still belongs to the leftover daemon"
  sleep 1
  printf 'done [at=%s]: PR https://example.test/pr/88 checks green\n' "$(date +%s)" >> "$home/state/task-w8.status"
  status=0
  wait "$checkpoint" || status=$?
  expect_code 0 "$status" "checkpoint after the takeover: $(cat "$out" "$home/checkpoint.err")"
  assert_contains "$(cat "$out")" "signal:" "the checkpoint did not report the done handoff"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null)
  assert_contains "$drained" "task-w8" "the attended drain does not show the done handoff"
  pass "checkpoint: with away mode off, it stops a leftover away daemon and its watcher, and worker events reach the attended drain"
}

test_checkpoint_keeps_an_away_daemon_while_away_mode_is_on() {
  local home out status
  home=$(make_home away-daemon)
  out="$home/out.txt"
  date '+%s' > "$home/state/.afk"
  start_leftover_daemon "$home"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$CHECKPOINT" --seconds 2 >"$out" 2>"$home/checkpoint.err" || status=$?
  expect_code 1 "$status" "checkpoint beside an away daemon"
  assert_contains "$(cat "$home/checkpoint.err")" "outside this foreground checkpoint" "the checkpoint must report the away daemon's watcher"
  pid_running "$LEFTOVER_PID" || fail "the checkpoint stopped an away daemon while away mode was on"
  kill -TERM "$LEFTOVER_PID" 2>/dev/null || true
  wait_until_gone "$LEFTOVER_PID" 50 || true
  pass "checkpoint: while away mode is on, it leaves the away daemon and its watcher running"
}

test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_checkpoint_takes_over_a_watcher_owned_by_a_leftover_away_daemon
test_checkpoint_keeps_an_away_daemon_while_away_mode_is_on
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_host_checkpoint_bounds_the_park_by_posture
test_host_checkpoint_passes_a_handback_and_reports_a_stand_down
test_host_checkpoint_needs_the_file_and_honors_off
test_real_host_checkpoint_ends_quietly_at_its_bound
