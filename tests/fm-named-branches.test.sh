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
  assert_grep 'Base branch: office' "$brief" "no-mistakes brief omitted the base branch"
  assert_grep 'no-mistakes axi run --base-branch office' "$brief" "no-mistakes brief omitted the PR base"
  assert_grep 'git checkout -b feature/widget' "$brief" "no-mistakes brief omitted the crew checkout"
  # shellcheck disable=SC2016
  assert_grep 'detached HEAD on a clean copy of its base branch' "$brief" "no-mistakes brief did not detach on the named base"

  id=named-brief-dp
  FM_HOME="$home" "$BRIEF" "$id" proj --mode direct-PR \
    --branch-name feature/widget --base-branch office >/dev/null
  brief="$home/data/$id/brief.md"
  # shellcheck disable=SC2016  # literal backticks in rendered prose must stay unexpanded
  assert_grep 'against the base branch `office` (`--base office`)' "$brief" "direct-PR brief omitted the PR base"

  id=named-brief-lo
  out=$(FM_HOME="$home" "$BRIEF" "$id" proj --mode local-only \
    --branch-name feature/widget --base-branch office 2>&1); status=$?
  expect_code 1 "$status" "a local-only named base was accepted"
  assert_contains "$out" "mode=local-only" "the local-only refusal did not explain itself"

  id=named-brief-lo
  FM_HOME="$home" "$BRIEF" "$id" proj --mode local-only \
    --branch-name feature/widget >/dev/null
  brief="$home/data/$id/brief.md"
  # shellcheck disable=SC2016
  assert_grep 'merge into local `main`' "$brief" "local-only brief omitted the landing branch"
  assert_grep 'ready in branch feature/widget' "$brief" "local-only brief omitted the crew branch"

  id=named-brief-default
  FM_HOME="$home" "$BRIEF" "$id" proj --mode local-only >/dev/null
  brief="$home/data/$id/brief.md"
  assert_no_grep 'Base branch: ' "$brief" "an omitted base wrote a base branch line"
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

  out=$(FM_HOME="$home" "$BRIEF" same proj --mode direct-PR \
    --branch-name office --base-branch office 2>&1); status=$?
  expect_code 1 "$status" "a crew branch equal to its base was accepted"
  assert_contains "$out" "cannot be the crew branch" "equal branches were not named"

  out=$(FM_HOME="$home" "$BRIEF" scout-name proj --scout --branch-name feature/widget 2>&1); status=$?
  expect_code 1 "$status" "a scout crew branch was accepted"
  assert_contains "$out" "applies only to ship briefs" "a scout crew branch was not refused as a ship-only flag"

  FM_HOME="$home" "$BRIEF" scout-base-collision proj --scout \
    --base-branch fm/scout-base-collision >/dev/null \
    || fail "a valid scout base equal to the default crew name was refused"
  assert_grep 'Base branch: fm/scout-base-collision' \
    "$home/data/scout-base-collision/brief.md" \
    "a valid scout base was not recorded in the brief"

  out=$(FM_HOME="$home" "$BRIEF" bad proj --mode local-only --base-branch 'has space' 2>&1); status=$?
  expect_code 1 "$status" "a base branch with a space was accepted"
  assert_contains "$out" "not a valid git branch name" "an unusable base was not named"
  pass "fm-brief: unusable crew and base selections are refused"
}

test_bare_originless_project_lock_resolves() {
  local home bare lock
  home="$TMP_ROOT/lock/home"
  bare="$TMP_ROOT/lock/project.git"
  mkdir -p "$home/state" "$home/data" "$home/config"
  git init -q --bare "$bare"
  lock=$(FM_HOME="$home" bash -c '. "$1"; fm_treehouse_project_lock_path "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$bare") \
    || fail "an origin-less bare project's shared lock could not be resolved"
  case "$lock" in
    "$home/state/"*) ;;
    *) fail "an origin-less bare project's lock escaped the local root: $lock" ;;
  esac
  pass "project locking resolves an origin-less bare repository"
}

