#!/usr/bin/env bash
# Tests for bin/fm-merge-local.sh: a local-only fast-forward may reconcile
# working-tree dirt only when every dirty path is proven to match the incoming
# branch content or becomes ignored and untracked at that branch head.
#
# Matrix:
#   (a) byte-identical tracked content permits the fast-forward
#   (b) one unresolved modified file refuses and names the path
#   (c) tracked-to-ignored conversion permits and preserves on-disk content
#   (d) branch-ignored untracked content permits and is preserved
#   (e) a diverged branch still refuses
#   (f) a non-default checkout still refuses
#   (g) mixed resolved and unresolved dirt refuses and names the blocker
#   (h) staged content and executable modes must also match the branch
#   (i) repository and global excludes cannot stand in for branch ignore rules
#   (j) already-ignored untracked files are enumerated and retained or refused
set -u

# shellcheck disable=SC1091
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/project"

  git -C "$case_dir/project" init -q
  printf 'tracked base\n' >"$case_dir/project/tracked.txt"
  printf 'resolved base\n' >"$case_dir/project/resolved.txt"
  printf 'unresolved base\n' >"$case_dir/project/unresolved.txt"
  printf 'runtime base\n' >"$case_dir/project/runtime-state.txt"
  git -C "$case_dir/project" add \
    tracked.txt resolved.txt unresolved.txt runtime-state.txt
  git -C "$case_dir/project" commit -qm "base"
  git -C "$case_dir/project" branch -m main
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/branch" main

  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/branch" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only" \
    "yolo=off"
  printf '%s\n' "$case_dir"
}

run_merge_local() {
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$MERGE_LOCAL" task-x1
}

assert_main_reached_branch() {
  local case_dir=$1
  [ "$(git -C "$case_dir/project" rev-parse main)" = \
    "$(git -C "$case_dir/project" rev-parse fm/task-x1)" ] \
    || fail "$2"
}

assert_path_clean() {
  local repo=$1 path=$2
  [ -z "$(git -C "$repo" status --porcelain=v1 --untracked-files=all -- "$path")" ] \
    || fail "$3"
}

test_byte_identical_tracked_content_permits() {
  local case_dir
  case_dir=$(make_case byte-identical)
  printf 'tracked target\n' >"$case_dir/branch/tracked.txt"
  git -C "$case_dir/branch" add tracked.txt
  git -C "$case_dir/branch" commit -qm "resolve tracked drift"
  printf 'tracked target\n' >"$case_dir/project/tracked.txt"

  run_merge_local "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr" \
    || fail "byte-identical: merge should succeed"

  assert_main_reached_branch "$case_dir" \
    "byte-identical: main did not fast-forward to the task branch"
  assert_path_clean "$case_dir/project" tracked.txt \
    "byte-identical: previously dirty tracked path was not clean after merge"
  pass "fm-merge-local permits byte-identical tracked dirt resolved by the branch"
}

test_unresolved_modified_file_refuses_with_path() {
  local case_dir before rc
  case_dir=$(make_case unresolved-modified)
  printf 'branch target\n' >"$case_dir/branch/unresolved.txt"
  git -C "$case_dir/branch" add unresolved.txt
  git -C "$case_dir/branch" commit -qm "incoming change"
  printf 'different local drift\n' >"$case_dir/project/unresolved.txt"
  before=$(git -C "$case_dir/project" rev-parse main)

  set +e
  run_merge_local "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unresolved-modified: merge should refuse"
  assert_grep 'unresolved.txt' "$case_dir/stderr" \
    "unresolved-modified: refusal did not name the unresolved path"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$before" ] \
    || fail "unresolved-modified: refusal advanced main"
  pass "fm-merge-local refuses unresolved modified dirt and names the path"
}

test_untracked_conversion_permits_and_preserves_file() {
  local case_dir before_hash after_hash
  case_dir=$(make_case untracked-conversion)
  git -C "$case_dir/branch" rm -q --cached runtime-state.txt
  printf 'runtime-state.txt\n' >"$case_dir/branch/.gitignore"
  git -C "$case_dir/branch" add .gitignore
  git -C "$case_dir/branch" commit -qm "leave runtime log untracked"
  printf 'runtime base\nruntime append\n' >"$case_dir/project/runtime-state.txt"
  before_hash=$(git -C "$case_dir/project" hash-object -- runtime-state.txt)

  run_merge_local "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr" \
    || fail "untracked-conversion: merge should succeed"

  after_hash=$(git -C "$case_dir/project" hash-object -- runtime-state.txt)
  [ "$after_hash" = "$before_hash" ] \
    || fail "untracked-conversion: merge changed the on-disk runtime file"
  [ -f "$case_dir/project/runtime-state.txt" ] \
    || fail "untracked-conversion: merge removed the on-disk runtime file"
  ! git -C "$case_dir/project" ls-files --error-unmatch runtime-state.txt >/dev/null 2>&1 \
    || fail "untracked-conversion: runtime file remained tracked"
  assert_path_clean "$case_dir/project" runtime-state.txt \
    "untracked-conversion: ignored runtime file remained dirty after merge"
  assert_main_reached_branch "$case_dir" \
    "untracked-conversion: main did not fast-forward to the task branch"
  pass "fm-merge-local preserves a tracked file converted to ignored-untracked"
}

