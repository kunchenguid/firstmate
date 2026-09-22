#!/usr/bin/env bash
# tests/fm-idle-compact-backstop.test.sh - behavior tests for
# bin/fm-idle-compact.sh's ring backstop (fm_idle_compact_ring_backstop, the
# last line of defence for a worker that was compacted, never rung, and is
# waiting on firstmate rather than on an external event) and the
# idle-duration basis (fm_idle_compact_activity_age: the threshold is
# measured from last activity of any kind, not from the status log alone).
# Split out of the original combined tests/fm-idle-compact.test.sh (see
# tests/idle-compact-helpers.sh) so ShellCheck's extended dataflow analysis
# runs over a bounded file instead of the whole suite at once.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-idle-compact.sh
. "$ROOT/bin/fm-idle-compact.sh"

# shellcheck source=tests/idle-compact-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/idle-compact-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-idle-compact-backstop)

test_backstop_fires_on_a_stale_done_episode_with_no_ring_record() {
  (
    local dir log marker
    dir=$(new_dir backstop-stale)
    log="$dir/sends.log"; : > "$log"
    fm_busy_classify() { printf 'idle claude-hook'; }
    fm_backend_composer_state() { printf 'empty'; }
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    marker=$(arrange_done_declaring_pause "$dir" t1 1800)

    fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'done' ] \
      || fail "the backstop must not disturb the episode phase"
    grep -q 'compacted - start the validation run now' "$log" \
      || fail "a stale phase=done episode over a still-declared pause must be rung"
    grep -q 'ring backstop re-sent' "$dir/state/.idle-compact.log" \
      || fail "the backstop must log, because it firing means the primary path missed"
    pass "fm_idle_compact_ring_backstop: a stale phase=done episode with no ring record is rung and logged"
  ) || exit 1
}

test_backstop_does_not_fire_on_a_fresh_done_episode() {
  (
    local dir log
    dir=$(new_dir backstop-fresh)
    log="$dir/sends.log"; : > "$log"
    fm_busy_classify() { printf 'idle claude-hook'; }
    fm_backend_composer_state() { printf 'empty'; }
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    arrange_done_declaring_pause "$dir" t1 30 >/dev/null

    fm_idle_compact_process_task "$dir/state" t1 30
    [ ! -s "$log" ] \
      || fail "a freshly-rung worker that has simply not taken its turn yet must be left alone"
    pass "fm_idle_compact_ring_backstop: a fresh phase=done episode is left alone"
  ) || exit 1
}

test_backstop_skips_when_the_inbox_already_holds_the_ring() {
  (
    local dir log
    dir=$(new_dir backstop-recorded)
    log="$dir/sends.log"; : > "$log"
    fm_busy_classify() { printf 'idle claude-hook'; }
    fm_backend_composer_state() { printf 'empty'; }
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    arrange_done_declaring_pause "$dir" t1 1800 >/dev/null
    fm_task_inbox_write "$dir/state" t1 "$(fm_idle_compact_ring_message)" >/dev/null

    fm_idle_compact_process_task "$dir/state" t1 30
    [ ! -s "$log" ] \
      || fail "a worker that already holds the ring record must never be sent it twice"
    pass "fm_idle_compact_ring_backstop: an existing ring record in the inbox suppresses the re-send"
  ) || exit 1
}

test_backstop_skips_when_the_ring_was_already_acknowledged() {
  (
    local dir log rec handled
    dir=$(new_dir backstop-handled)
    log="$dir/sends.log"; : > "$log"
    fm_busy_classify() { printf 'idle claude-hook'; }
    fm_backend_composer_state() { printf 'empty'; }
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    arrange_done_declaring_pause "$dir" t1 1800 >/dev/null
    rec=$(fm_task_inbox_write "$dir/state" t1 "$(fm_idle_compact_ring_message)")
    handled=$(fm_task_inbox_handled_dir "$dir/state" t1)
    mkdir -p "$handled" && mv "$rec" "$handled/"

    fm_idle_compact_process_task "$dir/state" t1 30
    [ ! -s "$log" ] \
      || fail "an acknowledged ring in handled/ still proves the worker was rung"
    pass "fm_idle_compact_ring_backstop: an acknowledged ring record in handled/ suppresses the re-send"
  ) || exit 1
}

