#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
# Source the daemon's pure classifiers once. The daemon's main loop is skipped
# under sourcing via its BASH_SOURCE guard, so only the testable functions
# (classify_*, housekeeping, escalate_*, stale_marker_*) become defined.
if [ -z "${FM_TEST_DAEMON_SOURCED:-}" ]; then
  export FM_TEST_DAEMON_SOURCED=1
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$DAEMON"
fi
TMP_ROOT=

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

cleanup() {
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
}

trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-wake-tests.XXXXXX")

make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "list-windows" ]; then
  if [ -n "${FM_FAKE_TMUX_WINDOW:-}" ]; then
    printf '%s\n' "$FM_FAKE_TMUX_WINDOW"
  fi
  exit 0
fi
if [ "${1:-}" = "capture-pane" ]; then
  if [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ]; then
    cat "$FM_FAKE_TMUX_CAPTURE"
  fi
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$dir"
}

# Like make_case, but the fake tmux also covers the sub-supervisor daemon's
# surface (display-message pane probe, send-keys capture) so the daemon's
# injection + housekeeping paths can be exercised. Behavior is controlled via
# FM_FAKE_TMUX_* env vars set per test.
make_supercase() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    [ "${FM_FAKE_TMUX_PANE_ALIVE:-1}" = "1" ] || exit 1
    _print=0
    # Return cursor_y when the format asks for it (pane_input_pending).
    for _a in "$@"; do
      case "$_a" in *cursor_y*) printf '%s\n' "${FM_FAKE_TMUX_CURSOR_Y:-0}"; exit 0 ;; esac
      [ "$_a" = "-p" ] && _print=1
    done
    [ "$_print" = 1 ] && printf 'fakepane\n'
    exit 0 ;;
  list-windows)
    [ -n "${FM_FAKE_TMUX_WINDOW:-}" ] && printf '%s\n' "$FM_FAKE_TMUX_WINDOW"
    exit 0 ;;
  capture-pane)
    # Honor a single-line band capture (-S N -E M, both non-negative) the way the
    # composer reader now bounds its capture to the cursor row; otherwise (e.g.
    # fm_pane_is_busy's "-S -40" tail) return the whole capture. -e is accepted and
    # ignored: this fake emits plain text, which the dim-stripper passes through.
    _S=""; _E=""; shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -S) _S="${2:-}"; shift 2; continue ;;
        -E) _E="${2:-}"; shift 2; continue ;;
        *) shift ;;
      esac
    done
    [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] || exit 0
    if [ -n "$_S" ] && [ -n "$_E" ]; then
      case "$_S$_E" in
        *[!0-9]*) cat "$FM_FAKE_TMUX_CAPTURE" 2>/dev/null ;;
        *) sed -n "$((_S + 1)),$((_E + 1))p" "$FM_FAKE_TMUX_CAPTURE" 2>/dev/null ;;
      esac
    else
      cat "$FM_FAKE_TMUX_CAPTURE" 2>/dev/null
    fi
    exit 0 ;;
  send-keys)
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -l) shift; [ "$#" -gt 0 ] && {
          printf '%s\n' "$1" >> "${FM_FAKE_TMUX_SENT:-/dev/null}"
          # Reflect sent text into capture so pane_input_pending sees it as
          # pending input (text in the composer).
          [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && printf '%s\n' "$1" >> "$FM_FAKE_TMUX_CAPTURE"
        } ;;
        Enter)
          # Optionally swallow Enter (file-based flag) to test the retry path.
          if [ -n "${FM_FAKE_TMUX_SWALLOW_FILE:-}" ] && [ -f "$FM_FAKE_TMUX_SWALLOW_FILE" ]; then
            rm -f "$FM_FAKE_TMUX_SWALLOW_FILE"
          else
            printf '[ENTER]\n' >> "${FM_FAKE_TMUX_SENT:-/dev/null}"
            # Enter submits: clear the last line (the typed text) from the
            # capture, simulating the composer being cleared on submit.
            if [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && [ -s "$FM_FAKE_TMUX_CAPTURE" ]; then
              _tmp=$(mktemp 2>/dev/null) || _tmp="${FM_FAKE_TMUX_CAPTURE}.tmp"
              sed '$d' "$FM_FAKE_TMUX_CAPTURE" > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$FM_FAKE_TMUX_CAPTURE"
              rm -f "$_tmp" 2>/dev/null
            fi
          fi
          ;;
      esac
      shift
    done
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$dir"
}

test_daemon_state_root_uses_fm_home() {
  local dir home override out
  dir=$(make_supercase daemon-fm-home)
  home="$dir/firstmate-home"
  override="$dir/override-state"
  mkdir -p "$home" "$override"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE='' _state_root)
  [ "$out" = "$home/state" ] || fail "daemon state root ignored FM_HOME: $out"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$override" _state_root)
  [ "$out" = "$override" ] || fail "daemon state root ignored FM_STATE_OVERRIDE: $out"

  pass "supervise daemon state root is scoped by FM_HOME"
}

append_wake() {
  local state=$1 kind=$2 key=$3 payload=$4
  (
    export FM_STATE_OVERRIDE="$state"
    # shellcheck disable=SC1090
    . "$LIB"
    fm_wake_append "$kind" "$key" "$payload"
  )
}

wait_for_exit() {
  local pid=$1 limit=${2:-50} i=0
  while [ "$i" -lt "$limit" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid"
      return "$?"
    fi
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return 124
}

is_live_non_zombie() {
  local pid=$1 stat
  kill -0 "$pid" 2>/dev/null || return 1
  stat=$(ps -p "$pid" -o stat= 2>/dev/null || true)
  case "$stat" in
    Z*) return 1 ;;
  esac
  return 0
}

hash_text() {
  if command -v md5 >/dev/null 2>&1; then
    printf '%s' "$1" | md5 -q
  else
    printf '%s' "$1" | md5sum | cut -d' ' -f1
  fi
}

test_concurrent_append_and_drain() {
  local dir state out1 out2 all pids i pid count unique malformed
  dir=$(make_case concurrent)
  state="$dir/state"
  out1="$dir/drain-one.out"
  out2="$dir/drain-two.out"
  all="$dir/all.out"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    append_wake "$state" signal "status-$i" "signal: $state/status-$i.status" &
    pids="$pids $!"
    i=$((i + 1))
  done
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out1" &
  pids="$pids $!"
  for pid in $pids; do
    wait "$pid" || fail "concurrent append/drain subprocess failed"
  done
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out2" || fail "final drain failed"
  cat "$out1" "$out2" > "$all"
  count=$(awk 'NF { count++ } END { print count + 0 }' "$all")
  [ "$count" -eq 40 ] || fail "expected 40 drained records, got $count"
  malformed=$(awk -F '\t' 'NF != 5 { bad++ } END { print bad + 0 }' "$all")
  [ "$malformed" -eq 0 ] || fail "drained records had malformed fields"
  unique=$(awk -F '\t' '{ keys[$4] = 1 } END { for (k in keys) count++; print count + 0 }' "$all")
  [ "$unique" -eq 40 ] || fail "expected 40 unique keys, got $unique"
  pass "concurrent append plus drain preserves queue records"
}

test_signal_catchup_without_running_watcher() {
  local dir state fakebin out drain_out status_file
  dir=$(make_case signal)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: first\n' > "$status_file"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for first signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print first signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after first signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "first signal was not queued"

  printf 'done: second\n' >> "$status_file"
  : > "$out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for second signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "signal written with no watcher was not caught"
  pass "signal written while no watcher runs is caught on next run"
}

test_stale_enqueue_before_suppressor() {
  local dir state fakebin out drain_out capture_file window key pane_hash
  dir=$(make_case stale)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  capture_file="$dir/pane.txt"
  window="test:fm-stale"
  printf 'idle prompt' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/stale.meta"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for stale pane"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print stale wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after stale wake failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "stale wake was not queued"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor was not written"
  pass "stale wake is queued before suppressor state is advanced"
}

