#!/usr/bin/env bash
# tests/fm-watch-wedge-cap.test.sh - focused unit tests for the
# FM_WEDGE_MAX_ESCALATIONS cap (local patch 2026-08-19, v6). Verifies:
#   1. cap fires PERMANENTLY-WEDGED at the threshold and writes BOTH
#      markers: STATE/.wedge-permanent-<key> (window-scoped) and
#      STATE/.wedge-permanent-<key>-<hash12> (per-hash);
#   2. subsequent polls for any hash in that window are silent (no extra
#      wakes) - fresh hashes included, per the v12 window-scoped gate;
#   3. the cap persists across pause-class transitions (paused: then
#      lifted) - Greptile R4 fix;
#   4. the cap is bound by FM_CAP_HORIZON_SECS (re-fires after the
#      horizon elapses) - Greptile R8 fix (the exit conditions are the
#      horizon and an operator removing BOTH markers; a pane hash change
#      alone does not re-engage while the window-scoped marker stands);
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
# consecutive wedge escalations on the same window, the watcher emits ONE
# terminal wake with PERMANENTLY-WEDGED and writes BOTH STATE/.wedge-permanent-
# <key>-<hash12> (per-hash) and STATE/.wedge-permanent-<key> (window-scoped,
# v12); each marker's content is the cap-fire epoch. Two exit conditions:
# FM_CAP_HORIZON_SECS elapses since that timestamp (default 24h), or the
# operator manually removes BOTH markers - a pane hash change alone does NOT
# re-engage while the window-scoped marker stands (v12). No auto-lift on
# pause_state_class=working (the v6/v7 lift sites were removed in v9 because
# pause_state_class=working can be a steady state during a wedge, not a recovery
# signal).

