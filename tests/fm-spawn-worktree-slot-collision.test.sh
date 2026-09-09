#!/usr/bin/env bash
# Regression tests for fm-spawn's treehouse worktree-pool-slot collision guard
# (bin/fm-spawn.sh, spawn_worktree_slot_conflict_task).
#
# A live incident: a treehouse pool handed a fresh spawn a slot another
# still-live task's state/<id>.meta already recorded as its own worktree. This
# is the spawn-side half of the worktree-pool-collision guard pair -
# bin/fm-teardown.sh's require_exclusive_worktree_slot_record is the
# teardown-side half, refusing to return a slot another live task's meta
# claims, and is already covered by tests/fm-teardown-endpoint-safety.test.sh.
# These tests simulate the same collision on the spawn side: two state/*.meta
# files recording the same worktree path, one belonging to the fresh spawn's
# would-be slot and one to an already-live task.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-slot-collision)

# make_collision_fakebin <dir>: a fake tmux whose `#{pane_current_path}` query
# returns FM_FAKE_PANE_COLLIDE for the first FM_FAKE_PANE_COLLIDE_READS calls,
# then FM_FAKE_PANE_CLEAN forever after - modeling treehouse handing back the
# contested slot on the first `treehouse get`, then a different slot once
# fm-spawn.sh resends 'treehouse get' after detecting the collision. Mirrors
# tests/fm-spawn-worktree-settle.test.sh's staged-pane technique.
make_collision_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_COLLIDE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_COLLIDE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_CLEAN:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_collision_case <name>: one project repo with two pool-shaped detached
# worktrees (a contested slot and a clean one) and a home ready to spawn into.
make_collision_case() {
  local name=$1 case_dir home project collide clean initial
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  collide="$case_dir/pool-collide"
  clean="$case_dir/pool-clean"
  fm_test_spawn_home "$home" codex
  git init --quiet "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  initial=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$collide" "$initial"
  git -C "$project" worktree add --quiet --detach "$clean" "$initial"
  printf '%s\n' "$case_dir|$home|$project|$collide|$clean"
}

read_collision_record() {
  IFS='|' read -r _ HOME_DIR PROJECT_DIR COLLIDE_DIR CLEAN_DIR <<EOF
$1
EOF
}

run_collision_spawn() {
  local id=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_COLLIDE="$COLLIDE_DIR" FM_FAKE_PANE_CLEAN="$CLEAN_DIR" \
    FM_FAKE_PANE_COLLIDE_READS="${FM_FAKE_PANE_COLLIDE_READS:-2}" \
    FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJECT_DIR" --mode no-mistakes --yolo off "$@" 2>&1
}

# A slot treehouse hands back that another live task's meta already claims
# must never be adopted: fm-spawn.sh should reject it and request another
# slot, landing the new task on the clean one instead.
test_contested_slot_is_rejected_and_a_clean_slot_is_adopted() {
  local rec other=live-holder-b1 id=collide-retry-a1 out status
  rec=$(make_collision_case retry-succeeds)
  read_collision_record "$rec"
  FAKEBIN_DIR=$(make_collision_fakebin "$TMP_ROOT/retry-succeeds/fake")
  COUNTFILE="$TMP_ROOT/retry-succeeds/pane-call-count"

  fm_write_meta "$HOME_DIR/state/$other.meta" \
    "window=firstmate:fm-$other" "worktree=$COLLIDE_DIR" "project=$PROJECT_DIR" "kind=ship"
  fm_test_spawn_brief "$HOME_DIR" "$id"

  out=$(run_collision_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once a clean slot is handed out"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_contains "$out" "$other" "the collision warning did not name the task already holding the slot"
  assert_grep "worktree=$CLEAN_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the clean slot handed out on retry"
  assert_no_grep "worktree=$COLLIDE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the slot another live task's meta already claims"
  pass "fm-spawn: a contested treehouse slot is rejected and a clean slot is adopted instead"
}

# When treehouse keeps handing back only the contested slot, fm-spawn.sh must
# fail loudly and bounded rather than adopt the collision or loop forever.
test_persistently_contested_slot_fails_bounded() {
  local rec other=live-holder-b2 id=collide-stuck-a2 out status
  rec=$(make_collision_case retry-exhausted)
  read_collision_record "$rec"
  FAKEBIN_DIR=$(make_collision_fakebin "$TMP_ROOT/retry-exhausted/fake")
  COUNTFILE="$TMP_ROOT/retry-exhausted/pane-call-count"

  fm_write_meta "$HOME_DIR/state/$other.meta" \
    "window=firstmate:fm-$other" "worktree=$COLLIDE_DIR" "project=$PROJECT_DIR" "kind=ship"
  fm_test_spawn_brief "$HOME_DIR" "$id"

  out=$(FM_FAKE_PANE_COLLIDE_READS=100000 FM_SPAWN_SLOT_CONFLICT_RETRIES=2 run_collision_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded after treehouse kept handing back only the contested slot"$'\n'"$out"
  assert_contains "$out" "refusing to launch into a contested slot" \
    "refusal did not explain the contested-slot exhaustion"
  assert_contains "$out" "$other" "refusal did not name the task holding the contested slot"
  assert_contains "$out" "2" "refusal did not report the configured retry bound"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "fm-spawn: a persistently contested treehouse slot fails loudly instead of looping or adopting it"
}

# The same collision, but the live holder's meta lives in a different, locally
# registered Firstmate home (a secondmate's own clone) rather than this home's
# own state/ - mirroring the cross-home shape
# tests/fm-teardown-endpoint-safety.test.sh already proves on the teardown side.
test_cross_home_contested_slot_is_rejected() {
  local rec other=live-holder-b3 id=collide-retry-cross-a3 out status
  local second_home second_project
  rec=$(make_collision_case cross-home)
  read_collision_record "$rec"
  FAKEBIN_DIR=$(make_collision_fakebin "$TMP_ROOT/cross-home/fake")
  COUNTFILE="$TMP_ROOT/cross-home/pane-call-count"

  second_home="$TMP_ROOT/cross-home/secondmate-home"
  second_project="$second_home/projects/project"
  mkdir -p "$second_home/projects" "$second_home/state" "$second_home/data"
  git clone -q "$PROJECT_DIR" "$second_project"
  printf '%s\n' "- mate - fixture (home: $second_home; scope: test; projects: project; added 2026-01-01)" \
    > "$HOME_DIR/data/secondmates.md"
  fm_write_meta "$second_home/state/$other.meta" \
    "window=firstmate:fm-$other" "worktree=$COLLIDE_DIR" "project=$second_project" "kind=ship"
  fm_test_spawn_brief "$HOME_DIR" "$id"

  out=$(run_collision_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once a clean slot is handed out"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_contains "$out" "$other" "the collision warning did not name the cross-home task holding the slot"
  assert_grep "worktree=$CLEAN_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the clean slot handed out on retry"
  assert_no_grep "worktree=$COLLIDE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the slot another firstmate home's live task already claims"
  pass "fm-spawn: a slot contested by another locally registered home's live task is rejected"
}

test_contested_slot_is_rejected_and_a_clean_slot_is_adopted
test_persistently_contested_slot_fails_bounded
test_cross_home_contested_slot_is_rejected

echo "# all fm-spawn-worktree-slot-collision tests passed"
