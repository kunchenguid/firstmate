#!/usr/bin/env bash
# Behavior tests for watcher declared-wait, pause, and captain-hold rechecks
# (bin/fm-watch.sh, bin/fm-classify-lib.sh). Shared fixtures live in
# tests/watch-triage-helpers.sh.
#
# Classifier tests in fm-watch-triage.test.sh export FM_CREW_STATE_BIN pointing
# at a hermetic make_fake_crew_state stub and never unset it. Three launches in
# this file pass no FM_CREW_STATE_BIN, so in the original run they inherited
# that stub's default unknown verdict. Install the same hermetic fake here so
# those launches keep that verdict instead of hitting the real
# bin/fm-crew-state.sh.
set -u

# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-triage-pause-tests)
mkdir -p "$TMP_ROOT/crew-state-bin"
FM_CREW_STATE_BIN=$(make_fake_crew_state "$TMP_ROOT/crew-state-bin")
export FM_CREW_STATE_BIN

# --- non-terminal stale, crew NOT provably working: surfaced immediately ------
# The key requirement: a crew with no running pipeline that has gone quiet (and is
# not busy) has stopped - it may be done via interactive menus, waiting, or wedged.
# It must surface at once, never wait out the wedge timer, so these users (a
# non-no-mistakes crew, or any crew with no running pipeline) are never left hanging.

test_nonterminal_stale_not_working_surfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-stale-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-stopped"
  printf 'idle prompt, finished' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/stopped.meta"
  # Non-terminal status (the crew never wrote a captain-relevant verb), .seen-*
  # primed so the signal scan does not pre-empt the stale path.
  printf 'working: implementing\n' > "$state/stopped.status"
  sig=$(seen_sig "$state/stopped.status"); printf '%s' "$sig" > "$state/.seen-stopped_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt, finished")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # No running pipeline; the pane is idle. NOT provably working.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'

  # Even with a high wedge threshold, a not-provably-working stale surfaces at once.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not surface a not-provably-working non-terminal stale at once"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print the immediate stale wake"
  grep -F "possible wedge" "$out" >/dev/null && fail "an immediate stopped-crew stale was mislabeled a wedge"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor was not advanced on surface"
  [ ! -e "$state/.stale-since-$key" ] || fail "stale-since timer should not be set when surfacing immediately"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the immediate stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "immediate stale wake was not queued"
  pass "a not-provably-working non-terminal stale is surfaced immediately (never left to wait out the timer)"
}

# --- non-terminal stale, crew DECLARED a pause: absorbed, re-surfaced on a long
#     cadence, never wedge-escalated ------------------------------------------
# The live 2026-07-09/10 case: a crew intentionally held awaiting an upstream tool
# release (paused: ...) whose idle pane tripped repeated possible-wedge escalations
# all day. With the paused verb, its stale is absorbed like a working crew but never
# uses the wedge timer; it re-surfaces once past PAUSE_RESURFACE_SECS (anchored on
# the pause's own status-file age, so a churny idle pane cannot reset the cadence)
# for a recheck, so a forgotten pause cannot rot invisibly.
test_nonterminal_stale_paused_absorbed_then_resurfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid back statusf
  dir=$(make_case nonterminal-stale-paused); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-held"
  printf 'idle, holding for upstream' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/held.meta"
  statusf="$state/held.status"
  # A DECLARED pause (not captain-relevant), .seen-* primed so the signal scan does
  # not pre-empt the stale path.
  printf 'paused: holding for the upstream tool release\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle, holding for upstream")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # crew_absorb_class reads the declared pause from fm-crew-state.sh.
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · holding for the upstream tool release'

  # Phase A: a fresh pause (status file just written) under a high re-surface
  # threshold is absorbed - no wake, no wedge timer.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for a fresh declared pause (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "fresh paused stale printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "fresh paused stale enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on paused absorb"
  [ -e "$state/.paused-$key" ] || fail "paused flag not recorded on absorb"
  [ ! -e "$state/.stale-since-$key" ] || fail "a paused absorb must not start the wedge timer"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional paused phase-A stop"

  # Phase B: age the pause past the (now normal) threshold by backdating its
  # status file, re-prime .seen-* to the new signature so the signal scan stays
  # quiet, and confirm it re-surfaces as a paused recheck - never a wedge.
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  : > "$out"
  printf 'idle, holding for upstream (token 2)' > "$capture_file"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not re-surface a declared pause past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "re-surface did not print a stale wake"
  grep -F "awaiting external" "$out" >/dev/null || fail "re-surface was not labeled a paused/awaiting-external recheck"
  grep -F "possible wedge" "$out" >/dev/null && fail "a declared pause was mislabeled a possible wedge"
  [ -e "$state/.paused-resurfaced-$key" ] || fail "the paused re-surface throttle marker was not recorded"
  [ ! -e "$state/.stale-since-$key" ] || fail "a paused re-surface must not use the wedge timer"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the paused re-surface failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "paused re-surface was not queued"
  pass "a declared pause is absorbed on first sight, then re-surfaced as a recheck past the threshold, never wedge-escalated"
}

# Own background work is a declared wait using the same existing paused verb.
# This intentionally keeps the first-sight alert, then uses the long cadence.
# The backend/current-state fixtures are not live-harness evidence.
test_own_work_wait_keeps_first_alert_then_long_cadence() {
  local wait_kind dir state fakebin out capture_file statusf window key sig pid round
  for wait_kind in background-shell pipeline-run foreground-command; do
    dir=$(make_case "own-work-$wait_kind"); state="$dir/state"; fakebin="$dir/fakebin"
    out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/own-work.status"
    window="test:fm-own-work"; key=$(printf '%s' "$window" | tr ':/.' '___')
    printf 'idle worker awaiting its own %s\n' "$wait_kind" > "$capture_file"
    printf 'window=%s\nkind=scout\nharness=grok\nbackend=tmux\n' "$window" > "$state/own-work.meta"
    printf 'paused: waiting for my %s to finish; resume on completion\n' "$wait_kind" > "$statusf"
    # Age before the first observation: backdating later can change the birth
    # time on macOS and accidentally turn this into a replacement declaration.
    set_mtime "$(( $(date +%s) - 500 ))" "$statusf"
    sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-own-work_status"
    printf '%s' "$(hash_text "$(cat "$capture_file")")" > "$state/.hash-$key"
    printf '1\n' > "$state/.count-$key"

    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_FAKE_TMUX_CURRENT_COMMAND=grok \
      FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting for own work' \
      watch_bg "$state" "$fakebin" "$out" env FM_PAUSE_RESURFACE_SECS=999
    pid=$!
    wait_for_exit "$pid" 100 || { reap "$pid"; fail "$wait_kind lost its first-sight alert"; }
    grep -Fx "stale: $window" "$out" >/dev/null || fail "$wait_kind did not surface as a plain stale"
    ack_stopped_cycle "$state" || fail "could not acknowledge $wait_kind first alert"

    # Cross the ordinary wedge threshold twice without aging the declaration
    # past the long pause cadence. Neither re-arm may add a second alert.
    for round in 1 2; do
      printf '%s\n' $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
      PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
        FM_FAKE_TMUX_CURRENT_COMMAND=grok \
        FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting for own work' \
        watch_bg "$state" "$fakebin" "$dir/recheck.out" env \
          FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999
      pid=$!
      wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "$wait_kind repeated an alert: $(cat "$dir/recheck.out")"; }
      [ ! -s "$dir/recheck.out" ] || { reap "$pid"; fail "$wait_kind printed a repeated alert"; }
      [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "$wait_kind queued a repeated alert"; }
      [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; fail "$wait_kind counted a wedge"; }
      reap "$pid"
      ack_stopped_cycle "$state" || fail "could not acknowledge $wait_kind test stop"
    done

    # Both the unchanged declaration and its first alert must be older than
    # the 240s cadence for a forgotten wait to get its bounded recheck.
    set_mtime "$(( $(date +%s) - 500 ))" "$state/.paused-resurfaced-$key"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_FAKE_TMUX_CURRENT_COMMAND=grok \
      FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting for own work' \
      watch_bg "$state" "$fakebin" "$dir/long-cadence.out" env \
        FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=240
    pid=$!
    wait_for_exit "$pid" 100 || { reap "$pid"; fail "$wait_kind never rechecked on the long cadence"; }
    grep -F 'awaiting external' "$dir/long-cadence.out" >/dev/null || fail "$wait_kind recheck lost its pause reason"
    grep -F 'possible wedge' "$dir/long-cadence.out" >/dev/null && fail "$wait_kind recheck became a wedge"
  done
  # Disconfirming control: an idle worker with no declaration must still alarm.
  dir=$(make_case own-work-undeclared); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/own-work.status"
  printf 'idle worker without a declared wait\n' > "$capture_file"
  printf 'window=%s\nkind=scout\nharness=grok\nbackend=tmux\n' "$window" > "$state/own-work.meta"
  printf 'working: implementing\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-own-work_status"
  printf '%s' "$(hash_text "$(cat "$capture_file")")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available' \
    watch_bg "$state" "$fakebin" "$out" env FM_STALE_ESCALATE_SECS=999
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "undeclared idle worker no longer alarms"; }
  grep -Fx "stale: $window" "$out" >/dev/null || fail "undeclared idle worker did not surface"
  grep -F "stale: $window" "$state/.wake-queue" >/dev/null || fail "undeclared idle worker's wake was not queued"
  pass "own-work waits keep one first alert, then bounded rechecks without wedges; undeclared idle still alarms"
}

