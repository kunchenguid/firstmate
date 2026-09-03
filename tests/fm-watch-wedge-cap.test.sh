#!/usr/bin/env bash
# tests/fm-watch-wedge-cap.test.sh - focused unit tests for the
# FM_WEDGE_MAX_ESCALATIONS cap (local patch 2026-08-19, v6). Verifies:
#   1. cap fires PERMANENTLY-WEDGED at the threshold and writes the
#      per-(window, hash) marker;
#   2. subsequent polls for the same hash are silent (no extra wakes);
#   3. the cap persists across pause-class transitions (paused: then
#      lifted) - Greptile R4 fix;
#   4. the cap is bound by FM_CAP_HORIZON_SECS (re-fires after the
#      horizon elapses) - Greptile R8 fix (v9 design, hash-keyed cap
#      and horizon-bounded are the two exit conditions; the third is
#      operator rm);
#   5. invalid override values (0, non-integer) fall back to the default
#      for FM_WEDGE_MAX_ESCALATIONS and FM_CAP_HORIZON_SECS.
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
# consecutive wedge escalations on the SAME (window, hash), the watcher emits ONE
# terminal wake with PERMANENTLY-WEDGED and writes a STATE/.wedge-permanent-
# <key>-<hash12> marker (the timestamp is the cap-fire epoch). Three exit
# conditions: FM_CAP_HORIZON_SECS elapses since that timestamp (default 24h);
# the pane hash changes (different marker key naturally invalidates the cap);
# the operator manually removes the marker. No auto-lift on
# pause_state_class=working (the v6/v7 lift sites were removed in v9 because
# pause_state_class=working can be a steady state during a wedge, not a recovery
# signal).

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

# v9: cap is bound by FM_CAP_HORIZON_SECS, NOT by pause_state_class=working lift sites.
# A new hash invalidates the marker naturally (keyed on hash); operator can `rm`
# manually for immediate re-engagement. See tests below for the new semantics.

test_wedge_cap_expires_after_horizon() {
  local dir state fakebin out capture_file window key pane_hash sig pid max marker
  dir=$(make_case wedge-cap-horizon); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedge-cap-horizon"
  printf 'idle wedged content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-horizon.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-horizon.status"
  sig=$(seen_sig "$state/wedge-cap-horizon.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-horizon_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle wedged content")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  max=3
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  marker="$state/.wedge-permanent-$key-${pane_hash:0:12}"

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
  [ -e "$marker" ] || fail "cap marker missing before horizon test"

  # Backdate the marker so it appears older than FM_CAP_HORIZON_SECS. The cap
  # is now stale; the next wedge_timer_check call should re-fire the cap.
  old_ts=$(( $(date +%s) - 90000 ))
  printf '%s\n' "$old_ts" > "$marker"
  # Backdate .stale-since so wedge_timer_check sees the wedge is old enough
  # to escalate (otherwise the empty-since branch resets the timer and the
  # counter never increments toward the cap).
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"

  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max FM_CAP_HORIZON_SECS=86400 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "watcher did not re-fire the cap after horizon"; }
  grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null || fail "watcher did not emit PERMANENTLY-WEDGED after cap horizon"
  ack_stopped_cycle "$state" || true
  unset FM_FAKE_CREW_STATE
  pass "the cap is bound by FM_CAP_HORIZON_SECS and re-fires after the horizon elapses"
}

test_wedge_cap_holds_within_horizon() {
  local dir state fakebin out capture_file window key pane_hash sig pid max marker
  dir=$(make_case wedge-cap-horizon-holds); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedge-cap-horizon-holds"
  printf 'idle wedged content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-horizon-holds.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-horizon-holds.status"
  sig=$(seen_sig "$state/wedge-cap-horizon-holds.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-horizon-holds_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle wedged content")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  max=3
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  marker="$state/.wedge-permanent-$key-${pane_hash:0:12}"

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
  [ -e "$marker" ] || fail "cap marker missing before horizon-holds test"

  # Marker is at the cap-fire timestamp (recent, well within horizon). The cap
  # MUST hold - subsequent wedge_timer_check calls must NOT re-fire the cap.
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max FM_CAP_HORIZON_SECS=86400 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    wait "$pid" 2>/dev/null || true
    ack_stopped_cycle "$state" || true
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || true
  # Drain must NOT contain a stale wake for this window.
  drain_out="$dir/drain.out"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || true
  if grep "$(printf '\tstale\t')" "$drain_out" 2>/dev/null | grep -F "$window" >/dev/null; then
    fail "cap re-fired within horizon (drain contains stale wake): $(cat "$drain_out")"
  fi
  unset FM_FAKE_CREW_STATE
  pass "the cap is honored within FM_CAP_HORIZON_SECS - no additional terminal wakes fire"
}

