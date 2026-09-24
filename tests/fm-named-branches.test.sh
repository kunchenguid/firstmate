#!/usr/bin/env bash
# Named crew branches and named integration branches, including a bare project.
#
# --branch-name selects the full crew branch. --base-branch selects the
# integration branch used at launch, as the PR target in the worker contract,
# and as the local landing ref. Omitted, both stay on the historical
# prefix-plus-id crew branch and the repository default.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIEF="$ROOT/bin/fm-brief.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
REVIEW="$ROOT/bin/fm-review-diff.sh"
TMP_ROOT=$(fm_test_tmproot fm-named-branches)

git_identity() { # <repo>
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name test
}

commit_file() { # <repo> <path> <body> <message>
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -qm "$4"
}

fill_brief() { # <file>
  local file=$1 content
  content=$(cat "$file")
  content=${content//'{TASK}'/Ship the office change on the named branch.}
  content=${content//'{FIRSTMATE_SPEC}'/Keep the change on the named crew branch.}
  printf '%s\n' "$content" > "$file"
}

test_brief_names_the_crew_and_base_branches() {
  local home id brief
  home="$TMP_ROOT/brief/home"
  mkdir -p "$home/data"
  id=named-brief-nm
  FM_HOME="$home" "$BRIEF" "$id" proj --mode no-mistakes \
    --branch-name feature/widget --base-branch office >/dev/null
  brief="$home/data/$id/brief.md"
  assert_grep 'Ship branch: feature/widget' "$brief" "no-mistakes brief omitted the crew branch"
  assert_grep 'Base branch contract: base_branch=office' "$brief" "no-mistakes brief omitted the base contract"
  assert_grep 'no-mistakes axi run --base-branch office' "$brief" "no-mistakes brief omitted the PR base"
  assert_grep 'git checkout -b feature/widget' "$brief" "no-mistakes brief omitted the crew checkout"
  # shellcheck disable=SC2016
  assert_grep 'detached HEAD on `office`' "$brief" "no-mistakes brief did not detach on the named base"

  id=named-brief-dp
  FM_HOME="$home" "$BRIEF" "$id" proj --mode direct-PR \
    --branch-name feature/widget --base-branch office >/dev/null
  brief="$home/data/$id/brief.md"
  assert_grep 'gh-axi pr create --base office' "$brief" "direct-PR brief omitted the PR base"

  id=named-brief-lo
  FM_HOME="$home" "$BRIEF" "$id" proj --mode local-only \
    --branch-name feature/widget --base-branch office >/dev/null
  brief="$home/data/$id/brief.md"
  # shellcheck disable=SC2016
  assert_grep 'merge into local `office`' "$brief" "local-only brief omitted the landing branch"
  assert_grep 'ready in branch feature/widget' "$brief" "local-only brief omitted the crew branch"

  id=named-brief-default
  FM_HOME="$home" "$BRIEF" "$id" proj --mode local-only >/dev/null
  brief="$home/data/$id/brief.md"
  assert_no_grep 'Base branch contract:' "$brief" "an omitted base wrote a base contract"
  assert_grep 'detached HEAD on a clean default branch' "$brief" "an omitted base changed the default checkout wording"
  assert_grep 'git checkout -b fm/named-brief-default' "$brief" "an omitted crew name left the legacy branch"
  pass "fm-brief: named crew and base branches render into launch, PR, and landing text"
}

test_brief_refuses_unusable_branch_selections() {
  local home out status
  home="$TMP_ROOT/brief-refuse/home"
  mkdir -p "$home/data"
  out=$(FM_HOME="$home" "$BRIEF" both proj --mode local-only \
    --branch-prefix fix/ --branch-name feature/widget 2>&1); status=$?
  expect_code 1 "$status" "both branch selectors were accepted"
  assert_contains "$out" "mutually exclusive" "both branch selectors were not named"

  out=$(FM_HOME="$home" "$BRIEF" same proj --mode local-only \
    --branch-name office --base-branch office 2>&1); status=$?
  expect_code 1 "$status" "a crew branch equal to its base was accepted"
  assert_contains "$out" "cannot be the crew branch" "equal branches were not named"

  out=$(FM_HOME="$home" "$BRIEF" scout-name proj --scout --branch-name feature/widget 2>&1); status=$?
  expect_code 1 "$status" "a scout crew branch was accepted"
  assert_contains "$out" "applies only to ship briefs" "a scout crew branch was not refused as a ship-only flag"

  out=$(FM_HOME="$home" "$BRIEF" bad proj --mode local-only --base-branch 'has space' 2>&1); status=$?
  expect_code 1 "$status" "a base branch with a space was accepted"
  assert_contains "$out" "not a usable git branch name" "an unusable base was not named"
  pass "fm-brief: unusable crew and base selections are refused"
}

test_spawn_checks_the_named_base_and_crew_branch_before_launch() {
  local home proj fakebin id out status
  home="$TMP_ROOT/spawn/home"
  proj="$TMP_ROOT/spawn/proj"
  fakebin="$TMP_ROOT/spawn/bin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$proj" "$fakebin"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  git init -q -b main "$proj"
  git_identity "$proj"
  commit_file "$proj" base base base
  printf -- '- proj [local-only] - named branch fixture (added 2026-01-01)\n' > "$home/data/projects.md"
  id=named-spawn-missing
  FM_HOME="$home" "$BRIEF" "$id" proj --mode local-only \
    --branch-name feature/widget --base-branch office >/dev/null
  fill_brief "$home/data/$id/brief.md"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode local-only --yolo off \
    --branch-name feature/widget --base-branch office 2>&1); status=$?
  expect_code 1 "$status" "a missing named base was launched"
  assert_contains "$out" "named base 'office' does not exist" "a missing named base was not named"
  assert_absent "$home/state/$id.meta" "a refused launch published a task record"

  id=named-spawn-mismatch
  FM_HOME="$home" "$BRIEF" "$id" proj --mode local-only \
    --branch-name feature/widget --base-branch office >/dev/null
  fill_brief "$home/data/$id/brief.md"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode local-only --yolo off \
    --branch-name feature/widget 2>&1); status=$?
  expect_code 1 "$status" "a spawn that dropped the brief's base was accepted"
  assert_contains "$out" "base mismatch" "a dropped base was not named"

  id=named-spawn-collision
  git -C "$proj" checkout -qb office
  commit_file "$proj" office office office
  FM_HOME="$home" "$BRIEF" "$id" proj --mode local-only \
    --branch-name feature/widget --base-branch office >/dev/null
  fill_brief "$home/data/$id/brief.md"
  printf 'kind=ship\nproject=%s\nbranch=feature/widget\n' "$(cd "$proj" && pwd -P)" \
    > "$home/state/named-spawn-other.meta"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode local-only --yolo off \
    --branch-name feature/widget --base-branch office 2>&1); status=$?
  expect_code 1 "$status" "a shared crew branch was launched"
  assert_contains "$out" "already assigned to task named-spawn-other" "the occupying task was not named"
  assert_absent "$home/state/$id.meta" "a colliding launch published a task record"
  pass "fm-spawn: named base and crew-branch occupancy are refused before launch"
}