# Sequence numbers - and so handled/ records - are never reused for a task's
# whole lifetime, so a task that runs a SECOND idle-compact episode keeps the
# first episode's acknowledged ring on disk, same constant body text. A
# second episode whose own ring enqueue genuinely failed must still be rung by
# the backstop; the stale first episode's ring must never satisfy the check.
test_backstop_ignores_a_prior_episodes_acknowledged_ring() {
  (
    local dir log rec handled marker
    dir=$(new_dir backstop-prior-episode)
    log="$dir/sends.log"; : > "$log"
    fm_busy_classify() { printf 'idle claude-hook'; }
    fm_backend_composer_state() { printf 'empty'; }
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600 \
      'paused: awaiting compaction before validation (commit 3985d693a, 1292 changed lines, over-cap accepted)'

    # Episode 1: rang and acknowledged.
    rec=$(fm_task_inbox_write "$dir/state" t1 "$(fm_idle_compact_ring_message)")
    handled=$(fm_task_inbox_handled_dir "$dir/state" t1)
    mkdir -p "$handled" && mv "$rec" "$handled/"

    # Episode 2's settle_epoch (fixed a few seconds ahead so it cannot land in
    # the same wall-clock second as episode 1's `at=` write above, which is
    # the only thing that timestamp comparison needs to tell them apart) is
    # strictly after episode 1's ring was recorded, and its own settling->done
    # ring enqueue genuinely failed - nothing new written to the inbox.
    marker=$(arrange_done_declaring_pause "$dir" t1 1800 "$(( $(date +%s) + 5 ))")

    fm_idle_compact_process_task "$dir/state" t1 30
    grep -q 'compacted - start the validation run now' "$log" \
      || fail "a second episode's genuinely missing ring must not be suppressed by a prior episode's acknowledged, textually identical ring"
    pass "fm_idle_compact_ring_backstop: a prior episode's acknowledged ring never suppresses a later episode's missing ring"
  ) || exit 1
}

test_backstop_fires_at_most_once_per_episode() {
  (
    local dir log marker
    dir=$(new_dir backstop-once)
    log="$dir/sends.log"; : > "$log"
    fm_busy_classify() { printf 'idle claude-hook'; }
    fm_backend_composer_state() { printf 'empty'; }
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    marker=$(arrange_done_declaring_pause "$dir" t1 1800)

    fm_idle_compact_process_task "$dir/state" t1 30
    backdate "$marker" 1800
    fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(wc -l < "$log")" = 1 ] \
      || fail "the backstop must re-send exactly once per episode, not on every later sweep"
    pass "fm_idle_compact_ring_backstop: the re-send happens at most once per episode"
  ) || exit 1
}

test_backstop_ignores_a_status_that_no_longer_declares_the_pause() {
  (
    local dir log marker
    dir=$(new_dir backstop-notdeclared)
    log="$dir/sends.log"; : > "$log"
    fm_busy_classify() { printf 'idle claude-hook'; }
    fm_backend_composer_state() { printf 'empty'; }
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600 'paused: no-mistakes run in progress, clears on its own'
    fm_idle_compact_task_context "$dir/state" t1
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    fm_idle_compact_marker_write "$marker" phase=done \
      "status_sig=$(fm_idle_compact_status_sig "$dir/state" t1)" \
      "pane_sig=$(fm_idle_compact_pane_sig "$FM_IDLE_COMPACT_BACKEND" "$FM_IDLE_COMPACT_TARGET" "$FM_IDLE_COMPACT_LABEL")"
    backdate "$marker" 1800

    fm_idle_compact_process_task "$dir/state" t1 30
    [ ! -s "$log" ] \
      || fail "a worker waiting on a genuine external event must never be rung to start validation"
    pass "fm_idle_compact_ring_backstop: a status declaring some other wait is never rung"
  ) || exit 1
}

