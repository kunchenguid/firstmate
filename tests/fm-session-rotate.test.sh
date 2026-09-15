#!/usr/bin/env bash
# tests/fm-session-rotate.test.sh - tests for context watermarks, handoff generation, and automated rotation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-rotate)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/projects"

# 1. Script parsing test
test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-session-rotate.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-session-rotate.sh must parse cleanly"
  [ -z "$out" ] || fail "bash -n bin/fm-session-rotate.sh emitted unexpected output: $out"

  out=$(bash -n "$ROOT/bin/fm-session-rotate-lib.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-session-rotate-lib.sh must parse cleanly"
  [ -z "$out" ] || fail "bash -n bin/fm-session-rotate-lib.sh emitted unexpected output: $out"

  pass "fm-session-rotate.sh & fm-session-rotate-lib.sh: bash -n succeeds"
}

# 2. Handoff generation test
test_handoff_generation() {
  local task_id="task-rotate-01"
  local state_dir="$HOME_DIR/state"

  # Scaffold decisions log
  FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-decision.sh" log "$task_id" \
    --choice "Modular architecture" \
    --rationale "High cohesion, low coupling" \
    --outcome "Clean test separation" \
    --key "arch-dec"

  # Create a dummy worktree git directory
  local wt_dir="$TMP_ROOT/wt-$task_id"
  mkdir -p "$wt_dir"
  git -C "$wt_dir" init -q -b main
  git -C "$wt_dir" config user.email "test@example.com"
  git -C "$wt_dir" config user.name "Test User"
  echo "v1" > "$wt_dir/code.txt"
  git -C "$wt_dir" add code.txt
  git -C "$wt_dir" commit -q -m "Initial commit"

  # Generate handoff
  FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-session-rotate.sh" generate-handoff "$task_id" \
    --worktree "$wt_dir" \
    --summary "Completed core module setup and initial schema" \
    --next "Implement REST endpoints and run unit tests"

  local handoff_file="$state_dir/$task_id.handoff.md"
  [ -f "$handoff_file" ] || fail "handoff file $handoff_file was not generated"

  local content
  content=$(cat "$handoff_file")
  echo "$content" | grep -q "$task_id" || fail "task id missing from handoff"
  echo "$content" | grep -q "Completed core module setup" || fail "summary missing from handoff"
  echo "$content" | grep -q "Implement REST endpoints" || fail "next steps missing from handoff"
  echo "$content" | grep -q "Modular architecture" || fail "decision journal missing from handoff"

  pass "fm-session-rotate: handoff generation aggregates git state, decisions, and next steps"
}

# 3. Watermark check test
test_watermark_check() {
  local task_id="task-watermark-02"
  local state_dir="$HOME_DIR/state"

  # Create status file with simulated token load
  local status_file="$state_dir/$task_id.status"
  python3 -c '
import sys
with open(sys.argv[1], "w") as f:
    for i in range(1000):
        f.write(f"working: step {i} - processing large payload with lots of context data\n")
' "$status_file"

  # Check with low threshold (should trigger rotation needed)
  set +e
  local out rc
  out=$(FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-session-rotate.sh" check "$task_id" --threshold 5000 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "check must exit 1 (rotation needed) when tokens exceed threshold"
  echo "$out" | grep -q "ROTATION_NEEDED" || fail "expected ROTATION_NEEDED status in output"

  # Check with high threshold (should pass / no rotation needed)
  out=$(FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-session-rotate.sh" check "$task_id" --threshold 500000 2>&1)
  rc=$?
  expect_code 0 "$rc" "check must exit 0 (within threshold) when tokens are below threshold"
  echo "$out" | grep -q "WITHIN_BUDGET" || fail "expected WITHIN_BUDGET status in output"

  pass "fm-session-rotate: watermark check correctly identifies 80k/custom threshold triggers"
}

test_rotate_refuses_when_under_threshold() {
  local task_id="task-rotate-refuse-03"
  mkdir -p "$HOME_DIR/state"
  printf 'tiny\n' > "$HOME_DIR/state/$task_id.status"
  set +e
  local out rc
  out=$(FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-session-rotate.sh" rotate "$task_id" --threshold 80000 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "rotate must refuse when estimated tokens are below threshold"
  echo "$out" | grep -q "WITHIN_BUDGET" || fail "under-threshold rotate must report WITHIN_BUDGET"
  echo "$out" | grep -q "rotate refused" || fail "under-threshold rotate must print a refusal"
  echo "$out" | grep -q "fm-control" && fail "under-threshold rotate must not invoke fm-control"
  [ ! -f "$HOME_DIR/state/$task_id.handoff.md" ] || fail "under-threshold rotate must not write a handoff"
  pass "fm-session-rotate: rotate refuses below threshold and does not relaunch"
}

test_script_parses
test_handoff_generation
test_watermark_check
test_rotate_refuses_when_under_threshold