test_wedge_cap_hash_change_invalidates_marker() {
  local dir state fakebin out capture_file window key pane_hash_old pane_hash_new sig pid max marker
  dir=$(make_case wedge-cap-hash-change); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedge-cap-hash-change"
  printf 'idle wedged content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-hash-change.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-hash-change.status"
  sig=$(seen_sig "$state/wedge-cap-hash-change.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-hash-change_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash_old=$(hash_text "idle wedged content")
  printf '%s' "$pane_hash_old" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  max=3
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  marker="$state/.wedge-permanent-$key-${pane_hash_old:0:12}"

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
  [ -e "$marker" ] || fail "cap marker missing before hash-change test"

  # Pane content changes (worker produces new output). The cap marker is
  # keyed on the OLD hash; the new wedge is on the NEW hash, so the marker
  # is naturally stale and the new hash can fire escalations and its own
  # cap when it climbs to FM_WEDGE_MAX_ESCALATIONS. Verify by running the
  # watcher until it exits (the new-hash wedge fires some wake) and drain
  # shows a stale wake for this window - proving the OLD marker did NOT
  # suppress the NEW hash.
  pane_hash_new=$(hash_text "crew is alive and producing output")
  printf '%s' "$pane_hash_new" > "$capture_file"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "new-hash watch did not exit (old marker may be suppressing new hash)"; }
  # The new-hash wedge fired SOME wake. Verify the queue has a stale wake
  # for this window.
  drain_out="$dir/drain.out"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || true
  if ! grep "$(printf '\tstale\t')" "$drain_out" 2>/dev/null | grep -F "$window" >/dev/null; then
    fail "new-hash wedge was suppressed by the old marker (no stale wake in queue): $(cat "$drain_out")"
  fi
  ack_stopped_cycle "$state" || true
  unset FM_FAKE_CREW_STATE
  pass "the cap marker is keyed on (window, hash) and a new hash naturally invalidates it"
}

test_wedge_cap_operator_can_rm_marker() {
  local dir state fakebin out capture_file window key pane_hash sig pid max marker
  dir=$(make_case wedge-cap-operator-rm); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedge-cap-operator-rm"
  printf 'idle wedged content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-operator-rm.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-operator-rm.status"
  sig=$(seen_sig "$state/wedge-cap-operator-rm.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-operator-rm_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle wedged content")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  max=3
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  marker="$state/.wedge-permanent-$key-${pane_hash:0:12}"

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
  [ -e "$marker" ] || fail "cap marker missing before operator-rm test"

  # Operator manually removes the marker (immediate re-engagement, bypassing
  # the horizon). The next wedge_timer_check call should re-fire the cap.
  rm -f "$marker"

  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" &
  pid=$!
  # The counter is at FM_WEDGE_MAX_ESCALATIONS (=max=3); with the marker gone,
  # the next wedge_timer_check call increments to max+1 and re-fires the cap
  # once FM_STALE_ESCALATE_SECS elapses. Verify the re-fire actually reaches
  # the drain as a fresh PERMANENTLY-WEDGED wake.
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "watcher did not exit after operator rm"; }
  grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null || fail "operator rm did not result in a fresh PERMANENTLY-WEDGED wake: $(cat "$out")"
  [ -e "$marker" ] || fail "cap marker was not recreated after operator rm re-fire"
  ack_stopped_cycle "$state" || true
  unset FM_FAKE_CREW_STATE
  pass "the operator can manually remove the cap marker for immediate re-engagement and a fresh PERMANENTLY-WEDGED wake fires"
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

  # FM_CAP_HORIZON_SECS validation: reject 0 and non-integer.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_CAP_HORIZON_SECS=0 "$WATCH" > "$out" &
  pid=$!
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "watcher with FM_CAP_HORIZON_SECS=0 failed"; }
  reap "$pid"
  ack_stopped_cycle "$state" || true
  grep -F "FM_CAP_HORIZON_SECS=0" "$state/.watch-triage.log" 2>/dev/null >/dev/null || fail "validation warning not logged for FM_CAP_HORIZON_SECS=0"

  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_CAP_HORIZON_SECS=abc "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    wait_for_exit "$pid" 100 || true
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || true
  grep -F "FM_CAP_HORIZON_SECS='abc'" "$state/.watch-triage.log" 2>/dev/null >/dev/null || fail "validation warning not logged for FM_CAP_HORIZON_SECS=abc"
  unset FM_FAKE_CREW_STATE
  pass "FM_WEDGE_MAX_ESCALATIONS and FM_CAP_HORIZON_SECS both reject 0 and non-integer values, falling back to defaults"
}

test_wedge_cap_fires_permanently_wedged_after_max_escalations
test_wedge_cap_suppresses_subsequent_polls_for_same_hash
test_wedge_cap_persists_across_pause_class_transitions
test_wedge_cap_expires_after_horizon
test_wedge_cap_holds_within_horizon
test_wedge_cap_hash_change_invalidates_marker
test_wedge_cap_operator_can_rm_marker
test_wedge_cap_validates_invalid_override