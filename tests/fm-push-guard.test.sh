#!/usr/bin/env bash
# Behavior tests for bin/fm-push-guard.sh.
#
# The guard compares the exact current remote branch tip with local HEAD before
# a worker pushes. It must refuse remote-only work unless every such commit is
# still reachable or has a patch-equivalent replacement in the local history.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-push-guard)
GUARD="$ROOT/bin/fm-push-guard.sh"

commit_file() {
  local repo=$1 file=$2 content=$3 subject=$4
  printf '%s\n' "$content" > "$repo/$file"
  git -C "$repo" add "$file"
  git -C "$repo" commit -qm "$subject" >/dev/null
}

# new_case <name> echoes a directory containing a bare origin plus worker and reviewer
# clones. Both clones begin on the same one-commit main branch.
new_case() {
  local name=$1 dir seed origin
  dir="$TMP_ROOT/$name"
  seed="$dir/seed"
  origin="$dir/origin.git"
  mkdir -p "$seed"
  git -C "$seed" init -q
  git -C "$seed" symbolic-ref HEAD refs/heads/main
  commit_file "$seed" base.txt base "base commit"
  git clone -q --bare "$seed" "$origin"
  git clone -q "file://$origin" "$dir/worker"
  git clone -q "file://$origin" "$dir/reviewer"
  printf '%s\n' "$dir"
}

track_remote_task_branch() {
  local worker=$1 branch=$2
  git -C "$worker" fetch -q origin "$branch"
  git -C "$worker" branch --set-upstream-to="origin/$branch" "$branch" >/dev/null
}

test_dropped_remote_commits_are_named() {
  local dir worker reviewer branch out status lost_one lost_two
  dir=$(new_case dropped)
  worker="$dir/worker"
  reviewer="$dir/reviewer"
  branch=fm/task

  git -C "$worker" checkout -qb "$branch"
  commit_file "$worker" worker.txt local "local continuation"

  git -C "$reviewer" checkout -qb "$branch"
  commit_file "$reviewer" heading.txt narrow "narrow-width heading truncation fix"
  lost_one=$(git -C "$reviewer" rev-parse HEAD)
  commit_file "$reviewer" ledger.txt release "ledger conflict-list release"
  lost_two=$(git -C "$reviewer" rev-parse HEAD)
  git -C "$reviewer" push -q -u origin "$branch"
  track_remote_task_branch "$worker" "$branch"

  out=$(cd "$worker" && "$GUARD" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "history-dropping push guard unexpectedly passed"
  assert_contains "$out" "$(printf '%.12s' "$lost_one")" \
    "refusal did not name the first lost commit"
  assert_contains "$out" "narrow-width heading truncation fix" \
    "refusal did not include the first lost commit subject"
  assert_contains "$out" "$(printf '%.12s' "$lost_two")" \
    "refusal did not name the second lost commit"
  assert_contains "$out" "ledger conflict-list release" \
    "refusal did not include the second lost commit subject"
  pass "fm-push-guard: refuses and names every dropped remote commit"
}

test_clean_descendant_push_passes() {
  local dir worker branch out status
  dir=$(new_case clean)
  worker="$dir/worker"
  branch=fm/task
  git -C "$dir/reviewer" push -q origin main:"$branch"
  git -C "$worker" checkout -qb "$branch"
  track_remote_task_branch "$worker" "$branch"
  commit_file "$worker" clean.txt clean "clean local change"

  out=$(cd "$worker" && "$GUARD" 2>&1); status=$?
  expect_code 0 "$status" "clean descendant push guard"
  assert_contains "$out" "safe" "clean descendant pass did not explain its result"
  pass "fm-push-guard: ordinary clean descendant push passes"
}

test_patch_equivalent_rebase_passes() {
  local dir worker reviewer branch remote_commit rebased_commit out status
  dir=$(new_case equivalent)
  worker="$dir/worker"
  reviewer="$dir/reviewer"
  branch=fm/task

  git -C "$reviewer" checkout -qb "$branch"
  commit_file "$reviewer" reviewed.txt preserved "reviewed content"
  remote_commit=$(git -C "$reviewer" rev-parse HEAD)
  git -C "$reviewer" push -q -u origin "$branch"

  git -C "$worker" checkout -qb "$branch"
  commit_file "$worker" local.txt local "local work before replay"
  track_remote_task_branch "$worker" "$branch"
  git -C "$worker" cherry-pick "$remote_commit" >/dev/null
  rebased_commit=$(git -C "$worker" rev-parse HEAD)
  [ "$rebased_commit" != "$remote_commit" ] \
    || fail "patch-equivalent fixture accidentally retained the original commit identity"

  out=$(cd "$worker" && "$GUARD" 2>&1); status=$?
  expect_code 0 "$status" "patch-equivalent rebase guard"
  assert_contains "$out" "patch-equivalent" \
    "content-preserving rebase pass did not identify the reproduced work"
  pass "fm-push-guard: content-preserving rebase passes despite changed commit ids"
}

test_no_upstream_refuses() {
  local dir worker out status
  dir=$(new_case no-upstream)
  worker="$dir/worker"
  git -C "$worker" checkout -qb fm/no-upstream

  out=$(cd "$worker" && "$GUARD" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "guard passed without an upstream"
  assert_contains "$out" "no upstream" "no-upstream refusal was not explicit"
  pass "fm-push-guard: missing upstream fails closed"
}

test_offline_remote_refuses() {
  local dir worker branch out status
  dir=$(new_case offline)
  worker="$dir/worker"
  branch=fm/task
  git -C "$dir/reviewer" push -q origin main:"$branch"
  git -C "$worker" checkout -qb "$branch"
  track_remote_task_branch "$worker" "$branch"
  mv "$dir/origin.git" "$dir/origin.offline"

  out=$(cd "$worker" && "$GUARD" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "guard passed while the remote was unavailable"
  assert_contains "$out" "remote head" "offline refusal did not explain the unknown remote head"
  pass "fm-push-guard: offline remote fails closed"
}

test_explicit_new_remote_branch_passes() {
  local dir worker out status
  dir=$(new_case new-branch)
  worker="$dir/worker"
  git -C "$worker" checkout -qb fm/new-task
  commit_file "$worker" new.txt new "first task change"

  out=$(cd "$worker" && "$GUARD" origin fm/new-task 2>&1); status=$?
  expect_code 0 "$status" "explicit new-branch push guard"
  assert_contains "$out" "does not exist" \
    "new-branch pass did not distinguish an absent ref from an unreachable remote"
  pass "fm-push-guard: explicit first push passes when the remote branch is provably absent"
}

test_dropped_remote_commits_are_named
test_clean_descendant_push_passes
test_patch_equivalent_rebase_passes
test_no_upstream_refuses
test_offline_remote_refuses
test_explicit_new_remote_branch_passes
