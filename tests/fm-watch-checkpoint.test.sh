#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)
SESSION_TEST_PIDS=()
SESSION_TEST_RELEASES=()
cleanup_session_tests() {
  local pid release
  for release in "${SESSION_TEST_RELEASES[@]}"; do
    [ ! -d "${release%/*}" ] || : > "$release"
  done
  fm_test_cleanup
  for pid in "${SESSION_TEST_PIDS[@]}"; do
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
}
trap cleanup_session_tests EXIT

session_process_alive() {
  local stat
  stat=$(ps -o stat= -p "$1" 2>/dev/null) || return 1
  case "$stat" in ''|*Z*) return 1 ;; esac
}

wait_session_watcher() { # <home> <live|gone>
  local home=$1 expected=$2 i=0 pid
  while [ "$i" -lt 200 ]; do
    pid=$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)
    if [ "$expected" = live ]; then
      if [ -n "$pid" ] && [ -e "$home/state/.last-watcher-beat" ] && session_process_alive "$pid"; then
        return 0
      fi
    elif ! session_process_alive "$SESSION_WATCH_PID"; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  fail "session watcher did not become $expected: $(cat "$home/arm.out" "$home/arm.err")"
}

start_session_owner() {
  sleep 120 &
  SESSION_OWNER_PID=$!
  SESSION_TEST_PIDS+=("$SESSION_OWNER_PID")
}

launch_session_watcher() {
  local home=$1 interval=${2:-999999}
  printf '%s\n' "$SESSION_OWNER_PID" > "$home/state/.lock"
  fm_test_track_watcher_state "$home/state"
  FM_HOME="$home" FM_POLL=30 FM_CHECK_INTERVAL="$interval" FM_HEARTBEAT=999999 \
    bash -c '
      printf "%s\n" "$$" > "$FM_HOME/launcher.pid"
      exec "$0"
    ' "$ROOT/bin/fm-watch-arm.sh" >"$home/arm.out" 2>"$home/arm.err" &
  SESSION_ARM_PID=$!
  SESSION_TEST_PIDS+=("$SESSION_ARM_PID")
}

start_session_watcher() { # <home> [check-interval]
  local home=$1
  launch_session_watcher "$@"
  wait_session_watcher "$home" live
  SESSION_WATCH_PID=$(cat "$home/state/.watch.lock/pid")
}

publish_session_owner() {
  FM_HOME="$1" bash -c '
    . "$1"
    fm_lock_acquire_wait "$STATE/.lock.acquire"
    printf "%s\n" "$2" > "$STATE/.lock"
    fm_lock_release "$STATE/.lock.acquire"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$2" || fail "replacement publication failed"
}

make_session_startup_barrier() {
  local home=$1
  mkdir -p "$home/fakebin"
  command -v ps > "$home/real-ps"
  SESSION_TEST_RELEASES+=("$home/identity-release")
  cat > "$home/fakebin/ps" <<'SH'
#!/usr/bin/env bash
launcher=$(cat "$FM_HOME/launcher.pid" 2>/dev/null || true)
if [ "${1:-}" = -p ] && [ "${2:-}" = "$launcher" ] \
  && [ "${3:-}" = -o ] && [ "${4:-}" = lstart= ] \
  && [ -f "$FM_HOME/state/.watch.lock/pid-identity" ] \
  && mkdir "$FM_HOME/identity-gate" 2>/dev/null; then
  : > "$FM_HOME/identity-requested"
  while [ ! -e "$FM_HOME/identity-release" ]; do sleep 0.05; done
fi
exec "$(cat "$FM_HOME/real-ps")" "$@"
SH
  chmod +x "$home/fakebin/ps"
}