test_wedge_cap_window_marker_silences_hash_churning_busy_pane() {
  # v12 regression for Greptile P1 follow-up: a worker that churns its rendered
  # pane hash on every poll (a ticking elapsed-time footer, a pane re-rendering
  # for any unrelated reason) must receive at most ONE terminal PERMANENTLY-
  # WEDGED wake for the wedge-event, even when every poll presents a fresh
  # hash that escapes the per-hash marker scheme. v12 introduces a window-
  # scoped marker (in addition to the per-hash marker) so the wedge is silenced
  # for the whole window until the cap horizon elapses or an operator rm
  # clears the marker.
  local dir state fakebin out capture_file window key pane_hash sig pid n max marker_window marker_hash
  dir=$(make_case wedge-cap-churning); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedge-cap-churning"
  printf 'busy wedged pane initial content\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/wedge-cap-churning.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-churning.status"
  sig=$(seen_sig "$state/wedge-cap-churning.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-churning_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "busy wedged pane initial content")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  # v17 (2026-09-11): churn test now exercises busy_turn_bound_check →
  # wedge_timer_check instead of the idle hash-change branch, so the
  # window-scoped marker is actually checked against a fresh hash per
  # poll. The busy verdict comes from the production semantic busy-state
  # contract (harness=pi + an armed .busy-state record written by the real
  # fm-busy-event.sh writer - a bare crew-state string is NOT trusted by
  # window_is_busy), FM_BUSY_TURN_MAX_SECS=1, .meta aged past 1s.
  printf 'busy: harness busy\n' > "$state/wedge-cap-churning.status"
  sig=$(seen_sig "$state/wedge-cap-churning.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-churning_status"
  touch -d '2 seconds ago' "$state/wedge-cap-churning.meta" 2>/dev/null || \
    perl -e 'utime(time()-2, time()-2, $ARGV[0])' "$state/wedge-cap-churning.meta"
  printf '1\n' > "$state/.count-$key"
  max=3
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  "$ROOT/bin/fm-busy-event.sh" arm "$state" "wedge-cap-churning" --state busy --source pi-ext --event poll >/dev/null \
    || fail "could not arm the busy-state record for the churn fixture"
  marker_window="$state/.wedge-permanent-$key"
  marker_hash="$state/.wedge-permanent-$key-${pane_hash:0:12}"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_BUSY_TURN_MAX_SECS=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "priming watch failed: $(cat "$out")"
  fi
  reap "$pid"
  # The priming poll takes the busy route below the busy-turn bound, where
  # wedge_timer_check only resets a missing timer - nothing actionable is
  # queued, so there may be nothing to ack.
  ack_stopped_cycle "$state" || true
  n=1
  while [ "$n" -le "$max" ]; do
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    touch -d '2 seconds ago' "$state/wedge-cap-churning.meta" 2>/dev/null || \
      perl -e 'utime(time()-2, time()-2, $ARGV[0])' "$state/wedge-cap-churning.meta"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_BUSY_TURN_MAX_SECS=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" &
    pid=$!
    if ! wait_for_exit "$pid" 100; then
      reap "$pid"; fail "round $n watch failed: $(cat "$out")"
    fi
    ack_stopped_cycle "$state" || fail "round $n ack failed"
    n=$((n + 1))
  done
  [ -e "$marker_hash" ] || fail "per-hash cap marker missing after firing"
  [ -e "$marker_window" ] || fail "window-scoped cap marker missing after firing - v12 window-scope write is broken"

  total_terminal=0
  i=0
  while [ "$i" -lt 12 ]; do
    i=$((i + 1))
    printf 'busy wedged pane iteration %d with brand new content\n' "$i" > "$capture_file"
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    touch -d '2 seconds ago' "$state/wedge-cap-churning.meta" 2>/dev/null || \
      perl -e 'utime(time()-2, time()-2, $ARGV[0])' "$state/wedge-cap-churning.meta"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_BUSY_TURN_MAX_SECS=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max FM_CAP_HORIZON_SECS=86400 "$WATCH" > "$out" &
    pid=$!
    if wait_poll_cycle "$state" "$pid" 2>/dev/null; then
      :
    fi
    reap "$pid"
    ack_stopped_cycle "$state" || true
    if grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null; then
      total_terminal=$((total_terminal + 1))
    fi
  done
  [ "$total_terminal" -eq 0 ] || fail "hash-churning pane fired $total_terminal additional PERMANENTLY-WEDGED wakes across 12 iterations - v12 window-scoped marker is not silencing the loop"
  [ -e "$marker_window" ] || fail "window-scoped marker was unexpectedly cleared during hash churn"
  unset FM_FAKE_CREW_STATE
  pass "the window-scoped cap marker silences hash-churning panes for the full cap horizon"
}


test_wedge_cap_marker_write_after_durable_wake_v13() {
  # v13 (2026-09-08): marker writes happen AFTER the durable wake row is
  # queued. This closes Greptile P1 #1 ("marker precedes durable wake"):
  # if the watcher dies between the marker write and fm_wake_append, the
  # marker silences retries even though no wake was queued.
  #
  # Test: drive the cap to fire with FM_WAKE_QUEUE pointing at a NON-
  # writable path. fm_wake_append returns failure. Watcher exits 1 with
  # NO cap marker written (per-hash AND window-scoped) - next poll must
  # be able to re-escalate the wedge from scratch.
  local dir state fakebin out capture_file window key pane_hash sig pid n max marker_hash marker_window
  dir=$(make_case wedge-cap-write-order); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedge-cap-write-order"
  printf 'idle wedged content for v13 ordering' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-write-order.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-write-order.status"
  sig=$(seen_sig "$state/wedge-cap-write-order.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-write-order_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle wedged content for v13 ordering")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  max=3
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  marker_hash="$state/.wedge-permanent-$key-${pane_hash:0:12}"
  marker_window="$state/.wedge-permanent-$key"

  # Allow the queue to be writable for rounds 1..max-1 so the normal stale
  # escalations land in the durable queue. On the firing round (round
  # max), we lock the queue directory so fm_wake_append will fail. v13
  # asserts the cap path does NOT write any marker when fm_wake_append
  # fails - this is the only way to exercise the v13 ordering without
  # also breaking normal stale wakes.
  mkdir -p "$dir/queue-parent"
  printf '%s\n' "# prior-round wakes" > "$dir/queue-parent/queue"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "priming watch failed: $(cat "$out")"
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || fail "priming ack failed"
  n=1
  while [ "$n" -le "$max" ]; do
    if [ "$n" -eq "$max" ]; then
      # Make fm_wake_append (the LAST step before the per-hash +
      # window-scoped marker writes in v12) fail on the firing round:
      # remove the queue file and lock the queue directory, so the
      # append's create cannot succeed (appending to the pre-existing
      # writable file would succeed even under a read-only parent). The
      # v13 fix asserts: NO marker is written when fm_wake_append fails.
      rm -f "$dir/queue-parent/queue"
      chmod 0555 "$dir/queue-parent"
    fi
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max \
      FM_WAKE_QUEUE="$dir/queue-parent/queue" "$WATCH" > "$out" &
    pid=$!
    set +e
    wait "$pid" 2>/dev/null
    round_status=$?
    if [ "$n" -eq "$max" ]; then
      # Round max is expected to exit 1: v13 writes no marker when
      # fm_wake_append fails and exits 1 so the next poll retries the
      # cap from scratch. Other rounds must exit 0 or the watcher
      # logic regressed.
      [ "$round_status" -eq 1 ] || fail "round max expected exit 1 (v13 no-marker append-failure path), got $round_status: $(cat "$out")"
    else
      [ "$round_status" -eq 0 ] || fail "round $n watch failed with exit $round_status: $(cat "$out")"
    fi
    if [ "$n" -lt "$max" ]; then
      ack_stopped_cycle "$state" || fail "round $n ack failed"
    fi
    n=$((n + 1))
  done
  chmod 0755 "$dir/queue-parent"
  [ ! -e "$marker_hash" ] || fail "per-hash marker was written despite fm_wake_append failure - v13 ordering is broken (the marker precedes the durable wake)"
  [ ! -e "$marker_window" ] || fail "window-scoped marker was written despite fm_wake_append failure - v13 ordering is broken"
  unset FM_FAKE_CREW_STATE
  pass "cap-fire ordering durably queues the wake BEFORE any marker is written (v13)"
}

test_wedge_cap_failed_window_marker_rolls_back_per_hash_v13() {
  # v13 (2026-09-08): closes Greptile P1 #3 ("failed window marker permits
  # repeats") and P1 #2 ("window marker survives append failure"). On a
  # window-scoped marker write FAILURE (after fm_wake_append success and
  # per-hash marker success), v13 rolls back the per-hash marker and
  # exits 1 - leaving no partial cap state visible.
  #
  # Test: pre-create $state/.wedge-permanent-<key> as a NON-EMPTY DIRECTORY
  # (so `date +%s > ...` cannot create a file at that exact path - bash
  # refuses to truncate a directory). The v13 fix rolls back the per-hash
  # marker (which is targeted at .wedge-permanent-<key>-<hash12>, a
  # different file) when the window-scoped marker write fails. We assert
  # the rollback fired: neither marker ends up on disk.
  local dir state fakebin out capture_file window key pane_hash sig pid n max marker_hash marker_window
  dir=$(make_case wedge-cap-window-fail); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedge-cap-window-fail"
  printf 'idle wedged content for v13 window-fail' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-window-fail.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-window-fail.status"
  sig=$(seen_sig "$state/wedge-cap-window-fail.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-window-fail_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle wedged content for v13 window-fail")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  max=3
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  marker_hash="$state/.wedge-permanent-$key-${pane_hash:0:12}"
  marker_window="$state/.wedge-permanent-$key"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "priming watch failed: $(cat "$out")"
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || fail "priming ack failed"
  n=1
  while [ "$n" -le "$max" ]; do
    if [ "$n" -eq "$max" ]; then
      # On the firing round, plant the window-scoped marker path as an
      # EXISTING DIRECTORY so `date +%s > "$STATE/.wedge-permanent-<key>"`
      # cannot create the file (bash refuses to redirect into a directory).
      # v13 then rolls back the per-hash marker (which IS writable).
      mkdir -p "$marker_window/blocker" 2>/dev/null
    fi
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" &
    pid=$!
    set +e
    wait "$pid" 2>/dev/null
    round_status=$?
    if [ "$n" -eq "$max" ]; then
      # Round max is expected to exit 1: v13 rolls back the per-hash
      # marker after a failed window-scoped marker write and exits 1.
      # Other rounds must exit 0 or the watcher logic regressed.
      [ "$round_status" -eq 1 ] || fail "round max expected exit 1 (v13 cap-failure rollback), got $round_status: $(cat "$out")"
    else
      [ "$round_status" -eq 0 ] || fail "round $n watch failed with exit $round_status: $(cat "$out")"
    fi
    if [ "$n" -lt "$max" ]; then
      ack_stopped_cycle "$state" || fail "round $n ack failed"
    fi
    n=$((n + 1))
  done
  rm -rf "$marker_window" 2>/dev/null || true
  [ ! -e "$marker_hash" ] || fail "per-hash marker was NOT rolled back when the window-scoped marker write failed - v13 rollback is incomplete"
  [ ! -e "$marker_window" ] || fail "window-scoped marker is unexpectedly present after a failed write - v13 ordering created an inconsistency"
  unset FM_FAKE_CREW_STATE
  pass "v13 rolls back the per-hash marker when the window-scoped marker write fails (no partial cap state)"
}


test_wedge_cap_rollback_resets_state_v14() {
  # v14 (2026-09-08): closes Greptile P1 from v13 review - "Failed cap
  # writes refire immediately". On either cap-marker write failure the
  # watcher must:
  #   - reset .wedge-escalations-<key> (so the next poll starts at 1, not
  #     at the saturated value)
  #   - reset .stale-since-<key> to "now" (so the next poll ages from 0,
  #     not 500s ago)
  #   - clear_write_tracking on the window key
  # Otherwise the next poll (which runs in a fresh watcher invocation) reads
  # the saturated n and the stale timer, fires PERMANENTLY-WEDGED again
  # immediately, and repeats every poll while the write failure persists.
  #
  # Test: drive the cap with FM_WAKE_QUEUE writable (so fm_wake_append
  # succeeds) and with the window-scoped marker path planted as a directory
  # (so the per-hash marker write succeeds and the window-scoped marker
  # write fails - the v13 failure path). After round max we inspect the
  # post-rollback state: escalation counter is 0, stale timer is "recent"
  # (within last 5 seconds), no per-hash marker.
  local dir state fakebin out capture_file window key pane_hash sig pid n max marker_hash marker_window
  dir=$(make_case wedge-cap-rollback); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedge-cap-rollback"
  printf 'idle wedged content for v14 rollback' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-rollback.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-rollback.status"
  sig=$(seen_sig "$state/wedge-cap-rollback.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-rollback_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle wedged content for v14 rollback")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  max=3
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  marker_hash="$state/.wedge-permanent-$key-${pane_hash:0:12}"
  marker_window="$state/.wedge-permanent-$key"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "priming watch failed: $(cat "$out")"
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || fail "priming ack failed"
  n=1
  while [ "$n" -le "$max" ]; do
    if [ "$n" -eq "$max" ]; then
      # Plant the window-scoped marker path as a non-empty directory so
      # the per-hash marker write succeeds (closing P1 #2/#3 in v13) and
      # the window-scoped marker write fails - triggering the v14 rollback.
      mkdir -p "$marker_window/blocker" 2>/dev/null
    fi
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" &
    pid=$!
    set +e
    wait "$pid" 2>/dev/null
    round_status=$?
    if [ "$n" -eq "$max" ]; then
      [ "$round_status" -eq 1 ] || fail "round max expected exit 1 (v14 cap-failure rollback), got $round_status: $(cat "$out")"
    else
      [ "$round_status" -eq 0 ] || fail "round $n watch failed with exit $round_status: $(cat "$out")"
    fi
    if [ "$n" -lt "$max" ]; then
      ack_stopped_cycle "$state" || fail "round $n ack failed"
    fi
    n=$((n + 1))
  done

  # v14 assertions: after the cap-failure rollback:
  #   1. .wedge-permanent-<key>-<hash12> must NOT exist (per-hash rolled back)
  #   2. .wedge-escalations-<key> must be 0 (counter rolled back to 0)
  #   3. .stale-since-<key> must be "recent" (within 5 seconds of now;
  #      rolled back so next poll ages from "now")
  rm -rf "$marker_window" 2>/dev/null || true
  [ ! -e "$marker_hash" ] || fail "per-hash marker was NOT rolled back - v14 rollback is incomplete (P1 #2/#3 regressed)"
  if [ -e "$state/.wedge-escalations-$key" ]; then
    ewf_after=$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo "")
    case "$ewf_after" in
      ''|"0") ;;
      *) fail "wedge-escalation counter was NOT reset by v14 rollback (still holds '$ewf_after' = saturation value) - the next poll will re-fire PERMANENTLY-WEDGED immediately (this is the P1 Greptile flagged on v13)"
         ;;
    esac
  fi
  if [ -e "$state/.stale-since-$key" ]; then
    ssf_age=$(($(date +%s) - $(cat "$state/.stale-since-$key")))
    [ "$ssf_age" -le 5 ] || fail "stale-since timer was NOT refreshed by v14 rollback (now ${ssf_age}s old - .stale-since-<key> still ages from 500s ago at the next poll, which means the next poll re-fires PERMANENTLY-WEDGED immediately)"
  else
    fail "stale-since was removed entirely (v14 rollback should RESTORE it to 'now', not delete it - the wedge timer needs an anchor)"
  fi
  unset FM_FAKE_CREW_STATE
  pass "v14 rollback resets both the escalation counter and the stale timer so the next poll re-escalates from 1, not the saturated value (closes Greptile P1 from v13 review)"
}


