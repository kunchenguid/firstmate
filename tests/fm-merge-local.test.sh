#!/usr/bin/env bash
# Tests for bin/fm-merge-local.sh: the guarded landing path for local-only ship
# tasks, and the one sanctioned exception to "never run state-changing git in a
# project". Crew branches are no longer a fixed fm/<id> (see bin/fm-brief.sh
# branch convention), so the ready branch is discovered from the task worktree's
# checked-out HEAD, with an explicit --branch override for the cases where the
# worktree can no longer answer.
#
# Matrix:
#   (a) attached worktree on a <type>/<slug> branch  -> fast-forward merge
#   (b) meta without worktree=                       -> refuse, name --branch
#   (c) worktree directory pruned                    -> refuse, name --branch
#   (d) detached worktree HEAD                       -> refuse, name --branch
#   (e) diverged branch                              -> fast-forward-only refusal
#   (f) --branch override                            -> lands when HEAD is unreadable
#   (g) --branch recovers each unavailable-worktree case, keeping every guard
#   (h) readable HEAD                                -> outranks an agreeing --branch
#   (i) --branch disagreeing with a readable HEAD    -> refused, main untouched
#   (j) empty or absent project=                     -> refuse before any git -C runs
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)

# A local-only project (no origin: local-only never has a remote) with one
# commit on main and a task worktree on a conventional-commit-style branch that
# is one commit ahead.
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/data"

  fm_git_init_commit "$case_dir/project"
  git -C "$case_dir/project" branch -M main
  git -C "$case_dir/project" worktree add -q -b feat/ready-work "$case_dir/wt" main
  printf 'crew work\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "feat: crew work"

  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

write_task_meta() {
  local case_dir=$1
  shift
  fm_write_meta "$case_dir/state/task-m1.meta" \
    "window=fm-task-m1" \
    "project=$case_dir/project" \
    "mode=local-only" \
    "$@"
}

# Standard meta: worktree present and attached.
write_attached_meta() {
  write_task_meta "$1" "worktree=$1/wt"
}

run_merge_local() {
  local case_dir=$1
  shift
  FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" \
    "$MERGE_LOCAL" "$@"
}

main_head() {
  git -C "$1/project" rev-parse main
}

branch_head() {
  git -C "$1/project" rev-parse "$2"
}

test_attached_worktree_branch_fast_forwards() {
  local case_dir out rc
  case_dir=$(make_case attached)
  write_attached_meta "$case_dir"

  set +e
  out=$(run_merge_local "$case_dir" task-m1 2> "$case_dir/stderr"); rc=$?
  set -e
  expect_code 0 "$rc" "attached: merge should succeed (stderr: $(cat "$case_dir/stderr"))"

  assert_contains "$out" "merged feat/ready-work into local main" \
    "attached: merge summary must name the discovered branch"
  [ "$(main_head "$case_dir")" = "$(branch_head "$case_dir" feat/ready-work)" ] \
    || fail "attached: main was not fast-forwarded to feat/ready-work"
  pass "fm-merge-local fast-forwards main to an attached worktree's <type>/<slug> branch"
}

test_missing_worktree_key_refuses() {
  local case_dir err rc before
  case_dir=$(make_case no-worktree-key)
  write_task_meta "$case_dir"
  before=$(main_head "$case_dir")

  set +e
  run_merge_local "$case_dir" task-m1 > /dev/null 2> "$case_dir/stderr"; rc=$?
  set -e
  err=$(cat "$case_dir/stderr")

  [ "$rc" -ne 0 ] || fail "no-worktree-key: must refuse when meta has no worktree="
  assert_contains "$err" "missing worktree=" "no-worktree-key: must say why the branch is unknown"
  assert_contains "$err" "--branch <name>" "no-worktree-key: must point at the --branch recovery"
  [ "$(main_head "$case_dir")" = "$before" ] || fail "no-worktree-key: main must be untouched"
  pass "fm-merge-local refuses when meta records no worktree and names the override"
}

