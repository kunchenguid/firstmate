#!/usr/bin/env bash
# tests/fm-land-behind-main.test.sh - refuse landing when a branch is too far behind main.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-land-lib.sh
. "$ROOT/bin/fm-land-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-land-behind-main)

make_stale_ship_repo() {  # <dir> <behind-count>
  local dir=$1 behind=$2 i
  git init -q -b main "$dir"
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m base
  git -C "$dir" checkout -q -b ship
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m ship
  git -C "$dir" checkout -q main
  i=0
  while [ "$i" -lt "$behind" ]; do
    git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
      commit -q --allow-empty -m "advance-$i"
    i=$((i + 1))
  done
}

make_ff_ship_repo() {  # <dir> <behind-count>
  local dir=$1 behind=$2 i
  git init -q -b main "$dir"
  i=0
  while [ "$i" -lt "$behind" ]; do
    git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
      commit -q --allow-empty -m "main-$i"
    i=$((i + 1))
  done
  git -C "$dir" checkout -q -b ship
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m ship
  git -C "$dir" checkout -q main
}

setup_merge_fixture() {  # <home> <id> <fixture-fn> <arg>
  local home=$1 id=$2 fn=$3 arg=$4 proj="$home/proj"
  "$fn" "$proj" "$arg"
  git -C "$proj" branch -f "fm/$id" ship
  git -C "$proj" checkout -q main
  mkdir -p "$home/state"
  printf 'project=%s\nmode=local-only\n' "$proj" > "$home/state/$id.meta"
}

test_land_lib_counts_behind_default() {
  local repo="$TMP_ROOT/count"
  make_stale_ship_repo "$repo" 25
  [ "$(fm_land_commits_behind_default "$repo" ship main)" = 25 ] \
    || fail "expected ship to be 25 commits behind main"
  fm_land_branch_too_far_behind_default "$repo" ship main \
    || fail "25 behind should exceed the default ceiling"
  pass "fm-land-lib measures commits behind the default branch"
}

test_land_refuse_reports_stale_branch() {
  local repo="$TMP_ROOT/refuse-lib" out status
  make_stale_ship_repo "$repo" 25
  out=$(fm_land_refuse_if_too_far_behind_default "$repo" ship main ship 2>&1) || status=$?
  status=${status:-0}
  [ "$status" -ne 0 ] || fail "land guard succeeded for a branch 25 commits behind main"
  assert_contains "$out" '25 commits behind main' \
    "refusal did not report how far behind the branch is"
  pass "fm-land-lib refuses landing when the branch is too far behind main"
}

test_merge_local_allows_when_close_enough() {
  local home="$TMP_ROOT/allow-behind" id=close-task out status before after
  setup_merge_fixture "$home" "$id" make_ff_ship_repo 5
  printf 'done: ready in branch fm/%s · Tests 1/0\n' "$id" > "$home/state/$id.status"
  before=$(git -C "$home/proj" rev-parse --short main)
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-merge-local.sh" "$id" 2>&1) || status=$?
  status=${status:-0}
  expect_code 0 "$status" "merge-local refused a fast-forward branch only 0 behind main: $out"
  after=$(git -C "$home/proj" rev-parse --short main)
  [ "$before" != "$after" ] || fail "merge-local did not advance main"
  pass "fm-merge-local still lands a fast-forward branch within the behind-main ceiling"
}

test_land_lib_counts_behind_default
test_land_refuse_reports_stale_branch
test_merge_local_allows_when_close_enough

echo "# all fm-land-behind-main tests passed"
