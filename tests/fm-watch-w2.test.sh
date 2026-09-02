#!/usr/bin/env bash
# GATE w2 - a wedged pre-cutover TMUX crewmate still raises a stale wake.
#
# THE FLEET IS MIXED, and will be until the drain empties. Every crewmate spawned
# before fm/muxwire-h2 lives in a tmux window whose meta has no `mux=` line, and
# some of them hold unlanded commits. A supervisor that gained herdr sensing by
# losing tmux sensing would have moved the blindness rather than removed it, so
# the old sense is pinned here in its own gate: the text hash, the busy-footer
# suppression, and the drain routing that keeps them reachable.
#
# ROUTING BY THE META, NOT BY THE SHAPE. Both cases below record a tmux target;
# one spells out `mux=tmux` and one predates the seam and records no mux at all.
# Both must take the legacy path, because absence of a herdr marker is exactly
# what the drain means.
#
# Mutation (LEDGER_MUTATE=1): give the wedged pane a busy footer - a correct
# watcher then suppresses the wake and the first assertion fails, proving the
# result comes from the busy detector rather than from the pane being listed.
set -u

# shellcheck source=tests/watch-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-w2)

PANE_TEXT='$ waiting at a prompt'
[ "${LEDGER_MUTATE:-}" = 1 ] && PANE_TEXT='thinking... (esc to interrupt)'

# The fake tmux from herdr-helpers backs capture-pane with $PANE_FILE.
run_tmux_case() {  # <case-dir> <window> <text> [limit]
  local dir=$1 window=$2 text=$3 limit=${4:-300} out="$1/watch.out" pid
  printf '%s\n' "$text" > "$dir/pane.txt"
  : > "$out"
  PATH="$dir/fakebin:$PATH" CALLS="$dir/calls" PANE_FILE="$dir/pane.txt" \
    TMUX_WINDOWS="$window" \
    FM_STATE_OVERRIDE="$dir/state" FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$FM_WATCH" > "$out" 2>"$dir/watch.err" &
  pid=$!
  wait_for_exit "$pid" "$limit" >/dev/null 2>&1 || true
  cat "$out"
}

pane_hash_of() { hash_text "$1"; }

test_a_wedged_tmux_crewmate_still_wakes_the_supervisor() {
  local dir state out
  dir=$(fm_watch_case "$TMP_ROOT" tmuxcrew); state="$dir/state"
  fm_watch_meta "$state" tmuxcrew firstmate:fm-tmuxcrew tmux ship
  fm_watch_prime "$state" firstmate:fm-tmuxcrew "$(pane_hash_of "$PANE_TEXT
")"
  out=$(run_tmux_case "$dir" firstmate:fm-tmuxcrew "$PANE_TEXT")
  printf '%s\n' "$out" | grep -Fx "stale: firstmate:fm-tmuxcrew" >/dev/null \
    || fail "a wedged tmux crewmate raised no stale wake (got: ${out:-<nothing>})"
  pass "w2: a wedged tmux crewmate still raises a stale wake"
}

# The meta that predates the mux= seam entirely. Absence is the drain marker.
test_a_meta_with_no_mux_line_still_takes_the_tmux_sense() {
  local dir state out
  dir=$(fm_watch_case "$TMP_ROOT" legacycrew); state="$dir/state"
  fm_watch_meta "$state" legacycrew firstmate:fm-legacycrew '' ship
  fm_watch_prime "$state" firstmate:fm-legacycrew "$(pane_hash_of '$ waiting at a prompt
')"
  out=$(run_tmux_case "$dir" firstmate:fm-legacycrew '$ waiting at a prompt')
  printf '%s\n' "$out" | grep -Fx "stale: firstmate:fm-legacycrew" >/dev/null \
    || fail "a pre-seam meta was not sensed through tmux (got: ${out:-<nothing>})"
  grep -q 'capture-pane' "$dir/calls" || fail "the legacy sense never captured the pane"
  grep -q '^api snapshot' "$dir/calls" \
    && fail "a draining tmux window was probed with herdr verbs"
  pass "w2: a meta with no mux= line still takes the tmux sense"
}

