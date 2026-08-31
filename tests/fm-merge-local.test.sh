#!/usr/bin/env bash
# Tests for bin/fm-merge-local.sh: the approved local-only landing must
# fast-forward the project's default branch onto the crewmate's task branch,
# and that branch is named through the home's task-branch prefix
# (config/branch-prefix, default fm/; bin/fm-branch-prefix-lib.sh), exactly as
# the scaffolded brief named it. A landing helper that looked only for the
# hardcoded default would strand every custom-prefix home's local-only work.
#
# Matrix:
#   (a) absent config -> lands the default fm/<id> branch (no regression)
#   (b) custom prefix -> lands ardy/<id> and reports that branch
#   (c) custom prefix + only the default branch exists -> loud refusal
#   (d) invalid prefix -> refused before any git action, default branch unmoved
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/home/state"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  printf 'base\n' > "$case_dir/_seed/feature.txt"
  git -C "$case_dir/_seed" add feature.txt
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -qm "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"

  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true

  touch "$case_dir/home/state/.last-watcher-beat"
  fm_write_meta "$case_dir/home/state/task-x1.meta" \
    "project=$case_dir/project" \
    "mode=local-only" \
    "window=fm-task-x1"
  printf '%s\n' "$case_dir"
}

# Commit one file change directly on a branch in the project clone, then
# return the clone to a clean checkout of main.
commit_on_branch() {
  local case_dir=$1 branch=$2 text=$3
  git -C "$case_dir/project" checkout -q -b "$branch" main
  printf '%s\n' "$text" > "$case_dir/project/feature.txt"
  git -C "$case_dir/project" add feature.txt
  git -C "$case_dir/project" -c user.email=t@t -c user.name=t commit -qm "task change"
  git -C "$case_dir/project" checkout -q main
}

run_merge_local() {
  local case_dir=$1
  shift
  FM_HOME="$case_dir/home" \
    "$MERGE_LOCAL" "$@"
}

test_default_prefix_lands_fm_branch() {
  local case_dir out main_before main_after
  case_dir=$(make_case default-prefix)
  commit_on_branch "$case_dir" fm/task-x1 'merged change'
  main_before=$(git -C "$case_dir/project" rev-parse main)

  out=$(run_merge_local "$case_dir" task-x1)

  main_after=$(git -C "$case_dir/project" rev-parse main)
  [ "$main_before" != "$main_after" ] \
    || fail "default-prefix: local main did not advance"
  assert_contains "$out" 'merged fm/task-x1 into local main' \
    "default-prefix: success line must name the default-prefixed branch"
  pass "fm-merge-local lands the default fm/<id> branch when no prefix is configured"
}

test_custom_prefix_lands_renamed_branch() {
  local case_dir out main_before main_after
  case_dir=$(make_case custom-prefix)
  mkdir -p "$case_dir/home/config"
  printf 'ardy\n' > "$case_dir/home/config/branch-prefix"
  commit_on_branch "$case_dir" ardy/task-x1 'merged change'
  main_before=$(git -C "$case_dir/project" rev-parse main)

  out=$(run_merge_local "$case_dir" task-x1)

  main_after=$(git -C "$case_dir/project" rev-parse main)
  [ "$main_before" != "$main_after" ] \
    || fail "custom-prefix: local main did not advance"
  assert_contains "$out" 'merged ardy/task-x1 into local main' \
    "custom-prefix: success line must name the renamed branch"
  pass "fm-merge-local resolves and lands the renamed <prefix>/<id> branch"
}

test_custom_prefix_ignores_default_named_branch() {
  local case_dir out err main_before
  case_dir=$(make_case only-default-branch)
  mkdir -p "$case_dir/home/config"
  printf 'ardy\n' > "$case_dir/home/config/branch-prefix"
  commit_on_branch "$case_dir" fm/task-x1 'stranded change'
  main_before=$(git -C "$case_dir/project" rev-parse main)

  out=$(run_merge_local "$case_dir" task-x1 2> "$case_dir/stderr")
  status=$?
  err=$(cat "$case_dir/stderr")

  expect_code 1 "$status" "only-default-branch: landing must refuse, got $status"
  assert_contains "$err" 'branch ardy/task-x1 does not exist' \
    "only-default-branch: refusal must name the renamed branch it resolved"
  [ "$main_before" = "$(git -C "$case_dir/project" rev-parse main)" ] \
    || fail "only-default-branch: a refused merge moved local main"
  [ -z "$out" ] || fail "only-default-branch: refusal printed success output"
  pass "fm-merge-local refuses loudly when only a default-named branch exists"
}

test_invalid_prefix_refuses_before_any_git_action() {
  local case_dir err main_before status
  case_dir=$(make_case invalid-prefix)
  mkdir -p "$case_dir/home/config"
  printf 'ar/dy\n' > "$case_dir/home/config/branch-prefix"
  commit_on_branch "$case_dir" fm/task-x1 'unmerged change'
  main_before=$(git -C "$case_dir/project" rev-parse main)

  run_merge_local "$case_dir" task-x1 > "$case_dir/out" 2> "$case_dir/stderr"
  status=$?
  err=$(cat "$case_dir/stderr")

  expect_code 1 "$status" "invalid-prefix: landing must refuse, got $status"
  assert_contains "$err" 'branch-prefix' \
    "invalid-prefix: refusal must name the config file"
  assert_contains "$err" 'error:' \
    "invalid-prefix: refusal must be an error line"
  [ "$main_before" = "$(git -C "$case_dir/project" rev-parse main)" ] \
    || fail "invalid-prefix: an invalid prefix must not merge anything"
  [ -s "$case_dir/out" ] && fail "invalid-prefix: refusal printed success output"
  pass "fm-merge-local refuses an invalid prefix before any git action"
}

test_default_prefix_lands_fm_branch
test_custom_prefix_lands_renamed_branch
test_custom_prefix_ignores_default_named_branch
test_invalid_prefix_refuses_before_any_git_action
