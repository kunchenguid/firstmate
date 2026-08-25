#!/usr/bin/env bash
# Regression tests for bin/fm-merge-local.sh, firstmate's guarded local-only
# landing path.
#
# Contract under test: the landing stays a clean fast-forward of the LOCAL
# default branch (never rewritten, never forced); a branch diverged by an
# earlier parallel landing gets ONE automatic conflict-free trivial rebase in a
# throwaway detached worktree before that fast-forward; a real conflict refuses
# loudly naming the conflicted files; every pre-existing refusal (mode gate,
# dirty primary checkout, wrong checked-out branch) is unchanged.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MERGE="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local)

fm_git_identity

make_case() {
  local name=$1 case_dir project origin state base_sha
  name=${1:-case}
  case_dir="$TMP_ROOT/$name"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  state="$case_dir/state"
  mkdir -p "$state"

  # Base commit B0, mirrored to a bare origin that deliberately lags behind.
  fm_git_init_commit "$project"
  fm_git_add_origin "$project" "$origin"
  base_sha=$(git -C "$project" rev-parse HEAD)
  printf 'unmoved title\n' > "$project/TITLE.txt"
  git -C "$project" add TITLE.txt
  git -C "$project" commit -qm "seed title"

  # Advance LOCAL main past B0 without pushing: origin stays stale, exactly like
  # the read-only firstmate origin.
  printf 'local advance\n' > "$project/local-main.txt"
  git -C "$project" add local-main.txt
  git -C "$project" commit -qm "advance local main"

  printf '%s\n' "$case_dir|$project|$state|$base_sha"
}

read_case_record() {
  IFS='|' read -r CASE_DIR PROJECT STATE_DIR BASE_SHA <<EOF
$1
EOF
}

write_task_meta() {  # <task-id> [mode]
  local id=$1 mode=${2:-local-only}
  fm_write_meta "$STATE_DIR/$id.meta" \
    "project=$PROJECT" \
    "kind=ship" \
    "worktree=$CASE_DIR/wt-$id" \
    "mode=$mode" \
    "yolo=off"
}

run_merge() {  # <task-id>
  FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE="$STATE_DIR" \
    "$MERGE" "$1" 2>&1
}

main_head() {
  git -C "$PROJECT" rev-parse refs/heads/main
}

branch_from_base() {  # <task-id> <script>
  local id=$1 body=$2
  git -C "$PROJECT" checkout -q -b "fm/$id" "$BASE_SHA"
  ( cd "$PROJECT" && eval "$body" )
  git -C "$PROJECT" add -A
  git -C "$PROJECT" commit -qm "lane $id"
  git -C "$PROJECT" checkout -q main
}

no_temp_worktrees_or_refs() {
  [ "$(git -C "$PROJECT" worktree list | wc -l)" = 1 ] \
    || fail "a throwaway worktree was left registered in the project"
  ! git -C "$PROJECT" for-each-ref --format='%(refname)' 'refs/heads/fm-merge-*' | grep -q . \
    || fail "a temporary landing ref was left behind"
}

test_plain_fast_forward_is_unchanged() {
  local rec out status
  rec=$(make_case plain-ff)
  read_case_record "$rec"
  write_task_meta ff-lane
  # A lane branched from the CURRENT local main tip needs no rebase at all.
  git -C "$PROJECT" checkout -q -b "fm/ff-lane" main
  printf 'ff content\n' > "$PROJECT/ff.txt"
  git -C "$PROJECT" add ff.txt
  git -C "$PROJECT" commit -qm "ff lane work"
  git -C "$PROJECT" checkout -q main

  out=$(run_merge ff-lane)
  status=$?
  expect_code 0 "$status" "a fast-forwardable branch should land unchanged"
  assert_contains "$out" "merged fm/ff-lane into local main (" "landing should report the merged range"
  if printf '%s\n' "$out" | grep -q "automatic trivial rebase"; then
    fail "a pure fast-forward must not be reported as a rebased landing"
  fi
  pass "an ordinary fast-forward landing keeps its exact prior contract and wording"
}

