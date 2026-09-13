#!/usr/bin/env bash
# tests/fm-idle-compact-tick.test.sh - behavior tests for
# bin/fm-idle-compact.sh's tick entry point (fm_idle_compact_tick): the live
# `enabled` CLI check, an absent-config no-op, a present-config sweep acting
# on an eligible task and delivering the ring end to end, the two production
# call sites (bin/fm-watch.sh's poll loop and bin/fm-supervise-daemon.sh's
# away-mode housekeeping()) exercising the SAME entry point, sweep-cadence
# gating, and sweep-lock deferral. Split out of the original combined
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

TMP_ROOT=$(fm_test_tmproot fm-idle-compact-tick)

# A worker deciding whether to wait for a compaction ring must not trust a
# generation-time brief snapshot (config/idle-compact can change afterward),
# so it checks live via `fm-idle-compact.sh enabled`. Exercised through the
# real direct-execution entry point, not the function directly, since that
# dispatch is the actual new surface.
test_cli_enabled_reports_live_config_state() {
  (
    local dir out
    dir=$(new_dir cli-enabled)

    if FM_CONFIG_OVERRIDE="$dir/config" bash "$ROOT/bin/fm-idle-compact.sh" enabled >/dev/null 2>&1; then
      fail "enabled must exit nonzero when config/idle-compact is absent"
    fi

    : > "$dir/config/idle-compact"
    FM_CONFIG_OVERRIDE="$dir/config" bash "$ROOT/bin/fm-idle-compact.sh" enabled >/dev/null 2>&1 \
      || fail "enabled must exit zero for an empty-but-present config (default minutes)"

    printf '0\n' > "$dir/config/idle-compact"
    if FM_CONFIG_OVERRIDE="$dir/config" bash "$ROOT/bin/fm-idle-compact.sh" enabled >/dev/null 2>&1; then
      fail "enabled must exit nonzero when config/idle-compact is 0"
    fi

    printf 'not-a-number\n' > "$dir/config/idle-compact"
    if FM_CONFIG_OVERRIDE="$dir/config" bash "$ROOT/bin/fm-idle-compact.sh" enabled >/dev/null 2>&1; then
      fail "enabled must exit nonzero when config/idle-compact is invalid"
    fi

    printf '20\n' > "$dir/config/idle-compact"
    out=$(FM_CONFIG_OVERRIDE="$dir/config" bash "$ROOT/bin/fm-idle-compact.sh" enabled) \
      || fail "enabled must exit zero for a valid positive integer"
    [ "$out" = 20 ] || fail "enabled must print the configured minutes on stdout (got: $out)"
  )
  pass "fm-idle-compact.sh enabled: reports the live config state, not a cached one"
}

test_tick_absent_config_is_grep_provably_inert() {
  (
    local dir log before after
    dir=$(new_dir tick-inert)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    # No config/idle-compact written at all.
    before=$(find "$dir/state" -type f | sort)

    fm_idle_compact_tick "$dir/state" "$dir/config"

    after=$(find "$dir/state" -type f | sort)
    [ "$before" = "$after" ] || fail "an absent config/idle-compact must leave state/ byte-for-byte untouched:"$'\n'"before:"$'\n'"$before"$'\n'"after:"$'\n'"$after"
    [ ! -s "$log" ] || fail "an absent config/idle-compact must never send anything"
    pass "fm_idle_compact_tick: an absent config/idle-compact is grep-provably inert (zero state mutation, zero sends)"
  ) || exit 1
}

test_tick_present_config_sweeps_eligible_task() {
  (
    local dir log marker
    dir=$(new_dir tick-active)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    printf '30\n' > "$dir/config/idle-compact"

    fm_idle_compact_tick "$dir/state" "$dir/config"

    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    [ -f "$marker" ] || fail "a present, valid config/idle-compact must sweep and act on an eligible task"
    [ "$(wc -l < "$log")" = 1 ] || fail "exactly one send expected from the sweep"
    pass "fm_idle_compact_tick: a present, valid config sweeps state/*.meta and acts on the eligible task"
  ) || exit 1
}

