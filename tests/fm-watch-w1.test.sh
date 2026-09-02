#!/usr/bin/env bash
# GATE w1 - a wedged HERDR crewmate raises a stale wake.
#
# THE GAP THIS CLOSES. fm/muxwire-h2 moved every crewmate onto herdr and left
# fm-watch.sh sensing through tmux, so a herdr pane was invisible to it: a
# crewmate that stopped without reporting was never noticed at all, and the
# captain's first guarantee - that supervision notices a wedged agent - was dead
# for the entire post-cutover fleet.
#
# WHAT "WEDGED" MEANS HERE, and why it is not a guess any more. The tmux sense
# hashes rendered text and calls two identical hashes with no busy footer stale.
# herdr answers the question directly: `agent_status: unknown` is a stopped
# agent. `idle` and `done` are NOT - an agent between turns is idle, and calling
# that stale is the defect gate w6 covers. So this gate pins BOTH halves: unknown
# wakes, idle does not, in the same file, so neither can be "fixed" by breaking
# the other.
#
# ONE CALL, NOT ONE PER CREWMATE: the sense reads `herdr api snapshot` once per
# cycle whatever the fleet width. The call count is asserted, because an O(n)
# rewrite would still pass every behavioural assertion above it.
#
# Mutation (LEDGER_MUTATE=1): report the wedged pane as `idle` instead of
# `unknown` - a correct watcher then raises nothing and the first assertion
# fails, proving the wake is keyed to the state read rather than to the pane
# merely being enumerated.
set -u

# shellcheck source=tests/watch-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-w1)

WEDGED=unknown
[ "${LEDGER_MUTATE:-}" = 1 ] && WEDGED=idle

test_a_wedged_herdr_crewmate_wakes_the_supervisor() {
  local dir state out
  dir=$(fm_watch_case "$TMP_ROOT" wedged); state="$dir/state"
  fm_watch_meta "$state" wedgedcrew wZ:p1 herdr ship
  fm_watch_prime "$state" wZ:p1 "$WEDGED"
  out=$(HERDR_SNAPSHOT_AGENTS="wZ:p1=$WEDGED" fm_watch_run "$dir")
  printf '%s\n' "$out" | grep -Fx "stale: wZ:p1" >/dev/null \
    || fail "a wedged herdr crewmate raised no stale wake (got: ${out:-<nothing>})"
  # The wake is durable, not just printed: a firstmate restarted between the
  # wake and its next turn must still find it.
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" \
    | grep "$(printf '\tstale\t')" | grep -F 'wZ:p1' >/dev/null \
    || fail "the herdr stale wake was not queued durably"
  pass "w1: a wedged herdr crewmate raises a stale wake"
}

# The routing assertion. A herdr pane must be sensed with herdr verbs; reaching
# for tmux capture-pane against a pane id would resolve to nothing and report a
# healthy crewmate wedged, or a wedged one healthy.
test_a_herdr_pane_is_never_sensed_through_tmux() {
  local dir state
  dir=$(fm_watch_case "$TMP_ROOT" routing); state="$dir/state"
  fm_watch_meta "$state" routecrew wZ:p1 herdr ship
  fm_watch_prime "$state" wZ:p1 unknown
  HERDR_SNAPSHOT_AGENTS='wZ:p1=unknown' fm_watch_run "$dir" >/dev/null
  grep -q 'capture-pane' "$dir/calls" \
    && fail "a herdr crewmate was sensed with tmux capture-pane"
  grep -q '^api snapshot' "$dir/calls" \
    || fail "the herdr sense never called api snapshot"
  pass "w1: a herdr crewmate is sensed through herdr, never tmux"
}

# O(1) at any fleet width. Three herdr crewmates, one snapshot.
test_the_fleet_is_read_in_one_call() {
  local dir state n
  dir=$(fm_watch_case "$TMP_ROOT" onecall); state="$dir/state"
  fm_watch_meta "$state" c1 wZ:p1 herdr ship
  fm_watch_meta "$state" c2 wZ:p2 herdr ship
  fm_watch_meta "$state" c3 wZ:p3 herdr ship
  fm_watch_prime "$state" wZ:p3 unknown
  HERDR_SNAPSHOT_AGENTS='wZ:p1=working,wZ:p2=idle,wZ:p3=unknown' fm_watch_run "$dir" >/dev/null
  n=$(grep -c '^api snapshot' "$dir/calls" || true)
  [ "$n" -le 1 ] || fail "the fleet was read $n times in one cycle; the snapshot must be fetched once"
  pass "w1: a whole herdr fleet is sensed in one snapshot call"
}

