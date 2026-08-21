#!/usr/bin/env bash
# tests/fm-omp-harness.test.sh - detection matrix for the omp (Oh My Pi) adapter.
#
# omp sets OMPCODE=1 alongside CLAUDECODE=1 on its child/tool processes (verified
# omp 17.3.3). The detection precedence hazard is identical to cursor's: omp does
# NOT clear an inherited CLAUDECODE, so whichever marker is tested first wins.
# This suite pins the LOGIC with env markers only, NO omp binary required, so CI
# enforces it everywhere.
#
# The load-bearing contracts:
#   1. OMPCODE=1 outranks CLAUDECODE=1 (omp is Pi-family, not Claude).
#   2. OMPCODE=1 outranks PI_CODING_AGENT=true (omp is a distinct fork).
#   3. CLAUDECODE=1 alone (no OMPCODE) is still claude.
#   4. PI_CODING_AGENT=true alone (no OMPCODE) is still pi.
#   5. Cursor markers still win over everything (unchanged precedence).
#   6. Grok marker still detected (unchanged precedence).
#   7. No markers: unknown (ancestry walk, no omp process to match).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"

# Run fm-harness.sh with a clean slate plus the given env markers.
# FM_CONFIG_OVERRIDE points at an empty dir so crew/secondmate resolution
# tests the detection logic, not the operator's local config/crew-harness
# (which may pin a specific adapter and mask the "default mirrors own" path).
DETECT_CONFIG=$(fm_test_tmproot omp-detect-config)
detect_with() {
  env -u CLAUDECODE -u OMPCODE -u PI_CODING_AGENT -u GROK_AGENT \
      -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u FM_PI_HARNESS \
      FM_CONFIG_OVERRIDE="$DETECT_CONFIG" \
      "$@" "$HARNESS"
}

test_ompcodes_outranks_claudecode() {
  local result
  result=$(detect_with OMPCODE=1 CLAUDECODE=1)
  expect_code 0 $? "omp detection should succeed"
  assert_contains "$result" "omp" "OMPCODE=1 + CLAUDECODE=1 should detect omp, got: $result"
}

test_ompcodes_outranks_pi_marker() {
  local result
  result=$(detect_with OMPCODE=1 PI_CODING_AGENT=true)
  assert_contains "$result" "omp" "OMPCODE=1 + PI_CODING_AGENT=true should detect omp, got: $result"
}

test_claudecode_alone_is_claude() {
  local result
  result=$(detect_with CLAUDECODE=1)
  assert_contains "$result" "claude" "CLAUDECODE=1 alone should detect claude, got: $result"
}

test_pi_marker_alone_is_pi() {
  local result
  result=$(detect_with PI_CODING_AGENT=true)
  assert_contains "$result" "pi" "PI_CODING_AGENT=true alone should detect pi, got: $result"
}

test_cursor_marker_still_wins() {
  local result
  result=$(detect_with CURSOR_AGENT=1 OMPCODE=1 CLAUDECODE=1)
  assert_contains "$result" "cursor" "CURSOR_AGENT=1 should outrank omp, got: $result"
}

test_grok_marker_still_detected() {
  local result
  result=$(detect_with GROK_AGENT=1 OMPCODE=1)
  assert_contains "$result" "grok" "GROK_AGENT=1 should outrank omp, got: $result"
}

test_no_markers_is_unknown() {
  local result
  result=$(detect_with)
  assert_contains "$result" "unknown" "no markers should detect unknown, got: $result"
}

test_crew_resolution_defaults_to_own() {
  local result
  result=$(detect_with OMPCODE=1 CLAUDECODE=1 "$HARNESS" crew)
  assert_contains "$result" "omp" "crew resolution with no config should mirror own (omp), got: $result"
}

test_ompcodes_outranks_claudecode
test_ompcodes_outranks_pi_marker
test_claudecode_alone_is_claude
test_pi_marker_alone_is_pi
test_cursor_marker_still_wins
test_grok_marker_still_detected
test_no_markers_is_unknown
test_crew_resolution_defaults_to_own
