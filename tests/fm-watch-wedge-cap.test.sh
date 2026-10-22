#!/usr/bin/env bash
# tests/fm-watch-wedge-cap.test.sh - bounded wedge escalations for one
# worker window. Disabled by default; FM_WEDGE_MAX_ESCALATIONS=N caps the
# per-window escalation count to N consecutive stale-hash wedges before a
# single PERMANENTLY-WEDGED wake, with the window-scoped
# STATE/.wedge-permanent-<key> marker silencing the wedge path for
# FM_CAP_HORIZON_SECS.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
# The fixture root for make_case, which reads TMP_ROOT at call time.
# shellcheck disable=SC2034
TMP_ROOT=$(fm_test_tmproot fm-watch-wedge-cap-tests)

ack_stopped_cycle() {  # <state>
  local state=$1 err sequence generation
  err="$state/.test-cycle-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

is_live_non_zombie() {
  local pid=$1 stat
  kill -0 "$pid" 2>/dev/null || return 1
  stat=$(ps -p "$pid" -o stat= 2>/dev/null || true)
  case "$stat" in
    Z*) return 1 ;;
  esac
  return 0
}

wait_for_exit() {
  local pid=$1 limit=${2:-50} i=0
  while [ "$i" -lt "$limit" ]; do
    if ! is_live_non_zombie "$pid"; then
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

file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

wait_poll_cycle() {  # <state> <pid> [limit-ticks]
  local state=$1 pid=$2 limit=${3:-300} beat first now i=0
  beat="$state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat")
    [ -n "$first" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    if [ -n "$now" ] && [ "$now" != "$first" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

# mark_status_seen <state> <status-file>: record the file's CURRENT complete
# snapshot as both reported and classified, so a status this case writes itself
# (a declared wait, then its lift) does not also raise a status-signal wake and
# mask which route the pane took.
mark_status_seen() {
  FM_STATE_OVERRIDE="$1" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    fm_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$1" "$2"
}

# prime_and_ack: run the watcher once on a long STALE_ESCALATE_SECS so it
# reaches the wedge path, drain the resulting wake, and return the state dir.
prime_and_ack() {
  local dir=$1 max=$2
  local state fakebin out capture_file window key sig pid
  state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedge-cap-$(basename "$dir" | sed -e 's/^wedge-cap-//' )"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max \
    "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "priming watch failed: $(cat "$out")"
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || fail "priming ack failed"
}

# poll_wedge_round: drive one wedge poll, optionally with the given cap
# settings, expect the watcher to exit on a wedge wake. Acknowledge.
poll_wedge_round() {
  local dir=$1 max=$2 extra_env=$3
  local state fakebin out capture_file window key pid n
  state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedge-cap-$(basename "$dir" | sed -e 's/^wedge-cap-//' )"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  # shellcheck disable=SC2086
  env FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max \
    PATH="$fakebin:$PATH" $extra_env \
    "$WATCH" > "$out" &
  pid=$!
  if ! wait_for_exit "$pid" 100; then
    reap "$pid"; fail "watcher did not exit on wedge round: $(cat "$out")"
  fi
  ack_stopped_cycle "$state" || fail "wedge round ack failed"
}

# poll_capped_wedge_round: one more poll on a pane already recorded as stably
# stale at its recorded hash - the population wedge_timer_check owns - with the
# cap settings a case chose, and WITHOUT acknowledging anything, so a case can
# leave a wake queued and unconsumed. <extra-env> drives the pane's endpoint
# verdict: FM_FAKE_TMUX_CURRENT_COMMAND is its foreground command and
# FM_FAKE_TMUX_WINDOWS the session inventory the recorded window must appear
# in, so an inventory that omits it reads as `missing`. `exit` requires the
# watcher to surface and exit, `absorb` requires it to survive whole poll cycles
# at the threshold instead.
poll_capped_wedge_round() {  # <dir> <max> <extra-env> <exit|absorb>
  local dir=$1 max=$2 extra_env=$3 mode=$4
  local state fakebin out capture_file window key pid
  state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedge-cap-$(basename "$dir" | sed -e 's/^wedge-cap-//' )"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  # shellcheck disable=SC2086
  env FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_STALE_ESCALATE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max \
    PATH="$fakebin:$PATH" $extra_env \
    "$WATCH" > "$out" &
  pid=$!
  if [ "$mode" = exit ]; then
    wait_for_exit "$pid" 100 || { reap "$pid"; return 1; }
    return 0
  fi
  wait_poll_cycle "$state" "$pid" 200 || { reap "$pid"; return 1; }
  reap "$pid"
  return 0
}

# log_tmux_inventory_calls <fakebin> <log>: wrap the case's fake tmux so every
# session-inventory read is logged. A watcher's ordinary per-poll traffic is
# capture-pane, so this log counts dead-endpoint probe attempts and nothing else.
log_tmux_inventory_calls() {
  local fakebin=$1 log=$2
  : > "$log"
  mv "$fakebin/tmux" "$fakebin/tmux-real"
  cat > "$fakebin/tmux" <<'PROBEWRAP'
#!/usr/bin/env bash
[ "${1:-}" = list-windows ] && printf 'probe\n' >> "${FM_FAKE_TMUX_INVENTORY_LOG:-/dev/null}"
exec "$FM_FAKE_TMUX_REAL" "$@"
PROBEWRAP
  chmod +x "$fakebin/tmux"
  export FM_FAKE_TMUX_REAL="$fakebin/tmux-real"
  export FM_FAKE_TMUX_INVENTORY_LOG="$log"
}

inventory_calls() {  # <log>
  local n
  n=$(grep -c '^probe$' "$1" 2>/dev/null) || n=0
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s\n' "$n"
}

# hold_capped_polls <dir> <max> <stale-secs> <timer-age-secs> <cycles> [env]:
# ONE watcher over <cycles> whole poll cycles on a pane already absorbed at its
# recorded hash, with the idle timer planted <timer-age-secs> old against a
# <stale-secs> threshold, so a case can place a window just under or well past
# that threshold and watch what each poll costs it. The endpoint reads live
# (FM_FAKE_TMUX_CURRENT_COMMAND=grok), so nothing here reports a death;
# <env> overrides the pane's verdict instead. Returns non-zero unless every
# cycle settles with the watcher still running - which is what a silenced window
# does - leaving <dir>/watch.out for the caller to read.
hold_capped_polls() {  # <dir> <max> <stale-secs> <timer-age-secs> <cycles> [extra-env]
  local dir=$1 max=$2 stale_secs=$3 timer_age=$4 cycles=$5 extra_env=${6-}
  local state fakebin out capture_file window key pid i
  state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedge-cap-$(basename "$dir" | sed -e 's/^wedge-cap-//' )"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  echo $(( $(date +%s) - timer_age )) > "$state/.stale-since-$key"
  : > "$out"
  # shellcheck disable=SC2086
  env FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=$stale_secs FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max \
    PATH="$fakebin:$PATH" $extra_env \
    "$WATCH" > "$out" &
  pid=$!
  i=1
  while [ "$i" -le "$cycles" ]; do
    wait_poll_cycle "$state" "$pid" 200 || { reap "$pid"; return 1; }
    i=$((i + 1))
  done
  reap "$pid"
  return 0
}

# Count the queued stale wakes for <window> whose payload carries <needle>.
queued_wakes_carrying() {  # <state> <window> <needle>
  awk -F '\t' -v w="$2" -v needle="$3" \
    'NF >= 5 && $3 == "stale" && $4 == w && index($5, needle) { n++ } END { print n + 0 }' \
    "$1/.wake-queue" 2>/dev/null || printf '0\n'
}

# 1. Disabled by default: FM_WEDGE_MAX_ESCALATIONS=0 leaves the cap inert,
# and a wedged worker keeps receiving stale wakes without ever firing
# PERMANENTLY-WEDGED.
test_wedge_cap_disabled_by_default() {
  local dir state out capture_file window key pane_hash sig pid
  dir=$(make_case wedge-cap-disabled); state="$dir/state"; capture_file="$dir/pane.txt"
  out="$dir/watch.out"
  window="test:fm-wedge-cap-disabled"
  printf 'wedged default-config pane' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-disabled.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-disabled.status"
  sig=$(seen_sig "$state/wedge-cap-disabled.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-disabled_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "wedged default-config pane")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  # Drive five wedge polls. Each must escape (escalation n, no PERMANENTLY-WEDGED),
  # and no cap marker may ever appear.
  local fakebin n
  fakebin="$dir/fakebin"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "priming watch failed (default-config cap path): $(cat "$out")"
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || fail "priming ack failed"
  n=1
  while [ "$n" -le 5 ]; do
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
      FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      "$WATCH" > "$out" &
    pid=$!
    if ! wait_for_exit "$pid" 100; then
      reap "$pid"; fail "wedge round $n (default config) failed to exit"
    fi
    grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null && fail "default-config round $n fired PERMANENTLY-WEDGED - cap should be disabled"
    [ ! -e "$state/.wedge-permanent-$key" ] || fail "default-config wrote the window-scoped cap marker (cap must stay inert)"
    ack_stopped_cycle "$state" || fail "default-config round $n ack failed"
    n=$((n + 1))
  done
  unset FM_FAKE_CREW_STATE
  pass "FM_WEDGE_MAX_ESCALATIONS=0 keeps the cap inert and never writes a cap marker"
}

# 2. Cap fires at threshold with PERMANENTLY-WEDGED and writes the
# window-scoped cap marker.
test_wedge_cap_fires_permanently_wedged_at_threshold() {
  local dir state out capture_file window key pane_hash sig
  dir=$(make_case wedge-cap-fires); state="$dir/state"; capture_file="$dir/pane.txt"
  out="$dir/watch.out"
  window="test:fm-wedge-cap-fires"
  printf 'idle wedged content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-fires.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-fires.status"
  sig=$(seen_sig "$state/wedge-cap-fires.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-fires_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle wedged content")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  prime_and_ack "$dir" 4 || fail "prime-and-ack failed"
  local n max
  n=1; max=4
  while [ "$n" -le "$max" ]; do
    poll_wedge_round "$dir" "$max" ""
    grep -F "escalation $n" "$out" >/dev/null || fail "round $n did not report escalation count $n: $(cat "$out")"
    if [ "$n" -lt "$max" ]; then
      grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null && fail "round $n fired PERMANENTLY-WEDGED before threshold"
    else
      grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null || fail "round $max did not fire PERMANENTLY-WEDGED: $(cat "$out")"
      grep -F "FM_WEDGE_MAX_ESCALATIONS=$max reached" "$out" >/dev/null || fail "round $max reason did not name FM_WEDGE_MAX_ESCALATIONS=$max: $(cat "$out")"
    fi
    n=$((n + 1))
  done
  [ -e "$state/.wedge-permanent-$key" ] || fail "window-scoped cap marker missing after cap fired"
  unset FM_FAKE_CREW_STATE
  pass "wedge cap fires PERMANENTLY-WEDGED at FM_WEDGE_MAX_ESCALATIONS and writes the window-scoped cap marker"
}

# 3. After the cap fires, subsequent polls on the SAME hash are silent
# (no PERMANENTLY-WEDGED wake).
test_wedge_cap_silences_subsequent_polls_for_same_hash() {
  local dir state out capture_file window key pane_hash
  dir=$(make_case wedge-cap-silenced); state="$dir/state"; capture_file="$dir/pane.txt"
  out="$dir/watch.out"
  window="test:fm-wedge-cap-silenced"
  printf 'idle wedged content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-silenced.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-silenced.status"
  pane_hash=$(hash_text "idle wedged content")
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  prime_and_ack "$dir" 3 || fail "prime-and-ack failed"
  local max n pid i
  max=3
  n=1
  while [ "$n" -le "$max" ]; do
    poll_wedge_round "$dir" "$max" ""
    n=$((n + 1))
  done
  grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null || fail "cap round did not fire PERMANENTLY-WEDGED"

  # Now drive 5 more polls on the SAME hash; none may fire PERMANENTLY-WEDGED.
  local fakebin
  fakebin="$dir/fakebin"
  i=0
  while [ "$i" -lt 5 ]; do
    i=$((i + 1))
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
      FM_STALE_ESCALATE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max \
      "$WATCH" > "$out" &
    pid=$!
    # A post-cap poll short-circuits inside wedge_timer_check on the
    # window-scoped marker and returns 0 without waking; the watcher keeps
    # polling until the next event. A watcher that exited with a wake of its own
    # fails this rather than passing quietly.
    if ! wait_poll_cycle "$state" "$pid" 200; then
      reap "$pid"
      fail "post-cap poll $i did not stay alive and silent: $(cat "$out")"
    fi
    reap "$pid"
    ack_stopped_cycle "$state" || true
    grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null && fail "post-cap poll $i re-fired PERMANENTLY-WEDGED"
  done
  unset FM_FAKE_CREW_STATE
  pass "subsequent polls on the same hash stay silent while the window-scoped cap marker stands"
}

# 4. The window-scoped marker silences a hash-churning pane that
# re-renders on every poll. The pane must receive at most ONE
# PERMANENTLY-WEDGED wake across all churn iterations, even when each poll
# presents a brand new stale hash.
test_wedge_cap_window_marker_silences_hash_churning_busy_pane() {
  local dir state out capture_file window key pane_hash sig pid
  dir=$(make_case wedge-cap-churning); state="$dir/state"; capture_file="$dir/pane.txt"
  out="$dir/watch.out"
  window="test:fm-wedge-cap-churning"
  fakebin="$dir/fakebin"
  printf 'churning wedged pane initial content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-churning.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-churning.status"
  sig=$(seen_sig "$state/wedge-cap-churning.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-churning_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "churning wedged pane initial content")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=3 \
    "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "priming watch failed (churning pane): $(cat "$out")"
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || fail "priming ack failed"
  local n max
  n=1; max=3
  while [ "$n" -le "$max" ]; do
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
      FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max \
      "$WATCH" > "$out" &
    pid=$!
    if ! wait_for_exit "$pid" 100; then
      reap "$pid"; fail "churning round $n failed to exit: $(cat "$out")"
    fi
    ack_stopped_cycle "$state" || fail "churning round $n ack failed"
    n=$((n + 1))
  done
  [ -e "$state/.wedge-permanent-$key" ] || fail "window-scoped cap marker missing after churn cap"
  local total_terminal i
  total_terminal=0
  i=0
  while [ "$i" -lt 12 ]; do
    i=$((i + 1))
    printf 'churning wedged pane iteration %d fresh content' "$i" > "$capture_file"
    # New hash on every poll: replace .hash-<key> so the matcher reads a
    # fresh hash each time, which is exactly the churn the window-scoped
    # marker has to stop.
    printf '%s' "$(hash_text "churning wedged pane iteration $i fresh content")" > "$state/.hash-$key"
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    # Record the fresh hash as this window's already-classified stale hash, the
    # state a pane that re-renders twice settles into. The FIRST-SIGHT route
    # would classify the new hash and publish nothing, so the poll would never
    # reach wedge_timer_check and the cap marker below would go unexercised.
    printf '%s' "$(hash_text "churning wedged pane iteration $i fresh content")" > "$state/.stale-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
      FM_STALE_ESCALATE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max FM_CAP_HORIZON_SECS=86400 \
      "$WATCH" > "$out" &
    pid=$!
    # A post-cap poll on a churning pane short-circuits on the window-scoped
    # marker at the top of wedge_timer_check and returns 0 without waking;
    # the watcher keeps polling. wait_poll_cycle confirms it is alive AND
    # did not publish a wake.
    if ! wait_poll_cycle "$state" "$pid" 200; then
      reap "$pid"; fail "post-cap churn poll $i watcher did not stay alive"
    fi
    # Stop the still-running watcher before grepping its output.
    reap "$pid"
    ack_stopped_cycle "$state" || true
    [ ! -s "$state/.wedge-escalations-$key" ] \
      || fail "post-cap churn poll $i advanced the escalation counter ($(cat "$state/.wedge-escalations-$key")); the window-scoped marker did not silence the wedge path"
    if grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null; then
      total_terminal=$((total_terminal + 1))
    fi
  done
  [ "$total_terminal" -eq 0 ] || fail "hash-churning pane re-fired PERMANENTLY-WEDGED $total_terminal times across 12 iterations - window-scoped marker is not silencing the loop"
  [ -e "$state/.wedge-permanent-$key" ] || fail "window-scoped marker was unexpectedly cleared during hash churn"
  unset FM_FAKE_CREW_STATE
  pass "the window-scoped cap marker silences a hash-churning pane across all post-cap polls"
}

# 5. The cap is bound by FM_CAP_HORIZON_SECS: after the marker ages past the
# horizon, a fresh wedge re-fires. Within the horizon a fresh stale hash in
# the same window is ALSO silent because the window-scoped marker still
# stands.
test_wedge_cap_expires_after_horizon() {
  local dir state out capture_file window key pane_hash sig
  dir=$(make_case wedge-cap-horizon); state="$dir/state"; capture_file="$dir/pane.txt"
  out="$dir/watch.out"
  fakebin="$dir/fakebin"
  window="test:fm-wedge-cap-horizon"
  printf 'idle wedged content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-horizon.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-horizon.status"
  sig=$(seen_sig "$state/wedge-cap-horizon.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-horizon_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle wedged content")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  prime_and_ack "$dir" 3 || fail "prime-and-ack failed"
  local max n pid
  max=3
  n=1
  while [ "$n" -le "$max" ]; do
    poll_wedge_round "$dir" "$max" ""
    n=$((n + 1))
  done
  grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null || fail "cap round did not fire PERMANENTLY-WEDGED"
  [ -e "$state/.wedge-permanent-$key" ] || fail "window-scoped marker missing after cap fire"

  # Within the (long) horizon, a fresh stale hash in the same window is silent:
  # the window-scoped marker silences wedge_timer_check without firing a wake,
  # so the watcher stays alive. wait_poll_cycle confirms both.
  printf 'idle wedged content fresh hash' > "$capture_file"
  new_hash=$(hash_text "idle wedged content fresh hash")
  printf '%s' "$new_hash" > "$state/.hash-$key"
  # Record the fresh hash as the already-classified stale hash of this window,
  # the state the pane settles into on its second identical render, so the poll
  # reaches wedge_timer_check where the window-scoped marker is consulted. The
  # FIRST-SIGHT route would classify and publish nothing, proving nothing about
  # the marker.
  printf '%s' "$new_hash" > "$state/.stale-$key"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max FM_CAP_HORIZON_SECS=86400 \
    "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid" 200; then
    reap "$pid"; fail "fresh-hash poll within horizon: watcher did not stay alive: $(cat "$out")"
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || true
  grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null && fail "fresh-hash poll within horizon fired PERMANENTLY-WEDGED - window-scoped marker is not silencing"
  [ ! -s "$state/.wedge-escalations-$key" ] \
    || fail "fresh-hash poll within horizon advanced the escalation counter ($(cat "$state/.wedge-escalations-$key")); the window-scoped marker did not silence the wedge path"

  # The same silence must hold when the horizon is a value the shell cannot
  # compare: bash's test ERRORS on such a value, and an errored comparison
  # reads as false, so the marker would expire at once and the cap would
  # re-fire on every poll - the unbounded train this cap exists to bound. An
  # unusable horizon is an invalid one, so the documented default applies and
  # the window stays silent. The idle timer is replanted so this poll reaches
  # the marker consult instead of waiting out the threshold.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max FM_CAP_HORIZON_SECS=99999999999999999999 \
    "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid" 200; then
    reap "$pid"; fail "fresh-hash poll with an unusable horizon: watcher did not stay alive: $(cat "$out")"
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || true
  grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null && fail "fresh-hash poll with an unusable horizon fired PERMANENTLY-WEDGED - the unusable horizon was not read as the documented default"
  [ ! -s "$state/.wedge-escalations-$key" ] \
    || fail "fresh-hash poll with an unusable horizon advanced the escalation counter ($(cat "$state/.wedge-escalations-$key")); the unusable horizon did not silence the wedge path"

  # Now age the cap marker past the horizon (cap=2s) and leave the pane
  # exactly as it was, so the only thing that changed is the marker age. The
  # escalation counter is pre-seeded one below the cap, so the very next poll
  # must drive the wedge to PERMANENTLY-WEDGED - proving the horizon released
  # the cap rather than an operator having removed the markers.
  cap_ts=$(( $(date +%s) - 5 ))
  printf '%s' "$cap_ts" > "$state/.wedge-permanent-$key"
  post_hash=$(hash_text "idle wedged content post-horizon")
  printf 'idle wedged content post-horizon' > "$capture_file"
  printf '%s' "$post_hash" > "$state/.hash-$key"
  printf '%s' "$post_hash" > "$state/.stale-$key"
  printf '%s\n' "$(( max - 1 ))" > "$state/.wedge-escalations-$key"
  printf '3\n' > "$state/.count-$key"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max FM_CAP_HORIZON_SECS=2 \
    "$WATCH" > "$out" &
  pid=$!
  if ! wait_for_exit "$pid" 100; then
    reap "$pid"; fail "post-horizon poll did not exit: $(cat "$out")"
  fi
  grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null || fail "post-horizon poll did not re-fire PERMANENTLY-WEDGED (cap did not expire)"
  unset FM_FAKE_CREW_STATE
  pass "the cap is bound by FM_CAP_HORIZON_SECS and re-fires after the horizon elapses"
}

# 6. Operator can rm the cap marker for immediate re-engagement; a fresh
# wedge then fires through a fresh counter.
test_wedge_cap_operator_can_rm_marker() {
  local dir state out capture_file window key pane_hash sig
  dir=$(make_case wedge-cap-operator-rm); state="$dir/state"; capture_file="$dir/pane.txt"
  out="$dir/watch.out"
  fakebin="$dir/fakebin"
  window="test:fm-wedge-cap-operator-rm"
  printf 'idle wedged content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-operator-rm.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-operator-rm.status"
  sig=$(seen_sig "$state/wedge-cap-operator-rm.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-operator-rm_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle wedged content")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  prime_and_ack "$dir" 3 || fail "prime-and-ack failed"
  local max n pid
  max=3
  n=1
  while [ "$n" -le "$max" ]; do
    poll_wedge_round "$dir" "$max" ""
    n=$((n + 1))
  done
  grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null || fail "cap round did not fire PERMANENTLY-WEDGED"
  [ -e "$state/.wedge-permanent-$key" ] || fail "window-scoped marker missing after cap fire"

  rm -f "$state/.wedge-permanent-$key"
  printf '1\n' > "$state/.count-$key"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max \
    "$WATCH" > "$out" &
  pid=$!
  if ! wait_for_exit "$pid" 60; then
    reap "$pid"; fail "post-rm poll did not exit: $(cat "$out")"
  fi
  grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null && fail "post-rm first poll re-fired the cap immediately (counter was not reset)"
  grep -F "escalation 1" "$out" >/dev/null || fail "post-rm first poll did not report fresh escalation 1: $(cat "$out")"
  unset FM_FAKE_CREW_STATE
  pass "operator rm of the cap marker lifts the cap and the next wedge re-accumulates from 1"
}

# 7. Invalid settings fall back to safe defaults: non-integer for any of the
# three cap settings is treated as the file-defined default, and 0 for the
# horizon or sentinel TTL falls back to the file-defined default rather than
# degrading into a re-fire loop.
test_wedge_cap_validates_invalid_overrides() {
  local dir state out capture_file window key pane_hash sig
  dir=$(make_case wedge-cap-validate); state="$dir/state"; capture_file="$dir/pane.txt"
  out="$dir/watch.out"
  fakebin="$dir/fakebin"
  window="test:fm-wedge-cap-validate"
  printf 'idle wedged content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-validate.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-validate.status"
  sig=$(seen_sig "$state/wedge-cap-validate.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-validate_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle wedged content")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Non-integer FM_WEDGE_MAX_ESCALATIONS falls back to 0 (cap disabled) and
  # the watcher must NOT fire PERMANENTLY-WEDGED across repeated wedges.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_WEDGE_MAX_ESCALATIONS=garbage FM_CAP_HORIZON_SECS=86400 FM_ROLLBACK_SENTINEL_TTL_SECS=3600 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" &
  local pid
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "priming watch (garbage override) failed"
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || fail "priming ack failed"
  local n
  n=1
  while [ "$n" -le 4 ]; do
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
      FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_WEDGE_MAX_ESCALATIONS=garbage FM_CAP_HORIZON_SECS=86400 FM_ROLLBACK_SENTINEL_TTL_SECS=3600 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      "$WATCH" > "$out" &
    pid=$!
    if ! wait_for_exit "$pid" 100; then
      reap "$pid"; fail "round $n (garbage override) failed to exit"
    fi
    grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null && fail "garbage override round $n fired PERMANENTLY-WEDGED - validation did not fall back to 0"
    n=$((n + 1))
  done
  unset FM_FAKE_CREW_STATE
  pass "non-integer FM_WEDGE_MAX_ESCALATIONS falls back to 0 and the cap stays inert"
}

# 7b. The escalation count is a count of consecutive escalations, so the
# counter file the ladder reads it from must never yield a number the shell
# cannot handle: a value beyond the shell's integer range ERRORS in a
# comparison and wraps around silently in the count's arithmetic, which would
# report a count of billions for a window that has escalated once - and, past
# any ceiling, a count that no longer describes the ladder. A counter the
# watcher cannot read as a count is a fresh count.
test_wedge_cap_reads_an_unreadable_counter_as_a_fresh_one() {
  local dir state out capture_file window key pane_hash sig
  dir=$(make_case wedge-cap-counter-unreadable); state="$dir/state"; capture_file="$dir/pane.txt"
  out="$dir/watch.out"
  fakebin="$dir/fakebin"
  window="test:fm-wedge-cap-counter-unreadable"
  printf 'idle wedged content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-counter-unreadable.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-counter-unreadable.status"
  sig=$(seen_sig "$state/wedge-cap-counter-unreadable.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-counter-unreadable_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle wedged content")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  prime_and_ack "$dir" 0 || fail "prime-and-ack failed"

  # A counter file holding a value beyond the shell's integer range. The next
  # poll must read it as a fresh count of 1.
  printf '99999999999999999999\n' > "$state/.wedge-escalations-$key"
  poll_wedge_round "$dir" 0 ""
  grep -F "escalation 1" "$out" >/dev/null \
    || fail "an escalation counter the shell cannot compare was not read as a fresh count: $(cat "$out")"
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || true)" = "1" ] \
    || fail "an escalation counter the shell cannot compare was not replaced by the fresh count: $(cat "$state/.wedge-escalations-$key" 2>/dev/null)"
  unset FM_FAKE_CREW_STATE
  pass "an escalation counter the shell cannot compare is read as a fresh count of 1, never as a count the arithmetic wrapped around"
}

# 8. The cap-fire path is durable: rolling back on a marker-write failure
# restores the escalation counter and stale timer, and a rollback failure
# itself writes a transient sentinel that silences the wedge for
# FM_ROLLBACK_SENTINEL_TTL_SECS.
test_wedge_cap_rollback_writes_sentinel_on_marker_failure() {
  local dir state out capture_file window key pane_hash sig pid n max marker_window sentinel
  dir=$(make_case wedge-cap-rollback); state="$dir/state"; capture_file="$dir/pane.txt"
  out="$dir/watch.out"
  fakebin="$dir/fakebin"
  window="test:fm-wedge-cap-rollback"
  printf 'idle wedged content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-rollback.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-rollback.status"
  sig=$(seen_sig "$state/wedge-cap-rollback.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-rollback_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle wedged content")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '2\n' > "$state/.count-$key"
  max=1
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  prime_and_ack "$dir" "$max" || fail "prime-and-ack failed"
  marker_window="$state/.wedge-permanent-$key"
  sentinel="$state/.wedge-rollback-failed-$key"

  # Two planted write failures in one poll: the cap-marker path is
  # a non-empty directory (so that write fails), and the escalation-counter
  # path is a directory (so the rollback's own counter reset fails too). A
  # failed rollback must leave a sentinel rather than silently preserving the
  # saturated counter, which would re-fire the wedge on every poll - the
  # wake-queue flood this bounds.
  mkdir -p "$marker_window/blocker"
  mkdir -p "$state/.wedge-escalations-$key"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max \
    "$WATCH" > "$out" &
  pid=$!
  # No `set -e` on either side: this script opts into `set -u` only, so enabling
  # errexit inside a case would change the error semantics of every case after it.
  wait_for_exit "$pid" 100
  round_status=$?
  [ "$round_status" -eq 1 ] || fail "cap-fire round expected exit 1 on the failed marker write, got $round_status: $(cat "$out")"
  [ -e "$sentinel" ] || fail "rollback-failed sentinel was not written after the rollback itself failed"
  unset FM_FAKE_CREW_STATE
  ack_stopped_cycle "$state" || fail "ack after the cap-fire round failed"

  # Drive one more poll: the sentinel short-circuits the wedge path. Within
  # FM_ROLLBACK_SENTINEL_TTL_SECS no new wake may be published at all.
  local queue_before
  queue_before=$(cat "$state/.wake-queue" 2>/dev/null || true)
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max FM_ROLLBACK_SENTINEL_TTL_SECS=3600 \
    "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || true
  grep -F "possible wedge" "$out" >/dev/null && fail "sentinel short-circuit still published a wedge wake"
  # The cap-fire round already queued its terminal wake (it appended before the
  # marker write it then failed on), so compare against the snapshot rather than
  # against an empty queue: no NEW stale row may appear while the sentinel holds.
  [ "$(cat "$state/.wake-queue" 2>/dev/null || true)" = "$queue_before" ] \
    || fail "sentinel short-circuit queued another wake: $(cat "$state/.wake-queue" 2>/dev/null)"
  grep -F "rollback-failed sentinel active" "$state/.watch-triage.log" >/dev/null \
    || fail "expected the sentinel short-circuit triage line; got triage: $(cat "$state/.watch-triage.log" 2>/dev/null) and watch.out: $(cat "$out")"
  [ -e "$sentinel" ] || fail "the sentinel was removed by the short-circuit poll; it must hold until TTL expiry or an operator rm"

  # The sentinel must hold just as long when the TTL is a value the shell
  # cannot compare: bash's test ERRORS on such a value and an errored
  # comparison reads as false, so the sentinel would be dropped on the very
  # next poll and the failed-write route would be back on every poll - the
  # wake-queue flood this sentinel exists to bound. An unusable TTL is an
  # invalid one, so the documented default applies and the sentinel holds.
  : > "$state/.watch-triage.log"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max FM_ROLLBACK_SENTINEL_TTL_SECS=99999999999999999999 \
    "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || true
  grep -F "rollback-failed sentinel active" "$state/.watch-triage.log" >/dev/null \
    || fail "a rollback-failed sentinel with an unusable TTL did not hold the wedge path: $(cat "$state/.watch-triage.log" 2>/dev/null) and watch.out: $(cat "$out")"
  [ -e "$sentinel" ] || fail "a rollback-failed sentinel with an unusable TTL was dropped instead of holding for the documented default"
  [ "$(cat "$state/.wake-queue" 2>/dev/null || true)" = "$queue_before" ] \
    || fail "a rollback-failed sentinel with an unusable TTL queued another wake: $(cat "$state/.wake-queue" 2>/dev/null)"

  # The sentinel silences ESCALATIONS, not detection: the agent exits while its
  # pane keeps rendering the identical frame, so the session inventory no longer
  # lists the recorded window and the endpoint reads as missing. A wedge path
  # that silenced that report too would hide a dead worker for the whole TTL.
  local gone
  gone="FM_FAKE_TMUX_CURRENT_COMMAND=bash FM_FAKE_TMUX_WINDOWS=someone-elses-window"
  poll_capped_wedge_round "$dir" "$max" "$gone" exit \
    || fail "the sentinel never reported the endpoint that went missing while it held: $(cat "$out")"
  grep -F "agent missing" "$out" >/dev/null \
    || fail "the gone endpoint was not reported while the sentinel held: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null \
    && fail "the gone endpoint was escalated as a wedge instead of reported: $(cat "$out")"
  [ "$(queued_wakes_carrying "$state" "$window" "agent missing")" -eq 1 ] \
    || fail "the sentinel reported the gone endpoint more than once"
  [ -e "$sentinel" ] || fail "reporting the gone endpoint consumed the sentinel; it must hold until TTL expiry or an operator rm"
  pass "the rollback-failed sentinel silences the wedge path within FM_ROLLBACK_SENTINEL_TTL_SECS and still reports a gone endpoint"
}

# 8b. The consecutive-escalation count is the only state the ceiling is
# computed from, so a state dir that will not take that write leaves a ceiling
# that cannot stop anything: every poll reads 1 again and republishes an
# escalation, which is the unbounded train this cap exists to bound, signalled
# only by a triage line in a log documented as safe to delete. A configured cap
# must therefore defend the count write the way the marker route defends its own
# marker - roll back, silence the path, end the cycle only when even the sentinel
# cannot be written - while the default uncapped path, which has no ceiling to
# enforce, keeps escalating exactly as it always has.
test_wedge_cap_unwritable_escalation_count_fails_safe() {
  local dir state out capture_file window key pane_hash sig fakebin max pid round_status sentinel
  dir=$(make_case wedge-cap-counter-fail); state="$dir/state"; capture_file="$dir/pane.txt"
  out="$dir/watch.out"; fakebin="$dir/fakebin"
  window="test:fm-wedge-cap-counter-fail"
  printf 'idle wedged content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-counter-fail.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-counter-fail.status"
  sig=$(seen_sig "$state/wedge-cap-counter-fail.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-counter-fail_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle wedged content")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  max=3
  prime_and_ack "$dir" "$max" || fail "prime-and-ack failed"
  sentinel="$state/.wedge-rollback-failed-$key"
  # The escalation-count path is a directory, so the write every later poll reads
  # the count from fails the way the marker route's planted blocker makes its
  # own marker write fail.
  mkdir -p "$state/.wedge-escalations-$key"

  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max \
    FM_ROLLBACK_SENTINEL_TTL_SECS=3600 \
    "$WATCH" > "$out" &
  pid=$!
  round_status=0
  wait_for_exit "$pid" 100 || round_status=$?
  [ "$round_status" -eq 1 ] \
    || fail "a failed escalation-count write under a configured cap expected exit 1, got $round_status: $(cat "$out")"
  [ "$(queued_wakes_carrying "$state" "$window" "possible wedge")" -eq 0 ] \
    || fail "a wedge escalation whose count could not be recorded was published anyway: $(cat "$state/.wake-queue" 2>/dev/null)"
  [ -e "$sentinel" ] \
    || fail "an escalation count this state dir refuses left the wedge path unsilenced: $(cat "$state/.watch-triage.log" 2>/dev/null)"

  # The next poll has to find that silence rather than restart at escalation 1:
  # one escalation per STALE_ESCALATE_SECS forever is exactly what this cap
  # exists to stop, and here nothing can record the count that would stop it.
  poll_capped_wedge_round "$dir" "$max" "" absorb \
    || fail "the poll after an unwritable escalation count never settled: $(cat "$out")"
  [ "$(queued_wakes_carrying "$state" "$window" "possible wedge")" -eq 0 ] \
    || fail "the next poll republished a wedge escalation from a counter this state dir refuses: $(cat "$state/.wake-queue" 2>/dev/null)"
  grep -F "rollback-failed sentinel active" "$state/.watch-triage.log" >/dev/null \
    || fail "the silenced poll did not report the sentinel to the operator: $(cat "$state/.watch-triage.log" 2>/dev/null)"

  # With the cap OFF there is no ceiling to enforce, so the same unwritable
  # counter must silence nothing: the unconfigured schedule is unchanged, and a
  # leftover sentinel from the configured rounds is left unread there.
  poll_wedge_round "$dir" 0 "FM_WATCH_HANDLING_SUCCESSOR=1"
  grep -F "escalation 1" "$out" >/dev/null \
    || fail "an unwritable escalation count silenced a window whose cap is off: $(cat "$out")"
  grep -F "escalation counter write FAILED" "$state/.watch-triage.log" >/dev/null \
    || fail "the unwritable escalation count was not reported on the uncapped path either: $(cat "$state/.watch-triage.log" 2>/dev/null)"
  [ -e "$sentinel" ] \
    || fail "the uncapped path consumed the sentinel the capped rounds stood"
  unset FM_FAKE_CREW_STATE
  pass "an escalation count the state dir refuses fails safe under a configured cap and silences nothing without one"
}

# 8c. The rollback-failure sentinel silences escalations, not detection - but
# the detection it keeps is the SAME dead-endpoint probe every other wedge route
# runs behind the STALE_ESCALATE_SECS threshold, paced by the idle timer the
# probe itself re-arms. Read from the top of the function, as its silence has to
# be, that probe had no threshold to sit behind: a window the sentinel held ran
# it on every poll for the whole TTL, so with the defaults a silenced window
# paid a backend read every 15s instead of every 240s, for an hour, while
# publishing nothing at all. Count the inventory reads the probe starts with,
# once below the threshold and once at it.
test_wedge_cap_sentinel_probe_keeps_its_cadence() {
  local dir state out capture_file window key pane_hash sig fakebin max sentinel inventory below at
  dir=$(make_case wedge-cap-sentinel-cadence); state="$dir/state"; capture_file="$dir/pane.txt"
  out="$dir/watch.out"; fakebin="$dir/fakebin"
  window="test:fm-wedge-cap-sentinel-cadence"
  printf 'idle wedged content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-sentinel-cadence.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-sentinel-cadence.status"
  sig=$(seen_sig "$state/wedge-cap-sentinel-cadence.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-sentinel-cadence_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle wedged content")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  max=1
  prime_and_ack "$dir" "$max" || fail "prime-and-ack failed"

  # A cap-state write this state dir refused, already rolled back as far as it
  # could: the sentinel the wedge path silences itself through for the TTL. The
  # window is wedged and already absorbed, and its endpoint reads live, so the
  # only thing the silence can still do here is consult the probe.
  sentinel="$state/.wedge-rollback-failed-$key"
  printf '%s rollback-failed\n' "$(date +%s)" > "$sentinel"
  inventory="$dir/inventory.log"
  log_tmux_inventory_calls "$fakebin" "$inventory"

  # Below the threshold the probe has nothing to decide: five whole polls, no
  # endpoint read, still no wake.
  hold_capped_polls "$dir" "$max" 240 5 5 \
    || fail "the silenced window did not stay silent and alive below the threshold: $(cat "$out")"
  below=$(inventory_calls "$inventory")
  [ "$below" -eq 0 ] \
    || fail "a window silenced below the escalation threshold read its endpoint $below times across five polls; the dead-endpoint probe belongs behind the same threshold every other wedge route runs it behind"
  [ -e "$sentinel" ] || fail "a poll below the threshold consumed the sentinel; it must hold until TTL expiry or an operator rm"

  # At the threshold the probe is owed its one read, and its own re-arm of the
  # shared idle timer is what keeps the rest of the polls off the backend.
  : > "$inventory"
  hold_capped_polls "$dir" "$max" 240 500 5 \
    || fail "the silenced window did not stay silent and alive at the threshold: $(cat "$out")"
  at=$(inventory_calls "$inventory")
  [ "$at" -le 1 ] \
    || fail "a window silenced at the escalation threshold read its endpoint $at times across five polls; the probe must keep its once-per-STALE_ESCALATE_SECS cadence there too"
  [ "$(queued_wakes_carrying "$state" "$window" "possible wedge")" -eq 0 ] \
    || fail "the sentinel published a wedge wake: $(cat "$state/.wake-queue" 2>/dev/null)"
  [ -e "$sentinel" ] || fail "a poll at the threshold consumed the sentinel; it must hold until TTL expiry or an operator rm"
  unset FM_FAKE_CREW_STATE FM_FAKE_TMUX_REAL FM_FAKE_TMUX_INVENTORY_LOG
  pass "a window silenced by the rollback-failure sentinel keeps the probe on its escalation cadence, not once per poll"
}

# 9. The cap is a ceiling on CONSECUTIVE escalations: a crew that genuinely
# resumes after the cap fired takes the watcher's wedge-bookkeeping reset with
# it, so the cap marker goes and a pane that wedges again escalates normally
# instead of staying silent until the horizon elapses.
test_wedge_cap_releases_after_genuine_recovery() {
  local dir state out capture_file window key pane_hash sig pid fakebin max n
  dir=$(make_case wedge-cap-recovery); state="$dir/state"; capture_file="$dir/pane.txt"
  out="$dir/watch.out"; fakebin="$dir/fakebin"
  window="test:fm-wedge-cap-recovery"
  printf 'idle wedged content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-recovery.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-recovery.status"
  sig=$(seen_sig "$state/wedge-cap-recovery.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-recovery_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle wedged content")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  prime_and_ack "$dir" 3 || fail "prime-and-ack failed"
  max=3
  n=1
  while [ "$n" -le "$max" ]; do
    poll_wedge_round "$dir" "$max" ""
    n=$((n + 1))
  done
  grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null || fail "cap round did not fire PERMANENTLY-WEDGED"
  [ -e "$state/.wedge-permanent-$key" ] || fail "window-scoped marker missing after cap fire"

  # The crew genuinely resumes: a busy pane whose completed-turn marker is
  # fresh, so it is not over the busy-turn bound and lands on the watcher's
  # reset-the-escalation-bookkeeping branch.
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  printf 'crew resumed, work rendering again' > "$capture_file"
  : > "$state/fm-wedge-cap-recovery.turn-ended"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max \
    "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "resume poll failed: $(cat "$out")"
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || fail "resume ack failed"
  [ ! -e "$state/.wedge-permanent-$key" ] \
    || fail "the window-scoped cap marker survived a genuine recovery; a re-wedging pane would stay silent until the horizon"

  # The crew wedges again: the escalation must reach the supervisor as an
  # ordinary wedge wake off a fresh counter, not as the cap's silence.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  rm -f "$state/fm-wedge-cap-recovery.turn-ended"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max \
    "$WATCH" > "$out" &
  pid=$!
  if ! wait_for_exit "$pid" 150; then
    reap "$pid"; fail "the re-wedged pane stayed silent after a genuine recovery: $(cat "$out")"
  fi
  grep -F "escalation 1" "$out" >/dev/null || fail "the re-wedge did not escalate from a fresh counter: $(cat "$out")"
  grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null && fail "the re-wedge fired the cap again instead of escalating normally"
  unset FM_FAKE_CREW_STATE
  pass "a genuine recovery clears the cap marker and the re-wedged pane escalates again"
}

# 10. The terminal wake is durable, so it is published BEFORE the cap markers
# and a marker write that keeps failing rolls the cap state back - which lets
# the cap re-accumulate and re-fire on the very next poll. Those repeated cap
# cycles must not each append their own PERMANENTLY-WEDGED row: one
# unacknowledged terminal row per window is the bound.
test_wedge_cap_publishes_one_terminal_wake_under_persistent_marker_failure() {
  local dir state out capture_file window key pane_hash sig pid fakebin max marker_window cycle round_status terminal_rows
  dir=$(make_case wedge-cap-dup-terminal); state="$dir/state"; capture_file="$dir/pane.txt"
  out="$dir/watch.out"; fakebin="$dir/fakebin"
  window="test:fm-wedge-cap-dup-terminal"
  printf 'idle wedged content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-dup-terminal.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-dup-terminal.status"
  sig=$(seen_sig "$state/wedge-cap-dup-terminal.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-dup-terminal_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle wedged content")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  max=1
  prime_and_ack "$dir" "$max" || fail "prime-and-ack failed"

  # A non-empty directory on the cap-marker path makes that write
  # fail on every cycle, while the rollback's own counter reset and idle-timer
  # refresh keep succeeding - so the cap re-accumulates from scratch and fires
  # again on the next wedge poll.
  marker_window="$state/.wedge-permanent-$key"
  mkdir -p "$marker_window/blocker"
  cycle=1
  while [ "$cycle" -le 2 ]; do
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
      FM_WATCH_HANDLING_SUCCESSOR=1 \
      FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max \
      "$WATCH" > "$out" &
    pid=$!
    round_status=0
    wait_for_exit "$pid" 100 || round_status=$?
    [ "$round_status" -eq 1 ] \
      || fail "cap cycle $cycle expected exit 1 on the failed marker write, got $round_status: $(cat "$out")"
    grep -F "cap-marker write FAILED on" "$state/.watch-triage.log" >/dev/null \
      || fail "cap cycle $cycle did not report the failed marker write: $(cat "$state/.watch-triage.log")"
    [ -d "$marker_window/blocker" ] || fail "cap cycle $cycle consumed the planted marker-write blocker"
    cycle=$((cycle + 1))
  done
  terminal_rows=$(awk -F '\t' '$3 == "stale" && $5 ~ /PERMANENTLY-WEDGED/ { n++ } END { print n + 0 }' "$state/.wake-queue")
  [ "$terminal_rows" -eq 1 ] \
    || fail "two cap cycles under a persistent marker-write failure queued $terminal_rows PERMANENTLY-WEDGED rows; exactly one terminal wake per window is the bound"
  grep -F "suppressing the duplicate terminal wake" "$state/.watch-triage.log" >/dev/null \
    || fail "the second cap cycle did not suppress its duplicate terminal wake: $(cat "$state/.watch-triage.log")"
  unset FM_FAKE_CREW_STATE
  pass "a persistent marker-write failure across two cap cycles queues exactly one PERMANENTLY-WEDGED wake"
}

# 11. The release boundary is the wedge EPISODE, not one branch of it. Every
# reset that drops a window's escalation count must drop the cap markers with
# it, and the sibling routes to that reset are the declared wait: the crew
# declares an external pause (absorbed on the long pause cadence) and then
# lifts it (reconciled on the next poll). A window left silent on either half
# would keep a recovered pane dark for the rest of FM_CAP_HORIZON_SECS.
test_wedge_cap_releases_after_declared_wait() {
  local dir state out capture_file window key pane_hash sig pid fakebin max n statusf
  dir=$(make_case wedge-cap-declared-wait); state="$dir/state"; capture_file="$dir/pane.txt"
  out="$dir/watch.out"; fakebin="$dir/fakebin"
  window="test:fm-wedge-cap-declared-wait"
  statusf="$state/wedge-cap-declared-wait.status"
  printf 'idle wedged content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-declared-wait.meta"
  printf 'working: still wedged\n' > "$statusf"
  mark_status_seen "$state" "$statusf"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle wedged content")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  prime_and_ack "$dir" 3 || fail "prime-and-ack failed"
  max=3
  n=1
  while [ "$n" -le "$max" ]; do
    poll_wedge_round "$dir" "$max" ""
    n=$((n + 1))
  done
  grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null || fail "cap round did not fire PERMANENTLY-WEDGED"
  [ -e "$state/.wedge-permanent-$key" ] || fail "window-scoped marker missing after cap fire"

  # The crew declares an external wait, so the pane is absorbed on the long
  # pause cadence - the wedge episode it was in ends there, not on the busy
  # branch the previous case exercises.
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · holding for the upstream tool release'
  printf 'paused: holding for the upstream tool release\n' > "$statusf"
  mark_status_seen "$state" "$statusf"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max \
    "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "declared-wait poll failed: $(cat "$out")"
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || fail "declared-wait ack failed"
  [ -e "$state/.paused-$key" ] || fail "the declared wait was not absorbed on the pause cadence"
  [ ! -e "$state/.wedge-permanent-$key" ] \
    || fail "the window-scoped cap marker survived the declared wait; a re-wedging pane would stay silent until the horizon"

  # The wait is lifted, so the pause reconciliation drops the rest of the
  # window's bookkeeping on its next poll.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  printf 'working: the wait is over\n' > "$statusf"
  mark_status_seen "$state" "$statusf"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max \
    "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "wait-lift poll failed: $(cat "$out")"
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || fail "wait-lift ack failed"

  # The crew wedges again: the escalation must reach the supervisor off a fresh
  # counter, not as the cap's silence.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max \
    "$WATCH" > "$out" &
  pid=$!
  if ! wait_for_exit "$pid" 150; then
    reap "$pid"; fail "the re-wedged pane stayed silent after a declared wait ended: $(cat "$out")"
  fi
  grep -F "escalation 1" "$out" >/dev/null || fail "the re-wedge did not escalate from a fresh counter: $(cat "$out")"
  grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null && fail "the re-wedge fired the cap again instead of escalating normally"
  unset FM_FAKE_CREW_STATE
  pass "a declared wait and its lift both release the cap markers, and the re-wedged pane escalates again"
}

# 12. The cap is a ceiling on ESCALATIONS, not on detection. A pane that keeps
# rendering the identical frame after its agent exits is not a wedge suspect at
# all, so the marker short-circuit must still consult the dead-record probe: the
# gone endpoint is reported once while the cap holds, and every later capped poll
# stays quiet instead of re-reporting it or re-firing the terminal wake.
test_wedge_cap_reports_gone_endpoint_while_capped() {
  local dir state out capture_file window key pane_hash sig pid fakebin max gone round
  dir=$(make_case wedge-cap-gone-endpoint); state="$dir/state"; capture_file="$dir/pane.txt"
  out="$dir/watch.out"; fakebin="$dir/fakebin"
  window="test:fm-wedge-cap-gone-endpoint"
  printf 'idle wedged content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-gone-endpoint.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-gone-endpoint.status"
  sig=$(seen_sig "$state/wedge-cap-gone-endpoint.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-gone-endpoint_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle wedged content")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  max=1
  prime_and_ack "$dir" "$max" || fail "prime-and-ack failed"

  # The endpoint is a live agent for this round, so the pane is escalated rather
  # than reported gone and the ceiling fires while the worker is provably here.
  poll_wedge_round "$dir" "$max" "FM_FAKE_TMUX_CURRENT_COMMAND=grok"
  grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null \
    || fail "the cap did not fire against a live endpoint: $(cat "$out")"
  [ -e "$state/.wedge-permanent-$key" ] || fail "the window-scoped cap marker is missing after the cap fired"

  # The agent now exits while its pane keeps rendering the identical frame: the
  # session inventory no longer lists the recorded window, so the endpoint reads
  # as missing rather than as an agent that might still recover.
  gone="FM_FAKE_TMUX_CURRENT_COMMAND=bash FM_FAKE_TMUX_WINDOWS=someone-elses-window"
  poll_capped_wedge_round "$dir" "$max" "$gone" exit \
    || fail "the capped window never reported its gone endpoint: $(cat "$out")"
  grep -F "agent missing" "$out" >/dev/null \
    || fail "the capped window did not report the gone endpoint: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null \
    && fail "the gone endpoint was escalated as a wedge instead of reported: $(cat "$out")"

  # Two further capped polls: the death is delivered once, not once per poll, and
  # neither of them re-fires the terminal wake or advances the counter.
  round=1
  while [ "$round" -le 2 ]; do
    poll_capped_wedge_round "$dir" "$max" "$gone" absorb \
      || fail "capped poll $round surfaced a wake: $(cat "$out")"
    grep -F "agent missing" "$out" >/dev/null \
      && fail "capped poll $round repeated the already-reported gone endpoint"
    grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null \
      && fail "capped poll $round re-fired the terminal wake"
    [ ! -s "$state/.wedge-escalations-$key" ] \
      || fail "capped poll $round advanced the escalation counter"
    round=$((round + 1))
  done
  gone=$(queued_wakes_carrying "$state" "$window" "agent missing")
  [ "$gone" -eq 1 ] \
    || fail "the capped window queued $gone gone-endpoint reports; a death is reported once per incarnation"
  unset FM_FAKE_CREW_STATE
  pass "a capped window still reports its gone endpoint exactly once across repeated polls"
}

# 13. The duplicate suppression for the terminal wake is episode-scoped, not
# window-scoped. The cap markers are released on every legitimate episode-ending
# reset, so a terminal wake left queued and UNACKNOWLEDGED by an earlier episode
# must not silence the next episode's own wake - while a rollback that keeps
# re-firing the cap inside one episode still publishes no second row (case 10).
test_wedge_cap_new_episode_publishes_its_own_terminal_wake() {
  local dir state out capture_file window key pane_hash sig pid fakebin max post_hash terminal_rows
  dir=$(make_case wedge-cap-new-episode); state="$dir/state"; capture_file="$dir/pane.txt"
  out="$dir/watch.out"; fakebin="$dir/fakebin"
  window="test:fm-wedge-cap-new-episode"
  printf 'idle wedged content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-new-episode.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-new-episode.status"
  sig=$(seen_sig "$state/wedge-cap-new-episode.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-new-episode_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle wedged content")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  max=1
  prime_and_ack "$dir" "$max" || fail "prime-and-ack failed"

  # Episode 1: the cap fires and its terminal wake is deliberately left queued
  # and unacknowledged, standing in for a supervisor that never consumed it.
  poll_capped_wedge_round "$dir" "$max" "" exit \
    || fail "the first episode did not fire the cap: $(cat "$out")"
  grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null \
    || fail "the first episode did not fire PERMANENTLY-WEDGED: $(cat "$out")"
  [ "$(queued_wakes_carrying "$state" "$window" "PERMANENTLY-WEDGED")" -eq 1 ] \
    || fail "the first episode did not queue exactly one terminal wake"

  # The crew genuinely resumes: a busy pane whose completed-turn marker is fresh
  # lands on the watcher's reset branch, which releases the cap state - the end
  # of that wedge episode - without consuming the wake still sitting in the queue.
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  printf 'crew resumed, work rendering again' > "$capture_file"
  : > "$state/wedge-cap-new-episode.turn-ended"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max \
    "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "resume poll failed: $(cat "$out")"
  fi
  reap "$pid"
  [ ! -e "$state/.wedge-permanent-$key" ] \
    || fail "the window-scoped cap marker survived the recovery that ended the first episode"

  # Episode 2: the crew wedges again on a fresh render, and the cap fires again.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  rm -f "$state/wedge-cap-new-episode.turn-ended"
  post_hash=$(hash_text "idle wedged content second episode")
  printf 'idle wedged content second episode' > "$capture_file"
  printf '%s' "$post_hash" > "$state/.hash-$key"
  printf '%s' "$post_hash" > "$state/.stale-$key"
  printf '3\n' > "$state/.count-$key"
  poll_capped_wedge_round "$dir" "$max" "" exit \
    || fail "the second episode stayed silent instead of publishing its own terminal wake: $(cat "$out")"
  terminal_rows=$(queued_wakes_carrying "$state" "$window" "PERMANENTLY-WEDGED")
  [ "$terminal_rows" -eq 2 ] \
    || fail "the second episode's terminal wake was suppressed by the first episode's unacknowledged one; $terminal_rows rows are queued"
  unset FM_FAKE_CREW_STATE
  pass "a new wedge episode publishes its own terminal wake behind an unconsumed earlier one"
}

# 14. The dead-endpoint probe keeps its own once-per-STALE_ESCALATE_SECS budget
# while a cap stands. Nothing clears the idle timer under a fired cap, so a probe
# that did not re-arm it would run a backend read on every poll for the whole
# horizon - and the canonical capped pane is one whose agent is provably still
# there, which is exactly the verdict that leaves the timer alone.
test_wedge_cap_probe_keeps_its_cadence_while_capped() {
  local dir state out capture_file window key pane_hash sig fakebin max probes inventory
  dir=$(make_case wedge-cap-probe-cadence); state="$dir/state"; capture_file="$dir/pane.txt"
  out="$dir/watch.out"; fakebin="$dir/fakebin"
  window="test:fm-wedge-cap-probe-cadence"
  printf 'idle wedged content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-probe-cadence.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-probe-cadence.status"
  sig=$(seen_sig "$state/wedge-cap-probe-cadence.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-probe-cadence_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle wedged content")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  max=1
  prime_and_ack "$dir" "$max" || fail "prime-and-ack failed"

  # The cap fires against a live agent, so the window it silences is one whose
  # endpoint the probe keeps answering `alive` - the case that must not become
  # a per-poll backend read.
  poll_wedge_round "$dir" "$max" "FM_FAKE_TMUX_CURRENT_COMMAND=grok"
  grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null \
    || fail "the cap did not fire against a live endpoint: $(cat "$out")"
  [ -e "$state/.wedge-permanent-$key" ] || fail "the cap marker is missing after the cap fired"

  inventory="$dir/inventory.log"
  log_tmux_inventory_calls "$fakebin" "$inventory"

  # The pane is already past a long escalation bound, and the cap marker stands,
  # so every poll reaches the at-threshold branch where the probe runs. The
  # window must stay silent while the probe keeps to its own cadence.
  hold_capped_polls "$dir" "$max" 240 500 5 \
    || fail "a capped poll did not stay silent and alive: $(cat "$out")"
  probes=$(inventory_calls "$inventory")
  [ "$probes" -le 1 ] \
    || fail "the capped window probed its endpoint $probes times across ten poll cycles; a cap that silences escalations must not turn the dead-endpoint probe into a per-poll backend read"
  grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null && fail "a capped poll re-fired the terminal wake"
  [ ! -s "$state/.wedge-escalations-$key" ] \
    || fail "a capped poll advanced the escalation counter while the probe kept its cadence"
  unset FM_FAKE_CREW_STATE FM_FAKE_TMUX_REAL FM_FAKE_TMUX_INVENTORY_LOG
  pass "a capped live endpoint is probed on its own escalation cadence, not once per poll"
}

# 15. A state dir that accepts the queue append but refuses to create the
# terminal-row episode marker is the degraded case that marker cannot cover.
# It must narrow duplicate suppression to the window-scoped queue check rather
# than switching it off, or every cap cycle appends its own terminal wake - the
# queue flood this cap exists to bound.
test_wedge_cap_unwritable_terminal_marker_does_not_flood() {
  local dir state out capture_file window key pane_hash sig pid fakebin max marker_window marker_episode cycle round_status terminal_rows
  dir=$(make_case wedge-cap-unwritable-marker); state="$dir/state"; capture_file="$dir/pane.txt"
  out="$dir/watch.out"; fakebin="$dir/fakebin"
  window="test:fm-wedge-cap-unwritable-marker"
  printf 'idle wedged content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-unwritable-marker.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-unwritable-marker.status"
  sig=$(seen_sig "$state/wedge-cap-unwritable-marker.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-unwritable-marker_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle wedged content")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  max=1
  prime_and_ack "$dir" "$max" || fail "prime-and-ack failed"

  # The episode marker cannot be created - a dangling symlink is absent to
  # every existence test and unwritable on every write - while appending to the
  # existing .wake-queue keeps working. The cap-marker path is a directory, so
  # the cap rolls back and re-fires on the next poll, which is what makes a
  # second terminal append possible at all.
  marker_episode="$state/.wedge-terminal-queued-$key"
  marker_window="$state/.wedge-permanent-$key"
  ln -s "$state/no-such-dir/episode" "$marker_episode"
  mkdir -p "$marker_window/blocker"
  cycle=1
  while [ "$cycle" -le 2 ]; do
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
      FM_WATCH_HANDLING_SUCCESSOR=1 \
      FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max \
      "$WATCH" > "$out" &
    pid=$!
    round_status=0
    wait_for_exit "$pid" 100 || round_status=$?
    [ "$round_status" -eq 1 ] \
      || fail "cap cycle $cycle expected exit 1 on the failed cap-marker write, got $round_status: $(cat "$out")"
    cycle=$((cycle + 1))
  done
  terminal_rows=$(queued_wakes_carrying "$state" "$window" "PERMANENTLY-WEDGED")
  [ "$terminal_rows" -eq 1 ] \
    || fail "two cap cycles with an unwritable episode marker queued $terminal_rows PERMANENTLY-WEDGED rows; a marker this state dir refuses must not widen into a row per cycle"
  grep -F "falls back to the queue check alone" "$state/.watch-triage.log" >/dev/null \
    || fail "the unwritable episode marker was not reported to the operator: $(cat "$state/.watch-triage.log" 2>/dev/null)"
  grep -F "suppressing the duplicate terminal wake" "$state/.watch-triage.log" >/dev/null \
    || fail "the second cap cycle did not suppress its duplicate terminal wake: $(cat "$state/.watch-triage.log" 2>/dev/null)"
  unset FM_FAKE_CREW_STATE
  pass "an unwritable terminal episode marker narrows suppression instead of flooding the queue"
}

# 16. The cap is OFF by default, so it has to be inert when it is off. Nothing
# sweeps its markers at startup and nothing clears them while a window keeps
# rendering the identical frame, so a leftover from a run where the cap WAS
# configured is exactly the state an operator is in after turning the cap back
# off: both the window-scoped cap marker and the rollback-failure sentinel must
# be left unread while FM_WEDGE_MAX_ESCALATIONS is not above 0.
test_wedge_cap_off_ignores_leftover_markers() {
  local dir state out capture_file window key pane_hash sig marker sentinel
  dir=$(make_case wedge-cap-off-leftover); state="$dir/state"; capture_file="$dir/pane.txt"
  out="$dir/watch.out"
  window="test:fm-wedge-cap-off-leftover"
  printf 'idle wedged content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-off-leftover.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-off-leftover.status"
  sig=$(seen_sig "$state/wedge-cap-off-leftover.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-off-leftover_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle wedged content")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  marker="$state/.wedge-permanent-$key"
  sentinel="$state/.wedge-rollback-failed-$key"

  # A cap marker written by an earlier run while the cap was configured. The
  # window must escalate again on the first poll, and must escalate normally
  # rather than fire a ceiling that is not configured.
  date +%s > "$marker"
  poll_wedge_round "$dir" 0 "FM_WATCH_HANDLING_SUCCESSOR=1"
  grep -F "escalation 1" "$out" >/dev/null \
    || fail "a leftover cap marker silenced the window with the cap turned off: $(cat "$out")"
  grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null \
    && fail "the cap fired while FM_WEDGE_MAX_ESCALATIONS was off: $(cat "$out")"
  rm -f "$marker"

  # The rollback-failure sentinel next, which stands ahead of every other wedge
  # check. The counter has to keep climbing across both rounds, so this one has
  # to be escalation 2 - a round that read the sentinel would publish nothing.
  printf '%s rollback-failed\n' "$(date +%s)" > "$sentinel"
  poll_wedge_round "$dir" 0 "FM_WATCH_HANDLING_SUCCESSOR=1"
  grep -F "escalation 2" "$out" >/dev/null \
    || fail "a leftover rollback-failure sentinel silenced the window with the cap turned off: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null \
    || fail "the window left the ordinary wedge path with the cap turned off: $(cat "$out")"
  unset FM_FAKE_CREW_STATE
  pass "with the cap off, a leftover cap marker or rollback-failure sentinel silences nothing"
}

# The release boundary is a wedge EPISODE, so the first-sight routes have to
# honour it as strictly as the reset routes do: each ends the episode the cap
# fired in and opens a new one on the very next render, and a window left capped
# across that boundary would answer the crew's next genuine wedge with silence
# for the rest of FM_CAP_HORIZON_SECS. The routes driven here are the ones that
# need a crew-state verdict to pick between them - a captain-relevant status log
# outranked by a live run, that same log with nothing overriding it, a
# non-terminal pane absorbed because the crew is provably working, and the
# away-posture one-shot the supervise daemon owns. The reset
# routes are the ones the recovery and declared-wait cases drive: a pane that
# leaves the stale path, and a declared wait and its lift.
drive_first_sight_release() {  # <route>
  local route=$1 dir state fakebin out capture_file window key statusf
  local fire_verdict route_verdict mode pid fresh_hash away_record=0
  dir=$(make_case "wedge-cap-release-$route")
  state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedge-cap-release-$route"
  statusf="$state/wedge-cap-release-$route.status"
  case "$route" in
    away-first-sight)
      # The away-posture record makes the watcher hand the stale identity to the
      # supervise daemon, which owns the one-shot per hash: the surface is the
      # daemon handoff, and it takes no crew-state verdict at all.
      printf 'working: still wedged\n' > "$statusf"
      fire_verdict='state: working · source: run-step · validating (running)'
      route_verdict=$fire_verdict
      mode="exit"
      away_record=1
      ;;
    provably-working-terminal)
      printf 'done: implementation complete, ready to validate\n' > "$statusf"
      fire_verdict='state: working · source: run-step · validating (running)'
      route_verdict=$fire_verdict
      mode="absorb"
      ;;
    surface-terminal)
      printf 'done: implementation complete, ready to validate\n' > "$statusf"
      fire_verdict='state: working · source: run-step · validating (running)'
      route_verdict='state: unknown · source: none · no run, no busy pane'
      mode="exit"
      ;;
    provably-working-nonterminal)
      printf 'working: still wedged\n' > "$statusf"
      fire_verdict='state: working · source: run-step · validating (running)'
      route_verdict=$fire_verdict
      mode="absorb"
      ;;
    *) fail "unknown first-sight release route: $route" ;;
  esac
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-release-$route.meta"
  printf 'wedged render the cap fires on' > "$capture_file"
  mark_status_seen "$state" "$statusf"
  printf '%s' "$(hash_text 'wedged render the cap fires on')" > "$state/.hash-$key"
  printf '%s' "$(hash_text 'wedged render the cap fires on')" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"

  # Fire this window's cap against its live endpoint, so the marker under test
  # is one the watcher really wrote rather than one this case planted.
  export FM_FAKE_CREW_STATE="$fire_verdict"
  poll_capped_wedge_round "$dir" 1 "" exit \
    || fail "the $route case never reached the wedge path: $(cat "$out")"
  grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null \
    || fail "the $route case did not fire its cap: $(cat "$out")"
  [ -e "$state/.wedge-permanent-$key" ] \
    || fail "the $route case left no fired cap marker to release"

  # The first sight of the next render on a window whose episode the cap has just
  # ended. The watcher is told the fresh render is already its recorded hash so
  # this poll classifies it as stably stale, which is the population these
  # routes live in.
  fresh_hash=$(hash_text 'the render that ends the capped episode')
  printf 'the render that ends the capped episode' > "$capture_file"
  printf '%s' "$fresh_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE="$route_verdict"
  [ "$away_record" -eq 0 ] || date +%s > "$state/.afk"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=1 \
    "$WATCH" > "$out" &
  pid=$!
  if [ "$mode" = exit ]; then
    wait_for_exit "$pid" 150 \
      || { reap "$pid"; fail "the $route first-sight poll never settled: $(cat "$out")"; }
    grep -F "stale: $window" "$out" >/dev/null \
      || { reap "$pid"; fail "the $route first-sight poll did not surface the render: $(cat "$out")"; }
  else
    wait_poll_cycle "$state" "$pid" 200 \
      || { reap "$pid"; fail "the $route first-sight poll did not survive its cycle: $(cat "$out")"; }
  fi
  reap "$pid"
  rm -f "$state/.afk"
  ack_stopped_cycle "$state" || true
  [ ! -e "$state/.wedge-permanent-$key" ] \
    || fail "the $route first-sight route left the cap marker standing, so the next genuine wedge would answer with silence until the horizon"
  [ ! -e "$state/.wedge-terminal-queued-$key" ] \
    || fail "the $route first-sight route kept the terminal-wake episode marker, so the next episode's own terminal wake would be suppressed"

  # A later render the recovered crew then goes quiet on opens a fresh wedge
  # episode, and the wedge behind it has to reach the supervisor - exactly what a
  # cap left standing across the boundary would have swallowed.
  fresh_hash=$(hash_text 'the render the recovered crew goes quiet on')
  printf 'the render the recovered crew goes quiet on' > "$capture_file"
  printf '%s' "$fresh_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=1 \
    "$WATCH" > "$out" &
  pid=$!
  wait_poll_cycle "$state" "$pid" 200 \
    || { reap "$pid"; fail "the fresh episode after the $route route did not survive its cycle: $(cat "$out")"; }
  reap "$pid"
  ack_stopped_cycle "$state" || true
  [ -e "$state/.stale-since-$key" ] \
    || fail "the $route route left no fresh wedge episode for the recovered crew to wedge against: $(cat "$out")"
  poll_wedge_round "$dir" 2 ""
  grep -F "escalation 1" "$out" >/dev/null \
    || fail "the wedge behind the released $route cap stayed silent: $(cat "$out")"
  grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null \
    && fail "the wedge behind the released $route cap fired the cap again instead of escalating normally"
  unset FM_FAKE_CREW_STATE
}

