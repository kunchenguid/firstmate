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
# fm-watch.sh and fm-supervise-daemon.sh processes. The captain-relevant
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

run_refill_cycle() {  # <home> <state> <fakebin> <out> <ready-file>
  local home=$1 state=$2 fakebin=$3 out=$4 ready_file=$5 pid
  rm -f "$state/.last-heartbeat"
  : > "$out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_HEARTBEAT_MAX=1 FM_REFILL_IDS_MAX=2 \
    FM_FAKE_READY_FILE="$ready_file" \
    "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 50 || fail "refill heartbeat watcher pass did not exit"
  grep -Fx heartbeat "$out" >/dev/null || fail "refill heartbeat watcher did not emit its wake reason"
}

heartbeat_cursor_seq() {
  sed -n '2p' "$1/.subsuper-heartbeat-state" 2>/dev/null
}

wait_for_heartbeat_cursor() {  # <state> <minimum-sequence>
  local state=$1 minimum=$2 i=0 seq
  while [ "$i" -lt 100 ]; do
    seq=$(heartbeat_cursor_seq "$state")
    case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
    [ "$seq" -ge "$minimum" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_for_enter_count() {  # <sent-log> <count>
  local sent=$1 count=$2 i=0 actual
  while [ "$i" -lt 100 ]; do
    actual=$(grep -c '^\[ENTER\]$' "$sent" 2>/dev/null || true)
    [ "$actual" -ge "$count" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_for_file_text() {  # <file> <fixed-text>
  local file=$1 expected=$2 i=0
  while [ "$i" -lt 100 ]; do
    grep -F "$expected" "$file" >/dev/null 2>&1 && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

heartbeat_observation_payload() {  # <state> <sequence>
  awk -F '\t' -v wanted="$2" \
    '$2 == wanted && $3 == "heartbeat" && $4 == "heartbeat" {
      sub(/^heartbeat /, "", $5)
      print $5
      exit
    }' \
    "$1/.subsuper-heartbeat-observations" "$1/.wake-queue" 2>/dev/null
}

file_occurrence_count() {  # <file> <fixed-text>
  awk -v needle="$2" '
    BEGIN { count = 0 }
    {
      line = $0
      while ((position = index(line, needle)) > 0) {
        count++
        line = substr(line, position + length(needle))
      }
    }
    END { print count }
  ' "$1" 2>/dev/null
}

wait_for_file_occurrence_count() {  # <file> <fixed-text> <minimum-count>
  local file=$1 expected=$2 minimum=$3 i=0 actual
  while [ "$i" -lt 100 ]; do
    actual=$(file_occurrence_count "$file" "$expected")
    [ "$actual" -ge "$minimum" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_for_file_empty() {  # <file>
  local file=$1 i=0
  while [ "$i" -lt 100 ]; do
    [ ! -s "$file" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_refill_heartbeat_dedupes_through_daemon_process() {
  (
    local dir state fakebin out sent pane ready_file daemon_pid baseline queued_seq evidence occurrence_before occurrence_after
    local corrupt_a_seq corrupt_b_seq corrupt_a_evidence corrupt_b_evidence corrupt_a_before corrupt_b_before
    local diagnostic diagnostic_before quarantine
    dir=$(make_supercase wd-refill-dedupe)
    state="$dir/state"
    fakebin="$dir/fakebin"
    out="$dir/watch.out"
    sent="$dir/sent.log"
    pane="$dir/pane.txt"
    ready_file="$dir/ready-case"
    daemon_pid=

    # shellcheck disable=SC2329 # Registered by the subshell's EXIT trap below.
    cleanup_refill_daemon() {
      [ -z "$daemon_pid" ] || ! kill -0 "$daemon_pid" 2>/dev/null \
        || { kill "$daemon_pid" 2>/dev/null || true; wait "$daemon_pid" 2>/dev/null || true; }
      fm_test_cleanup
    }
    trap cleanup_refill_daemon EXIT

    mkdir -p "$dir/config" "$dir/data"
    printf '# Backlog\n' > "$dir/data/backlog.md"
    : > "$sent"
    : > "$pane"
    printf 'initial\n' > "$ready_file"
    cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version|-v|-V) printf 'tasks-axi 0.2.5\n' ;;
  update) printf '%s\n' '--archive-body' ;;
  mv) printf '%s\n' '[<id>...]' ;;
  ready)
    case "$(cat "${FM_FAKE_READY_FILE:?}")" in
      initial) printf 'count: 4\nready[4]{id,state,kind,repo,title}:\n  beta,queued,task,"-",beta\n  alpha,queued,task,"-",alpha\n  hidden-a,queued,task,"-",hidden a\n  hidden-b,queued,task,"-",hidden b\n' ;;
      reordered) printf 'count: 4\nready[4]{id,state,kind,repo,title}:\n  beta,queued,task,"-",beta\n  alpha,queued,task,"-",alpha\n  hidden-b,queued,task,"-",hidden b\n  hidden-a,queued,task,"-",hidden a\n' ;;
      count-change) printf 'count: 5\nready[5]{id,state,kind,repo,title}:\n  beta,queued,task,"-",beta\n  alpha,queued,task,"-",alpha\n  hidden-a,queued,task,"-",hidden a\n  hidden-b,queued,task,"-",hidden b\n  hidden-c,queued,task,"-",hidden c\n' ;;
      replacement) printf 'count: 5\nready[5]{id,state,kind,repo,title}:\n  beta,queued,task,"-",beta\n  alpha,queued,task,"-",alpha\n  hidden-a,queued,task,"-",hidden a\n  hidden-b,queued,task,"-",hidden b\n  hidden-d,queued,task,"-",hidden d\n' ;;
      empty) printf 'count: 0\nready: 0 unblocked queued tasks\n' ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
SH
    chmod +x "$fakebin/tasks-axi"

    date '+%s' > "$state/.afk"
    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
      FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=fakepane \
      FM_FAKE_TMUX_CAPTURE="$pane" FM_FAKE_TMUX_SENT="$sent" FM_FAKE_READY_FILE="$ready_file" \
      FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_HEARTBEAT_MAX=1 \
      FM_REFILL_IDS_MAX=2 FM_ESCALATE_BATCH_SECS=0 FM_HOUSEKEEPING_TICK=999999 \
      "$DAEMON" > "$dir/daemon.out" 2> "$dir/daemon.err" &
    daemon_pid=$!
    wait_for_enter_count "$sent" 1 \
      || fail "the real away daemon did not inject the first refill digest: $(cat "$dir/daemon.err")"
    wait_for_file_empty "$state/.subsuper-escalations" \
      || fail "the first refill digest was delivered but not durably cleared"
    grep -F 'refill: ready=4 live=0 ids=beta,alpha fingerprint=' "$sent" >/dev/null \
      || fail "the first daemon digest omitted capped producer evidence"
    queued_seq=$(cat "$state/.wake-queue.seq")
    wait_for_heartbeat_cursor "$state" "$queued_seq" \
      || fail "the daemon did not commit the first durable heartbeat cursor"
    baseline=$(heartbeat_cursor_seq "$state")
    wait_for_heartbeat_cursor "$state" $((baseline + 1)) \
      || fail "the daemon did not process a repeated refill cycle"
    [ "$(grep -c '^\[ENTER\]$' "$sent" || true)" -eq 1 ] \
      || fail "unchanged refill state consumed another daemon injection"
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
    daemon_pid=

    printf 'reordered\n' > "$ready_file"
    run_refill_cycle "$dir" "$state" "$fakebin" "$out" "$ready_file"
    queued_seq=$(cat "$state/.wake-queue.seq")

    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
      FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=fakepane \
      FM_FAKE_TMUX_CAPTURE="$pane" FM_FAKE_TMUX_SENT="$sent" FM_FAKE_READY_FILE="$ready_file" \
      FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_HEARTBEAT_MAX=1 \
      FM_REFILL_IDS_MAX=2 FM_ESCALATE_BATCH_SECS=0 FM_HOUSEKEEPING_TICK=999999 \
      "$DAEMON" > "$dir/reordered.out" 2> "$dir/reordered.err" &
    daemon_pid=$!
    wait_for_heartbeat_cursor "$state" "$queued_seq" \
      || fail "the restarted daemon did not process reordered refill evidence"
    [ "$(grep -c '^\[ENTER\]$' "$sent" || true)" -eq 1 ] \
      || fail "canonical ready-id reordering changed the refill identity"
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
    daemon_pid=

    printf 'count-change\n' > "$ready_file"
    run_refill_cycle "$dir" "$state" "$fakebin" "$out" "$ready_file"
    queued_seq=$(cat "$state/.wake-queue.seq")
    evidence=$(heartbeat_observation_payload "$state" "$queued_seq")
    [ -n "$evidence" ] || fail "the ready-set count change lacked durable producer evidence"
    occurrence_before=$(file_occurrence_count "$sent" "$evidence")
    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
      FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=fakepane \
      FM_FAKE_TMUX_CAPTURE="$pane" FM_FAKE_TMUX_SENT="$sent" FM_FAKE_READY_FILE="$ready_file" \
      FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_HEARTBEAT_MAX=1 \
      FM_REFILL_IDS_MAX=2 FM_ESCALATE_BATCH_SECS=0 FM_HOUSEKEEPING_TICK=999999 \
      "$DAEMON" > "$dir/count-change.out" 2> "$dir/count-change.err" &
    daemon_pid=$!
    wait_for_heartbeat_cursor "$state" "$queued_seq" \
      || fail "the daemon did not process a ready-set count change"
    wait_for_file_occurrence_count "$sent" "$evidence" $((occurrence_before + 1)) \
      || fail "a ready-set change beyond capped display ids was suppressed"
    wait_for_file_empty "$state/.subsuper-escalations" \
      || fail "the ready-set count change was delivered but not durably cleared"
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
    daemon_pid=

    printf 'replacement\n' > "$ready_file"
    run_refill_cycle "$dir" "$state" "$fakebin" "$out" "$ready_file"
    queued_seq=$(cat "$state/.wake-queue.seq")
    evidence=$(heartbeat_observation_payload "$state" "$queued_seq")
    [ -n "$evidence" ] || fail "the ready-set replacement lacked durable producer evidence"
    occurrence_before=$(file_occurrence_count "$sent" "$evidence")
    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
      FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=fakepane \
      FM_FAKE_TMUX_CAPTURE="$pane" FM_FAKE_TMUX_SENT="$sent" FM_FAKE_READY_FILE="$ready_file" \
      FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_HEARTBEAT_MAX=1 \
      FM_REFILL_IDS_MAX=2 FM_ESCALATE_BATCH_SECS=0 FM_HOUSEKEEPING_TICK=999999 \
      "$DAEMON" > "$dir/replacement.out" 2> "$dir/replacement.err" &
    daemon_pid=$!
    wait_for_heartbeat_cursor "$state" "$queued_seq" \
      || fail "the daemon did not process a same-count ready-set replacement"
    wait_for_file_occurrence_count "$sent" "$evidence" $((occurrence_before + 1)) \
      || fail "a same-count ready-set replacement beyond capped display ids was suppressed"
    wait_for_file_empty "$state/.subsuper-escalations" \
      || fail "the ready-set replacement was delivered but not durably cleared"
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
    daemon_pid=

    printf 'empty\n' > "$ready_file"
    run_refill_cycle "$dir" "$state" "$fakebin" "$out" "$ready_file"
    FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/orphan-drain.out" \
      || fail "primary-session catch-up could not drain the orphaned empty heartbeat"
    grep -F 'refill: ready=0 live=0' "$dir/orphan-drain.out" >/dev/null \
      || fail "the crash-orphan drain fixture did not consume the empty main-queue heartbeat"
    printf 'broken\n' > "$state/.wake-queue.seq"
    printf 'replacement\n' > "$ready_file"
    run_refill_cycle "$dir" "$state" "$fakebin" "$out" "$ready_file"
    queued_seq=$(cat "$state/.wake-queue.seq")
    evidence=$(heartbeat_observation_payload "$state" "$queued_seq")
    [ -n "$evidence" ] || fail "the post-drain replacement lacked durable producer evidence"
    occurrence_before=$(file_occurrence_count "$sent" "$evidence")
    [ "$queued_seq" -gt "$(heartbeat_cursor_seq "$state")" ] \
      || fail "a malformed queue sequence regressed behind the durable heartbeat acknowledgement"

    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
      FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=fakepane \
      FM_FAKE_TMUX_CAPTURE="$pane" FM_FAKE_TMUX_SENT="$sent" FM_FAKE_READY_FILE="$ready_file" \
      FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_HEARTBEAT_MAX=1 \
      FM_REFILL_IDS_MAX=2 FM_ESCALATE_BATCH_SECS=0 FM_HOUSEKEEPING_TICK=999999 \
      "$DAEMON" > "$dir/restart.out" 2> "$dir/restart.err" &
    daemon_pid=$!
    wait_for_heartbeat_cursor "$state" "$queued_seq" \
      || fail "the restarted daemon did not replay drained and queued heartbeat transitions in order"
    wait_for_file_occurrence_count "$sent" "$evidence" $((occurrence_before + 1)) \
      || fail "the queued empty-to-nonempty transition was suppressed after restart"
    wait_for_file_empty "$state/.subsuper-escalations" \
      || fail "the empty-to-nonempty transition was delivered but not durably cleared"
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
    daemon_pid=
    occurrence_after=$(file_occurrence_count "$sent" "$evidence")
    [ "$occurrence_after" -eq $((occurrence_before + 1)) ] \
      || fail "restart replay injected a duplicate refill digest"

    printf 'count-change\n' > "$ready_file"
    run_refill_cycle "$dir" "$state" "$fakebin" "$out" "$ready_file"
    queued_seq=$(cat "$state/.wake-queue.seq")
    evidence=$(heartbeat_observation_payload "$state" "$queued_seq")
    [ -n "$evidence" ] || fail "the pre-ack crash observation lacked durable producer evidence"
    occurrence_before=$(file_occurrence_count "$sent" "$evidence")
    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
      FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=fakepane \
      FM_FAKE_TMUX_CAPTURE="$pane" FM_FAKE_TMUX_SENT="$sent" FM_FAKE_READY_FILE="$ready_file" \
      FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_HEARTBEAT_MAX=1 \
      FM_REFILL_IDS_MAX=2 FM_ESCALATE_BATCH_SECS=999 FM_HOUSEKEEPING_TICK=999999 \
      FM_HEARTBEAT_TEST_FAIL_BEFORE_ACK=1 \
      "$DAEMON" > "$dir/pre-ack-crash.out" 2> "$dir/pre-ack-crash.err" &
    daemon_pid=$!
    wait_for_file_text "$state/.subsuper-escalations" "$evidence" \
      || fail "the pre-ack crash fixture never durably appended its refill digest"
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
    daemon_pid=
    wait_for_file_occurrence_count "$sent" "$evidence" $((occurrence_before + 1)) \
      || fail "daemon cleanup did not deliver the pre-ack refill digest"
    [ "$(heartbeat_cursor_seq "$state")" -lt "$queued_seq" ] \
      || fail "the pre-ack crash fixture unexpectedly acknowledged its observation"

    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
      FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=fakepane \
      FM_FAKE_TMUX_CAPTURE="$pane" FM_FAKE_TMUX_SENT="$sent" FM_FAKE_READY_FILE="$ready_file" \
      FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_HEARTBEAT_MAX=1 \
      FM_REFILL_IDS_MAX=2 FM_ESCALATE_BATCH_SECS=0 FM_HOUSEKEEPING_TICK=999999 \
      "$DAEMON" > "$dir/at-least-once-replay.out" 2> "$dir/at-least-once-replay.err" &
    daemon_pid=$!
    wait_for_heartbeat_cursor "$state" "$queued_seq" \
      || fail "the restarted daemon suppressed its unacknowledged refill observation"
    wait_for_file_occurrence_count "$sent" "$evidence" $((occurrence_before + 2)) \
      || fail "the restarted daemon did not redeliver the unacknowledged refill digest"
    wait_for_file_empty "$state/.subsuper-escalations" \
      || fail "the redelivered refill digest was not durably cleared"
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
    daemon_pid=
    occurrence_after=$(file_occurrence_count "$sent" "$evidence")
    [ "$occurrence_after" -eq $((occurrence_before + 2)) ] \
      || fail "the acknowledged crash replay was delivered more than once"

    rm -f "$state/.subsuper-heartbeat-state"
    mkdir "$state/.subsuper-heartbeat-state"
    printf 'replacement\n' > "$ready_file"
    run_refill_cycle "$dir" "$state" "$fakebin" "$out" "$ready_file"
    corrupt_a_seq=$(cat "$state/.wake-queue.seq")
    corrupt_a_evidence=$(heartbeat_observation_payload "$state" "$corrupt_a_seq")
    [ -n "$corrupt_a_evidence" ] || fail "the first corrupt-state observation lacked durable evidence"
    corrupt_a_before=$(file_occurrence_count "$sent" "$corrupt_a_evidence")
    printf 'initial\n' > "$ready_file"
    run_refill_cycle "$dir" "$state" "$fakebin" "$out" "$ready_file"
    corrupt_b_seq=$(cat "$state/.wake-queue.seq")
    corrupt_b_evidence=$(heartbeat_observation_payload "$state" "$corrupt_b_seq")
    [ -n "$corrupt_b_evidence" ] || fail "the changed corrupt-state observation lacked durable evidence"
    corrupt_b_before=$(file_occurrence_count "$sent" "$corrupt_b_evidence")
    diagnostic="typed failure: malformed heartbeat acknowledgement quarantined; replaying unacknowledged refill observations at least once"
    diagnostic_before=$(file_occurrence_count "$sent" "$diagnostic")
    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
      FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=fakepane \
      FM_FAKE_TMUX_CAPTURE="$pane" FM_FAKE_TMUX_SENT="$sent" FM_FAKE_READY_FILE="$ready_file" \
      FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_HEARTBEAT_MAX=1 \
      FM_REFILL_IDS_MAX=2 FM_ESCALATE_BATCH_SECS=0 FM_HOUSEKEEPING_TICK=999999 \
      "$DAEMON" > "$dir/corrupt-state-replay.out" 2> "$dir/corrupt-state-replay.err" &
    daemon_pid=$!
    wait_for_heartbeat_cursor "$state" "$corrupt_b_seq" \
      || fail "malformed owned state starved a later changed refill observation"
    wait_for_file_occurrence_count "$sent" "$corrupt_a_evidence" $((corrupt_a_before + 1)) \
      || fail "the first observation behind malformed owned state was suppressed"
    wait_for_file_occurrence_count "$sent" "$corrupt_b_evidence" $((corrupt_b_before + 1)) \
      || fail "the changed observation behind malformed owned state was suppressed"
    wait_for_file_occurrence_count "$sent" "$diagnostic" $((diagnostic_before + 1)) \
      || fail "malformed owned state did not emit its typed diagnostic"
    wait_for_file_empty "$state/.subsuper-escalations" \
      || fail "the corrupt-state replay digest was delivered but not durably cleared"
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
    daemon_pid=
    [ -f "$state/.subsuper-heartbeat-state" ] \
      || fail "malformed owned state was not replaced by a regular acknowledgement"
    quarantine=$(find "$state" -maxdepth 1 -type d -name '.subsuper-heartbeat-state.corrupt.*' -print -quit)
    [ -n "$quarantine" ] && [ -d "$quarantine/state" ] && [ -f "$quarantine/reported" ] \
      || fail "malformed owned state was not preserved in a reported quarantine"
    trap - EXIT
  ) || fail "real away-daemon refill process case failed"
  pass "lifecycle: real away daemon replays pre-ack crashes and quarantined-state transitions"
}

test_routine_then_terminal_after_restart
test_stale_pane_transient_persistent_resume
test_refill_heartbeat_dedupes_through_daemon_process
