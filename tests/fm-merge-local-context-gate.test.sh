#!/usr/bin/env bash
# Tests for the context-contract gate in bin/fm-merge-local.sh: a local-only
# landing whose branch carries project-code changes for a KNOWN slug (explicit
# repo->slug map: lia=>lia-core, lia-mascot=>lia-mascot, kg-hpmor=>kg-hpmor)
# must have that slug's detail record with its 4-key frontmatter
# (milestone/focus/blocker/next_move) in the home's data/projects/ dir.
#
# Matrix (each case drives the real script against a fixture project repo):
#   (a) code change with no detail record at all is REFUSED, naming the file
#   (b) code change with a detail record missing frontmatter keys is REFUSED
#   (c) code change with a complete frontmatter record lands (exit 0, merged)
#   (d) code change in an unknown repo warns and lands (warn-only, exit 0)
#   (e) a branch with no code changes lands without needing any record
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-ctx-tests)

# make_repo <case-dir> <repo-name>: fixture project repo with a base commit on
# main and a fm/task-x1 branch carrying one code change. Leaves the checkout
# on main and clean, the way the merge gate expects. Echoes the repo path.
make_repo() {
  local case_dir=$1 name=$2 repo
  repo="$case_dir/$name"
  git init -q -b main "$repo"
  printf 'base\n' > "$repo/code.txt"
  git -C "$repo" add code.txt
  git -C "$repo" commit -qm base
  git -C "$repo" checkout -qb fm/task-x1
  printf 'change\n' >> "$repo/code.txt"
  git -C "$repo" commit -qam change
  git -C "$repo" checkout -q main
  printf '%s\n' "$repo"
}

# make_case <name> <repo-name>: state dir with a local-only task meta pointing
# at the fixture repo, plus an empty home detail dir. Echoes the case dir.
make_case() {
  local name=$1 repo_name=$2 case_dir repo
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/home/data/projects"
  repo=$(make_repo "$case_dir" "$repo_name")
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$repo" \
    "kind=ship" \
    "mode=local-only"
  printf '%s\n' "$case_dir"
}

run_merge_local() {
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/home" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$MERGE_LOCAL" task-x1
}

test_refuses_when_record_missing() {
  local case_dir rc
  case_dir=$(make_case record-missing lia-mascot)

  set +e
  run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "record-missing: landing without a detail record should be refused"
  assert_grep 'REFUSED' "$case_dir/stderr" "record-missing: refusal did not say REFUSED"
  assert_grep "$case_dir/home/data/projects/lia-mascot.md" "$case_dir/stderr" \
    "record-missing: refusal did not name the missing detail file"
  [ "$(git -C "$case_dir/lia-mascot" rev-parse main)" != "$(git -C "$case_dir/lia-mascot" rev-parse fm/task-x1)" ] \
    || fail "record-missing: refused landing still moved main"
  pass "fm-merge-local refuses code-without-record and names the detail file"
}

test_refuses_when_frontmatter_incomplete() {
  local case_dir rc
  case_dir=$(make_case frontmatter-incomplete lia-mascot)
  printf '%s\n' '---' 'milestone: m1' 'focus: things' '---' 'body' > "$case_dir/home/data/projects/lia-mascot.md"

  set +e
  run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "frontmatter-incomplete: landing with a stale record should be refused"
  assert_grep 'lia-mascot.md' "$case_dir/stderr" \
    "frontmatter-incomplete: refusal did not name the detail file"
  assert_grep "blocker" "$case_dir/stderr" \
    "frontmatter-incomplete: refusal did not name the missing frontmatter key"
  pass "fm-merge-local refuses code-without-frontmatter and names the missing key"
}

test_lands_when_record_current() {
  local case_dir rc
  case_dir=$(make_case record-current lia-mascot)
  printf '%s\n' '---' 'milestone: m1' 'focus: things' 'blocker: none' 'next_move: ship' '---' 'body' \
    > "$case_dir/home/data/projects/lia-mascot.md"

  set +e
  run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "record-current: landing with a current record should succeed"
  [ "$(git -C "$case_dir/lia-mascot" rev-parse main)" = "$(git -C "$case_dir/lia-mascot" rev-parse fm/task-x1)" ] \
    || fail "record-current: main was not fast-forwarded to the branch"
  pass "fm-merge-local lands code-with-frontmatter"
}

test_unknown_repo_warns_and_lands() {
  local case_dir rc
  case_dir=$(make_case unknown-repo something-else)

  set +e
  run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "unknown-repo: landing for an unmapped repo should succeed"
  assert_grep 'warning' "$case_dir/stderr" "unknown-repo: warn-only path printed no warning"
  assert_grep 'something-else' "$case_dir/stderr" "unknown-repo: warning did not name the repo"
  [ "$(git -C "$case_dir/something-else" rev-parse main)" = "$(git -C "$case_dir/something-else" rev-parse fm/task-x1)" ] \
    || fail "unknown-repo: main was not fast-forwarded to the branch"
  pass "fm-merge-local warns once and lands for an unknown repo"
}

test_empty_diff_needs_no_record() {
  local case_dir rc repo
  case_dir="$TMP_ROOT/empty-diff"
  mkdir -p "$case_dir/state" "$case_dir/home/data/projects"
  repo="$case_dir/lia-mascot"
  git init -q -b main "$repo"
  printf 'base\n' > "$repo/code.txt"
  git -C "$repo" add code.txt
  git -C "$repo" commit -qm base
  git -C "$repo" checkout -qb fm/task-x1
  git -C "$repo" checkout -q main
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$repo" \
    "kind=ship" \
    "mode=local-only"

  set +e
  run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "empty-diff: a branch with no changes should land without a record"
  pass "fm-merge-local lands an empty branch diff without demanding a record"
}

test_refuses_when_record_missing
test_refuses_when_frontmatter_incomplete
test_lands_when_record_current
test_unknown_repo_warns_and_lands
test_empty_diff_needs_no_record
