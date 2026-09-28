#!/usr/bin/env bash
# Regression tests for fm-spawn's --adopt-worktree first dispatch.
#
# A project whose tickets are claimed by creating a named worktree (for example
# `git worktree add .claude/worktrees/issue-<N> -b issue-<N>`) needs the spawn to
# launch into that exact copy instead of a Treehouse pool slot.
# These tests drive the real spawn path with a fake terminal and prove the
# adopted copy is recorded and entered without `treehouse get`, that the
# isolation proof still refuses the repository primary checkout, and that every
# other unusable path is refused with its concrete condition before any
# endpoint or record exists.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-adopt-worktree)

# make_case <name> <id>: a project with an origin that advanced after the
# ticket copy was claimed, and that claimed copy inside the project tree.
make_case() {
  local name=$1 id=$2 case_dir home project origin claim publisher fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  claim="$project/.claude/worktrees/issue-7"
  publisher="$case_dir/publisher"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_test_spawn_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  printf '.claude/worktrees/\n' > "$project/.gitignore"
  git -C "$project" add README.md .gitignore
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  git -C "$project" fetch --quiet origin
  git -C "$project" worktree add --quiet "$claim" -b issue-7

  git clone --quiet "file://$origin" "$publisher"
  printf 'advanced\n' > "$publisher/advanced-main.txt"
  git -C "$publisher" add advanced-main.txt
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm advance-main
  git -C "$publisher" push --quiet origin main

  CASE_DIR=$case_dir
  HOME_DIR=$home
  PROJECT_DIR=$project
  CLAIM_DIR=$(cd "$claim" && pwd -P)
  FAKEBIN_DIR=$fakebin
  PANE_LOG="$case_dir/pane.log"
  : > "$PANE_LOG"
}

# run_spawn <pane-path> <id> [args...]: spawn from PROJECT_DIR with the fake
# pane reporting <pane-path> and every pane text line logged to PANE_LOG.
run_spawn() {
  local pane=$1 id=$2
  shift 2
  FM_FAKE_PANE_LOG="$PANE_LOG" fm_test_run_spawn "$HOME_DIR" "$pane" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR" "$@"
}

test_adopted_worktree_is_recorded_and_entered_without_a_pool_allocation() {
  local id out status
  id='adopt-claimed-copy-a1'
  make_case claimed-copy "$id"

  out=$(run_spawn "$CLAIM_DIR" "$id" --mode no-mistakes --yolo off --adopt-worktree "$CLAIM_DIR")
  status=$?
  expect_code 0 "$status" "spawn should launch into the adopted ticket copy"$'\n'"$out"
  assert_contains "$out" "spawned $id" "the adopted spawn did not report success"
  assert_grep "worktree=$CLAIM_DIR" "$HOME_DIR/state/$id.meta" \
    "the adopted copy was not recorded as the task worktree"
  assert_grep "worktree_source=adopted" "$HOME_DIR/state/$id.meta" \
    "the task record does not mark its worktree as adopted rather than pooled"
  ! grep -Fq 'treehouse get' "$PANE_LOG" \
    || fail "the adopted spawn still asked Treehouse for a pool slot"$'\n'"$(cat "$PANE_LOG")"
  assert_grep "cd -- '$CLAIM_DIR'" "$PANE_LOG" \
    "the adopted spawn did not enter the adopted copy before launch"
  [ "$(git -C "$CLAIM_DIR" rev-parse HEAD)" = "$(git -C "$CLAIM_DIR" rev-parse origin/main)" ] \
    || fail "the adopted copy was not refreshed to current origin/main before launch"
  [ "$(git -C "$CLAIM_DIR" symbolic-ref --short HEAD)" = issue-7 ] \
    || fail "the adopted copy no longer sits on its claim branch"
  pass "an adopted worktree is recorded and entered without a Treehouse pool allocation"
}

test_adopted_primary_checkout_is_refused_by_the_isolation_proof() {
  local id out status primary before
  for spawning in primary linked; do
    id="adopt-primary-from-$spawning-a2"
    make_case "primary-from-$spawning" "$id"
    primary=$PROJECT_DIR
    if [ "$spawning" = linked ]; then
      git -C "$primary" worktree add --quiet --detach "$CASE_DIR/linked-home" HEAD
      PROJECT_DIR="$CASE_DIR/linked-home"
    fi
    before=$(git -C "$primary" rev-parse HEAD)

    out=$(run_spawn "$primary" "$id" --mode no-mistakes --yolo off --adopt-worktree "$primary")
    status=$?
    [ "$status" -ne 0 ] || fail "spawn adopted the repository primary checkout (spawning from $spawning)"
    assert_contains "$out" "did not yield an isolated worktree" \
      "the primary checkout was not refused by the isolation proof (spawning from $spawning)"
    assert_contains "$out" "refusing to launch to avoid tangling the primary checkout" \
      "the refusal did not name the primary-checkout protection (spawning from $spawning)"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "the refused adoption published task metadata"
    [ ! -s "$PANE_LOG" ] || fail "the refused adoption drove a pane"$'\n'"$(cat "$PANE_LOG")"
    [ "$(git -C "$primary" rev-parse HEAD)" = "$before" ] || fail "the refused adoption moved the primary checkout"
  done
  pass "an adopted path that is the primary checkout is refused exactly as a pooled one"
}