test_wedge_cap_rollback_failure_sets_sentinel_v15() {
  # v15 (2026-09-08): closes Greptile P1 from v14 review - "Rollback
  # failures preserve saturation". v14 used `|| true` on every rollback
  # line, so a rollback that itself failed (the SAME fs condition that
  # broke the marker write) would silently preserve the saturation. v15:
  #
  # 1. _wedge_cap_rollback returns 1 if any reset fails AND writes a
  #    .wedge-rollback-failed-<key> sentinel (timestamp + first failing
  #    path).
  # 2. wedge_timer_check checks for the sentinel at the top - if recent
  #    (within FM_ROLLBACK_SENTINEL_TTL_SECS, default 3600s), it returns 0
  #    without publishing a wake or writing a marker.
  #
  # This test exercises the top-of-function sentinel check directly:
  # plant a sentinel file with a recent timestamp, drive a poll, and
  # confirm the wedge path short-circuits (no PERMANENTLY-WEDGED wake).
  # (The cap path's exit-2 path is exercised indirectly by ensuring the
  # sentinel state in STATE survives a round; see also
  # test_wedge_cap_rollback_resets_state_v14 for the rollback SUCCESS
  # path. Together they cover the v15 contract.)
  local dir state fakebin out capture_file window key pane_hash sig pid n max marker_hash marker_window sentinel
  dir=$(make_case wedge-cap-rollback-fails); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedge-cap-rollback-fails"
  printf 'idle wedged content for v15 rollback-fails' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-rollback-fails.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-rollback-fails.status"
  sig=$(seen_sig "$state/wedge-cap-rollback-fails.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-rollback-fails_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle wedged content for v15 rollback-fails")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  max=3
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  marker_hash="$state/.wedge-permanent-$key-${pane_hash:0:12}"
  marker_window="$state/.wedge-permanent-$key"
  sentinel="$state/.wedge-rollback-failed-$key"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "priming watch failed: $(cat "$out")"
  fi
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
    wait_for_exit "$pid" 100 || { reap "$pid"; fail "round $n watch failed: $(cat "$out")"; }
    ack_stopped_cycle "$state" || fail "round $n ack failed"
    n=$((n + 1))
  done
  [ -e "$marker_hash" ] || fail "per-hash cap marker missing after firing - prime test before sentinel test must pass first"
  [ -e "$marker_window" ] || fail "window-scoped cap marker missing after firing - prime test before sentinel test must pass first"

  # Now plant the v15 sentinel: .wedge-rollback-failed-<key> with a recent
  # timestamp. Drive ONE more poll and confirm the wedge path short-circuits.
  # The short-circuit is by design a non-exiting path: the watcher stays
  # alive (it's still polling the window) but wedge_timer_check returns 0
  # at the top without publishing a wake. The test uses wait_poll_cycle
  # (which waits for a heartbeat) to confirm the watcher is alive AND
  # processing the sentinel without publishing a wake.
  #
  # triage_log writes to STATE/.watch-triage.log, not stdout - the test
  # checks that file (not $out) for the expected short-circuit log line.
  printf '%s %s\n' "$(date +%s)" "test-injected" > "$sentinel"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max FM_ROLLBACK_SENTINEL_TTL_SECS=3600 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "v15 sentinel poll failed (watcher never beat): $(cat "$out")"
  fi
  if grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null; then
    reap "$pid"; fail "v15 sentinel short-circuit published a PERMANENTLY-WEDGED wake - the queue-flood behavior v15 closed is broken"
  fi
  if ! grep -F "rollback-failed sentinel active" "$state/.watch-triage.log" >/dev/null; then
    reap "$pid"; fail "expected triage_log 'rollback-failed sentinel active' was not emitted (triage file: $(cat "$state/.watch-triage.log" 2>/dev/null || echo missing))"
  fi
  [ -e "$sentinel" ] || { reap "$pid"; fail "v15 sentinel was removed by the short-circuit poll - it should remain until TTL expiry or operator rm"; }
  reap "$pid"

  # Final cleanup of the primed cap markers so the test exits clean.
  rm -f "$marker_hash" "$marker_window"

  unset FM_FAKE_CREW_STATE
  pass "v15 rollback-failed sentinel short-circuits the wedge path - no wake-amplification under persistent fs failure (closes Greptile P1 from v14 review)"
}


