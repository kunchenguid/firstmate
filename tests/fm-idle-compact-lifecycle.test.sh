#!/usr/bin/env bash
# tests/fm-idle-compact-lifecycle.test.sh - behavior tests for the second
# half of bin/fm-idle-compact.sh's 4-phase marker state machine
# (fm_idle_compact_process_task): save-sent waiting on the induced turn-end,
# the settling window and its post-render baseline capture, the save-timeout
# abandon path, and the phase=done reset triggers (status change, repeated
# identical append, pane change) plus the reset-stamp holdoff. Split out of
# the original combined tests/fm-idle-compact.test.sh (see
# tests/idle-compact-helpers.sh) so ShellCheck's extended dataflow analysis
# runs over a bounded file instead of the whole suite at once.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-idle-compact.sh
. "$ROOT/bin/fm-idle-compact.sh"

# shellcheck source=tests/idle-compact-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/idle-compact-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-idle-compact-lifecycle)

test_savesent_no_turnended_yet_stays_savesent() {
  (
    local dir log marker
    dir=$(new_dir sm-waiting)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    fm_idle_compact_marker_write "$marker" phase=save-sent "sent_epoch=$(date +%s)" "baseline_turnended="

    fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = save-sent ] \
      || fail "with no new turn-ended signature, the marker must stay phase=save-sent"
    [ ! -s "$log" ] || fail "/compact must not be sent before the save turn completes"
    pass "fm_idle_compact_process_task: phase=save-sent waits for a new turn-ended signature before compacting"
  ) || exit 1
}

test_savesent_turnended_advanced_sends_compact_and_marks_settling() {
  (
    local dir log marker
    dir=$(new_dir sm-advance)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    fm_idle_compact_marker_write "$marker" phase=save-sent "sent_epoch=$(date +%s)" "baseline_turnended="
    touch "$dir/state/t1.turn-ended"

    fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = settling ] \
      || fail "a new turn-ended signature must advance the marker to phase=settling"
    case "$(fm_idle_compact_marker_field "$marker" settle_epoch)" in
      ''|*[!0-9]*) fail "phase=settling must record a numeric settle_epoch" ;;
    esac
    [ "$(wc -l < "$log")" = 1 ] || fail "exactly one send (the /compact message) must have gone out"
    [ "$(cut -f2 "$log")" = t1 ] || fail "the send must target task t1"
    case "$(cut -f3 "$log")" in
      '/compact '*) ;;
      *) fail "the sent message must be a literal /compact command with focus text" ;;
    esac
    grep -q "brief.md" "$log" || fail "the /compact focus text must point at the brief"
    grep -q "precompact-notes.md" "$log" || fail "the /compact focus text must point at the precompact notes"
    pass "fm_idle_compact_process_task: a completed save turn sends /compact with focus text and records phase=settling"
  ) || exit 1
}

test_savesent_turnended_advanced_but_unsafe_defers() {
  (
    local dir log marker
    dir=$(new_dir sm-advance-unsafe)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    log="$dir/sends.log"; : > "$log"
    fm_busy_classify() { printf 'busy claude-hook'; }
    fm_backend_composer_state() { printf 'empty'; }
    stub_recording_send "$log"
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    fm_idle_compact_marker_write "$marker" phase=save-sent "sent_epoch=$(date +%s)" "baseline_turnended="
    touch "$dir/state/t1.turn-ended"

    fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = save-sent ] \
      || fail "a completed save turn into a now-busy pane must not advance past save-sent"
    [ ! -s "$log" ] || fail "/compact must never be sent while the pane reads busy"
    pass "fm_idle_compact_process_task: a completed save turn into an unsafe pane defers /compact to a later sweep"
  ) || exit 1
}

test_savesent_turnended_advanced_but_crew_working_defers() {
  (
    local dir log marker
    dir=$(new_dir sm-advance-midtask)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: working")
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    fm_idle_compact_marker_write "$marker" phase=save-sent "sent_epoch=$(date +%s)" "baseline_turnended="
    touch "$dir/state/t1.turn-ended"

    fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = save-sent ] \
      || fail "a save-wait interrupted by new work (crew state working) must not advance past save-sent"
    [ ! -s "$log" ] || fail "/compact must never be sent while the reconciled crew state reads working, even between turns"
    pass "fm_idle_compact_process_task: a turn-ended advance from unrelated mid-task work never triggers /compact (eligibility is re-checked)"
  ) || exit 1
}

