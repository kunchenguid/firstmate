#!/usr/bin/env bash
# tests/fm-idle-compact-send.test.sh - behavior tests for the first half of
# bin/fm-idle-compact.sh's 4-phase marker state machine
# (fm_idle_compact_process_task): the no-marker phase (first eligible+safe
# sweep sends the notes-save message or, for a declared pause, /compact
# directly) and the settling phase's worker-ring behavior. Split out of the
# original combined tests/fm-idle-compact.test.sh (see
# tests/idle-compact-helpers.sh) so ShellCheck's extended dataflow analysis
# runs over a bounded file instead of the whole suite at once.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-idle-compact.sh
. "$ROOT/bin/fm-idle-compact.sh"

# shellcheck source=tests/idle-compact-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/idle-compact-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-idle-compact-send)

# --- 4-phase marker state machine (fm_idle_compact_process_task) -----------
# fm_busy_classify/fm_backend_composer_state are stubbed idle+empty (safe
# throughout) unless a test says otherwise; fm_idle_compact_send is stubbed
# to record calls to a log file, decoupling the state machine from
# bin/fm-send.sh's own real delivery mechanics (separately owned/tested).

test_no_marker_eligible_sends_save_and_marks_savesent() {
  (
    local dir log marker
    dir=$(new_dir sm-firstsend)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"

    fm_idle_compact_process_task "$dir/state" t1 30
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    [ -f "$marker" ] || fail "a first eligible+safe sweep must write the marker"
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = save-sent ] \
      || fail "the marker must record phase=save-sent after the first send"
    [ "$(wc -l < "$log")" = 1 ] || fail "exactly one send (the save message) must have gone out"
    grep -q "precompact-notes.md" "$log" || fail "the save message must point at precompact-notes.md"
    grep -q "key file paths" "$log" || fail "the save message must ask for key file paths (the documented save-content list)"
    pass "fm_idle_compact_process_task: no marker + eligible + safe sends the save message and records phase=save-sent"
  ) || exit 1
}

test_no_marker_ineligible_creates_no_marker() {
  (
    local dir log marker
    dir=$(new_dir sm-ineligible)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: working")
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"

    fm_idle_compact_process_task "$dir/state" t1 30
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    [ ! -e "$marker" ] || fail "an ineligible (working) task must never get a marker"
    [ ! -s "$log" ] || fail "an ineligible task must never be sent anything"
    pass "fm_idle_compact_process_task: an ineligible task (mid-task) is left untouched"
  ) || exit 1
}

test_no_marker_unsafe_pane_defers_no_send() {
  (
    local dir log marker
    dir=$(new_dir sm-unsafe)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    log="$dir/sends.log"; : > "$log"
    fm_busy_classify() { printf 'busy claude-hook'; }
    fm_backend_composer_state() { printf 'empty'; }
    stub_recording_send "$log"

    fm_idle_compact_process_task "$dir/state" t1 30
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    [ ! -e "$marker" ] || fail "an eligible task with a busy pane must not get a marker yet"
    [ ! -s "$log" ] || fail "a busy pane must never be sent anything"
    pass "fm_idle_compact_process_task: eligible but unsafe (busy pane) defers to a later sweep, never sends"
  ) || exit 1
}

test_no_marker_declared_state_skips_save_sends_compact_directly() {
  (
    local dir log marker
    dir=$(new_dir sm-declared)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 5 'paused: awaiting compaction before validation'
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"

    fm_idle_compact_process_task "$dir/state" t1 30
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = settling ] \
      || fail "the declared-state fast path must jump straight to phase=settling, skipping phase=save-sent"
    [ "$(fm_idle_compact_marker_field "$marker" declared)" = 1 ] \
      || fail "the marker must record declared=1 so the settle transition knows to ring the worker"
    [ "$(wc -l < "$log")" = 1 ] || fail "exactly one send (a direct /compact) must have gone out, no notes-save message"
    [ "$(cut -f2 "$log")" = t1 ] || fail "the declared-state send must target t1"
    case "$(cut -f3 "$log")" in
      '/compact '*) : ;;
      *) fail "the declared-state send must be a literal /compact command" ;;
    esac
    grep -q "branch fm/t1" "$log" || fail "the declared-state /compact focus text must name the branch"
    grep -q "brief.md" "$log" || fail "the declared-state /compact focus text must name the brief path"
    grep -q "mode=" "$log" || fail "the declared-state /compact focus text must name the delivery contract"
    pass "fm_idle_compact_process_task: the declared-state phrase skips the notes-save turn and sends /compact directly"
  ) || exit 1
}

test_no_marker_declared_state_ignored_when_pane_unsafe() {
  (
    local dir log marker
    dir=$(new_dir sm-declared-unsafe)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 5 'paused: awaiting compaction before validation'
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    log="$dir/sends.log"; : > "$log"
    fm_busy_classify() { printf 'busy claude-hook'; }
    fm_backend_composer_state() { printf 'empty'; }
    stub_recording_send "$log"

    fm_idle_compact_process_task "$dir/state" t1 30
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    [ ! -e "$marker" ] || fail "the declared-state fast path must still respect the live safety gate"
    [ ! -s "$log" ] || fail "a busy pane must never be sent anything, declared state or not"
    pass "fm_idle_compact_process_task: the declared-state fast path still defers to the live safety gate"
  ) || exit 1
}