test_spawn_checks_the_named_base_and_crew_branch_before_launch() {
  local home proj fakebin remote id out status
  home="$TMP_ROOT/spawn/home"
  proj="$TMP_ROOT/spawn/proj"
  fakebin="$TMP_ROOT/spawn/bin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$proj" "$fakebin"
  printf 'claude\n' > "$home/config/crew-harness"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  git init -q -b main "$proj"
  git_identity "$proj"
  commit_file "$proj" base base base
  printf -- '- proj [local-only] - named branch fixture (added 2026-01-01)\n' > "$home/data/projects.md"
  remote="$TMP_ROOT/spawn/remote.git"
  git init -q --bare "$remote"
  git -C "$proj" remote add origin "$remote"
  git -C "$proj" push -q origin main
  id=named-spawn-missing
  FM_HOME="$home" "$BRIEF" "$id" proj --mode no-mistakes \
    --branch-name feature/widget --base-branch nowhere >/dev/null
  fill_brief "$home/data/$id/brief.md"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off \
    --branch-name feature/widget --base-branch nowhere 2>&1); status=$?
  expect_code 1 "$status" "a missing named base was launched"
  assert_contains "$out" "origin/nowhere" "a missing named base was not named"
  assert_absent "$home/state/$id.meta" "a refused launch published a task record"

  id=named-spawn-mismatch
  FM_HOME="$home" "$BRIEF" "$id" proj --mode no-mistakes \
    --branch-name feature/widget --base-branch office >/dev/null
  fill_brief "$home/data/$id/brief.md"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off \
    --branch-name feature/widget 2>&1); status=$?
  expect_code 1 "$status" "a spawn that dropped the brief's base was accepted"
  assert_contains "$out" "records a Base branch line but the spawn has no --base-branch" "a dropped base was not named"

  id=named-spawn-collision
  FM_HOME="$home" "$BRIEF" "$id" proj --mode no-mistakes \
    --branch-name feature/widget --base-branch main >/dev/null
  fill_brief "$home/data/$id/brief.md"
  printf 'kind=ship\nproject=%s\nbranch=feature/widget\n' "$(cd "$proj" && pwd -P)" \
    > "$home/state/named-spawn-other.meta"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off \
    --branch-name feature/widget --base-branch main 2>&1); status=$?
  expect_code 1 "$status" "a shared crew branch was launched"
  assert_contains "$out" "already assigned to task named-spawn-other" "the occupying task was not named"
  assert_absent "$home/state/$id.meta" "a colliding launch published a task record"

  id=named-spawn-local-ref
  git -C "$proj" branch feature/local
  FM_HOME="$home" "$BRIEF" "$id" proj --mode no-mistakes \
    --branch-name feature/local --base-branch main >/dev/null
  fill_brief "$home/data/$id/brief.md"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off \
    --branch-name feature/local --base-branch main 2>&1); status=$?
  expect_code 1 "$status" "an existing local crew branch was launched"
  assert_contains "$out" "already exists locally" "the local crew branch was not refused"
  assert_absent "$home/state/$id.meta" "a local branch collision published a task record"

  git -C "$proj" checkout -qb office
  commit_file "$proj" office office office
  git -C "$proj" checkout -q main
  git -C "$proj" push -q origin office
  git -C "$proj" push -q origin refs/heads/office:refs/heads/feature/remote
  id=named-spawn-remote-ref
  FM_HOME="$home" "$BRIEF" "$id" proj --mode direct-PR \
    --branch-name feature/remote --base-branch office >/dev/null
  fill_brief "$home/data/$id/brief.md"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode direct-PR --yolo off \
    --branch-name feature/remote --base-branch office 2>&1); status=$?
  expect_code 1 "$status" "an existing remote crew branch was launched"
  assert_contains "$out" "already exists on origin" "the remote crew branch was not refused"
  assert_absent "$home/state/$id.meta" "a remote branch collision published a task record"

  git -C "$proj" remote set-url origin "$TMP_ROOT/spawn/missing.git"
  id=named-spawn-local-only-offline
  FM_HOME="$home" "$BRIEF" "$id" proj --mode local-only \
    --branch-name feature/offline >/dev/null
  fill_brief "$home/data/$id/brief.md"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode local-only --yolo off \
    --branch-name feature/offline 2>&1); status=$?
  assert_not_contains "$out" "could not check whether crew branch feature/offline exists on origin" \
    "a local-only spawn required an unreachable origin for crew collision checking"
  pass "fm-spawn: named base and crew-branch occupancy are refused before launch"
}

