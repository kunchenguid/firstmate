#!/usr/bin/env bash
# Tests for bin/fm-merge-local.sh: fast-forwards the local default branch to the
# crewmate's fm/<id> branch for local-only projects and for Firstmate's own
# repository (where local main is authoritative).
#
# Matrix:
#   (a) fast-forwards a clean local-only project branch
#   (b) fast-forwards a no-mistakes task on Firstmate's own repository (FM_ROOT)
#   (c) fast-forwards a direct-PR task on Firstmate's own repository (FM_ROOT)
#   (d) refuses a no-mistakes task on an ordinary project (not local-only)
#   (e) refuses a direct-PR task on an ordinary project (not local-only)
#   (f) refuses when task meta is missing
#   (g) refuses when project directory does not exist or is not a git repo
#   (h) refuses when branch fm/<id> does not exist
#   (i) refuses when project checkout is not on its default branch
#   (j) refuses when project checkout is dirty
#   (k) refuses when branch has diverged (not a fast-forward)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)

make_repo() {
  local dir=$1 default=${2:-main}
  mkdir -p "$dir"
  git -C "$dir" init --quiet --initial-branch="$default"
  echo "initial" > "$dir/file.txt"
  git -C "$dir" add file.txt
  git -C "$dir" commit --quiet -m "initial commit"
}

test_fast_forward_local_only_project() {
  local case_dir proj_dir state_dir rc before after
  case_dir="$TMP_ROOT/local-only-clean"
  proj_dir="$case_dir/projects/myproj"
  state_dir="$case_dir/state"
  mkdir -p "$state_dir"
  make_repo "$proj_dir" main

  git -C "$proj_dir" checkout -b fm/task-loc1 --quiet
  echo "feature" >> "$proj_dir/file.txt"
  git -C "$proj_dir" commit --quiet -am "feature commit"
  git -C "$proj_dir" checkout main --quiet

  fm_write_meta "$state_dir/task-loc1.meta" \
    "window=fm-task-loc1" \
    "worktree=$case_dir/wt" \
    "project=$proj_dir" \
    "kind=ship" \
    "mode=local-only"

  before=$(git -C "$proj_dir" rev-parse HEAD)

  set +e
  FM_ROOT_OVERRIDE="$case_dir/fmroot" \
  FM_HOME="$case_dir/fmroot" \
  FM_STATE_OVERRIDE="$state_dir" \
    "$MERGE_LOCAL" task-loc1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "local-only: fm-merge-local should succeed"
  after=$(git -C "$proj_dir" rev-parse HEAD)
  [ "$before" != "$after" ] || fail "local-only: default branch was not advanced"
  assert_grep "merged fm/task-loc1 into local main" "$case_dir/stdout" \
    "local-only: success message was not printed"
  pass "fm-merge-local fast-forwards a clean local-only project branch"
}

test_fast_forward_no_mistakes_firstmate_repo() {
  local case_dir fm_root state_dir rc before after
  case_dir="$TMP_ROOT/fm-no-mistakes"
  fm_root="$case_dir/firstmate"
  state_dir="$case_dir/state"
  mkdir -p "$state_dir"
  make_repo "$fm_root" main

  git -C "$fm_root" checkout -b fm/task-fm1 --quiet
  echo "firstmate feature" >> "$fm_root/file.txt"
  git -C "$fm_root" commit --quiet -am "firstmate fix"
  git -C "$fm_root" checkout main --quiet

  fm_write_meta "$state_dir/task-fm1.meta" \
    "window=fm-task-fm1" \
    "worktree=$case_dir/wt" \
    "project=$fm_root" \
    "kind=ship" \
    "mode=no-mistakes"

  before=$(git -C "$fm_root" rev-parse HEAD)

  set +e
  FM_ROOT_OVERRIDE="$fm_root" \
  FM_HOME="$fm_root" \
  FM_STATE_OVERRIDE="$state_dir" \
    "$MERGE_LOCAL" task-fm1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "firstmate no-mistakes: fm-merge-local should succeed"
  after=$(git -C "$fm_root" rev-parse HEAD)
  [ "$before" != "$after" ] || fail "firstmate no-mistakes: default branch was not advanced"
  assert_grep "merged fm/task-fm1 into local main" "$case_dir/stdout" \
    "firstmate no-mistakes: success message was not printed"
  pass "fm-merge-local fast-forwards a no-mistakes task on Firstmate's own repository"
}

