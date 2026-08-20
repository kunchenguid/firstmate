#!/usr/bin/env bash
# Tests for the guarded local-only fast-forward path.
#
# Matrix:
#   (a) identical unstaged tracked files are detected without project mutation
#   (b) a one-byte-different tracked file keeps the ordinary refusal
#   (c) an otherwise qualifying file plus an untracked file refuses
#   (d) an otherwise qualifying file plus a deleted tracked file refuses
#   (e) a qualifying file staged against HEAD refuses
#   (f) a qualifying dirty tree on a diverged branch refuses
#   (g) a qualifying dirty tree off the default branch refuses
#   (h) a task outside local-only refuses
#   (i) a clean checkout still fast-forwards
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)

make_case() {
  local name=$1 mode=${2:-local-only} case_dir project
  case_dir="$TMP_ROOT/$name"
  project="$case_dir/project"
  mkdir -p "$case_dir/state" "$project/locked"
  git init -q -b main "$project"
  git -C "$project" config user.email fmtest@example.invalid
  git -C "$project" config user.name fmtest
  printf 'base\n' > "$project/locked/accepted.txt"
  printf 'base\n' > "$project/other.txt"
  printf 'base\n' > "$project/deleted.txt"
  git -C "$project" add .
  git -C "$project" commit -qm baseline
  git -C "$project" checkout -qb fm/task-x1
  printf 'incoming\n' > "$project/locked/accepted.txt"
  printf 'task branch\n' > "$project/other.txt"
  git -C "$project" add .
  git -C "$project" commit -qm task-change
  git -C "$project" checkout -q main
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "project=$project" \
    "mode=$mode"
  printf '%s\n' "$case_dir"
}

run_merge() {
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    "$MERGE_LOCAL" task-x1
}

write_target_content() {
  local project=$1 path=$2
  git -C "$project" show "fm/task-x1:$path" > "$project/$path"
}

snapshot_project() {
  local case_dir=$1 project=$2
  git -C "$project" rev-parse HEAD > "$case_dir/head.before"
  git -C "$project" write-tree > "$case_dir/index.before"
  git -C "$project" status --porcelain=v1 -z > "$case_dir/status.before"
  git -C "$project" hash-object --no-filters -- locked/accepted.txt > "$case_dir/accepted.before"
  git -C "$project" hash-object --no-filters -- other.txt > "$case_dir/other.before"
  git -C "$project" hash-object --no-filters -- deleted.txt > "$case_dir/deleted.before"
}

assert_project_unchanged() {
  local case_dir=$1 project=$2 label=$3
  cmp -s "$case_dir/head.before" <(git -C "$project" rev-parse HEAD) \
    || fail "$label: detection changed HEAD"
  cmp -s "$case_dir/index.before" <(git -C "$project" write-tree) \
    || fail "$label: detection changed the index"
  git -C "$project" status --porcelain=v1 -z > "$case_dir/status.after"
  cmp -s "$case_dir/status.before" "$case_dir/status.after" \
    || fail "$label: detection changed checkout status"
  cmp -s "$case_dir/accepted.before" <(git -C "$project" hash-object --no-filters -- locked/accepted.txt) \
    || fail "$label: detection changed the accepted file"
  cmp -s "$case_dir/other.before" <(git -C "$project" hash-object --no-filters -- other.txt) \
    || fail "$label: detection changed other tracked content"
  cmp -s "$case_dir/deleted.before" <(git -C "$project" hash-object --no-filters -- deleted.txt) \
    || fail "$label: detection changed unrelated tracked content"
}

test_detects_identical_dirty_files_without_project_mutation() {
  local case_dir project rc
  case_dir=$(make_case detects-identical)
  project="$case_dir/project"
  write_target_content "$project" locked/accepted.txt
  write_target_content "$project" other.txt
  snapshot_project "$case_dir" "$project"
  set +e
  run_merge "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "detects-identical: identical dirty files should use the distinct detection exit"
  assert_project_unchanged "$case_dir" "$project" detects-identical
  assert_grep 'detected identical dirty paths: locked/accepted.txt, other.txt' "$case_dir/stderr" \
    "detects-identical: detection did not name every covered path"
  assert_grep 'no project changes were made' "$case_dir/stderr" \
    "detects-identical: detection did not report its non-mutating result"
  assert_grep 'staging them discards nothing' "$case_dir/stderr" \
    "detects-identical: detection did not explain why manual resolution is safe"
  assert_grep 'To land by hand: git -C ' "$case_dir/stderr" \
    "detects-identical: detection did not provide a manual landing command"
  assert_grep 'add -- locked/accepted.txt other.txt &&' "$case_dir/stderr" \
    "detects-identical: manual command did not include every covered path"
  pass "fm-merge-local detects identical dirty files and leaves the checkout plus index unchanged"
}

test_refuses_one_byte_different_tracked_file() {
  local case_dir project rc before
  case_dir=$(make_case one-byte-different)
  project="$case_dir/project"
  printf 'incominh\n' > "$project/locked/accepted.txt"
  before=$(git -C "$project" rev-parse main)
  set +e
  run_merge "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "one-byte-different: local merge should use the ordinary refusal"
  [ "$before" = "$(git -C "$project" rev-parse main)" ] || fail "one-byte-different: main changed despite refusal"
  assert_grep 'dirty working tree; refusing' "$case_dir/stderr" \
    "one-byte-different: refusal did not retain the dirty-tree message"
  assert_no_grep 'detected identical dirty paths' "$case_dir/stderr" \
    "one-byte-different: ordinary refusal was mistaken for detection"
  pass "fm-merge-local refuses a tracked dirty file that differs by one byte"
}

