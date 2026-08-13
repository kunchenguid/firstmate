#!/usr/bin/env bash
# Regression tests for bin/fm-merge-local.sh's guarded local-only fast-forward.
# The default target remains the project's default branch, while an explicitly
# approved --target-branch may name only the clean branch already checked out in
# the recorded project. Every case uses throwaway repositories.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)
ID=task-x1
TASK_BRANCH="fm/$ID"

make_case() {
  local name=$1 task_base=$2 checkout_branch=$3 mode=${4:-local-only}
  local case_dir="$TMP_ROOT/$name" project="$TMP_ROOT/$name/project"
  mkdir -p "$case_dir/state" "$project"
  git -C "$project" init -q -b main
  printf '%s\n' base > "$project/base.txt"
  git -C "$project" add base.txt
  git -C "$project" commit -qm base
  git -C "$project" branch integration
  # A dangling remote-tracking symbolic ref is enough to exercise the script's
  # established origin/HEAD default-branch resolution without network access.
  git -C "$project" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

  git -C "$project" checkout -q "$task_base"
  git -C "$project" checkout -q -b "$TASK_BRANCH"
  printf '%s\n' task > "$project/task.txt"
  git -C "$project" add task.txt
  git -C "$project" commit -qm task
  git -C "$project" checkout -q "$checkout_branch"

  fm_write_meta "$case_dir/state/$ID.meta" \
    "project=$project" \
    "kind=ship" \
    "mode=$mode"
  printf '%s\n' "$case_dir"
}

run_merge() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$MERGE_LOCAL" "$@"
}

ref_sha() {
  git -C "$1/project" rev-parse "refs/heads/$2"
}

run_refusal() {
  local case_dir=$1
  shift
  set +e
  run_merge "$case_dir" "$@" > "$case_dir/stdout" 2> "$case_dir/stderr"
  local rc=$?
  set -e
  printf '%s\n' "$rc"
}

test_default_target_compatibility() {
  local case_dir task_sha integration_before
  case_dir=$(make_case default-target main main)
  task_sha=$(ref_sha "$case_dir" "$TASK_BRANCH")
  integration_before=$(ref_sha "$case_dir" integration)

  run_merge "$case_dir" "$ID" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "default-target: merge failed"

  [ "$(ref_sha "$case_dir" main)" = "$task_sha" ] \
    || fail "default-target: default main branch did not fast-forward"
  [ "$(ref_sha "$case_dir" integration)" = "$integration_before" ] \
    || fail "default-target: unrelated integration branch moved"
  assert_grep "merged $TASK_BRANCH into local main" "$case_dir/stdout" \
    "default-target: success did not identify the established default target"
  pass "fm-merge-local preserves default-target fast-forward behavior"
}

test_explicit_integration_target() {
  local case_dir task_sha main_before
  case_dir=$(make_case explicit-target integration integration)
  task_sha=$(ref_sha "$case_dir" "$TASK_BRANCH")
  main_before=$(ref_sha "$case_dir" main)
  # Same-named non-branch refs must not make the fully qualified target ambiguous.
  git -C "$case_dir/project" tag integration "refs/heads/main"

  run_merge "$case_dir" "$ID" --target-branch integration \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "explicit-target: merge failed"

  [ "$(ref_sha "$case_dir" integration)" = "$task_sha" ] \
    || fail "explicit-target: integration branch did not fast-forward"
  [ "$(ref_sha "$case_dir" main)" = "$main_before" ] \
    || fail "explicit-target: default main branch moved"
  [ "$(git -C "$case_dir/project" rev-parse refs/tags/integration)" = "$main_before" ] \
    || fail "explicit-target: same-named tag moved"
  assert_grep "merged $TASK_BRANCH into local integration" "$case_dir/stdout" \
    "explicit-target: success did not identify the integration target"
  pass "fm-merge-local fast-forwards an explicit checked-out integration branch only"
}

test_wrong_checked_out_target_refuses() {
  local case_dir target_before rc
  case_dir=$(make_case wrong-checkout integration main)
  target_before=$(ref_sha "$case_dir" integration)
  rc=$(run_refusal "$case_dir" "$ID" --target-branch integration)

  expect_code 1 "$rc" "wrong-checkout"
  assert_grep "expected target branch 'integration'" "$case_dir/stderr" \
    "wrong-checkout: refusal did not identify the required target"
  [ "$(ref_sha "$case_dir" integration)" = "$target_before" ] \
    || fail "wrong-checkout: target branch moved"
  pass "fm-merge-local refuses to switch or merge a target that is not checked out"
}

test_dirty_target_refuses() {
  local case_dir target_before rc
  case_dir=$(make_case dirty-target integration integration)
  target_before=$(ref_sha "$case_dir" integration)
  printf '%s\n' dirty > "$case_dir/project/untracked.txt"
  rc=$(run_refusal "$case_dir" "$ID" --target-branch integration)

  expect_code 1 "$rc" "dirty-target"
  assert_grep 'has a dirty working tree; refusing to merge into it' "$case_dir/stderr" \
    "dirty-target: refusal did not explain the dirty project"
  [ "$(ref_sha "$case_dir" integration)" = "$target_before" ] \
    || fail "dirty-target: target branch moved"
  pass "fm-merge-local refuses a dirty explicit target"
}

