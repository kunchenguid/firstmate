#!/usr/bin/env bash
# Regression test for the spawn project-match gate (bin/fm-spawn.sh backlog
# preflight): a fresh spawn on a home whose backlog tracks the task must target
# the project the item records as its repo, so an isolated worktree of the wrong
# repository cannot pass the isolation checks. An item with no recorded repo is
# refused unless --repo-unrecorded-ok acknowledges the target.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-project-match)

# make_match_case <name> <id> [repo] builds a home with a real backlog carrying
# <id> (recording <repo> when given), a project named alpha, and its worktree.
make_match_case() {
  local name=$1 id=$2 repo=${3-} case_dir file
  case_dir="$TMP_ROOT/$name"
  CASE_HOME="$case_dir/home"
  CASE_PROJ="$case_dir/alpha"
  CASE_OTHER="$case_dir/beta"
  CASE_WT="$case_dir/wt"
  CASE_FAKEBIN=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$CASE_HOME" codex
  fm_git_worktree "$CASE_PROJ" "$CASE_WT" "wt-$name"
  fm_git_init_commit "$CASE_OTHER"
  fm_test_spawn_brief "$CASE_HOME" "$id" "Exercise the project match for $id."
  file="$CASE_HOME/data/backlog.md"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$file"
  if [ -n "$repo" ]; then
    tasks-axi add "$id" "project match fixture" --kind ship --repo "$repo" --file "$file" >/dev/null
  else
    tasks-axi add "$id" "project match fixture" --kind ship --file "$file" >/dev/null
  fi
}

run_match_spawn() { # <id> <project-dir> [extra args...]
  local id=$1 proj=$2
  shift 2
  fm_test_run_spawn "$CASE_HOME" "$CASE_WT" "$CASE_FAKEBIN" \
    "$id" "$proj" --mode no-mistakes --yolo off "$@"
}

test_matching_repo_spawns() {
  local id=match-ok-z1 out status
  make_match_case match-ok "$id" alpha
  out=$(run_match_spawn "$id" "$CASE_PROJ")
  status=$?
  expect_code 0 "$status" "a project matching the recorded repo should spawn"$'\n'"$out"
  assert_grep "worktree=$CASE_WT" "$CASE_HOME/state/$id.meta" "matching spawn did not record its worktree"
  pass "a project matching the item's recorded repo spawns"
}

test_mismatched_repo_is_refused_naming_both() {
  local id=match-bad-z2 out status
  make_match_case match-bad "$id" alpha
  out=$(run_match_spawn "$id" "$CASE_OTHER")
  status=$?
  expect_code 1 "$status" "a project disagreeing with the recorded repo should be refused"$'\n'"$out"
  assert_contains "$out" "project mismatch for $id" "refusal did not name the mismatch"
  assert_contains "$out" "repo alpha" "refusal did not name the recorded repo"
  assert_contains "$out" "project beta" "refusal did not name the targeted project"
  assert_absent "$CASE_HOME/state/$id.meta" "a refused spawn must not publish a task record"
  pass "a project disagreeing with the recorded repo is refused naming both"
}

test_unrecorded_repo_requires_acknowledgement() {
  local id=match-none-z3 out status
  make_match_case match-none "$id"
  out=$(run_match_spawn "$id" "$CASE_PROJ")
  status=$?
  expect_code 1 "$status" "an item with no recorded repo should be refused"$'\n'"$out"
  assert_contains "$out" "records no repo" "refusal did not explain the missing repo"
  assert_contains "$out" "--repo-unrecorded-ok" "refusal did not name the acknowledgement flag"
  assert_absent "$CASE_HOME/state/$id.meta" "a refused spawn must not publish a task record"

  out=$(run_match_spawn "$id" "$CASE_PROJ" --repo-unrecorded-ok)
  status=$?
  expect_code 0 "$status" "the acknowledgement flag should allow an unrecorded repo"$'\n'"$out"
  assert_grep "worktree=$CASE_WT" "$CASE_HOME/state/$id.meta" "acknowledged spawn did not record its worktree"
  pass "an item with no recorded repo needs --repo-unrecorded-ok"
}

test_acknowledgement_does_not_waive_a_mismatch() {
  local id=match-ack-z4 out status
  make_match_case match-ack "$id" alpha
  out=$(run_match_spawn "$id" "$CASE_OTHER" --repo-unrecorded-ok)
  status=$?
  expect_code 1 "$status" "the acknowledgement must not waive a recorded mismatch"$'\n'"$out"
  assert_contains "$out" "project mismatch for $id" "refusal did not name the mismatch"
  pass "--repo-unrecorded-ok does not waive a recorded repo mismatch"
}

test_matching_repo_spawns
test_mismatched_repo_is_refused_naming_both
test_unrecorded_repo_requires_acknowledgement
test_acknowledgement_does_not_waive_a_mismatch

echo "# all fm-spawn-project-match tests passed"