# The busy footer is the tmux sense's whole suppression mechanism. It has to keep
# working, or the drain fills the captain's terminal with false alarms.
test_a_busy_tmux_pane_is_not_stale() {
  local dir state out
  dir=$(fm_watch_case "$TMP_ROOT" tmuxbusy); state="$dir/state"
  fm_watch_meta "$state" busycrew firstmate:fm-busycrew tmux ship
  fm_watch_prime "$state" firstmate:fm-busycrew "$(pane_hash_of 'thinking... (esc to interrupt)
')"
  out=$(run_tmux_case "$dir" firstmate:fm-busycrew 'thinking... (esc to interrupt)' 40)
  case "$out" in
    *stale*) fail "a busy tmux pane was reported stale: $out" ;;
  esac
  fm_watch_assert_sensed "$state" firstmate:fm-busycrew 2 \
    "the watcher never weighed the busy pane"
  pass "w2: a busy tmux pane raises no stale wake"
}

# THE FIELD-SHIFT TRAP, pinned. A pre-seam meta records no mux= line, so the
# record describing it carries an empty field - and TAB is IFS *whitespace*, so a
# naive `IFS=<tab> read` collapses the run and every later field shifts left: the
# kind is read as the mux and the id as the kind. A draining SECONDMATE then
# loses its exemption and wakes the captain for idling, which is its healthy
# resting state. Asserting it here, on the drain, is where the shift actually
# bites.
test_a_pre_seam_secondmate_keeps_its_exemption() {
  local dir state out
  dir=$(fm_watch_case "$TMP_ROOT" legacysecondmate); state="$dir/state"
  fm_watch_meta "$state" domain firstmate:fm-domain '' secondmate
  fm_watch_prime "$state" firstmate:fm-domain "$(pane_hash_of '$ waiting at a prompt
')"
  out=$(run_tmux_case "$dir" firstmate:fm-domain '$ waiting at a prompt' 40)
  case "$out" in
    *stale*) fail "a draining secondmate lost its exemption: $out" ;;
  esac
  fm_watch_assert_ran "$dir" "the watcher never ran, so the exemption proved nothing"
  pass "w2: a pre-seam meta's kind is still read correctly (secondmate stays exempt)"
}

# THE MIXED FLEET, which is the whole reason this gate is separate from w1. Both
# kinds of crewmate are in flight at once, and each must be sensed with the verbs
# of the surface that minted it: the draining window through capture-pane, and
# the herdr pane NOT through capture-pane. Aiming tmux at a herdr pane id
# resolves to nothing, which reads as an empty pane that never changes - a
# healthy crewmate reported wedged, on a cadence, forever.
test_a_mixed_fleet_senses_each_crewmate_on_its_own_surface() {
  local dir state out
  dir=$(fm_watch_case "$TMP_ROOT" mixedfleet); state="$dir/state"
  fm_watch_meta "$state" drainer firstmate:fm-drainer tmux ship
  fm_watch_meta "$state" herdrcrew wZ:p1 herdr ship
  fm_watch_prime "$state" firstmate:fm-drainer "$(pane_hash_of '$ waiting at a prompt
')"
  fm_watch_prime "$state" wZ:p1 working
  out=$(HERDR_SNAPSHOT_AGENTS='wZ:p1=working' \
    run_tmux_case "$dir" firstmate:fm-drainer '$ waiting at a prompt')
  printf '%s\n' "$out" | grep -Fx "stale: firstmate:fm-drainer" >/dev/null \
    || fail "the draining crewmate did not wake beside a healthy herdr one (got: ${out:-<nothing>})"
  grep -F 'capture-pane -p -t wZ:p1' "$dir/calls" >/dev/null \
    && fail "the herdr crewmate was capture-pane'd; a herdr pane id is not a tmux target"
  grep -F 'capture-pane -p -t firstmate:fm-drainer' "$dir/calls" >/dev/null \
    || fail "the draining crewmate was not sensed through tmux"
  pass "w2: a mixed fleet senses each crewmate on the surface that minted it"
}

test_a_wedged_tmux_crewmate_still_wakes_the_supervisor
test_a_meta_with_no_mux_line_still_takes_the_tmux_sense
test_a_busy_tmux_pane_is_not_stale
test_a_pre_seam_secondmate_keeps_its_exemption
test_a_mixed_fleet_senses_each_crewmate_on_its_own_surface
