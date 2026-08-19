#!/usr/bin/env bash
# Behavior tests for bin/fm-context-measure-lib.sh's fm_context_measure_transcript,
# the single owner of "how many context tokens does this transcript carry?"
# (docs/session-handover.md "Measuring the context").
#
# Four correctness rules pinned here: dedupe a multi-block turn by requestId,
# take the LAST entry rather than the max (compaction resets the total),
# exclude isSidechain entries, and ignore a trailing synthetic all-zero-usage
# entry (fm-session-pulse-false-zero) so an abnormally-ended turn is never
# reported as a real, valid 0.
#
# All hermetic: no real agent session, no network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-context-measure-lib.sh
. "$ROOT/bin/fm-context-measure-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-context-measure-lib)

# --- fixtures ----------------------------------------------------------------

# One assistant transcript line whose four usage fields sum to $1.
assistant_line() {
  local total=$1 rid=${2:-req-1} sidechain=${3:-false}
  printf '{"type":"assistant","isSidechain":%s,"requestId":"%s","message":{"usage":{"input_tokens":2,"cache_creation_input_tokens":8,"cache_read_input_tokens":%s,"output_tokens":10}}}\n' \
    "$sidechain" "$rid" "$((total - 20))"
}

# A trailing synthetic entry, the shape Claude Code writes when a turn ends
# abnormally: assistant, main chain, model "<synthetic>", all four usage fields 0.
synthetic_zero_line() {
  printf '{"type":"assistant","isSidechain":false,"message":{"model":"<synthetic>","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}\n'
}

# $TMP_ROOT's own directory does not survive fm_test_tmproot's command
# substitution (its EXIT trap fires when that subshell exits), so mkdir -p
# recreates it on demand rather than assuming a bare mktemp against it works.
NEW_TRANSCRIPT_N=0
new_transcript() {
  NEW_TRANSCRIPT_N=$((NEW_TRANSCRIPT_N + 1))
  local dir="$TMP_ROOT/t$NEW_TRANSCRIPT_N"
  mkdir -p "$dir"
  printf '%s\n' "$dir/transcript.jsonl"
}

# --- rule 3: synthetic zero-usage entries -------------------------------------

# The exact fixture the bug report reproduces with: one real 300,010-token
# turn, then the trailing zero-usage entry Claude Code writes on an abnormal
# turn end. Before the fix this returned "0" with exit 0, a false measurement
# indistinguishable from a genuinely empty session.
test_trailing_synthetic_zero_does_not_report_a_false_zero() {
  local t out status
  t=$(new_transcript)
  {
    assistant_line 300010 req-real
    synthetic_zero_line
  } > "$t"
  out=$(fm_context_measure_transcript "$t"); status=$?
  if [ "$status" -eq 0 ] && [ "$out" = "0" ]; then
    fail "a trailing synthetic zero-usage entry reported a false 0: $out"
  fi
  # The narrow fix recovers the real total; a wider rewrite could instead
  # legitimately fail to measure, but must never report a false 0 (see brief).
  if [ "$status" -eq 0 ]; then
    [ "$out" = "300010" ] || fail "measured '$out' instead of the real total 300010"
  fi
  pass "fm-context-measure-lib: a trailing synthetic zero-usage entry never reports a false 0"
}

test_trailing_synthetic_zero_recovers_the_real_total() {
  local t out status
  t=$(new_transcript)
  {
    assistant_line 300010 req-real
    synthetic_zero_line
  } > "$t"
  out=$(fm_context_measure_transcript "$t"); status=$?
  expect_code 0 "$status" "the real prior total must still be measurable"
  [ "$out" = "300010" ] || fail "expected 300010, got '$out'"
  pass "fm-context-measure-lib: a trailing synthetic zero-usage entry recovers the last real total"
}

