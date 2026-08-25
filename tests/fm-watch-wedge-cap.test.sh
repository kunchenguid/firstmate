#!/usr/bin/env bash
# tests/fm-watch-wedge-cap.test.sh - focused unit tests for the
# FM_WEDGE_MAX_ESCALATIONS cap (local patch 2026-08-19, v6). Verifies:
#   1. cap fires PERMANENTLY-WEDGED at the threshold and writes the
#      per-(window, hash) marker;
#   2. subsequent polls for the same hash are silent (no extra wakes);
#   3. the cap persists across pause-class transitions (paused: then
#      lifted) - Greptile R4 fix;
#   4. the cap lifts on unambiguous recovery (new hash + active pipeline)
#      - Greptile R5 fix;
#   5. invalid override values (0, non-integer) fall back to the default.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
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

# --- FM_WEDGE_MAX_ESCALATIONS cap (local patch 2026-08-19, v6) ----------------
# The cap is a hard floor on the LLM-supervised unattended loop that the 2026-
# 08-18 MiniMax drain (~359M tokens) demonstrated. Past FM_WEDGE_MAX_ESCALATIONS
# consecutive wedge escalations on the SAME stale hash, the watcher emits ONE
# terminal wake with PERMANENTLY-WEDGED and writes a STATE/.wedge-permanent-
# <key>-<hash12> marker. Subsequent polls for that hash short-circuit. The cap
# lifts on unambiguous recovery (pause_state_class=working for the window).

test_wedge_cap_fires_permanently_wedged_after_max_escalations() {
  local dir state fakebin out capture_file window key pane_hash sig pid n max
  dir=$(make_case wedge-cap-fires); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedge-cap"
  printf 'idle wedged content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap.status"
  sig=$(seen_sig "$state/wedge-cap.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle wedged content")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  max=4
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Priming round: pre-seeded .hash and .count mean one wait_poll_cycle
  # reaches the wedge path (n=2 from the count pre-seed + increment).
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited on the priming round (should absorb): $(cat "$out")"
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the priming stop"

  # Drive past the cap (max=4). Rounds 1..3 are normal escalations; round 4 fires PERMANENTLY-WEDGED.
  n=1
  while [ "$n" -le "$max" ]; do
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" &
    pid=$!
    if ! wait_for_exit "$pid" 100; then
      reap "$pid"; fail "watcher did not exit on wedge round $n: $(cat "$out")"
    fi
    grep -F "escalation $n" "$out" >/dev/null || fail "round $n did not report escalation count $n: $(cat "$out")"
    if [ "$n" -lt "$max" ]; then
      grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null && fail "round $n fired PERMANENTLY-WEDGED before the cap"
    else
      grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null || fail "round $max (cap) did not produce PERMANENTLY-WEDGED: $(cat "$out")"
    fi
    ack_stopped_cycle "$state" || fail "could not acknowledge wedge round $n"
    n=$((n + 1))
  done

  # The per-(window, hash) marker must be set.
  [ -e "$state/.wedge-permanent-$key-${pane_hash:0:12}" ] || fail "cap marker .wedge-permanent-<key>-<hash12> was not written after the cap fired"
  unset FM_FAKE_CREW_STATE
  pass "wedge cap fires PERMANENTLY-WEDGED at FM_WEDGE_MAX_ESCALATIONS and writes the per-hash marker"
}

test_wedge_cap_suppresses_subsequent_polls_for_same_hash() {
  local dir state fakebin out capture_file window key pane_hash sig pid n max
  dir=$(make_case wedge-cap-suppress); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedge-cap-suppress"
  printf 'idle wedged content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-suppress.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-suppress.status"
  sig=$(seen_sig "$state/wedge-cap-suppress.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-suppress_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle wedged content")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  max=3
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Priming + cap-firing rounds, condensed.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" &
  pid=$!
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "priming watch failed"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "priming ack failed"

  n=1
  while [ "$n" -le "$max" ]; do
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" &
    pid=$!
    wait_for_exit "$pid" 100 || { reap "$pid"; fail "round $n watch failed"; }
    ack_stopped_cycle "$state" || fail "round $n ack failed"
    n=$((n + 1))
  done

  # Cap marker must exist after the cap fired.
  [ -e "$state/.wedge-permanent-$key-${pane_hash:0:12}" ] || fail "cap marker missing before the suppression check"

  # Now run a fresh watcher poll: pane is still wedged (same content, worker
  # still NOT genuinely recovered - FM_FAKE_CREW_STATE=paused, so v7 site 3 does
  # NOT lift the marker). The wedge_timer_check early-return path should fire.
  # No wake should be queued.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  # Worker is genuinely still wedged (paused state, not working) - this is an
  # operator wait or stuck wedge, not a recovery. The cap must hold.
  FM_FAKE_CREW_STATE='state: paused · source: run-step · waiting on external release' \
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited when the cap should have suppressed (the marker exists, watcher should have absorbed): $(cat "$out")"
  fi
  reap "$pid"
  # The drain output must NOT contain a stale wake for this window - the cap
  # short-circuited before fm_wake_append was reached.
  drain_out="$dir/drain-after-suppress.out"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || true
  if grep "$(printf '\tstale\t')" "$drain_out" 2>/dev/null | grep -F "$window" >/dev/null; then
    fail "capped hash still produced a stale wake after the cap fired: $(cat "$drain_out")"
  fi
  unset FM_FAKE_CREW_STATE
  pass "subsequent polls for the capped hash are silent - no additional terminal wakes fire"
}

