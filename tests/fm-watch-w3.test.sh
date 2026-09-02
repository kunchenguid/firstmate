#!/usr/bin/env bash
# GATE w3 - an idle kind=secondmate herdr pane raises no stale wake.
#
# A SECONDMATE IDLING IS HEALTHY, and that is its designed resting state: it is a
# full firstmate in its own home, sitting on its own watcher, acting only on work
# the main firstmate routes to it. An empty queue is not a stall. Its parent
# supervises it through status writes and the heartbeat review, never through
# pane-idle staleness - and the exception predates the herdr cutover, so the
# cutover must not quietly drop it while moving the sense underneath.
#
# NARROW BY DESIGN. The same file pins the other side: an ordinary ship crewmate
# in the identical wedged state DOES wake. Without that half, deleting the whole
# stale sense would pass this gate.
#
# Mutation (LEDGER_MUTATE=1): record the secondmate as kind=ship - a correct
# watcher then wakes on it and the silence assertion fails, proving the exception
# is keyed to the recorded kind and not to secondmates happening to be quiet.
set -u

# shellcheck source=tests/watch-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-w3)

SM_KIND=secondmate
[ "${LEDGER_MUTATE:-}" = 1 ] && SM_KIND=ship

# The state that would wake an ordinary crewmate, on a pane recorded as a
# secondmate. Nothing may come of it.
test_an_idle_secondmate_pane_raises_nothing() {
  local dir state out
  dir=$(fm_watch_case "$TMP_ROOT" secondmate); state="$dir/state"
  fm_watch_meta "$state" smhome wZ:p4 herdr "$SM_KIND"
  fm_watch_prime "$state" wZ:p4 unknown
  out=$(HERDR_SNAPSHOT_AGENTS='wZ:p4=unknown' fm_watch_run "$dir" 40)
  case "$out" in
    *stale*) fail "an idle secondmate pane raised a stale wake: $out" ;;
  esac
  fm_watch_assert_ran "$dir" "the watcher never ran, so the exemption proved nothing"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" | grep -q 'stale' \
    && fail "a secondmate stale wake was queued even though none was printed"
  pass "w3: an idle kind=secondmate herdr pane raises no stale wake"
}

# The exception must stay an exception. Same surface, same state, ordinary kind.
test_an_ordinary_crewmate_in_the_same_state_does_wake() {
  local dir state out
  dir=$(fm_watch_case "$TMP_ROOT" ordinary); state="$dir/state"
  fm_watch_meta "$state" shipcrew wZ:p4 herdr ship
  fm_watch_prime "$state" wZ:p4 unknown
  out=$(HERDR_SNAPSHOT_AGENTS='wZ:p4=unknown' fm_watch_run "$dir")
  printf '%s\n' "$out" | grep -Fx "stale: wZ:p4" >/dev/null \
    || fail "the secondmate exception swallowed an ordinary crewmate's stale wake (got: ${out:-<nothing>})"
  pass "w3: an ordinary crewmate in the identical state still wakes"
}

# A secondmate never stops being one because a sibling crewmate is wedged: the
# exception is per-target, not per-fleet.
test_the_exception_is_per_target() {
  local dir state out
  dir=$(fm_watch_case "$TMP_ROOT" mixed); state="$dir/state"
  fm_watch_meta "$state" smhome wZ:p4 herdr "$SM_KIND"
  fm_watch_meta "$state" shipcrew wZ:p5 herdr ship
  fm_watch_prime "$state" wZ:p4 unknown
  fm_watch_prime "$state" wZ:p5 unknown
  out=$(HERDR_SNAPSHOT_AGENTS='wZ:p4=unknown,wZ:p5=unknown' fm_watch_run "$dir")
  printf '%s\n' "$out" | grep -Fx "stale: wZ:p5" >/dev/null \
    || fail "the crewmate beside a secondmate did not wake (got: ${out:-<nothing>})"
  case "$out" in
    *wZ:p4*) fail "the secondmate woke alongside its sibling: $out" ;;
  esac
  # And the exemption has to be decided on the surface the panes actually live
  # on. A tmux capture-pane aimed at a herdr pane id resolves to nothing, which
  # looks like an unchanging pane - so the exemption could hold there for a
  # reason that has nothing to do with the recorded kind.
  grep -q 'capture-pane' "$dir/calls" \
    && fail "herdr panes were sensed through tmux; the exemption was decided on the wrong surface"
  pass "w3: the secondmate exception applies per target, not per fleet"
}

test_an_idle_secondmate_pane_raises_nothing
test_an_ordinary_crewmate_in_the_same_state_does_wake
test_the_exception_is_per_target