# --- the idle-duration basis (fm_idle_compact_activity_age) -----------------
# Requirement 2's threshold is measured from last activity, not from the status
# log alone: AGENTS.md's status-append protocol makes a status line a WAKE
# EVENT, written on wake-worthy transitions, so a crewmate steered back to
# work, doing it, and ending its turn leaves an hours-old status file untouched.

test_recent_turn_end_blocks_eligibility_despite_ancient_status() {
  (
    local dir
    dir=$(new_dir basis-turnend)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 10800 "needs-decision: which gate"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    : > "$dir/state/t1.turn-ended"

    fm_idle_compact_eligible "$dir/state" t1 30 \
      && fail "a crewmate that completed a turn seconds ago is not idle, however old its status log is"
    # ... and once that turn is itself hours old, it is idle again.
    backdate "$dir/state/t1.turn-ended" 10800
    fm_idle_compact_eligible "$dir/state" t1 30 \
      || fail "a crewmate whose newest activity of any kind is hours old must be eligible"
    pass "fm_idle_compact_eligible: the idle threshold is measured from the newest activity (turn-ended), not the status log alone"
  ) || exit 1
}

test_recent_spawn_record_blocks_eligibility() {
  (
    local dir
    dir=$(new_dir basis-meta)
    touch_status "$dir/state" t1 10800
    write_task_meta "$dir/state" t1
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")

    fm_idle_compact_eligible "$dir/state" t1 30 \
      && fail "a just-recorded spawn (a fresh incarnation behind an inherited status log) must not read as idle"
    pass "fm_idle_compact_eligible: a fresh spawn record counts as activity in the idle-duration basis"
  ) || exit 1
}

test_identical_repeated_status_append_ends_the_episode() {
  (
    local dir log marker status_sig pane_sig
    dir=$(new_dir sm-identical-append)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600 "blocked: waiting on the gate"
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    fm_idle_compact_task_context "$dir/state" t1
    status_sig=$(fm_idle_compact_status_sig "$dir/state" t1)
    # shellcheck disable=SC2031  # read within the same subshell that just set it above
    pane_sig=$(fm_idle_compact_pane_sig "$FM_IDLE_COMPACT_BACKEND" "$FM_IDLE_COMPACT_TARGET" "$FM_IDLE_COMPACT_LABEL")
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    fm_idle_compact_marker_write "$marker" phase=done "status_sig=$status_sig" "pane_sig=$pane_sig"

    # A SECOND, textually identical append: a genuinely new status line, and so
    # a genuine reset, even though the last line's text did not change.
    printf 'blocked: waiting on the gate\n' >> "$dir/state/t1.status"

    fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = reset ] \
      || fail "a repeated, textually identical status append is still a new append and must end the episode"
    pass "fm_idle_compact_process_task: a repeated, textually identical status append still ends the episode"
  ) || exit 1
}

# --- run ---------------------------------------------------------------------

test_backstop_fires_on_a_stale_done_episode_with_no_ring_record
test_backstop_does_not_fire_on_a_fresh_done_episode
test_backstop_skips_when_the_inbox_already_holds_the_ring
test_backstop_skips_when_the_ring_was_already_acknowledged
test_backstop_ignores_a_prior_episodes_acknowledged_ring
test_backstop_fires_at_most_once_per_episode
test_backstop_ignores_a_status_that_no_longer_declares_the_pause

test_recent_turn_end_blocks_eligibility_despite_ancient_status
test_recent_spawn_record_blocks_eligibility
test_identical_repeated_status_append_ends_the_episode

echo "all fm-idle-compact-backstop tests passed"