test_wedge_cap_persists_across_pause_class_transitions() {
  local dir state fakebin out capture_file window key pane_hash sig pid max
  dir=$(make_case wedge-cap-pause); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedge-cap-pause"
  printf 'idle wedged content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-pause.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-pause.status"
  sig=$(seen_sig "$state/wedge-cap-pause.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-pause_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle wedged content")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  max=3
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Drive to cap.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" &
  pid=$!
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "priming watch failed"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "priming ack failed"
  n=1
  while [ "$n" -le "$max" ]; do
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" &
    pid=$!
    wait_for_exit "$pid" 100 || { reap "$pid"; fail "round $n watch failed"; }
    ack_stopped_cycle "$state" || fail "round $n ack failed"
    n=$((n + 1))
  done
  [ -e "$state/.wedge-permanent-$key-${pane_hash:0:12}" ] || fail "cap marker missing before pause-cycle test"

  # Operator declares paused: - but the worker is NOT actually working
  # (FM_FAKE_CREW_STATE=paused), so this is an operator wait, not a recovery.
  # pause_state_class returns "paused" (not "working"), so the v6 lift sites
  # do NOT fire. The cap marker MUST persist (Greptile R4 fix).
  printf 'paused: waiting on a human\n' > "$state/wedge-cap-pause.status"
  sig=$(seen_sig "$state/wedge-cap-pause.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-pause_status"
  printf 'idle wedged content' > "$capture_file"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  # Worker is genuinely paused (not working) - this is an operator wait, not recovery.
  FM_FAKE_CREW_STATE='state: paused · source: run-step · waiting on external release' \
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" &
  pid=$!
  # In idle (no-actionable-wake) mode the watcher stays alive in its poll loop
  # and the cap suppresses any escalation; a startup rearm-resurface check wake
  # may or may not fire depending on the downtime-marker state from prior
  # rounds. Wait for two distinct beat mtimes (one full poll cycle) to confirm
  # the watcher has scanned the pane, then reap. Either way, the wedge_timer_check
  # early-return on the cap marker means no stale wake is queued.
  if ! wait_poll_cycle "$state" "$pid"; then
    # Watcher may have exited via rearm-resurface check; drain and continue.
    wait "$pid" 2>/dev/null || true
    ack_stopped_cycle "$state" || true
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || true
  [ -e "$state/.wedge-permanent-$key-${pane_hash:0:12}" ] || fail "cap marker was cleared after a paused: declaration with non-working crew (Greptile R4 regression)"

  # Operator lifts the pause, but the worker still isn't working - status returns
  # to "working:" verb but FM_FAKE_CREW_STATE stays "paused" so pause_state_class
  # returns "paused" (the status verb matches but the authoritative state says
  # still waiting). Marker MUST persist.
  printf 'working: back online\n' > "$state/wedge-cap-pause.status"
  sig=$(seen_sig "$state/wedge-cap-pause.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-pause_status"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  FM_FAKE_CREW_STATE='state: paused · source: run-step · waiting on external release' \
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    wait "$pid" 2>/dev/null || true
    ack_stopped_cycle "$state" || true
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || true
  [ -e "$state/.wedge-permanent-$key-${pane_hash:0:12}" ] || fail "cap marker was cleared after the pause was lifted without an active pipeline (Greptile R4 regression)"
  unset FM_FAKE_CREW_STATE
  pass "the cap marker persists across pause: and unpause transitions when the worker is not actively recovered"
}

test_wedge_cap_lifts_on_same_hash_recovery() {
  local dir state fakebin out capture_file window key pane_hash sig pid max
  dir=$(make_case wedge-cap-lift-same); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedge-cap-lift-same"
  printf 'idle wedged content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-lift-same.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-lift-same.status"
  sig=$(seen_sig "$state/wedge-cap-lift-same.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-lift-same_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle wedged content")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  max=3
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Drive to cap.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" &
  pid=$!
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "priming watch failed"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "priming ack failed"
  n=1
  while [ "$n" -le "$max" ]; do
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" &
    pid=$!
    wait_for_exit "$pid" 100 || { reap "$pid"; fail "round $n watch failed"; }
    ack_stopped_cycle "$state" || fail "round $n ack failed"
    n=$((n + 1))
  done
  [ -e "$state/.wedge-permanent-$key-${pane_hash:0:12}" ] || fail "cap marker missing before same-hash recovery test"

  # Operator declared paused: earlier; the .paused-$key marker is in place.
  # The crew's authoritative state now says working (the worker recovered
  # during the declared wait), so pause_state_class returns "working" while
  # the status verb is still "paused:" - the unambiguous recovery signal.
  # This is v6 site 2: same hash + was-paused + working -> lift the cap.
  : > "$state/.paused-$key"
  printf 'paused: waiting on a human\n' > "$state/wedge-cap-lift-same.status"
  sig=$(seen_sig "$state/wedge-cap-lift-same.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-lift-same_status"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    wait "$pid" 2>/dev/null || true
    ack_stopped_cycle "$state" || true
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || true
  [ ! -e "$state/.wedge-permanent-$key-${pane_hash:0:12}" ] || fail "cap marker was NOT lifted on same-hash recovery with active pipeline (v6 site 2 failed)"
  unset FM_FAKE_CREW_STATE
  pass "the cap marker is lifted when the same hash resumes with an active pipeline (v6 site 2)"
}

test_wedge_cap_lifts_on_unambiguous_recovery() {
  local dir state fakebin out capture_file window key pane_hash_old pane_hash_new sig pid max
  dir=$(make_case wedge-cap-lift); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedge-cap-lift"
  printf 'idle wedged content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-lift.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-lift.status"
  sig=$(seen_sig "$state/wedge-cap-lift.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-lift_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash_old=$(hash_text "idle wedged content")
  printf '%s' "$pane_hash_old" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  max=3
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Drive to cap on the OLD hash.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" &
  pid=$!
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "priming watch failed"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "priming ack failed"
  n=1
  while [ "$n" -le "$max" ]; do
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" &
    pid=$!
    wait_for_exit "$pid" 100 || { reap "$pid"; fail "round $n watch failed"; }
    ack_stopped_cycle "$state" || fail "round $n ack failed"
    n=$((n + 1))
  done
  [ -e "$state/.wedge-permanent-$key-${pane_hash_old:0:12}" ] || fail "cap marker missing before recovery test"

  # The pane becomes active (different content). The v6 site 1 lift happens when
  # the new hash is FIRST detected as stale by wedge_timer_check's
  # new-stale-detection branch (n=2 consecutive polls of the new hash, then
  # .stale-$key is the OLD hash, h is the NEW hash -> v6 site 1 fires).
  printf 'crew is alive and producing output' > "$capture_file"
  pane_hash_new=$(hash_text "crew is alive and producing output")
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" &
  pid=$!
  # Wait up to ~15s for the lift: hash change -> poll 1 (different hash, count=0),
  # poll 2 (count=1), poll 3 (count=2, wedge path entered, v6 site 1 fires).
  i=0
  while [ "$i" -lt 150 ]; do
    if [ ! -e "$state/.wedge-permanent-$key-${pane_hash_old:0:12}" ]; then
      break
    fi
    is_live_non_zombie "$pid" || break
    sleep 0.1
    i=$((i + 1))
  done
  if is_live_non_zombie "$pid"; then
    kill "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
  ack_stopped_cycle "$state" || true
  [ ! -e "$state/.wedge-permanent-$key-${pane_hash_old:0:12}" ] || fail "cap marker for the old hash was NOT lifted on unambiguous recovery (v6 site 1 failed)"
  unset FM_FAKE_CREW_STATE
  pass "the cap marker is lifted when a new hash is detected with an active pipeline"
}

test_wedge_cap_validates_invalid_override() {
  local dir state fakebin out capture_file window key sig pid
  dir=$(make_case wedge-cap-validate); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedge-cap-validate"
  printf 'idle wedged content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-validate.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-validate.status"
  sig=$(seen_sig "$state/wedge-cap-validate.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-validate_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text "idle wedged content")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Run with FM_WEDGE_MAX_ESCALATIONS=0 - would fire on first escalation if
  # not validated. The watcher should fall back to the default (10), log a
  # warning, and NOT fire the cap prematurely.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=0 "$WATCH" > "$out" &
  pid=$!
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "watcher with FM_WEDGE_MAX_ESCALATIONS=0 failed"; }
  reap "$pid"
  ack_stopped_cycle "$state" || true
  grep -F "FM_WEDGE_MAX_ESCALATIONS=0" "$state/.watch-triage.log" 2>/dev/null >/dev/null || fail "validation warning not logged for FM_WEDGE_MAX_ESCALATIONS=0"
  grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null && fail "FM_WEDGE_MAX_ESCALATIONS=0 fired PERMANENTLY-WEDGED on first escalation (validation did not catch it)"

  # Run with FM_WEDGE_MAX_ESCALATIONS=abc - non-integer. Default should be used.
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=abc "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    wait_for_exit "$pid" 100 || true
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || true
  grep -F "FM_WEDGE_MAX_ESCALATIONS='abc'" "$state/.watch-triage.log" 2>/dev/null >/dev/null || fail "validation warning not logged for FM_WEDGE_MAX_ESCALATIONS=abc"
  unset FM_FAKE_CREW_STATE
  pass "FM_WEDGE_MAX_ESCALATIONS rejects 0 and non-integer values, falling back to default 10"
}

test_wedge_cap_lifts_on_same_hash_worker_active_without_pause() {
  local dir state fakebin out capture_file window key pane_hash sig pid max
  dir=$(make_case wedge-cap-lift-no-pause); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedge-cap-lift-no-pause"
  printf 'idle wedged content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-lift-no-pause.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-lift-no-pause.status"
  sig=$(seen_sig "$state/wedge-cap-lift-no-pause.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-lift-no-pause_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle wedged content")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  max=3
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Drive to cap.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" &
  pid=$!
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "priming watch failed"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "priming ack failed"
  n=1
  while [ "$n" -le "$max" ]; do
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" &
    pid=$!
    wait_for_exit "$pid" 100 || { reap "$pid"; fail "round $n watch failed"; }
    ack_stopped_cycle "$state" || fail "round $n ack failed"
    n=$((n + 1))
  done
  [ -e "$state/.wedge-permanent-$key-${pane_hash:0:12}" ] || fail "cap marker missing before same-hash-worker-active test"

  # Greptile R6 case. The pane hash is unchanged AND status is "working:" (no
  # declared pause) AND FM_FAKE_CREW_STATE says working - this is the v7 site 3
  # lift: same-hash recovery WITHOUT a declared pause. The wedge was a
  # misdetection or has been resolved; the marker MUST lift.
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" &
  pid=$!
  # Site 3 fires on a wedge_timer_check call (same hash, count>=2, busy_now=1)
  # - wait for the marker to be lifted (counter-reset not required, the cap
  # will re-fire on next wedge_timer_check call after the lift).
  i=0
  while [ "$i" -lt 150 ]; do
    if [ ! -e "$state/.wedge-permanent-$key-${pane_hash:0:12}" ]; then
      break
    fi
    is_live_non_zombie "$pid" || break
    sleep 0.1
    i=$((i + 1))
  done
  if is_live_non_zombie "$pid"; then
    kill "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
  ack_stopped_cycle "$state" || true
  [ ! -e "$state/.wedge-permanent-$key-${pane_hash:0:12}" ] || fail "cap marker was NOT lifted on same-hash worker-active recovery without a declared pause (v7 site 3 failed)"
  unset FM_FAKE_CREW_STATE
  pass "the cap marker is lifted when the same hash resumes with an active pipeline outside a declared pause (v7 site 3)"
}

test_wedge_cap_fires_permanently_wedged_after_max_escalations
test_wedge_cap_suppresses_subsequent_polls_for_same_hash
test_wedge_cap_persists_across_pause_class_transitions
test_wedge_cap_lifts_on_unambiguous_recovery
test_wedge_cap_lifts_on_same_hash_recovery
test_wedge_cap_lifts_on_same_hash_worker_active_without_pause
test_wedge_cap_validates_invalid_override