test_settling_within_window_defers_capture() {
  (
    local dir log marker
    dir=$(new_dir sm-settling-wait)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    fm_idle_compact_marker_write "$marker" phase=settling "settle_epoch=$(date +%s)"

    FM_IDLE_COMPACT_SETTLE_SECS=3600 fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = settling ] \
      || fail "inside the settle window the marker must stay phase=settling (no baseline captured yet)"
    [ -z "$(fm_idle_compact_marker_field "$marker" pane_sig)" ] \
      || fail "no pane signature may be captured before the compaction render has settled"
    [ ! -s "$log" ] || fail "phase=settling must never send anything"
    pass "fm_idle_compact_process_task: phase=settling inside the settle window defers baseline capture to a later sweep"
  ) || exit 1
}

test_settling_past_window_records_done_and_next_sweep_is_noop() {
  (
    local dir log marker status_sig pane_sig
    dir=$(new_dir sm-settling-done)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    # settle_epoch long past: by now the compaction summary has rendered, so
    # the pane content captured below already includes it.
    fm_idle_compact_marker_write "$marker" phase=settling "settle_epoch=1"

    FM_IDLE_COMPACT_SETTLE_SECS=1 fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'done' ] \
      || fail "past the settle window the marker must advance to phase=done"
    fm_idle_compact_task_context "$dir/state" t1
    status_sig=$(fm_idle_compact_status_sig "$dir/state" t1)
    # shellcheck disable=SC2031  # read within the same subshell that just set it above
    pane_sig=$(fm_idle_compact_pane_sig "$FM_IDLE_COMPACT_BACKEND" "$FM_IDLE_COMPACT_TARGET" "$FM_IDLE_COMPACT_LABEL")
    [ "$(fm_idle_compact_marker_field "$marker" status_sig)" = "$status_sig" ] \
      || fail "phase=done must record the CURRENT (post-render) status signature"
    [ "$(fm_idle_compact_marker_field "$marker" pane_sig)" = "$pane_sig" ] \
      || fail "phase=done must record the CURRENT (post-render) pane signature"
    [ ! -s "$log" ] || fail "settling into phase=done must never send anything"

    # The self-trigger regression: the very next sweep sees its own baseline
    # as unchanged and must NOT start a new save+compact episode.
    fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'done' ] \
      || fail "the sweep after settling must keep phase=done, not restart the episode"
    [ ! -s "$log" ] || fail "the compaction's own settled output must never re-trigger a save message"
    pass "fm_idle_compact_process_task: the post-render baseline is captured at settle expiry and the episode never self-triggers"
  ) || exit 1
}

test_savesent_timeout_abandons_without_compact() {
  (
    local dir log marker
    dir=$(new_dir sm-timeout)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    # sent long ago, save turn never completed (no turn-ended touch)
    fm_idle_compact_marker_write "$marker" phase=save-sent "sent_epoch=1" "baseline_turnended="

    FM_IDLE_COMPACT_SAVE_TIMEOUT_SECS=1 fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'done' ] \
      || fail "a save turn that never completes must be abandoned to phase=done past the timeout"
    [ ! -s "$log" ] || fail "an abandoned episode must never send /compact"
    case "$(fm_idle_compact_marker_field "$marker" settle_epoch)" in
      ''|*[!0-9]*) fail "the abandon path must stamp a numeric settle_epoch so the ring backstop scopes to this episode" ;;
    esac
    pass "fm_idle_compact_process_task: a save turn that never completes is abandoned past FM_IDLE_COMPACT_SAVE_TIMEOUT_SECS, without ever sending /compact, and stamps settle_epoch"
  ) || exit 1
}