test_tick_delivers_the_ring_through_the_shared_sweep() {
  (
    local dir log marker
    dir=$(new_dir tick-ring)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600 \
      'paused: awaiting compaction before validation (commit 3985d693a, 1292 changed lines, over-cap accepted)'
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    printf '30\n' > "$dir/config/idle-compact"
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)

    # Sweep one: the declared pause skips the notes save and sends /compact.
    fm_idle_compact_tick "$dir/state" "$dir/config"
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'settling' ] \
      || fail "the first sweep must send /compact and record phase=settling"
    # Sweep two, past the settle window: the ring goes out and the episode lands.
    rm -f "$dir/state/.idle-compact-last-sweep"
    FM_IDLE_COMPACT_SETTLE_SECS=0 fm_idle_compact_tick "$dir/state" "$dir/config"
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'done' ] \
      || fail "the second sweep must land the episode at phase=done"
    grep -q 'compacted - start the validation run now' "$log" \
      || fail "the ring must be delivered by the shared sweep both supervision paths call"
    pass "fm_idle_compact_tick: the shared sweep both supervision paths call delivers the ring end to end"
  ) || exit 1
}

# bin/fm-watch.sh's main loop (attended) and bin/fm-supervise-daemon.sh's
# housekeeping (away mode) must reach the ring through the SAME entry point, or
# a worker's recovery would depend on whether the captain happened to be away -
# which is exactly the condition both 2026-09-06 lanes ran under. Both tests
# below source the real production file and drive its actual call site (the
# single-argument fm_idle_compact_tick form bin/fm-watch.sh's loop uses, and
# the housekeeping() function bin/fm-supervise-daemon.sh's tick literally is)
# against a declared-pause fixture, and assert the ring lands - not that the
# call text merely appears in the file.

test_watch_tick_call_site_delivers_the_ring_end_to_end() {
  (
    local dir log marker
    dir=$(new_dir watch-tick-ring)
    FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" . "$ROOT/bin/fm-watch.sh"
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600 \
      'paused: awaiting compaction before validation (commit 3985d693a, 1292 changed lines, over-cap accepted)'
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    printf '30\n' > "$dir/config/idle-compact"
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)

    # The exact call bin/fm-watch.sh's poll loop makes: fm_idle_compact_tick
    # "$STATE" || true, against the STATE/CONFIG this sourcing resolved.
    # shellcheck disable=SC2153 # STATE is assigned by sourcing bin/fm-watch.sh above, not a typo of $state
    fm_idle_compact_tick "$STATE" || true
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'settling' ] \
      || fail "bin/fm-watch.sh's tick call site must send /compact and record phase=settling"
    rm -f "$dir/state/.idle-compact-last-sweep"
    FM_IDLE_COMPACT_SETTLE_SECS=0 fm_idle_compact_tick "$STATE" || true
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'done' ] \
      || fail "bin/fm-watch.sh's tick call site must land the episode at phase=done"
    grep -q 'compacted - start the validation run now' "$log" \
      || fail "bin/fm-watch.sh's own fm_idle_compact_tick call site must deliver the ring"
    pass "bin/fm-watch.sh: its poll-loop fm_idle_compact_tick call delivers the ring end to end"
  ) || exit 1
}

