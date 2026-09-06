#!/usr/bin/env bash
# Behavior tests for bin/fm-merge-local.sh, firstmate's guarded local-only
# landing.
#
# The landing target is the task's DELIVERY TARGET BRANCH: the `base=` recorded
# in state/<id>.meta when the task has one, and the project's default branch
# otherwise. Projects that ship onto a long-lived feature branch could not use
# this path at all while it assumed the default branch, so their landings fell
# back to a raw `git merge --ff-only` outside every guard here.
#
# Matrix:
#   (a) recorded base + fast-forwardable branch      -> LANDS on that branch
#   (b) no recorded base                             -> LANDS on the default branch
#   (c) recorded base + dirty project tree           -> REFUSE
#   (d) recorded base + wrong branch checked out     -> REFUSE
#   (e) recorded base + diverged branch              -> REFUSE (never a merge commit)
#   (f) recorded base that does not exist            -> REFUSE
#   (g) mode is not local-only                       -> REFUSE
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local)

# Build one case: a project on `main` with a `feat/stack` branch ahead of it, and
# an `fm/task-m1` branch one commit ahead of whichever branch is named. Leaves the
# project checked out on <checkout>. Echoes the case dir.
# Args: name branch-parent checkout [base]
make_case() {
  local name=$1 parent=$2 checkout=$3 base=${4:-} case_dir proj
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/project"
  mkdir -p "$case_dir/state"
  git init -q -b main "$proj"
  git -C "$proj" commit -q --allow-empty -m "main baseline"
  git -C "$proj" branch feat/stack
  git -C "$proj" checkout -q feat/stack
  git -C "$proj" commit -q --allow-empty -m "feature baseline"
  git -C "$proj" checkout -q -b fm/task-m1 "$parent"
  git -C "$proj" commit -q --allow-empty -m "task work"
  git -C "$proj" checkout -q "$checkout"

  fm_write_meta "$case_dir/state/task-m1.meta" \
    "window=firstmate:fm-task-m1" \
    "endpoint_task_id=task-m1" \
    "worktree=$case_dir/wt" \
    "project=$proj" \
    "kind=ship" \
    "mode=local-only"
  [ -z "$base" ] || printf 'base=%s\n' "$base" >> "$case_dir/state/task-m1.meta"
  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

run_merge_local() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_SPAWN_NO_GUARD=1 \
    "$MERGE_LOCAL" task-m1 "$@"
}

branch_head() {
  git -C "$1/project" rev-parse --short "$2"
}

# (a) The whole point: a task recording a non-default delivery target branch lands
# onto that branch through the ordinary guarded fast-forward, no raw git needed.
test_recorded_base_lands_on_that_branch() {
  local case_dir rc task_head main_before
  case_dir=$(make_case base-lands feat/stack feat/stack feat/stack)
  task_head=$(branch_head "$case_dir" fm/task-m1)
  main_before=$(branch_head "$case_dir" main)

  set +e
  run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "base-lands: the guarded landing should succeed"
  [ "$(branch_head "$case_dir" feat/stack)" = "$task_head" ] \
    || fail "base-lands: feat/stack did not fast-forward to the task branch"
  [ "$(branch_head "$case_dir" main)" = "$main_before" ] \
    || fail "base-lands: the default branch was moved by a landing that targets feat/stack"
  assert_grep "merged fm/task-m1 into local feat/stack" "$case_dir/stdout" \
    "base-lands: the report did not name the branch it landed on"
  pass "a recorded delivery target branch lands through the guarded fast-forward path"
}

# (b) No recorded base is the common case and must behave exactly as before.
test_absent_base_lands_on_the_default_branch() {
  local case_dir rc task_head
  case_dir=$(make_case no-base main main)
  task_head=$(branch_head "$case_dir" fm/task-m1)

  set +e
  run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "no-base: the guarded landing should succeed on the default branch"
  [ "$(branch_head "$case_dir" main)" = "$task_head" ] \
    || fail "no-base: main did not fast-forward to the task branch"
  assert_grep "merged fm/task-m1 into local main" "$case_dir/stdout" \
    "no-base: the report did not name the default branch"
  pass "a task with no recorded delivery target branch still lands on the repo default branch"
}

# (c)-(f) Every existing guard survives the target-branch change. Each row runs one
# preparation on the case before the landing attempt.
test_every_guard_survives_the_recorded_base() {
  local label prep expect case_dir rc n=0
  while IFS='|' read -r label prep expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case "$prep" in
      dirty)
        case_dir=$(make_case "guard-$n" feat/stack feat/stack feat/stack)
        printf 'uncommitted\n' > "$case_dir/project/scratch.txt" ;;
      wrong-branch)
        case_dir=$(make_case "guard-$n" feat/stack main feat/stack) ;;
      diverged)
        case_dir=$(make_case "guard-$n" feat/stack feat/stack feat/stack)
        git -C "$case_dir/project" commit -q --allow-empty -m "target advanced past the task branch" ;;
      missing-base)
        case_dir=$(make_case "guard-$n" main main feat/absent) ;;
      not-local-only)
        case_dir=$(make_case "guard-$n" feat/stack feat/stack feat/stack)
        sed 's/^mode=local-only$/mode=no-mistakes/' "$case_dir/state/task-m1.meta" \
          > "$case_dir/state/task-m1.meta.tmp"
        mv -f "$case_dir/state/task-m1.meta.tmp" "$case_dir/state/task-m1.meta" ;;
      *) fail "unknown preparation '$prep'" ;;
    esac

    set +e
    run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "$label: the landing should have been refused"
    assert_grep "$expect" "$case_dir/stderr" "$label: refusal did not explain itself"
    # No guard may land anything, and none may create a merge commit.
    [ "$(git -C "$case_dir/project" rev-list --count --merges HEAD)" = 0 ] \
      || fail "$label: a refused landing created a merge commit"
  done <<'ROWS'
a dirty project tree|dirty|has a dirty working tree
the wrong branch checked out|wrong-branch|expected 'feat/stack'
a diverged task branch|diverged|is not a fast-forward of feat/stack
a recorded base branch that does not exist|missing-base|recorded delivery target branch 'feat/absent' does not exist
a task that is not local-only|not-local-only|is mode=no-mistakes, not local-only
ROWS
  pass "the clean-tree, checked-out-branch, fast-forward-only, target-exists and mode guards all still refuse"
}

test_recorded_base_lands_on_that_branch
test_absent_base_lands_on_the_default_branch
test_every_guard_survives_the_recorded_base
