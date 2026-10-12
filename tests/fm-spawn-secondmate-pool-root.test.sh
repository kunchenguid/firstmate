#!/usr/bin/env bash
# Regression tests for the per-home Treehouse pool root (bin/fm-wake-lib.sh's
# fm_treehouse_home_pool_root, consumed by bin/fm-spawn.sh and bin/fm-teardown.sh).
#
# Treehouse keys a pool by the project's origin, so a secondmate home whose
# project clone shares an origin with the main home's clone resolves to the main
# home's pool and is handed a worktree of the MAIN home's clone. These tests
# build exactly that fleet - one origin, a main home clone, a secondmate home
# clone - with both pools laid out as the real binary lays them under a root
# (<root>/.treehouse/<repo>-<hash>/<slot>/<repo>), then drive the real spawn and
# teardown paths with a fake terminal and a recording fake treehouse.
# They prove the secondmate spawn types `--root <per-home root>`, lands in a
# worktree of the secondmate's own clone under that root, and that teardown
# returns the slot with the same root; and that the main home's typed command
# and pool are unchanged.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
WAKE_LIB="$ROOT/bin/fm-wake-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-secondmate-pool-root)

# The pool directory name Treehouse derives from the origin; any stable string
# works here because the layout, not the hash, is what the scripts read.
POOL_NAME=proj-0ddba11

git_commit() {  # <repo> <message>
  git -C "$1" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "$2"
}

# Lay one pool slot out as Treehouse would under <root>: a detached worktree of
# <clone> at <root>/.treehouse/<pool>/1/proj plus the pool's state file that
# fm_treehouse_pool_slot requires. Echoes the slot path.
lay_pool_slot() {  # <root> <clone>
  local root=$1 clone=$2 pool slot
  pool="$root/.treehouse/$POOL_NAME"
  slot="$pool/1/proj"
  mkdir -p "$pool/1"
  git -C "$clone" worktree add --quiet --detach "$slot" HEAD
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$slot" > "$pool/treehouse-state.json"
  printf '%s\n' "$slot"
}

# Replace the fixture's no-op treehouse with one that records every invocation
# to FM_FAKE_TREEHOUSE_LOG, one line per call, so the suite can assert exactly
# which root a return addressed.
add_recording_treehouse() {  # <fakebin>
  cat > "$1/treehouse" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_TREEHOUSE_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TREEHOUSE_LOG"
exit 0
SH
  chmod +x "$1/treehouse"
}

prepare_home() {  # <home> <task-id>
  local home=$1 id=$2
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'manual\n' > "$home/config/backlog-backend"
  touch "$home/state/.last-watcher-beat"
  fm_test_spawn_brief "$home" "$id"
}

# make_fleet <name> <task-id> <secondmate-id>
# One origin, a main home clone, a secondmate home clone bound to the main home,
# a Treehouse base (TREEHOUSE_ROOT) holding the main home's pool, and the
# secondmate's per-home pool under <base>/.fm-pools/<secondmate-id>. Both pools
# hold a ready slot. Echoes a |-separated record for read_fleet_record.
make_fleet() {
  local name=$1 id=$2 mate=$3 case_dir seed origin main_home second_home base second_root main_slot second_slot fakebin
  case_dir="$TMP_ROOT/$name"
  seed="$case_dir/seed"
  origin="$case_dir/origin.git"
  main_home="$case_dir/main-home"
  second_home="$case_dir/second-home"
  base="$case_dir/treehouse-base"
  second_root="$base/.fm-pools/$mate"

  git init --quiet -b main "$seed"
  printf 'base\n' > "$seed/README.md"
  git -C "$seed" add README.md
  git_commit "$seed" initial
  git clone --quiet --bare "$seed" "$origin"

  prepare_home "$main_home" "$id"
  prepare_home "$second_home" "$id"
  git clone --quiet "file://$origin" "$main_home/projects/proj"
  git clone --quiet "file://$origin" "$second_home/projects/proj"
  # Bind the secondmate home to the main home the way a seed does: the home's
  # identity and parent markers, and the parent's registration of the mate,
  # which a teardown inside the secondmate home resolves.
  printf '%s\n' "$mate" > "$second_home/.fm-secondmate-home"
  cat > "$second_home/.fm-secondmate-parent" <<REC
schema=fm-secondmate-parent.v1
route=local
parent_home=$main_home
REC
  fm_write_secondmate_meta "$main_home/state/$mate.meta" "$second_home" "firstmate:fm-$mate" proj
  printf -- '- %s - fixture scope (home: %s; scope: fixture; projects: proj; added 2026-10-12)\n' \
    "$mate" "$second_home" > "$main_home/data/secondmates.md"

  main_slot=$(lay_pool_slot "$base" "$main_home/projects/proj")
  second_slot=$(lay_pool_slot "$second_root" "$second_home/projects/proj")

  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  add_recording_treehouse "$fakebin"
  fm_test_fake_sleep_noop "$fakebin"

  printf '%s\n' "$case_dir|$main_home|$second_home|$base|$second_root|$main_slot|$second_slot|$fakebin"
}