test_unusable_adopted_paths_are_refused_with_their_condition() {
  local id out status case_name path want other
  for case_name in missing foreign subdirectory pool-slot recorded dirty unlanded; do
    id="adopt-refuse-$case_name-a3"
    make_case "refuse-$case_name" "$id"
    path=$CLAIM_DIR
    case "$case_name" in
      missing)
        path="$CASE_DIR/no-such-copy"
        want="does not exist"
        ;;
      foreign)
        git init --quiet -b main "$CASE_DIR/other"
        git -C "$CASE_DIR/other" -c user.name=t -c user.email=t@t commit -q --allow-empty -m other
        git -C "$CASE_DIR/other" worktree add --quiet "$CASE_DIR/other-copy" -b other-copy
        path=$(cd "$CASE_DIR/other-copy" && pwd -P)
        want="is not a git worktree of project"
        ;;
      subdirectory)
        mkdir -p "$CLAIM_DIR/sub"
        path="$CLAIM_DIR/sub"
        want="not a worktree root"
        ;;
      pool-slot)
        mkdir -p "$CASE_DIR/pool/1"
        printf '{}\n' > "$CASE_DIR/pool/treehouse-state.json"
        git -C "$PROJECT_DIR" worktree add --quiet --detach "$CASE_DIR/pool/1/project" HEAD
        path=$(cd "$CASE_DIR/pool/1/project" && pwd -P)
        want="is a Treehouse pool slot"
        ;;
      recorded)
        other='other-task-a3'
        fm_write_meta "$HOME_DIR/state/$other.meta" "worktree=$CLAIM_DIR" "kind=ship"
        want="is already recorded for task $other"
        ;;
      dirty)
        printf 'claimed-session work\n' > "$CLAIM_DIR/uncommitted.txt"
        want="has uncommitted changes"
        ;;
      unlanded)
        printf 'earlier work\n' > "$CLAIM_DIR/earlier.txt"
        git -C "$CLAIM_DIR" add earlier.txt
        git -C "$CLAIM_DIR" -c user.name=t -c user.email=t@t commit -qm earlier
        want="carries commits not on 'origin/main'"
        ;;
    esac

    out=$(run_spawn "$path" "$id" --mode no-mistakes --yolo off --adopt-worktree "$path")
    status=$?
    [ "$status" -ne 0 ] || fail "spawn adopted an unusable path ($case_name)"$'\n'"$out"
    assert_contains "$out" "$want" "the $case_name refusal did not name its condition"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "the $case_name refusal published task metadata"
    case "$case_name" in
      dirty) assert_grep 'claimed-session work' "$CLAIM_DIR/uncommitted.txt" \
        "the dirty refusal discarded the claimed copy's work" ;;
      unlanded) [ -f "$CLAIM_DIR/earlier.txt" ] \
        || fail "the unlanded refusal reset the claimed copy's commit away" ;;
    esac
  done
  pass "missing, foreign, subdirectory, pool-slot, recorded, dirty, and unlanded adopted paths are refused by name"
}

test_adopt_worktree_is_refused_outside_a_first_ship_or_scout_dispatch() {
  local id out status
  id='adopt-combination-a4'
  make_case combination "$id"

  out=$(run_spawn "$CLAIM_DIR" "$id" --relaunch --adopt-worktree "$CLAIM_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "--relaunch accepted --adopt-worktree"
  assert_contains "$out" "--adopt-worktree applies only to a first ship or scout dispatch" \
    "the relaunch refusal did not explain the flag's scope"

  out=$(FM_FAKE_PANE_LOG="$PANE_LOG" fm_test_run_spawn "$HOME_DIR" "$CLAIM_DIR" "$FAKEBIN_DIR" \
    "$id=$PROJECT_DIR" --scout --adopt-worktree "$CLAIM_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "batch dispatch accepted --adopt-worktree"
  assert_contains "$out" "--adopt-worktree is single-task only" \
    "the batch refusal did not explain the flag's scope"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused combination published task metadata"
  pass "--adopt-worktree is refused on relaunch and batch dispatch"
}

test_adopted_worktree_is_recorded_and_entered_without_a_pool_allocation
test_adopted_primary_checkout_is_refused_by_the_isolation_proof
test_unusable_adopted_paths_are_refused_with_their_condition
test_adopt_worktree_is_refused_outside_a_first_ship_or_scout_dispatch

echo "# all fm-spawn-adopt-worktree tests passed"