wait_session_startup_barrier() {
  local home=$1 i=0
  while [ ! -e "$home/identity-requested" ] && [ "$i" -lt 200 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$home/identity-requested" ] || fail "watcher never requested its launcher's startup identity: $(cat "$home/arm.err")"
  SESSION_WATCH_PID=$(cat "$home/state/.watch.lock/pid")
  session_process_alive "$SESSION_WATCH_PID" || fail "watcher exited before startup was released"
  assert_absent "$home/state/.last-watcher-beat" "watcher reached its poll before startup was released"
}

# The real arm remains alive after its session owner exits, reproducing a
# detached background task. No pane or harness process-name fixture is involved.
test_session_exit_stops_only_its_watcher() {
  local home other owner watcher other_watcher other_owner
  home=$(make_home owner-exit)
  other=$(make_home other-owner)
  start_session_owner
  owner=$SESSION_OWNER_PID
  start_session_watcher "$home"
  watcher=$SESSION_WATCH_PID
  start_session_owner
  other_owner=$SESSION_OWNER_PID
  start_session_watcher "$other"
  other_watcher=$SESSION_WATCH_PID
  kill -TERM "$owner"
  wait "$owner" || true
  SESSION_WATCH_PID=$watcher
  wait_session_watcher "$home" gone
  session_process_alive "$other_watcher" || fail "owner exit stopped another home's watcher"
  session_process_alive "$other_owner" || fail "owner exit stopped another home's session"
  assert_absent "$home/state/.watch.lock/pid" "owner exit retained the watcher singleton"
  assert_contains "$(cat "$home/arm.err")" 'session owner exited' "owner exit was not diagnosed"
  FM_HOME="$other" "$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null
  pass "session exit promptly stops its real watcher and preserves another home"
}

test_replacement_owner_preserves_supervision_until_it_exits() {
  local home old_owner replacement watcher old_arm
  home=$(make_home replacement-owner)
  start_session_owner
  old_owner=$SESSION_OWNER_PID
  start_session_watcher "$home"
  watcher=$SESSION_WATCH_PID
  old_arm=$SESSION_ARM_PID
  start_session_owner
  replacement=$SESSION_OWNER_PID
  # Publish through the same claim lock used by fm-lock.sh; a late old exit
  # must see the replacement before deciding whether to stop this watcher.
  publish_session_owner "$home" "$replacement"
  kill -TERM "$old_owner"
  wait "$old_owner" || true
  sleep 2
  session_process_alive "$watcher" || fail "old owner exit killed a live replacement's watcher"
  kill -KILL "$old_arm"
  wait "$old_arm" 2>/dev/null || true
  # Both postures and active work retain supervision while that owner lives.
  printf 'working: active work\n' > "$home/state/task.status"
  : > "$home/state/.afk"
  sleep 2
  session_process_alive "$watcher" || fail "away posture lost a live owner's watcher"
  printf 'quiet\n' > "$home/state/.afk"
  sleep 2
  session_process_alive "$watcher" || fail "quiet posture lost a live owner's watcher"
  kill -TERM "$replacement"
  wait "$replacement" || true
  SESSION_WATCH_PID=$watcher
  wait_session_watcher "$home" gone
  pass "replacement ownership preserves supervision through old exit and stops at new exit"
}

test_launcher_exit_stops_watcher_with_a_live_shared_owner() {
  local home owner arm watcher
  home=$(make_home launcher-exit)
  start_session_owner
  owner=$SESSION_OWNER_PID
  start_session_watcher "$home"
  arm=$SESSION_ARM_PID
  watcher=$SESSION_WATCH_PID
  # A chat closing while BOTH kernel processes stay alive has no observable
  # exit here. Keep the watcher alive instead of inventing per-chat liveness.
  sleep 2
  session_process_alive "$owner" || fail "shared owner was not live in the unsupported-chat-exit case"
  session_process_alive "$arm" || fail "launcher was not live in the unsupported-chat-exit case"
  session_process_alive "$watcher" || fail "live processes were mistaken for an observed session exit"
  # Model a shared server staying alive after the session-scoped tool process
  # disappears. SIGKILL prevents the arm's ordinary cleanup from masking it.
  kill -KILL "$arm"
  wait "$arm" 2>/dev/null || true
  SESSION_WATCH_PID=$watcher
  wait_session_watcher "$home" gone
  session_process_alive "$owner" || fail "launcher exit killed the shared owner process"
  assert_contains "$(cat "$home/arm.err")" 'session launcher exited' "launcher exit was not diagnosed"
  pass "launcher exit stops its watcher even while a shared owner process remains alive"
}

test_live_owner_with_unreadable_identity_retains_supervision() {
  local home owner watcher
  home=$(make_home unreadable-owner)
  start_session_owner
  owner=$SESSION_OWNER_PID
  mkdir -p "$home/proc/$owner"
  printf '%s (sleep) S\n' "$owner" > "$home/proc/$owner/stat"
  printf 'sleep\0' > "$home/proc/$owner/cmdline"
  if FM_PROC_ROOT_OVERRIDE="$home/proc" bash -c '. "$1"; fm_pid_identity "$2"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$owner" >/dev/null; then
    fail "the live owner's identity was readable in the unreadable-identity fixture"
  fi
  FM_PROC_ROOT_OVERRIDE="$home/proc" start_session_watcher "$home"
  watcher=$SESSION_WATCH_PID
  sleep 2
  session_process_alive "$owner" || fail "the unreadable owner exited before the assertion"
  session_process_alive "$watcher" || fail "unreadable identity stopped a live owner's watcher"
  session_process_alive "$SESSION_ARM_PID" || fail "unreadable identity stopped the live arm"
  kill -TERM "$owner"
  wait "$owner" || true
  SESSION_WATCH_PID=$watcher
  wait_session_watcher "$home" gone
  assert_contains "$(cat "$home/arm.err")" 'session owner exited' "unreadable identity disabled owner-exit detection"
  pass "a live owner with unreadable identity retains supervision until it exits"
}

test_launcher_exit_before_identity_capture_stops_watcher() {
  local home owner arm
  home=$(make_home launcher-startup-exit)
  make_session_startup_barrier "$home"
  start_session_owner
  owner=$SESSION_OWNER_PID
  PATH="$home/fakebin:$PATH" FM_PROC_ROOT_OVERRIDE="$home/no-proc" launch_session_watcher "$home"
  arm=$SESSION_ARM_PID
  wait_session_startup_barrier "$home"
  kill -KILL "$arm"
  wait "$arm" 2>/dev/null || true
  : > "$home/identity-release"
  wait_session_watcher "$home" gone
  session_process_alive "$owner" || fail "startup launcher exit killed the shared owner"
  assert_absent "$home/state/.watch.lock/pid" "startup launcher exit retained the watcher singleton"
  assert_contains "$(cat "$home/arm.err")" 'session launcher exited' "startup launcher exit was not diagnosed"
  pass "launcher exit before identity capture stops its watcher with a live shared owner"
}

test_replacement_before_first_owner_observation_preserves_supervision() {
  local home owner replacement watcher arm holder i=0
  home=$(make_home replacement-before-monitor)
  start_session_owner
  owner=$SESSION_OWNER_PID
  start_session_owner
  replacement=$SESSION_OWNER_PID
  SESSION_TEST_RELEASES+=("$home/ownership-release")
  FM_HOME="$home" bash -c '
    . "$1"
    fm_lock_acquire_wait "$STATE/.lock.acquire"
    trap '\''fm_lock_release "$STATE/.lock.acquire"'\'' EXIT
    : > "$FM_HOME/ownership-held"
    while [ ! -e "$FM_HOME/ownership-release" ]; do sleep 0.05; done
    printf "%s\n" "$2" > "$STATE/.lock"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$replacement" &
  holder=$!
  SESSION_TEST_PIDS+=("$holder")
  while [ ! -e "$home/ownership-held" ] && [ "$i" -lt 200 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$home/ownership-held" ] || fail "the fixture never excluded the monitor's first ownership observation"
  SESSION_OWNER_PID=$owner
  start_session_watcher "$home"
  arm=$SESSION_ARM_PID
  watcher=$SESSION_WATCH_PID
  kill -TERM "$owner"
  wait "$owner" || true
  kill -KILL "$arm"
  wait "$arm" 2>/dev/null || true
  : > "$home/ownership-release"
  wait "$holder" || fail "the fixture could not publish replacement ownership"
  sleep 2
  session_process_alive "$replacement" || fail "the replacement owner exited before the assertion"
  session_process_alive "$watcher" || fail "a replacement published before monitor startup lost its watcher"
  [ "$(cat "$home/state/.watch.lock/pid")" = "$watcher" ] || fail "replacement changed the watcher singleton"
  kill -TERM "$replacement"
  wait "$replacement" || true
  SESSION_WATCH_PID=$watcher
  wait_session_watcher "$home" gone
  pass "replacement before the monitor's first observation survives the old launcher and stops at its own exit"
}

test_owner_exit_stops_a_blocked_check() {
  local home owner watcher check_pid i=0
  home=$(make_home blocked-owner-exit)
  cat > "$home/state/blocked.check.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/check.pid"
exec sleep 120
SH
  chmod 0700 "$home/state/blocked.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" blocked >/dev/null || fail "check registration failed"
  start_session_owner
  owner=$SESSION_OWNER_PID
  start_session_watcher "$home" 1
  watcher=$SESSION_WATCH_PID
  while [ "$i" -lt 200 ] && [ ! -s "$home/check.pid" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$home/check.pid" ] || fail "the real watcher never entered the blocked check"
  check_pid=$(cat "$home/check.pid")
  session_process_alive "$check_pid" || fail "the check was not blocked at owner exit"
  kill -TERM "$owner"
  wait "$owner" || true
  SESSION_WATCH_PID=$watcher
  wait_session_watcher "$home" gone
  session_process_alive "$check_pid" && fail "owner exit left the blocked check running"
  pass "owner exit stops a real watcher blocked in a registered check and reaps that check"
}

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
  local home out err status watcher_pid
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  watcher_pid=$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)
  if [ -n "$watcher_pid" ] && session_process_alive "$watcher_pid"; then
    fail "quiet checkpoint left a watcher running"
  fi
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_perl_timeout_fallback_honors_cleanup_bound_before_escalating() {
  local home fallback_bin tool tool_path status watcher_pid
  home=$(make_home perl-fallback)
  fallback_bin="$home/fallback-bin"
  mkdir -p "$home/root/bin" "$fallback_bin"
  cp "$CHECKPOINT" "$home/root/bin/fm-watch-checkpoint.sh"
  cp "$ROOT/bin/fm-supervision-engine-lib.sh" "$home/root/bin/fm-supervision-engine-lib.sh"
  for tool in bash dirname mktemp rm perl grep cat; do
    tool_path=$(command -v "$tool") || fail "could not locate $tool for the Perl fallback fixture"
    ln -s "$tool_path" "$fallback_bin/$tool"
  done
  cat > "$home/root/bin/fm-watch.sh" <<'PL'
#!/usr/bin/env perl
use strict;
use warnings;
$SIG{INT} = 'IGNORE';
open my $pid_file, '>', "$ENV{FM_HOME}/watcher.pid" or die "open pid file: $!";
printf {$pid_file} "%s\n", $$;
close $pid_file;
sleep 7;
open my $cleanup_file, '>', "$ENV{FM_HOME}/cleanup-reached" or die "open cleanup marker: $!";
print {$cleanup_file} "reached\n";
close $cleanup_file;
END {
  if (open my $exit_file, '>', "$ENV{FM_HOME}/natural-exit") {
    print {$exit_file} "natural\n";
  }
}
sleep 20;
PL
  chmod +x "$home/root/bin/fm-watch-checkpoint.sh" "$home/root/bin/fm-watch.sh"

  status=0
  PATH="$fallback_bin" FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_WATCHER_CLEANUP_LOCK_BOUND=8 \
    "$home/root/bin/fm-watch-checkpoint.sh" --seconds 1 >"$home/out.txt" 2>"$home/err.txt" || status=$?

  expect_code 124 "$status" "Perl fallback checkpoint exit"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 1s" \
    "Perl fallback did not return a quiet checkpoint"
  [ -e "$home/cleanup-reached" ] || fail "the Perl fallback killed the watcher before its 8-second cleanup bound"
  [ ! -e "$home/natural-exit" ] || fail "the INT-ignoring watcher exited naturally instead of being killed"
  [ -s "$home/watcher.pid" ] || fail "the INT-ignoring watcher did not start"
  watcher_pid=$(cat "$home/watcher.pid")
  if kill -0 "$watcher_pid" 2>/dev/null; then
    fail "the INT-ignoring watcher survived the Perl fallback escalation"
  fi
  pass "Perl fallback honors the cleanup bound before escalating an INT-ignoring direct watcher"
}

test_announced_recovery_is_not_reannounced_by_next_checkpoint() {
  local home out err status marker
  home=$(make_home announced-recovery)
  out="$home/out.txt"
  err="$home/err.txt"
  append_wake "$home/state" check buried 'check: unacknowledged durable wake' \
    || fail "could not append the unacknowledged durable wake"

  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "first recovery checkpoint exit"
  assert_contains "$(cat "$out")" "check: rearm-resurface" \
    "first checkpoint did not announce the pending recovery"
  marker=$(cat "$home/state/.watcher-down")
  case "$marker" in
    announced:downtime:*) ;;
    *) fail "first checkpoint did not leave an announced generation: $marker" ;;
  esac
  [ -s "$home/state/.wake-queue" ] \
    || fail "durable wake did not stay unacknowledged after the announcement"

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
  grep "$(printf '\tcheck\tburied\tcheck: unacknowledged durable wake')" \
    "$home/state/.wake-queue" >/dev/null \
    || fail "unacknowledged durable wake was not retained"
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

test_quiet_checkpoint_exits_124_cleanly
test_perl_timeout_fallback_honors_cleanup_bound_before_escalating
test_announced_recovery_is_not_reannounced_by_next_checkpoint
test_never_announced_recovery_is_announced_once
test_queue_append_during_checkpoint_still_resurfaces
test_session_exit_stops_only_its_watcher
test_replacement_owner_preserves_supervision_until_it_exits
test_launcher_exit_stops_watcher_with_a_live_shared_owner
test_live_owner_with_unreadable_identity_retains_supervision
test_launcher_exit_before_identity_capture_stops_watcher
test_replacement_before_first_owner_observation_preserves_supervision
test_owner_exit_stops_a_blocked_check
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_host_checkpoint_bounds_the_park_by_posture
test_host_checkpoint_passes_a_handback_and_reports_a_stand_down
test_host_checkpoint_needs_the_file_and_honors_off
test_real_host_checkpoint_ends_quietly_at_its_bound
