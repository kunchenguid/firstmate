#!/usr/bin/env bash
# tests/fm-idle-compact-config.test.sh - behavior tests for the opt-in
# idle-worker pre-cache-expiry compaction owner (bin/fm-idle-compact.sh):
# config/idle-compact parsing (absent/empty/valid/invalid) and the
# eligibility intersection (kind, harness, idle age, reconciled crew state -
# each exclusion arm on its own, plus the declared-state fast path and the
# live safety gate). Split out of the original combined tests/fm-idle-compact
# .test.sh (see tests/idle-compact-helpers.sh) so ShellCheck's extended
# dataflow analysis runs over a bounded file instead of the whole suite at
# once.
#
# Hermetic: fm_busy_classify, fm_backend_composer_state, and
# fm_idle_compact_send are function-overridden per test (the same dependency-
# injection idiom tests/fm-daemon.test.sh already uses for
# fm_backend_composer_state/pane_is_busy), and bin/fm-crew-state.sh is
# replaced via the FM_CREW_STATE_BIN override this file's eligibility check
# reads at call time. No real tmux, no real Claude session, no network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-idle-compact.sh
. "$ROOT/bin/fm-idle-compact.sh"

# shellcheck source=tests/idle-compact-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/idle-compact-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-idle-compact-config)

# --- config parsing (fm_idle_compact_threshold_minutes) --------------------

test_config_absent_is_disabled() {
  local dir out rc=0
  dir=$(new_dir config-absent)
  out=$(fm_idle_compact_threshold_minutes "$dir/config") || rc=$?
  [ "$rc" -ne 0 ] || fail "an absent config/idle-compact must disable the feature"
  [ -z "$out" ] || fail "a disabled threshold must print nothing, got '$out'"
  pass "fm_idle_compact_threshold_minutes: absent config/idle-compact disables the feature"
}

test_config_empty_file_uses_default_15() {
  local dir out
  dir=$(new_dir config-empty)
  : > "$dir/config/idle-compact"
  out=$(fm_idle_compact_threshold_minutes "$dir/config") || fail "an empty-but-present file must enable the feature"
  [ "$out" = 15 ] || fail "expected the documented 15-minute default, got '$out'"
  pass "fm_idle_compact_threshold_minutes: an empty-but-present file enables the feature at the 15-minute default"
}

test_config_comment_only_uses_default_15() {
  local dir out
  dir=$(new_dir config-comment)
  printf '# just a comment\n\n# another\n' > "$dir/config/idle-compact"
  out=$(fm_idle_compact_threshold_minutes "$dir/config") || fail "a comment-only file must enable the feature"
  [ "$out" = 15 ] || fail "expected the documented 15-minute default, got '$out'"
  pass "fm_idle_compact_threshold_minutes: a comment-only file enables the feature at the 15-minute default"
}

test_config_valid_value_used_verbatim() {
  local dir out
  dir=$(new_dir config-valid)
  printf '  45  \n' > "$dir/config/idle-compact"
  out=$(fm_idle_compact_threshold_minutes "$dir/config") || fail "a valid positive integer must enable the feature"
  [ "$out" = 45 ] || fail "expected the configured value 45 (whitespace-trimmed), got '$out'"
  pass "fm_idle_compact_threshold_minutes: a valid positive integer is used verbatim, whitespace-trimmed"
}

test_config_invalid_value_disabled() {
  local dir val rc
  dir=$(new_dir config-invalid)
  for val in abc -5 1.5; do
    printf '%s\n' "$val" > "$dir/config/idle-compact"
    rc=0
    fm_idle_compact_threshold_minutes "$dir/config" >/dev/null || rc=$?
    [ "$rc" -ne 0 ] || fail "invalid value '$val' must disable the feature, not enable it"
  done
  pass "fm_idle_compact_threshold_minutes: a non-positive-integer value disables the feature, same as absent"
}

test_config_whitespace_only_line_is_treated_as_empty() {
  local dir out
  dir=$(new_dir config-whitespace)
  printf '   \n\t\n' > "$dir/config/idle-compact"
  out=$(fm_idle_compact_threshold_minutes "$dir/config") || fail "a whitespace-only file has no non-blank content line, so it must behave like an empty file (enabled)"
  [ "$out" = 15 ] || fail "expected the documented 15-minute default, got '$out'"
  pass "fm_idle_compact_threshold_minutes: a whitespace-only file trims to no content and enables the feature at the default"
}

