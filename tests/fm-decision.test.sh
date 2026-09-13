#!/usr/bin/env bash
# tests/fm-decision.test.sh - tests for the 4-layer decision logging engine.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-decision)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"

# 1. Script parsing test
test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-decision.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-decision.sh must parse cleanly"
  [ -z "$out" ] || fail "bash -n bin/fm-decision.sh emitted unexpected output: $out"

  out=$(bash -n "$ROOT/bin/fm-decision-lib.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-decision-lib.sh must parse cleanly"
  [ -z "$out" ] || fail "bash -n bin/fm-decision-lib.sh emitted unexpected output: $out"

  pass "fm-decision.sh & fm-decision-lib.sh: bash -n succeeds"
}

# 2. Decision logging and retrieval test
test_decision_log_and_list() {
  local task_id="task-test-01"
  local state_dir="$HOME_DIR/state"

  # Log a decision
  FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-decision.sh" log "$task_id" \
    --choice "Direct REST integration" \
    --rationale "Low latency and native status" \
    --rejected-opt "File polling:High disk IO" \
    --rejected-opt "WebSockets:Complexity overhead" \
    --constraint "Herdr daemon must be active" \
    --constraint "Max timeout 180s" \
    --outcome "Achieved sub-50ms latency" \
    --key "arch-01"
  local rc=$?
  expect_code 0 "$rc" "fm-decision.sh log must succeed"

  local dec_file="$state_dir/$task_id.decisions.jsonl"
  [ -f "$dec_file" ] || fail "decision log file $dec_file was not created"

  # Verify JSON contents
  local content
  content=$(cat "$dec_file")
  echo "$content" | grep -q "Direct REST integration" || fail "choice not found in decisions file"
  echo "$content" | grep -q "File polling" || fail "rejected option not found in decisions file"
  echo "$content" | grep -q "Herdr daemon must be active" || fail "constraint not found in decisions file"
  echo "$content" | grep -q "Achieved sub-50ms latency" || fail "outcome not found in decisions file"

  # Test list output
  local list_out
  list_out=$(FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-decision.sh" list "$task_id")
  echo "$list_out" | grep -q "arch-01" || fail "fm-decision.sh list did not output decision key"
  echo "$list_out" | grep -q "Direct REST integration" || fail "fm-decision.sh list did not output choice"

  # Test show output
  local show_out
  show_out=$(FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-decision.sh" show "$task_id" "arch-01")
  echo "$show_out" | grep -q "Low latency" || fail "fm-decision.sh show did not output rationale"

  pass "fm-decision: logging, listing, and showing decisions in jsonl succeeds"
}

# 3. Library API programmatic test
test_decision_lib_api() {
  local task_id="task-lib-02"
  local state_dir="$HOME_DIR/state"

  bash -c '
    . "'"$ROOT"'/bin/fm-decision-lib.sh"
    fm_decision_log "'"$state_dir"'" "'"$task_id"'" \
      "PostgreSQL" \
      "ACID compliance and JSONB support" \
      "[{\"option\":\"MongoDB\",\"reason\":\"Document model not needed\"},{\"option\":\"SQLite\",\"reason\":\"Multi-writer concurrency needed\"}]" \
      "[\"Postgres 16+\",\"Max 100 connections\"]" \
      "Database schema migrated and verified" \
      "db-choice"
  '
  local rc=$?
  expect_code 0 "$rc" "fm_decision_log programmatic API must succeed"

  local dec_file="$state_dir/$task_id.decisions.jsonl"
  [ -f "$dec_file" ] || fail "decision log file $dec_file was not created by lib API"

  local content
  content=$(cat "$dec_file")
  echo "$content" | grep -q "PostgreSQL" || fail "choice missing from lib-generated log"
  echo "$content" | grep -q "MongoDB" || fail "rejected options missing from lib-generated log"

  pass "fm-decision-lib.sh: programmatic library functions succeed"
}

test_script_parses
test_decision_log_and_list
test_decision_lib_api