read_fleet_record() {
  IFS='|' read -r CASE_DIR MAIN_HOME SECOND_HOME BASE SECOND_ROOT MAIN_SLOT SECOND_SLOT FAKEBIN_DIR <<EOF
$1
EOF
}

# run_fleet_spawn <home> <pane-path> <task-id> [fm-spawn args...]
# The spawn under test, with the pane already sitting in <pane-path> (what the
# typed `treehouse get` leaves behind) and every typed pre-launch line recorded.
run_fleet_spawn() {
  local home=$1 pane=$2 id=$3
  shift 3
  FM_FAKE_PANE_LOG="$CASE_DIR/$(basename "$home").pane.log" \
  FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/$(basename "$home").treehouse.log" \
  TREEHOUSE_ROOT="$BASE" \
    fm_test_run_spawn "$home" "$pane" "$FAKEBIN_DIR" "$id" "$home/projects/proj" "$@"
}

run_fleet_teardown() {  # <home> <task-id>
  local home=$1 id=$2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/$(basename "$home").treehouse.log" \
    TREEHOUSE_ROOT="$BASE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$TEARDOWN" "$id" 2>&1
}

common_dir_of() {  # <path>
  local common
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir) || return 1
  CDPATH='' cd -- "$common" && pwd -P
}

# Resolve the per-home root exactly as the scripts do, through the library's
# public function, so the suite's expectation and the implementation cannot
# agree only by both being wrong about the layout.
derive_root() {  # <home> [env assignments...]
  local home=$1
  shift
  # shellcheck disable=SC2016  # $1/$2 are expanded by the inner bash from its positional arguments, not here
  env "$@" bash -c '. "$1"; fm_treehouse_home_pool_root "$2"' _ "$WAKE_LIB" "$home"
}