test_supervise_daemon_housekeeping_delivers_the_ring_end_to_end() {
  (
    local dir log marker
    dir=$(new_dir daemon-tick-ring)
    FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" . "$ROOT/bin/fm-supervise-daemon.sh"
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600 \
      'paused: awaiting compaction before validation (commit 3985d693a, 1292 changed lines, over-cap accepted)'
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    printf '30\n' > "$dir/config/idle-compact"
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)

    # The real away-mode call site: housekeeping() step (4), the exact
    # condition both 2026-09-06 lanes ran under.
    housekeeping "$dir/state"
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'settling' ] \
      || fail "bin/fm-supervise-daemon.sh's housekeeping() must send /compact and record phase=settling"
    rm -f "$dir/state/.idle-compact-last-sweep"
    FM_IDLE_COMPACT_SETTLE_SECS=0 housekeeping "$dir/state"
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'done' ] \
      || fail "bin/fm-supervise-daemon.sh's housekeeping() must land the episode at phase=done"
    grep -q 'compacted - start the validation run now' "$log" \
      || fail "bin/fm-supervise-daemon.sh's own housekeeping() call site must deliver the ring"
    pass "bin/fm-supervise-daemon.sh: away-mode housekeeping() delivers the ring end to end"
  ) || exit 1
}

test_tick_sweep_due_gating() {
  (
    local dir
    dir=$(new_dir tick-sweepdue)
    mkdir -p "$dir/state"
    fm_idle_compact_sweep_due "$dir/state" \
      || fail "a fleet with no prior sweep marker must be immediately due"
    touch "$dir/state/.idle-compact-last-sweep"
    if FM_IDLE_COMPACT_INTERVAL=3600 fm_idle_compact_sweep_due "$dir/state"; then
      fail "a fresh sweep marker must not be due again inside FM_IDLE_COMPACT_INTERVAL"
    fi
    if FM_IDLE_COMPACT_INTERVAL=0 fm_idle_compact_sweep_due "$dir/state"; then
      :
    else
      fail "FM_IDLE_COMPACT_INTERVAL=0 must always be due"
    fi
    pass "fm_idle_compact_sweep_due: gates the sweep cadence off the last-sweep marker's age"
  ) || exit 1
}

test_tick_held_sweep_lock_defers_whole_sweep() {
  (
    local dir log lock holder_pid
    dir=$(new_dir tick-lockheld)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    # shellcheck disable=SC2034 # read by fm_idle_compact_eligible in the sourced fm-idle-compact.sh library
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    printf '30\n' > "$dir/config/idle-compact"

    # A concurrent supervisor (a DIFFERENT live pid - the same pid would take
    # fm_lock_try_acquire's self-held reclaim path) holds the sweep lock for
    # the duration of the tick under test.
    lock="$dir/state/.idle-compact.lock"
    ( fm_lock_try_acquire "$lock" && sleep 30 ) &
    holder_pid=$!
    for _ in $(seq 1 50); do
      [ -L "$lock" ] && break
      sleep 0.1
    done
    [ -L "$lock" ] || fail "fixture: background holder never acquired the sweep lock"

    fm_idle_compact_tick "$dir/state" "$dir/config"

    kill "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
    [ ! -s "$log" ] || fail "a held sweep lock must defer every send to the lock holder's sweep"
    [ ! -e "$dir/state/.idle-compact-last-sweep" ] \
      || fail "a locked-out tick must not touch the last-sweep marker (the holder's sweep owns it)"
    [ ! -e "$(fm_idle_compact_marker_path "$dir/state" t1)" ] \
      || fail "a locked-out tick must not advance any task's marker state machine"
    pass "fm_idle_compact_tick: a sweep lock held by a live concurrent supervisor defers the whole sweep"
  ) || exit 1
}

# --- run ---------------------------------------------------------------------

test_cli_enabled_reports_live_config_state
test_tick_absent_config_is_grep_provably_inert
test_tick_present_config_sweeps_eligible_task
test_tick_delivers_the_ring_through_the_shared_sweep
test_watch_tick_call_site_delivers_the_ring_end_to_end
test_supervise_daemon_housekeeping_delivers_the_ring_end_to_end
test_tick_sweep_due_gating
test_tick_held_sweep_lock_defers_whole_sweep

echo "all fm-idle-compact-tick tests passed"
