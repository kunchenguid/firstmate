#!/usr/bin/env bash
# Behavior tests for bin/fm-merge-local.sh ship-branch resolution.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-merge-local)
MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"

make_local_only_case() {
  local name=$1 branch=$2 write_meta_branch=$3 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/home/state"

  git init -q "$case_dir/project"
  git -C "$case_dir/project" checkout -q -b main
  printf 'base\n' > "$case_dir/project/file.txt"
  git -C "$case_dir/project" add file.txt
  git -C "$case_dir/project" -c user.email=t@t -c user.name=t commit -qm baseline
  git -C "$case_dir/project" checkout -q -b "$branch"
  printf 'change\n' >> "$case_dir/project/file.txt"
  git -C "$case_dir/project" add file.txt
  git -C "$case_dir/project" -c user.email=t@t -c user.name=t commit -qm change
  git -C "$case_dir/project" checkout -q main

  {
    echo "project=$case_dir/project"
    echo "mode=local-only"
    echo "worktree=$case_dir/project"
    [ "$write_meta_branch" = 1 ] && echo "branch=$branch"
  } > "$case_dir/home/state/task-x.meta"
  printf '%s\n' "$case_dir"
}

test_default_fm_branch_still_lands() {
  local case_dir out
  case_dir=$(make_local_only_case default-fm fm/task-x 0)
  out=$(FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/home/state" \
    "$MERGE_LOCAL" task-x 2>&1) || fail "default fm/<id> merge failed: $out"
  assert_contains "$out" "merged fm/task-x" "default path did not land fm/<id>"
  pass "fm-merge-local: absent branch= still lands fm/<task-id>"
}

test_recorded_branch_lands() {
  local case_dir out
  case_dir=$(make_local_only_case named-branch feat/named-local 1)
  out=$(FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/home/state" \
    "$MERGE_LOCAL" task-x 2>&1) || fail "recorded branch= merge failed: $out"
  assert_contains "$out" "merged feat/named-local" "recorded branch= was not used for landing"
  pass "fm-merge-local: branch= from meta is the land target"
}

test_default_fm_branch_still_lands
test_recorded_branch_lands