test_untracked_conversion_refuses_divergent_staged_content() {
  local after_hash before before_hash before_index case_dir rc
  case_dir=$(make_case untracked-conversion-staged-content)
  git -C "$case_dir/branch" rm -q --cached runtime-state.txt
  printf 'runtime-state.txt\n' >"$case_dir/branch/.gitignore"
  git -C "$case_dir/branch" add .gitignore
  git -C "$case_dir/branch" commit -qm "leave runtime log untracked"
  printf 'staged runtime state\n' >"$case_dir/project/runtime-state.txt"
  git -C "$case_dir/project" add runtime-state.txt
  printf 'working runtime state\n' >"$case_dir/project/runtime-state.txt"
  before=$(git -C "$case_dir/project" rev-parse main)
  before_index=$(git -C "$case_dir/project" rev-parse :runtime-state.txt)
  before_hash=$(git -C "$case_dir/project" hash-object -- runtime-state.txt)

  set +e
  run_merge_local "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "untracked-conversion-staged-content: merge should refuse"
  assert_grep 'staged content or mode does not match the working-tree copy' \
    "$case_dir/stderr" \
    "untracked-conversion-staged-content: refusal did not diagnose divergent state"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$before" ] \
    || fail "untracked-conversion-staged-content: refusal advanced main"
  [ "$(git -C "$case_dir/project" rev-parse :runtime-state.txt)" = "$before_index" ] \
    || fail "untracked-conversion-staged-content: refusal changed the index"
  after_hash=$(git -C "$case_dir/project" hash-object -- runtime-state.txt)
  [ "$after_hash" = "$before_hash" ] \
    || fail "untracked-conversion-staged-content: refusal changed working content"
  pass "fm-merge-local preserves divergent staged content by refusing conversion"
}

test_untracked_conversion_refuses_divergent_staged_mode() {
  local before before_index case_dir rc
  case_dir=$(make_case untracked-conversion-staged-mode)
  git -C "$case_dir/branch" rm -q --cached runtime-state.txt
  printf 'runtime-state.txt\n' >"$case_dir/branch/.gitignore"
  git -C "$case_dir/branch" add .gitignore
  git -C "$case_dir/branch" commit -qm "leave runtime log untracked"
  chmod +x "$case_dir/project/runtime-state.txt"
  git -C "$case_dir/project" add runtime-state.txt
  chmod -x "$case_dir/project/runtime-state.txt"
  before=$(git -C "$case_dir/project" rev-parse main)
  before_index=$(git -C "$case_dir/project" ls-files --stage -- runtime-state.txt)

  set +e
  run_merge_local "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "untracked-conversion-staged-mode: merge should refuse"
  assert_grep 'staged content or mode does not match the working-tree copy' \
    "$case_dir/stderr" \
    "untracked-conversion-staged-mode: refusal did not diagnose divergent mode"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$before" ] \
    || fail "untracked-conversion-staged-mode: refusal advanced main"
  [ "$(git -C "$case_dir/project" ls-files --stage -- runtime-state.txt)" = \
    "$before_index" ] \
    || fail "untracked-conversion-staged-mode: refusal changed the index mode"
  pass "fm-merge-local preserves divergent staged mode by refusing conversion"
}

test_branch_ignored_untracked_file_permits() {
  local case_dir before_hash after_hash
  case_dir=$(make_case ignored-untracked)
  printf 'scratch-state.txt\n' >"$case_dir/branch/.gitignore"
  git -C "$case_dir/branch" add .gitignore
  git -C "$case_dir/branch" commit -qm "ignore runtime scratch"
  printf 'runtime scratch\n' >"$case_dir/project/scratch-state.txt"
  before_hash=$(git -C "$case_dir/project" hash-object -- scratch-state.txt)

  run_merge_local "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr" \
    || fail "ignored-untracked: merge should succeed"

  after_hash=$(git -C "$case_dir/project" hash-object -- scratch-state.txt)
  [ "$after_hash" = "$before_hash" ] \
    || fail "ignored-untracked: merge changed the untracked file"
  assert_path_clean "$case_dir/project" scratch-state.txt \
    "ignored-untracked: branch-ignored file remained dirty after merge"
  assert_main_reached_branch "$case_dir" \
    "ignored-untracked: main did not fast-forward to the task branch"
  pass "fm-merge-local permits an untracked path ignored at the branch head"
}