test_check_output_is_queued() {
  local dir state fakebin out drain_out check_file
  dir=$(make_case check)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  check_file="$state/task.check.sh"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'merged: https://example.test/pr/1\n'
SH
  chmod +x "$check_file"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for check output"
  grep -F "check: $check_file: merged: https://example.test/pr/1" "$out" >/dev/null || fail "watcher did not print check wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after check wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "$check_file" | grep -F 'merged: https://example.test/pr/1' >/dev/null || fail "check wake was not queued"
  [ -e "$state/.last-check" ] || fail "check cadence marker was not written after queue append"
  pass "check output is queued before cadence suppression"
}

test_singleton_start() {
  local dir state fakebin out1 out2 pid1 pid2 live
  dir=$(make_case singleton)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out1="$dir/watch-one.out"
  out2="$dir/watch-two.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out1" &
  pid1=$!
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out2" &
  pid2=$!
  sleep 0.5
  live=0
  is_live_non_zombie "$pid1" && live=$((live + 1))
  is_live_non_zombie "$pid2" && live=$((live + 1))
  [ "$live" -eq 1 ] || fail "expected exactly one live watcher, got $live"
  grep -h 'watcher: already running pid ' "$out1" "$out2" >/dev/null || fail "second watcher did not report existing singleton"
  kill "$pid1" "$pid2" 2>/dev/null || true
  wait "$pid1" 2>/dev/null || true
  wait "$pid2" 2>/dev/null || true
  pass "simultaneous watcher starts leave exactly one live process"
}

test_atomic_double_drain() {
  local dir state out1 out2 all count leftover
  dir=$(make_case double-drain)
  state="$dir/state"
  out1="$dir/drain-one.out"
  out2="$dir/drain-two.out"
  all="$dir/all.out"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "heartbeat append failed"
  append_wake "$state" signal task "signal: $state/task.status" || fail "signal append failed"
  append_wake "$state" stale 's:fm-task' 'stale: s:fm-task' || fail "stale append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out1" &
  pid1=$!
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out2" &
  pid2=$!
  wait "$pid1" || fail "first drain failed"
  wait "$pid2" || fail "second drain failed"
  cat "$out1" "$out2" > "$all"
  count=$(awk 'NF { count++ } END { print count + 0 }' "$all")
  [ "$count" -eq 3 ] || fail "two drains consumed records more than once or lost records; got $count"
  leftover=$(FM_STATE_OVERRIDE="$state" "$DRAIN" | awk 'NF { count++ } END { print count + 0 }')
  [ "$leftover" -eq 0 ] || fail "queue was not empty after double drain"
  pass "two atomic drains cannot consume the same records twice"
}

test_drain_dedupes_obvious_duplicates() {
  local dir state out count
  dir=$(make_case dedupe)
  state="$dir/state"
  out="$dir/drain.out"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "first heartbeat append failed"
  append_wake "$state" signal task.status "signal: $state/task.status" || fail "first signal append failed"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "second heartbeat append failed"
  append_wake "$state" signal task.status "signal: $state/task.status $state/task.turn-ended" || fail "second signal append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "dedupe drain failed"
  count=$(awk 'NF { count++ } END { print count + 0 }' "$out")
  [ "$count" -eq 2 ] || fail "expected 2 deduped records, got $count"
  grep "$(printf '\theartbeat\theartbeat\theartbeat')" "$out" >/dev/null || fail "heartbeat was not preserved"
  grep "$(printf '\tsignal\ttask.status\t')" "$out" | grep -F "$state/task.turn-ended" >/dev/null || fail "latest signal payload was not preserved"
  pass "drain collapses obvious duplicate heartbeat and signal records"
}

test_stale_watch_lock_reclaimed() {
  local dir state fakebin out dead_pid pid live lock_pid
  dir=$(make_case stale-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  dead_pid=999999
  while kill -0 "$dead_pid" 2>/dev/null; do
    dead_pid=$((dead_pid + 1))
  done
  mkdir "$state/.watch.lock"
  printf '%s\n' "$dead_pid" > "$state/.watch.lock/pid"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  sleep 0.5
  live=0
  is_live_non_zombie "$pid" && live=1
  [ "$live" -eq 1 ] || fail "watcher did not reclaim stale lock and stay alive"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ "$lock_pid" != "$dead_pid" ] || fail "stale watch lock pid was not replaced"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "killed watcher stale lock is reclaimed"
}

test_live_stale_watch_lock_is_actionable() {
  local dir state fakebin out err status
  dir=$(make_case live-stale-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  err="$dir/watch.err"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  touch -t 200001010000 "$state/.last-watcher-beat"
  status=0
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2> "$err" || status=$?
  [ "$status" -ne 0 ] || fail "watcher silently no-opped behind a live stale holder"
  grep -F 'heartbeat is stale' "$err" >/dev/null || fail "watcher did not explain the stale live lock"
  pass "live watcher lock with stale heartbeat is actionable"
}

test_guard_warns_on_pending_queue() {
  local dir state err
  dir=$(make_case guard)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'project=x\n' > "$state/task.meta"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "guard heartbeat append failed"
  FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=999999 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  grep -F 'queued wakes pending - drain them' "$err" >/dev/null || fail "guard did not warn about pending queue"
  pass "guard warns when queued wakes are pending"
}

test_guard_rearms_after_draining_pending_queue() {
  local dir state err
  dir=$(make_case guard-order)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'project=x\n' > "$state/task.meta"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "guard heartbeat append failed"
  FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  grep -F 'queued wakes pending - drain them' "$err" >/dev/null || fail "guard did not warn about pending queue"
  grep -F 'After draining queued wakes, re-arm the watcher' "$err" >/dev/null || fail "guard did not order re-arm after drain"
  ! grep -F 'Restart it NOW, before anything else' "$err" >/dev/null || fail "guard still gave conflicting restart-first instruction"
  pass "guard orders watcher re-arm after queued wake drain"
}

test_classify_routine_signal_self() {
  local dir state out
  dir=$(make_supercase classify-routine)
  state="$dir/state"
  printf 'working: step 1\nworking: step 2\n' > "$state/foo-x1.status"
  out=$(FM_STATE_OVERRIDE="$state" classify_signal "$state/foo-x1.status" "$state")
  case "$out" in self\|*) pass "routine signal self-handles" ;; *) fail "routine signal did not self-handle: $out" ;; esac
}

test_classify_terminal_signal_escalates() {
  local dir state kw out
  dir=$(make_supercase classify-terminal)
  state="$dir/state"
  for kw in "done: PR https://x/y/pull/1" "needs-decision: pick A" "blocked: no perms" \
            "failed: rc 2" "PR ready https://x/y/pull/2" "checks green" \
            "ready in branch fm/t1" "merged"; do
    printf 'working\n%s\n' "$kw" > "$state/t.status"
    out=$(FM_STATE_OVERRIDE="$state" classify_signal "$state/t.status" "$state")
    case "$out" in escalate\|*) ;; *) fail "captain verb did not escalate ($kw): $out" ;; esac
  done
  pass "captain-relevant status verbs escalate"
}

test_classify_check_and_unknown_escalate() {
  local out
  out=$(classify_check "check: /s/c.check.sh: merged: https://x")
  case "$out" in escalate\|*) ;; *) fail "check did not escalate: $out" ;; esac
  out=$(classify_unknown "frobnicate: weird")
  case "$out" in escalate\|*) ;; *) fail "unknown did not fail-safe escalate: $out" ;; esac
  out=$(classify_heartbeat)
  case "$out" in self\|*) ;; *) fail "heartbeat did not self-handle: $out" ;; esac
  pass "check + unknown escalate; heartbeat self-handles"
}

test_stale_transient_self_records_marker() {
  local dir state out key
  dir=$(make_supercase stale-transient)
  state="$dir/state"
  printf 'working: building\n' > "$state/qux-w4.status"
  stale_marker_record "sess:fm-qux-w4" "$state"
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "sess:fm-qux-w4" "$state")
  case "$out" in self\|*) ;; *) fail "transient stale did not self-handle: $out" ;; esac
  key=$(printf '%s' "$(window_to_task "sess:fm-qux-w4")" | tr ':/.' '___')
  [ -e "$state/.subsuper-stale-$key" ] || fail "stale marker was not recorded"
  pass "transient stale self-handles and records a persistence marker"
}