test_absent_worktree_dir_refuses() {
  local case_dir err rc before
  case_dir=$(make_case pruned-worktree)
  write_attached_meta "$case_dir"
  rm -rf "$case_dir/wt"
  before=$(main_head "$case_dir")

  set +e
  run_merge_local "$case_dir" task-m1 > /dev/null 2> "$case_dir/stderr"; rc=$?
  set -e
  err=$(cat "$case_dir/stderr")

  [ "$rc" -ne 0 ] || fail "pruned-worktree: must refuse when the worktree directory is gone"
  assert_contains "$err" "worktree for task task-m1 is missing" \
    "pruned-worktree: must report the missing worktree"
  assert_contains "$err" "--branch <name>" "pruned-worktree: must point at the --branch recovery"
  [ "$(main_head "$case_dir")" = "$before" ] || fail "pruned-worktree: main must be untouched"
  pass "fm-merge-local refuses a pruned worktree and names the override"
}

test_detached_worktree_head_refuses() {
  local case_dir err rc before
  case_dir=$(make_case detached)
  write_attached_meta "$case_dir"
  git -C "$case_dir/wt" checkout -q --detach
  before=$(main_head "$case_dir")

  set +e
  run_merge_local "$case_dir" task-m1 > /dev/null 2> "$case_dir/stderr"; rc=$?
  set -e
  err=$(cat "$case_dir/stderr")

  [ "$rc" -ne 0 ] || fail "detached: must refuse a detached worktree HEAD"
  assert_contains "$err" "is detached" "detached: must report the detached HEAD"
  assert_contains "$err" "--branch <name>" "detached: must point at the --branch recovery"
  [ "$(main_head "$case_dir")" = "$before" ] || fail "detached: main must be untouched"
  pass "fm-merge-local refuses a detached worktree HEAD and names the override"
}

test_diverged_branch_refuses_fast_forward() {
  local case_dir err rc before
  case_dir=$(make_case diverged)
  write_attached_meta "$case_dir"
  # Advance main independently so the ready branch is no longer a fast-forward.
  printf 'main moved\n' > "$case_dir/project/main.txt"
  git -C "$case_dir/project" add main.txt
  git -C "$case_dir/project" commit -qm "main advances"
  before=$(main_head "$case_dir")

  set +e
  run_merge_local "$case_dir" task-m1 > /dev/null 2> "$case_dir/stderr"; rc=$?
  set -e
  err=$(cat "$case_dir/stderr")

  [ "$rc" -ne 0 ] || fail "diverged: must refuse a non-fast-forward branch"
  assert_contains "$err" "REFUSED: feat/ready-work is not a fast-forward of main" \
    "diverged: must give the fast-forward-only refusal"
  [ "$(main_head "$case_dir")" = "$before" ] || fail "diverged: main must be untouched"
  pass "fm-merge-local refuses a diverged branch with the fast-forward-only guard"
}

test_branch_override_merges_without_worktree_head() {
  local case_dir out rc
  case_dir=$(make_case override)
  write_attached_meta "$case_dir"
  # Detach HEAD so a passing result can only come from the override, not discovery.
  git -C "$case_dir/wt" checkout -q --detach

  set +e
  out=$(run_merge_local "$case_dir" task-m1 --branch feat/ready-work 2> "$case_dir/stderr"); rc=$?
  set -e
  expect_code 0 "$rc" "override: --branch merge should succeed (stderr: $(cat "$case_dir/stderr"))"

  assert_contains "$out" "merged feat/ready-work into local main" \
    "override: merge summary must name the overridden branch"
  [ "$(main_head "$case_dir")" = "$(branch_head "$case_dir" feat/ready-work)" ] \
    || fail "override: main was not fast-forwarded to feat/ready-work"
  pass "fm-merge-local --branch lands approved work when the worktree HEAD is detached"
}