promote_keeps_the_named_branches() {
  local home id instructions meta
  home="$TMP_ROOT/promote/home"
  id=named-promote
  mkdir -p "$home/state" "$home/data"
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\nbase_branch=office\n' "$id" > "$home/state/$id.meta"
  FM_HOME="$home" "$BRIEF" "$id" proj --scout --base-branch office >/dev/null
  fill_brief "$home/data/$id/brief.md"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" "$id" \
    --mode local-only --yolo off --branch-name feature/widget --base-branch office >/dev/null
  instructions="$home/data/$id/ship-instructions.md"
  meta="$home/state/$id.meta"
  assert_grep 'Ship branch: feature/widget' "$instructions" "promotion omitted the crew branch"
  assert_grep 'Base branch contract: base_branch=office' "$instructions" "promotion omitted the base"
  # shellcheck disable=SC2016
  assert_grep 'merge into local `office`' "$instructions" "promotion omitted the landing branch"
  assert_grep 'branch=feature/widget' "$meta" "promotion did not record the crew branch"
  assert_grep 'base_branch=office' "$meta" "promotion did not record the base"
  pass "fm-promote: a named crew branch and base survive promotion"
}

test_local_merge_lands_on_the_recorded_base() {
  local home proj id office feature out
  home="$TMP_ROOT/merge/home"
  proj="$TMP_ROOT/merge/proj"
  id=named-merge
  mkdir -p "$home/data" "$home/state" "$proj"
  git init -q -b main "$proj"
  git_identity "$proj"
  commit_file "$proj" base base base
  git -C "$proj" checkout -qb office
  commit_file "$proj" office office office
  git -C "$proj" checkout -qb feature/widget
  commit_file "$proj" change change change
  feature=$(git -C "$proj" rev-parse HEAD)
  git -C "$proj" checkout -q office
  printf 'project=%s\nmode=local-only\nbranch=feature/widget\nbase_branch=office\n' "$proj" \
    > "$home/state/$id.meta"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$MERGE_LOCAL" "$id") \
    || fail "named-base merge failed: $out"
  office=$(git -C "$proj" rev-parse refs/heads/office)
  [ "$office" = "$feature" ] || fail "named-base merge did not fast-forward office"
  assert_contains "$out" "merged feature/widget into local office" "named-base merge did not name office"
  pass "fm-merge-local: a recorded base is the landing branch"
}

