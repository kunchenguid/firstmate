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
  printf '.claude/worktrees/\n.claude/settings.local.json\n.opencode/\n' > "$project/.gitignore"
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

# The collision this feature exists to prevent crosses firstmate homes: a
# secondmate home has its own state dir, so the record scan in the spawning home
# cannot see a worker another home already launched into the same ticket copy.
# The owner claim written on adoption is what closes that, so it is driven here
# from a genuinely separate $FM_HOME.
second_home() { # <home-dir> <id>
  local home=$1 id=$2
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_test_spawn_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"
}

test_adoption_from_another_firstmate_home_is_refused() {
  local id other_id other_home out status link
  id='adopt-claim-first-a5'
  other_id='adopt-claim-second-a5'
  make_case cross-home "$id"
  other_home="$CASE_DIR/home-two"
  second_home "$other_home" "$other_id"

  out=$(run_spawn "$CLAIM_DIR" "$id" --mode no-mistakes --yolo off --adopt-worktree "$CLAIM_DIR")
  status=$?
  expect_code 0 "$status" "the first adoption should launch"$'\n'"$out"

  out=$(FM_FAKE_PANE_LOG="$PANE_LOG" fm_test_run_spawn "$other_home" "$CLAIM_DIR" "$FAKEBIN_DIR" \
    "$other_id" "$PROJECT_DIR" --mode no-mistakes --yolo off --adopt-worktree "$CLAIM_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "a second firstmate home adopted a copy another home already holds"$'\n'"$out"
  assert_contains "$out" "already claimed by task $id" \
    "the cross-home refusal did not name the task holding the copy"
  assert_contains "$out" "$HOME_DIR" \
    "the cross-home refusal did not name the firstmate home holding the copy"
  [ ! -e "$other_home/state/$other_id.meta" ] || fail "the refused cross-home adoption published task metadata"

  # A different spelling of the same copy resolves to the same worktree, so the
  # claim must refuse it exactly as it refuses the literal path.
  link="$CASE_DIR/claim-link"
  ln -s "$CLAIM_DIR" "$link"
  out=$(FM_FAKE_PANE_LOG="$PANE_LOG" fm_test_run_spawn "$other_home" "$link" "$FAKEBIN_DIR" \
    "$other_id" "$PROJECT_DIR" --mode no-mistakes --yolo off --adopt-worktree "$link")
  status=$?
  [ "$status" -ne 0 ] || fail "a symlinked spelling slipped past the owner claim"$'\n'"$out"
  assert_contains "$out" "already claimed by task $id" \
    "the symlinked spelling was not refused by the owner claim"
  [ ! -e "$other_home/state/$other_id.meta" ] || fail "the refused symlinked adoption published task metadata"

  # The ticket number is the natural task id for a copy named issue-<N>, so two
  # homes dispatching the same id against one copy is the likeliest collision of
  # all: a claim is this task's own only when the home matches too.
  second_home "$CASE_DIR/home-three" "$id"
  out=$(FM_FAKE_PANE_LOG="$PANE_LOG" fm_test_run_spawn "$CASE_DIR/home-three" "$CLAIM_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR" --mode no-mistakes --yolo off --adopt-worktree "$CLAIM_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "a second firstmate home adopted a copy held under the same task id"$'\n'"$out"
  assert_contains "$out" "already claimed by task $id" \
    "the same-id cross-home refusal did not name the task holding the copy"
  assert_contains "$out" "$HOME_DIR" \
    "the same-id cross-home refusal did not name the firstmate home holding the copy"
  [ ! -e "$CASE_DIR/home-three/state/$id.meta" ] \
    || fail "the refused same-id cross-home adoption published task metadata"
  assert_grep "home=$HOME_DIR" "$(git -C "$CLAIM_DIR" rev-parse --absolute-git-dir)/fm-adopted-owner" \
    "the refused same-id adoption overwrote the owning home's claim"
  pass "an adopted copy another firstmate home holds is refused, however it is spelled or named"
}

# The creator's own gitignored wiring file is invisible to the clean-copy check,
# so adoption has to save it before arming and put it back afterwards. This is
# the byte-for-byte contract on the file the creator handed over.
test_adoption_preserves_the_copys_own_wiring_file() {
  local id out status settings original
  id='adopt-preserve-settings-a8'
  make_case preserve-settings "$id"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  settings="$CLAIM_DIR/.claude/settings.local.json"
  mkdir -p "$CLAIM_DIR/.claude"
  printf '{"permissions":{"allow":["Bash(ls:*)"]}}\n' > "$settings"
  original=$(cat "$settings")

  out=$(run_spawn "$CLAIM_DIR" "$id" --mode no-mistakes --yolo off --adopt-worktree "$CLAIM_DIR")
  status=$?
  expect_code 0 "$status" "the adoption of a copy carrying its own settings should launch"$'\n'"$out"
  [ "$(cat "$settings")" != "$original" ] \
    || fail "the launch never armed its own wiring, so this test proves nothing"
  assert_grep "worktree_source=adopted" "$HOME_DIR/state/$id.meta" \
    "the adopted copy was not recorded as adopted"

  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" PATH="$FAKEBIN_DIR:$PATH" \
    "$ROOT/bin/fm-teardown.sh" "$id" --force > "$CASE_DIR/teardown.log" 2>&1
  status=$?
  expect_code 0 "$status" "teardown of the adopted task should succeed"$'\n'"$(cat "$CASE_DIR/teardown.log")"
  [ "$(cat "$settings")" = "$original" ] \
    || fail "teardown did not hand the creator's own settings file back byte-identical"$'\n'"$(cat "$settings")"
  pass "a copy's own wiring file survives adoption and teardown byte-identical"
}

# Re-running the same first dispatch against a copy already holding a live
# adoption must not re-preserve firstmate's own armed wiring as if it were the
# creator's: the originals saved by the first adoption are still pending restore.
test_redispatch_refuses_rather_than_replacing_preserved_originals() {
  local id out status settings original store
  id='adopt-redispatch-store-b1'
  make_case redispatch-store "$id"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  settings="$CLAIM_DIR/.claude/settings.local.json"
  mkdir -p "$CLAIM_DIR/.claude"
  printf '{"permissions":{"allow":["Bash(rg:*)"]}}\n' > "$settings"
  original=$(cat "$settings")

  out=$(run_spawn "$CLAIM_DIR" "$id" --mode no-mistakes --yolo off --adopt-worktree "$CLAIM_DIR")
  status=$?
  expect_code 0 "$status" "the first adoption should launch"$'\n'"$out"
  store=$(git -C "$CLAIM_DIR" rev-parse --absolute-git-dir)/fm-adopted-wiring
  [ -d "$store" ] || fail "the first adoption preserved nothing, so this test proves nothing"

  out=$(run_spawn "$CLAIM_DIR" "$id" --mode no-mistakes --yolo off --adopt-worktree "$CLAIM_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "a second first-dispatch adopted a copy whose originals are still held"$'\n'"$out"
  assert_contains "$out" "still holds harness wiring preserved at" \
    "the redispatch refusal did not name the preserved originals it would have replaced"
  [ "$(cat "$store/.claude/settings.local.json")" = "$original" ] \
    || fail "the refused redispatch replaced the creator's preserved original with firstmate's armed wiring"

  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" PATH="$FAKEBIN_DIR:$PATH" \
    "$ROOT/bin/fm-teardown.sh" "$id" --force > "$CASE_DIR/teardown.log" 2>&1
  status=$?
  expect_code 0 "$status" "teardown of the adopted task should succeed"$'\n'"$(cat "$CASE_DIR/teardown.log")"
  [ "$(cat "$settings")" = "$original" ] \
    || fail "teardown after a refused redispatch handed back firstmate's wiring as the creator's settings"$'\n'"$(cat "$settings")"
  pass "a redispatch onto a live adoption refuses instead of replacing the preserved originals"
}

# A refusal that happens after the copy is claimed must not take the creator's
# own wiring file with it: nothing of firstmate's was armed yet.
test_refused_adoption_leaves_the_copys_own_wiring_file() {
  local id out status settings original
  id='adopt-refuse-keeps-settings-a9'
  make_case refuse-keeps-settings "$id"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  settings="$CLAIM_DIR/.claude/settings.local.json"
  mkdir -p "$CLAIM_DIR/.claude"
  printf '{"permissions":{"allow":["Bash(git status:*)"]}}\n' > "$settings"
  original=$(cat "$settings")
  printf 'earlier work\n' > "$CLAIM_DIR/earlier.txt"
  git -C "$CLAIM_DIR" add earlier.txt
  git -C "$CLAIM_DIR" -c user.name=t -c user.email=t@t commit -qm earlier

  out=$(run_spawn "$CLAIM_DIR" "$id" --mode no-mistakes --yolo off --adopt-worktree "$CLAIM_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn adopted a copy carrying unlanded commits"$'\n'"$out"
  assert_contains "$out" "carries commits not on 'origin/main'" \
    "the refusal did not name its condition"
  [ "$(cat "$settings")" = "$original" ] \
    || fail "a refused adoption destroyed the creator's own settings file"$'\n'"$(cat "$settings")"
  pass "a refused adoption leaves the copy's own wiring file byte-identical"
}

# An adopted copy is its creator's, so nothing resets it the way a returned pool
# slot self-heals: a spawn that dies after arming wiring must take that wiring
# and its claim back out of the copy it was handed.
test_aborted_adoption_leaves_no_firstmate_wiring_in_the_copy() {
  local id out status claim excl
  id='adopt-abort-wiring-a6'
  make_case abort-wiring "$id"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  # A read-only per-worktree info/exclude fails the launch one step after the
  # claude hook wiring is armed into the copy and long before any task record.
  excl=$(git -C "$CLAIM_DIR" rev-parse --path-format=absolute --git-path info/exclude)
  mkdir -p "$(dirname "$excl")"
  : > "$excl"
  chmod a-w "$excl" "$(dirname "$excl")"

  out=$(run_spawn "$CLAIM_DIR" "$id" --mode no-mistakes --yolo off --adopt-worktree "$CLAIM_DIR")
  status=$?
  chmod u+w "$(dirname "$excl")" "$excl"
  [ "$status" -ne 0 ] || fail "the spawn survived a failed launch step"$'\n'"$out"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "the aborted adoption published task metadata"
  [ ! -e "$CLAIM_DIR/.claude/settings.local.json" ] \
    || fail "the aborted adoption left firstmate's hook wiring in its creator's copy"
  claim=$(git -C "$CLAIM_DIR" rev-parse --absolute-git-dir)/fm-adopted-owner
  [ ! -e "$claim" ] || fail "the aborted adoption left its owner claim on its creator's copy"
  pass "an adoption that aborts before publishing its record leaves the copy as it was handed over"
}

# A copy whose only deviation is a submodule left on the pin an older base
# recorded carries no user work at all. Reporting it as uncommitted changes
# sends the captain hunting for work that does not exist, so the adopted check
# has to diagnose it the way the pooled base refresh already does.
test_stale_submodule_pin_is_not_reported_as_uncommitted_work() {
  local id out status sub subpin1 subpin2
  id='adopt-stale-submodule-a7'
  make_case stale-submodule "$id"
  sub="$CASE_DIR/sub-origin"

  git init --quiet -b main "$sub"
  printf 'pin one\n' > "$sub/lib.txt"
  git -C "$sub" add lib.txt
  git -C "$sub" -c user.name=t -c user.email=t@t commit -qm sub-one
  subpin1=$(git -C "$sub" rev-parse HEAD)
  printf 'pin two\n' > "$sub/lib.txt"
  git -C "$sub" -c user.name=t -c user.email=t@t commit -qam sub-two
  subpin2=$(git -C "$sub" rev-parse HEAD)

  git -C "$PROJECT_DIR" -c protocol.file.allow=always -c user.name=t -c user.email=t@t \
    submodule --quiet add "file://$sub" ui
  git -C "$PROJECT_DIR" -c user.name=t -c user.email=t@t commit -qm add-submodule
  git -C "$CLAIM_DIR" checkout --quiet -B issue-7 main
  git -C "$CLAIM_DIR" -c protocol.file.allow=always submodule --quiet update --init
  git -C "$CLAIM_DIR/ui" checkout --quiet "$subpin1"

  out=$(run_spawn "$CLAIM_DIR" "$id" --mode no-mistakes --yolo off --adopt-worktree "$CLAIM_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn adopted a copy carrying a stale submodule pin"$'\n'"$out"
  assert_contains "$out" "stale submodule checkout" \
    "the stale submodule pin was not named as the cause"
  assert_contains "$out" "submodule 'ui'" "the refusal did not name the submodule"
  assert_contains "$out" "$subpin2" "the refusal did not report the pin this base records"
  assert_not_contains "$out" "has uncommitted changes" \
    "a stale submodule pin was misreported as the creator's uncommitted work"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "the stale-submodule refusal published task metadata"
  [ "$(git -C "$CLAIM_DIR/ui" rev-parse HEAD)" = "$subpin1" ] \
    || fail "the refusal converged the submodule instead of leaving the copy untouched"
  pass "an adopted copy whose only deviation is a stale submodule pin is diagnosed as one"
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
test_adoption_from_another_firstmate_home_is_refused
test_aborted_adoption_leaves_no_firstmate_wiring_in_the_copy
test_adoption_preserves_the_copys_own_wiring_file
test_refused_adoption_leaves_the_copys_own_wiring_file
test_redispatch_refuses_rather_than_replacing_preserved_originals
test_stale_submodule_pin_is_not_reported_as_uncommitted_work
test_unusable_adopted_paths_are_refused_with_their_condition
test_adopt_worktree_is_refused_outside_a_first_ship_or_scout_dispatch

echo "# all fm-spawn-adopt-worktree tests passed"