# A captain-held crew can leave a stable backend endpoint after its agent exits.
# fm-crew-state then authoritatively reports stopped rather than paused, but the
# confirmed-dead agent plus the declared wait or captain-held transfer must retain
# bounded pause handling.
# A still-live agent at an external-decision gate is the disconfirming case: it
# must surface once, while the unchanged hash must not append the same wake on
# every watcher re-arm.
test_exited_declared_pause_is_bounded_but_live_gate_surfaces() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid back round wakes bare
  dir=$(make_case exited-declared-pause); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
  window="test:fm-held"
  printf 'idle bare shell after agent exit\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held.meta"
  printf 'paused: held per captain while an external decision is pending\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle bare shell after agent exit")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  round=1
  while [ "$round" -le 6 ]; do
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
    pid=$!
    if wait_poll_cycle "$state" "$pid"; then
      reap "$pid"
    elif kill -0 "$pid" 2>/dev/null; then
      reap "$pid"
      fail "dead-agent watcher round $round timed out before completing a poll cycle"
    else
      wait "$pid" || fail "dead-agent watcher round $round failed"
    fi
    round=$((round + 1))
  done
  # A watcher that queues nothing never creates .wake-queue, so these counts
  # read a path that may legitimately be absent. awk aborts on a missing file
  # before END runs, which collapses the count to the empty string and turns the
  # next comparison into an "integer expression expected" error - reported as a
  # flood of an unprintable number of wakes instead of the real contract breach
  # the grep below names. No queue means no wakes, per the drain-count read at
  # the end of this file.
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  bare=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  [ "$wakes" -le 1 ] || fail "dead-agent declared pause flooded $wakes stale wakes across six unchanged polls"
  [ "$bare" -eq 0 ] || fail "dead-agent declared pause surfaced as $bare bare stopped-crew wakes"
  grep -F "awaiting external" "$state/.wake-queue" >/dev/null \
    || fail "dead-agent declared pause did not use the bounded paused recheck"

  dir=$(make_case exited-captain-held); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
  window="test:fm-held"
  printf 'idle bare shell after captain-held transfer\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held.meta"
  printf 'captain-held [key=route]: tracked by held-decision-route\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle bare shell after captain-held transfer")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "captain-held dead-agent pane did not re-surface on the bounded cadence"
  grep -F "awaiting the captain" "$state/.wake-queue" >/dev/null \
    || fail "captain-held dead-agent pane surfaced as a stopped crew instead of a captain-owned recheck: $(cat "$state/.wake-queue")"
  grep -F "awaiting external" "$state/.wake-queue" >/dev/null \
    && fail "captain-held dead-agent pane borrowed the pause verb's external-wait wording"

  dir=$(make_case alive-decision-gate); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/gate.status"
  window="test:fm-gate"
  printf 'idle external-decision gate\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/gate.meta"
  printf 'paused: waiting at an active external-decision gate\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-gate_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle external-decision gate")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  # First sight must surface promptly so a live external-decision gate is not
  # hidden behind the pause cadence.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting at an active external-decision gate' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "live external-decision gate did not surface immediately"
  ack_stopped_cycle "$state" || fail "could not acknowledge the immediate external-decision surface"

  # Re-arm with the stale timer already beyond the wedge threshold. This is the
  # exact unchanged-hash fallback after the immediate surface: it must retain
  # the pause cadence and discard any residual wedge timer instead of emitting
  # a second possible-wedge wake.
  printf '%s\n' $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting at an active external-decision gate' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"
    fail "live external-decision gate escalated on the wedge timer after its immediate surface: $(cat "$out")"
  fi
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "live external-decision gate lost its pause cadence marker"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "live external-decision gate retained the wedge timer"; }
  reap "$pid"
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  bare=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  [ "$wakes" -eq 0 ] || fail "acknowledged external-decision surface replayed $wakes wakes"
  [ "$bare" -eq 0 ] || fail "acknowledged external-decision bare stale remained queued"
  pass "exited declared-pause and captain-held panes use bounded pause cadence while a live decision gate still surfaces once"
}