test_branch_override_recovers_every_unavailable_worktree() {
  local case_dir out rc
  # meta without worktree=, and a pruned worktree directory: both must still land.
  case_dir=$(make_case override-no-key)
  write_task_meta "$case_dir"
  set +e
  out=$(run_merge_local "$case_dir" task-m1 --branch feat/ready-work 2> "$case_dir/stderr"); rc=$?
  set -e
  expect_code 0 "$rc" "override-no-key: --branch must land without worktree= (stderr: $(cat "$case_dir/stderr"))"
  [ "$(main_head "$case_dir")" = "$(branch_head "$case_dir" feat/ready-work)" ] \
    || fail "override-no-key: main was not fast-forwarded"

  case_dir=$(make_case override-pruned)
  write_attached_meta "$case_dir"
  git -C "$case_dir/project" worktree remove --force "$case_dir/wt"
  set +e
  out=$(run_merge_local "$case_dir" task-m1 --branch=feat/ready-work 2> "$case_dir/stderr"); rc=$?
  set -e
  expect_code 0 "$rc" "override-pruned: --branch=<name> must land after a prune (stderr: $(cat "$case_dir/stderr"))"
  assert_contains "$out" "merged feat/ready-work into local main" \
    "override-pruned: merge summary must name the overridden branch"
  [ "$(main_head "$case_dir")" = "$(branch_head "$case_dir" feat/ready-work)" ] \
    || fail "override-pruned: main was not fast-forwarded"
  pass "fm-merge-local --branch recovers a missing worktree= and a pruned worktree"
}

test_branch_override_keeps_every_merge_guard() {
  local case_dir err rc before
  # An unknown branch name must be rejected, not merged blindly. Detach first so
  # the override is actually consulted rather than refused as a HEAD mismatch.
  case_dir=$(make_case override-unknown-branch)
  write_attached_meta "$case_dir"
  git -C "$case_dir/wt" checkout -q --detach
  before=$(main_head "$case_dir")
  set +e
  run_merge_local "$case_dir" task-m1 --branch feat/never-created > /dev/null 2> "$case_dir/stderr"; rc=$?
  set -e
  err=$(cat "$case_dir/stderr")
  [ "$rc" -ne 0 ] || fail "override-unknown-branch: must refuse a branch absent from the project"
  assert_contains "$err" "branch feat/never-created does not exist" \
    "override-unknown-branch: must name the missing branch"
  [ "$(main_head "$case_dir")" = "$before" ] || fail "override-unknown-branch: main must be untouched"

  # A diverged branch stays refused even when named explicitly.
  case_dir=$(make_case override-diverged)
  write_attached_meta "$case_dir"
  printf 'main moved\n' > "$case_dir/project/main.txt"
  git -C "$case_dir/project" add main.txt
  git -C "$case_dir/project" commit -qm "main advances"
  before=$(main_head "$case_dir")
  set +e
  run_merge_local "$case_dir" task-m1 --branch feat/ready-work > /dev/null 2> "$case_dir/stderr"; rc=$?
  set -e
  err=$(cat "$case_dir/stderr")
  [ "$rc" -ne 0 ] || fail "override-diverged: --branch must not bypass the fast-forward guard"
  assert_contains "$err" "REFUSED: feat/ready-work is not a fast-forward of main" \
    "override-diverged: must keep the fast-forward-only refusal"
  [ "$(main_head "$case_dir")" = "$before" ] || fail "override-diverged: main must be untouched"

  # A dirty project checkout stays refused even when the branch is named.
  case_dir=$(make_case override-dirty)
  write_attached_meta "$case_dir"
  printf 'uncommitted\n' > "$case_dir/project/dirty.txt"
  git -C "$case_dir/project" add dirty.txt
  before=$(main_head "$case_dir")
  set +e
  run_merge_local "$case_dir" task-m1 --branch feat/ready-work > /dev/null 2> "$case_dir/stderr"; rc=$?
  set -e
  err=$(cat "$case_dir/stderr")
  [ "$rc" -ne 0 ] || fail "override-dirty: --branch must not bypass the clean-tree guard"
  assert_contains "$err" "dirty working tree" "override-dirty: must keep the clean-tree refusal"
  [ "$(main_head "$case_dir")" = "$before" ] || fail "override-dirty: main must be untouched"

  pass "fm-merge-local --branch keeps the existence, fast-forward, and clean-tree guards"
}

