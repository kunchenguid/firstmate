#!/usr/bin/env bash
# tests/fm-wake-daemon-lifecycle-e2e.test.sh - the watcher + supervise-daemon
# lifecycle, end to end, over one shared state root and a shimmed tmux:
#
#   routine status -> self-handled, queued
#   terminal status written while the watcher is DOWN -> caught on restart (catch-up)
#   drain queued records -> exactly ONE captain-relevant digest is buffered
#   housekeeping catch-all scan -> NO duplicate digest
#   buffered digest flushes to the supervisor pane as exactly ONE submission
#   stale working-pane: transient (self + marker) -> persistent (escalates once,
#     clears its marker) -> resumed/busy (clears without escalating)
#
# This proves the operator-visible routing/queueing/dedupe behavior through real
# fm-watch.sh runs plus the daemon's own functions. The captain-relevant
# status-phrase matrix and the lock-primitive races stay as focused units
# (fm-daemon.test.sh, fm-watcher-lock.test.sh) - an e2e cannot deterministically
# cover a race, and the phrase list is a product contract worth a dedicated test.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

# Source the daemon's pure functions (its main loop is guarded out under sourcing).
if [ -z "${FM_TEST_DAEMON_SOURCED:-}" ]; then
  export FM_TEST_DAEMON_SOURCED=1
  # shellcheck source=/dev/null
  . "$DAEMON"
fi

TMP_ROOT=$(fm_test_tmproot fm-wake-daemon-e2e)

# Run the daemon-managed watcher once: under the supervise-daemon (away mode) the
# watcher is one-shot - it exits with a single reason line on EVERY wake and the
# daemon does the triage. This e2e exercises exactly that path, so it runs with
# state/.afk present (which the daemon owns) to keep the watcher one-shot; the
# always-on standalone triage is covered by fm-watch-triage.test.sh. fakebin
# shadows tmux. Echoes nothing; the caller reads $out.
run_watcher_once() {
  local state=$1 fakebin=$2 out=$3
  mkdir -p "$state"
  date '+%s' > "$state/.afk"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 50
}