promote_keeps_the_named_branches() {
  local home project id instructions meta
  home="$TMP_ROOT/promote/home"
  project="$home/project"
  id=named-promote
  mkdir -p "$home/state" "$home/data" "$project"
  git init -q -b main "$project"
  git_identity "$project"
  commit_file "$project" base base base
  git -C "$project" checkout -qb office
  promote_remote="$home/remote.git"
  git init -q --bare "$promote_remote"
  git -C "$project" remote add origin "$promote_remote"
  git -C "$project" push -q origin main office
  printf 'window=fm-%s\nkind=scout\nworktree=%s\nproject=%s\nbase_branch=office\n' "$id" "$project" "$project" > "$home/state/$id.meta"
  FM_HOME="$home" "$BRIEF" "$id" proj --scout --base-branch office >/dev/null
  fill_brief "$home/data/$id/brief.md"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" "$id" \
    --mode direct-PR --yolo off --branch-name feature/widget --base-branch office >/dev/null
  instructions="$home/data/$id/ship-instructions.md"
  meta="$home/state/$id.meta"
  assert_grep 'Ship branch: feature/widget' "$instructions" "promotion omitted the crew branch"
  # shellcheck disable=SC2016
  assert_grep 'Never push to the base branch `office`' "$instructions" "promotion omitted the base"
  # shellcheck disable=SC2016
  assert_grep 'against the base branch `office` (`--base office`)' "$instructions" "promotion omitted the PR base"
  assert_grep 'branch=feature/widget' "$meta" "promotion did not record the crew branch"
  assert_grep 'base_branch=office' "$meta" "promotion did not record the base"
  pass "fm-promote: a named crew branch and base survive promotion"
}

