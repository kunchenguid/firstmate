#!/usr/bin/env bash
# tests/fm-watch-wedge-cap.test.sh - bounded wedge escalations for one
# worker window. Disabled by default; FM_WEDGE_MAX_ESCALATIONS=N caps the
# per-window escalation count to N consecutive stale-hash wedges before a
# single PERMANENTLY-WEDGED wake, with both STATE/.wedge-permanent-<key>
# (window-scoped) and STATE/.wedge-permanent-<key>-<hash12> (per-hash)
# markers silencing the wedge path for FM_CAP_HORIZON_SECS.
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
    [ ! -e "$state/.wedge-permanent-$key-${pane_hash:0:12}" ] || fail "default-config wrote the per-hash cap marker"
    ack_stopped_cycle "$state" || fail "default-config round $n ack failed"
    n=$((n + 1))
  done
  unset FM_FAKE_CREW_STATE
  pass "FM_WEDGE_MAX_ESCALATIONS=0 keeps the cap inert and never writes a cap marker"
}

# 2. Cap fires at threshold with PERMANENTLY-WEDGED and writes BOTH the
# per-hash and window-scoped markers.
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
  [ -e "$state/.wedge-permanent-$key-${pane_hash:0:12}" ] || fail "per-hash marker missing after cap fired"
  [ -e "$state/.wedge-permanent-$key" ] || fail "window-scoped marker missing after cap fired"
  unset FM_FAKE_CREW_STATE
  pass "wedge cap fires PERMANENTLY-WEDGED at FM_WEDGE_MAX_ESCALATIONS and writes both markers"
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
    # A post-cap poll short-circuits inside wedge_timer_check on the per-hash
    # marker and returns 0 without waking; the watcher keeps polling until
    # the next event. wait_poll_cycle confirms it is alive AND did not fire.
    if wait_poll_cycle "$state" "$pid" 200 2>/dev/null; then
      :
    fi
    reap "$pid"
    ack_stopped_cycle "$state" || true
    grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null && fail "post-cap poll $i re-fired PERMANENTLY-WEDGED"
  done
  unset FM_FAKE_CREW_STATE
  pass "subsequent polls on the same hash stay silent while the per-hash cap marker stands"
}

# 4. The window-scoped marker silences a hash-churning pane that
# re-renders on every poll. The pane must receive at most ONE
# PERMANENTLY-WEDGED wake across all churn iterations, even when each poll
# presents a brand new stale hash that escapes the per-hash marker scheme.
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
  [ -e "$state/.wedge-permanent-$key-${pane_hash:0:12}" ] || fail "per-hash cap marker missing after churn cap"
  local total_terminal i
  total_terminal=0
  i=0
  while [ "$i" -lt 12 ]; do
    i=$((i + 1))
    printf 'churning wedged pane iteration %d fresh content' "$i" > "$capture_file"
    # New hash on every poll: replace .hash-<key> so the matcher reads a
    # fresh hash each time and would normally re-fire the cap through the
    # per-hash branch. The window-scoped marker is what stops the loop.
    printf '%s' "$(hash_text "churning wedged pane iteration $i fresh content")" > "$state/.hash-$key"
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    # Reset the absorbed hash so the matcher sees each fresh hash as a new
    # arrival (the provably-working absorbed path).
    rm -f "$state/.stale-$key"
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
  # Reset the absorbed hash so the matcher treats the new hash as a fresh
  # arrival and reaches wedge_timer_check.
  rm -f "$state/.stale-$key"
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

  # Now age both cap markers past the horizon (cap=2s) and leave the pane
  # exactly as it was, so the only thing that changed is the marker age. The
  # escalation counter is pre-seeded one below the cap, so the very next poll
  # must drive the wedge to PERMANENTLY-WEDGED - proving the horizon released
  # the cap rather than an operator having removed the markers.
  cap_ts=$(( $(date +%s) - 5 ))
  printf '%s' "$cap_ts" > "$state/.wedge-permanent-$key"
  printf '%s' "$cap_ts" > "$state/.wedge-permanent-$key-${pane_hash:0:12}"
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

# 6. Operator can rm BOTH markers for immediate re-engagement; a fresh
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

  rm -f "$state/.wedge-permanent-$key" "$state/.wedge-permanent-$key-${pane_hash:0:12}"
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
  pass "operator rm of both markers lifts the cap and the next wedge re-accumulates from 1"
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

# 8. The cap-fire path is durable: rolling back on a marker-write failure
# restores the escalation counter and stale timer, and a rollback failure
# itself writes a transient sentinel that silences the wedge for
# FM_ROLLBACK_SENTINEL_TTL_SECS.
test_wedge_cap_rollback_writes_sentinel_on_marker_failure() {
  local dir state out capture_file window key pane_hash sig pid n max marker_hash marker_window sentinel
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
  marker_hash="$state/.wedge-permanent-$key-${pane_hash:0:12}"
  marker_window="$state/.wedge-permanent-$key"
  sentinel="$state/.wedge-rollback-failed-$key"

  # Two planted write failures in one poll: the window-scoped marker path is a
  # non-empty directory (so its write fails after the per-hash marker landed),
  # and the escalation-counter path is a directory (so the rollback's own
  # counter reset fails too). A failed rollback must leave a sentinel rather
  # than silently preserving the saturated counter, which would re-fire the
  # wedge on every poll - the wake-queue flood this bounds.
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
  set +e
  wait_for_exit "$pid" 100
  round_status=$?
  set -e
  [ "$round_status" -eq 1 ] || fail "cap-fire round expected exit 1 on the failed marker write, got $round_status: $(cat "$out")"
  [ ! -e "$marker_hash" ] || fail "per-hash marker was left behind after the window-scoped marker write failed"
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
  pass "the rollback-failed sentinel silences the wedge path within FM_ROLLBACK_SENTINEL_TTL_SECS"
}

test_wedge_cap_disabled_by_default
test_wedge_cap_fires_permanently_wedged_at_threshold
test_wedge_cap_silences_subsequent_polls_for_same_hash
test_wedge_cap_window_marker_silences_hash_churning_busy_pane
test_wedge_cap_expires_after_horizon
test_wedge_cap_operator_can_rm_marker
test_wedge_cap_validates_invalid_overrides
test_wedge_cap_rollback_writes_sentinel_on_marker_failure