test_disjoint_parallel_lane_lands_without_worker_roundtrip() {
  local rec out status before after
  rec=$(make_case disjoint)
  read_case_record "$rec"
  write_task_meta dis-lane
  branch_from_base dis-lane 'printf '"'"'lane file\n'"'"' > lane.txt'

  before=$(main_head)
  out=$(run_merge dis-lane)
  status=$?
  expect_code 0 "$status" "a disjoint diverged lane should land automatically"
  assert_contains "$out" "(after automatic trivial rebase)" \
    "the automatic trivial rebase should be visible in the landing report"
  after=$(main_head)
  [ "$before" != "$after" ] || fail "local main did not move"
  git -C "$PROJECT" merge-base --is-ancestor "$before" "$after" \
    || fail "local main was not advanced as a fast-forward"
  grep -q 'lane file' "$PROJECT/lane.txt" || fail "the lane's file is missing after landing"
  grep -q 'local advance' "$PROJECT/local-main.txt" || fail "the parallel local-main advance was lost"
  no_temp_worktrees_or_refs

  # Idempotence: relanding the now-stale branch must be a contained no-op, not
  # another roundtrip or a failure.
  out=$(run_merge dis-lane)
  status=$?
  expect_code 0 "$status" "relaning a landed branch should be a calm no-op"
  assert_contains "$out" "already contained in local main" "the no-op should say why nothing moved"
  no_temp_worktrees_or_refs
  pass "two disjoint parallel lanes land back to back with no manual steer"
}

test_real_conflict_refuses_loudly_naming_the_file() {
  local rec out status head_before
  rec=$(make_case conflict)
  read_case_record "$rec"
  write_task_meta con-lane
  branch_from_base con-lane 'printf '"'"'conflicting title\n'"'"' > TITLE.txt'

  head_before=$(main_head)
  out=$(run_merge con-lane)
  status=$?
  [ "$status" -ne 0 ] || fail "a genuinely conflicting lane must not land"
  assert_contains "$out" "REFUSED: automatic trivial rebase" "the conflict refusal must be loud"
  assert_contains "$out" "TITLE.txt" "the conflicted file must be named"
  assert_contains "$out" "Nothing was merged" "the refusal must state that nothing landed"
  [ "$(main_head)" = "$head_before" ] || fail "local main moved despite a refused landing"
  [ -z "$(git -C "$PROJECT" status --porcelain)" ] || fail "the refusal left the primary checkout dirty"
  no_temp_worktrees_or_refs
  pass "a synthetic same-file conflict aborts loudly naming the file without merging"
}

test_existing_red_state_refusals_are_unchanged() {
  local rec out status
  rec=$(make_case red-states)
  read_case_record "$rec"

  # Non-local-only tasks keep using the PR path.
  write_task_meta pr-lane no-mistakes
  branch_from_base pr-lane 'true'
  out=$(run_merge pr-lane)
  status=$?
  [ "$status" -ne 0 ] || fail "a non-local-only task must be refused"
  assert_contains "$out" "not local-only" "the mode gate must stay"

  # A dirty primary checkout is still refused.
  write_task_meta dirty-lane
  branch_from_base dirty-lane 'printf '"'"'x\n'"'"' > lane.txt'
  printf 'uncommitted\n' > "$PROJECT/dirty.txt"
  out=$(run_merge dirty-lane)
  status=$?
  [ "$status" -ne 0 ] || fail "a dirty primary checkout must be refused"
  assert_contains "$out" "dirty working tree" "the dirtiness refusal must stay"
  rm -f "$PROJECT/dirty.txt"

  # A primary checkout not on the default branch is still refused.
  git -C "$PROJECT" checkout -q -b side-branch
  out=$(run_merge dirty-lane)
  status=$?
  [ "$status" -ne 0 ] || fail "a non-default checked-out primary must be refused"
  assert_contains "$out" "expected default branch" "the branch-state refusal must stay"
  git -C "$PROJECT" checkout -q main
  git -C "$PROJECT" branch -q -D side-branch

  pass "existing guarantees hold: mode gate, dirty primary, wrong checked-out branch"
}

test_patch_identical_twin_needs_no_roundtrip() {
  local rec out status
  rec=$(make_case twins)
  read_case_record "$rec"
  write_task_meta twin-a
  write_task_meta twin-b
  branch_from_base twin-a 'printf '"'"'same fix\n'"'"' > fix.txt'
  branch_from_base twin-b 'printf '"'"'same fix\n'"'"' > fix.txt'

  out=$(run_merge twin-a)
  status=$?
  expect_code 0 "$status" "the first twin should land via trivial rebase"
  assert_contains "$out" "(after automatic trivial rebase)" "the first twin lands rebased"
  out=$(run_merge twin-b)
  status=$?
  expect_code 0 "$status" "the identical second twin should land without help"
  assert_contains "$out" "already contained in local main" "the twin should be recognized as contained"
  pass "a patch-identical parallel lane resolves itself with no worker roundtrip"
}

test_plain_fast_forward_is_unchanged
test_disjoint_parallel_lane_lands_without_worker_roundtrip
test_real_conflict_refuses_loudly_naming_the_file
test_existing_red_state_refusals_are_unchanged
test_patch_identical_twin_needs_no_roundtrip

echo "# all fm-merge-local tests passed"