ack_handled_wakes() {  # <state> <drain-stderr>
  local state=$1 drain_err=$2 sequence generation
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$drain_err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$drain_err")
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

# --- Phase 1: routine self-handled, queued; terminal caught after restart ---
test_routine_then_terminal_after_restart() {
  local dir state fakebin out drain_out drain_err status_file
  dir=$(make_supercase wd-lifecycle)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  drain_err="$dir/drain.err"
  status_file="$state/task-w1.status"

  # A routine status fires a signal; the watcher queues it and exits.
  printf 'working: building\n' > "$status_file"
  run_watcher_once "$state" "$fakebin" "$out" || fail "watcher did not exit for the routine signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not report the routine signal"

  # Drain it and route through the daemon: a routine status self-handles.
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2> "$drain_err" \
    || fail "drain after routine signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null \
    || fail "routine signal was not queued"
  FM_STATE_OVERRIDE="$state" handle_wake "signal: $status_file" "$state"
  ack_handled_wakes "$state" "$drain_err" || fail "routine wake acknowledgement failed"
  [ ! -s "$state/.subsuper-escalations" ] || fail "routine status was escalated by the daemon"

  # The watcher is now DOWN (one-shot exit). A terminal status lands while it is
  # down; the next watcher run must catch it up (losslessness across restart).
  printf 'done: PR https://example.test/pr/900\n' >> "$status_file"
  : > "$out"
  run_watcher_once "$state" "$fakebin" "$out" || fail "restarted watcher did not exit for the terminal signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "terminal signal written while watcher down was not caught on restart"

  # Drain and route the terminal: exactly ONE digest is buffered.
  : > "$drain_out"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2> "$drain_err" \
    || fail "drain after terminal signal failed"
  FM_STATE_OVERRIDE="$state" handle_wake "signal: $status_file" "$state"
  ack_handled_wakes "$state" "$drain_err" || fail "terminal wake acknowledgement failed"
  [ -s "$state/.subsuper-escalations" ] || fail "captain-relevant terminal status was not buffered"
  [ "$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')" -eq 1 ] \
    || fail "expected exactly one buffered digest after the terminal signal"

  # The catch-all heartbeat scan must NOT re-escalate the same status (no dup).
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  [ "$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')" -eq 1 ] \
    || fail "catch-all scan duplicated the already-buffered digest"

  # With afk active, the buffered digest flushes to the supervisor pane as ONE
  # submission (one typed line + one Enter), then the buffer clears.
  local sent
  sent="$dir/sent.log"; : > "$sent"
  printf '❯\n' > "$dir/pane.txt"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" FM_ESCALATE_BATCH_SECS=0 escalate_flush "$state" \
    || fail "escalate_flush failed for the buffered digest"
  [ "$(grep -c '\[ENTER\]' "$sent")" -eq 1 ] || fail "buffered digest was not submitted exactly once"
  [ ! -s "$state/.subsuper-escalations" ] || fail "buffer not cleared after a successful flush"
  pass "lifecycle: routine self-handles, terminal survives a watcher restart, buffers once, no dup, injects once"
}

# --- Phase 2: stale working-pane transient -> persistent -> resumed ----------
test_stale_pane_transient_persistent_resume() {
  local dir state fakebin win key resumed_gen
  dir=$(make_supercase wd-stale)
  state="$dir/state"
  fakebin="$dir/fakebin"
  win="sess:fm-stale-w2"
  key=$(printf '%s' "stale-w2" | tr ':/.' '___')
  printf 'working: compiling\n' > "$state/stale-w2.status"

  # Transient: first stale observation self-handles and records a marker.
  stale_marker_record "$win" "$state"
  case "$(FM_STATE_OVERRIDE="$state" classify_stale "$win" "$state")" in
    self\|*) : ;;
    *) fail "transient stale did not self-handle" ;;
  esac
  [ -e "$state/.subsuper-stale-$key" ] || fail "transient stale did not record a persistence marker"

  # Persistent: the marker ages past the threshold and the pane is still idle, so
  # housekeeping escalates exactly once and clears the marker.
  printf 'idle prompt $\n' > "$dir/pane.txt"
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  : > "$state/.subsuper-escalations" 2>/dev/null || true
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state" \
    2>"$dir/housekeeping.err"
  [ ! -s "$dir/housekeeping.err" ] \
    || fail "missing task metadata leaked a raw read error: $(cat "$dir/housekeeping.err")"
  [ -s "$state/.subsuper-escalations" ] || fail "persistent stale did not escalate"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "stale marker not cleared after escalation"

  # Resumed: a fresh transient marker but the crew is provably working again ->
  # housekeeping clears the marker without escalating. The proof is the crew's
  # own semantic busy-state record (bin/fm-busy-lib.sh), not rendered pane text.
  stale_marker_record "$win" "$state"
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  printf 'Working...\n' > "$dir/pane.txt"
  fm_write_meta "$state/stale-w2.meta" "window=$win" "worktree=$dir/wt" "kind=ship" "harness=pi"
  resumed_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" stale-w2)
  "$ROOT/bin/fm-busy-event.sh" apply "$state" stale-w2 busy --gen "$resumed_gen" \
    --source pi-ext --event agent-start
  : > "$state/.subsuper-escalations"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "resumed stale marker was not cleared"
  [ ! -s "$state/.subsuper-escalations" ] || fail "resumed (busy) stale was escalated"
  pass "lifecycle: stale pane transient self-handles, persistent escalates once and clears, resumed clears quietly"
}