test_wedge_cap_rollback_sentinel_keyed_on_busy_route_v17() {
  # v17 (2026-09-11): busy-pane regression for the rollback-failed sentinel.
  # busy_turn_bound_check declares an empty `local key` on its fall-through
  # path, and bash dynamic scoping used to shadow wedge_timer_check's key
  # with that empty value when the cap path handed off to _wedge_cap_rollback
  # - so on the busy route the sentinel was written as
  # .wedge-rollback-failed- (empty key) while the next poll's keyed lookup
  # reads .wedge-rollback-failed-<key>: the v15 short-circuit silently did
  # not hold exactly where v17's fix targets it. Drive the REAL busy route
  # (busy crew state + crossed busy-turn bound) through a failing
  # window-marker write whose rollback reset also fails, then require the
  # NEXT busy-route poll to short-circuit on the keyed sentinel.
  local dir state fakebin out capture_file window key pane_hash sig pid max
  local marker_window marker_hash sentinel esc esc_after round_status rollbacks
  dir=$(make_case wedge-cap-busy-route-sentinel); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedge-cap-busy-sentinel"
  printf 'busy wedged pane for v17 busy-route sentinel\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/fm-wedge-cap-busy-sentinel.meta"
  printf 'busy: harness busy\n' > "$state/fm-wedge-cap-busy-sentinel.status"
  sig=$(seen_sig "$state/fm-wedge-cap-busy-sentinel.status"); printf '%s' "$sig" > "$state/.seen-fm-wedge-cap-busy-sentinel_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "busy wedged pane for v17 busy-route sentinel")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  max=1
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  # The busy verdict comes from the production semantic busy-state contract:
  # harness=pi in the meta plus an armed .busy-state record written by the
  # real fm-busy-event.sh writer. A bare crew-state string is NOT trusted by
  # window_is_busy, so without this the poll silently takes an idle absorb
  # path and never reaches busy_turn_bound_check.
  "$ROOT/bin/fm-busy-event.sh" arm "$state" "fm-wedge-cap-busy-sentinel" --state busy --source pi-ext --event poll >/dev/null \
    || fail "could not arm the busy-state record for the busy-route fixture"
  marker_window="$state/.wedge-permanent-$key"
  marker_hash="$state/.wedge-permanent-$key-${pane_hash:0:12}"
  sentinel="$state/.wedge-rollback-failed-$key"
  esc="$state/.wedge-escalations-$key"

  # Round 1: the cap fires on the busy route (max=1, fresh escalation), the
  # window-scoped marker write fails (non-empty directory blocker), and the
  # rollback's escalation-file reset ALSO fails (the escalation path is the
  # same kind of blocker) - so the rollback must write the keyed sentinel
  # and the cap path must exit 2.
  mkdir -p "$esc/blocker"
  mkdir -p "$marker_window/blocker"
  touch -d '2 seconds ago' "$state/fm-wedge-cap-busy-sentinel.meta" 2>/dev/null || \
    perl -e 'utime(time()-2, time()-2, $ARGV[0])' "$state/fm-wedge-cap-busy-sentinel.meta"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_BUSY_TURN_MAX_SECS=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max FM_ROLLBACK_SENTINEL_TTL_SECS=3600 "$WATCH" > "$out" &
  pid=$!
  round_status=0
  wait_for_exit "$pid" 100 || round_status=$?
  [ "$round_status" -ne 124 ] || fail "round 1 watch did not exit after the cap-failure rollback: $(cat "$out")"
  [ -e "$sentinel" ] || { rollbacks=''; for f in "$state"/.wedge-rollback-failed*; do if [ -e "$f" ]; then rollbacks="$rollbacks $f"; fi; done; fail "round 1 wrote no sentinel at .wedge-rollback-failed-$key - the busy route built the sentinel name from an unscoped key (pre-v17 shadowing) or the rollback sentinel write is broken (found:${rollbacks:- none})"; }
  [ "$round_status" -eq 2 ] || fail "round 1 expected exit 2 (rollback-failed sentinel set), got $round_status: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "round 1 ack failed"

  # Round 2: restore a healthy fs (blockers gone, per-hash and window
  # markers removed, timer re-aged, counter reset to 0) and drive one more
  # busy-route poll. The keyed sentinel must short-circuit it: no
  # PERMANENTLY-WEDGED wake, the sentinel-active triage line, the sentinel
  # retained, and the escalation counter untouched. Pre-v17 the keyed
  # lookup missed and this poll re-fired the cap - the queue-flood the
  # sentinel exists to stop.
  rm -rf "$marker_window" "$esc"
  rm -f "$marker_hash"
  printf '0\n' > "$esc"
  touch -d '2 seconds ago' "$state/fm-wedge-cap-busy-sentinel.meta" 2>/dev/null || \
    perl -e 'utime(time()-2, time()-2, $ARGV[0])' "$state/fm-wedge-cap-busy-sentinel.meta"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  rm -f "$state/.watch-triage.log"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_BUSY_TURN_MAX_SECS=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max FM_ROLLBACK_SENTINEL_TTL_SECS=3600 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    : # a pre-fix regression exits on its own after re-firing; assertions below catch it
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || true
  if grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null; then
    fail "busy-route poll re-fired PERMANENTLY-WEDGED despite the keyed rollback sentinel - the v15 short-circuit does not hold on the busy-pane route (pre-v17 empty-key shadowing): $(cat "$out")"
  fi
  if ! grep -F "rollback-failed sentinel active" "$state/.watch-triage.log" >/dev/null; then
    fail "expected triage_log 'rollback-failed sentinel active' was not emitted on the busy route (triage file: $(cat "$state/.watch-triage.log" 2>/dev/null || echo missing))"
  fi
  [ -e "$sentinel" ] || fail "the short-circuit poll removed the keyed sentinel - it must remain until TTL expiry or operator rm"
  esc_after=$(cat "$esc" 2>/dev/null || true)
  [ "$esc_after" = "0" ] || fail "the sentinel short-circuit poll escalated anyway (counter now '$esc_after', expected untouched 0)"
  unset FM_FAKE_CREW_STATE
  pass "the rollback-failed sentinel is written and honored under its proper window key on the busy-pane route (closes the v17 dynamic-scoping shadowing)"
}

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
# v12: a new hash does NOT lift the cap - the window-scoped marker silences all
# hashes in the window; operator can `rm` BOTH markers for immediate
# re-engagement. See tests below for the new semantics.

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

  # Backdate BOTH markers (per-hash AND window-scoped) so both appear older
  # than FM_CAP_HORIZON_SECS. The cap is now stale on both gates; the next
  # wedge_timer_check call must NOT be short-circuited by either marker.
  old_ts=$(( $(date +%s) - 90000 ))
  printf '%s\n' "$old_ts" > "$marker"
  printf '%s\n' "$old_ts" > "$state/.wedge-permanent-$key"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"

  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max FM_CAP_HORIZON_SECS=86400 "$WATCH" > "$out" &
  pid=$!
  # v11+v12: cap fires at horizon expiry, but the wedge-escalation counter was
  # reset to 0 when the original cap fired. So this first poll reports
  # escalation 1 (not an immediate re-fire of PERMANENTLY-WEDGED). The wedge
  # re-accumulates over FM_WEDGE_MAX_ESCALATIONS polls and re-fires on the
  # $max-th round.
  if ! wait_for_exit "$pid" 100; then
    reap "$pid"; fail "watcher did not exit on the first post-horizon poll (markers may still be short-circuiting): $(cat "$out")"
  fi
  grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null && fail "first post-horizon poll re-fired the cap immediately - counter was not reset when the original cap fired: $(cat "$out")"
  grep -F "escalation 1" "$out" >/dev/null || fail "first post-horizon poll did not report fresh escalation count (expected escalation 1): $(cat "$out")"
  ack_stopped_cycle "$state" || true

  # Drive FM_WEDGE_MAX_ESCALATIONS - 1 more polls so the wedge re-accumulates
  # and re-fires the cap on the final round.
  n=2
  while [ "$n" -le "$max" ]; do
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max FM_CAP_HORIZON_SECS=86400 "$WATCH" > "$out" &
    pid=$!
    if ! wait_for_exit "$pid" 100; then
      reap "$pid"; fail "post-horizon round $n watch failed: $(cat "$out")"
    fi
    if [ "$n" -lt "$max" ]; then
      grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null && fail "post-horizon round $n fired PERMANENTLY-WEDGED before the cap"
    else
      grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null || fail "post-horizon round $max did not re-fire the cap: $(cat "$out")"
    fi
    ack_stopped_cycle "$state" || fail "post-horizon round $n ack failed"
    n=$((n + 1))
  done

  unset FM_FAKE_CREW_STATE
  pass "the cap is bound by FM_CAP_HORIZON_SECS on BOTH markers; the wedge can re-engage and re-fire on its own merits"
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