# A dead worker reaches handle_paused_stale rather than the live fallback above.
# When one declared wait directly replaces another, the existing
# throttle belongs to the old declaration and must not suppress the new wait's
# first inspection merely because its timestamp is still young.
test_absorbed_replacement_wait_does_not_inherit_the_old_throttle() {
  local spec name initial replacement expected dir state fakebin out capture_file
  local statusf window key sig back pid wakes
  for spec in \
    'paused-replacement|paused: waiting on validation run one|paused: waiting on validation run two|awaiting external' \
    'captain-held-replacement|captain-held [key=route]: awaiting the routing call|captain-held [key=release]: awaiting the release call|awaiting the captain'
  do
    name=${spec%%|*}; spec=${spec#*|}
    initial=${spec%%|*}; spec=${spec#*|}
    replacement=${spec%%|*}; expected=${spec#*|}
    dir=$(make_case "$name"); state="$dir/state"; fakebin="$dir/fakebin"
    out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
    window="test:fm-held"
    printf 'idle after agent exit\n' > "$capture_file"
    printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held.meta"
    printf '%s\n' "$initial" > "$statusf"
    back=$(( $(date +%s) - 500 ))
    if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
    else touch -m -d "@$back" "$statusf"; fi
    sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
    key=$(printf '%s' "$window" | tr ':/.' '___')
    printf '%s' "$(hash_text 'idle after agent exit')" > "$state/.hash-$key"
    printf '1\n' > "$state/.count-$key"

    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
      FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
    pid=$!
    wait_for_exit "$pid" 100 || fail "[$name] initial declared wait did not re-surface"
    ack_stopped_cycle "$state" || fail "[$name] could not acknowledge the initial declared wait"

    printf '%s\n' "$replacement" >> "$statusf"
    sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
    printf 'idle after replacement wait\n' > "$capture_file"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
      FM_WATCH_HANDLING_SUCCESSOR=1 \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
      FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
    pid=$!
    wait_for_exit "$pid" 100 \
      || { reap "$pid"; fail "[$name] replacement declared wait inherited the old throttle"; }
    wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' \
      "$state/.wake-queue" 2>/dev/null || echo 0)
    [ "$wakes" -eq 1 ] || fail "[$name] replacement declared wait produced $wakes wakes instead of one"
    grep -F "$expected" "$state/.wake-queue" >/dev/null \
      || fail "[$name] replacement declared wait used the wrong recheck reason: $(cat "$state/.wake-queue")"
  done
  pass "absorbed paused and captain-held replacements each start their own re-surface cadence"
}

# Run one watcher round against a parked-worker fixture, so a round differs only
# in the pane contents the case just wrote. Armed the way fm-watch-arm.sh arms a
# successor after firstmate handled a wake, because that is what a supervision
# turn actually does and it is the only arm that stays in the poll loop instead of
# re-announcing the previous round's downtime - without it a round exits on
# `check: rearm-resurface` before it ever reaches the stale path, and every
# absorb assertion below passes vacuously. A live agent (pane_current_command
# matching the recorded harness) on an idle pane is the exact population
# pause_state_class answers `none` for.
# <mode> `exit` requires the watcher to surface and exit; `absorb` requires it to
# survive whole poll cycles - enough to see the new hash, count it stable, and
# reach the stale path. Returns 1 when the watcher does the other thing.
parked_watch_round() {  # <state> <fakebin> <out> <capture> <window> <exit|absorb>
  local state=$1 fakebin=$2 out=$3 capture=$4 window=$5 mode=$6 pid cycles=0
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_FAKE_CREW_STATE='state: paused · source: status-log · parked' \
    FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
  pid=$!
  if [ "$mode" = exit ]; then
    wait_for_exit "$pid" 100 || { reap "$pid"; return 1; }
    return 0
  fi
  while [ "$cycles" -lt 4 ]; do
    wait_poll_cycle "$state" "$pid" 300 || { reap "$pid"; return 1; }
    cycles=$((cycles + 1))
  done
  reap "$pid"
  return 0
}

# --- a live worker parked on a declared wait: pane churn must not re-alarm ----
# The 2026-08/09 alarm loop, in both observed forms - a worker parked on the
# CAPTAIN (captain-held, five consecutive alarms) and one parked on the PIPELINE
# (paused:, dozens across one day). pause_state_class deliberately returns `none`
# for either while the agent is still ALIVE, so that a worker genuinely waiting on
# a decision is never silenced; first sight of each distinct stale hash therefore
# reaches surface_nonterminal_stale. An idle parked pane still churns its hash (a
# clock, a token counter), so every tick used to re-enter that first-sight path and
# wake firstmate - the throttle was written by the very wake it should have
# prevented, and the hash-change path cleared it again before it was ever read.
# The contract pinned here: the FIRST sight still surfaces, further sights inside
# PAUSE_RESURFACE_SECS are absorbed, and the window's end still re-surfaces once,
# so a forgotten wait cannot rot invisibly.
test_live_declared_wait_churn_honors_the_resurface_throttle() {
  local spec name status_line dir state fakebin out capture_file statusf window key
  local sig round wakes bare text throttle replacement
  for spec in \
    'paused-pipeline-churn|paused: waiting on the validation run to finish' \
    'captain-held-churn|captain-held [key=route]: awaiting the captain on the routing call'
  do
    name=${spec%%|*}; status_line=${spec#*|}
    dir=$(make_case "$name"); state="$dir/state"; fakebin="$dir/fakebin"
    out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/parked.status"
    window="test:fm-parked"
    printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/parked.meta"
    printf '%s\n' "$status_line" > "$statusf"
    sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-parked_status"
    key=$(printf '%s' "$window" | tr ':/.' '___')
    throttle="$state/.paused-resurfaced-$key"

    # First sight of a parked-but-live worker must still surface: the state is
    # inconclusive and firstmate has to look at it.
    text='parked, elapsed 1s'
    printf '%s' "$text" > "$capture_file"
    printf '%s' "$(hash_text "$text")" > "$state/.hash-$key"
    printf '1\n' > "$state/.count-$key"
    parked_watch_round "$state" "$fakebin" "$out" "$capture_file" "$window" exit \
      || fail "[$name] first sight of a parked live worker did not surface"
    ack_stopped_cycle "$state" || fail "[$name] could not acknowledge the first surface"
    [ -e "$throttle" ] || fail "[$name] the first surface recorded no re-surface throttle"

    # The pane now churns while the SAME declared wait stands, each round fully
    # handled as a real supervision turn would. Every one of these used to alarm.
    round=2
    while [ "$round" -le 4 ]; do
      printf 'parked, elapsed %ss' "$round" > "$capture_file"
      parked_watch_round "$state" "$fakebin" "$out" "$capture_file" "$window" absorb \
        || fail "[$name] watcher exited during churn round $round instead of supervising through it"
      wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' \
        "$state/.wake-queue" 2>/dev/null || echo 0)
      [ "$wakes" -eq 0 ] \
        || fail "[$name] pane churn re-alarmed a parked worker $wakes time(s) inside the re-surface window"
      [ -e "$throttle" ] || fail "[$name] pane churn cleared the re-surface throttle"
      round=$((round + 1))
    done

    # A direct wait-to-wait transition starts a NEW declaration even though the
    # same window remains parked. Its first sight must not inherit the previous
    # declaration's throttle, or an unrelated replacement wait can stay silent
    # for nearly the whole old cadence window.
    case "$name" in
      paused-pipeline-churn) replacement='paused: waiting on the replacement validation run' ;;
      captain-held-churn) replacement='captain-held [key=release]: awaiting the captain on the release call' ;;
    esac
    printf '%s\n' "$replacement" >> "$statusf"
    sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-parked_status"
    printf 'replacement wait, elapsed 1s' > "$capture_file"
    parked_watch_round "$state" "$fakebin" "$out" "$capture_file" "$window" exit \
      || fail "[$name] a replacement declared wait inherited the previous wait's re-surface throttle"
    wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' \
      "$state/.wake-queue" 2>/dev/null || echo 0)
    bare=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' \
      "$state/.wake-queue" 2>/dev/null || echo 0)
    [ "$wakes" -eq 1 ] || fail "[$name] replacement declared wait produced $wakes first wakes instead of one"
    [ "$bare" -eq 1 ] || fail "[$name] replacement declared wait changed the wake identity: $(cat "$state/.wake-queue")"
    ack_stopped_cycle "$state" || fail "[$name] could not acknowledge the replacement wait's first surface"

    printf 'replacement wait, elapsed 2s' > "$capture_file"
    parked_watch_round "$state" "$fakebin" "$out" "$capture_file" "$window" absorb \
      || fail "[$name] replacement wait re-alarmed inside its own re-surface window"
    wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' \
      "$state/.wake-queue" 2>/dev/null || echo 0)
    [ "$wakes" -eq 0 ] || fail "[$name] replacement wait re-alarmed $wakes time(s) inside its own re-surface window"

    # End of the window: the wait must re-surface exactly once, on the same plain
    # identity as before, so absorbing churn never becomes silence.
    set_mtime "$(( $(date +%s) - 2000 ))" "$throttle"
    printf 'parked, elapsed 5s' > "$capture_file"
    parked_watch_round "$state" "$fakebin" "$out" "$capture_file" "$window" exit \
      || fail "[$name] a parked worker did not re-surface once its re-surface window elapsed"
    wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' \
      "$state/.wake-queue" 2>/dev/null || echo 0)
    bare=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' \
      "$state/.wake-queue" 2>/dev/null || echo 0)
    [ "$wakes" -eq 1 ] || fail "[$name] elapsed re-surface window produced $wakes wakes instead of one"
    [ "$bare" -eq 1 ] || fail "[$name] elapsed re-surface changed the wake identity: $(cat "$state/.wake-queue")"
  done
  pass "a parked live worker surfaces once, absorbs pane churn for the whole re-surface window, then re-surfaces when it elapses"
}

test_live_paused_until_controls_recheck_time() {
  local dir state fakebin out capture_file statusf window key sig wakes future past
  dir=$(make_case live-paused-until); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/parked.status"
  window="test:fm-parked"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/parked.meta"
  future=$(iso_utc_at "$(( $(date +%s) + 7200 ))")
  printf 'paused: rate limit until %s\n' "$future" > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-parked_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf 'parked, elapsed 1s' > "$capture_file"
  printf '%s' "$(hash_text 'parked, elapsed 1s')" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  parked_watch_round "$state" "$fakebin" "$out" "$capture_file" "$window" absorb \
    || fail "a live worker woke before its declared future time"
  printf 'parked, elapsed 2s' > "$capture_file"
  parked_watch_round "$state" "$fakebin" "$out" "$capture_file" "$window" absorb \
    || fail "pane churn bypassed a live worker's declared future time"
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' \
    "$state/.wake-queue" 2>/dev/null || echo 0)
  [ "$wakes" -eq 0 ] || fail "a live worker produced $wakes wakes before its declared time"

  past=$(iso_utc_at "$(( $(date +%s) - 120 ))")
  printf 'paused: rate limit until %s\n' "$past" >> "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-parked_status"
  printf 'parked, elapsed 3s' > "$capture_file"
  parked_watch_round "$state" "$fakebin" "$out" "$capture_file" "$window" exit \
    || fail "a live worker did not wake when its declared time passed"
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' \
    "$state/.wake-queue" 2>/dev/null || echo 0)
  [ "$wakes" -eq 1 ] || fail "a passed declared time produced $wakes wakes instead of one"
  ack_stopped_cycle "$state" || fail "could not acknowledge the due declared-time recheck"
  printf 'parked, elapsed 4s' > "$capture_file"
  parked_watch_round "$state" "$fakebin" "$out" "$capture_file" "$window" absorb \
    || fail "a due declared time bypassed the reset long cadence"
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' \
    "$state/.wake-queue" 2>/dev/null || echo 0)
  [ "$wakes" -eq 0 ] || fail "a due declared time rechecked again inside the long cadence"
  pass "a live paused worker stays absorbed until its declared time, then rechecks"
}


# --- work the captain is already holding: pane churn must not re-alarm -------
# The other record of a legitimate wait. The declared-wait bound above reads the
# status LINE, and a delivered task's line stays `done: PR ...` while the wait
# itself lives in the BACKLOG, written there by bin/fm-captain-hold.sh. No line
# predicate can see that record, so both stale alarms - the captain-relevant one
# and the inconclusive one - re-fired on every new pane hash for as long as the
# captain was deciding, which is the 2026-09 loop observed on delivered work
# awaiting their merge word.
# Pinned here, in both directions: while the call stands the first sight still
# alarms, further sights of the SAME call and status-log state are absorbed, and
# a new pane hash after the window's end alarms once more; and the identical
# fixture WITHOUT the hold keeps alarming on every hash, because a bound that
# swallowed an unheld delivery or blocker would be worse than the churn it removes.
#
# The backlog is real rather than a fixture file: bin/fm-captain-hold.sh is the
# only writer of a hold and tasks-axi the only reader, so a hand-written row
# would pin this test's idea of a hold instead of the one the watcher consults.
# These four cases require tasks-axi on PATH and fail if it is absent, so a
# missing backlog reader cannot turn unexercised safety checks into a green run.
#
# Cost: every case below drives churn through ONE watcher process rather than
# relaunching per pane change. Watcher startup dominates a round here, and an
# absorbing watcher stays in its poll loop across churn in production anyway, so
# the cheaper shape is also the more faithful one.

# The window key every hold fixture uses, derived the way fm-watch.sh derives it.
hold_key() {
  printf '%s' test:fm-held-merge | tr ':/.' '___'
}

make_hold_home() {  # <name> <status-line> <hold|nohold>
  local name=$1 line=$2 hold=$3 dir state
  dir=$(make_case "$name"); state="$dir/state"
  mkdir -p "$dir/data" "$dir/config"
  fm_test_tasks_toml "$dir/.tasks.toml" || return 1
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  (cd "$dir" && tasks-axi add held-merge 'delivered work' --file data/backlog.md) >/dev/null 2>&1 \
    || return 1
  if [ "$hold" = hold ]; then
    run_hold "$dir" hold held-merge --reason 'awaiting the captain on the merge' || return 1
  fi
  printf 'window=test:fm-held-merge\nkind=ship\nharness=grok\nbackend=tmux\n' \
    > "$state/held-merge.meta"
  printf '%s\n' "$line" > "$state/held-merge.status"
  printf '%s' "$(seen_sig "$state/held-merge.status")" > "$state/.seen-held-merge_status"
  printf '%s\n' "$dir"
}

# Launch one watcher against a hold fixture, armed the way parked_watch_round
# arms one, plus the home the backlog read resolves against. The crew reads
# stopped: a delivered worker's agent has exited, and that is the population
# whose alarm the call must bound. The pid lands in HOLD_WATCH_PID rather than on
# stdout: a command substitution would background the watcher inside a subshell,
# leaving the caller unable to wait on or reap its own watcher.
HOLD_WATCH_PID=
hold_watch_launch() {  # <dir> <out> <capture>
  local dir=$1 out=$2 capture=$3
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW=test:fm-held-merge \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
    FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_HOME="$dir" FM_DATA_OVERRIDE="$dir/data" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_STATE_OVERRIDE="$dir/state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS="${FM_HOLD_PAUSE_RESURFACE_SECS:-999}" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" 2>&1 &
  HOLD_WATCH_PID=$!
}

# One sighting that must surface and exit the cycle.
hold_watch_surface() {  # <dir> <out> <capture> <pane-text>
  local dir=$1 out=$2 capture=$3 text=$4
  printf '%s\n' "$text" > "$capture"
  hold_watch_launch "$dir" "$out" "$capture"
  wait_for_exit "$HOLD_WATCH_PID" 100 || { reap "$HOLD_WATCH_PID"; return 1; }
  return 0
}

# <count> successive pane changes driven through ONE watcher, each given three
# poll cycles: one to see the new hash, one to count it stable and classify, one
# to prove the classification held. The watcher must stay in the loop throughout.
hold_watch_churn() {  # <dir> <out> <capture> <label> <count>
  local dir=$1 out=$2 capture=$3 label=$4 count=$5 i=1 c
  local state="$dir/state"
  printf '%s 0\n' "$label" > "$capture"
  hold_watch_launch "$dir" "$out" "$capture"
  while [ "$i" -le "$count" ]; do
    printf '%s %s\n' "$label" "$i" > "$capture"
    c=0
    while [ "$c" -lt 3 ]; do
      wait_poll_cycle "$state" "$HOLD_WATCH_PID" 300 \
        || { reap "$HOLD_WATCH_PID"; return 1; }
      c=$((c + 1))
    done
    i=$((i + 1))
  done
  reap "$HOLD_WATCH_PID"
  return 0
}

hold_stale_wakes() {  # <state>
  awk -F '\t' '$3 == "stale" && $4 == "test:fm-held-merge" { n++ } END { print n + 0 }' \
    "$1/.wake-queue" 2>/dev/null || echo 0
}

# Both status lines a held task really carries: the delivery that routes through
# the captain-relevant stale branch, and a worker line that routes through the
# inconclusive one. The hold is invisible to the status line in both, so both
# branches had the same blindness and both are covered.
test_open_captain_call_bounds_stale_churn() {
  local spec name line dir state out capture throttle wakes
  command -v tasks-axi >/dev/null 2>&1 \
    || fail "tasks-axi is required (captain-hold stale bound)"
  for spec in \
    'held-delivery|done: PR https://example.invalid/pull/1 checks green' \
    'held-worker-line|working: still tidying the branch'
  do
    name=${spec%%|*}; line=${spec#*|}
    dir=$(make_hold_home "$name" "$line" hold) \
      || fail "[$name] could not build a captain-held backlog fixture"
    state="$dir/state"; out="$dir/watch.out"; capture="$dir/pane.txt"
    throttle="$state/.paused-resurfaced-$(hold_key)"

    # First sight still alarms: the call bounds repetition, never the first look.
    hold_watch_surface "$dir" "$out" "$capture" 'idle, elapsed 1s' \
      || fail "[$name] first sight of held work did not surface"
    wakes=$(hold_stale_wakes "$state")
    [ "$wakes" -eq 1 ] || fail "[$name] first sight produced $wakes wakes instead of one"
    ack_stopped_cycle "$state" || fail "[$name] could not acknowledge the first surface"

    # The pane churns while the SAME call stands. Every one of these alarmed.
    hold_watch_churn "$dir" "$out" "$capture" 'idle, tick' 2 \
      || fail "[$name] watcher exited during pane churn instead of supervising through it: $(cat "$out")"
    wakes=$(hold_stale_wakes "$state")
    [ "$wakes" -eq 0 ] \
      || fail "[$name] pane churn re-alarmed held work $wakes time(s) inside the re-surface window"

    # After the window ends, the next new pane hash re-surfaces held work exactly
    # once, so a forgotten call on a churning pane cannot hide behind the bound.
    [ -e "$throttle" ] || fail "[$name] the absorbed churn recorded no re-surface cadence to elapse"
    set_mtime "$(( $(date +%s) - 5000 ))" "$throttle"
    hold_watch_surface "$dir" "$out" "$capture" 'idle, elapsed 9s' \
      || fail "[$name] held work did not re-surface once its re-surface window elapsed"
    wakes=$(hold_stale_wakes "$state")
    [ "$wakes" -eq 1 ] \
      || fail "[$name] elapsed re-surface window produced $wakes wakes instead of one"
  done
  pass "work under an open captain call surfaces once, absorbs pane churn, then re-surfaces when the window elapses"
}


# The other half of the same bound, and the one that decides whether widening the
# wait was safe: the identical fixtures with NO hold must keep alarming on every
# new hash, on both branches.
test_stale_churn_without_a_captain_call_still_alarms() {
  local spec name line dir state out capture round wakes
  command -v tasks-axi >/dev/null 2>&1 \
    || fail "tasks-axi is required (unheld stale alarm)"
  for spec in \
    'unheld-delivery|done: PR https://example.invalid/pull/1 checks green' \
    'unheld-blocker|blocked: cannot reach the release host' \
    'unheld-worker-line|working: still tidying the branch'
  do
    name=${spec%%|*}; line=${spec#*|}
    dir=$(make_hold_home "$name" "$line" nohold) \
      || fail "[$name] could not build an unheld backlog fixture"
    state="$dir/state"; out="$dir/watch.out"; capture="$dir/pane.txt"
    round=1
    while [ "$round" -le 2 ]; do
      hold_watch_surface "$dir" "$out" "$capture" "idle, elapsed ${round}s" \
        || fail "[$name] an unheld stale window stopped alarming on round $round"
      wakes=$(hold_stale_wakes "$state")
      [ "$wakes" -eq 1 ] \
        || fail "[$name] round $round produced $wakes wakes instead of one"
      ack_stopped_cycle "$state" || fail "[$name] could not acknowledge round $round"
      round=$((round + 1))
    done
  done
  pass "a stale window with no open captain call keeps alarming on every new hash"
}


# The cadence marker may never outlive the wake it claims to record. Recording it
# before publishing the durable wake turned a delayed alarm into a lost one: the
# append fails, the watcher exits with nothing queued, and the next sighting
# reads that fresh marker and absorbs the retry. An unwritable queue is the real
# failure, so it is the one this drives.
test_failed_wake_append_does_not_arm_the_captain_hold_throttle() {
  local dir state out capture wakes rc
  command -v tasks-axi >/dev/null 2>&1 \
    || fail "tasks-axi is required (failed wake append)"
  dir=$(make_hold_home append-failure 'done: PR https://example.invalid/pull/1 checks green' hold) \
    || fail "could not build a captain-held backlog fixture"
  state="$dir/state"; out="$dir/watch.out"; capture="$dir/pane.txt"

  # A directory where the queue file belongs: every append fails, whatever the
  # caller does, so the watcher cannot publish the wake it just decided to send.
  # Its exit code is read directly here because a refusing watcher exits NON-zero,
  # which is the correct outcome and not the "surfaced" one hold_watch_surface means.
  rm -f "$state/.wake-queue"
  mkdir -p "$state/.wake-queue"
  printf 'idle, elapsed 1s\n' > "$capture"
  hold_watch_launch "$dir" "$out" "$capture"
  wait_for_exit "$HOLD_WATCH_PID" 100
  rc=$?
  rmdir "$state/.wake-queue"
  [ "$rc" -ne 124 ] || fail "the watcher did not exit when its durable queue could not be written"
  [ "$rc" -ne 0 ] || fail "the watcher reported success despite an unwritable durable queue"
  [ -e "$state/.paused-resurfaced-$(hold_key)" ] \
    && fail "a wake that never reached the durable queue still armed the re-surface throttle"

  # The retry must alarm: nothing was ever delivered, so nothing may be absorbed.
  hold_watch_surface "$dir" "$out" "$capture" 'idle, elapsed 2s' \
    || fail "the retry after a failed wake append was absorbed instead of alarming"
  wakes=$(hold_stale_wakes "$state")
  [ "$wakes" -eq 1 ] \
    || fail "the retry after a failed wake append produced $wakes wakes instead of one"
  pass "a wake that never reached the durable queue arms no re-surface throttle"
}

# The task id is not the captain call. A task can be answered with `--release`
# and held again as a genuinely different call with NO status append, and binding
# the throttle to the status-log signature alone let the second call inherit the
# first one's silence and absorbed its first sight. That is the one alarm this
# bound must never swallow: a delivery announced twice is noise, but a decision
# waiting on the captain that is never surfaced is invisible.
# Measured at base c499f84 this fixture alarms on every sighting, so the
# suppression was introduced by the bound itself rather than pre-existing.
test_reheld_captain_call_starts_its_own_resurface_window() {
  local dir state out capture wakes
  command -v tasks-axi >/dev/null 2>&1 \
    || fail "tasks-axi is required (re-held captain call)"
  dir=$(make_hold_home reheld-call 'done: PR https://example.invalid/pull/1 checks green' hold) \
    || fail "could not build a captain-held backlog fixture"
  state="$dir/state"; out="$dir/watch.out"; capture="$dir/pane.txt"

  hold_watch_surface "$dir" "$out" "$capture" 'idle, elapsed 1s' \
    || fail "first sight of the first captain call did not surface"
  ack_stopped_cycle "$state" || fail "could not acknowledge the first call's surface"
  hold_watch_churn "$dir" "$out" "$capture" 'idle, tick' 1 \
    || fail "the first call's churn was not absorbed"
  [ "$(hold_stale_wakes "$state")" -eq 0 ] \
    || fail "the first call's churn re-alarmed inside its own window"

  # Answer and release, then re-hold: a second, distinct captain call on the same
  # task id, with no status append, so the status signature cannot tell them apart.
  printf 'go ahead\n' > "$dir/decision.txt"
  run_hold "$dir" answer held-merge --decision-file "$dir/decision.txt" --release \
    || fail "could not record the captain's answer"
  run_hold "$dir" hold held-merge --reason 'awaiting the captain a second time' \
    || fail "could not re-hold the task as a second captain call"

  hold_watch_surface "$dir" "$out" "$capture" 'idle, elapsed 3s' \
    || fail "the second captain call inherited the first call's silence"
  wakes=$(hold_stale_wakes "$state")
  [ "$wakes" -eq 1 ] \
    || fail "the second captain call produced $wakes first wakes instead of one"
  pass "a released-then-re-held task is a distinct captain call whose first sight still alarms"
}


test_secondmate_paused_resurfaces_in_normal_mode() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid back
  dir=$(make_case secondmate-paused-resurface); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/secondmate-held.status"
  window="test:fm-secondmate-held"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-held.meta"
  printf 'paused: awaiting the upstream release\nThe release window opens tomorrow.\n\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-secondmate-held_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream release'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not re-surface a paused secondmate"
  grep -F "stale: $window" "$out" >/dev/null || fail "paused secondmate did not emit a stale recheck"
  grep -F "awaiting external" "$out" >/dev/null || fail "paused secondmate recheck omitted its external-wait reason"
  grep -F "awaiting the captain" "$out" >/dev/null && fail "paused secondmate recheck named the captain instead of its external dependency"
  grep -F "possible wedge" "$out" >/dev/null && fail "paused secondmate was mislabeled a wedge"
  unset FM_FAKE_CREW_STATE
  pass "a declared paused secondmate re-surfaces on the bounded normal-mode cadence"
}

# A captain hold is the other declared wait, but unlike paused: it has no
# current-state mapping, so a held mate reports `unknown` rather than `paused`.
# The bounded re-surface must still reach it, or a mate's hold rots invisibly:
# nothing else re-reads a quiet mate's endpoint.
test_secondmate_captain_held_resurfaces_in_normal_mode() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid back
  dir=$(make_case secondmate-held-resurface); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/secondmate-hold.status"
  window="test:fm-secondmate-hold"
  printf 'idle awaiting the captain\n' > "$capture_file"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-hold.meta"
  printf 'captain-held [key=route]: tracked by task-decision-route\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-secondmate-hold_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  pane_hash=$(hash_text "idle awaiting the captain")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not re-surface a captain-held secondmate"
  grep -F "stale: $window" "$out" >/dev/null || fail "captain-held secondmate did not emit a stale recheck"
  grep -F "awaiting the captain" "$out" >/dev/null || fail "captain-held secondmate recheck did not name the captain as the blocker: $(cat "$out")"
  grep -F "awaiting external" "$out" >/dev/null && fail "captain-held secondmate recheck claimed an external wait"
  grep -F "possible wedge" "$out" >/dev/null && fail "captain-held secondmate was mislabeled a wedge"
  unset FM_FAKE_CREW_STATE
  pass "a captain-held secondmate re-surfaces on the bounded normal-mode cadence"
}

test_secondmate_nonpaused_stale_remains_suppressed() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid
  dir=$(make_case secondmate-stale-suppressed); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/secondmate-working.status"
  window="test:fm-secondmate-working"
  printf 'idle while the parent supervises\n' > "$capture_file"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-working.meta"
  printf 'working: the parent supervises this secondmate\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-secondmate-working_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  pane_hash=$(hash_text "idle while the parent supervises")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher surfaced an ordinary secondmate stale pane: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "ordinary secondmate stale pane printed a wake reason: $(cat "$out")"; }
  reap "$pid"
  pass "a non-paused secondmate retains normal stale suppression"
}

test_secondmate_unpause_clears_pause_tracking() {
  local dir state fakebin out statusf window key pid
  dir=$(make_case secondmate-unpause-clears); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; statusf="$state/secondmate-resumed.status"; window="test:fm-secondmate-resumed"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-resumed.meta"
  printf 'working: upstream landed\n' > "$statusf"
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-secondmate-resumed_status"
  key=${window//:/_}
  key=${key//\//_}
  key=${key//./_}
  : > "$state/.paused-$key"
  : > "$state/.paused-rechecked-$key"
  : > "$state/.paused-resurfaced-$key"
  : > "$state/.stale-$key"
  : > "$state/.stale-since-$key"
  : > "$state/.wedge-escalations-$key"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_poll_cycle "$state" "$pid" || fail "watcher exited while reconciling a resumed secondmate: $(cat "$out")"
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "resumed secondmate retained the pause marker"; }
  [ ! -e "$state/.stale-$key" ] || { reap "$pid"; fail "resumed secondmate retained stale tracking"; }
  [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; fail "resumed secondmate retained wedge tracking"; }
  reap "$pid"
  pass "a resumed secondmate clears pause and stale tracking before stale exemption"
}

test_nonterminal_stale_pause_transitions_reclassify_unchanged_hash() {
  local dir state fakebin out capture_file window key pane_hash sig pid i
  dir=$(make_case nonterminal-stale-pause-transition); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-transition"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/transition.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/transition.status"
  sig=$(seen_sig "$state/transition.status"); printf '%s' "$sig" > "$state/.seen-transition_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s\n' $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream release'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do
    [ -e "$state/.paused-$key" ] && [ ! -e "$state/.stale-since-$key" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "a stale hash that entered pause was wedge-escalated: $(cat "$out")"; }
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "unchanged stale hash did not enter paused mode"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "pause transition retained its wedge timer"; }
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "a stale hash that entered pause was wedge-escalated: $(cat "$out")"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional entered-pause watcher stop"

  printf 'working: upstream landed, resuming\n' > "$state/transition.status"
  sig=$(seen_sig "$state/transition.status"); printf '%s' "$sig" > "$state/.seen-transition_status"
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do
    [ ! -e "$state/.paused-$key" ] && [ -s "$state/.stale-since-$key" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "a stale hash that left pause did not resume wedge tracking: $(cat "$out")"; }
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "unchanged stale hash retained paused mode after resume"; }
  [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "unchanged stale hash did not restart wedge tracking after resume"; }
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "a stale hash that left pause did not resume wedge tracking: $(cat "$out")"; }
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "unchanged stale hashes reclassify when a crew enters or leaves pause"
}

