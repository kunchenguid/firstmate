#!/usr/bin/env bash
# Behavior tests for bin/fm-auto-rebase.sh, the model-free task-branch rebase.
# Every case runs real git against a project with a bare origin and a task
# worktree, and asserts the exit status, the task branch, and the refs origin
# and the local base branch end up holding.
set -u

# A fleet pane may carry a hooks-path override; these fixtures need none.
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REBASE="$ROOT/bin/fm-auto-rebase.sh"
TMP_ROOT=$(fm_test_tmproot fm-auto-rebase)
fm_git_identity fmtest fmtest@example.invalid

# fixture <name>: a project on main with a bare origin, a task worktree on
# fm/t1 holding one commit that edits f, that branch pushed to origin, and a
# second clone of origin for advancing the remote. Sets FX_REPO, FX_WT,
# FX_ORIGIN, FX_OTHER.
fixture() {
  local dir="$TMP_ROOT/$1"
  FX_REPO="$dir/repo"
  FX_WT="$dir/wt"
  FX_ORIGIN="$dir/repo.origin.git"
  FX_OTHER="$dir/other"
  fm_git_init_commit "$FX_REPO"
  printf 'a\nb\nc\n' > "$FX_REPO/f"
  git -C "$FX_REPO" add f
  git -C "$FX_REPO" commit -qm base
  fm_git_add_origin "$FX_REPO" "$FX_ORIGIN"
  git -C "$FX_REPO" fetch -q origin
  git -C "$FX_REPO" remote set-head origin main >/dev/null
  git -C "$FX_REPO" worktree add --quiet -b fm/t1 "$FX_WT"
  printf 'task\n' > "$FX_WT/task"
  git -C "$FX_WT" add task
  git -C "$FX_WT" commit -qm 'the task change'
  git -C "$FX_WT" push -q origin fm/t1
  git clone -q "file://$FX_ORIGIN" "$FX_OTHER"
}

# advance_origin <file> <content>: commit on origin's main from the other clone.
advance_origin() {
  printf '%s\n' "$2" > "$FX_OTHER/$1"
  git -C "$FX_OTHER" add "$1"
  git -C "$FX_OTHER" commit -qm "origin edits $1"
  git -C "$FX_OTHER" push -q origin main
}

run_rebase() {  # <args...>; sets OUT and RC
  OUT=$("$REBASE" --repo "$FX_WT" "$@" 2>&1)
  RC=$?
}

head_of() {  # <repo> <ref>
  git -C "$1" rev-parse --verify --quiet "$2"
}

test_clean_rebase_pushes_with_lease() {
  local local_main
  fixture clean
  advance_origin other 'from main'
  local_main=$(head_of "$FX_REPO" refs/heads/main)
  run_rebase --mode direct-PR
  expect_code 0 "$RC" "clean direct-PR rebase"
  assert_contains "$OUT" "rebased: fm/t1" "a clean rebase did not report it"
  assert_contains "$OUT" "pushed: fm/t1" "a clean direct-PR rebase did not push"
  git -C "$FX_WT" merge-base --is-ancestor "$(head_of "$FX_ORIGIN" refs/heads/main)" HEAD \
    || fail "the task branch does not contain origin's main after the rebase"
  assert_equals "$(head_of "$FX_WT" HEAD)" "$(head_of "$FX_ORIGIN" refs/heads/fm/t1)" "origin's task branch is not the rebased head"
  assert_equals "$local_main" "$(head_of "$FX_REPO" refs/heads/main)" "the local base branch moved"
  pass "auto-rebase: a clean rebase lands on origin's base and pushes the task branch"
}

test_current_branch_is_a_noop() {
  local before remote_before
  fixture current
  advance_origin other 'from main'
  run_rebase --mode direct-PR
  expect_code 0 "$RC" "first rebase"
  before=$(head_of "$FX_WT" HEAD)
  remote_before=$(head_of "$FX_ORIGIN" refs/heads/fm/t1)
  run_rebase --mode direct-PR
  expect_code 0 "$RC" "up-to-date rebase"
  assert_contains "$OUT" "current: fm/t1 already contains" "an up-to-date branch was not reported current"
  assert_not_contains "$OUT" "pushed:" "an up-to-date branch was pushed"
  assert_equals "$before" "$(head_of "$FX_WT" HEAD)" "an up-to-date branch moved"
  assert_equals "$remote_before" "$(head_of "$FX_ORIGIN" refs/heads/fm/t1)" "origin's task branch moved"
  pass "auto-rebase: a branch that already contains its base is left alone"
}