test_fast_forward_direct_pr_firstmate_repo() {
  local case_dir fm_root state_dir rc before after
  case_dir="$TMP_ROOT/fm-direct-pr"
  fm_root="$case_dir/firstmate"
  state_dir="$case_dir/state"
  mkdir -p "$state_dir"
  make_repo "$fm_root" main

  git -C "$fm_root" checkout -b fm/task-fm2 --quiet
  echo "direct PR fix" >> "$fm_root/file.txt"
  git -C "$fm_root" commit --quiet -am "direct pr fix"
  git -C "$fm_root" checkout main --quiet

  fm_write_meta "$state_dir/task-fm2.meta" \
    "window=fm-task-fm2" \
    "worktree=$case_dir/wt" \
    "project=$fm_root" \
    "kind=ship" \
    "mode=direct-PR"

  before=$(git -C "$fm_root" rev-parse HEAD)

  set +e
  FM_ROOT_OVERRIDE="$fm_root" \
  FM_HOME="$fm_root" \
  FM_STATE_OVERRIDE="$state_dir" \
    "$MERGE_LOCAL" task-fm2 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "firstmate direct-PR: fm-merge-local should succeed"
  after=$(git -C "$fm_root" rev-parse HEAD)
  [ "$before" != "$after" ] || fail "firstmate direct-PR: default branch was not advanced"
  assert_grep "merged fm/task-fm2 into local main" "$case_dir/stdout" \
    "firstmate direct-PR: success message was not printed"
  pass "fm-merge-local fast-forwards a direct-PR task on Firstmate's own repository"
}

test_refuses_no_mistakes_ordinary_project() {
  local case_dir proj_dir state_dir rc
  case_dir="$TMP_ROOT/ordinary-no-mistakes"
  proj_dir="$case_dir/projects/otherproj"
  state_dir="$case_dir/state"
  mkdir -p "$state_dir"
  make_repo "$proj_dir" main

  git -C "$proj_dir" checkout -b fm/task-ord1 --quiet
  echo "change" >> "$proj_dir/file.txt"
  git -C "$proj_dir" commit --quiet -am "change"
  git -C "$proj_dir" checkout main --quiet

  fm_write_meta "$state_dir/task-ord1.meta" \
    "window=fm-task-ord1" \
    "worktree=$case_dir/wt" \
    "project=$proj_dir" \
    "kind=ship" \
    "mode=no-mistakes"

  set +e
  FM_ROOT_OVERRIDE="$case_dir/fmroot" \
  FM_HOME="$case_dir/fmroot" \
  FM_STATE_OVERRIDE="$state_dir" \
    "$MERGE_LOCAL" task-ord1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "ordinary no-mistakes: fm-merge-local should refuse"
  assert_grep "is mode=no-mistakes on $proj_dir, not local-only; merge PR tasks with bin/fm-pr-merge.sh" "$case_dir/stderr" \
    "ordinary no-mistakes: refusal did not explain mode"
  pass "fm-merge-local refuses a no-mistakes task on an ordinary project"
}