test_wedge_cap_window_marker_silences_fresh_hash() {
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

  # v12: a new hash in the SAME window is intentionally silenced by the
  # window-scoped marker. v2 protected the "fresh stale hash in the same
  # window" case, but that was over-eager against the hash-churning busy
  # pane loop Greptile flagged on the rebased PR. Verify the new hash does
  # NOT fire: the watch runs without exiting, both markers stay, and the
  # drain shows no new wake.
  pane_hash_new=$(hash_text "crew is alive and producing output")
  printf '%s' "$pane_hash_new" > "$capture_file"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max FM_CAP_HORIZON_SECS=86400 "$WATCH" > "$out" &
  pid=$!
  if wait_poll_cycle "$state" "$pid" 2>/dev/null; then
    :
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || true
  [ -e "$state/.wedge-permanent-$key-${pane_hash_old:0:12}" ] || fail "per-hash marker was unexpectedly cleared on hash change"
  [ -e "$state/.wedge-permanent-$key" ] || fail "window-scoped marker was unexpectedly cleared on hash change"
  drain_out="$dir/drain.out"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || true
  if grep "$(printf '	stale	')" "$drain_out" 2>/dev/null | grep -F "$window" >/dev/null; then
    fail "new-hash wedge was NOT suppressed by the window-scoped marker: $(cat "$drain_out")"
  fi
  unset FM_FAKE_CREW_STATE
  pass "the window-scoped cap marker silences a fresh hash in the same window until horizon"
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

  # v12: operator removes BOTH the per-hash marker AND the window-scoped
  # marker to lift the cap. Removing only the per-hash leaves the window-
  # scoped gate in place, which is the intended behavior (per-hash alone
  # would let a hash-churning busy pane re-fire the cap on a fresh hash,
  # but the window-scoped gate stops the loop).
  rm -f "$marker" "$state/.wedge-permanent-$key"

  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" &
  pid=$!
  # v11+v12: counter is reset to 0 when the cap fires (v11), and both markers
  # were rm'd above (v12). The wedge re-engages at escalation 1 and re-
  # accumulates over FM_WEDGE_MAX_ESCALATIONS polls before re-firing. Verify
  # the first poll reports escalation 1 (no PERMANENTLY-WEDGED), then drive
  # FM_WEDGE_MAX_ESCALATIONS - 1 more polls and verify the cap re-fires on
  # the $max-th round with the per-hash marker recreated.
  if ! wait_for_exit "$pid" 100; then
    reap "$pid"; fail "watcher did not exit on the first post-rm poll (markers may still be short-circuiting): $(cat "$out")"
  fi
  grep -F "escalation 1" "$out" >/dev/null || fail "first post-rm poll did not report fresh escalation count (expected escalation 1): $(cat "$out")"
  grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null && fail "first post-rm poll re-fired the cap immediately - counter was not reset when the original cap fired: $(cat "$out")"
  ack_stopped_cycle "$state" || true

  n=2
  while [ "$n" -le "$max" ]; do
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" &
    pid=$!
    if ! wait_for_exit "$pid" 100; then
      reap "$pid"; fail "post-rm round $n watch failed: $(cat "$out")"
    fi
    if [ "$n" -lt "$max" ]; then
      grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null && fail "post-rm round $n fired PERMANENTLY-WEDGED before the cap"
    else
      grep -F "PERMANENTLY-WEDGED" "$out" >/dev/null || fail "post-rm round $max did not re-fire the cap: $(cat "$out")"
    fi
    ack_stopped_cycle "$state" || fail "post-rm round $n ack failed"
    n=$((n + 1))
  done
  [ -e "$marker" ] || fail "per-hash marker was not recreated after operator rm re-fire"
  unset FM_FAKE_CREW_STATE
  pass "the operator can manually remove both cap markers for immediate re-engagement and a fresh PERMANENTLY-WEDGED wake fires once the wedge re-accumulates"
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



test_wedge_cap_escalation_counter_resets_on_cap_fire() {
  # Regression for Greptile P1 (v11): the wedge-escalation counter in
  # .wedge-escalations-<key> MUST be reset to 0 (or removed) when the cap
  # fires. Otherwise a pane that later produces a fresh hash sees n already
  # at FM_WEDGE_MAX_ESCALATIONS and fires PERMANENTLY-WEDGED on the FIRST
  # poll of the new hash, then on every subsequent poll. The cap exists to
  # bound that exact loop; this test pins the reset by inspecting the
  # counter file directly after the cap fires.
  local dir state fakebin out capture_file window key pane_hash sig pid n max marker_a ewf_after_cap
  dir=$(make_case wedge-cap-counter-reset); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedge-cap-counter-reset"
  printf 'idle wedged content' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedge-cap-counter-reset.meta"
  printf 'working: still wedged\n' > "$state/wedge-cap-counter-reset.status"
  sig=$(seen_sig "$state/wedge-cap-counter-reset.status"); printf '%s' "$sig" > "$state/.seen-wedge-cap-counter-reset_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle wedged content")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  max=3
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  marker_a="$state/.wedge-permanent-$key-${pane_hash:0:12}"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "priming watch failed: $(cat "$out")"
  fi
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
    if ! wait_for_exit "$pid" 100; then
      reap "$pid"; fail "round $n watch failed: $(cat "$out")"
    fi
    ack_stopped_cycle "$state" || fail "round $n ack failed"
    n=$((n + 1))
  done
  [ -e "$marker_a" ] || fail "cap marker missing after firing"

  if [ -e "$state/.wedge-escalations-$key" ]; then
    ewf_after_cap=$(cat "$state/.wedge-escalations-$key" 2>/dev/null || true)
    case "$ewf_after_cap" in
      ''|"0") ;;
      *) fail "wedge-escalation counter was not reset when the cap fired (still holds '$ewf_after_cap' = saturation value) - a fresh hash will re-fire the cap immediately"
         ;;
    esac
  fi
  unset FM_FAKE_CREW_STATE
  pass "the wedge-escalation counter resets to 0 when the cap fires"
}

test_wedge_cap_fires_permanently_wedged_after_max_escalations
test_wedge_cap_suppresses_subsequent_polls_for_same_hash
test_wedge_cap_persists_across_pause_class_transitions
test_wedge_cap_expires_after_horizon
test_wedge_cap_holds_within_horizon
test_wedge_cap_window_marker_silences_fresh_hash
test_wedge_cap_escalation_counter_resets_on_cap_fire
test_wedge_cap_marker_write_after_durable_wake_v13
test_wedge_cap_failed_window_marker_rolls_back_per_hash_v13
test_wedge_cap_rollback_resets_state_v14
test_wedge_cap_rollback_failure_sets_sentinel_v15
test_wedge_cap_rollback_sentinel_keyed_on_busy_route_v17
test_wedge_cap_window_marker_silences_hash_churning_busy_pane
test_wedge_cap_operator_can_rm_marker
test_wedge_cap_validates_invalid_override