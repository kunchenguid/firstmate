#!/usr/bin/env bash
# Behavior tests for the versioned phase-boundary session-state compiler.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-state)
mkdir -p "$TMP_ROOT"
TOOL="$ROOT/bin/fm-session-state.sh"
CANDIDATE="$TMP_ROOT/candidate.json"
TARGET="$TMP_ROOT/session-state.json"

write_valid_candidate() {
  local path=$1
  cat > "$path" <<'JSON'
{
  "schema_version": "firstmate.session-state/v1",
  "task_id": "sample-task",
  "compiled_at": "2026-07-26T12:00:00Z",
  "completed_phase": {
    "name": "implementation",
    "checklist": [
      {"item": "feature implemented", "status": "done"},
      {"item": "focused tests passed", "status": "done"}
    ]
  },
  "deviations": [
    {"summary": "fixture deviation", "disposition": "accepted within scope"}
  ],
  "decisions": [
    {"summary": "use the existing interface", "authority": "worker"}
  ],
  "evidence_pointers": ["tests/fm-session-state.test.sh"],
  "budget": {
    "iteration_cap": 8,
    "iterations_used": 3,
    "wall_clock_deadline": "2026-07-26T18:00:00Z",
    "token_budget": 50000,
    "tokens_used": 12000
  },
  "next_phase": {
    "name": "validation",
    "acceptance_criteria": ["all required checks pass"],
    "resume_action": "run the focused validation suite"
  }
}
JSON
}

test_schema_is_versioned_and_complete() {
  local schema
  schema=$($TOOL schema) || fail "schema command failed"
  # shellcheck disable=SC2016  # JSON Schema uses a literal $id property.
  assert_contains "$schema" '"$id": "urn:firstmate:session-state:v1"' \
    "schema lost its versioned identifier"
  for field in completed_phase deviations decisions evidence_pointers budget acceptance_criteria resume_action; do
    assert_contains "$schema" "\"$field\"" "schema omitted required field $field"
  done
  assert_contains "$schema" 'budget.iterations_used must not exceed budget.iteration_cap' \
    "schema omitted the iteration-cap invariant enforced by the validator"
  assert_contains "$schema" 'budget.tokens_used must be null when unavailable or must not exceed budget.token_budget' \
    "schema omitted the token-budget invariant enforced by the validator"
  printf '%s\n' "$schema" | jq -e . >/dev/null || fail "schema command emitted invalid JSON"
  pass "fm-session-state: schema is versioned and carries the phase-boundary contract"
}

test_validate_accepts_complete_state() {
  write_valid_candidate "$CANDIDATE"
  "$TOOL" validate "$CANDIDATE" >/dev/null 2>&1 \
    || fail "validator rejected a complete v1 state"
  pass "fm-session-state: validator accepts complete v1 state"
}

test_compile_replaces_atomically_after_validation() {
  local before after status=0
  write_valid_candidate "$CANDIDATE"
  printf 'old valid state placeholder\n' > "$TARGET"
  "$TOOL" compile "$CANDIDATE" "$TARGET" >/dev/null 2>&1 \
    || fail "compiler rejected a complete candidate"
  "$TOOL" validate "$TARGET" >/dev/null 2>&1 \
    || fail "compiled canonical state is invalid"
  assert_contains "$(cat "$TARGET")" '"name": "validation"' \
    "compiled state lost the exact resume phase"
  if find "$TMP_ROOT" -maxdepth 1 -name '.session-state.compile.*' | grep . >/dev/null; then
    fail "compiler left a phase-boundary temporary file behind"
  fi

  before=$(shasum -a 256 "$TARGET" | awk '{print $1}')
  jq '.budget.iterations_used = 9' "$CANDIDATE" > "$TMP_ROOT/invalid.json"
  "$TOOL" compile "$TMP_ROOT/invalid.json" "$TARGET" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "compiler accepted iterations beyond the declared cap"
  after=$(shasum -a 256 "$TARGET" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "failed iteration-cap compile changed the previous canonical state"

  status=0
  jq '.budget.tokens_used = 50001' "$CANDIDATE" > "$TMP_ROOT/invalid-token-budget.json"
  "$TOOL" compile "$TMP_ROOT/invalid-token-budget.json" "$TARGET" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "compiler accepted tokens beyond the declared budget"
  after=$(shasum -a 256 "$TARGET" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "failed token-budget compile changed the previous canonical state"
  pass "fm-session-state: compile publishes valid state atomically and preserves prior state on failure"
}

test_validate_rejects_incomplete_boundary() {
  local status=0
  write_valid_candidate "$CANDIDATE"
  jq 'del(.next_phase.resume_action)' "$CANDIDATE" > "$TMP_ROOT/incomplete.json"
  "$TOOL" validate "$TMP_ROOT/incomplete.json" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "validator accepted a boundary without an exact resume action"
  pass "fm-session-state: validator rejects an incomplete phase boundary"
}

test_schema_is_versioned_and_complete
test_validate_accepts_complete_state
test_compile_replaces_atomically_after_validation
test_validate_rejects_incomplete_boundary
