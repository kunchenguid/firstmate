#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"

test_detects_cursor_via_env_marker() {
  local out
  out=$(CURSOR_AGENT=1 CLAUDECODE='' PI_CODING_AGENT='' GROK_AGENT='' "$HARNESS")
  assert_contains "$out" "cursor" "CURSOR_AGENT=1 should detect the cursor harness"
  pass "detects cursor via CURSOR_AGENT marker"
}

test_claude_still_wins_when_both_set() {
  local out
  out=$(CURSOR_AGENT=1 CLAUDECODE=1 "$HARNESS")
  assert_contains "$out" "claude" "a genuine claude session (CLAUDECODE=1) must resolve to claude, not cursor"
  pass "preference-neutral: claude wins when CLAUDECODE is set"
}

test_detects_cursor_via_env_marker
test_claude_still_wins_when_both_set
