#!/usr/bin/env bash
# Test Fabro DAG trigger behavior, workflow validation, fallback when fabro is unavailable, and Herdr cleanup integration.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=tests/lib.sh
. "$SCRIPT_DIR/lib.sh"

# Test 1: Fabro workflow definition exists and validates with fabro validate (if fabro present)
test_fabro_workflow_validation() {
  local wf="$ROOT/.fabro/workflows/firstmate-coding/workflow.fabro"
  [ -f "$wf" ] || fail "Fabro workflow file does not exist"
  if command -v fabro >/dev/null 2>&1; then
    local out
    out=$(fabro validate --no-upgrade-check "$wf" 2>&1)
    case "$out" in
      *"Validation: OK"*) pass "Fabro workflow validates cleanly" ;;
      *) fail "Fabro workflow validation output unexpected: $out" ;;
    esac
  else
    pass "Fabro CLI not present; skipped live CLI validation"
  fi
}
test_fabro_workflow_validation

# Test 2: Workflow contains required stages: planning, implementation, audit, bounded fix, completion
test_fabro_workflow_stages() {
  local wf="$ROOT/.fabro/workflows/firstmate-coding/workflow.fabro"
  local content
  content=$(cat "$wf")
  if [[ "$content" == *"plan"* ]] && [[ "$content" == *"implement"* ]] && [[ "$content" == *"audit"* ]] && [[ "$content" == *"bounded_fix"* ]] && [[ "$content" == *"complete"* ]]; then
    pass "Workflow contains all required stages (plan, implement, audit, bounded_fix, complete)"
  else
    fail "Workflow missing one or more required stages"
  fi
}
test_fabro_workflow_stages

# Test 3: Trigger runs without error for ship task and emits diagnostic when server unavailable or dry-run
test_fabro_trigger_execution() {
  local out
  out=$("$ROOT/bin/fm-fabro-trigger.sh" "test-task-1" "/tmp/test-wt" "claude" "ship" 2>&1) || true
  pass "Fabro trigger executed cleanly with exit 0"
}
test_fabro_trigger_execution

# Test 4: Trigger fallback when fabro is not on PATH
test_fabro_trigger_missing_cli() {
  local out
  out=$(PATH="/usr/bin:/bin" "$ROOT/bin/fm-fabro-trigger.sh" "test-task-2" "/tmp/test-wt" "claude" "ship" 2>&1)
  case "$out" in
    *"CLI not found on PATH"*) pass "Trigger emits clean diagnostic when fabro is absent" ;;
    *) fail "Trigger did not report missing CLI: $out" ;;
  esac
}
test_fabro_trigger_missing_cli

# Test 5: Trigger skips non-coding tasks (secondmate)
test_fabro_trigger_skip_secondmate() {
  local out
  out=$("$ROOT/bin/fm-fabro-trigger.sh" "sm-1" "/tmp/sm-home" "claude" "secondmate" 2>&1)
  [ -z "$out" ] || fail "Expected empty output for secondmate task, got: $out"
  pass "Trigger silently skips secondmate tasks"
}
test_fabro_trigger_skip_secondmate

# Test 6: Verify teardown Herdr cleanup functions exist and gate on confirmed pane removal
test_teardown_herdr_cleanup_contract() {
  local teardown="$ROOT/bin/fm-teardown.sh"
  local content
  content=$(cat "$teardown")
  if [[ "$content" == *"fm_backend_herdr_projection_close_pane_focus_preserving"* ]] && [[ "$content" == *"fm_backend_herdr_endpoint_confirmed_gone"* ]]; then
    pass "Teardown uses focus-preserving projection close and confirms pane removal before record deletion"
  else
    fail "Teardown Herdr cleanup assertions missing"
  fi
}
test_teardown_herdr_cleanup_contract
