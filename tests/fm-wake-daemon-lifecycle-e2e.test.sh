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
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
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

# This deliberately drives the executable producer path instead of constructing
# a heartbeat payload. It is the regression for the overnight refill loop:
# watcher -> fm-refill -> durable queue -> away-supervisor routing.
run_refill_cycle() {  # <home> <state> <fakebin> <out> <ready-case>
  local home=$1 state=$2 fakebin=$3 out=$4 ready_case=$5 pid
  rm -f "$state/.last-heartbeat"
  : > "$out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_HEARTBEAT_MAX=1 FM_REFILL_IDS_MAX=2 \
    FM_FAKE_READY_CASE="$ready_case" \
    "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 50 || fail "refill heartbeat watcher pass ($ready_case) did not exit"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_latest_payload heartbeat heartbeat' \
    _ "$ROOT/bin/fm-wake-lib.sh"
}

test_refill_heartbeat_dedupes_after_real_producer_path() {
  local dir state fakebin out payload initial_fingerprint changed_fingerprint
  dir=$(make_supercase wd-refill-dedupe)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  mkdir -p "$dir/config" "$dir/data"
  printf '# Backlog\n' > "$dir/data/backlog.md"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version|-v|-V) printf 'tasks-axi 0.2.5\n' ;;
  update) printf '%s\n' '--archive-body' ;;
  mv) printf '%s\n' '[<id>...]' ;;
  ready)
    case "${FM_FAKE_READY_CASE:-initial}" in
      initial) printf 'count: 4\nready[4]{id,state,kind,repo,title}:\n  beta,queued,task,"-",beta\n  alpha,queued,task,"-",alpha\n  hidden-a,queued,task,"-",hidden a\n  hidden-b,queued,task,"-",hidden b\n' ;;
      reordered) printf 'count: 4\nready[4]{id,state,kind,repo,title}:\n  beta,queued,task,"-",beta\n  alpha,queued,task,"-",alpha\n  hidden-b,queued,task,"-",hidden b\n  hidden-a,queued,task,"-",hidden a\n' ;;
      count-change) printf 'count: 5\nready[5]{id,state,kind,repo,title}:\n  beta,queued,task,"-",beta\n  alpha,queued,task,"-",alpha\n  hidden-a,queued,task,"-",hidden a\n  hidden-b,queued,task,"-",hidden b\n  hidden-c,queued,task,"-",hidden c\n' ;;
      replacement) printf 'count: 5\nready[5]{id,state,kind,repo,title}:\n  beta,queued,task,"-",beta\n  alpha,queued,task,"-",alpha\n  hidden-a,queued,task,"-",hidden a\n  hidden-b,queued,task,"-",hidden b\n  hidden-d,queued,task,"-",hidden d\n' ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/tasks-axi"

  # A first real watcher pass produces the refill evidence and the supervisor
  # surfaces it once.
  date '+%s' > "$state/.afk"
  payload=$(run_refill_cycle "$dir" "$state" "$fakebin" "$out" initial)
  case "$payload" in
    'heartbeat refill: ready=4 live=0 ids=beta,alpha fingerprint='*) ;;
    *) fail "real refill producer did not queue capped evidence: $payload" ;;
  esac
  initial_fingerprint=${payload##* fingerprint=}
  FM_STATE_OVERRIDE="$state" FM_INJECT_SKIP=heartbeat handle_wake heartbeat "$state" "$payload"
  [ "$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')" -eq 1 ] \
    || fail "first real refill heartbeat did not reach one escalation"

  # Force the next scheduled heartbeat without changing fleet evidence. The
  # durable refill state survives the watcher restart and suppresses its digest.
  : > "$state/.subsuper-escalations"
  payload=$(run_refill_cycle "$dir" "$state" "$fakebin" "$out" reordered)
  [ "${payload##* fingerprint=}" = "$initial_fingerprint" ] \
    || fail "canonical ready-id ordering changed the producer fingerprint"
  FM_STATE_OVERRIDE="$state" FM_INJECT_SKIP=heartbeat handle_wake heartbeat "$state" "$payload"
  [ ! -s "$state/.subsuper-escalations" ] \
    || fail "unchanged real refill heartbeat created a second away digest"

  payload=$(run_refill_cycle "$dir" "$state" "$fakebin" "$out" count-change)
  case "$payload" in
    'heartbeat refill: ready=5 live=0 ids=beta,alpha fingerprint='*) ;;
    *) fail "count-change case did not preserve the capped display ids: $payload" ;;
  esac
  changed_fingerprint=${payload##* fingerprint=}
  [ "$changed_fingerprint" != "$initial_fingerprint" ] \
    || fail "a ready-count change beyond the display cap kept the old fingerprint"
  FM_STATE_OVERRIDE="$state" FM_INJECT_SKIP=heartbeat handle_wake heartbeat "$state" "$payload"
  [ "$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')" -eq 1 ] \
    || fail "a ready-count change beyond the display cap was suppressed"

  : > "$state/.subsuper-escalations"
  payload=$(run_refill_cycle "$dir" "$state" "$fakebin" "$out" replacement)
  case "$payload" in
    'heartbeat refill: ready=5 live=0 ids=beta,alpha fingerprint='*) ;;
    *) fail "replacement case did not preserve the capped display ids: $payload" ;;
  esac
  [ "${payload##* fingerprint=}" != "$changed_fingerprint" ] \
    || fail "a same-count replacement beyond the display cap kept the old fingerprint"
  FM_STATE_OVERRIDE="$state" FM_INJECT_SKIP=heartbeat handle_wake heartbeat "$state" "$payload"
  [ "$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')" -eq 1 ] \
    || fail "a same-count replacement beyond the display cap was suppressed"
  pass "lifecycle: refill dedupe covers complete canonical ready state behind capped display ids"
}

test_routine_then_terminal_after_restart
test_stale_pane_transient_persistent_resume
test_refill_heartbeat_dedupes_after_real_producer_path