test_nonexistent_and_invalid_targets_refuse() {
  local missing_case invalid_case rc
  missing_case=$(make_case nonexistent-target integration integration)
  rc=$(run_refusal "$missing_case" "$ID" --target-branch absent)
  expect_code 1 "$rc" "nonexistent-target"
  assert_grep "target branch 'absent' does not exist" "$missing_case/stderr" \
    "nonexistent-target: refusal did not identify the missing local branch"

  invalid_case=$(make_case invalid-target integration integration)
  rc=$(run_refusal "$invalid_case" "$ID" --target-branch 'bad..target')
  expect_code 1 "$rc" "invalid-target"
  assert_grep "invalid target branch name 'bad..target'" "$invalid_case/stderr" \
    "invalid-target: refusal did not identify unsafe ref syntax"
  pass "fm-merge-local refuses nonexistent and syntactically unsafe targets"
}

test_divergence_refuses() {
  local case_dir target_before task_before rc
  case_dir=$(make_case divergence main integration)
  printf '%s\n' integration > "$case_dir/project/integration.txt"
  git -C "$case_dir/project" add integration.txt
  git -C "$case_dir/project" commit -qm integration
  target_before=$(ref_sha "$case_dir" integration)
  task_before=$(ref_sha "$case_dir" "$TASK_BRANCH")
  rc=$(run_refusal "$case_dir" "$ID" --target-branch integration)

  expect_code 1 "$rc" "divergence"
  assert_grep "is not a fast-forward of integration (it has diverged)" "$case_dir/stderr" \
    "divergence: refusal did not explain the non-fast-forward"
  [ "$(ref_sha "$case_dir" integration)" = "$target_before" ] \
    || fail "divergence: target branch moved"
  [ "$(ref_sha "$case_dir" "$TASK_BRANCH")" = "$task_before" ] \
    || fail "divergence: task branch moved"
  pass "fm-merge-local refuses divergence without moving either branch"
}

test_non_local_only_mode_refuses() {
  local case_dir target_before rc
  case_dir=$(make_case wrong-mode integration integration direct-PR)
  target_before=$(ref_sha "$case_dir" integration)
  rc=$(run_refusal "$case_dir" "$ID" --target-branch integration)

  expect_code 1 "$rc" "wrong-mode"
  assert_grep 'is mode=direct-PR, not local-only' "$case_dir/stderr" \
    "wrong-mode: refusal did not preserve the local-only boundary"
  [ "$(ref_sha "$case_dir" integration)" = "$target_before" ] \
    || fail "wrong-mode: target branch moved"
  pass "fm-merge-local refuses explicit targets for non-local-only tasks"
}

test_option_errors_refuse() {
  local case_dir before rc
  case_dir=$(make_case option-errors integration integration)
  before=$(ref_sha "$case_dir" integration)

  rc=$(run_refusal "$case_dir" "$ID" --target-branch)
  expect_code 2 "$rc" "missing-target-value"
  assert_grep '--target-branch requires a branch name' "$case_dir/stderr" \
    "missing-target-value: refusal was unclear"

  rc=$(run_refusal "$case_dir" "$ID" --target-branch integration --target-branch main)
  expect_code 2 "$rc" "duplicate-target-option"
  assert_grep '--target-branch may be specified only once' "$case_dir/stderr" \
    "duplicate-target-option: refusal was unclear"

  rc=$(run_refusal "$case_dir" "$ID" --target-branch=integration)
  expect_code 2 "$rc" "malformed-target-option"
  assert_grep 'use --target-branch <branch>' "$case_dir/stderr" \
    "malformed-target-option: refusal was unclear"

  rc=$(run_refusal "$case_dir" "$ID" --unknown)
  expect_code 2 "$rc" "unknown-long-option"
  assert_grep 'unknown option: --unknown' "$case_dir/stderr" \
    "unknown-long-option: refusal was unclear"

  rc=$(run_refusal "$case_dir" "$ID" -x)
  expect_code 2 "$rc" "unknown-short-option"
  assert_grep 'unknown option: -x' "$case_dir/stderr" \
    "unknown-short-option: refusal was unclear"

  [ "$(ref_sha "$case_dir" integration)" = "$before" ] \
    || fail "option-errors: target branch moved"
  pass "fm-merge-local rejects omitted, duplicate, and unknown option forms"
}

test_task_branch_cannot_be_target() {
  local case_dir before rc
  case_dir=$(make_case self-target integration "$TASK_BRANCH")
  before=$(ref_sha "$case_dir" "$TASK_BRANCH")
  rc=$(run_refusal "$case_dir" "$ID" --target-branch "$TASK_BRANCH")

  expect_code 1 "$rc" "self-target"
  assert_grep 'is the task branch; refusing to merge a branch into itself' "$case_dir/stderr" \
    "self-target: refusal did not identify the task/target equality"
  [ "$(ref_sha "$case_dir" "$TASK_BRANCH")" = "$before" ] \
    || fail "self-target: task branch moved"
  pass "fm-merge-local refuses the task branch as its own target"
}

test_default_target_compatibility
test_explicit_integration_target
test_wrong_checked_out_target_refuses
test_dirty_target_refuses
test_nonexistent_and_invalid_targets_refuse
test_divergence_refuses
test_non_local_only_mode_refuses
test_option_errors_refuse
test_task_branch_cannot_be_target
