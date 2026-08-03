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
#   EXTERNAL watcher owner (the Pi shape, where the tracked extension arms and
#     holds the singleton): the daemon classifies from the durable wake queue
#     instead of idling on a child that can never win the lock - captain-relevant
#     records escalate, routine records stay silent, the queue is never consumed
#     destructively, and a replayed batch cannot double-escalate
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

# The lock/queue helpers the daemon itself sources at runtime (inside
# fm_super_main, which sourcing skips). fm_watcher_healthy takes its state root as
# an argument, so one top-level source serves every case; only the queue path
# globals are state-scoped, and consume_once below re-sources for those.
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"

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

# --- Phase 1: routine self-handled, queued; terminal caught after restart ---
test_routine_then_terminal_after_restart() {
  local dir state fakebin out drain_out status_file
  dir=$(make_supercase wd-lifecycle)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  status_file="$state/task-w1.status"

  # A routine status fires a signal; the watcher queues it and exits.
  printf 'working: building\n' > "$status_file"
  run_watcher_once "$state" "$fakebin" "$out" || fail "watcher did not exit for the routine signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not report the routine signal"

  # Drain it and route through the daemon: a routine status self-handles.
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after routine signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null \
    || fail "routine signal was not queued"
  FM_STATE_OVERRIDE="$state" handle_wake "signal: $status_file" "$state"
  [ ! -s "$state/.subsuper-escalations" ] || fail "routine status was escalated by the daemon"

  # The watcher is now DOWN (one-shot exit). A terminal status lands while it is
  # down; the next watcher run must catch it up (losslessness across restart).
  printf 'done: PR https://example.test/pr/900\n' >> "$status_file"
  : > "$out"
  run_watcher_once "$state" "$fakebin" "$out" || fail "restarted watcher did not exit for the terminal signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "terminal signal written while watcher down was not caught on restart"

  # Drain and route the terminal: exactly ONE digest is buffered.
  : > "$drain_out"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after terminal signal failed"
  FM_STATE_OVERRIDE="$state" handle_wake "signal: $status_file" "$state"
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
  : > "$dir/pane.txt"
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

# --- Phase 3: an EXTERNAL watcher owns the cycle ----------------------------
# The Pi shape: .pi/extensions/fm-primary-pi-watch.ts arms bin/fm-watch-arm.sh and
# keeps that watcher attached to the live Pi process, so the EXTENSION holds the
# home singleton and the daemon's own child exits with "watcher: already running".
# The owner here is a real bin/fm-watch.sh - the same process the extension arms -
# so the contended lock, its identity record, and its liveness beacon are all
# genuine; only the wake records are appended directly (through the production
# fm_wake_append, exactly as that watcher would) to keep the phase deterministic.

# Start a real watcher that ACQUIRES the singleton and then sleeps, so it stays a
# healthy external owner for the rest of the case. A long FM_POLL keeps it parked:
# the state starts with no status files, so its first scan finds nothing to
# surface and it blocks instead of one-shot exiting. Echoes its pid.
start_external_watcher() {  # <dir> <state> <fakebin>
  local dir=$1 state=$2 fakebin=$3 pid i=0
  mkdir -p "$state"
  date '+%s' > "$state/.afk"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=60 \
    FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$dir/external.out" 2>&1 &
  pid=$!
  while [ "$i" -lt 100 ]; do
    [ -e "$state/.last-watcher-beat" ] && [ -n "$(cat "$state/.watch.lock/pid" 2>/dev/null)" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  printf '%s' "$pid"
}

stop_external_watcher() {  # <pid>
  local pid=$1
  [ -n "$pid" ] || return 0
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# Run the daemon's queue consumption against <state>. fm-wake-lib.sh is sourced in
# a subshell so FM_WAKE_QUEUE resolves to THIS case's state root; consume_wake_queue
# and handle_wake come from the daemon already sourced above.
consume_once() {  # <state>
  local state=$1
  # The queue paths are resolved with ${VAR:-default}, so the top-level source
  # above would otherwise pin them to ITS state root. Clear them first so this
  # case's root wins.
  ( unset FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
    FM_STATE_OVERRIDE="$state" . "$ROOT/bin/fm-wake-lib.sh"
    consume_wake_queue "$state" )
}

test_external_owner_consumes_queue_without_draining_it() {
  local dir state fakebin ext_pid queue_lines cursor
  dir=$(make_supercase wd-external-owner)
  state="$dir/state"
  fakebin="$dir/fakebin"

  ext_pid=$(start_external_watcher "$dir" "$state" "$fakebin")
  [ -n "$(cat "$state/.watch.lock/pid" 2>/dev/null)" ] \
    || { stop_external_watcher "$ext_pid"; fail "external watcher never acquired the singleton"; }

  # The daemon must recognise the external owner. Its own child is not running,
  # so no pid is passed as "ours".
  FM_HOME="$dir" daemon_external_watcher_owns "$state" "$WATCH" \
    || { stop_external_watcher "$ext_pid"; fail "a healthy external watcher was not detected as the cycle owner"; }

  # ...and must NOT mistake its OWN child for an external owner, or it would
  # starve itself the moment it did own the watcher.
  if FM_HOME="$dir" daemon_external_watcher_owns "$state" "$WATCH" "$(cat "$state/.watch.lock/pid")"; then
    stop_external_watcher "$ext_pid"
    fail "the daemon treated its own watcher child as an external owner"
  fi

  # A captain-relevant record, appended exactly as the owning watcher appends it.
  printf 'blocked: needs a credential\n' > "$state/ext-task.status"
  append_wake "$state" signal ext-task.status "signal: $state/ext-task.status"

  : > "$state/.subsuper-escalations" 2>/dev/null || true
  FM_HOME="$dir" consume_once "$state"

  [ -s "$state/.subsuper-escalations" ] \
    || { stop_external_watcher "$ext_pid"; fail "captain-relevant queued record did not escalate under an external owner"; }
  [ "$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')" -eq 1 ] \
    || { stop_external_watcher "$ext_pid"; fail "expected exactly one digest from one queued record"; }
  grep -F 'blocked: needs a credential' "$state/.subsuper-escalations" >/dev/null \
    || { stop_external_watcher "$ext_pid"; fail "the digest did not carry the captain-relevant status text"; }

  # NON-DESTRUCTIVE: the record is still queued for firstmate's own drain, which
  # is what keeps the away-mode return catch-up complete.
  queue_lines=$(wc -l < "$state/.wake-queue" | tr -d ' ')
  [ "$queue_lines" -eq 1 ] \
    || { stop_external_watcher "$ext_pid"; fail "consumption removed queue records (expected 1, got $queue_lines)"; }
  cursor=$(cat "$state/.subsuper-wake-cursor" 2>/dev/null || echo 0)
  [ "$cursor" -eq 1 ] \
    || { stop_external_watcher "$ext_pid"; fail "cursor did not advance to the consumed sequence (got '$cursor')"; }

  # Re-running must NOT re-escalate: the cursor is the no-double-handling boundary.
  FM_HOME="$dir" consume_once "$state"
  [ "$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')" -eq 1 ] \
    || { stop_external_watcher "$ext_pid"; fail "a second consumption re-escalated an already-classified record"; }

  # A routine record under the same external owner stays silent (away mode must
  # not become a firehose just because its input moved to the queue).
  printf 'working: still compiling\n' > "$state/ext-routine.status"
  append_wake "$state" signal ext-routine.status "signal: $state/ext-routine.status"
  FM_HOME="$dir" consume_once "$state"
  [ "$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')" -eq 1 ] \
    || { stop_external_watcher "$ext_pid"; fail "a routine queued record escalated under an external owner"; }

  stop_external_watcher "$ext_pid"
  pass "external owner: queued captain-relevant record escalates once, routine stays silent, queue survives for firstmate's drain"
}

test_external_owner_replay_is_lossless_and_not_duplicated() {
  local dir state fakebin ext_pid
  dir=$(make_supercase wd-external-replay)
  state="$dir/state"
  fakebin="$dir/fakebin"

  ext_pid=$(start_external_watcher "$dir" "$state" "$fakebin")
  printf 'failed: build broke\n' > "$state/replay-task.status"
  append_wake "$state" signal replay-task.status "signal: $state/replay-task.status"

  : > "$state/.subsuper-escalations" 2>/dev/null || true
  FM_HOME="$dir" consume_once "$state"
  [ "$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')" -eq 1 ] \
    || { stop_external_watcher "$ext_pid"; fail "queued terminal record did not escalate"; }

  # Simulate a daemon that crashed after classifying but BEFORE its cursor write:
  # on restart the batch replays. Nothing may be lost, and the seen-status dedupe
  # must stop the replay from double-escalating the same status line.
  rm -f "$state/.subsuper-wake-cursor"
  FM_HOME="$dir" consume_once "$state"
  [ "$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')" -eq 1 ] \
    || { stop_external_watcher "$ext_pid"; fail "a replayed batch double-escalated the same status line"; }

  # The record is still on the durable queue, so a drain after the away stretch
  # still recovers it even if the daemon never ran at all.
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" \
    || { stop_external_watcher "$ext_pid"; fail "drain after external-owner consumption failed"; }
  grep -F "signal: $state/replay-task.status" "$dir/drain.out" >/dev/null \
    || { stop_external_watcher "$ext_pid"; fail "consumed-but-undrained record was lost to firstmate's drain"; }

  stop_external_watcher "$ext_pid"
  pass "external owner: a replayed batch cannot double-escalate, and firstmate's drain still recovers the record"
}

test_dead_lock_holder_is_not_an_external_owner() {
  local dir state fakebin
  dir=$(make_supercase wd-external-dead)
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$state/.watch.lock"

  # A lock left behind by a process that is gone. The daemon must NOT treat this
  # as an external owner, or it would sit reading a queue nothing is filling.
  printf '999999\n' > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf 'stale-identity\n' > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"

  if FM_HOME="$dir" daemon_external_watcher_owns "$state" "$WATCH"; then
    fail "a lock held by a dead pid was treated as a healthy external owner"
  fi
  pass "external owner: a dead or stale lock holder never diverts the daemon from owning the cycle"
}

test_routine_then_terminal_after_restart
test_stale_pane_transient_persistent_resume
test_external_owner_consumes_queue_without_draining_it
test_external_owner_replay_is_lossless_and_not_duplicated
test_dead_lock_holder_is_not_an_external_owner