test_refuses_direct_pr_ordinary_project() {
  local case_dir proj_dir state_dir rc
  case_dir="$TMP_ROOT/ordinary-direct-pr"
  proj_dir="$case_dir/projects/otherproj2"
  state_dir="$case_dir/state"
  mkdir -p "$state_dir"
  make_repo "$proj_dir" main

  git -C "$proj_dir" checkout -b fm/task-ord2 --quiet
  echo "change" >> "$proj_dir/file.txt"
  git -C "$proj_dir" commit --quiet -am "change"
  git -C "$proj_dir" checkout main --quiet

  fm_write_meta "$state_dir/task-ord2.meta" \
    "window=fm-task-ord2" \
    "worktree=$case_dir/wt" \
    "project=$proj_dir" \
    "kind=ship" \
    "mode=direct-PR"

  set +e
  FM_ROOT_OVERRIDE="$case_dir/fmroot" \
  FM_HOME="$case_dir/fmroot" \
  FM_STATE_OVERRIDE="$state_dir" \
    "$MERGE_LOCAL" task-ord2 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "ordinary direct-PR: fm-merge-local should refuse"
  assert_grep "is mode=direct-PR on $proj_dir, not local-only; merge PR tasks with bin/fm-pr-merge.sh" "$case_dir/stderr" \
    "ordinary direct-PR: refusal did not explain mode"
  pass "fm-merge-local refuses a direct-PR task on an ordinary project"
}

test_refuses_missing_meta() {
  local case_dir state_dir rc
  case_dir="$TMP_ROOT/missing-meta"
  state_dir="$case_dir/state"
  mkdir -p "$state_dir"

  set +e
  FM_ROOT_OVERRIDE="$case_dir/fmroot" \
  FM_HOME="$case_dir/fmroot" \
  FM_STATE_OVERRIDE="$state_dir" \
    "$MERGE_LOCAL" missing-task > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-merge-local should refuse"
  assert_grep "error: no meta for task missing-task" "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  pass "fm-merge-local refuses when task meta is missing"
}

test_refuses_missing_project() {
  local case_dir state_dir rc
  case_dir="$TMP_ROOT/missing-proj"
  state_dir="$case_dir/state"
  mkdir -p "$state_dir"

  fm_write_meta "$state_dir/task-missproj.meta" \
    "window=fm-task-missproj" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/nonexistent" \
    "kind=ship" \
    "mode=local-only"

  set +e
  FM_ROOT_OVERRIDE="$case_dir/fmroot" \
  FM_HOME="$case_dir/fmroot" \
  FM_STATE_OVERRIDE="$state_dir" \
    "$MERGE_LOCAL" task-missproj > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-proj: fm-merge-local should refuse"
  assert_grep "project directory '$case_dir/nonexistent' does not exist" "$case_dir/stderr" \
    "missing-proj: refusal did not explain missing project"
  pass "fm-merge-local refuses when project directory does not exist"
}

test_refuses_missing_branch() {
  local case_dir proj_dir state_dir rc
  case_dir="$TMP_ROOT/missing-branch"
  proj_dir="$case_dir/projects/myproj"
  state_dir="$case_dir/state"
  mkdir -p "$state_dir"
  make_repo "$proj_dir" main

  fm_write_meta "$state_dir/task-nobranch.meta" \
    "window=fm-task-nobranch" \
    "worktree=$case_dir/wt" \
    "project=$proj_dir" \
    "kind=ship" \
    "mode=local-only"

  set +e
  FM_ROOT_OVERRIDE="$case_dir/fmroot" \
  FM_HOME="$case_dir/fmroot" \
  FM_STATE_OVERRIDE="$state_dir" \
    "$MERGE_LOCAL" task-nobranch > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-branch: fm-merge-local should refuse"
  assert_grep "branch fm/task-nobranch does not exist in $proj_dir" "$case_dir/stderr" \
    "missing-branch: refusal did not explain missing branch"
  pass "fm-merge-local refuses when branch fm/<id> does not exist"
}