# A transcript whose ONLY assistant entry is a synthetic zero, and one with no
# assistant usage at all, must both stay unmeasurable exactly as before the fix.
test_genuinely_empty_transcript_stays_unmeasurable() {
  local t status
  t=$(new_transcript)
  : > "$t"
  fm_context_measure_transcript "$t" >/dev/null 2>&1; status=$?
  [ "$status" -ne 0 ] || fail "an empty transcript must stay unmeasurable"

  t=$(new_transcript)
  synthetic_zero_line > "$t"
  fm_context_measure_transcript "$t" >/dev/null 2>&1; status=$?
  [ "$status" -ne 0 ] || fail "a transcript with only a synthetic zero entry must stay unmeasurable"

  t=$(new_transcript)
  printf '{"type":"user","message":{"role":"user","content":"hi"}}\n' > "$t"
  fm_context_measure_transcript "$t" >/dev/null 2>&1; status=$?
  [ "$status" -ne 0 ] || fail "a transcript with no assistant usage at all must stay unmeasurable"
  pass "fm-context-measure-lib: a genuinely empty or all-zero transcript stays unmeasurable"
}

# --- ordinary measurement and existing dedupe are unchanged -------------------

test_ordinary_nonzero_measurement_is_unchanged() {
  local t out
  t=$(new_transcript)
  assistant_line 75782 req-a > "$t"
  out=$(fm_context_measure_transcript "$t")
  [ "$out" = "75782" ] || fail "expected 75782, got '$out'"
  pass "fm-context-measure-lib: an ordinary non-zero measurement is unchanged"
}

# A multi-block turn writes several JSONL lines sharing one requestId, each
# carrying that turn's own cumulative usage. Dedupe must take the final one of
# that requestId, not sum or take the very last line regardless of requestId.
test_dedupe_by_request_id_is_unchanged() {
  local t out
  t=$(new_transcript)
  {
    assistant_line 100000 req-multi
    assistant_line 100000 req-multi
    assistant_line 120000 req-multi
  } > "$t"
  out=$(fm_context_measure_transcript "$t")
  [ "$out" = "120000" ] || fail "expected the final block of one requestId (120000), got '$out'"
  pass "fm-context-measure-lib: dedupe-by-requestId still takes the final block of a multi-block turn"
}

test_takes_last_never_max_across_compaction() {
  local t out
  t=$(new_transcript)
  {
    assistant_line 240000 req-pre
    assistant_line 30000 req-post
  } > "$t"
  out=$(fm_context_measure_transcript "$t")
  [ "$out" = "30000" ] || fail "expected the last total 30000, not the pre-compaction peak, got '$out'"
  pass "fm-context-measure-lib: takes the last total, never the max, across a compaction"
}

test_excludes_sidechain_entries() {
  local t out
  t=$(new_transcript)
  {
    assistant_line 20000 req-main false
    assistant_line 999999 req-sub true
  } > "$t"
  out=$(fm_context_measure_transcript "$t")
  [ "$out" = "20000" ] || fail "a sidechain entry must not count toward the total, got '$out'"
  pass "fm-context-measure-lib: excludes isSidechain entries"
}

# --- degradation ---------------------------------------------------------------

test_missing_file_is_unmeasurable() {
  local status
  fm_context_measure_transcript "$TMP_ROOT/nope-does-not-exist.jsonl" >/dev/null 2>&1; status=$?
  [ "$status" -ne 0 ] || fail "a missing transcript must be unmeasurable"
  pass "fm-context-measure-lib: a missing transcript is unmeasurable"
}

run_all() {
  test_trailing_synthetic_zero_does_not_report_a_false_zero
  test_trailing_synthetic_zero_recovers_the_real_total
  test_genuinely_empty_transcript_stays_unmeasurable
  test_ordinary_nonzero_measurement_is_unchanged
  test_dedupe_by_request_id_is_unchanged
  test_takes_last_never_max_across_compaction
  test_excludes_sidechain_entries
  test_missing_file_is_unmeasurable
}

if ! command -v jq >/dev/null 2>&1; then
  printf 'skip: jq not found - the context measurement needs it\n'
  exit 0
fi

run_all
