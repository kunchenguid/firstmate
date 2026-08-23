#!/usr/bin/env bash
# Regression tests for fm-merge-local.sh's local landing.
#
# A task branch is always cut from origin's default-branch tip, so on a project
# whose local default branch carries commits origin does not have, landing that
# branch naively erases them. These tests drive the real script and prove the
# nominal landing still fast-forwards, the trap is refused by name, the explicit
# escape hatch is the only way through, and what it drops stays recoverable for
# as long as its rescue ref lives.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MERGE="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local)

git_c() { git -C "$1" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' "${@:2}"; }

# make_case <name> <id> [local_only_commit=yes]: build a home plus a project
# whose local main optionally carries an adoption commit origin never had, and a
# task branch fm/<id> cut from origin/main. Echoes home|project.
make_case() {
  local name=$1 id=$2 adopt=${3:-yes} case_dir home project origin base
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  mkdir -p "$home/state"

  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git_c "$project" add README.md
  git_c "$project" commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  git -C "$project" fetch --quiet origin
  git -C "$project" remote set-head origin --auto >/dev/null 2>&1
  base=$(git -C "$project" rev-parse HEAD)

  if [ "$adopt" = yes ]; then
    printf 'local adoption that must survive\n' > "$project/adoption.txt"
    git_c "$project" add adoption.txt
    git_c "$project" commit -qm 'adopt upstream PR #1234 locally'
  fi

  # The task branch starts at origin/main, exactly as a freshened pool worktree does.
  git_c "$project" branch "fm/$id" "$base"
  git_c "$project" checkout --quiet "fm/$id"
  printf 'worker change\n' > "$project/worker.txt"
  git_c "$project" add worker.txt
  git_c "$project" commit -qm 'worker work'
  git_c "$project" checkout --quiet main

  fm_write_meta "$home/state/$id.meta" "project=$project" "mode=local-only" "yolo=off"
  printf '%s|%s\n' "$home" "$project"
}

read_case_record() {
  IFS='|' read -r HOME_DIR PROJECT_DIR <<EOF
$1
EOF
}

run_merge() {
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    "$MERGE" "$@" 2>&1
}

test_clean_landing_fast_forwards() {
  local rec id out status
  id='merge-local-clean-r1'
  rec=$(make_case clean "$id" no)
  read_case_record "$rec"

  out=$(run_merge "$id")
  status=$?
  expect_code 0 "$status" "a clean landing should fast-forward without friction"
  assert_contains "$out" "merged fm/$id into local main" "clean landing did not report the merge"
  assert_grep 'worker change' "$PROJECT_DIR/worker.txt" "clean landing did not bring the worker's change"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed clean landing: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "a landing that drops nothing still fast-forwards with no added friction"
}

test_landing_that_drops_a_local_commit_is_refused() {
  local rec id out status before
  id='merge-local-trap-r2'
  rec=$(make_case trap "$id")
  read_case_record "$rec"
  before=$(git -C "$PROJECT_DIR" rev-parse main)

  out=$(run_merge "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a landing that erases a local commit succeeded"
  assert_contains "$out" "would drop 1 commit(s)" "refusal did not count the dropped commits"
  assert_contains "$out" "adopt upstream PR #1234 locally" "refusal did not name the commit that would disappear"
  assert_contains "$out" "git merge main" "refusal did not name the reconciliation to run"
  assert_contains "$out" "--drop-local-commits" "refusal did not name its explicit escape hatch"
  [ "$(git -C "$PROJECT_DIR" rev-parse main)" = "$before" ] || fail "the refusal still moved main"
  assert_grep 'local adoption that must survive' "$PROJECT_DIR/adoption.txt" \
    "the refused landing already erased the local adoption"
  assert_absent "$HOME_DIR/state/$id.local-merge-drop" "a refusal wrote a drop record"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed refusal:\n%s\n' "$out"
  fi
  pass "a landing that would erase a local commit is refused, naming the commit and the fix"
}

test_reconciled_branch_lands_cleanly() {
  local rec id out status
  id='merge-local-reconciled-r3'
  rec=$(make_case reconciled "$id")
  read_case_record "$rec"

  # The documented reconciliation: merge the local default branch into the task branch.
  git_c "$PROJECT_DIR" checkout --quiet "fm/$id"
  git_c "$PROJECT_DIR" merge --quiet --no-edit main
  git_c "$PROJECT_DIR" checkout --quiet main

  out=$(run_merge "$id")
  status=$?
  expect_code 0 "$status" "a reconciled branch should land: $out"
  assert_grep 'local adoption that must survive' "$PROJECT_DIR/adoption.txt" \
    "the reconciled landing lost the local adoption"
  assert_grep 'worker change' "$PROJECT_DIR/worker.txt" "the reconciled landing lost the worker's change"
  pass "the reconciliation the refusal names makes the same landing pass"
}

test_escape_hatch_drops_explicitly_and_traceably() {
  local rec id out status dropped_sha
  id='merge-local-escape-r4'
  rec=$(make_case escape "$id")
  read_case_record "$rec"
  dropped_sha=$(git -C "$PROJECT_DIR" rev-parse main)

  out=$(run_merge --drop-local-commits "$id")
  status=$?
  expect_code 0 "$status" "the explicit escape hatch should land: $out"
  assert_contains "$out" "DROPPING 1 local-only commit(s)" "the escape hatch dropped commits silently"
  assert_contains "$out" "$dropped_sha" "the escape hatch did not print the dropped commit's full SHA"
  assert_present "$HOME_DIR/state/$id.local-merge-drop" "the escape hatch left no trace record"
  assert_grep "dropped=$dropped_sha" "$HOME_DIR/state/$id.local-merge-drop" \
    "the trace record does not carry the dropped commit's recoverable SHA"
  [ "$(git -C "$PROJECT_DIR" rev-parse main)" = "$(git -C "$PROJECT_DIR" rev-parse "fm/$id")" ] \
    || fail "the escape hatch did not land the branch"
  [ ! -e "$PROJECT_DIR/adoption.txt" ] || fail "the escape hatch claimed a drop it did not perform"
  git -C "$PROJECT_DIR" cat-file -e "$dropped_sha^{commit}" \
    || fail "the dropped commit is not recoverable by the recorded SHA"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed escape hatch:\n%s\n' "$out"
  fi
  pass "the escape hatch drops only when asked, prints what it dropped, and records recoverable SHAs"
}

test_escape_hatch_is_a_noop_on_a_clean_landing() {
  local rec id out status
  id='merge-local-escape-noop-r5'
  rec=$(make_case escape-noop "$id" no)
  read_case_record "$rec"

  out=$(run_merge --drop-local-commits "$id")
  status=$?
  expect_code 0 "$status" "the escape hatch should stay harmless on a clean landing: $out"
  assert_contains "$out" "was unnecessary" "the escape hatch did not report itself unnecessary"
  assert_contains "$out" "merged fm/$id into local main" "the clean landing did not fast-forward"
  assert_absent "$HOME_DIR/state/$id.local-merge-drop" "a clean landing wrote a drop record"
  pass "the escape hatch never turns a clean landing into a reset"
}

test_dropped_commits_outlive_an_aggressive_gc() {
  local rec id out status dropped_sha ref rescue
  id='merge-local-rescue-r6'
  rec=$(make_case rescue "$id")
  read_case_record "$rec"
  dropped_sha=$(git -C "$PROJECT_DIR" rev-parse main)
  ref="refs/fm-dropped/$id/$(git -C "$PROJECT_DIR" rev-parse --short main)"

  out=$(run_merge --drop-local-commits "$id")
  status=$?
  expect_code 0 "$status" "the explicit escape hatch should land: $out"
  assert_contains "$out" "$ref" "the escape hatch did not name the rescue ref that keeps the drop recoverable"
  assert_contains "$out" "update-ref -d $ref" "the escape hatch did not say how to release the rescue ref"
  assert_grep "rescue_ref=$ref" "$HOME_DIR/state/$id.local-merge-drop" \
    "the trace record does not name the rescue ref that holds the dropped commits"
  rescue=$(git -C "$PROJECT_DIR" rev-parse --verify --quiet "$ref" || true)
  [ "$rescue" = "$dropped_sha" ] \
    || fail "rescue ref holds '$rescue', expected the pre-reset tip $dropped_sha"

  # The reflog is exactly what the record used to depend on; prune it away.
  git -C "$PROJECT_DIR" reflog expire --expire=now --expire-unreachable=now --all >/dev/null 2>&1
  git -C "$PROJECT_DIR" gc --prune=now --quiet >/dev/null 2>&1 || fail "gc failed in the test project"
  git -C "$PROJECT_DIR" cat-file -e "$dropped_sha^{commit}" 2>/dev/null \
    || fail "the dropped commit died with the reflog, so the recorded SHA is dead"
  assert_contains "$(git -C "$PROJECT_DIR" log -1 --format='%s' "$dropped_sha")" \
    'adopt upstream PR #1234 locally' "the rescued commit is no longer readable after gc"

  # And the documented release really releases: the ref is the only thing holding them.
  git -C "$PROJECT_DIR" update-ref -d "$ref"
  git -C "$PROJECT_DIR" reflog expire --expire=now --expire-unreachable=now --all >/dev/null 2>&1
  git -C "$PROJECT_DIR" gc --prune=now --quiet >/dev/null 2>&1 || fail "gc failed after releasing the rescue ref"
  if git -C "$PROJECT_DIR" cat-file -e "$dropped_sha^{commit}" 2>/dev/null; then
    fail "the dropped commit survived the documented release, so the rescue ref is not what was holding it"
  fi
  pass "dropped commits are held by a rescue ref that outlives the reflog, and the documented release frees them"
}

test_successive_drops_each_keep_their_own_rescue() {
  local rec id out status first_sha second_sha first_ref second_ref
  id='merge-local-rescue-twice-r7'
  rec=$(make_case rescue-twice "$id")
  read_case_record "$rec"
  first_sha=$(git -C "$PROJECT_DIR" rev-parse main)
  first_ref="refs/fm-dropped/$id/$(git -C "$PROJECT_DIR" rev-parse --short main)"

  out=$(run_merge --drop-local-commits "$id")
  status=$?
  expect_code 0 "$status" "the first authorized drop should land: $out"

  # A later local-only commit makes the same task droppable again. The second
  # drop must succeed on its own, without the operator releasing the first rescue.
  printf 'a second local adoption\n' > "$PROJECT_DIR/adoption-2.txt"
  git_c "$PROJECT_DIR" add adoption-2.txt
  git_c "$PROJECT_DIR" commit -qm 'adopt upstream PR #5678 locally'
  second_sha=$(git -C "$PROJECT_DIR" rev-parse main)
  second_ref="refs/fm-dropped/$id/$(git -C "$PROJECT_DIR" rev-parse --short main)"
  [ "$second_ref" != "$first_ref" ] || fail "both drops resolved to the same rescue ref name"

  out=$(run_merge --drop-local-commits "$id")
  status=$?
  expect_code 0 "$status" "the second authorized drop should land without releasing the first rescue: $out"
  assert_contains "$out" "$second_ref" "the second drop did not name its own rescue ref"

  [ "$(git -C "$PROJECT_DIR" rev-parse --verify --quiet "$first_ref")" = "$first_sha" ] \
    || fail "the second drop displaced the first drop's rescue ref"
  [ "$(git -C "$PROJECT_DIR" rev-parse --verify --quiet "$second_ref")" = "$second_sha" ] \
    || fail "the second drop did not pin its own tip"

  git -C "$PROJECT_DIR" reflog expire --expire=now --expire-unreachable=now --all >/dev/null 2>&1
  git -C "$PROJECT_DIR" gc --prune=now --quiet >/dev/null 2>&1 || fail "gc failed in the test project"
  git -C "$PROJECT_DIR" cat-file -e "$first_sha^{commit}" 2>/dev/null \
    || fail "the first drop's commits died once a second drop happened"
  git -C "$PROJECT_DIR" cat-file -e "$second_sha^{commit}" 2>/dev/null \
    || fail "the second drop's commits are not held by their rescue ref"
  assert_contains "$(git -C "$PROJECT_DIR" log -1 --format='%s' "$first_sha")" \
    'adopt upstream PR #1234 locally' "the first drop's rescued commit is no longer readable"
  assert_contains "$(git -C "$PROJECT_DIR" log -1 --format='%s' "$second_sha")" \
    'adopt upstream PR #5678 locally' "the second drop's rescued commit is no longer readable"
  pass "successive drops on one task each keep their own rescue ref, and neither release is forced by the other"
}

test_redropping_a_recovered_tip_reuses_its_own_rescue() {
  local rec id out status dropped_sha ref
  id='merge-local-rescue-redrop-r8'
  rec=$(make_case rescue-redrop "$id")
  read_case_record "$rec"
  dropped_sha=$(git -C "$PROJECT_DIR" rev-parse main)
  ref="refs/fm-dropped/$id/$(git -C "$PROJECT_DIR" rev-parse --short main)"

  out=$(run_merge --drop-local-commits "$id")
  status=$?
  expect_code 0 "$status" "the first authorized drop should land: $out"

  # The operator recovers main from the rescue ref, then decides to drop again.
  git_c "$PROJECT_DIR" reset --hard --quiet "$ref"

  out=$(run_merge --drop-local-commits "$id")
  status=$?
  expect_code 0 "$status" "re-dropping a recovered tip should land: $out"
  assert_contains "$out" "already holds $dropped_sha" "the re-drop did not say the rescue ref was already in place"
  [ "$(git -C "$PROJECT_DIR" rev-parse --verify --quiet "$ref")" = "$dropped_sha" ] \
    || fail "the re-drop moved the rescue ref off the tip it already held"
  [ "$(git -C "$PROJECT_DIR" rev-parse main)" = "$(git -C "$PROJECT_DIR" rev-parse "fm/$id")" ] \
    || fail "the re-drop did not land the branch"
  pass "re-dropping a tip a rescue ref already holds keeps that ref and says so"
}

test_clean_landing_fast_forwards
test_landing_that_drops_a_local_commit_is_refused
test_reconciled_branch_lands_cleanly
test_escape_hatch_drops_explicitly_and_traceably
test_escape_hatch_is_a_noop_on_a_clean_landing
test_dropped_commits_outlive_an_aggressive_gc
test_successive_drops_each_keep_their_own_rescue
test_redropping_a_recovered_tip_reuses_its_own_rescue

echo "# all fm-merge-local tests passed"