test_nonterminal_paused_rechecks_authoritative_state() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-paused-recheck); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-pause-recheck"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/pause-recheck.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/pause-recheck.status"
  sig=$(seen_sig "$state/pause-recheck.status"); printf '%s' "$sig" > "$state/.seen-pause-recheck_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$state/.paused-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "an active run behind a declared pause surfaced instead of resuming wedge tracking: $(cat "$out")"
  fi
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "authoritative active run retained paused mode"; }
  [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "authoritative active run did not resume wedge tracking"; }
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a declared pause is periodically rechecked against authoritative active-run state"
}

test_paused_authoritative_working_preserves_wedge_timer() {
  local dir state fakebin out capture_file window key pane_hash sig pid since
  dir=$(make_case paused-working-preserves-wedge-timer); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-paused-working"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/paused-working.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/paused-working.status"
  sig=$(seen_sig "$state/paused-working.status"); printf '%s' "$sig" > "$state/.seen-paused-working_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$state/.paused-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_numeric_file "$state/.stale-since-$key" 30 || { reap "$pid"; fail "authoritative working state did not start wedge tracking"; }
  since=$(cat "$state/.stale-since-$key")
  sleep 2
  [ "$(cat "$state/.stale-since-$key" 2>/dev/null || true)" = "$since" ] \
    || { reap "$pid"; fail "repeat authoritative working recheck reset the wedge timer"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional authoritative-working stop"

  # Past the threshold the timer asks whether the pane can explain its own quiet
  # before it escalates, and the worker's declaration is that explanation: the
  # override decides which BOOKKEEPING owns the pane, not whether the wait the
  # worker declared still stands. This is the idle-pane counterpart of the busy
  # pane's declared-wait exception above, which the two paths used to disagree on.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a still-declared wait wedge-escalated past the threshold under a working verdict: $(cat "$out")"
  fi
  reap "$pid"
  grep -F "possible wedge" "$out" >/dev/null \
    && fail "a still-declared wait was reported as a possible wedge: $(cat "$out")"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "a still-declared wait counted $(cat "$state/.wedge-escalations-$key") wedge escalation(s)"

  # Lifting the declaration restores the unchanged escalation, which is what
  # keeps the deferral above from being indistinguishable from no detection.
  printf 'working: resumed after the release landed\n' >> "$state/paused-working.status"
  sig=$(seen_sig "$state/paused-working.status"); printf '%s' "$sig" > "$state/.seen-paused-working_status"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "authoritative working state did not wedge-escalate past the threshold once the declaration was lifted"
  grep -F "possible wedge" "$out" >/dev/null || fail "authoritative working wedge escalation omitted its reason"
  [ ! -e "$state/.stale-since-$key" ] || fail "wedge timer remained after authoritative working escalation"
  unset FM_FAKE_CREW_STATE
  pass "a paused status overridden by authoritative working preserves its wedge timer, is rechecked rather than wedge-escalated while the declaration stands, and escalates once it is lifted"
}

test_captain_held_never_rechecked_while_away_record_exists() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid back
  dir=$(make_case away-record-held-secondmate); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/secondmate-hold.status"
  window="test:fm-secondmate-hold"
  printf 'idle awaiting the captain\n' > "$capture_file"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-hold.meta"
  printf 'captain-held [key=route]: tracked by task-decision-route\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-secondmate-hold_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  pane_hash=$(hash_text "idle awaiting the captain")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  write_away_record "$state"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  # Phase A: the record exists, the hold is well past the cadence, and the
  # watcher still absorbs it across whole poll cycles: no wake, no throttle.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid" || ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher rechecked a captain-held item while the away-posture record exists: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a captain-held recheck was printed while the away-posture record exists"
  [ ! -s "$state/.wake-queue" ] || fail "a captain-held recheck was queued while the away-posture record exists"
  [ ! -e "$state/.paused-resurfaced-$key" ] || fail "the recheck throttle was armed for an item that must never be rechecked"
  grep -F 'never rechecked while the away-posture record exists' "$state/.watch-triage.log" >/dev/null \
    || fail "the silent absorb did not name the away-posture rule in the triage log"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional phase-A stop"
  # Phase B: archiving the record (the return) restores the bounded recheck.
  archive_away_record "$state"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "archiving the away-posture record did not restore the captain-held recheck"; }
  grep -F "awaiting the captain" "$out" >/dev/null || fail "the restored recheck did not name the captain: $(cat "$out")"
  unset FM_FAKE_CREW_STATE
  pass "a captain-held item is never rechecked while the away-posture record exists, and the recheck returns once the record is archived"
}

