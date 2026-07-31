#!/usr/bin/env bash
# tests/fm-format-task-cost.test.sh - behavior tests for
# bin/fm-format-task-cost.sh, the per-agent cost estimator that
# bin/fm-session-start.sh's backlog digest appends to each task line.
#
# Coverage:
#   - model/effort -> cost matrix
#   - missing task id / missing state/<id>.meta -> silent, exit 0
#   - resolves state/ via $FM_HOME regardless of the caller's cwd (the actual
#     bug: it used to hardcode a "state/" path relative to cwd)
#   - FM_STATE_OVERRIDE takes precedence over FM_HOME/state
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FORMAT_COST="$ROOT/bin/fm-format-task-cost.sh"
TMP_ROOT=$(fm_test_tmproot fm-format-task-cost)

new_home() {
  local name=$1
  local home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

test_model_effort_matrix() {
  local home meta
  home=$(new_home matrix)
  meta="$home/state/t.meta"

  fm_write_meta "$meta" "model=opus" "effort=xhigh"
  expect_cost() {
    local expected got
    expected=$1
    got=$(FM_HOME="$home" "$FORMAT_COST" t)
    [ "$got" = "$expected" ] || fail "model=$MODEL_UNDER_TEST effort=$EFFORT_UNDER_TEST: expected $expected, got $got"
  }
  MODEL_UNDER_TEST=opus EFFORT_UNDER_TEST=xhigh expect_cost "~\$50"

  fm_write_meta "$meta" "model=opus" "effort=low"
  MODEL_UNDER_TEST=opus EFFORT_UNDER_TEST=low expect_cost "~\$20"

  fm_write_meta "$meta" "model=sonnet" "effort=medium"
  MODEL_UNDER_TEST=sonnet EFFORT_UNDER_TEST=medium expect_cost "~\$10"

  fm_write_meta "$meta" "model=sonnet" "effort=high"
  MODEL_UNDER_TEST=sonnet EFFORT_UNDER_TEST=high expect_cost "~\$15"

  fm_write_meta "$meta" "model=haiku" "effort=low"
  MODEL_UNDER_TEST=haiku EFFORT_UNDER_TEST=low expect_cost "~\$2"

  pass "cost matrix matches model base rate times effort multiplier"
}

test_unknown_model_and_effort_fall_back_to_sonnet_medium() {
  local home meta got
  home=$(new_home unknown)
  meta="$home/state/t.meta"
  fm_write_meta "$meta" "model=default" "effort=low"

  got=$(FM_HOME="$home" "$FORMAT_COST" t)
  [ "$got" = "~\$8" ] || fail "unrecognized model should fall back to the sonnet base rate; got $got"

  pass "an unrecognized model/effort value falls back to the sonnet/medium base rate and multiplier"
}

test_missing_taskid_is_silent() {
  local home out status=0
  home=$(new_home no-taskid)
  out=$(FM_HOME="$home" "$FORMAT_COST" 2>&1) || status=$?
  expect_code 0 "$status" "missing task id must exit 0"
  [ -z "$out" ] || fail "missing task id must print nothing, got: $out"

  pass "a missing task id argument is silent and exits 0"
}

test_missing_meta_file_is_silent() {
  local home out status=0
  home=$(new_home no-meta)
  out=$(FM_HOME="$home" "$FORMAT_COST" no-such-task 2>&1) || status=$?
  expect_code 0 "$status" "a task with no recorded metadata must exit 0"
  [ -z "$out" ] || fail "a task with no recorded metadata must print nothing, got: $out"

  pass "a task id with no state/<id>.meta file is silent and exits 0"
}

test_resolves_state_via_fm_home_regardless_of_cwd() {
  local home meta got
  home=$(new_home cwd-independence)
  meta="$home/state/cwd-task.meta"
  fm_write_meta "$meta" "model=opus" "effort=low"

  got=$(cd /tmp && FM_HOME="$home" "$FORMAT_COST" cwd-task)
  [ "$got" = "~\$20" ] || fail "invoking from an unrelated cwd (/tmp) must still resolve state/ via \$FM_HOME; got $got"

  pass "state/<id>.meta resolves via \$FM_HOME, not the caller's cwd"
}

test_fm_state_override_takes_precedence() {
  local home override_dir meta got
  home=$(new_home state-override-home)
  override_dir="$TMP_ROOT/state-override-dir"
  mkdir -p "$override_dir"
  meta="$override_dir/override-task.meta"
  fm_write_meta "$meta" "model=haiku" "effort=xhigh"

  got=$(FM_HOME="$home" FM_STATE_OVERRIDE="$override_dir" "$FORMAT_COST" override-task)
  [ "$got" = "~\$4" ] || fail "FM_STATE_OVERRIDE must take precedence over \$FM_HOME/state; got $got"

  pass "FM_STATE_OVERRIDE takes precedence over \$FM_HOME/state"
}

test_model_effort_matrix
test_unknown_model_and_effort_fall_back_to_sonnet_medium
test_missing_taskid_is_silent
test_missing_meta_file_is_silent
test_resolves_state_via_fm_home_regardless_of_cwd
test_fm_state_override_takes_precedence