# An idle agent is BETWEEN TURNS, not abandoned. This is the half of the state
# vocabulary the tmux hash could not express at all.
test_an_idle_herdr_crewmate_is_not_stale() {
  local dir state out
  dir=$(fm_watch_case "$TMP_ROOT" idle); state="$dir/state"
  fm_watch_meta "$state" idlecrew wZ:p1 herdr ship
  fm_watch_prime "$state" wZ:p1 idle
  out=$(HERDR_SNAPSHOT_AGENTS='wZ:p1=idle' fm_watch_run "$dir" 40)
  case "$out" in
    *stale*) fail "an idle herdr crewmate was reported stale: $out" ;;
  esac
  fm_watch_assert_sensed "$state" wZ:p1 2 "the watcher never weighed the idle crewmate"
  pass "w1: an idle herdr crewmate raises no stale wake"
}

# A pane herdr knows nothing about is ORPHAN territory, which this task is
# deliberately not in. Silence, not a wake nobody can act on.
test_a_pane_with_no_agent_raises_nothing() {
  local dir state out
  dir=$(fm_watch_case "$TMP_ROOT" noagent); state="$dir/state"
  fm_watch_meta "$state" gonecrew wZ:p7 herdr ship
  fm_watch_prime "$state" wZ:p7 unknown
  out=$(HERDR_SNAPSHOT_AGENTS='wZ:p1=idle' fm_watch_run "$dir" 40)
  case "$out" in
    *stale*) fail "a pane absent from the snapshot was reported stale: $out" ;;
  esac
  fm_watch_assert_reset "$state" wZ:p7 \
    "the unlisted pane was never reached, or its episode was not ended"
  pass "w1: a pane the snapshot does not list raises nothing (not orphan detection)"
}

# RAISING NOTHING IS NOT REMEMBERING NOTHING. The documented recovery path
# relaunches an agent IN THE SAME PANE, and a pane mid-relaunch holds no agent
# at all - so the wedge/relaunch/wedge sequence passes through the not-listed
# branch above. If that branch carried the first wedge's suppressor across, the
# second wedge would land on a marker that still says "already reported" and the
# crewmate would be invisible for the life of the pane, exactly as it would with
# no clearing at all.
test_a_relaunch_through_no_agent_does_not_poison_the_marker() {
  local dir state out
  dir=$(fm_watch_case "$TMP_ROOT" relaunch); state="$dir/state"
  fm_watch_meta "$state" relaunched wZ:p1 herdr ship
  fm_watch_prime "$state" wZ:p1 unknown
  out=$(HERDR_SNAPSHOT_AGENTS='wZ:p1=unknown' fm_watch_run "$dir")
  printf '%s\n' "$out" | grep -Fx "stale: wZ:p1" >/dev/null \
    || fail "the first wedge did not wake (got: ${out:-<nothing>})"

  # The agent is killed and relaunched: for a while the pane holds no agent, so
  # herdr lists nothing for it. Nothing may wake, and nothing may be remembered.
  out=$(HERDR_SNAPSHOT_AGENTS='wQ:p9=idle' fm_watch_run "$dir" 40)
  case "$out" in *stale*) fail "a pane mid-relaunch was reported stale: $out" ;; esac
  fm_watch_assert_reset "$state" wZ:p1 \
    "the suppressor survived the pane losing its agent; the next wedge is invisible"

  # The relaunched agent comes up already unclassifiable, with no healthy sample
  # in between - the worst ordering, and the one a marker-only fix misses.
  fm_watch_prime "$state" wZ:p1 unknown
  out=$(HERDR_SNAPSHOT_AGENTS='wZ:p1=unknown' fm_watch_run "$dir")
  printf '%s\n' "$out" | grep -Fx "stale: wZ:p1" >/dev/null \
    || fail "a crewmate that wedged, was relaunched and wedged again stayed silent (got: ${out:-<nothing>})"
  pass "w1: a relaunch through no-agent ends the episode instead of poisoning it"
}