# Quiet mode's record is a present captain (bin/fm-afk-contract.sh AWAY OR
# QUIET), so it silences nothing: the same hold is rechecked with that record
# live, both on the watcher's own cadence and through the one-shot handoff a
# running quiet daemon owns.
write_quiet_record() {  # <state>
  if ! FM_HOME="$(dirname "$1")" FM_STATE_OVERRIDE="$1" FM_AFK_MODE=quiet "$ROOT/bin/fm-afk-contract.sh" enter --words 'keep routine wakes off my main' >/dev/null 2>&1; then
    fail "could not write quiet mode's record in $1"
  fi
}

test_captain_held_rechecked_under_a_quiet_record() {
  local dir state fakebin out capture_file statusf window key back pid
  dir=$(make_case quiet-record-held); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/secondmate-hold.status"
  window="test:fm-secondmate-hold"
  printf 'idle awaiting the captain\n' > "$capture_file"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-hold.meta"
  printf 'captain-held [key=route]: tracked by task-decision-route\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-secondmate-hold_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  printf '%s' "$(hash_text "idle awaiting the captain")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  write_quiet_record "$state"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a captain-held item was not rechecked beside quiet mode's record"; }
  unset FM_FAKE_CREW_STATE
  grep -F "awaiting the captain" "$out" >/dev/null || fail "the recheck beside a quiet record did not name the captain: $(cat "$out")"
  ! grep -F 'never rechecked while the away-posture record exists' "$state/.watch-triage.log" >/dev/null 2>&1 \
    || fail "quiet mode's record silenced a captain-held item as if the captain were away: $(cat "$state/.watch-triage.log")"
  [ -f "$state/.afk-contract" ] || fail "fixture: quiet mode's record is gone"
  ack_stopped_cycle "$state" || fail "could not acknowledge the captain-held recheck"

  dir=$(make_case quiet-daemon-held-oneshot); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held-afk.status"
  window="test:fm-held-afk"
  printf 'idle awaiting the captain\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held-afk.meta"
  printf 'captain-held [key=route]: tracked by task-decision-route\n' > "$statusf"
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-held-afk_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  printf 'quiet\n' > "$state/.afk"
  write_quiet_record "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "the quiet daemon's one-shot never handed off a captain-held pane"; }
  grep -F "stale: $window" "$state/.wake-queue" >/dev/null \
    || fail "the quiet daemon's one-shot did not queue the captain-held pane for the daemon: $(cat "$state/.wake-queue" 2>/dev/null)"
  pass "quiet mode's record silences no captain-held recheck, on the watcher's cadence or through a quiet daemon's one-shot"
}