test_stale_terminal_escalates() {
  local dir state out
  dir=$(make_supercase stale-terminal)
  state="$dir/state"
  printf 'done: ready in branch fm/t1\n' > "$state/fin-t5.status"
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "sess:fm-fin-t5" "$state")
  case "$out" in escalate\|*) ;; *) fail "terminal stale did not escalate: $out" ;; esac
  pass "stale + terminal status escalates immediately"
}

test_housekeeping_persistent_stale_escalates() {
  local dir state fakebin win pane key
  dir=$(make_supercase stale-persistent)
  state="$dir/state"
  fakebin="$dir/fakebin"
  win="sess:fm-pers-w5"
  pane="$dir/pane.txt"
  printf 'working\n' > "$state/pers-w5.status"
  printf 'idle prompt $\n' > "$pane"
  key=$(printf '%s' "pers-w5" | tr ':/.' '___')
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  [ -s "$state/.subsuper-escalations" ] || fail "persistent stale was not escalated"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "stale marker not cleared after escalation"
  pass "persistent stale escalates after threshold and clears its marker"
}

test_housekeeping_resumed_stale_cleared() {
  local dir state fakebin win pane key
  dir=$(make_supercase stale-resumed)
  state="$dir/state"
  fakebin="$dir/fakebin"
  win="sess:fm-res-w6"
  pane="$dir/pane.txt"
  printf 'working\n' > "$state/res-w6.status"
  printf 'Working...\n' > "$pane"
  key=$(printf '%s' "res-w6" | tr ':/.' '___')
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  [ -e "$state/.subsuper-stale-$key" ] && fail "resumed stale marker was not cleared"
  [ -s "$state/.subsuper-escalations" ] && fail "resumed stale was escalated"
  pass "resumed (busy) stale clears its marker without escalating"
}

test_escalate_batches_into_one_digest() {
  local dir state fakebin sent capture n
  dir=$(make_supercase batch)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; : > "$capture"
  escalate_add "$state" "event A: done: PR 1"
  escalate_add "$state" "event B: done: PR 2"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=0 escalate_flush "$state" \
    || fail "escalate_flush failed"
  grep -F "event A" "$sent" >/dev/null || fail "batch digest missing event A"
  grep -F "event B" "$sent" >/dev/null || fail "batch digest missing event B"
  grep -F 'event A: done: PR 1 | event B: done: PR 2' "$sent" >/dev/null \
    || fail "batch digest did not join events with literal ' | '"
  [ -s "$state/.subsuper-escalations" ] && fail "escalation buffer not cleared after flush"
  [ -e "$state/.subsuper-escalations.since" ] && fail "first-append sidecar not cleared after flush"
  n=$(grep -c '\[ENTER\]' "$sent")
  [ "$n" -eq 1 ] || fail "expected one injected digest, got $n send-keys submits"
  pass "multiple escalations flush as a single batched digest"
}

test_escalate_batch_age_uses_first_append() {
  local dir state fakebin sent capture
  dir=$(make_supercase batch-age)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; : > "$capture"
  escalate_add "$state" "event A: done: PR 1"
  escalate_add "$state" "event B: done: PR 2"
  echo $(( $(date +%s) - 100 )) > "$state/.subsuper-escalations.since"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=90 FM_HOUSEKEEPING_TICK=0 \
    housekeeping "$state"
  grep -F 'event A: done: PR 1 | event B: done: PR 2' "$sent" >/dev/null \
    || fail "backdated batch did not flush as a joined digest (max-delay measured from last append)"
  [ -s "$state/.subsuper-escalations" ] && fail "escalation buffer not cleared after backdated flush"
  [ -e "$state/.subsuper-escalations.since" ] && fail "first-append sidecar not cleared after flush"
  pass "batch flush measures max-delay from the first append, not the last"
}

test_heartbeat_scan_dedup() {
  local dir state
  dir=$(make_supercase scan-dedup)
  state="$dir/state"
  printf 'done: ready\n' > "$state/dup-t6.status"
  rm -f "$state/.subsuper-last-scan"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  [ -s "$state/.subsuper-escalations" ] || fail "catch-all scan did not escalate a terminal"
  : > "$state/.subsuper-escalations"
  echo $(( $(date +%s) - 99999 )) > "$state/.subsuper-last-scan"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  [ -s "$state/.subsuper-escalations" ] && fail "catch-all scan re-escalated the same terminal (dedup failed)"
  pass "catch-all scan escalates a missed terminal once, not twice"
}

test_handle_wake_routes_self_and_escalate() {
  local dir state
  dir=$(make_supercase handle)
  state="$dir/state"
  printf 'working\n' > "$state/h-routine.status"
  FM_STATE_OVERRIDE="$state" handle_wake "signal: $state/h-routine.status" "$state"
  [ -s "$state/.subsuper-escalations" ] && fail "routine signal was escalated by handle_wake"
  printf 'done: PR 1\n' > "$state/h-done.status"
  FM_STATE_OVERRIDE="$state" handle_wake "signal: $state/h-done.status" "$state"
  [ -s "$state/.subsuper-escalations" ] || fail "captain signal was not buffered by handle_wake"
  pass "handle_wake routes routine->self and captain->escalate"
}

test_inject_skip_forces_self() {
  local dir state
  dir=$(make_supercase skip)
  state="$dir/state"
  printf 'done: PR 1\n' > "$state/s1.status"
  FM_STATE_OVERRIDE="$state" FM_INJECT_SKIP="signal" handle_wake "signal: $state/s1.status" "$state"
  [ -s "$state/.subsuper-escalations" ] && fail "INJECT_SKIP=signal did not force self-handle"
  pass "INJECT_SKIP forces self-handle, bypassing captain-relevant classification"
}

test_is_wake_reason_distinguishes_status_stdout() {
  # Real wake reasons are recognized; watcher status lines (singleton collision)
  # are not, so the main loop can idle them without flooding escalations.
  is_wake_reason "signal: /x/y.status" || fail "signal: not recognized as wake"
  is_wake_reason "stale: s:fm-x" || fail "stale: not recognized as wake"
  is_wake_reason "check: /s/c.sh: merged" || fail "check: not recognized as wake"
  is_wake_reason "heartbeat" || fail "heartbeat not recognized as wake"
  is_wake_reason "watcher: already running" && fail "singleton status line misclassified as wake"
  is_wake_reason "watcher: already running pid 123" && fail "singleton status (pid) misclassified as wake"
  pass "is_wake_reason distinguishes watcher wake reasons from singleton-status stdout"
}

test_terminal_stale_escalate_leaves_no_marker() {
  local dir state win key
  dir=$(make_supercase stale-terminal-nomarker)
  state="$dir/state"
  win="sess:fm-fin-n7"
  printf 'done: PR https://x/y/pull/7\n' > "$state/fin-n7.status"
  key=$(printf '%s' "fin-n7" | tr ':/.' '___')
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  FM_STATE_OVERRIDE="$state" handle_wake "stale: $win" "$state"
  [ -s "$state/.subsuper-escalations" ] || fail "terminal stale was not escalated"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "terminal stale left a persistence marker (housekeeping would re-escalate)"
  : > "$state/.subsuper-escalations"
  rm -f "$state/.subsuper-last-scan"
  FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  [ ! -s "$state/.subsuper-escalations" ] || fail "housekeeping re-escalated a terminal stale as a wedge"
  pass "terminal-stale escalate removes its marker so housekeeping does not re-escalate"
}

test_signal_escalate_marks_seen_no_catchall_refire() {
  local dir state key
  dir=$(make_supercase signal-seen)
  state="$dir/state"
  printf 'done: PR https://x/y/pull/8\n' > "$state/sig-t8.status"
  FM_STATE_OVERRIDE="$state" handle_wake "signal: $state/sig-t8.status" "$state"
  [ -s "$state/.subsuper-escalations" ] || fail "captain signal was not escalated"
  key=$(printf '%s' "sig-t8" | tr ':/.' '___')
  [ "$(cat "$state/.subsuper-seen-status-$key" 2>/dev/null || true)" = "done: PR https://x/y/pull/8" ] \
    || fail "captain signal escalate did not write the seen-status marker"
  : > "$state/.subsuper-escalations"
  rm -f "$state/.subsuper-last-scan"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  [ ! -s "$state/.subsuper-escalations" ] || fail "catch-all scan re-fired an already-escalated signal"
  pass "captain signal escalate marks seen so the catch-all scan does not re-fire"
}