test_worktree_head_outranks_branch_override() {
  local case_dir out rc
  case_dir=$(make_case head-wins)
  write_attached_meta "$case_dir"
  # A second landable branch the override could have named. The worktree HEAD is
  # readable, so discovery must win and this branch must stay unmerged.
  git -C "$case_dir/project" branch feat/other-task main

  set +e
  out=$(run_merge_local "$case_dir" task-m1 --branch feat/ready-work 2> "$case_dir/stderr"); rc=$?
  set -e
  expect_code 0 "$rc" "head-wins: an agreeing --branch must still merge (stderr: $(cat "$case_dir/stderr"))"
  assert_contains "$out" "merged feat/ready-work into local main" \
    "head-wins: must merge the branch the worktree has checked out"
  [ "$(main_head "$case_dir")" = "$(branch_head "$case_dir" feat/ready-work)" ] \
    || fail "head-wins: main was not fast-forwarded to the discovered branch"
  pass "fm-merge-local uses the worktree HEAD when it is readable"
}

test_branch_override_disagreeing_with_head_refuses() {
  local case_dir err rc before
  case_dir=$(make_case override-mismatch)
  write_attached_meta "$case_dir"
  # Another task's branch, ahead of main and a perfectly valid fast-forward, so
  # only the identity check can stop it landing.
  git -C "$case_dir/project" worktree add -q -b feat/other-task "$case_dir/other-wt" main
  printf 'other work\n' > "$case_dir/other-wt/other.txt"
  git -C "$case_dir/other-wt" add other.txt
  git -C "$case_dir/other-wt" commit -qm "feat: other task work"
  before=$(main_head "$case_dir")

  set +e
  run_merge_local "$case_dir" task-m1 --branch feat/other-task > /dev/null 2> "$case_dir/stderr"; rc=$?
  set -e
  err=$(cat "$case_dir/stderr")

  [ "$rc" -ne 0 ] || fail "override-mismatch: must refuse a --branch that is not the task's checked-out work"
  assert_contains "$err" "REFUSED: --branch feat/other-task disagrees with the branch task task-m1 has checked out (feat/ready-work)" \
    "override-mismatch: must name both branches in the refusal"
  [ "$(main_head "$case_dir")" = "$before" ] || fail "override-mismatch: main must be untouched"
  pass "fm-merge-local refuses a --branch that disagrees with a readable worktree HEAD"
}

test_missing_project_refuses() {
  local case_dir err rc
  # An empty project= would make every git -C "$PROJ" run in the current
  # directory - firstmate's own checkout - instead of the project.
  case_dir=$(make_case no-project)
  fm_write_meta "$case_dir/state/task-m1.meta" \
    "window=fm-task-m1" \
    "project=" \
    "worktree=$case_dir/wt" \
    "mode=local-only"
  set +e
  run_merge_local "$case_dir" task-m1 --branch feat/ready-work > /dev/null 2> "$case_dir/stderr"; rc=$?
  set -e
  err=$(cat "$case_dir/stderr")
  [ "$rc" -ne 0 ] || fail "no-project: must refuse an empty project="
  assert_contains "$err" "missing project=" "no-project: must name the missing project key"

  case_dir=$(make_case gone-project)
  fm_write_meta "$case_dir/state/task-m1.meta" \
    "window=fm-task-m1" \
    "project=$case_dir/not-a-project" \
    "worktree=$case_dir/wt" \
    "mode=local-only"
  set +e
  run_merge_local "$case_dir" task-m1 > /dev/null 2> "$case_dir/stderr"; rc=$?
  set -e
  err=$(cat "$case_dir/stderr")
  [ "$rc" -ne 0 ] || fail "gone-project: must refuse a project directory that does not exist"
  assert_contains "$err" "project for task task-m1 is missing" "gone-project: must name the absent project"
  pass "fm-merge-local refuses an empty or absent project= instead of running git in the cwd"
}