test_resolver_derives_per_home_root_only_for_secondmate_homes() {
  local rec out status
  rec=$(make_fleet resolver pool-root-resolver-r1 mate-resolver)
  read_fleet_record "$rec"

  out=$(derive_root "$SECOND_HOME" TREEHOUSE_ROOT="$BASE" 2>&1)
  status=$?
  expect_code 0 "$status" "the resolver should derive a secondmate home's root"$'\n'"$out"
  assert_equals "$SECOND_ROOT" "$out" "the secondmate root is not <base>/.fm-pools/<id>"

  out=$(derive_root "$SECOND_HOME" -u TREEHOUSE_ROOT HOME="$CASE_DIR/user-home" 2>&1)
  status=$?
  expect_code 0 "$status" "the resolver should fall back to HOME without TREEHOUSE_ROOT"$'\n'"$out"
  assert_equals "$CASE_DIR/user-home/.fm-pools/mate-resolver" "$out" \
    "without TREEHOUSE_ROOT the root is not <HOME>/.fm-pools/<id>"

  out=$(derive_root "$MAIN_HOME" TREEHOUSE_ROOT="$BASE" 2>&1)
  status=$?
  expect_code 0 "$status" "the resolver should accept the main home"$'\n'"$out"
  assert_equals "" "$out" "the main home must derive no per-home root"

  out=$(derive_root "$SECOND_HOME" TREEHOUSE_ROOT=relative/base 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a relative TREEHOUSE_ROOT must not yield a per-home root: '$out'"
  assert_contains "$out" "not absolute" "the relative-base refusal did not say why"

  printf 'bad/id\n' > "$SECOND_HOME/.fm-secondmate-home"
  out=$(derive_root "$SECOND_HOME" TREEHOUSE_ROOT="$BASE" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a malformed identity marker must not yield a per-home root: '$out'"
  assert_contains "$out" "usable secondmate id" "the malformed-marker refusal did not name the marker"
  pass "the resolver derives <base>/.fm-pools/<id> for a secondmate home, nothing for the main home, and refuses an unusable base or marker"
}

test_secondmate_spawn_lands_in_its_own_clone_under_the_per_home_root() {
  local rec id out status pane_log slot_common second_common main_common claim
  id='pool-root-second-spawn-r1'
  rec=$(make_fleet second-spawn "$id" mate-second)
  read_fleet_record "$rec"
  pane_log="$CASE_DIR/second-home.pane.log"

  out=$(run_fleet_spawn "$SECOND_HOME" "$SECOND_SLOT" "$id" --scout)
  status=$?
  expect_code 0 "$status" "the secondmate spawn should launch from its own pool"$'\n'"$out"
  assert_contains "$out" "spawned $id" "the secondmate spawn did not report success"

  grep -Fxq -- "treehouse get --root '$SECOND_ROOT'" "$pane_log" \
    || fail "the secondmate spawn did not type the per-home root; typed lines:"$'\n'"$(cat "$pane_log")"
  [ "$(grep -c -- 'treehouse get' "$pane_log")" -eq 1 ] \
    || fail "the secondmate spawn typed treehouse get more than once:"$'\n'"$(cat "$pane_log")"

  assert_grep "worktree=$SECOND_SLOT" "$SECOND_HOME/state/$id.meta" \
    "the secondmate spawn did not record its per-home slot as the task worktree"
  case "$SECOND_SLOT" in
    "$SECOND_ROOT/.treehouse/"*) ;;
    *) fail "the recorded slot is not under the per-home root: $SECOND_SLOT" ;;
  esac
  slot_common=$(common_dir_of "$SECOND_SLOT") || fail "cannot resolve the slot's common git dir"
  second_common=$(common_dir_of "$SECOND_HOME/projects/proj") || fail "cannot resolve the secondmate clone's git dir"
  main_common=$(common_dir_of "$MAIN_HOME/projects/proj") || fail "cannot resolve the main clone's git dir"
  assert_equals "$second_common" "$slot_common" \
    "the secondmate worker's slot is not a worktree of the secondmate's own clone"
  assert_not_equals "$main_common" "$slot_common" \
    "the secondmate worker's slot is a worktree of the main home's clone"

  # The spawn recognized the slot as a pool slot of its own clone: it claimed it.
  claim="$(dirname "$SECOND_SLOT")/.fm-slot-owner"
  assert_grep "task=$id" "$claim" "the secondmate spawn did not claim its per-home pool slot"

  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# secondmate spawn under the per-home pool root\n'
    printf '$ FM_HOME=%s TREEHOUSE_ROOT=%s bin/fm-spawn.sh %s %s --scout\n%s\nexit=%s\n' \
      "$SECOND_HOME" "$BASE" "$id" "$SECOND_HOME/projects/proj" "$out" "$status"
    printf 'typed: %s\nslot common dir: %s\nsecondmate clone: %s\nmain clone: %s\n' \
      "$(grep -- 'treehouse get' "$pane_log")" "$slot_common" "$second_common" "$main_common"
  fi
  pass "a secondmate spawn types --root <per-home root> and lands in a worktree of its own clone under that root"
}

test_secondmate_teardown_returns_the_slot_to_the_per_home_root() {
  local rec id out status th_log claim
  id='pool-root-second-teardown-r1'
  rec=$(make_fleet second-teardown "$id" mate-teardown)
  read_fleet_record "$rec"
  th_log="$CASE_DIR/second-home.treehouse.log"

  out=$(run_fleet_spawn "$SECOND_HOME" "$SECOND_SLOT" "$id" --scout)
  status=$?
  expect_code 0 "$status" "the secondmate spawn should launch before teardown"$'\n'"$out"
  claim="$(dirname "$SECOND_SLOT")/.fm-slot-owner"
  assert_grep "task=$id" "$claim" "the secondmate spawn did not claim its slot"

  # A scout teardown needs the work product and the completion gate's record.
  mkdir -p "$SECOND_HOME/data/$id"
  printf 'Scout report.\n' > "$SECOND_HOME/data/$id/report.md"
  printf 'decisions_reviewed=1\n' >> "$SECOND_HOME/state/$id.meta"
  : > "$th_log"

  out=$(run_fleet_teardown "$SECOND_HOME" "$id")
  status=$?
  expect_code 0 "$status" "the secondmate teardown should return the slot"$'\n'"$out"

  grep -Fxq -- "return --root $SECOND_ROOT --force $SECOND_SLOT" "$th_log" \
    || fail "teardown did not return the slot under the per-home root; treehouse calls:"$'\n'"$(cat "$th_log")"
  [ ! -e "$SECOND_HOME/state/$id.meta" ] || fail "teardown left the task record behind"
  [ ! -e "$claim" ] || fail "teardown left the slot claim behind after returning the slot"

  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# secondmate teardown under the per-home pool root\n'
    printf '$ FM_HOME=%s TREEHOUSE_ROOT=%s bin/fm-teardown.sh %s\n%s\nexit=%s\n' \
      "$SECOND_HOME" "$BASE" "$id" "$out" "$status"
    printf 'treehouse calls:\n%s\n' "$(cat "$th_log")"
  fi
  pass "a secondmate teardown returns the slot with the same per-home root the spawn acquired it under"
}