test_live_captain_held_first_sight_silenced_by_away_record() {
  local dir state fakebin out capture_file statusf window key sig pid
  dir=$(make_case away-record-held-live); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held-live.status"
  window="test:fm-held-live"
  printf 'parked at the decision gate\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held-live.meta"
  printf 'captain-held [key=route]: tracked by task-decision-route\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held-live_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  write_away_record "$state"
  # A LIVE agent at the gate: without the record pause_state_class answers none
  # and the first sight surfaces (test_exited_declared_pause_is_bounded_but_live_gate_surfaces).
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid" || ! wait_poll_cycle "$state" "$pid" || ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a live captain-held pane surfaced on first sight while the away-posture record exists: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || fail "a live captain-held pane was queued while the away-posture record exists"
  [ -e "$state/.stale-$key" ] || fail "the silenced first sight did not advance the stale suppressor"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a live captain-held pane is absorbed on first sight while the away-posture record exists"
}

test_backlog_hold_never_rechecked_while_away_record_exists() {
  local dir out capture wakes
  command -v tasks-axi >/dev/null 2>&1 \
    || { echo "skip: tasks-axi not found (away-record backlog hold)"; return 0; }
  dir=$(make_hold_home away-record-backlog-hold 'done: PR https://example.test/pr/9 checks green' hold) \
    || fail "could not build the backlog-hold fixture"
  out="$dir/watch.out"; capture="$dir/pane.txt"
  write_away_record "$dir/state"
  # Without the record the FIRST sight of a held delivery alarms
  # (test_stale_churn_without_a_captain_call_still_alarms and its siblings). With
  # it, even the first sight and every later hash are absorbed.
  hold_watch_churn "$dir" "$out" "$capture" 'held delivery, pane tick' 3 \
    || fail "watcher exited while churning a backlog-held delivery under the away-posture record: $(cat "$out")"
  wakes=$(hold_stale_wakes "$dir/state")
  [ "$wakes" -eq 0 ] || fail "a backlog-held delivery was rechecked $wakes time(s) while the away-posture record exists"
  pass "a delivery the captain already holds is never rechecked while the away-posture record exists"
}