# ============================================================================
# /afk presence-gating + injection hardening
# ============================================================================

test_collapse_newlines_pure() {
  local out
  out=$(_collapse_newlines $'line one\nline two\nline three')
  [ "$out" = "line one - line two - line three" ] || fail "collapse failed: '$out'"
  out=$(_collapse_newlines "no newlines here")
  [ "$out" = "no newlines here" ] || fail "collapse changed no-newline text"
  out=$(_collapse_newlines $'a\nb')
  [ "$out" = "a - b" ] || fail "collapse two lines failed: '$out'"
  pass "_collapse_newlines replaces newlines with literal separator"
}

test_afk_absent_daemon_does_not_inject() {
  local dir state fakebin sent capture
  dir=$(make_supercase afk-off)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; : > "$capture"
  escalate_add "$state" "done: PR 1"
  # afk flag deliberately NOT set
  if PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=0 escalate_flush "$state"; then
    fail "escalate_flush succeeded while afk inactive"
  fi
  [ -s "$sent" ] && fail "daemon injected while afk inactive"
  [ -s "$state/.subsuper-escalations" ] || fail "buffer not preserved when afk inactive"
  pass "afk flag absent: daemon does not inject, buffer preserved"
}

test_afk_present_injects_with_marker() {
  local dir state fakebin sent capture sent_line
  dir=$(make_supercase afk-on)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; : > "$capture"
  escalate_add "$state" "done: PR 1"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=0 escalate_flush "$state" \
    || fail "escalate_flush failed with afk active"
  [ -s "$sent" ] || fail "no injection sent with afk active"
  sent_line=$(grep -v '\[ENTER\]' "$sent" | head -1)
  message_is_injection "$sent_line" || fail "injection not prefixed with sentinel marker"
  pass "afk flag present: daemon injects with sentinel marker prefix"
}

test_inject_digest_is_single_line() {
  local dir state fakebin sent capture non_enter
  dir=$(make_supercase single-line)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; : > "$capture"
  escalate_add "$state" "done: PR https://x/y/pull/1"
  escalate_add "$state" "needs-decision: pick A"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=0 escalate_flush "$state" \
    || fail "escalate_flush failed"
  # The sent log is: <digest-line>\n[ENTER]\n. The digest must be exactly one
  # line (no embedded newlines that would fragment submission).
  non_enter=$(grep -cv '\[ENTER\]' "$sent")
  [ "$non_enter" -eq 1 ] || fail "expected 1 digest line, got $non_enter (embedded newlines?)"
  grep -v '\[ENTER\]' "$sent" | grep -qF 'done: PR https://x/y/pull/1' \
    || fail "digest missing first event"
  grep -v '\[ENTER\]' "$sent" | grep -qF 'needs-decision: pick A' \
    || fail "digest missing second event"
  pass "injected digest is single-line (no embedded newlines)"
}

test_busy_guard_defers_when_supervisor_busy() {
  local dir state fakebin sent capture
  dir=$(make_supercase busy-guard)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"
  # pane shows a busy signature (firstmate mid-turn)
  printf 'esc to interrupt\n' > "$capture"
  escalate_add "$state" "done: PR 1"
  afk_enter "$state"
  if PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=0 escalate_flush "$state"; then
    fail "escalate_flush should defer when supervisor pane busy"
  fi
  [ -s "$sent" ] && fail "daemon injected into a busy pane"
  [ -s "$state/.subsuper-escalations" ] || fail "buffer not preserved when deferred"
  pass "busy-guard defers injection when supervisor pane is busy"
}

test_marker_detection() {
  # message_is_injection: marker present -> injection; absent -> real message
  message_is_injection "${FM_INJECT_MARK}Supervisor escalate: done" \
    || fail "marker-prefixed message not detected as injection"
  message_is_injection "how's it going?" \
    && fail "plain message misdetected as injection"
  message_is_injection "" && fail "empty message misdetected as injection"
  # should_exit_afk: the full afk-exit contract
  local dir state
  dir=$(make_supercase marker-detect)
  state="$dir/state"
  afk_enter "$state"
  should_exit_afk "$state" "${FM_INJECT_MARK}escalate" \
    && fail "marker message should not exit afk (internal escalation)"
  should_exit_afk "$state" "status update please" \
    || fail "plain message should exit afk (captain is back)"
  pass "marker detection: marker -> stay afk, no marker -> exit afk"
}

test_afk_turn_exemption() {
  local dir state
  dir=$(make_supercase afk-exempt)
  state="$dir/state"
  afk_enter "$state"
  # /afk while already away must NOT self-cancel (re-entering/extending)
  should_exit_afk "$state" "/afk" \
    && fail "bare /afk should not exit afk"
  should_exit_afk "$state" "/afk back in an hour" \
    && fail "/afk with args should not exit afk"
  # a non-/afk skill invocation DOES exit (the captain is actively working)
  should_exit_afk "$state" "/no-mistakes" \
    || fail "non-afk skill should exit afk"
  pass "/afk invocation is exempt from afk exit (no self-cancel)"
}

test_should_exit_afk_when_afk_inactive() {
  local dir state
  dir=$(make_supercase no-afk)
  state="$dir/state"
  # afk flag absent: should never signal exit (nothing to exit)
  should_exit_afk "$state" "hello" \
    && fail "should_exit_afk true when afk inactive"
  should_exit_afk "$state" "${FM_INJECT_MARK}test" \
    && fail "should_exit_afk true when afk inactive (marker)"
  pass "should_exit_afk returns false when afk is not active"
}

# ============================================================================
# Injection hardening: composer guard, type-once submit, strip marker, dedupe
# ============================================================================

test_strip_injection_marker() {
  local stripped
  stripped=$(strip_injection_marker "${FM_INJECT_MARK}Supervisor escalate: done")
  [ "$stripped" = "Supervisor escalate: done" ] \
    || fail "marker not stripped: '$stripped'"
  # No marker → unchanged.
  stripped=$(strip_injection_marker "no marker here")
  [ "$stripped" = "no marker here" ] \
    || fail "non-marker text changed: '$stripped'"
  # Empty → empty.
  stripped=$(strip_injection_marker "")
  [ "$stripped" = "" ] || fail "empty text changed: '$stripped'"
  # Only marker → empty.
  stripped=$(strip_injection_marker "$FM_INJECT_MARK")
  [ "$stripped" = "" ] || fail "bare marker not stripped: '$stripped'"
  pass "strip_injection_marker removes the sentinel marker cleanly"
}

test_pane_input_pending_detects_partial_input() {
  local dir state fakebin capture
  dir=$(make_supercase pending-input)
  state="$dir/state"
  fakebin="$dir/fakebin"
  capture="$dir/pane.txt"
  # Line 3 (cursor_y=2) has human's partial text (no Enter) → pending.
  printf 'line one\nline two\nhuman draft text\n' > "$capture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=2 \
    pane_input_pending "fakepane" \
    || fail "pane_input_pending should detect non-empty composer (human text)"
  pass "pane_input_pending detects partial input on the cursor line"
}

test_pane_input_pending_blank_is_not_pending() {
  local dir state fakebin capture
  dir=$(make_supercase pending-blank)
  state="$dir/state"
  fakebin="$dir/fakebin"
  capture="$dir/pane.txt"
  # Cursor line (line 3, cursor_y=2) is blank → not pending.
  printf 'some output\nmore output\n\n' > "$capture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=2 \
    pane_input_pending "fakepane" \
    && fail "blank composer line falsely detected as pending"
  pass "pane_input_pending: blank cursor line is not pending"
}

test_pane_input_pending_idle_prompt_not_pending() {
  local dir state fakebin capture
  dir=$(make_supercase pending-prompt)
  state="$dir/state"
  fakebin="$dir/fakebin"
  capture="$dir/pane.txt"
  # Cursor line (line 3, cursor_y=2) is a bare prompt ($) → idle → not pending.
  printf 'output\noutput\n$ \n' > "$capture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=2 \
    pane_input_pending "fakepane" \
    && fail "bare prompt falsely detected as pending"
  # Bare > prompt also idle.
  printf 'output\noutput\n> \n' > "$capture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=2 \
    pane_input_pending "fakepane" \
    && fail "bare > prompt falsely detected as pending"
  pass "pane_input_pending: bare prompts are not pending (idle)"
}