# --- Phase 3: a real daemon process ends with away mode or with its lock ------
# These run the executed daemon through its production entry (bin/fm-afk-start.sh)
# against the shimmed tmux pane, so its main loop, not its sourced functions, is
# what must notice that it is no longer needed.
DAEMON_PIDS=""
reap_daemons() {
  local pid
  for pid in $DAEMON_PIDS; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap reap_daemons EXIT

DAEMON_PID=
start_away_daemon() {  # <dir>
  local dir=$1 state="$1/state" i watcher
  date '+%s' > "$state/.afk"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_SUPERVISOR_TARGET=fakepane FM_SUPERVISOR_BACKEND=tmux FM_DAEMON_PRIMARY_HARNESS=unknown \
    FM_AFK_STATE_PREPARED=1 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_HEARTBEAT=999999 \
    FM_CHECK_INTERVAL=999999 FM_HOUSEKEEPING_TICK=1 FM_ESCALATE_BATCH_SECS=999 \
    FM_STALE_ESCALATE_SECS=999999 FM_MAX_DEFER_SECS=0 \
    "$ROOT/bin/fm-afk-start.sh" > "$dir/daemon.out" 2>&1 &
  DAEMON_PID=$!
  DAEMON_PIDS="$DAEMON_PIDS $DAEMON_PID"
  i=0
  while [ "$i" -lt 100 ]; do
    watcher=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    if [ -n "$watcher" ] && [ "$(ps -o ppid= -p "$watcher" 2>/dev/null | tr -d ' ')" = "$DAEMON_PID" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  fail "the away daemon never started its watcher: $(cat "$dir/daemon.out")"
}

daemon_gone_within() {  # <pid> <tenths>
  local i=0
  while [ "$i" -lt "$2" ] && is_live_non_zombie "$1"; do sleep 0.1; i=$((i + 1)); done
  ! is_live_non_zombie "$1"
}

test_daemon_exits_when_away_mode_ends_and_worker_events_reach_the_attended_drain() {
  local dir state armout drain_out arm_pid
  dir=$(make_supercase wd-afk-ends)
  state="$dir/state"
  armout="$dir/arm.out"
  drain_out="$dir/drain.out"
  start_away_daemon "$dir"

  # Away mode ends without the daemon being signalled - the lost-lock return.
  rm -f "$state/.afk"
  daemon_gone_within "$DAEMON_PID" 100 \
    || fail "the away daemon kept running after away mode ended"
  [ ! -e "$state/.supervise-daemon.pid" ] || fail "the exited daemon left its pid file"

  # A worker's done handoff, then the attended firstmate's own arm and drain.
  printf 'done [at=%s]: PR https://example.test/pr/77 checks green\n' "$(date +%s)" >> "$state/task-w7.status"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=30 \
    "$ROOT/bin/fm-watch-arm.sh" > "$armout" 2>&1 &
  arm_pid=$!
  wait_for_exit "$arm_pid" 400 >/dev/null 2>&1 || true
  grep -Eq '^(signal:|check:)' "$armout" || fail "the attended arm reported no wake: $(cat "$armout")"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "the attended drain failed"
  grep -q 'task-w7' "$drain_out" || fail "the attended drain does not show the done handoff: $(cat "$drain_out")"
  ! grep -qF 'pr/77' "$state/.subsuper-escalations" 2>/dev/null \
    || fail "the done handoff went to the away daemon's buffer instead of the attended firstmate"
  pass "lifecycle: an away daemon exits on its own when away mode ends, and worker events reach the attended drain"
}

test_daemon_exits_when_it_loses_its_lock() {
  local dir state lock holder
  dir=$(make_supercase wd-lock-lost)
  state="$dir/state"
  lock="$state/.supervise-daemon.lock"
  start_away_daemon "$dir"

  # Another daemon takes the singleton: the lock and the pid file now name it.
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_lock_remove_path "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$lock"
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2" || exit 1
    printf "%s\n" "$(cat "$2/pid")" > "$3"
    exec sleep 60
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$lock" "$state/.supervise-daemon.pid" &
  holder=$!
  DAEMON_PIDS="$DAEMON_PIDS $holder"
  daemon_gone_within "$DAEMON_PID" 100 \
    || fail "the away daemon kept running after another process took its lock"
  [ "$(cat "$lock/pid" 2>/dev/null)" = "$holder" ] || fail "the exiting daemon disturbed its successor's lock"
  [ "$(cat "$state/.supervise-daemon.pid" 2>/dev/null)" = "$holder" ] \
    || fail "the exiting daemon removed its successor's pid file"
  [ -e "$state/.afk" ] || fail "the exiting daemon cleared away mode"
  kill -TERM "$holder" 2>/dev/null || true
  pass "lifecycle: an away daemon that no longer holds its lock exits without touching its successor"
}

test_routine_then_terminal_after_restart
test_stale_pane_transient_persistent_resume
test_daemon_exits_when_away_mode_ends_and_worker_events_reach_the_attended_drain
test_daemon_exits_when_it_loses_its_lock