test_promote_rejects_base_changes_and_branch_collisions() {
  local home project remote scout id out status
  home="$TMP_ROOT/promote-refuse/home"
  project="$home/project"
  remote="$home/remote.git"
  mkdir -p "$home/state" "$home/data" "$project"
  git init -q -b main "$project"
  git_identity "$project"
  commit_file "$project" base base base
  git -C "$project" checkout -qb office
  git init -q --bare "$remote"
  git -C "$project" remote add origin "$remote"
  git -C "$project" push -q origin main office

  git -C "$project" fetch -q origin refs/heads/office:refs/remotes/origin/office
  id=named-promote-base-change
  printf 'window=fm-%s\nkind=scout\nworktree=%s\nproject=%s\nbase_branch=office\n' "$id" "$project" "$project" > "$home/state/$id.meta"
  FM_HOME="$home" "$BRIEF" "$id" proj --scout --base-branch office >/dev/null
  fill_brief "$home/data/$id/brief.md"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" "$id" \
    --mode direct-PR --yolo off --branch-name feature/change --base-branch release 2>&1); status=$?
  expect_code 1 "$status" "promotion changed the scout's recorded base"
  assert_contains "$out" "cannot change the scout's recorded base" "a changed promotion base was not refused"
  assert_grep 'kind=scout' "$home/state/$id.meta" "base-change refusal published ship metadata"
  assert_absent "$home/data/$id/ship-instructions.md" "base-change refusal published ship instructions"

  id=named-promote-local-collision
  git -C "$project" branch feature/local
  git -C "$project" fetch -q origin refs/heads/office:refs/remotes/origin/office
  printf 'window=fm-%s\nkind=scout\nworktree=%s\nproject=%s\nbase_branch=office\n' "$id" "$project" "$project" > "$home/state/$id.meta"
  FM_HOME="$home" "$BRIEF" "$id" proj --scout --base-branch office >/dev/null
  fill_brief "$home/data/$id/brief.md"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" "$id" \
    --mode direct-PR --yolo off --branch-name feature/local --base-branch office 2>&1); status=$?
  expect_code 1 "$status" "promotion reused an existing local branch"
  assert_contains "$out" "already exists locally" "a local promotion branch collision was not refused"
  assert_grep 'kind=scout' "$home/state/$id.meta" "local collision published ship metadata"
  assert_absent "$home/data/$id/ship-instructions.md" "local collision published ship instructions"

  git -C "$project" push -q origin refs/heads/office:refs/heads/office
  git -C "$project" push -q origin refs/heads/office:refs/heads/feature/remote
  id=named-promote-remote-collision
  printf 'window=fm-%s\nkind=scout\nworktree=%s\nproject=%s\nbase_branch=office\n' "$id" "$project" "$project" > "$home/state/$id.meta"
  FM_HOME="$home" "$BRIEF" "$id" proj --scout --base-branch office >/dev/null
  fill_brief "$home/data/$id/brief.md"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" "$id" \
    --mode direct-PR --yolo off --branch-name feature/remote --base-branch office 2>&1); status=$?
  expect_code 1 "$status" "promotion reused an existing remote branch"
  assert_contains "$out" "already exists on origin" "a remote promotion branch collision was not refused"
  assert_grep 'kind=scout' "$home/state/$id.meta" "remote collision published ship metadata"
  assert_absent "$home/data/$id/ship-instructions.md" "remote collision published ship instructions"

  id=named-promote-missing-remote-base
  printf 'window=fm-%s\nkind=scout\nworktree=%s\nproject=%s\nbase_branch=release\n' "$id" "$project" "$project" > "$home/state/$id.meta"
  FM_HOME="$home" "$BRIEF" "$id" proj --scout --base-branch release >/dev/null
  fill_brief "$home/data/$id/brief.md"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" "$id" \
    --mode direct-PR --yolo off --branch-name feature/missing-base --base-branch release 2>&1); status=$?
  expect_code 1 "$status" "promotion accepted a missing remote base"
  assert_contains "$out" "does not exist on origin" "a missing remote base was not refused"
  assert_grep 'kind=scout' "$home/state/$id.meta" "missing remote base refusal published ship metadata"
  assert_absent "$home/data/$id/ship-instructions.md" "missing remote base refusal published ship instructions"

  git -C "$project" push -q origin refs/heads/office:refs/heads/release
  git -C "$project" checkout -q main
  git -C "$project" branch -D office >/dev/null
  git -C "$project" fetch -q origin refs/heads/release:refs/remotes/origin/release
  id=named-promote-remote-base
  printf 'window=fm-%s\nkind=scout\nworktree=%s\nproject=%s\nbase_branch=release\n' "$id" "$project" "$project" > "$home/state/$id.meta"
  FM_HOME="$home" "$BRIEF" "$id" proj --scout --base-branch release >/dev/null
  fill_brief "$home/data/$id/brief.md"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" "$id" \
    --mode direct-PR --yolo off --branch-name feature/remote-base --base-branch release >/dev/null
  assert_grep 'refs/remotes/origin/release' "$home/data/$id/ship-instructions.md" \
    "remote promotion instructions did not name the qualified base ref"

  scout="$home/scout"
  git clone -q "$remote" "$scout"
  git -C "$scout" fetch -q origin refs/heads/release:refs/remotes/origin/release
  git -C "$scout" update-ref -d refs/remotes/origin/release
  id=named-promote-missing-local-remote-base
  printf 'window=fm-%s\nkind=scout\nworktree=%s\nproject=%s\nbase_branch=release\n' "$id" "$scout" "$project" > "$home/state/$id.meta"
  FM_HOME="$home" "$BRIEF" "$id" proj --scout --base-branch release >/dev/null
  fill_brief "$home/data/$id/brief.md"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" "$id" \
    --mode direct-PR --yolo off --branch-name feature/missing-local-remote-base --base-branch release 2>&1); status=$?
  expect_code 1 "$status" "promotion accepted a missing local remote-tracking base"
  assert_contains "$out" "not available in the scout worktree" \
    "missing local remote-tracking base was not refused"
  assert_grep 'kind=scout' "$home/state/$id.meta" "missing local remote-tracking base published ship metadata"
  assert_absent "$home/data/$id/ship-instructions.md" \
    "missing local remote-tracking base published ship instructions"

  git -C "$project" branch office main
  id=named-promote-local-only-offline
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\nproject=%s\n' "$id" "$project" > "$home/state/$id.meta"
  FM_HOME="$home" "$BRIEF" "$id" proj --scout >/dev/null
  fill_brief "$home/data/$id/brief.md"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" "$id" \
    --mode local-only --yolo off --branch-name feature/offline >/dev/null \
    || fail "local-only promotion required an unreachable origin"
  assert_grep 'kind=ship' "$home/state/$id.meta" "offline local-only promotion did not publish ship metadata"

  git -C "$project" remote remove origin
  id=named-promote-publishing-local-base
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\nproject=%s\nbase_branch=office\n' "$id" "$project" > "$home/state/$id.meta"
  FM_HOME="$home" "$BRIEF" "$id" proj --scout --base-branch office >/dev/null
  fill_brief "$home/data/$id/brief.md"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" "$id" \
    --mode direct-PR --yolo off --branch-name feature/publishing-local-base --base-branch office 2>&1); status=$?
  expect_code 1 "$status" "a publishing promotion accepted a local-only base"
  assert_contains "$out" "without origin" "a publishing promotion did not require a remote base"
  assert_grep 'kind=scout' "$home/state/$id.meta" "a local-only publishing base refusal published ship metadata"
  assert_absent "$home/data/$id/ship-instructions.md" "a local-only publishing base refusal published ship instructions"
  pass "fm-promote: changed bases and occupied crew branches are refused"
}