test_pane_input_pending_honors_idle_override_after_border_strip() {
  local dir state fakebin capture
  dir=$(make_supercase pending-custom-idle)
  state="$dir/state"
  fakebin="$dir/fakebin"
  capture="$dir/pane.txt"
  printf '│ custom idle> │\n' > "$capture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=0 \
    FM_COMPOSER_IDLE_RE='^custom idle>$' pane_input_pending "fakepane" \
    && fail "FM_COMPOSER_IDLE_RE was not applied after border stripping"
  pass "pane_input_pending honors FM_COMPOSER_IDLE_RE after border stripping"
}

test_composer_guard_defers_on_partial_input() {
  local dir state fakebin sent capture
  dir=$(make_supercase composer-guard)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"
  # Cursor line has partial text (human mid-typing, no Enter).
  printf 'human draft text\n' > "$capture"
  escalate_add "$state" "done: PR 1"
  afk_enter "$state"
  if PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=0 escalate_flush "$state"; then
    fail "escalate_flush should defer when composer has pending input"
  fi
  [ -s "$sent" ] && fail "daemon injected into a pane with pending input"
  [ -s "$state/.subsuper-escalations" ] || fail "buffer not preserved when deferred"
  pass "composer guard defers injection when pane has pending input"
}

test_inject_types_once_retries_enter_only() {
  # Scenario: Enter is swallowed on the first attempt. The daemon must retry
  # Enter (NOT retype the digest) and succeed on the second Enter. Assert
  # exactly ONE digest was typed (no concatenation), and the digest was
  # eventually submitted.
  local dir state fakebin sent capture swallow_file
  dir=$(make_supercase swallow-enter)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; : > "$capture"
  swallow_file="$dir/.swallow"
  touch "$swallow_file"
  escalate_add "$state" "done: PR 1"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_SWALLOW_FILE="$swallow_file" \
    FM_INJECT_CONFIRM_SLEEP=0.1 FM_ESCALATE_BATCH_SECS=0 escalate_flush "$state" \
    || fail "escalate_flush failed despite Enter retry"
  # Exactly ONE digest line typed (send-keys -l called once). No retype.
  local digest_lines
  digest_lines=$(grep -cv '\[ENTER\]' "$sent")
  [ "$digest_lines" -eq 1 ] \
    || fail "expected 1 digest type, got $digest_lines (retype into uncleared composer?)"
  # Two Enters: first swallowed, second submitted.
  local enters
  enters=$(grep -c '\[ENTER\]' "$sent")
  [ "$enters" -eq 1 ] \
    || fail "expected 1 recorded Enter (second after swallow), got $enters"
  # Buffer cleared → success.
  [ -s "$state/.subsuper-escalations" ] && fail "buffer not cleared after successful inject"
  pass "swallowed Enter: type-once + Enter-retry, no concatenation"
}

test_inject_no_duplicate_on_success() {
  # Scenario: normal inject (Enter works first time). Exactly ONE digest typed,
  # ONE Enter, buffer cleared.
  local dir state fakebin sent capture
  dir=$(make_supercase normal-inject)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; : > "$capture"
  escalate_add "$state" "done: PR 1"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_INJECT_CONFIRM_SLEEP=0.1 \
    FM_ESCALATE_BATCH_SECS=0 escalate_flush "$state" \
    || fail "escalate_flush failed"
  local digest_lines enters
  digest_lines=$(grep -cv '\[ENTER\]' "$sent")
  [ "$digest_lines" -eq 1 ] || fail "expected 1 digest, got $digest_lines (duplicate?)"
  enters=$(grep -c '\[ENTER\]' "$sent")
  [ "$enters" -eq 1 ] || fail "expected 1 Enter, got $enters"
  [ -s "$state/.subsuper-escalations" ] && fail "buffer not cleared"
  pass "normal inject: exactly one digest, one Enter, no duplicates"
}

test_classify_signal_dedup_against_scan() {
  # If the catch-all scan already escalated a status (seen marker matches),
  # classify_signal must self-handle to avoid a duplicate in the digest.
  local dir state key out
  dir=$(make_supercase signal-dedup)
  state="$dir/state"
  printf 'done: PR https://x/y/pull/9\n' > "$state/dup-s9.status"
  # Simulate the catch-all scan having already escalated this status.
  key=$(printf '%s' "dup-s9" | tr ':/.' '___')
  printf 'done: PR https://x/y/pull/9' > "$state/.subsuper-seen-status-$key"
  out=$(FM_STATE_OVERRIDE="$state" classify_signal "$state/dup-s9.status" "$state")
  case "$out" in self\|*) ;; *) fail "signal not deduped against scan: $out" ;; esac
  # Without the seen marker, it should escalate.
  rm -f "$state/.subsuper-seen-status-$key"
  out=$(FM_STATE_OVERRIDE="$state" classify_signal "$state/dup-s9.status" "$state")
  case "$out" in escalate\|*) ;; *) fail "signal should escalate when not seen: $out" ;; esac
  pass "classify_signal dedupes against the catch-all scan seen marker"
}

test_classify_stale_dedup_against_signal() {
  # If the signal path already escalated a status (seen marker matches),
  # classify_stale must self-handle to avoid a duplicate in the digest.
  local dir state key out
  dir=$(make_supercase stale-dedup)
  state="$dir/state"
  printf 'done: PR https://x/y/pull/10\n' > "$state/dup-s10.status"
  key=$(printf '%s' "dup-s10" | tr ':/.' '___')
  printf 'done: PR https://x/y/pull/10' > "$state/.subsuper-seen-status-$key"
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "sess:fm-dup-s10" "$state")
  case "$out" in self\|*) ;; *) fail "stale not deduped against signal: $out" ;; esac
  # Without the seen marker, it should escalate.
  rm -f "$state/.subsuper-seen-status-$key"
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "sess:fm-dup-s10" "$state")
  case "$out" in escalate\|*) ;; *) fail "stale should escalate when not seen: $out" ;; esac
  pass "classify_stale dedupes against the signal path seen marker"
}

# ============================================================================
# afk-invx-i5 regressions: bordered-composer detection (RC1), submit-ACK on a
# bordered composer (RC2), and the max-defer escape (RC1b).
# ============================================================================

# Fake tmux simulating a claude-style BORDERED composer ("│ > … │"), the exact
# rendering the old detector misread as permanent pending input.
#   - display-message cursor_y -> 0 (composer is line 1)
#   - capture-pane          -> the current composer line from $FM_FAKE_COMPOSER
#   - send-keys -l <text>   -> composer becomes "│ > <text> │"  (typed, unsent)
#   - send-keys Enter       -> unless $FM_FAKE_SWALLOW exists, composer clears to
#                              "│ > │" (bordered-empty); a one-shot swallow
#                              deletes the flag, a persistent one keeps it.
# $FM_FAKE_SENT (optional) logs each typed line and each non-swallowed [ENTER].
make_bordered_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"; fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  printf '│ > │\n' > "$dir/composer"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
COMPOSER="${FM_FAKE_COMPOSER:?FM_FAKE_COMPOSER unset}"
case "${1:-}" in
  display-message)
    print=0
    for a in "$@"; do case "$a" in *cursor_y*) printf '0\n'; exit 0 ;; esac; done
    for a in "$@"; do [ "$a" = "-p" ] && print=1; done
    [ "$print" = 1 ] && printf 'fakepane\n'
    exit 0 ;;
  capture-pane) cat "$COMPOSER" 2>/dev/null; exit 0 ;;
  list-windows) exit 0 ;;
  send-keys)
    shift
    text=""; is_enter=0; lit=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift ;;
        -l) lit=1 ;;
        Enter) is_enter=1 ;;
        *) [ "$lit" = 1 ] && text="$1" ;;
      esac
      shift
    done
    if [ "$is_enter" = 1 ]; then
      if [ -n "${FM_FAKE_SWALLOW:-}" ] && [ -f "$FM_FAKE_SWALLOW" ]; then
        [ "${FM_FAKE_PERSIST_SWALLOW:-0}" = 1 ] || rm -f "$FM_FAKE_SWALLOW"
      else
        [ -n "${FM_FAKE_SENT:-}" ] && printf '[ENTER]\n' >> "$FM_FAKE_SENT"
        printf '│ > │\n' > "$COMPOSER"
      fi
    elif [ "$lit" = 1 ]; then
      [ "${FM_FAKE_SEND_FAIL:-0}" = 1 ] && exit 1
      [ -n "${FM_FAKE_SENT:-}" ] && printf '%s\n' "$text" >> "$FM_FAKE_SENT"
      printf '│ > %s │\n' "$text" > "$COMPOSER"
    fi
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$dir"
}