test_done_unchanged_signatures_is_noop() {
  (
    local dir log marker status_sig pane_sig
    dir=$(new_dir sm-done-noop)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
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

    fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'done' ] \
      || fail "unchanged status and pane signatures must leave the marker at phase=done"
    [ ! -s "$log" ] || fail "an unchanged phase=done episode must never send anything again"
    pass "fm_idle_compact_process_task: phase=done with unchanged status/pane signatures is a pure no-op (already compacted this episode)"
  ) || exit 1
}

test_done_status_change_clears_marker_and_restarts_episode() {
  (
    local dir log marker status_sig pane_sig
    dir=$(new_dir sm-done-restart)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
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

    # A new status append ends the episode. The append is fresh (a real crew
    # writes one now, not an hour ago), so the sweep that observes it must
    # stamp the reset and start no new episode yet.
    printf 'blocked: new episode\n' >> "$dir/state/t1.status"

    fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = reset ] \
      || fail "a new status append must end the episode and leave a phase=reset activity stamp"
    [ ! -s "$log" ] || fail "a crewmate that just appended a status must not be sent anything on that same sweep"

    # One full idle window later - with nothing further from the crew - the
    # stamp has aged out and the next episode starts.
    backdate "$marker" 3600
    backdate "$dir/state/t1.status" 3600
    fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = save-sent ] \
      || fail "once the reset stamp has aged past the threshold, a fresh episode must start"
    [ "$(wc -l < "$log")" = 1 ] || fail "a fresh episode must send exactly one new save message"
    pass "fm_idle_compact_process_task: a new status append ends the episode and the next one waits out a full fresh idle window"
  ) || exit 1
}

test_reset_stamp_holds_off_a_new_episode_for_a_full_window() {
  (
    local dir log marker
    dir=$(new_dir sm-reset-holdoff)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 7200
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    # Pane activity was observed a minute ago: the status log is ancient, but
    # this crewmate is not idle - its cache is warm and compacting it now is
    # exactly the waste this feature exists to avoid.
    fm_idle_compact_marker_write "$marker" phase=reset
    backdate "$marker" 60

    fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = reset ] \
      || fail "a fresh reset stamp must keep holding off the next episode"
    [ ! -s "$log" ] || fail "an ancient status log must not make a just-active crewmate eligible"
    pass "fm_idle_compact_process_task: a fresh pane-activity reset stamp holds off the next episode for a full idle window"
  ) || exit 1
}

test_done_pane_change_clears_marker() {
  (
    local dir log marker status_sig
    dir=$(new_dir sm-done-panechange)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    log="$dir/sends.log"; : > "$log"
    fm_busy_classify() { printf 'idle claude-hook'; }
    fm_backend_composer_state() { printf 'empty'; }
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: working")
    fm_idle_compact_task_context "$dir/state" t1
    status_sig=$(fm_idle_compact_status_sig "$dir/state" t1)
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    fm_idle_compact_marker_write "$marker" phase=done "status_sig=$status_sig" "pane_sig=stale-pane-sig"

    # Status unchanged, but pane content changed (fm_backend_capture output
    # differs from the fixed stale_pane_sig recorded above) - reconcile as
    # "not eligible right now" (crew state is 'working'), which still must
    # clear the stale marker rather than silently keep it.
    fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = reset ] \
      || fail "a changed pane signature must end the phase=done episode even when the crew is not currently eligible"
    pass "fm_idle_compact_process_task: a changed pane signature alone ends phase=done, independent of status"
  ) || exit 1
}

# --- run ---------------------------------------------------------------------

test_savesent_no_turnended_yet_stays_savesent
test_savesent_turnended_advanced_sends_compact_and_marks_settling
test_savesent_turnended_advanced_but_unsafe_defers
test_savesent_turnended_advanced_but_crew_working_defers
test_settling_within_window_defers_capture
test_settling_past_window_records_done_and_next_sweep_is_noop
test_savesent_timeout_abandons_without_compact
test_done_unchanged_signatures_is_noop
test_done_status_change_clears_marker_and_restarts_episode
test_reset_stamp_holds_off_a_new_episode_for_a_full_window
test_done_pane_change_clears_marker

echo "all fm-idle-compact-lifecycle tests passed"