test_afk_one_shot_never_hands_off_captain_held_under_away_record() {
  local dir state fakebin out capture_file statusf window key sig pid
  dir=$(make_case away-record-held-afk-oneshot); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held-afk.status"
  window="test:fm-held-afk"
  printf 'idle awaiting the captain\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held-afk.meta"
  printf 'captain-held [key=route]: tracked by task-decision-route\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held-afk_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  date '+%s' > "$state/.afk"
  write_away_record "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid" || ! wait_poll_cycle "$state" "$pid" || ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "the daemon-owned one-shot handed off a captain-held pane while the away-posture record exists: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || fail "the daemon-owned one-shot queued a captain-held pane while the away-posture record exists"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$(hash_text 'idle awaiting the captain')" ] \
    || fail "the silenced one-shot did not advance the stale suppressor to the pane hash"
  reap "$pid"
  pass "the daemon-owned one-shot never hands off a captain-held pane while the away-posture record exists"
}

# --- declared waits are condition-aware: `until <UTC ISO 8601>` --------------
# A paused: line naming when the wait clears is rechecked at that time when it
# falls within the flat cadence, but a distant or mistyped time cannot extend
# the cadence, and a time that has passed is rechecked at once.
paused_until_fixture() {  # <name> <until-epoch> <status-age-secs>
  local name=$1 until=$2 age=$3 dir state statusf window key back
  dir=$(make_case "$name"); state="$dir/state"
  window="test:fm-until"
  statusf="$state/until.status"
  printf 'idle, waiting for the reset\n' > "$dir/pane.txt"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/until.meta"
  printf 'paused: rate limit resets, until %s, then resuming\n' "$(iso_utc_at "$until")" > "$statusf"
  back=$(( $(date +%s) - age ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-until_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  printf '%s' "$(hash_text 'idle, waiting for the reset')" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s\n' "$dir"
}

until_watch() {  # <dir> <cadence> -> pid in UNTIL_PID
  local dir=$1
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW=test:fm-until FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available' \
    FM_STATE_OVERRIDE="$dir/state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS="$2" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch.out" 2>&1 &
  UNTIL_PID=$!
}

test_paused_until_near_future_is_quiet_before_the_cadence() {
  local dir state
  dir=$(paused_until_fixture until-near-future "$(( $(date +%s) + 120 ))" 60); state="$dir/state"
  until_watch "$dir" 240
  if ! wait_poll_cycle "$state" "$UNTIL_PID" || ! wait_poll_cycle "$state" "$UNTIL_PID"; then
    reap "$UNTIL_PID"; fail "a declared wait with a near-future until time was rechecked before that time: $(cat "$dir/watch.out")"
  fi
  [ ! -s "$state/.wake-queue" ] || fail "a declared wait with a near-future until time was queued for a recheck"
  grep -F 'declared time not reached' "$state/.watch-triage.log" >/dev/null \
    || fail "the absorb did not cite the declared time in the triage log"
  reap "$UNTIL_PID"
  pass "a declared wait naming a near-future until time stays quiet until that time"
}

test_paused_until_wrong_year_is_bounded_by_the_cadence() {
  local dir state
  dir=$(paused_until_fixture until-wrong-year "$(( $(date +%s) + 31536000 ))" 300); state="$dir/state"
  until_watch "$dir" 240
  wait_for_exit "$UNTIL_PID" 100 \
    || { reap "$UNTIL_PID"; fail "a wrong-year declared time silenced the wait beyond the recheck cadence"; }
  grep -F 'stale: test:fm-until' "$dir/watch.out" >/dev/null \
    || fail "the bounded wrong-year recheck did not print a stale wake: $(cat "$dir/watch.out")"
  grep -F 'declared time is beyond the recheck cadence' "$dir/watch.out" >/dev/null \
    || fail "the bounded recheck gave the wrong reason: $(cat "$dir/watch.out")"
  grep -F 'declared clearing time has passed' "$dir/watch.out" >/dev/null \
    && fail "the bounded recheck falsely claimed the future declared time passed"
  pass "a wrong-year declared time cannot silence the watcher beyond the recheck cadence"
}

test_paused_until_that_passed_is_rechecked_before_the_cadence() {
  local dir state
  dir=$(paused_until_fixture until-passed "$(( $(date +%s) - 30 ))" 60); state="$dir/state"
  until_watch "$dir" 999
  wait_for_exit "$UNTIL_PID" 100 || { reap "$UNTIL_PID"; fail "a declared wait whose until time passed was not rechecked ahead of the cadence"; }
  grep -F 'stale: test:fm-until' "$dir/watch.out" >/dev/null || fail "the due recheck did not print a stale wake: $(cat "$dir/watch.out")"
  grep -F 'declared clearing time has passed' "$dir/watch.out" >/dev/null \
    || fail "the due recheck did not say the declared time passed: $(cat "$dir/watch.out")"
  grep -F 'possible wedge' "$dir/watch.out" >/dev/null && fail "a due declared wait was mislabeled a possible wedge"
  # The due recheck fires once per declaration: a second watcher on the same
  # unchanged declaration absorbs it again.
  ack_stopped_cycle "$state" || fail "could not acknowledge the due recheck"
  : > "$dir/watch.out"
  until_watch "$dir" 999
  if ! wait_poll_cycle "$state" "$UNTIL_PID" || ! wait_poll_cycle "$state" "$UNTIL_PID"; then
    reap "$UNTIL_PID"; fail "the due recheck repeated on every poll instead of once per declaration: $(cat "$dir/watch.out")"
  fi
  reap "$UNTIL_PID"
  pass "a declared wait whose until time has passed is rechecked at once, then held to the cadence"
}

# --- a live worker paused on its own background job --------------------------
# A worker declared `paused:` on its own background job and the job then ended
# without a new status line, so only the passage of time can tell the watcher
# the wait should be over. Without `until`, the first-sight alert spends the
# declaration's re-surface throttle and every later sight - including the one
# after the job ended - is held for PAUSE_RESURFACE_SECS. Naming the job's
# start plus its timeout as `until` gives that same declaration one recheck once
# the job can no longer be running.
bg_job_paused_case() {  # <name> <status-line> -> dir
  local dir state window key
  dir=$(make_case "$1"); state="$dir/state"; window="test:fm-parked"
  printf 'window=%s\nkind=scout\nharness=grok\nbackend=tmux\n' "$window" > "$state/parked.meta"
  printf '%s\n' "$2" > "$state/parked.status"
  printf '%s' "$(seen_sig "$state/parked.status")" > "$state/.seen-parked_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf 'nightly build running' > "$dir/pane.txt"
  printf '%s' "$(hash_text 'nightly build running')" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s\n' "$dir"
}

bg_job_stale_wakes() {  # <state> -> count of stale wakes queued for the parked window
  awk -F '\t' '$3 == "stale" && $4 == "test:fm-parked" { n++ } END { print n + 0 }' \
    "$1/.wake-queue" 2>/dev/null || echo 0
}

test_paused_bg_job_without_until_stays_silent_after_the_job_ends() {
  local dir state
  dir=$(bg_job_paused_case bg-job-no-until \
    "paused [key=nightly-build] [at=$(date +%s)]: nightly build; resume when the job finishes")
  state="$dir/state"
  parked_watch_round "$state" "$dir/fakebin" "$dir/watch.out" "$dir/pane.txt" test:fm-parked exit \
    || fail "first sight of a worker paused on its background job did not surface"
  ack_stopped_cycle "$state" || fail "could not acknowledge the first-sight alert"
  printf '[bg failed] nightly build - Exited with code 1' > "$dir/pane.txt"
  parked_watch_round "$state" "$dir/fakebin" "$dir/watch.out" "$dir/pane.txt" test:fm-parked absorb \
    || fail "the ended job surfaced although the declaration names no time"
  [ "$(bg_job_stale_wakes "$state")" -eq 0 ] \
    || fail "the ended job surfaced inside the cadence although the declaration names no time"
  pass "without until, a worker paused on its own ended background job is not rechecked inside the cadence"
}

test_paused_bg_job_until_timeout_rechecks_after_the_job_ends() {
  local dir state started
  started=$(date +%s)
  dir=$(bg_job_paused_case bg-job-until-running \
    "paused [key=nightly-build] [at=$started]: nightly build (background job, 600s timeout); resume when it ends, until $(iso_utc_at "$(( started + 600 ))")")
  state="$dir/state"
  parked_watch_round "$state" "$dir/fakebin" "$dir/watch.out" "$dir/pane.txt" test:fm-parked absorb \
    || fail "a worker paused on its running background job woke before the job's timeout"
  [ "$(bg_job_stale_wakes "$state")" -eq 0 ] || fail "the running job surfaced before its timeout"
  started=$(( $(date +%s) - 180 ))
  dir=$(bg_job_paused_case bg-job-until \
    "paused [key=nightly-build] [at=$started]: nightly build (background job, 120s timeout); resume when it ends, until $(iso_utc_at "$(( started + 120 ))")")
  state="$dir/state"
  printf '[bg failed] nightly build - Exited with code 1' > "$dir/pane.txt"
  parked_watch_round "$state" "$dir/fakebin" "$dir/watch.out" "$dir/pane.txt" test:fm-parked exit \
    || fail "the job's timeout passed without a recheck of the worker paused on it"
  [ "$(bg_job_stale_wakes "$state")" -eq 1 ] || fail "the passed timeout queued the wrong number of rechecks"
  awk -F '\t' '$3 == "stale" && $5 == "stale: test:fm-parked" { found = 1 } END { exit !found }' \
    "$state/.wake-queue" || fail "the recheck carried an unexpected reason: $(cat "$state/.wake-queue")"
  case "$(cat "$state/.paused-resurfaced-test_fm-parked" 2>/dev/null)" in
    *:due) ;;
    *) fail "the recheck was not recorded as the passed declared time" ;;
  esac
  ack_stopped_cycle "$state" || fail "could not acknowledge the due recheck"
  printf '[bg failed] nightly build - Exited with code 1 (idle)' > "$dir/pane.txt"
  parked_watch_round "$state" "$dir/fakebin" "$dir/watch.out" "$dir/pane.txt" test:fm-parked absorb \
    || fail "the due recheck repeated instead of returning to the cadence"
  pass "until set to a background job's timeout rechecks the worker paused on it once the job must have ended"
}