test_pane_input_pending_bordered_idle_not_pending() {
  # THE regression: an idle claude composer is a bordered box ("│ > … │"). The
  # old idle regex only matched a BARE prompt, so every idle claude pane read as
  # pending and the away-mode daemon deferred 100% of escalations for 9.5h.
  local dir state fakebin capture line
  dir=$(make_supercase pending-bordered-idle)
  state="$dir/state"; fakebin="$dir/fakebin"; capture="$dir/pane.txt"
  for line in \
    "│ >                                            │" \
    "│ ❯                                            │" \
    "│ >  │" \
    "│                                              │"; do
    printf '%s\n' "$line" > "$capture"
    if PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=0 \
      pane_input_pending "fakepane"; then
      fail "bordered idle composer falsely detected as pending: <$line>"
    fi
  done
  pass "pane_input_pending: an idle bordered composer is NOT pending (afk-invx-i5)"
}

test_pane_input_pending_bordered_with_text_is_pending() {
  # Guard against over-broadening: real unsubmitted text inside the box must
  # still read as pending so the daemon defers (and the captain-return race is
  # still protected).
  local dir state fakebin capture
  dir=$(make_supercase pending-bordered-text)
  state="$dir/state"; fakebin="$dir/fakebin"; capture="$dir/pane.txt"
  printf '%s\n' "│ > fix findings 1 and 3, skip 2               │" > "$capture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=0 \
    pane_input_pending "fakepane" \
    || fail "real text inside a bordered composer was not detected as pending"
  pass "pane_input_pending: text inside a bordered composer is still pending"
}

test_submit_ack_confirms_on_bordered_empty_composer() {
  # RC2: the submit acknowledgement must recognize a bordered-EMPTY composer as
  # "submitted." The old ACK reused the broken check, so on claude it could never
  # confirm and always reported a false "Enter swallowed."
  local dir fakebin sent verdict
  dir=$(make_bordered_case ack-bordered)
  fakebin="$dir/fakebin"; sent="$dir/sent.log"; : > "$sent"
  verdict=$(PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    fm_tmux_submit_core "win" "the digest" 3 0.05 0.05)
  [ "$verdict" = empty ] || fail "submit-ACK did not confirm on a bordered-empty composer: $verdict"
  [ "$(grep -cv '\[ENTER\]' "$sent")" -eq 1 ] || fail "digest typed more than once (retype)"
  [ "$(grep -c '\[ENTER\]' "$sent")" -eq 1 ] || fail "expected exactly one submitted Enter"
  pass "submit-ACK confirms a submit when the composer returns to a bordered-empty box"
}

test_submit_ack_reports_pending_on_persistent_swallow() {
  # A genuinely swallowed Enter (text stays in the box across all retries) is
  # reported as "pending" — the daemon keeps the buffer, fm-send exits non-zero —
  # and the digest is typed ONCE (Enter-only retries, never a retype).
  local dir fakebin sent verdict
  dir=$(make_bordered_case ack-swallow)
  fakebin="$dir/fakebin"; sent="$dir/sent.log"; : > "$sent"
  touch "$dir/.swallow"
  verdict=$(PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 \
    fm_tmux_submit_core "win" "the digest" 3 0.05 0.05)
  [ "$verdict" = pending ] || fail "persistent swallow not reported as pending: $verdict"
  [ "$(grep -cv '\[ENTER\]' "$sent")" -eq 1 ] || fail "digest retyped on swallow (expected type-once)"
  pass "submit-ACK reports pending on a persistently swallowed Enter (type-once)"
}

test_max_defer_empty_swallow_types_once_and_alarms() {
  local dir state fakebin sent
  dir=$(make_bordered_case maxdefer-stuck)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  printf '│ > │\n' > "$dir/composer"
  touch "$dir/.swallow"
  escalate_add "$state" "needs-decision: pick A"
  echo $(( $(date +%s) - 600 )) > "$state/.subsuper-escalations.since"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_INJECT_CONFIRM_SLEEP=0.05 \
    FM_ESCALATE_BATCH_SECS=99999 FM_MAX_DEFER_SECS=60 housekeeping "$state"
  [ "$(grep -c 'Supervisor escalate' "$sent" 2>/dev/null || true)" -eq 1 ] \
    || fail "max-defer typed the digest more than once"
  [ -s "$state/.subsuper-inject-wedged" ] \
    || fail "stuck max-defer inject did not raise a wedge alarm marker"
  [ -s "$state/.subsuper-escalations" ] \
    || fail "buffer lost after a failed max-defer inject (must be preserved)"
  pass "max-defer on an empty stuck pane types once, alarms, and preserves the buffer"
}

test_max_defer_flushes_empty_idle_pane() {
  local dir state fakebin sent
  dir=$(make_bordered_case maxdefer-recover)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  printf '│ > │\n' > "$dir/composer"
  escalate_add "$state" "done: PR https://x/y/pull/1"
  echo $(( $(date +%s) - 600 )) > "$state/.subsuper-escalations.since"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_ESCALATE_BATCH_SECS=99999 FM_MAX_DEFER_SECS=60 FM_INJECT_CONFIRM_SLEEP=0.05 \
    housekeeping "$state"
  [ ! -s "$state/.subsuper-escalations" ] || fail "buffer not cleared after a recovered max-defer flush"
  [ ! -e "$state/.subsuper-inject-wedged" ] || fail "wedge alarm left behind after a successful max-defer flush"
  pass "max-defer flushes and clears the buffer on an empty bordered pane"
}

test_max_defer_pending_composer_alarms_without_typing() {
  local dir state fakebin sent
  dir=$(make_bordered_case maxdefer-pending-digest)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  printf '│ > human draft │\n' > "$dir/composer"
  escalate_add "$state" "needs-decision: pick B"
  echo $(( $(date +%s) - 600 )) > "$state/.subsuper-escalations.since"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_ESCALATE_BATCH_SECS=99999 FM_MAX_DEFER_SECS=60 FM_INJECT_CONFIRM_SLEEP=0.05 \
    housekeeping "$state"
  [ ! -s "$sent" ] || fail "max-defer typed into a pending composer"
  [ -s "$state/.subsuper-inject-wedged" ] || fail "pending composer did not raise a wedge alarm marker"
  [ -s "$state/.subsuper-escalations" ] || fail "buffer lost while composer was pending"
  grep -F 'human draft' "$dir/composer" >/dev/null || fail "pending composer content changed"
  pass "max-defer on a pending composer alarms without typing"
}

test_normal_flush_clears_stale_wedge_marker() {
  local dir state fakebin sent
  dir=$(make_bordered_case normal-clears-wedge)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  printf 'old wedge\n' > "$state/.subsuper-inject-wedged"
  escalate_add "$state" "done: PR https://x/y/pull/2"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_INJECT_CONFIRM_SLEEP=0.05 escalate_flush "$state" \
    || fail "normal escalate_flush failed"
  [ ! -s "$state/.subsuper-escalations" ] || fail "buffer not cleared after normal flush"
  [ ! -e "$state/.subsuper-inject-wedged" ] || fail "wedge marker survived successful normal flush"
  pass "normal flush clears a stale wedge marker"
}

test_below_max_defer_does_nothing() {
  local dir state fakebin sent capture
  dir=$(make_supercase below-maxdefer)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; printf 'stuck junk line\n' > "$capture"
  escalate_add "$state" "needs-decision: pick A"
  date +%s > "$state/.subsuper-escalations.since"   # just now
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=0 \
    FM_ESCALATE_BATCH_SECS=99999 FM_MAX_DEFER_SECS=300 housekeeping "$state"
  [ ! -s "$sent" ] || fail "injected before MAX_DEFER elapsed"
  [ ! -e "$state/.subsuper-inject-wedged" ] || fail "wedge alarm fired before MAX_DEFER"
  [ -s "$state/.subsuper-escalations" ] || fail "buffer dropped below MAX_DEFER"
  pass "below MAX_DEFER: no inject, no alarm, buffer preserved"
}