test_diverged_branch_still_refuses() {
  local case_dir rc
  case_dir=$(make_case diverged)
  printf 'branch-only\n' >"$case_dir/branch/branch.txt"
  git -C "$case_dir/branch" add branch.txt
  git -C "$case_dir/branch" commit -qm "branch change"
  printf 'main-only\n' >"$case_dir/project/main.txt"
  git -C "$case_dir/project" add main.txt
  git -C "$case_dir/project" commit -qm "main change"

  set +e
  run_merge_local "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "diverged: merge should refuse"
  assert_grep 'is not a fast-forward of main (it has diverged)' "$case_dir/stderr" \
    "diverged: fast-forward refusal changed or disappeared"
  pass "fm-merge-local still refuses a diverged task branch"
}

test_non_default_checkout_still_refuses() {
  local case_dir rc
  case_dir=$(make_case non-default)
  printf 'branch target\n' >"$case_dir/branch/tracked.txt"
  git -C "$case_dir/branch" add tracked.txt
  git -C "$case_dir/branch" commit -qm "branch change"
  git -C "$case_dir/project" checkout -qb other

  set +e
  run_merge_local "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "non-default: merge should refuse"
  assert_grep "is on 'other', expected default branch 'main'; cannot merge safely" \
    "$case_dir/stderr" \
    "non-default: checkout refusal changed or disappeared"
  pass "fm-merge-local still refuses a non-default checkout"
}

test_mixed_resolved_and_unresolved_refuses() {
  local case_dir before rc
  case_dir=$(make_case mixed)
  printf 'resolved target\n' >"$case_dir/branch/resolved.txt"
  printf 'unresolved target\n' >"$case_dir/branch/unresolved.txt"
  git -C "$case_dir/branch" add resolved.txt unresolved.txt
  git -C "$case_dir/branch" commit -qm "incoming mixed changes"
  printf 'resolved target\n' >"$case_dir/project/resolved.txt"
  printf 'different local drift\n' >"$case_dir/project/unresolved.txt"
  before=$(git -C "$case_dir/project" rev-parse main)

  set +e
  run_merge_local "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "mixed: merge should refuse"
  assert_grep 'unresolved.txt' "$case_dir/stderr" \
    "mixed: refusal did not name the unresolved path"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$before" ] \
    || fail "mixed: refusal advanced main despite one unresolved path"
  pass "fm-merge-local refuses a mixed set when any dirty path is unresolved"
}

test_divergent_staged_content_refuses() {
  local case_dir before before_index rc
  case_dir=$(make_case divergent-staged)
  printf 'tracked target\n' >"$case_dir/branch/tracked.txt"
  git -C "$case_dir/branch" add tracked.txt
  git -C "$case_dir/branch" commit -qm "incoming tracked content"
  printf 'staged local content\n' >"$case_dir/project/tracked.txt"
  git -C "$case_dir/project" add tracked.txt
  printf 'tracked target\n' >"$case_dir/project/tracked.txt"
  before=$(git -C "$case_dir/project" rev-parse main)
  before_index=$(git -C "$case_dir/project" rev-parse :tracked.txt)

  set +e
  run_merge_local "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "divergent-staged: merge should refuse"
  assert_grep 'staged content does not match the branch-head blob' \
    "$case_dir/stderr" \
    "divergent-staged: refusal did not diagnose the staged content"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$before" ] \
    || fail "divergent-staged: refusal advanced main"
  [ "$(git -C "$case_dir/project" rev-parse :tracked.txt)" = "$before_index" ] \
    || fail "divergent-staged: refusal changed the staged content"
  pass "fm-merge-local refuses divergent staged content"
}

test_working_tree_mode_must_match() {
  local case_dir before rc
  case_dir=$(make_case mode-mismatch)
  printf 'tracked target\n' >"$case_dir/branch/tracked.txt"
  chmod +x "$case_dir/branch/tracked.txt"
  git -C "$case_dir/branch" add tracked.txt
  git -C "$case_dir/branch" commit -qm "incoming executable"
  printf 'tracked target\n' >"$case_dir/project/tracked.txt"
  chmod -x "$case_dir/project/tracked.txt"
  before=$(git -C "$case_dir/project" rev-parse main)

  set +e
  run_merge_local "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "mode-mismatch: merge should refuse"
  assert_grep 'working-tree mode 100644 does not match branch-head mode 100755' \
    "$case_dir/stderr" \
    "mode-mismatch: refusal did not diagnose the executable mode"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$before" ] \
    || fail "mode-mismatch: refusal advanced main"
  pass "fm-merge-local refuses a working-tree mode mismatch"
}