test_required_captain_hold_tests_fail_without_tasks_axi() {
  local name out
  out="$TMP_ROOT/missing-tasks-axi.out"
  for name in \
    test_open_captain_call_bounds_stale_churn \
    test_stale_churn_without_a_captain_call_still_alarms \
    test_failed_wake_append_does_not_arm_the_captain_hold_throttle \
    test_reheld_captain_call_starts_its_own_resurface_window
  do
    # Hide only this dependency's discovery in the child, regardless of where
    # the host installed it, while keeping the suite's setup tools available.
    if (
      # shellcheck disable=SC2329 # Exported for dependency discovery in the child Bash.
      command() {
        if [ "$#" -eq 2 ] && [ "$1" = -v ] && [ "$2" = tasks-axi ]; then
          return 1
        fi
        builtin command "$@"
      }
      export -f command
      FM_TEST_ONLY="$name" bash "$ROOT/tests/fm-watch-triage-pause.test.sh"
    ) > "$out" 2>&1; then
      fail "$name passed without required tasks-axi: $(cat "$out")"
    fi
    grep -F 'not ok - tasks-axi is required' "$out" >/dev/null \
      || fail "$name failed without the dependency diagnostic: $(cat "$out")"
    grep -F 'skip:' "$out" >/dev/null \
      && fail "$name skipped a required test: $(cat "$out")"
  done
  pass "all four required captain-hold tests fail when tasks-axi is unavailable"
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
  exit 0
fi

fm_test_run \
  test_required_captain_hold_tests_fail_without_tasks_axi \
  test_nonterminal_stale_not_working_surfaced \
  test_nonterminal_stale_paused_absorbed_then_resurfaced \
  test_exited_declared_pause_is_bounded_but_live_gate_surfaces \
  test_own_work_wait_keeps_first_alert_then_long_cadence \
  test_absorbed_replacement_wait_does_not_inherit_the_old_throttle \
  test_live_declared_wait_churn_honors_the_resurface_throttle \
  test_live_paused_until_controls_recheck_time \
  test_open_captain_call_bounds_stale_churn \
  test_stale_churn_without_a_captain_call_still_alarms \
  test_failed_wake_append_does_not_arm_the_captain_hold_throttle \
  test_reheld_captain_call_starts_its_own_resurface_window \
  test_secondmate_paused_resurfaces_in_normal_mode \
  test_secondmate_captain_held_resurfaces_in_normal_mode \
  test_secondmate_nonpaused_stale_remains_suppressed \
  test_secondmate_unpause_clears_pause_tracking \
  test_nonterminal_stale_pause_transitions_reclassify_unchanged_hash \
  test_nonterminal_paused_rechecks_authoritative_state \
  test_paused_authoritative_working_preserves_wedge_timer \
  test_captain_held_never_rechecked_while_away_record_exists \
  test_live_captain_held_first_sight_silenced_by_away_record \
  test_backlog_hold_never_rechecked_while_away_record_exists \
  test_afk_one_shot_never_hands_off_captain_held_under_away_record \
  test_captain_held_rechecked_under_a_quiet_record \
  test_paused_until_near_future_is_quiet_before_the_cadence \
  test_paused_until_wrong_year_is_bounded_by_the_cadence \
  test_paused_until_that_passed_is_rechecked_before_the_cadence \
  test_paused_bg_job_without_until_stays_silent_after_the_job_ends \
  test_paused_bg_job_until_timeout_rechecks_after_the_job_ends