test_max_defer_afk_inactive_does_not_flush_or_alarm() {
  local dir state fakebin sent
  dir=$(make_bordered_case maxdefer-inactive)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  escalate_add "$state" "needs-decision: pick B"
  echo $(( $(date +%s) - 600 )) > "$state/.subsuper-escalations.since"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_ESCALATE_BATCH_SECS=99999 FM_MAX_DEFER_SECS=60 FM_INJECT_CONFIRM_SLEEP=0.05 \
    housekeeping "$state"
  [ ! -s "$sent" ] || fail "injected while afk was inactive"
  [ ! -e "$state/.subsuper-inject-wedged" ] || fail "wedge alarm fired while afk was inactive"
  [ -s "$state/.subsuper-escalations" ] || fail "buffer dropped while afk was inactive"
  pass "max-defer does not flush or alarm while afk is inactive"
}

test_fm_send_exits_nonzero_on_confirmed_swallow() {
  # fm-send.sh must exit NON-ZERO when a steer's Enter is positively swallowed
  # (text left in the composer), so firstmate learns the instruction did not land
  # — and exit ZERO on a clean submit.
  local dir fakebin err
  dir=$(make_bordered_case send-swallow)
  fakebin="$dir/fakebin"; err="$dir/send.err"
  # Clean submit -> exit 0.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" FM_FAKE_COMPOSER="$dir/composer" \
    FM_SEND_SLEEP=0.05 "$ROOT/bin/fm-send.sh" sess:win 'route this work' >/dev/null 2>"$err" \
    || fail "fm-send exited non-zero on a clean submit: $(cat "$err")"
  # Persistent swallow -> exit non-zero with a clear message.
  printf '│ > │\n' > "$dir/composer"
  touch "$dir/.swallow"
  if PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" FM_FAKE_COMPOSER="$dir/composer" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_SEND_SLEEP=0.05 \
    "$ROOT/bin/fm-send.sh" sess:win 'fix findings 1 and 3, skip 2' >/dev/null 2>"$err"; then
    fail "fm-send exited zero despite a swallowed Enter (silent unsubmitted instruction)"
  fi
  grep -F 'not submitted' "$err" >/dev/null || fail "fm-send did not explain the swallowed submit: $(cat "$err")"
  pass "fm-send exits non-zero on a confirmed swallow, zero on a clean submit"
}

test_fm_send_exits_nonzero_on_initial_send_failure() {
  local dir fakebin err
  dir=$(make_bordered_case send-type-failure)
  fakebin="$dir/fakebin"; err="$dir/send.err"
  if PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" FM_FAKE_COMPOSER="$dir/composer" \
    FM_FAKE_SEND_FAIL=1 FM_SEND_SLEEP=0.05 \
    "$ROOT/bin/fm-send.sh" sess:win 'route this work' >/dev/null 2>"$err"; then
    fail "fm-send exited zero despite initial tmux send-keys failure"
  fi
  grep -F 'text not sent' "$err" >/dev/null || fail "fm-send did not explain initial send failure: $(cat "$err")"
  pass "fm-send exits non-zero when initial text send fails"
}

# A pid that is guaranteed dead: walk up from a high number until kill -0 fails.
dead_pid() {
  local p=999999
  while kill -0 "$p" 2>/dev/null; do
    p=$((p + 1))
  done
  printf '%s\n' "$p"
}

# fm_lock_try_acquire is single-winner: N processes racing on one lockdir, each
# writing its own (live) pid and holding it for the contention window, must
# yield exactly one success. This is the core race-proofing guarantee. Each
# contender runs in its own `bash -c` with FM_STATE_OVERRIDE as a command-scoped
# env prefix (not a subshell var modification), keeping the dataflow clean.
test_lock_single_winner_under_concurrency() {
  local dir state lockdir marker i pids pid wins
  dir=$(make_case lock-concurrency)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  marker="$dir/wins"
  : > "$marker"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      if fm_lock_try_acquire "$2"; then
        printf "%s\n" "$$" >> "$3"
        # Stay alive so the held lock names a live pid for the whole window;
        # otherwise a late contender could legitimately reclaim a dead-pid lock.
        sleep 1
      fi
    ' _ "$LIB" "$lockdir" "$marker" &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  wins=$(awk 'NF { c++ } END { print c + 0 }' "$marker")
  [ "$wins" -eq 1 ] || fail "expected exactly one lock winner under concurrency, got $wins"
  pass "concurrent fm_lock_try_acquire yields exactly one winner"
}

# A genuinely-dead-pid stale lock is reclaimed by a single acquirer.
test_lock_steals_dead_pid_lock() {
  local dir state lockdir dead rc newpid
  dir=$(make_case lock-dead-steal)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  rc=0
  newpid=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then cat "$2/pid"; else exit 7; fi
  ' _ "$LIB" "$lockdir") || rc=$?
  [ "$rc" -eq 0 ] || fail "acquirer failed to steal a dead-pid stale lock (rc=$rc)"
  [ "$newpid" != "$dead" ] || fail "stale dead-pid lock was not replaced (still $dead)"
  [ -n "$newpid" ] || fail "reclaimed lock has no pid recorded"
  pass "dead-pid stale lock is reclaimed by a single acquirer"
}

test_lock_stale_steal_single_winner_under_concurrency() {
  local dir state lockdir dead marker i pids pid wins
  dir=$(make_case lock-stale-concurrency)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  marker="$dir/wins"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  : > "$marker"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      if fm_lock_try_acquire "$2"; then
        printf "%s\n" "${BASHPID:-$$}" >> "$3"
        sleep 1
      fi
    ' _ "$LIB" "$lockdir" "$marker" &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  wins=$(awk 'NF { c++ } END { print c + 0 }' "$marker")
  [ "$wins" -eq 1 ] || fail "expected exactly one stale-lock stealer, got $wins"
  pass "concurrent stale-lock steal yields exactly one winner"
}

test_lock_live_steal_mutex_is_not_reclaimed() {
  local dir state lockdir dead holder_file holder out i lockpid stealpid
  dir=$(make_case lock-live-stealer)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  holder_file="$dir/holder"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2.steal" || exit 7
    printf "%s\n" "${BASHPID:-$$}" > "$3"
    sleep 2
    fm_lock_release "$2.steal"
  ' _ "$LIB" "$lockdir" "$holder_file" &
  holder=$!
  i=0
  while [ "$i" -lt 50 ] && [ ! -s "$holder_file" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$holder_file" ] || fail "live steal mutex holder did not start"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s lockpid=%s stealpid=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}" "$(cat "$2/pid" 2>/dev/null || true)" "$(cat "$2.steal/pid" 2>/dev/null || true)"
  ' _ "$LIB" "$lockdir")
  wait "$holder" || fail "live steal mutex holder failed"
  case "$out" in
    *"rc=1"*) ;;
    *) fail "stale lock was stolen while a live stealer held the mutex: $out" ;;
  esac
  lockpid=${out#*lockpid=}; lockpid=${lockpid%% *}
  stealpid=${out#*stealpid=}; stealpid=${stealpid%% *}
  [ "$lockpid" = "$dead" ] || fail "primary lock changed while live steal mutex was held: $out"
  [ "$stealpid" = "$(cat "$holder_file")" ] || fail "live steal mutex owner changed: $out"
  pass "live steal mutex is not reclaimed"
}

# A lock held by a LIVE pid is never stolen; acquire is a no-op that reports the
# live holder via FM_LOCK_HELD_PID and leaves the pid file untouched.
test_lock_does_not_steal_live_lock() {
  local dir state lockdir live out lockpid
  dir=$(make_case lock-live-noop)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  sleep 300 &
  live=$!
  mkdir "$lockdir"
  printf '%s\n' "$live" > "$lockdir/pid"
  out=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}"
  ' _ "$LIB" "$lockdir")
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  case "$out" in
    *"rc=1"*) ;;
    *) fail "live-held lock was acquired instead of refused: $out" ;;
  esac
  case "$out" in
    *"held=$live"*) ;;
    *) fail "live holder pid not reported via FM_LOCK_HELD_PID: $out" ;;
  esac
  lockpid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$lockpid" = "$live" ] || fail "live holder's lock pid was clobbered (got '$lockpid')"
  pass "live-held lock is not stolen"
}

