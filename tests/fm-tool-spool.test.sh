#!/usr/bin/env bash
# tests/fm-tool-spool.test.sh - tests for tool schema deferral & tool output spooling guards.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-tool-spool)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/state/tool-outputs"

# 1. Script parsing test
test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-tool-spool.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-tool-spool.sh must parse cleanly"
  [ -z "$out" ] || fail "bash -n bin/fm-tool-spool.sh emitted unexpected output: $out"

  out=$(bash -n "$ROOT/bin/fm-tool-spool-lib.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-tool-spool-lib.sh must parse cleanly"
  [ -z "$out" ] || fail "bash -n bin/fm-tool-spool-lib.sh emitted unexpected output: $out"

  pass "fm-tool-spool.sh & fm-tool-spool-lib.sh: bash -n succeeds"
}

# 2. Small output passthrough
test_small_output_passthrough() {
  local out rc
  out=$(FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-tool-spool.sh" wrap -- printf "small output line 1\nsmall output line 2\n")
  rc=$?
  expect_code 0 "$rc" "fm-tool-spool.sh wrap small command must succeed"
  echo "$out" | grep -q "small output line 1" || fail "small output line 1 missing"
  echo "$out" | grep -q "small output line 2" || fail "small output line 2 missing"
  pass "fm-tool-spool.sh: small output passes through directly"
}

# 3. Large output spooling guard
test_large_output_spooling() {
  local out rc
  # Generate 200 lines
  out=$(FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-tool-spool.sh" wrap --max-lines 20 -- seq 1 200)
  rc=$?
  expect_code 0 "$rc" "fm-tool-spool.sh wrap large command must succeed"
  echo "$out" | grep -q "output truncated" || fail "truncation notice missing from spooled output"
  echo "$out" | grep -q "Total lines: 200" || fail "total line count missing from spooled output"
  echo "$out" | grep -q "Full output saved to:" || fail "output log path missing from spooled output"

  # Extract output path and verify full 200 lines exist there
  local log_path
  log_path=$(echo "$out" | grep "Full output saved to:" | sed 's/.*Full output saved to: //')
  [ -f "$log_path" ] || fail "spooled log file $log_path does not exist"
  local count
  count=$(wc -l < "$log_path" | tr -d ' ')
  [ "$count" -eq 200 ] || fail "spooled log file expected 200 lines, got $count"

  pass "fm-tool-spool.sh: large output is spooled to file with structured preview"
}

# 4. On-demand tool discovery
test_tool_discovery() {
  local out rc
  out=$(FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-tool-spool.sh" discover "git")
  rc=$?
  expect_code 0 "$rc" "fm-tool-spool.sh discover git must succeed"
  echo "$out" | grep -q "Tool: git" || fail "tool discovery missing header"

  pass "fm-tool-spool.sh: on-demand tool discovery succeeds"
}

test_script_parses
test_small_output_passthrough
test_large_output_spooling
test_tool_discovery
