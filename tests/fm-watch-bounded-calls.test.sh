#!/usr/bin/env bash
# Behavior tests for hard bounds around supervision-loop dependencies.
# Each hanging dependency is exercised through a real watcher cycle. A passing
# case proves both that the cycle reaches an actionable exit and that its durable
# work remains eligible after the deadline path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-bounded-calls)
BASE_PATH=$PATH

assert_file() {  # <path> <message>
  [ -f "$1" ] || fail "$2"
}

wait_for_file() {  # <path>
  local path=$1
  for _ in $(seq 1 100); do
    [ -s "$path" ] && return 0
    sleep 0.02
  done
  return 1
}

make_lab() {  # <name>
  local name=$1 lab source
  lab="$TMP_ROOT/$name"
  mkdir -p "$lab/bin" "$lab/home/state" "$lab/fakebin"
  for source in "$ROOT"/bin/*; do
    ln -s "$source" "$lab/bin/$(basename "$source")"
  done
  cat > "$lab/fakebin/timeout" <<'SH'
#!/usr/bin/env bash
set -u
target=${FM_TEST_TIMEOUT_TARGET:-}
if [ -n "$target" ]; then
  case "$*" in
    *"$target"*)
      printf '%s\n' "$target" >> "${FM_TEST_TIMEOUT_LOG:?}"
      exit 124
      ;;
  esac
fi
if [ "${1:-}" = -k ]; then
  shift 2
fi
shift
exec "$@"
SH
  chmod 0700 "$lab/fakebin/timeout"
  cat > "$lab/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: stopped · source: none · bounded-call fixture\n'
SH
  chmod 0700 "$lab/fakebin/fm-crew-state.sh"
  printf '%s\n' "$lab"
}

replace_with_hang() {  # <path>
  rm -f "$1"
  cat > "$1" <<'SH'
#!/usr/bin/env bash
while :; do /bin/sleep 10; done
SH
  chmod 0700 "$1"
}

make_tmux() {  # <lab> <capture-mode: quick|hang> <other-mode: quick|hang>
  local lab=$1 capture=$2 other=$3
  cat > "$lab/fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  capture-pane)
    if [ "$capture" = hang ]; then
      while :; do /bin/sleep 10; done
    fi
    printf 'pane\n'
    exit 0
    ;;
esac
if [ "$other" = hang ]; then
  while :; do /bin/sleep 10; done
fi
exit 1
SH
  chmod 0700 "$lab/fakebin/tmux"
}

make_herdr() {  # <lab> <agent-mode: quick|hang> <schema-mode: quick|hang> [session-mode: quick|hang]
  local lab=$1 agent=$2 schema=$3 sessions=${4:-quick}
  cat > "$lab/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"session list"*)
    if [ "$sessions" = hang ]; then
      while :; do /bin/sleep 10; done
    fi
    printf '%s\n' '{"sessions":[{"name":"default","socket_path":"/tmp/fm-bounded-herdr.sock"}]}'
    ;;
  *"api schema"*)
    if [ "$schema" = hang ]; then
      while :; do /bin/sleep 10; done
    fi
    printf '%s\n' '{"methods":["events.subscribe","pane.agent_status_changed"]}'
    ;;
  *"agent get"*)
    if [ "$agent" = hang ]; then
      while :; do /bin/sleep 10; done
    fi
    printf '%s\n' '{"result":{"agent":{"agent_status":"idle"}}}'
    ;;
  *"pane read"*) printf 'pane\n' ;;
  *"status --json"*) printf '%s\n' '{"client":{"protocol":20},"server":{"running":true}}' ;;
  *) exit 1 ;;
esac
SH
  chmod 0700 "$lab/fakebin/herdr"
  cat > "$lab/fakebin/event-reader" <<'SH'
#!/usr/bin/env bash
printf '@subscribed\n'
/bin/sleep 0.1
SH
  chmod 0700 "$lab/fakebin/event-reader"
}

seed_event_window() {  # <lab>
  local lab=$1 state="$1/home/state" gen
  printf 'kind=ship\nbackend=herdr\nwindow=default:w1:p2\nharness=pi\n' > "$state/worker.meta"
  gen=$(FM_STATE_OVERRIDE="$state" "$lab/bin/fm-busy-event.sh" arm "$state" worker)
  FM_STATE_OVERRIDE="$state" "$lab/bin/fm-busy-event.sh" apply "$state" worker busy \
    --gen "$gen" --source pi-ext --event agent-start >/dev/null
}

install_event_fallback_sleep() {  # <lab>
  local lab=$1
  cat > "$lab/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
if [ ! -e "${FM_TEST_EVENT_SLEEP_MARKER:?}" ]; then
  : > "$FM_TEST_EVENT_SLEEP_MARKER"
  printf 'done: event fallback reached the next cycle\n' > "${FM_TEST_EVENT_STATE:?}/event-exit.status"
fi
exec /bin/sleep "$@"
SH
  chmod 0700 "$lab/fakebin/sleep"
}

install_term_ignoring_timeout() {  # <lab>
  local lab=$1
  cat > "$lab/fakebin/timeout" <<'SH'
#!/usr/bin/env bash
set -u
kill_after=
if [ "${1:-}" = -k ]; then
  kill_after=${2:-}
  shift 2
fi
shift
case "$*" in
  *"/.fm-custom-check."*) ;;
  *) exec "$@" ;;
esac
printf 'kill-after=%s\n' "${kill_after:-none}" >> "${FM_TEST_TIMEOUT_LOG:?}"
"$@" &
child=$!
/bin/sleep 0.1
kill -TERM "$child" 2>/dev/null || true
if [ -n "$kill_after" ]; then
  /bin/sleep 0.1
  kill -KILL "$child" 2>/dev/null || true
fi
wait "$child" 2>/dev/null || true
exit 137
SH
  chmod 0700 "$lab/fakebin/timeout"
}

file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1"; else stat -c %Y "$1"; fi
}

prime_signal_seen() {  # <state> <file>
  FM_STATE_OVERRIDE="$1" bash -c '
    . "$1"
    sig=$(fm_wake_signal_sig "$3") || exit 1
    printf "%s" "$sig" > "$(fm_wake_signal_seen_path "$2" "$3")"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$1" "$2"
}

seed_direct_exit() {  # <state>
  printf 'done: bounded call reached the next stage\n' > "$1/cycle-exit.status"
}

seed_heartbeat_exit() {  # <state>
  seed_direct_exit "$1"
  prime_signal_seen "$1" "$1/cycle-exit.status"
  : > "$1/.last-heartbeat"
  touch -t 200001010000 "$1/.last-heartbeat"
}

pane_hash() {
  if command -v md5 >/dev/null 2>&1; then
    printf 'pane' | md5 -q
  else
    printf 'pane' | md5sum | cut -d' ' -f1
  fi
}

run_watch() {  # <lab> <timeout-target> [env assignments...]
  local lab=$1 target=$2 rc=0
  shift 2
  : > "$lab/timeout.log"
  : > "$lab/watch.out"
  : > "$lab/watch.err"
  # Inner timeout shims return immediately; this outer bound only catches a
  # watcher-cycle hang. Leave enough room for shell/process startup under load.
  FM_TIMEOUT_MECHANISM_OVERRIDE=bash fm_run_timed 15 \
    env FM_TIMEOUT_MECHANISM_OVERRIDE= FM_HOME="$lab/home" \
      FM_STATE_OVERRIDE="$lab/home/state" FM_ROOT_OVERRIDE="$lab" \
      FM_POLL=0.1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 \
      FM_HEARTBEAT=999999 FM_CREW_STATE_BIN="$lab/fakebin/fm-crew-state.sh" \
      FM_TEST_TIMEOUT_TARGET="$target" FM_TEST_TIMEOUT_LOG="$lab/timeout.log" \
      PATH="$lab/fakebin:$BASE_PATH" "$@" "$lab/bin/fm-watch.sh" \
      > "$lab/watch.out" 2> "$lab/watch.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "$target stopped the watcher cycle (rc=$rc): $(cat "$lab/watch.err")"
  [ -e "$lab/home/state/.last-watcher-beat" ] \
    || fail "$target prevented the liveness beacon from being refreshed"
  [ "$(file_mtime "$lab/home/state/.last-watcher-beat")" -gt 946684800 ] \
    || fail "$target left the liveness beacon stale"
}

ack_all() {  # <state>
  local state=$1 sequence generation
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" \
    > "$state/.bounded-drain.out" 2> "$state/.bounded-drain.err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$state/.bounded-drain.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$state/.bounded-drain.err")
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" \
    --ack-through "$sequence" --recovery-generation "$generation" >/dev/null
}

record_value() {  # <record> <key>
  sed -n "s/^$2=//p" "$1" | tail -1
}

create_pending() {  # <lab> <task> <completed:0|1>
  local lab=$1 task=$2 completed=$3
  FM_HOME="$lab/home" FM_STATE_OVERRIDE="$lab/home/state" \
    FM_PENDING_REPLY_NOW=10 FM_PENDING_REPLY_GRACE_SECS=1 bash -c '
      . "$1"
      corr=$(fm_pending_reply_create "$2" "$3" "$4" "bounded dependency") || exit 1
      fm_pending_reply_mark_delivered "$3" "$corr" || exit 1
      if [ "$5" = 1 ]; then
        fm_pending_reply_mark_turn_completed "$3" "$corr" request || exit 1
      fi
      printf "%s\n" "$corr"
    ' _ "$lab/bin/fm-pending-reply-lib.sh" "$lab/home" "$lab/home/state" "$task" "$completed"
}

write_secondmate_meta() {  # <state> <task> <home> <backend> <window> [remote]
  local state=$1 task=$2 home=$3 backend=$4 window=$5 remote=${6-}
  {
    printf 'kind=secondmate\n'
    printf 'home=%s\n' "$home"
    printf 'backend=%s\n' "$backend"
    printf 'window=%s\n' "$window"
    printf 'harness=codex\n'
    [ -z "$remote" ] || printf 'remote_host=%s\n' "$remote"
  } > "$state/$task.meta"
}

test_procevent_reconcile() {
  local lab state result
  lab=$(make_lab procevent-reconcile); state="$lab/home/state"
  replace_with_hang "$lab/bin/fm-procevent.sh"
  mkdir -p "$state/procevent" "$state/procevent-inbox"
  result="$state/procevent-inbox/source.1.result"
  printf 'pending capture\n' > "$result"
  printf 'test\n' > "${result%.result}.adapter"
  seed_direct_exit "$state"
  run_watch "$lab" fm-procevent.sh
  assert_grep 'process-event reconciliation exceeded its 60s bound' "$state/.watch-triage.log" \
    "process-event deadline was not logged"
  assert_grep 'signal:' "$lab/watch.out" "watcher did not reach its next actionable stage"
  assert_file "$result" "pending process-event capture was lost"
  assert_absent "${result%.result}.handled" "timed-out reconciliation falsely acknowledged its capture"
  pass "process-event reconciliation timeout preserves an unhandled capture"
}

test_inactive_reconcile() {
  local lab state pending
  lab=$(make_lab inactive-reconcile); state="$lab/home/state"
  replace_with_hang "$lab/bin/fm-inactive-reconcile.sh"
  mkdir -p "$state/terminal-outcomes"
  pending="$state/terminal-outcomes/fingerprint.pending"
  printf 'schema=fm-terminal-outcome.v1\nphase=pending\n' > "$pending"
  seed_direct_exit "$state"
  run_watch "$lab" fm-inactive-reconcile.sh
  assert_grep 'inactive-outcome reconciliation exceeded its 60s bound' "$state/.watch-triage.log" \
    "inactive reconciliation deadline was not logged"
  assert_file "$pending" "inactive reconciliation timeout lost its pending receipt"
  assert_grep 'signal:' "$lab/watch.out" "watcher did not continue after inactive reconciliation timed out"
  pass "inactive reconciliation timeout retains its pending receipt"
}

test_secondmate_scan() {
  local lab state mate queue
  lab=$(make_lab secondmate-scan); state="$lab/home/state"; mate="$lab/mate"
  mkdir -p "$mate/state"
  queue="$mate/state/.wake-queue"
  printf '1\t1\tsignal\told\told queued work\n' > "$queue"
  write_secondmate_meta "$state" mate "$mate" tmux session:fm-mate
  replace_with_hang "$lab/bin/fm-secondmate-wake-check.sh"
  seed_direct_exit "$state"
  run_watch "$lab" fm-secondmate-wake-check.sh
  assert_absent "$state/.secondmate-wake-scan" "timed-out secondmate scan advanced its cadence marker"
  assert_grep 'secondmate wake-loop scan exceeded its 30s bound' "$state/.watch-triage.log" \
    "secondmate scan deadline was not logged"
  assert_grep 'old queued work' "$queue" "secondmate scan timeout consumed the stalled work"
  ack_all "$state" || fail "could not acknowledge the first watcher cycle"
  rm -f "$lab/bin/fm-secondmate-wake-check.sh"
  ln -s "$ROOT/bin/fm-secondmate-wake-check.sh" "$lab/bin/fm-secondmate-wake-check.sh"
  run_watch "$lab" no-timeout-target
  assert_grep 'check: secondmate-wake-stall' "$lab/watch.out" \
    "the next scan did not re-detect the secondmate stall"
  assert_grep 'secondmate-wake-stall:mate:1' "$state/.wake-queue" \
    "the retried scan did not leave the stall durably queued"
  pass "secondmate scan timeout is retried without consuming stalled work"
}

test_remote_observe() {
  local lab state mate corr rec
  lab=$(make_lab remote-observe); state="$lab/home/state"; mate="$lab/mate"
  mkdir -p "$mate/state"
  write_secondmate_meta "$state" mate "$mate" tmux remote:mate remote-host
  corr=$(create_pending "$lab" mate 0)
  rec="$state/pending-replies/$corr"
  replace_with_hang "$lab/bin/fm-on.sh"
  seed_direct_exit "$state"
  run_watch "$lab" fm-on.sh FM_PENDING_REPLY_NOW=100
  [ "$(record_value "$rec" phase)" = awaiting_report ] \
    || fail "remote observation timeout resolved or advanced the pending reply"
  assert_grep 'remote secondmate observation exceeded its 30s bound' "$state/.watch-triage.log" \
    "remote observation deadline was not logged"
  assert_grep 'signal:' "$lab/watch.out" "watcher did not continue after remote observation timed out"
  pass "remote observation timeout keeps the reply unresolved"
}

test_recovery_send() {
  local lab state mate corr rec
  lab=$(make_lab recovery-send); state="$lab/home/state"; mate="$lab/mate"
  mkdir -p "$mate/state"
  write_secondmate_meta "$state" mate "$mate" tmux session:fm-mate
  make_tmux "$lab" quick quick
  corr=$(create_pending "$lab" mate 1)
  rec="$state/pending-replies/$corr"
  replace_with_hang "$lab/bin/fm-send.sh"
  seed_direct_exit "$state"
  run_watch "$lab" fm-send.sh FM_PENDING_REPLY_NOW=100
  case "$(record_value "$rec" phase)" in
    recovery_failed|escalated) ;;
    *) fail "timed-out recovery send did not take the existing unresolved failure branch" ;;
  esac
  [ "$(record_value "$rec" recovery_delivery_outcome)" = failed ] \
    || fail "timed-out recovery send was not recorded as failed"
  [ -z "$(record_value "$rec" recovery_sent_epoch)" ] \
    || fail "timed-out recovery send was falsely confirmed"
  assert_grep 'pending-reply recovery send exceeded its 30s bound' "$state/.watch-triage.log" \
    "recovery send deadline was not logged"
  pass "recovery send timeout remains unresolved and unconfirmed"
}

test_pending_native_busy() {
  local lab state mate corr rec
  lab=$(make_lab pending-native-busy); state="$lab/home/state"; mate="$lab/mate"
  mkdir -p "$mate/state"
  write_secondmate_meta "$state" mate "$mate" herdr default:w1:p2
  make_herdr "$lab" hang quick
  corr=$(create_pending "$lab" mate 0)
  rec="$state/pending-replies/$corr"
  seed_direct_exit "$state"
  run_watch "$lab" fm_backend_busy_state FM_PENDING_REPLY_NOW=100
  [ "$(record_value "$rec" phase)" = awaiting_report ] \
    || fail "native busy-state timeout resolved the pending reply"
  assert_grep 'pending-reply backend observation exceeded its 10s bound' "$state/.watch-triage.log" \
    "native busy-state deadline was not logged"
  pass "native busy-state timeout becomes an unresolved observation"
}

test_pending_capture() {
  local lab state mate corr rec
  lab=$(make_lab pending-capture); state="$lab/home/state"; mate="$lab/mate"
  mkdir -p "$mate/state"
  write_secondmate_meta "$state" mate "$mate" tmux session:fm-mate
  make_tmux "$lab" hang quick
  corr=$(create_pending "$lab" mate 0)
  rec="$state/pending-replies/$corr"
  seed_direct_exit "$state"
  run_watch "$lab" fm_backend_capture FM_PENDING_REPLY_NOW=100
  [ "$(record_value "$rec" phase)" = awaiting_report ] \
    || fail "pending-reply capture timeout resolved the pending reply"
  assert_grep 'pending-reply backend capture exceeded its 10s bound' "$state/.watch-triage.log" \
    "pending-reply capture deadline was not logged"
  pass "pending-reply capture timeout becomes an unresolved observation"
}

test_watcher_capture() {
  local lab state key
  lab=$(make_lab watcher-capture); state="$lab/home/state"; key=session_fm-worker
  make_tmux "$lab" hang quick
  printf 'kind=ship\nwindow=session:fm-worker\nharness=codex\n' > "$state/worker.meta"
  seed_heartbeat_exit "$state"
  run_watch "$lab" fm_backend_capture FM_HEARTBEAT=1
  assert_grep 'backend capture exceeded its 10s bound' "$state/.watch-triage.log" \
    "watcher capture deadline was not logged"
  assert_absent "$state/.hash-$key" "capture timeout advanced the pane hash"
  assert_absent "$state/.count-$key" "capture timeout advanced the pane count"
  assert_absent "$state/.stale-$key" "capture timeout advanced stale bookkeeping"
  assert_absent "$state/.wedge-escalations-$key" "capture timeout advanced wedge bookkeeping"
  assert_grep 'heartbeat' "$lab/watch.out" "watcher did not reach the post-window stage"
  pass "watcher capture timeout skips all window bookkeeping"
}

setup_agent_alive_case() {  # <name> <first|second>
  local name=$1 branch=$2 lab state key hash
  lab=$(make_lab "$name"); state="$lab/home/state"; key=session_fm-agent
  make_tmux "$lab" quick hang
  printf 'kind=ship\nwindow=session:fm-agent\nharness=codex\n' > "$state/agent.meta"
  printf 'paused: waiting on an external dependency\n' > "$state/agent.status"
  prime_signal_seen "$state" "$state/agent.status"
  hash=$(pane_hash)
  printf '%s' "$hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  if [ "$branch" = first ]; then
    : > "$state/.paused-$key"
    date +%s > "$state/.paused-rechecked-$key"
  fi
  printf '%s\n' "$lab"
}

test_agent_alive_cached_pause() {
  local lab state
  lab=$(setup_agent_alive_case agent-alive-cached first); state="$lab/home/state"
  run_watch "$lab" fm_backend_agent_alive
  assert_grep 'agent-alive probe exceeded its 10s bound' "$state/.watch-triage.log" \
    "cached-pause agent probe deadline was not logged"
  assert_grep 'stale: session:fm-agent' "$lab/watch.out" \
    "unknown agent state did not conservatively surface the stale pane"
  pass "cached-pause agent probe timeout stays unknown and surfaces"
}

test_agent_alive_recheck() {
  local lab state
  lab=$(setup_agent_alive_case agent-alive-recheck second); state="$lab/home/state"
  run_watch "$lab" fm_backend_agent_alive
  assert_grep 'agent-alive probe exceeded its 10s bound' "$state/.watch-triage.log" \
    "pause recheck agent probe deadline was not logged"
  assert_grep 'stale: session:fm-agent' "$lab/watch.out" \
    "unknown recheck state did not conservatively surface the stale pane"
  pass "pause-recheck agent probe timeout stays unknown and surfaces"
}

test_window_busy() {
  local lab state key hash
  lab=$(make_lab window-busy); state="$lab/home/state"; key=default_w1_p2
  make_herdr "$lab" hang quick
  printf 'kind=ship\nbackend=herdr\nwindow=default:w1:p2\nharness=pi\n' > "$state/worker.meta"
  hash=$(pane_hash)
  printf '%s' "$hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  run_watch "$lab" window_is_busy
  assert_grep 'window busy-state probe exceeded its 10s bound' "$state/.watch-triage.log" \
    "window busy-state deadline was not logged"
  assert_grep 'stale: default:w1:p2' "$lab/watch.out" \
    "busy-state timeout was treated as busy and absorbed"
  pass "window busy-state timeout resolves to not busy and surfaces"
}

test_events_capability() {
  local lab state
  lab=$(make_lab events-capability); state="$lab/home/state"
  make_herdr "$lab" quick hang
  seed_event_window "$lab"
  install_event_fallback_sleep "$lab"
  run_watch "$lab" fm_backend_events_capable \
    FM_BACKEND_HERDR_EVENT_READER="$lab/fakebin/event-reader" \
    FM_TEST_EVENT_SLEEP_MARKER="$lab/event-slept" FM_TEST_EVENT_STATE="$state"
  assert_grep 'backend event-capability probe exceeded its 10s bound' "$state/.watch-triage.log" \
    "event-capability deadline was not logged"
  assert_file "$lab/event-slept" "event-capability timeout did not take the poll fallback"
  assert_grep 'signal:' "$lab/watch.out" "watcher did not begin the next cycle after capability timeout"
  pass "event-capability timeout falls back to the next poll cycle"
}

test_event_socket_discovery() {
  local lab state
  lab=$(make_lab event-socket-discovery); state="$lab/home/state"
  make_herdr "$lab" quick quick hang
  seed_event_window "$lab"
  install_event_fallback_sleep "$lab"
  run_watch "$lab" "session list" \
    FM_BACKEND_HERDR_EVENT_READER="$lab/fakebin/event-reader" \
    FM_TEST_EVENT_SLEEP_MARKER="$lab/event-slept" FM_TEST_EVENT_STATE="$state"
  assert_grep 'Herdr event socket discovery exceeded its 10s bound: default' \
    "$state/.watch-triage.log" "event socket discovery deadline was not logged"
  assert_file "$lab/event-slept" "event socket discovery timeout did not take the poll fallback"
  assert_grep 'event-exit.status' "$state/.wake-queue" \
    "event socket discovery timeout lost the next cycle's durable signal"
  assert_absent "$state/.herdr-escalated-default_w1_p2" \
    "event socket discovery timeout falsely committed a transition"
  pass "event socket discovery timeout preserves polling and durable signals"
}

test_event_agent_status() {
  local lab state
  lab=$(make_lab event-agent-status); state="$lab/home/state"
  make_herdr "$lab" hang quick quick
  seed_event_window "$lab"
  cat > "$lab/fakebin/event-reader" <<'SH'
#!/usr/bin/env bash
printf '@subscribed\n'
if [ ! -e "${FM_TEST_EVENT_READER_MARKER:?}" ]; then
  : > "$FM_TEST_EVENT_READER_MARKER"
  printf 'done: event level fallback reached the next cycle\n' > "${FM_TEST_EVENT_STATE:?}/event-exit.status"
fi
/bin/sleep 0.1
SH
  chmod 0700 "$lab/fakebin/event-reader"
  run_watch "$lab" "agent get" FM_BACKEND_HERDR_EVENT_READER="$lab/fakebin/event-reader" \
    FM_TEST_EVENT_READER_MARKER="$lab/event-read" FM_TEST_EVENT_STATE="$state"
  assert_grep 'Herdr event agent-status probe exceeded its 10s bound: default:w1:p2' \
    "$state/.watch-triage.log" "event agent-status deadline was not logged"
  assert_file "$lab/event-read" "event reader was not subscribed before level reconciliation"
  assert_grep 'event-exit.status' "$state/.wake-queue" \
    "event agent-status timeout lost the next cycle's durable signal"
  assert_absent "$state/.herdr-escalated-default_w1_p2" \
    "event agent-status timeout falsely committed a transition"
  pass "event agent-status timeout preserves polling and durable signals"
}

test_herdr_shared_status_contract() {
  local lab raw
  lab=$(make_lab herdr-shared-status)
  make_herdr "$lab" quick quick quick
  : > "$lab/timeout.log"
  # shellcheck disable=SC2016 # Expansion is deliberately deferred to the child shell.
  raw=$(env FM_ROOT_OVERRIDE="$lab" FM_TEST_TIMEOUT_TARGET="agent get" \
    FM_TEST_TIMEOUT_LOG="$lab/timeout.log" PATH="$lab/fakebin:$BASE_PATH" \
    bash -c '. "$1"; fm_backend_herdr_agent_status_raw default w1:p2' \
      _ "$lab/bin/backends/herdr.sh") \
    || fail "shared Herdr agent-status read failed"
  [ "$raw" = idle ] \
    || fail "event deadline changed the shared Herdr agent-status contract: $raw"
  pass "shared Herdr agent-status reads retain their existing contract"
}

test_term_ignoring_check() {
  local lab state check
  lab=$(make_lab term-ignoring-check); state="$lab/home/state"
  install_term_ignoring_timeout "$lab"
  check="$state/stubborn.check.sh"
  cat > "$check" <<'SH'
#!/usr/bin/env bash
trap '' TERM
printf 'partial check output\n'
fifo="${0}.fifo"
mkfifo "$fifo"
exec 9<> "$fifo"
read -r -t 8 -u 9 _ || true
SH
  chmod 0700 "$check"
  FM_HOME="$lab/home" FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$lab" \
    "$lab/bin/fm-check-register.sh" stubborn >/dev/null
  seed_direct_exit "$state"
  run_watch "$lab" term-ignoring-check FM_CHECK_INTERVAL=0
  assert_grep 'kill-after=1' "$lab/timeout.log" \
    "the external check deadline did not configure kill-after escalation"
  assert_grep 'authenticated check exceeded its 30s bound: stubborn.check.sh' \
    "$state/.watch-triage.log" "authenticated check deadline was not logged"
  assert_absent "$state/.last-check" \
    "timed-out authenticated check advanced the slow-check cadence"
  assert_no_grep 'partial check output' "$state/.wake-queue" \
    "timed-out authenticated check surfaced partial output"
  assert_grep 'cycle-exit.status' "$state/.wake-queue" \
    "timed-out authenticated check lost the next actionable signal"
  pass "TERM-ignoring authenticated check is killed without advancing cadence"
}

test_crew_state_triage() {
  local lab state
  lab=$(make_lab crew-state-triage); state="$lab/home/state"
  replace_with_hang "$lab/fakebin/fm-crew-state.sh"
  printf 'working: no-verb signal requiring current-state classification\n' > "$state/worker.status"
  run_watch "$lab" fm-crew-state.sh
  assert_grep 'crew current-state read exceeded its 15s bound: worker' \
    "$state/.watch-triage.log" "crew current-state deadline was not logged"
  assert_grep 'worker.status' "$state/.wake-queue" \
    "crew current-state timeout did not leave the signal durably surfaced"
  if grep -q 'absorbed benign' "$state/.watch-triage.log" 2>/dev/null; then
    fail "crew current-state timeout was absorbed as provably working"
  fi
  assert_grep 'signal:' "$lab/watch.out" \
    "crew current-state timeout did not reach the actionable exit"
  pass "crew current-state timeout surfaces instead of absorbing supervision"
}

test_apply_lock_namespace() {
  local lab claims ready release holder contender_status=0
  lab=$(make_lab apply-lock-namespace); claims="$lab/claims"
  ready="$lab/apply-ready"; release="$lab/apply-release"
  FM_PROCEVENT_CLAIM_ROOT="$claims" bash -c '
    . "$1/bin/fm-pr-lib.sh"
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-procevent-lib.sh"
    fm_procevent_apply_lock_acquire wait remote-reply-a || exit 1
    trap "fm_procevent_apply_lock_release remote-reply-a" EXIT
    printf "ready\n" > "$2"
    while [ ! -e "$3" ]; do
      kill -0 "$4" 2>/dev/null || exit 0
      sleep 0.02
    done
  ' _ "$ROOT" "$ready" "$release" $$ &
  holder=$!
  wait_for_file "$ready" || fail "apply-lock namespace holder never acquired"
  # shellcheck disable=SC2016 # Expansion is deliberately deferred to the child shell.
  FM_TIMEOUT_MECHANISM_OVERRIDE=bash fm_run_timed 1 env \
    FM_PROCEVENT_CLAIM_ROOT="$claims" bash -c '
      . "$1/bin/fm-pr-lib.sh"
      . "$1/bin/fm-wake-lib.sh"
      . "$1/bin/fm-procevent-lib.sh"
      fm_procevent_source_lock_acquire remote-reply-a.apply || exit 1
      fm_procevent_source_lock_release remote-reply-a.apply
    ' _ "$ROOT" || contender_status=$?
  : > "$release"
  wait "$holder" 2>/dev/null || true
  [ "$contender_status" -eq 0 ] \
    || fail "apply lock collided with valid source id remote-reply-a.apply"
  pass "apply locks use a namespace disjoint from source locks"
}

test_apply_lock_symlink() {
  local lab state redirected sentinel
  lab=$(make_lab apply-lock-symlink); state="$lab/home/state"
  redirected="$lab/redirected-claims"; sentinel="$lab/adapter-ran"
  mkdir -p "$state/procevent-inbox" "$redirected"
  ln -s "$redirected" "$lab/claim-root"
  printf 'capture\n' > "$state/procevent-inbox/source.1.result"
  printf 'bounded-test\n' > "$state/procevent-inbox/source.1.adapter"
  cat > "$lab/bin/fm-procevent-bounded-test.sh" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  self-announcing) exit 1 ;;
  autohandle) : > "$sentinel"; exit 0 ;;
  *) exit 1 ;;
esac
SH
  chmod 0700 "$lab/bin/fm-procevent-bounded-test.sh"
  FM_HOME="$lab/home" FM_STATE_OVERRIDE="$state" FM_PROCEVENT_CLAIM_ROOT="$lab/claim-root" \
    "$lab/bin/fm-procevent.sh" reconcile >/dev/null
  assert_absent "$sentinel" "symlinked claim root allowed adapter application"
  assert_absent "$redirected/apply-locks/source.lock" "symlinked claim root redirected apply-lock state"
  assert_file "$state/procevent-inbox/source.1.result" "rejected apply lock lost the pending capture"
  assert_absent "$state/procevent-inbox/source.1.handled" "rejected apply lock acknowledged the capture"
  pass "apply lock rejects a symlinked machine-wide claim root"
}

CASES=(
  procevent_reconcile
  inactive_reconcile
  secondmate_scan
  remote_observe
  recovery_send
  pending_native_busy
  pending_capture
  watcher_capture
  agent_alive_cached_pause
  agent_alive_recheck
  window_busy
  events_capability
  event_socket_discovery
  event_agent_status
  herdr_shared_status_contract
  term_ignoring_check
  crew_state_triage
  apply_lock_namespace
  apply_lock_symlink
)

if [ -n "${FM_BOUNDED_CASE:-}" ]; then
  "test_${FM_BOUNDED_CASE}"
else
  for bounded_case in "${CASES[@]}"; do
    "test_${bounded_case}"
  done
fi