test_ambient_excludes_do_not_approve_untracked_files() {
  local case_dir before info_exclude rc
  case_dir=$(make_case ambient-excludes)
  info_exclude=$(git -C "$case_dir/project" rev-parse --absolute-git-dir)
  info_exclude="$info_exclude/info/exclude"
  printf 'info-only.txt\n' >>"$info_exclude"
  printf 'global-only.txt\n' >"$case_dir/global-excludes"
  git -C "$case_dir/project" config core.excludesFile "$case_dir/global-excludes"
  printf 'repository exclude\n' >"$case_dir/project/info-only.txt"
  printf 'global exclude\n' >"$case_dir/project/global-only.txt"
  before=$(git -C "$case_dir/project" rev-parse main)

  set +e
  run_merge_local "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "ambient-excludes: merge should refuse"
  assert_grep 'info-only.txt' "$case_dir/stderr" \
    "ambient-excludes: repository-excluded path was not diagnosed"
  assert_grep 'global-only.txt' "$case_dir/stderr" \
    "ambient-excludes: globally excluded path was not diagnosed"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$before" ] \
    || fail "ambient-excludes: refusal advanced main"
  pass "fm-merge-local ignores ambient exclude sources in the target view"
}

test_already_ignored_untracked_file_is_preserved() {
  local case_dir before_hash after_hash
  case_dir=$(make_case already-ignored)
  printf 'generated-state.txt\n' >"$case_dir/project/.gitignore"
  git -C "$case_dir/project" add .gitignore
  git -C "$case_dir/project" commit -qm "ignore generated state"
  git -C "$case_dir/branch" merge -q --ff-only main
  printf 'branch-only\n' >"$case_dir/branch/branch.txt"
  git -C "$case_dir/branch" add branch.txt
  git -C "$case_dir/branch" commit -qm "incoming branch change"
  printf 'generated state\n' >"$case_dir/project/generated-state.txt"
  before_hash=$(git -C "$case_dir/project" hash-object -- generated-state.txt)

  run_merge_local "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr" \
    || fail "already-ignored: merge should succeed"

  after_hash=$(git -C "$case_dir/project" hash-object -- generated-state.txt)
  [ "$after_hash" = "$before_hash" ] \
    || fail "already-ignored: merge changed the ignored untracked file"
  assert_main_reached_branch "$case_dir" \
    "already-ignored: main did not fast-forward to the task branch"
  pass "fm-merge-local preserves an already-ignored untracked file"
}

test_already_ignored_file_tracked_by_target_refuses() {
  local case_dir before rc
  case_dir=$(make_case ignored-to-tracked)
  printf 'generated-state.txt\n' >"$case_dir/project/.gitignore"
  git -C "$case_dir/project" add .gitignore
  git -C "$case_dir/project" commit -qm "ignore generated state"
  git -C "$case_dir/branch" merge -q --ff-only main
  rm "$case_dir/branch/.gitignore"
  printf 'incoming generated state\n' >"$case_dir/branch/generated-state.txt"
  git -C "$case_dir/branch" add -f generated-state.txt
  git -C "$case_dir/branch" add -u
  git -C "$case_dir/branch" commit -qm "track generated state"
  printf 'local generated state\n' >"$case_dir/project/generated-state.txt"
  before=$(git -C "$case_dir/project" rev-parse main)

  set +e
  run_merge_local "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "ignored-to-tracked: merge should refuse"
  assert_grep 'generated-state.txt' "$case_dir/stderr" \
    "ignored-to-tracked: refusal did not name the ignored local file"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$before" ] \
    || fail "ignored-to-tracked: refusal advanced main"
  assert_grep 'local generated state' "$case_dir/project/generated-state.txt" \
    "ignored-to-tracked: refusal overwrote the ignored local file"
  pass "fm-merge-local refuses an ignored file tracked by the target"
}

test_byte_identical_tracked_content_permits
test_unresolved_modified_file_refuses_with_path
test_untracked_conversion_permits_and_preserves_file
test_untracked_conversion_refuses_divergent_staged_content
test_untracked_conversion_refuses_divergent_staged_mode
test_branch_ignored_untracked_file_permits
test_diverged_branch_still_refuses
test_non_default_checkout_still_refuses
test_mixed_resolved_and_unresolved_refuses
test_divergent_staged_content_refuses
test_working_tree_mode_must_match
test_ambient_excludes_do_not_approve_untracked_files
test_already_ignored_untracked_file_is_preserved
test_already_ignored_file_tracked_by_target_refuses