test_local_merge_fast_forwards_a_bare_repository() {
  local home seed bare id feature out landed
  home="$TMP_ROOT/bare/home"
  seed="$TMP_ROOT/bare/seed"
  bare="$TMP_ROOT/bare/proj.git"
  id=named-bare
  mkdir -p "$home/data" "$home/state" "$seed"
  git init -q -b main "$seed"
  git_identity "$seed"
  commit_file "$seed" base base base
  git init -q --bare "$bare"
  git -C "$seed" remote add origin "$bare"
  git -C "$seed" push -q origin main
  git -C "$seed" checkout -qb office
  commit_file "$seed" office office office
  git -C "$seed" push -q origin office
  git -C "$seed" checkout -qb feature/widget
  commit_file "$seed" change change change
  feature=$(git -C "$seed" rev-parse HEAD)
  git -C "$seed" push -q origin feature/widget
  printf 'project=%s\nmode=local-only\nbranch=feature/widget\nbase_branch=office\n' "$bare" \
    > "$home/state/$id.meta"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$MERGE_LOCAL" "$id") \
    || fail "bare named-base merge failed: $out"
  landed=$(git -C "$bare" rev-parse refs/heads/office)
  [ "$landed" = "$feature" ] || fail "bare repository did not fast-forward office"
  assert_contains "$out" "merged feature/widget into local office" "bare merge did not name office"
  pass "fm-merge-local: a bare repository fast-forwards the recorded base"
}

test_review_uses_the_recorded_base() {
  local home proj id out
  home="$TMP_ROOT/review/home"
  proj="$TMP_ROOT/review/proj"
  id=named-review
  mkdir -p "$home/data" "$home/state" "$proj"
  git init -q -b main "$proj"
  git_identity "$proj"
  commit_file "$proj" base base base
  git -C "$proj" checkout -qb office
  commit_file "$proj" office office office
  git -C "$proj" checkout -qb feature/widget
  commit_file "$proj" change change change
  printf 'worktree=%s\nproject=%s\nbranch=feature/widget\nbase_branch=office\n' "$proj" "$proj" \
    > "$home/state/$id.meta"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$REVIEW" "$id" --stat) \
    || fail "named-base review failed: $out"
  assert_contains "$out" "diff base: office" "review did not use the recorded base"
  assert_not_contains "$out" "diff base: main" "review fell back to main"
  pass "fm-review-diff: a recorded base is the compare ref"
}

test_brief_names_the_crew_and_base_branches
test_brief_refuses_unusable_branch_selections
test_spawn_checks_the_named_base_and_crew_branch_before_launch
promote_keeps_the_named_branches
test_local_merge_lands_on_the_recorded_base
test_local_merge_fast_forwards_a_bare_repository
test_review_uses_the_recorded_base