test_config_zero_disabled() {
  local dir rc=0
  dir=$(new_dir config-zero)
  printf '0\n' > "$dir/config/idle-compact"
  fm_idle_compact_threshold_minutes "$dir/config" >/dev/null || rc=$?
  [ "$rc" -ne 0 ] || fail "a zero threshold must disable the feature"
  pass "fm_idle_compact_threshold_minutes: zero disables the feature"
}

# --- eligibility (fm_idle_compact_eligible) ---------------------------------

test_eligible_excludes_secondmate() {
  (
    local dir
    dir=$(new_dir elig-secondmate)
    write_task_meta "$dir/state" t1 claude secondmate
    touch_status "$dir/state" t1 3600
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    if fm_idle_compact_eligible "$dir/state" t1 30; then
      fail "a secondmate task must never be eligible (its idle pane is its normal healthy state)"
    fi
    pass "fm_idle_compact_eligible: kind=secondmate is always excluded"
  ) || exit 1
}

test_eligible_excludes_non_claude_harness() {
  (
    local dir h
    dir=$(new_dir elig-harness)
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    for h in codex opencode pi grok kimi muse; do
      write_task_meta "$dir/state" "t-$h" "$h" ship
      touch_status "$dir/state" "t-$h" 3600
      if fm_idle_compact_eligible "$dir/state" "t-$h" 30; then
        fail "harness=$h must be excluded - only claude has a verified /compact today"
      fi
    done
    pass "fm_idle_compact_eligible: every non-claude verified harness is excluded"
  ) || exit 1
}

test_eligible_excludes_idle_too_young() {
  (
    local dir
    dir=$(new_dir elig-young)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 60
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    if fm_idle_compact_eligible "$dir/state" t1 30; then
      fail "a status only 60s old must not clear a 30-minute threshold"
    fi
    pass "fm_idle_compact_eligible: idle duration under the threshold is excluded"
  ) || exit 1
}

test_eligible_excludes_missing_status() {
  (
    local dir
    dir=$(new_dir elig-nostatus)
    write_task_meta "$dir/state" t1
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    if fm_idle_compact_eligible "$dir/state" t1 30; then
      fail "a task with no status file yet must not be eligible"
    fi
    pass "fm_idle_compact_eligible: a missing status file excludes the task"
  ) || exit 1
}

test_eligible_excludes_missing_meta() {
  (
    local dir
    dir=$(new_dir elig-nometa)
    touch_status "$dir/state" t1 3600
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    if fm_idle_compact_eligible "$dir/state" t1 30; then
      fail "a task with no meta file must not be eligible"
    fi
    pass "fm_idle_compact_eligible: a missing meta file excludes the task"
  ) || exit 1
}

test_eligible_excludes_non_wait_crew_states() {
  (
    local dir s
    dir=$(new_dir elig-crewstates)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    for s in working unknown failed; do
      FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: $s")
      if fm_idle_compact_eligible "$dir/state" t1 30; then
        fail "reconciled crew state '$s' must never be eligible - not a genuine long wait, or mid-task"
      fi
    done
    pass "fm_idle_compact_eligible: working, unknown, and failed are all excluded (never mid-task)"
  ) || exit 1
}

test_eligible_includes_every_wait_state() {
  (
    local dir s
    dir=$(new_dir elig-waitstates)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    for s in parked 'done' blocked paused; do
      FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: $s · source: run-step · detail")
      fm_idle_compact_eligible "$dir/state" t1 30 \
        || fail "reconciled crew state '$s' (with a realistic ' · source: ...' tail) should be eligible when otherwise idle long enough"
    done
    pass "fm_idle_compact_eligible: parked/done/blocked/paused are all eligible, tail content after the state word ignored"
  ) || exit 1
}

# --- declared-state fast path (fm_idle_compact_declared_paused) -------------

test_eligible_declared_state_bypasses_threshold() {
  (
    local dir
    dir=$(new_dir elig-declared)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 5 'paused: awaiting compaction before validation'
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    fm_idle_compact_eligible "$dir/state" t1 30 \
      || fail "the exact declared-state phrase must bypass the idle-minutes threshold even when the status is only 5s old"
    pass "fm_idle_compact_eligible: the declared-state phrase bypasses the idle-minutes threshold"
  ) || exit 1
}