test_local_merge_lands_on_the_default_branch() {
  local home proj id feature out
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
  git -C "$proj" checkout -q main
  printf 'project=%s\nmode=local-only\nbranch=feature/widget\n' "$proj" \
    > "$home/state/$id.meta"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$MERGE_LOCAL" "$id") \
    || fail "local-only merge failed: $out"
  [ "$(git -C "$proj" rev-parse refs/heads/main)" = "$feature" ] \
    || fail "local-only merge did not fast-forward main"
  [ "$(git -C "$proj" branch --show-current)" = main ] || fail "local-only merge changed the active checkout"
  assert_contains "$out" "merged feature/widget into local main" "local-only merge did not name main"
  pass "fm-merge-local: a local-only task lands on the default branch"
}

test_local_merge_refuses_a_recorded_base() {
  local home proj id out status
  home="$TMP_ROOT/merge-base/home"
  proj="$TMP_ROOT/merge-base/proj"
  id=named-merge-based
  mkdir -p "$home/data" "$home/state" "$proj"
  git init -q -b main "$proj"
  git_identity "$proj"
  commit_file "$proj" base base base
  git -C "$proj" checkout -qb feature/widget
  commit_file "$proj" change change change
  git -C "$proj" checkout -qb main
  printf 'project=%s\nmode=local-only\nbranch=feature/widget\nbase_branch=office\n' "$proj" \
    > "$home/state/$id.meta"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$MERGE_LOCAL" "$id" 2>&1); status=$?
  expect_code 1 "$status" "a local-only task with a recorded base was merged"
  assert_contains "$out" "records a base branch but mode=local-only cannot carry one" \
    "a contradictory local-only base was not named"
  pass "fm-merge-local: a recorded base contradicts mode=local-only"
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
  git -C "$seed" checkout -qb feature/widget
  commit_file "$seed" change change change
  feature=$(git -C "$seed" rev-parse HEAD)
  git -C "$seed" push -q origin feature/widget
  printf 'project=%s\nmode=local-only\nbranch=feature/widget\n' "$bare" \
    > "$home/state/$id.meta"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$MERGE_LOCAL" "$id") \
    || fail "bare local-only merge failed: $out"
  landed=$(git -C "$bare" rev-parse refs/heads/main)
  [ "$landed" = "$feature" ] || fail "bare repository did not fast-forward main"
  assert_contains "$out" "merged feature/widget into local main" "bare merge did not name main"
  pass "fm-merge-local: a bare repository fast-forwards the default branch"
}