test_wedge_cap_releases_on_every_first_sight_route() {
  drive_first_sight_release provably-working-terminal
  drive_first_sight_release surface-terminal
  drive_first_sight_release provably-working-nonterminal
  drive_first_sight_release away-first-sight
  pass "every first-sight route that ends a wedge episode releases that episode's cap and lets the next wedge escalate"
}

# The hot non-terminal first-sight surface is the one that ends the episode
# marker on every non-terminal stale poll, so it is the route whose episode the
# cap has to be released on most often. Drive that exact sequence and assert the
# fresh wedge escalates immediately.
test_wedge_cap_releases_after_nonterminal_stale_episode() {
  local dir state out capture_file window key pane_hash sig pid fakebin max n statusf
  dir=$(make_case wedge-cap-nonterminal-reset); state="$dir/state"; capture_file="$dir/pane.txt"
  out="$dir/watch.out"; fakebin="$dir/fakebin"
  window="test:fm-wedge-cap-nonterminal-reset"
  statusf="$state/wedge-cap-nonterminal-reset.status"
  printf 'idle wedged content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-nonterminal-reset.meta"
  printf 'working: still wedged\n' > "$statusf"
  mark_status_seen "$state" "$statusf"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle wedged content")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  prime_and_ack "$dir" 3 || fail "prime-and-ack failed"
  max=3
  n=1
  while [ "$n" -le "$max" ]; do
    poll_wedge_round "$dir" "$max" ""
    n=$((n + 1))
  done
  grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null || fail "cap round did not fire PERMANENTLY-WEDGED"
  [ -e "$state/.wedge-permanent-$key" ] || fail "window-scoped marker missing after cap fire"

  # Now a non-terminal stale poll on a FRESH hash. That takes the first-sight
  # branch into surface_nonterminal_stale, the hottest of the episode-ending
  # routes: it ends the wedge episode on every non-terminal stale poll, so a cap
  # left standing here would keep a genuinely re-wedged pane silent for the whole
  # horizon.
  # pause_state_class must NOT be working or paused here, or the poll takes the
  # provably-working absorb or the declared-wait branch instead of that surface.
  export FM_FAKE_CREW_STATE='state: idle · source: none'
  printf 'a different pane body entirely' > "$capture_file"
  rm -f "$state/.stale-$key" "$state/.wedge-escalations-$key"
  printf '%s' "$(hash_text "a different pane body entirely")" > "$state/.hash-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max \
    "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 200 || fail "non-terminal reset poll did not settle: $(cat "$out")"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "non-terminal reset ack failed"

  [ ! -e "$state/.wedge-permanent-$key" ] \
    || fail "a non-terminal stale poll ended the wedge episode but left the cap marker standing; a genuine new wedge would stay silent for the whole horizon"

  # And the fresh wedge must escalate immediately rather than sit silenced.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  n=1
  while [ "$n" -le "$max" ]; do
    poll_wedge_round "$dir" "$max" ""
    grep -F "escalation $n" "$out" >/dev/null \
      || fail "the fresh wedge after a non-terminal reset did not reach escalation $n: $(cat "$out")"
    n=$((n + 1))
  done
  unset FM_FAKE_CREW_STATE
  pass "a non-terminal stale poll ends the episode, releases the cap, and lets the fresh wedge escalate immediately"
}