test_non_local_only_mode_refuses() {
  local case_dir err rc before
  case_dir=$(make_case wrong-mode)
  # A PR-based delivery path instead of the local-only one this script serves.
  fm_write_meta "$case_dir/state/task-m1.meta" \
    "window=fm-task-m1" \
    "project=$case_dir/project" \
    "worktree=$case_dir/wt" \
    "mode=no-mistakes"
  before=$(main_head "$case_dir")

  set +e
  run_merge_local "$case_dir" task-m1 --branch feat/ready-work > /dev/null 2> "$case_dir/stderr"; rc=$?
  set -e
  err=$(cat "$case_dir/stderr")

  [ "$rc" -ne 0 ] || fail "wrong-mode: must refuse a task that is not mode=local-only"
  assert_contains "$err" "not local-only" "wrong-mode: must name the mode mismatch"
  [ "$(main_head "$case_dir")" = "$before" ] || fail "wrong-mode: main must be untouched"
  pass "fm-merge-local refuses a task whose delivery mode is not local-only"
}

test_unknown_argument_refuses() {
  local case_dir err rc before
  case_dir=$(make_case bad-arg)
  write_attached_meta "$case_dir"
  before=$(main_head "$case_dir")

  set +e
  run_merge_local "$case_dir" task-m1 --force > /dev/null 2> "$case_dir/stderr"; rc=$?
  set -e
  err=$(cat "$case_dir/stderr")

  [ "$rc" -ne 0 ] || fail "bad-arg: must refuse an unrecognized argument"
  assert_contains "$err" "invalid local merge request" "bad-arg: must refuse the malformed request"
  [ "$(main_head "$case_dir")" = "$before" ] || fail "bad-arg: main must be untouched"
  pass "fm-merge-local refuses an unrecognized argument instead of ignoring it"
}

# A --branch that names the default branch would fast-forward main onto main - a
# no-op that must not be reported as a successful land of approved work.
test_branch_equal_default_refuses() {
  local case_dir err rc before
  case_dir=$(make_case branch-equals-default)
  write_attached_meta "$case_dir"
  # Detach the worktree HEAD so the operator-supplied --branch is consulted.
  git -C "$case_dir/wt" checkout -q --detach
  before=$(main_head "$case_dir")

  set +e
  run_merge_local "$case_dir" task-m1 --branch main > /dev/null 2> "$case_dir/stderr"; rc=$?
  set -e
  err=$(cat "$case_dir/stderr")

  [ "$rc" -ne 0 ] || fail "branch-equals-default: --branch main must be refused, not reported as a merge"
  assert_contains "$err" "default branch" "branch-equals-default: must say the ready branch is the default"
  [ "$(main_head "$case_dir")" = "$before" ] || fail "branch-equals-default: main must be untouched"
  pass "fm-merge-local refuses a ready branch equal to the default (no-op passed off as success)"
}

test_attached_worktree_branch_fast_forwards
test_missing_worktree_key_refuses
test_absent_worktree_dir_refuses
test_detached_worktree_head_refuses
test_diverged_branch_refuses_fast_forward
test_branch_override_merges_without_worktree_head
test_branch_override_recovers_every_unavailable_worktree
test_branch_override_keeps_every_merge_guard
test_worktree_head_outranks_branch_override
test_branch_override_disagreeing_with_head_refuses
test_missing_project_refuses
test_non_local_only_mode_refuses
test_unknown_argument_refuses
test_branch_equal_default_refuses