test_lock_empty_pid_uses_minimum_grace() {
  local dir state lockdir out
  dir=$(make_case lock-empty-grace)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  mkdir "$lockdir"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"rc=1"*) ;;
    *) fail "empty mid-acquire lock was stolen with zero stale threshold: $out" ;;
  esac
  [ -d "$lockdir" ] || fail "empty mid-acquire lock dir was removed during grace"
  [ ! -e "$lockdir/pid" ] || fail "empty mid-acquire lock gained a pid during grace"
  pass "empty mid-acquire lock keeps a minimum grace"
}

test_lock_late_claim_loses_after_recreate() {
  local dir state lockdir out
  dir=$(make_case lock-late-claim)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    owner1=$(fm_lock_owner_dir "$2") || exit 20
    ln -s "$owner1" "$2" || exit 21
    touch -h -t 200001010000 "$2" 2>/dev/null || sleep 2
    if ! fm_lock_try_acquire "$2"; then exit 22; fi
    before=$(cat "$2/pid" 2>/dev/null || true)
    if fm_lock_claim "$2" "$owner1"; then late=won; else late=lost; fi
    after=$(cat "$2/pid" 2>/dev/null || true)
    current_owner=$(readlink "$2" 2>/dev/null || true)
    printf "late=%s before=%s after=%s owner_changed=%s\n" "$late" "$before" "$after" "$([ "$current_owner" != "$owner1" ] && echo yes || echo no)"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"late=lost"*) ;;
    *) fail "late original claimant succeeded after lock recreation: $out" ;;
  esac
  case "$out" in
    *"owner_changed=yes"*) ;;
    *) fail "stale owner was not replaced before late claim: $out" ;;
  esac
  before=${out#*before=}; before=${before%% *}
  after=${out#*after=}; after=${after%% *}
  [ -n "$before" ] || fail "recreated lock did not record a pid: $out"
  [ "$before" = "$after" ] || fail "late claim changed the recreated lock pid: $out"
  pass "late original claimant cannot claim a recreated lock"
}

test_lock_paused_mid_acquire_claim_fails_during_steal() {
  local dir state lockdir out pid
  dir=$(make_case lock-paused-claim-steal)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    owner=$(fm_lock_owner_dir "$2") || exit 20
    ln -s "$owner" "$2" || exit 21
    fm_lock_try_acquire "$2.steal" || exit 22
    steal_owner=${FM_LOCK_OWNER_DIR:-}
    if fm_lock_claim "$2" "$owner"; then late=won; else late=lost; fi
    if fm_lock_try_create "$2" "$steal_owner"; then stealer=won; else stealer=lost; fi
    pid=$(cat "$2/pid" 2>/dev/null || true)
    printf "late=%s stealer=%s pid=%s\n" "$late" "$stealer" "$pid"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"late=lost"*) ;;
    *) fail "paused claimant succeeded while steal mutex was held: $out" ;;
  esac
  case "$out" in
    *"stealer=won"*) ;;
    *) fail "stealer could not claim after paused claimant backed off: $out" ;;
  esac
  pid=${out#*pid=}; pid=${pid%% *}
  [ -n "$pid" ] || fail "stealer claim did not record a pid: $out"
  pass "paused mid-acquire claimant backs off to active stealer"
}

test_watch_restart_rejects_reused_pid() {
  local dir state fakebin out live pid i lock_pid
  dir=$(make_case restart-reused-pid)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  sleep 300 &
  live=$!
  mkdir "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "stale watcher identity" > "$state/.watch.lock/pid-identity"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" --restart > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 50 ]; do
    lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    [ "$lock_pid" = "$pid" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ "$lock_pid" = "$pid" ] || fail "restart did not replace stale reused-pid lock (got '$lock_pid')"
  is_live_non_zombie "$live" || fail "restart killed a reused unrelated pid"
  kill "$pid" "$live" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "watch restart refuses to signal a reused pid"
}

test_watcher_self_evicts_on_lock_takeover() {
  local dir state fakebin out pid i lock_pid
  dir=$(make_case self-evict)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 50 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] || fail "watcher did not record its own pid in the lock"
  # Simulate a second watcher taking over the singleton lock. $$ (the test
  # runner) is a live pid that is not the watcher.
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  wait_for_exit "$pid" 60 || fail "watcher did not self-evict after lock takeover"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ "$lock_pid" = "$$" ] || fail "self-evicting watcher clobbered the new holder's lock (got '$lock_pid')"
  pass "watcher self-evicts when the lock pid no longer names it"
}

test_daemon_state_root_uses_fm_home
test_concurrent_append_and_drain
test_signal_catchup_without_running_watcher
test_stale_enqueue_before_suppressor
test_check_output_is_queued
test_singleton_start
test_atomic_double_drain
test_drain_dedupes_obvious_duplicates
test_stale_watch_lock_reclaimed
test_live_stale_watch_lock_is_actionable
test_lock_single_winner_under_concurrency
test_lock_steals_dead_pid_lock
test_lock_stale_steal_single_winner_under_concurrency
test_lock_live_steal_mutex_is_not_reclaimed
test_lock_does_not_steal_live_lock
test_lock_empty_pid_uses_minimum_grace
test_lock_late_claim_loses_after_recreate
test_lock_paused_mid_acquire_claim_fails_during_steal
test_watch_restart_rejects_reused_pid
test_watcher_self_evicts_on_lock_takeover
test_guard_warns_on_pending_queue
test_guard_rearms_after_draining_pending_queue
# Sub-supervisor (fm-supervise-daemon.sh) classifier + batching + housekeeping.
test_classify_routine_signal_self
test_classify_terminal_signal_escalates
test_classify_check_and_unknown_escalate
test_stale_transient_self_records_marker
test_stale_terminal_escalates
test_housekeeping_persistent_stale_escalates
test_housekeeping_resumed_stale_cleared
test_escalate_batches_into_one_digest
test_escalate_batch_age_uses_first_append
test_heartbeat_scan_dedup
test_handle_wake_routes_self_and_escalate
test_inject_skip_forces_self
test_is_wake_reason_distinguishes_status_stdout
test_terminal_stale_escalate_leaves_no_marker
test_signal_escalate_marks_seen_no_catchall_refire
# /afk presence-gating + injection hardening.
test_collapse_newlines_pure
test_afk_absent_daemon_does_not_inject
test_afk_present_injects_with_marker
test_inject_digest_is_single_line
test_busy_guard_defers_when_supervisor_busy
test_marker_detection
test_afk_turn_exemption
test_should_exit_afk_when_afk_inactive
# Injection hardening: composer guard, type-once submit, strip marker, dedupe.
test_strip_injection_marker
test_pane_input_pending_detects_partial_input
test_pane_input_pending_blank_is_not_pending
test_pane_input_pending_idle_prompt_not_pending
test_pane_input_pending_honors_idle_override_after_border_strip
test_composer_guard_defers_on_partial_input
test_inject_types_once_retries_enter_only
test_inject_no_duplicate_on_success
test_classify_signal_dedup_against_scan
test_classify_stale_dedup_against_signal
# afk-invx-i5 regressions: bordered-composer detection, submit-ACK, max-defer.
test_pane_input_pending_bordered_idle_not_pending
test_pane_input_pending_bordered_with_text_is_pending
test_submit_ack_confirms_on_bordered_empty_composer
test_submit_ack_reports_pending_on_persistent_swallow
test_max_defer_empty_swallow_types_once_and_alarms
test_max_defer_flushes_empty_idle_pane
test_max_defer_pending_composer_alarms_without_typing
test_normal_flush_clears_stale_wedge_marker
test_below_max_defer_does_nothing
test_max_defer_afk_inactive_does_not_flush_or_alarm
test_fm_send_exits_nonzero_on_confirmed_swallow
test_fm_send_exits_nonzero_on_initial_send_failure