test_eligible_declared_state_with_trailing_detail_bypasses_threshold() {
  (
    local dir
    dir=$(new_dir elig-declared-detail)
    write_task_meta "$dir/state" t1
    # The exact line pt-checkin-fidelity-lane8 appended on 2026-09-06: the brief
    # asks the worker to note its measured lane size, so trailing detail after
    # the phrase is the norm. A whole-line equality test missed it, dropped the
    # episode onto the ordinary path, and left the worker unrung for 60 minutes.
    touch_status "$dir/state" t1 5 \
      'paused: awaiting compaction before validation (commit 3985d693a, 1292 changed lines, over-cap accepted)'
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    fm_idle_compact_eligible "$dir/state" t1 30 \
      || fail "the declared-state phrase with trailing detail must bypass the idle-minutes threshold"
    pass "fm_idle_compact_eligible: the declared-state phrase bypasses the threshold with trailing detail after it"
  ) || exit 1
}

test_eligible_declared_phrase_must_end_on_a_word_boundary() {
  (
    local dir
    dir=$(new_dir elig-declared-boundary)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 5 'paused: awaiting compaction before validationX of the fixtures'
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    if fm_idle_compact_eligible "$dir/state" t1 30; then
      fail "the prefix match must end on a word boundary, not swallow a longer word"
    fi
    pass "fm_idle_compact_eligible: the declared-phrase prefix match requires a word boundary after it"
  ) || exit 1
}

test_eligible_other_paused_text_still_gated_by_threshold() {
  (
    local dir
    dir=$(new_dir elig-declared-other)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 5 'paused: waiting on an upstream release'
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    if fm_idle_compact_eligible "$dir/state" t1 30; then
      fail "any other paused: text must still be gated by the ordinary idle-minutes threshold"
    fi
    pass "fm_idle_compact_eligible: any paused: text that does not start with the declared phrase gets no bypass"
  ) || exit 1
}

# --- live safety gate (fm_idle_compact_safe_to_send) ------------------------

test_safe_to_send_requires_exact_idle() {
  (
    fm_busy_classify() { printf 'busy claude-hook'; }
    fm_backend_composer_state() { printf 'empty'; }
    if fm_idle_compact_safe_to_send /nonexistent-state t1; then
      fail "a busy verdict must refuse the send"
    fi
    fm_busy_classify() { printf 'unknown none'; }
    if fm_idle_compact_safe_to_send /nonexistent-state t1; then
      fail "an unproven unknown verdict must refuse the send, not just busy"
    fi
    pass "fm_idle_compact_safe_to_send: only an exact idle busy verdict permits proceeding"
  ) || exit 1
}

test_safe_to_send_requires_exact_empty_composer() {
  (
    fm_busy_classify() { printf 'idle claude-hook'; }
    fm_backend_composer_state() { printf 'pending'; }
    if fm_idle_compact_safe_to_send /nonexistent-state t1; then
      fail "a pending composer must refuse the send"
    fi
    fm_backend_composer_state() { printf 'unknown'; }
    if fm_idle_compact_safe_to_send /nonexistent-state t1; then
      fail "an unknown composer verdict must refuse the send"
    fi
    pass "fm_idle_compact_safe_to_send: only an exact empty composer verdict permits proceeding"
  ) || exit 1
}

test_safe_to_send_true_when_idle_and_empty() {
  (
    fm_busy_classify() { printf 'idle claude-hook'; }
    fm_backend_composer_state() { printf 'empty'; }
    fm_idle_compact_safe_to_send /nonexistent-state t1 \
      || fail "an exact idle verdict plus an exact empty composer must permit the send"
    pass "fm_idle_compact_safe_to_send: idle + empty together permit the send"
  ) || exit 1
}

# --- run ---------------------------------------------------------------------

test_config_absent_is_disabled
test_config_empty_file_uses_default_15
test_config_comment_only_uses_default_15
test_config_valid_value_used_verbatim
test_config_invalid_value_disabled
test_config_whitespace_only_line_is_treated_as_empty
test_config_zero_disabled

test_eligible_excludes_secondmate
test_eligible_excludes_non_claude_harness
test_eligible_excludes_idle_too_young
test_eligible_excludes_missing_status
test_eligible_excludes_missing_meta
test_eligible_excludes_non_wait_crew_states
test_eligible_includes_every_wait_state

test_eligible_declared_state_bypasses_threshold
test_eligible_declared_state_with_trailing_detail_bypasses_threshold
test_eligible_declared_phrase_must_end_on_a_word_boundary
test_eligible_other_paused_text_still_gated_by_threshold

test_safe_to_send_requires_exact_idle
test_safe_to_send_requires_exact_empty_composer
test_safe_to_send_true_when_idle_and_empty

echo "all fm-idle-compact-config tests passed"