test_wedge_cap_disabled_by_default
test_wedge_cap_fires_permanently_wedged_at_threshold
test_wedge_cap_silences_subsequent_polls_for_same_hash
test_wedge_cap_window_marker_silences_hash_churning_busy_pane
test_wedge_cap_expires_after_horizon
test_wedge_cap_operator_can_rm_marker
test_wedge_cap_validates_invalid_overrides
test_wedge_cap_reads_an_unreadable_counter_as_a_fresh_one
test_wedge_cap_rollback_writes_sentinel_on_marker_failure
test_wedge_cap_unwritable_escalation_count_fails_safe
test_wedge_cap_sentinel_probe_keeps_its_cadence
test_wedge_cap_releases_after_genuine_recovery
test_wedge_cap_publishes_one_terminal_wake_under_persistent_marker_failure
test_wedge_cap_releases_after_declared_wait
test_wedge_cap_reports_gone_endpoint_while_capped
test_wedge_cap_new_episode_publishes_its_own_terminal_wake
test_wedge_cap_probe_keeps_its_cadence_while_capped
test_wedge_cap_unwritable_terminal_marker_does_not_flood
test_wedge_cap_releases_on_every_first_sight_route
test_wedge_cap_releases_after_nonterminal_stale_episode
test_wedge_cap_off_ignores_leftover_markers