test_main_home_spawn_and_teardown_are_unchanged() {
  local rec id out status pane_log th_log slot_common main_common
  id='pool-root-main-r1'
  rec=$(make_fleet main-unchanged "$id" mate-unused)
  read_fleet_record "$rec"
  pane_log="$CASE_DIR/main-home.pane.log"
  th_log="$CASE_DIR/main-home.treehouse.log"

  out=$(run_fleet_spawn "$MAIN_HOME" "$MAIN_SLOT" "$id" --scout)
  status=$?
  expect_code 0 "$status" "the main home spawn should launch from the shared pool"$'\n'"$out"
  grep -Fxq -- 'treehouse get' "$pane_log" \
    || fail "the main home did not type the bare treehouse get; typed lines:"$'\n'"$(cat "$pane_log")"
  ! grep -Fq -- '--root' "$pane_log" \
    || fail "the main home's typed treehouse get carries a root:"$'\n'"$(cat "$pane_log")"
  assert_grep "worktree=$MAIN_SLOT" "$MAIN_HOME/state/$id.meta" \
    "the main home spawn did not record the shared pool slot"
  slot_common=$(common_dir_of "$MAIN_SLOT") || fail "cannot resolve the main slot's common git dir"
  main_common=$(common_dir_of "$MAIN_HOME/projects/proj") || fail "cannot resolve the main clone's git dir"
  assert_equals "$main_common" "$slot_common" "the main home's slot is not a worktree of its own clone"

  mkdir -p "$MAIN_HOME/data/$id"
  printf 'Scout report.\n' > "$MAIN_HOME/data/$id/report.md"
  printf 'decisions_reviewed=1\n' >> "$MAIN_HOME/state/$id.meta"
  : > "$th_log"
  out=$(run_fleet_teardown "$MAIN_HOME" "$id")
  status=$?
  expect_code 0 "$status" "the main home teardown should return the slot"$'\n'"$out"
  grep -Fxq -- "return --force $MAIN_SLOT" "$th_log" \
    || fail "the main home's return changed shape; treehouse calls:"$'\n'"$(cat "$th_log")"
  pass "the main home still types a bare treehouse get and returns without a root"
}

test_secondmate_spawn_refuses_an_underivable_root_before_any_window() {
  local rec id out status pane_log
  id='pool-root-refuse-r1'
  rec=$(make_fleet refuse "$id" mate-refuse)
  read_fleet_record "$rec"
  pane_log="$CASE_DIR/second-home.pane.log"
  printf 'bad/id\n' > "$SECOND_HOME/.fm-secondmate-home"

  out=$(run_fleet_spawn "$SECOND_HOME" "$SECOND_SLOT" "$id" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate home with an unusable identity marker must not spawn"$'\n'"$out"
  assert_contains "$out" "Treehouse pool root" "the refusal did not name the pool root"
  [ ! -e "$SECOND_HOME/state/$id.meta" ] || fail "the refused spawn published task metadata"
  [ ! -e "$pane_log" ] || ! grep -Fq -- 'treehouse get' "$pane_log" \
    || fail "the refused spawn still typed treehouse get:"$'\n'"$(cat "$pane_log")"
  pass "a secondmate home whose pool root cannot be derived refuses before typing treehouse get"
}

test_resolver_derives_per_home_root_only_for_secondmate_homes
test_secondmate_spawn_lands_in_its_own_clone_under_the_per_home_root
test_secondmate_teardown_returns_the_slot_to_the_per_home_root
test_main_home_spawn_and_teardown_are_unchanged
test_secondmate_spawn_refuses_an_underivable_root_before_any_window

echo "# all fm-spawn-secondmate-pool-root tests passed"