test_conflict_aborts_and_leaves_the_branch() {
  local before remote_before
  fixture conflict
  advance_origin f 'origin version'
  printf 'task version\n' > "$FX_WT/f"
  git -C "$FX_WT" commit -qam 'task edits f'
  git -C "$FX_WT" push -q origin fm/t1
  before=$(head_of "$FX_WT" HEAD)
  remote_before=$(head_of "$FX_ORIGIN" refs/heads/fm/t1)
  run_rebase --mode direct-PR
  expect_code 1 "$RC" "conflicting rebase"
  assert_contains "$OUT" "conflict: fm/t1 onto refs/remotes/origin/main in: f" "the conflict was not named with its path"
  assert_equals "$before" "$(head_of "$FX_WT" HEAD)" "a conflict moved the task branch"
  assert_equals "fm/t1" "$(git -C "$FX_WT" symbolic-ref --short HEAD)" "a conflict left HEAD off the task branch"
  assert_equals "" "$(git -C "$FX_WT" status --porcelain)" "a conflict left the worktree dirty"
  assert_absent "$(git -C "$FX_WT" rev-parse --absolute-git-dir)/rebase-merge" "a conflict left a rebase in progress"
  assert_equals "$remote_before" "$(head_of "$FX_ORIGIN" refs/heads/fm/t1)" "a conflict pushed"
  pass "auto-rebase: a conflict aborts, exits 1, and leaves the branch untouched"
}

test_local_only_rebases_onto_local_main_without_remote() {
  local origin_main tracking remote_branch
  fixture localonly
  printf 'local\n' > "$FX_REPO/local"
  git -C "$FX_REPO" add local
  git -C "$FX_REPO" commit -qm 'local main advances'
  advance_origin other 'origin only'
  origin_main=$(head_of "$FX_ORIGIN" refs/heads/main)
  tracking=$(head_of "$FX_WT" refs/remotes/origin/main)
  remote_branch=$(head_of "$FX_ORIGIN" refs/heads/fm/t1)
  run_rebase --mode local-only
  expect_code 0 "$RC" "local-only rebase"
  assert_not_contains "$OUT" "pushed:" "local-only pushed"
  git -C "$FX_WT" merge-base --is-ancestor refs/heads/main HEAD \
    || fail "local-only did not rebase onto the local base branch"
  if git -C "$FX_WT" cat-file -e "$origin_main^{commit}" 2>/dev/null \
    && git -C "$FX_WT" merge-base --is-ancestor "$origin_main" HEAD; then
    fail "local-only rebased onto origin's base"
  fi
  assert_equals "$tracking" "$(head_of "$FX_WT" refs/remotes/origin/main)" "local-only fetched from origin"
  assert_equals "$remote_branch" "$(head_of "$FX_ORIGIN" refs/heads/fm/t1)" "local-only changed origin's task branch"
  pass "auto-rebase: local-only rebases onto local main and never fetches or pushes"
}

test_no_mistakes_never_pushes() {
  local remote_branch
  fixture nm
  advance_origin other 'from main'
  remote_branch=$(head_of "$FX_ORIGIN" refs/heads/fm/t1)
  run_rebase --mode no-mistakes
  expect_code 0 "$RC" "no-mistakes rebase"
  assert_contains "$OUT" "rebased: fm/t1" "no-mistakes did not rebase"
  assert_not_contains "$OUT" "pushed:" "no-mistakes pushed"
  assert_equals "$remote_branch" "$(head_of "$FX_ORIGIN" refs/heads/fm/t1)" "no-mistakes changed origin's task branch"
  pass "auto-rebase: no-mistakes rebases locally and leaves the push to its pipeline"
}

test_remote_only_commits_refuse_before_rebasing() {
  local before remote_before
  fixture diverged
  advance_origin other 'from main'
  git -C "$FX_OTHER" fetch -q origin fm/t1
  git -C "$FX_OTHER" checkout -q -b fm/t1 FETCH_HEAD
  printf 'remote\n' > "$FX_OTHER/remote"
  git -C "$FX_OTHER" add remote
  git -C "$FX_OTHER" commit -qm 'someone else pushes to the task branch'
  git -C "$FX_OTHER" push -q origin fm/t1
  before=$(head_of "$FX_WT" HEAD)
  remote_before=$(head_of "$FX_ORIGIN" refs/heads/fm/t1)
  run_rebase --mode direct-PR
  expect_code 2 "$RC" "rebase with remote-only commits"
  assert_contains "$OUT" "commits the local branch lacks" "the refusal did not say why"
  assert_equals "$before" "$(head_of "$FX_WT" HEAD)" "the refusal moved the task branch"
  assert_equals "$remote_before" "$(head_of "$FX_ORIGIN" refs/heads/fm/t1)" "the refusal overwrote origin's task branch"
  pass "auto-rebase: origin commits missing locally refuse before any rebase or push"
}

test_refusals() {
  fixture refuse
  run_rebase
  expect_code 2 "$RC" "missing --mode"
  printf 'dirty\n' > "$FX_WT/f"
  run_rebase --mode direct-PR
  expect_code 2 "$RC" "dirty worktree"
  assert_contains "$OUT" "uncommitted changes" "a dirty worktree was refused without saying why"
  git -C "$FX_WT" checkout -q -- f
  git -C "$FX_WT" checkout -q --detach
  run_rebase --mode direct-PR
  expect_code 2 "$RC" "detached HEAD"
  assert_contains "$OUT" "detached" "a detached HEAD was refused without saying why"
  pass "auto-rebase: a missing mode, a dirty tree, and a detached HEAD are refused"
}

fm_test_run test_clean_rebase_pushes_with_lease test_current_branch_is_a_noop \
  test_conflict_aborts_and_leaves_the_branch test_local_only_rebases_onto_local_main_without_remote \
  test_no_mistakes_never_pushes test_remote_only_commits_refuse_before_rebasing test_refusals