# ONCE PER WEDGE, NOT ONCE PER PANE. `.stale-*` means "this stalled episode was
# already reported". Under tmux the observation was a content HASH, so a fresh
# wedge always carried a fresh value and the marker aged out by accident; a herdr
# observation is CATEGORICAL - the literal `unknown` every time. A crewmate that
# wedges, is relaunched INTO THE SAME PANE by stuck-crewmate-recovery, and wedges
# again would otherwise match the marker its first wedge left and stay invisible
# for the life of the pane. That is the guarantee this task exists to restore,
# defeated after one use, so it is pinned here in the same file as the first
# wake.
test_a_recovered_then_rewedged_crewmate_wakes_again() {
  local dir state out
  dir=$(fm_watch_case "$TMP_ROOT" rewedge); state="$dir/state"
  fm_watch_meta "$state" rewedged wZ:p1 herdr ship
  fm_watch_prime "$state" wZ:p1 "$WEDGED"
  out=$(HERDR_SNAPSHOT_AGENTS="wZ:p1=$WEDGED" fm_watch_run "$dir")
  printf '%s\n' "$out" | grep -Fx "stale: wZ:p1" >/dev/null \
    || fail "the first wedge did not wake (got: ${out:-<nothing>})"

  # The agent is relaunched in the same pane and works for a while. One watcher
  # run over a healthy pane, which must end the episode rather than remember it.
  out=$(HERDR_SNAPSHOT_AGENTS='wZ:p1=working' fm_watch_run "$dir" 40)
  case "$out" in *stale*) fail "a working crewmate woke: $out" ;; esac
  [ "$(cat "$state/.hash-wZ_p1" 2>/dev/null)" = working ] \
    || fail "the watcher never sensed the recovered crewmate; the silence proves nothing"

  # And now it wedges again, in that same pane, on the same categorical state.
  out=$(HERDR_SNAPSHOT_AGENTS="wZ:p1=$WEDGED" fm_watch_run "$dir")
  printf '%s\n' "$out" | grep -Fx "stale: wZ:p1" >/dev/null \
    || fail "the SECOND wedge on the same pane was suppressed forever (got: ${out:-<nothing>})"
  pass "w1: a recovered-then-rewedged crewmate wakes again, not once per pane"
}

# THE PIN HAS TO REACH THE VERB, not just the reachability probe. Every herdr
# verb takes its session from $HERDR_SESSION and defaults to `default`, and
# `api snapshot` reports the agents of THAT session - so a watcher that skipped
# fm_herdr_session would poll `default` while the fleet ran under a pinned name,
# find none of its own panes, and go blind through the silent not-listed path
# rather than through an error anyone could see.
test_the_session_pin_reaches_the_snapshot() {
  local dir state out
  dir=$(fm_watch_case "$TMP_ROOT" pinned); state="$dir/state"
  fm_watch_meta "$state" pinnedcrew wZ:p1 herdr ship
  fm_watch_prime "$state" wZ:p1 unknown
  out=$(FM_HERDR_SESSION=captainpin HERDR_SNAPSHOT_SESSION=captainpin \
        HERDR_SNAPSHOT_AGENTS='wZ:p1=unknown' fm_watch_run "$dir")
  printf '%s\n' "$out" | grep -Fx "stale: wZ:p1" >/dev/null \
    || fail "a session-pinned fleet was polled through the wrong session; every pane read as absent (got: ${out:-<nothing>})"
  pass "w1: FM_HERDR_SESSION reaches the snapshot verb, not just the probe"
}

test_a_wedged_herdr_crewmate_wakes_the_supervisor
test_a_recovered_then_rewedged_crewmate_wakes_again
test_the_session_pin_reaches_the_snapshot
test_a_herdr_pane_is_never_sensed_through_tmux
test_the_fleet_is_read_in_one_call
test_an_idle_herdr_crewmate_is_not_stale
test_a_pane_with_no_agent_raises_nothing
test_a_relaunch_through_no_agent_does_not_poison_the_marker
