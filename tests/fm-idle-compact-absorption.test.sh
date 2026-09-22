#!/usr/bin/env bash
# tests/fm-idle-compact-absorption.test.sh - behavior tests for
# bin/fm-idle-compact.sh's induced-turn absorption
# (fm_idle_compact_absorbs_signal), the episode-scoped, one-shot-per-send
# exemption bin/fm-watch.sh's signal triage asks this owner about. The
# watcher-side behavior (a wake really is suppressed, and a non-induced
# turn-end in the same window really does still wake) is proven end to end
# against a live watcher in tests/fm-watch-triage.test.sh; these cover the
# predicate's own arms. Split out of the original combined
# tests/fm-idle-compact.test.sh (see tests/idle-compact-helpers.sh) so
# ShellCheck's extended dataflow analysis runs over a bounded file instead of
# the whole suite at once.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-idle-compact.sh
. "$ROOT/bin/fm-idle-compact.sh"

# shellcheck source=tests/idle-compact-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/idle-compact-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-idle-compact-absorption)

test_absorbs_the_induced_turn_exactly_once() {
  (
    local dir state marker now
    dir=$(new_dir absorb-once); state="$dir/state"
    write_task_meta "$state" t1
    now=$(date +%s)
    marker=$(arm_induced_turn "$state" t1 "$((now - 5))")

    fm_idle_compact_absorbs_signal "$state" "$state/t1.turn-ended" \
      || fail "the turn-end induced by this episode's own save message must be absorbed"
    [ -n "$(fm_idle_compact_marker_field "$marker" absorbed_turnended)" ] \
      || fail "the absorbed turn's signature must be recorded on the episode marker"

    # The watcher scans twice across its signal grace window: re-seeing the
    # SAME signature is the same turn, not a second one.
    fm_idle_compact_absorbs_signal "$state" "$state/t1.turn-ended" \
      || fail "re-seeing the same absorbed signature must stay absorbed (idempotent)"

    # A LATER turn-end in the same episode window is real crew work and must
    # wake the captain normally - this fence is the safety case for the whole
    # exemption.
    set_mtime_epoch "$state/t1.turn-ended" "$now"
    fm_idle_compact_absorbs_signal "$state" "$state/t1.turn-ended" \
      && fail "a SECOND turn-end in the same episode window is not induced and must still wake"
    pass "fm_idle_compact_absorbs_signal: exactly one turn per induced send is absorbed; a later turn-end still wakes"
  ) || exit 1
}

test_never_absorbs_a_status_signal() {
  (
    local dir state now
    dir=$(new_dir absorb-status); state="$dir/state"
    write_task_meta "$state" t1
    now=$(date +%s)
    arm_induced_turn "$state" t1 "$((now - 5))" >/dev/null
    printf 'blocked: gate is red\n' > "$state/t1.status"

    fm_idle_compact_absorbs_signal "$state" "$state/t1.status" \
      && fail "a status append is the crew's own captain-facing report and must never be absorbed"
    pass "fm_idle_compact_absorbs_signal: a status append is never absorbed, even mid-episode"
  ) || exit 1
}

test_absorbs_nothing_outside_an_in_flight_episode() {
  (
    local dir state marker now phase
    dir=$(new_dir absorb-expired); state="$dir/state"
    write_task_meta "$state" t1
    now=$(date +%s)
    marker=$(arm_induced_turn "$state" t1 "$((now - 5))")

    rm -f "$marker"
    fm_idle_compact_absorbs_signal "$state" "$state/t1.turn-ended" \
      && fail "with no episode marker at all, nothing may be absorbed (the feature-off case)"

    for phase in 'done' reset; do
      fm_idle_compact_marker_write "$marker" "phase=$phase"
      fm_idle_compact_absorbs_signal "$state" "$state/t1.turn-ended" \
        && fail "a finished episode (phase=$phase) must absorb nothing - the exemption expires with it"
    done

    # An in-flight episode whose send is older than the bound the state machine
    # abandons a never-completing save turn on has expired too.
    fm_idle_compact_marker_write "$marker" phase=save-sent \
      "sent_epoch=$((now - 5000))" "baseline_turnended="
    fm_idle_compact_absorbs_signal "$state" "$state/t1.turn-ended" \
      && fail "a turn-end past FM_IDLE_COMPACT_SAVE_TIMEOUT_SECS from its send is no longer provably induced"
    pass "fm_idle_compact_absorbs_signal: the exemption expires with the episode and with its send window"
  ) || exit 1
}

test_does_not_absorb_while_a_sweep_holds_the_lock() {
  (
    local dir state marker lock holder_pid now
    dir=$(new_dir absorb-lockheld); state="$dir/state"
    write_task_meta "$state" t1
    now=$(date +%s)
    marker=$(arm_induced_turn "$state" t1 "$((now - 5))")

    # The signal path runs from the watcher's triage loop, not from the sweep,
    # so a concurrent supervisor (a DIFFERENT live pid - the same pid would
    # take fm_lock_try_acquire's self-held reclaim path) can be mid-sweep on
    # this very marker. Its write and this one must not interleave.
    lock=$(fm_idle_compact_lock_path "$state")
    ( fm_lock_try_acquire "$lock" && sleep 30 ) &
    holder_pid=$!
    for _ in $(seq 1 50); do
      [ -L "$lock" ] && break
      sleep 0.1
    done
    [ -L "$lock" ] || fail "fixture: background holder never acquired the sweep lock"

    fm_idle_compact_absorbs_signal "$state" "$state/t1.turn-ended" \
      && { kill "$holder_pid" 2>/dev/null; fail "a turn-end must not be absorbed while a sweep holds the marker's lock"; }
    [ -z "$(fm_idle_compact_marker_field "$marker" absorbed_turnended)" ] \
      || { kill "$holder_pid" 2>/dev/null; fail "a locked-out absorption must not have rewritten the episode marker"; }

    kill "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true

    # Released, the same signal is absorbed as before - the lock defers the
    # decision, it does not discard the episode.
    fm_idle_compact_absorbs_signal "$state" "$state/t1.turn-ended" \
      || fail "once the sweep lock is released the induced turn-end must be absorbed again"
    pass "fm_idle_compact_absorbs_signal: a sweep holding the idle-compact lock defers absorption instead of racing its marker write"
  ) || exit 1
}

test_does_not_absorb_over_an_unannounced_earlier_turn_end() {
  (
    local dir state now
    dir=$(new_dir absorb-unannounced); state="$dir/state"
    write_task_meta "$state" t1
    now=$(date +%s)
    arm_induced_turn "$state" t1 "$((now - 5))" >/dev/null
    # A turn-end the watcher never surfaced is still pending on this file, so
    # the recorded baseline no longer matches the .seen-* suppressor: the
    # signal is not provably ours and must wake.
    prime_seen "$state" "$state/t1.turn-ended" "0:1"

    fm_idle_compact_absorbs_signal "$state" "$state/t1.turn-ended" \
      && fail "an unannounced earlier turn-end on the same file must block absorption (fail toward waking)"
    pass "fm_idle_compact_absorbs_signal: an unannounced earlier turn-end blocks absorption"
  ) || exit 1
}

# --- run ---------------------------------------------------------------------

test_absorbs_the_induced_turn_exactly_once
test_never_absorbs_a_status_signal
test_absorbs_nothing_outside_an_in_flight_episode
test_does_not_absorb_while_a_sweep_holds_the_lock
test_does_not_absorb_over_an_unannounced_earlier_turn_end

echo "all fm-idle-compact-absorption tests passed"