test_refuses_dirty_project() {
  local case_dir proj_dir state_dir rc
  case_dir="$TMP_ROOT/dirty-proj"
  proj_dir="$case_dir/projects/myproj"
  state_dir="$case_dir/state"
  mkdir -p "$state_dir"
  make_repo "$proj_dir" main

  git -C "$proj_dir" checkout -b fm/task-dirty --quiet
  echo "change" >> "$proj_dir/file.txt"
  git -C "$proj_dir" commit --quiet -am "change"
  git -C "$proj_dir" checkout main --quiet
  echo "uncommitted edit" >> "$proj_dir/file.txt"

  fm_write_meta "$state_dir/task-dirty.meta" \
    "window=fm-task-dirty" \
    "worktree=$case_dir/wt" \
    "project=$proj_dir" \
    "kind=ship" \
    "mode=local-only"

  set +e
  FM_ROOT_OVERRIDE="$case_dir/fmroot" \
  FM_HOME="$case_dir/fmroot" \
  FM_STATE_OVERRIDE="$state_dir" \
    "$MERGE_LOCAL" task-dirty > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "dirty-proj: fm-merge-local should refuse"
  assert_grep "has a dirty working tree; refusing to merge into it" "$case_dir/stderr" \
    "dirty-proj: refusal did not explain dirty working tree"
  pass "fm-merge-local refuses when project checkout is dirty"
}

test_refuses_off_default_project() {
  local case_dir proj_dir state_dir rc
  case_dir="$TMP_ROOT/off-default-proj"
  proj_dir="$case_dir/projects/myproj"
  state_dir="$case_dir/state"
  mkdir -p "$state_dir"
  make_repo "$proj_dir" main

  git -C "$proj_dir" checkout -b other-branch --quiet
  git -C "$proj_dir" checkout -b fm/task-offdef --quiet
  echo "change" >> "$proj_dir/file.txt"
  git -C "$proj_dir" commit --quiet -am "change"
  git -C "$proj_dir" checkout other-branch --quiet

  fm_write_meta "$state_dir/task-offdef.meta" \
    "window=fm-task-offdef" \
    "worktree=$case_dir/wt" \
    "project=$proj_dir" \
    "kind=ship" \
    "mode=local-only"

  set +e
  FM_ROOT_OVERRIDE="$case_dir/fmroot" \
  FM_HOME="$case_dir/fmroot" \
  FM_STATE_OVERRIDE="$state_dir" \
    "$MERGE_LOCAL" task-offdef > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "off-default: fm-merge-local should refuse"
  assert_grep "expected default branch 'main'; cannot merge safely" "$case_dir/stderr" \
    "off-default: refusal did not explain non-default branch"
  pass "fm-merge-local refuses when project checkout is not on its default branch"
}

test_refuses_diverged_branch() {
  local case_dir proj_dir state_dir rc
  case_dir="$TMP_ROOT/diverged-branch"
  proj_dir="$case_dir/projects/myproj"
  state_dir="$case_dir/state"
  mkdir -p "$state_dir"
  make_repo "$proj_dir" main

  git -C "$proj_dir" checkout -b fm/task-div --quiet
  echo "task change" >> "$proj_dir/file.txt"
  git -C "$proj_dir" commit --quiet -am "task change"
  git -C "$proj_dir" checkout main --quiet
  echo "competing change" >> "$proj_dir/other.txt"
  git -C "$proj_dir" add other.txt
  git -C "$proj_dir" commit --quiet -m "competing change on main"

  fm_write_meta "$state_dir/task-div.meta" \
    "window=fm-task-div" \
    "worktree=$case_dir/wt" \
    "project=$proj_dir" \
    "kind=ship" \
    "mode=local-only"

  set +e
  FM_ROOT_OVERRIDE="$case_dir/fmroot" \
  FM_HOME="$case_dir/fmroot" \
  FM_STATE_OVERRIDE="$state_dir" \
    "$MERGE_LOCAL" task-div > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "diverged-branch: fm-merge-local should refuse"
  assert_grep "REFUSED: fm/task-div is not a fast-forward of main (it has diverged)" "$case_dir/stderr" \
    "diverged-branch: refusal did not explain divergence"
  pass "fm-merge-local refuses when branch has diverged (not a fast-forward)"
}

test_fast_forward_local_only_project
test_fast_forward_no_mistakes_firstmate_repo
test_fast_forward_direct_pr_firstmate_repo
test_refuses_no_mistakes_ordinary_project
test_refuses_direct_pr_ordinary_project
test_refuses_missing_meta
test_refuses_missing_project
test_refuses_missing_branch
test_refuses_dirty_project
test_refuses_off_default_project
test_refuses_diverged_branch
