#!/usr/bin/env bash
# Characterization tests for fm-busy-event.sh's CLI boundary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-busy-event.sh"

test_unknown_command_prints_usage() {
  local output rc=0
  output=$("$SCRIPT" unknown 2>&1) || rc=$?
  expect_code 2 "$rc" "an unknown command must be rejected as usage"
  assert_contains "$output" "usage:" "usage errors must print the command synopsis"
  pass "fm-busy-event.sh: unknown commands are rejected with usage"
}

test_invalid_task_id_is_rejected_before_state_mutation() {
  local state output rc=0
  state=$(fm_test_tmproot fm-busy-event-cli)
  output=$("$SCRIPT" arm "$state" 'bad/id' 2>&1) || rc=$?
  expect_code 1 "$rc" "task IDs containing path separators must be rejected"
  assert_contains "$output" "invalid task id" "invalid task IDs must explain the refusal"
  [ ! -e "$state/bad/id.busy-gen" ] || fail "invalid task ID created a gen sidecar"
  pass "fm-busy-event.sh: invalid task IDs cannot mutate state"
}

test_invalid_arm_arguments_are_rejected_before_state_mutation() {
  local root state output rc=0 leftover
  root=$(fm_test_tmproot fm-busy-event-invalid-arm)
  state="$root/state"
  mkdir -p "$state"

  output=$("$SCRIPT" arm "$state" 'bad id' 2>&1) || rc=$?
  expect_code 1 "$rc" "an invalid task id must be refused"
  assert_contains "$output" "invalid task id" "invalid task IDs must explain the refusal"

  rc=0
  output=$("$SCRIPT" arm "$state" t1 --source 'bad source' 2>&1) || rc=$?
  expect_code 1 "$rc" "an invalid --source token must be refused"
  assert_contains "$output" "invalid --source" "invalid --source must explain the refusal"

  rc=0
  output=$("$SCRIPT" arm "$state" t1 --event 'bad event' 2>&1) || rc=$?
  expect_code 1 "$rc" "an invalid --event token must be refused"
  assert_contains "$output" "invalid --event" "invalid --event must explain the refusal"

  leftover=$(find "$state" -mindepth 1 -print -quit 2>/dev/null || true)
  [ -z "$leftover" ] || fail "invalid arm arguments wrote into the state dir: $leftover"
  pass "fm-busy-event.sh: invalid arm arguments cannot mutate state"
}

test_unknown_command_prints_usage
test_invalid_task_id_is_rejected_before_state_mutation
test_invalid_arm_arguments_are_rejected_before_state_mutation