# The dead-record guarantee has to hold on the one wedge route that reaches the
# ladder through a GATE. The terminal-status route is entered on a repeated hash
# only while a wedge timer is running for it, and a fired cap ends the episode by
# dropping exactly that timer while keeping the window silent - so the gate alone
# left this hash with no ladder at all, and an agent that then exited behind a
# byte-identical frame was never reported for the rest of the horizon. Drive the
# cap on THIS route: a captain-relevant status log the crew state overrides, then
# the endpoint gone under the marker the cap left behind and with no idle timer
# re-armed for it, which is what that window looks like for the whole horizon.
test_wedge_cap_reports_gone_endpoint_on_terminal_override_route() {
  local dir state out capture_file window key pane_hash pid fakebin max statusf round
  dir=$(make_case wedge-cap-terminal-override); state="$dir/state"; capture_file="$dir/pane.txt"
  out="$dir/watch.out"; fakebin="$dir/fakebin"
  window="test:fm-wedge-cap-terminal-override"
  statusf="$state/wedge-cap-terminal-override.status"
  printf 'idle wedged content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-terminal-override.meta"
  # Captain-relevant status line, seen, so the pane is the terminal-status
  # population: the classification the overriding crew state has to beat.
  printf 'done: implementation complete, ready to validate\n' > "$statusf"
  mark_status_seen "$state" "$statusf"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle wedged content")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  max=1
  prime_and_ack "$dir" "$max" || fail "prime-and-ack failed"

  # The crew is provably working, so this hash is absorbed as an overridden
  # terminal status with its wedge timer running, and the cap fires there.
  poll_capped_wedge_round "$dir" "$max" "" exit \
    || fail "the terminal-override route never reached its cap: $(cat "$out")"
  grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null \
    || fail "the terminal-override route did not fire PERMANENTLY-WEDGED: $(cat "$out")"
  [ -e "$state/.wedge-permanent-$key" ] \
    || fail "no fired cap marker is standing to hold this window silent"
  [ ! -e "$state/.stale-since-$key" ] \
    || fail "the fired cap did not end the wedge episode it silenced"

  # The agent now exits while its pane keeps rendering the identical frame. No
  # route re-arms the idle timer for that, so this poll plants none: the window
  # has to get back to the dead-record probe by itself, through the marker the
  # cap left standing, or the agent that just left is never reported. The
  # escalation bound is short so the ladder's own re-armed timer reaches the
  # probe within this one watcher's lifetime.
  : > "$out"
  env FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=bash FM_FAKE_TMUX_WINDOWS=someone-elses-window \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_STALE_ESCALATE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max \
    PATH="$fakebin:$PATH" \
    "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 300 \
    || { reap "$pid"; fail "the capped terminal-override window never reported its gone endpoint: $(cat "$out")"; }
  grep -F "agent missing" "$out" >/dev/null \
    || fail "the capped terminal-override window did not report the gone endpoint: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null \
    && fail "the gone endpoint was escalated as a wedge instead of reported: $(cat "$out")"
  [ "$(queued_wakes_carrying "$state" "$window" "agent missing")" -eq 1 ] \
    || fail "the capped terminal-override window did not queue exactly one gone-endpoint report"

  # The window stays on the ladder's own cadence after that: the death is
  # delivered once, not once per poll, and no terminal wake is re-published.
  : > "$out"
  env FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=bash FM_FAKE_TMUX_WINDOWS=someone-elses-window \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_STALE_ESCALATE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max \
    PATH="$fakebin:$PATH" \
    "$WATCH" > "$out" &
  pid=$!
  round=1
  while [ "$round" -le 2 ]; do
    wait_poll_cycle "$state" "$pid" 300 \
      || { reap "$pid"; fail "capped poll $round surfaced a wake: $(cat "$out")"; }
    round=$((round + 1))
  done
  reap "$pid"
  [ "$(queued_wakes_carrying "$state" "$window" "agent missing")" -eq 1 ] \
    || fail "the capped terminal-override window repeated the gone-endpoint report"
  grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null \
    && fail "a capped poll on the terminal-override route re-fired the terminal wake"
  unset FM_FAKE_CREW_STATE
  pass "a cap fired on the terminal-override route still reports a gone endpoint exactly once"
}

test_wedge_cap_reports_gone_endpoint_on_terminal_override_route