test_refuses_qualifying_file_plus_untracked_file() {
  local case_dir project rc
  case_dir=$(make_case qualifying-plus-untracked)
  project="$case_dir/project"
  write_target_content "$project" locked/accepted.txt
  printf 'untracked\n' > "$project/untracked.txt"
  set +e
  run_merge "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "qualifying-plus-untracked: local merge should refuse"
  assert_grep 'dirty working tree; refusing' "$case_dir/stderr" \
    "qualifying-plus-untracked: refusal did not retain the dirty-tree message"
  pass "fm-merge-local refuses an untracked file alongside an otherwise identical dirty file"
}

test_refuses_qualifying_file_plus_deleted_file() {
  local case_dir project rc
  case_dir=$(make_case qualifying-plus-deletion)
  project="$case_dir/project"
  write_target_content "$project" locked/accepted.txt
  rm "$project/deleted.txt"
  set +e
  run_merge "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "qualifying-plus-deletion: local merge should refuse"
  assert_grep 'dirty working tree; refusing' "$case_dir/stderr" \
    "qualifying-plus-deletion: refusal did not retain the dirty-tree message"
  pass "fm-merge-local refuses a deletion alongside an otherwise identical dirty file"
}

test_refuses_staged_qualifying_file() {
  local case_dir project rc
  case_dir=$(make_case staged-qualifying)
  project="$case_dir/project"
  write_target_content "$project" locked/accepted.txt
  git -C "$project" add locked/accepted.txt
  set +e
  run_merge "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "staged-qualifying: local merge should refuse"
  assert_grep 'dirty working tree; refusing' "$case_dir/stderr" \
    "staged-qualifying: refusal did not retain the dirty-tree message"
  pass "fm-merge-local refuses a dirty path whose staged state differs from HEAD"
}

test_refuses_diverged_dirty_branch() {
  local case_dir project rc before
  case_dir=$(make_case diverged-dirty)
  project="$case_dir/project"
  printf 'main divergence\n' > "$project/main-only.txt"
  git -C "$project" add main-only.txt
  git -C "$project" commit -qm main-divergence
  write_target_content "$project" locked/accepted.txt
  before=$(git -C "$project" rev-parse main)
  set +e
  run_merge "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "diverged-dirty: local merge should refuse"
  [ "$before" = "$(git -C "$project" rev-parse main)" ] || fail "diverged-dirty: main changed despite refusal"
  assert_grep 'dirty working tree; refusing' "$case_dir/stderr" \
    "diverged-dirty: refusal did not retain the dirty-tree message"
  pass "fm-merge-local refuses a dirty checkout when the task branch has diverged"
}

test_refuses_dirty_checkout_off_default_branch() {
  local case_dir project rc
  case_dir=$(make_case off-default)
  project="$case_dir/project"
  git -C "$project" checkout -qb side-branch
  write_target_content "$project" locked/accepted.txt
  set +e
  run_merge "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "off-default: local merge should refuse"
  [ "$(git -C "$project" rev-parse --abbrev-ref HEAD)" = side-branch ] \
    || fail "off-default: refusal changed the current branch"
  assert_grep "expected default branch 'main'" "$case_dir/stderr" \
    "off-default: refusal did not identify the default-branch requirement"
  pass "fm-merge-local refuses an identical dirty checkout that is not on the default branch"
}

test_refuses_non_local_only_task() {
  local case_dir project rc
  case_dir=$(make_case non-local-only no-mistakes)
  project="$case_dir/project"
  write_target_content "$project" locked/accepted.txt
  set +e
  run_merge "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "non-local-only: local merge should refuse"
  assert_grep 'mode=no-mistakes, not local-only' "$case_dir/stderr" \
    "non-local-only: refusal did not identify the task mode"
  pass "fm-merge-local refuses a task that is not local-only"
}

test_clean_checkout_fast_forwards_unchanged() {
  local case_dir project
  case_dir=$(make_case clean-fast-forward)
  project="$case_dir/project"
  run_merge "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "clean-fast-forward: clean local merge should succeed"
  [ "$(git -C "$project" rev-parse main)" = "$(git -C "$project" rev-parse fm/task-x1)" ] \
    || fail "clean-fast-forward: main did not fast-forward"
  [ -z "$(git -C "$project" status --porcelain)" ] \
    || fail "clean-fast-forward: landing left the project dirty"
  assert_grep 'merged fm/task-x1 into local main' "$case_dir/stdout" \
    "clean-fast-forward: ordinary landing output changed"
  pass "fm-merge-local keeps the clean-checkout fast-forward path unchanged"
}

test_detects_identical_dirty_files_without_project_mutation
test_refuses_one_byte_different_tracked_file
test_refuses_qualifying_file_plus_untracked_file
test_refuses_qualifying_file_plus_deleted_file
test_refuses_staged_qualifying_file
test_refuses_diverged_dirty_branch
test_refuses_dirty_checkout_off_default_branch
test_refuses_non_local_only_task
test_clean_checkout_fast_forwards_unchanged