test_settling_declared_rings_worker_on_done() {
  (
    local dir log marker
    dir=$(new_dir sm-declared-ring)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    fm_idle_compact_marker_write "$marker" phase=settling "settle_epoch=1" declared=1

    FM_IDLE_COMPACT_SETTLE_SECS=1 fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'done' ] \
      || fail "past the settle window a declared episode must still advance to phase=done"
    [ "$(wc -l < "$log")" = 1 ] || fail "exactly one ring message must go out on the declared settle->done transition"
    grep -q 'compacted - start the validation run now' "$log" \
      || fail "the ring message must tell the worker to start the validation run now"
    pass "fm_idle_compact_process_task: a declared episode rings the worker with an inbox message once it settles to phase=done"
  ) || exit 1
}

test_settling_declared_unsafe_pane_still_rings() {
  (
    local dir log marker
    dir=$(new_dir sm-declared-ring-unsafe)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    log="$dir/sends.log"; : > "$log"
    # shellcheck disable=SC2329 # invoked indirectly through fm_idle_compact_safe_to_send
    fm_busy_classify() { printf 'busy claude-hook'; }
    # shellcheck disable=SC2329 # invoked indirectly through fm_idle_compact_safe_to_send
    fm_backend_composer_state() { printf 'pending'; }
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    fm_idle_compact_marker_write "$marker" phase=settling "settle_epoch=1" declared=1

    FM_IDLE_COMPACT_SETTLE_SECS=1 fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'done' ] \
      || fail "a durable ring must not be deferred by a live pane verdict"
    grep -q 'compacted - start the validation run now' "$log" \
      || fail "the ring is an inbox record, so a busy pane is exactly the case it exists for"
    pass "fm_idle_compact_process_task: the post-settle ring is durable and goes out even over a busy pane"
  ) || exit 1
}

test_settling_declared_send_failure_stays_settling() {
  (
    local dir marker
    dir=$(new_dir sm-declared-ring-fail)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    stub_always_safe
    # shellcheck disable=SC2329 # invoked indirectly through fm_idle_compact_ring_worker
    fm_idle_compact_send() { return 1; }
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    fm_idle_compact_marker_write "$marker" phase=settling "settle_epoch=1" declared=1

    FM_IDLE_COMPACT_SETTLE_SECS=1 fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'settling' ] \
      || fail "the episode must advance to phase=done only after the ring record exists"
    pass "fm_idle_compact_process_task: a failed ring enqueue keeps the episode in phase=settling for a later sweep"
  ) || exit 1
}

test_settling_ordinary_path_rings_a_worker_still_declaring_the_pause() {
  (
    local dir log marker
    dir=$(new_dir sm-ordinary-declared-ring)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600 \
      'paused: awaiting compaction before validation (commit 3985d693a, 1292 changed lines, over-cap accepted)'
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    # No declared=1: the ordinary save-then-compact path, which is the path both
    # 2026-09-06 lanes took because their status lines carried trailing detail.
    fm_idle_compact_marker_write "$marker" phase=settling "settle_epoch=1"

    FM_IDLE_COMPACT_SETTLE_SECS=1 fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'done' ] \
      || fail "past the settle window the episode must still advance to phase=done"
    grep -q 'compacted - start the validation run now' "$log" \
      || fail "a worker whose status still declares the compaction pause must be rung whichever path the episode took"
    pass "fm_idle_compact_process_task: the ordinary path also rings a worker whose status still declares the compaction pause"
  ) || exit 1
}

test_settling_non_declared_never_rings_worker() {
  (
    local dir log marker
    dir=$(new_dir sm-nondeclared-ring)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    fm_idle_compact_marker_write "$marker" phase=settling "settle_epoch=1"

    FM_IDLE_COMPACT_SETTLE_SECS=1 fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'done' ] \
      || fail "past the settle window an ordinary episode must still advance to phase=done"
    [ ! -s "$log" ] || fail "an ordinary (non-declared) episode must never send a ring message on settle->done"
    pass "fm_idle_compact_process_task: an ordinary episode settling to phase=done never rings the worker"
  ) || exit 1
}

# --- run ---------------------------------------------------------------------

test_no_marker_eligible_sends_save_and_marks_savesent
test_no_marker_ineligible_creates_no_marker
test_no_marker_unsafe_pane_defers_no_send
test_no_marker_declared_state_skips_save_sends_compact_directly
test_no_marker_declared_state_ignored_when_pane_unsafe
test_settling_declared_rings_worker_on_done
test_settling_declared_unsafe_pane_still_rings
test_settling_declared_send_failure_stays_settling
test_settling_ordinary_path_rings_a_worker_still_declaring_the_pause
test_settling_non_declared_never_rings_worker

echo "all fm-idle-compact-send tests passed"