test_review_uses_the_recorded_base() {
  local home proj remote id out feature status
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
  feature=$(git -C "$proj" rev-parse HEAD)
  remote="$TMP_ROOT/review/remote.git"
  git init -q --bare "$remote"
  git -C "$proj" remote add origin "$remote"
  git -C "$proj" push -q origin main
  printf 'worktree=%s\nproject=%s\nmode=local-only\nbranch=feature/widget\nbase_branch=office\n' "$proj" "$proj" \
    > "$home/state/$id.meta"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$REVIEW" "$id" --stat) \
    || fail "named-base review failed: $out"
  assert_contains "$out" "diff base: office" "review did not use the recorded base"
  assert_not_contains "$out" "diff base: main" "review fell back to main"

  git -C "$proj" branch origin/main "$feature"
  id=named-review-qualified
  printf 'worktree=%s\nproject=%s\nmode=direct-PR\nbranch=feature/widget\nbase_branch=main\n' "$proj" "$proj" \
    > "$home/state/$id.meta"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$REVIEW" "$id" --stat) \
    || fail "qualified remote-base review failed: $out"
  assert_contains "$out" "diff base: origin/main" "qualified remote-base review did not name origin/main"
  assert_not_contains "$out" "no changes vs origin/main" "review used the shadowing local origin/main branch"

  git -C "$remote" update-ref -d refs/heads/main
  id=named-review-stale
  printf 'worktree=%s\nproject=%s\nmode=direct-PR\nbranch=feature/widget\nbase_branch=main\n' "$proj" "$proj" \
    > "$home/state/$id.meta"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$REVIEW" "$id" --stat 2>&1); status=$?
  expect_code 1 "$status" "review used a cached remote base after fetch failure"
  assert_contains "$out" "refusing to review against a cached ref" \
    "stale remote-base review did not report the fetch failure"
  pass "fm-review-diff: a recorded base is the compare ref"
}

test_scout_review_uses_a_local_base_when_origin_lacks_it() {
  local home proj remote id out
  home="$TMP_ROOT/review-scout-local/home"
  proj="$TMP_ROOT/review-scout-local/proj"
  remote="$TMP_ROOT/review-scout-local/remote.git"
  id=named-review-scout-local
  mkdir -p "$home/data" "$home/state" "$proj"
  git init -q -b main "$proj"
  git_identity "$proj"
  commit_file "$proj" base base base
  git -C "$proj" checkout -qb office
  commit_file "$proj" office office office
  git -C "$proj" checkout -qb "fm/$id"
  commit_file "$proj" change change change
  git init -q --bare "$remote"
  git -C "$proj" remote add origin "$remote"
  git -C "$proj" push -q origin main
  printf 'kind=scout\nmode=scout\nworktree=%s\nproject=%s\nbranch=fm/%s\nbase_branch=office\n' \
    "$proj" "$proj" "$id" > "$home/state/$id.meta"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$REVIEW" "$id" --stat) \
    || fail "scout review refused its valid local-only base: $out"
  assert_contains "$out" "diff base: office" \
    "scout review did not use its local named base"
  assert_not_contains "$out" "diff base: origin/office" \
    "scout review invented a remote named base"
  pass "fm-review-diff: a scout uses its local named base when origin lacks it"
}

test_brief_names_the_crew_and_base_branches
test_brief_refuses_unusable_branch_selections
test_bare_originless_project_lock_resolves
test_spawn_checks_the_named_base_and_crew_branch_before_launch
promote_keeps_the_named_branches
test_promote_rejects_base_changes_and_branch_collisions
test_local_merge_lands_on_the_default_branch
test_local_merge_refuses_a_recorded_base
test_local_merge_fast_forwards_a_bare_repository
test_review_uses_the_recorded_base
test_scout_review_uses_a_local_base_when_origin_lacks_it
