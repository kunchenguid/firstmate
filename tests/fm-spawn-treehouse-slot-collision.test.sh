#!/usr/bin/env bash
# Regression test for fm-spawn.sh's post-acquisition Treehouse slot-collision
# guard (bin/fm-spawn.sh, spawn_worktree_claimed_elsewhere and the retry loop
# around `treehouse get`).
#
# Reproduced live: rapid-fire fm-spawn.sh calls against the same Treehouse pool
# handed two different tasks the identical worktree path, because Treehouse's
# own pool-state liveness tracking loses track of a slot once the interactive
# agent replaces the short-lived intermediate shell that `treehouse get`
# originally opened. Firstmate cannot fix Treehouse's own bookkeeping, so
# fm-spawn.sh verifies independently: after every `treehouse get`, it greps
# every OTHER task's state/*.meta for the same worktree=, and on a match
# returns the colliding slot and retries acquisition (bounded, then fails
# loudly) rather than proceeding to launch onto a worktree another live task
# may already own.
#
# This test fakes both tmux (to control what pane_current_path reports after
# each `treehouse get`) and treehouse itself (to observe and succeed the
# `return --force` call the guard issues on a detected collision).
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-treehouse-slot-collision)

# make_collision_fakebin <dir> <return-log> builds a fake tmux whose
# `#{pane_current_path}` query reports FM_FAKE_PANE_WT1 after the first
# `treehouse get` is sent and FM_FAKE_PANE_WT2 after every `get` sent after
# that - one worktree per acquisition attempt, not per pane read - plus a fake
# treehouse that exits 0 and appends every `return` invocation's arguments to
# <return-log>.
make_collision_fakebin() {
  local dir=$1 return_log=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"treehouse get"*)
    n=0
    [ -f "\${FM_FAKE_GET_COUNTFILE:?unset}" ] && n=\$(cat "\$FM_FAKE_GET_COUNTFILE")
    n=\$((n + 1))
    printf '%s\n' "\$n" > "\$FM_FAKE_GET_COUNTFILE"
    exit 0
    ;;
esac
case "\$*" in
  *"#{pane_current_path}"*)
    n=0
    [ -f "\${FM_FAKE_GET_COUNTFILE:?unset}" ] && n=\$(cat "\$FM_FAKE_GET_COUNTFILE")
    if [ "\$n" -le 1 ]; then
      printf '%s\n' "\${FM_FAKE_PANE_WT1:?unset}"
    else
      printf '%s\n' "\${FM_FAKE_PANE_WT2:?unset}"
    fi
    exit 0
    ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = return ]; then
  printf '%s\n' "\$*" >> "$return_log"
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# make_collision_case <name> <id>: a home, a project with two real, isolated
# worktrees (WT1 the slot Treehouse will collide on, WT2 the clean slot a
# retry lands on), and an unrelated other task's state/<id>.meta already
# recording WT1 as its own worktree - simulating the live incident's second
# task landing on a slot the first task's record already claims.
make_collision_case() {
  local name=$1 id=$2 case_dir home proj wt1 wt2 return_log countfile fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt1="$case_dir/wt1"
  wt2="$case_dir/wt2"
  return_log="$case_dir/treehouse-return.log"
  countfile="$case_dir/get-call-count"
  mkdir -p "$case_dir"
  : > "$return_log"
  fakebin=$(make_collision_fakebin "$case_dir/fake" "$return_log")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt1" "wt1-$name"
  git -C "$proj" worktree add --quiet -b "wt2-$name" "$wt2"
  fm_test_spawn_brief "$home" "$id" "Exercise the Treehouse slot-collision guard for $id."
  fm_write_meta "$home/state/other-holder-$name.meta" "worktree=$wt1"
  printf '%s\n' "$case_dir|$home|$proj|$wt1|$wt2|$fakebin|$countfile|$return_log|other-holder-$name"
}

read_collision_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT1_DIR WT2_DIR FAKEBIN_DIR COUNTFILE RETURN_LOG HOLDER_ID <<EOF
$1
EOF
}

run_collision_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_WT1="$WT1_DIR" FM_FAKE_PANE_WT2="$WT2_DIR" \
    FM_FAKE_GET_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A collision on the first acquired slot is returned and retried; the spawn
# lands on the clean second slot and the colliding one is never recorded.
test_collision_is_returned_and_retried_onto_a_clean_slot() {
  local rec id out status
  id=collision-recovers-z1
  rec=$(make_collision_case collision-recovers "$id")
  read_collision_record "$rec"

  out=$(run_collision_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once a retry lands on an unclaimed slot"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_contains "$out" "$HOLDER_ID" "the collision warning did not name the task already holding the slot"
  assert_grep "worktree=$WT2_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the clean second slot"
  assert_no_grep "worktree=$WT1_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the slot task $HOLDER_ID already owns"
  assert_grep "return" "$RETURN_LOG" "the colliding slot was never returned to the pool"
  assert_grep "--force" "$RETURN_LOG" "the colliding slot was not force-returned"
  assert_grep "$WT1_DIR" "$RETURN_LOG" "the return call did not name the colliding worktree"
  [ "$(wc -l < "$RETURN_LOG")" -eq 1 ] || fail "expected exactly one treehouse return call, got $(wc -l < "$RETURN_LOG")"
  pass "a detected slot collision is returned and retried onto a clean slot, never recording the collided path"
}

# A pane stuck handing back the same claimed slot on every attempt exhausts
# the bounded retry budget and fails loudly instead of launching onto a
# worktree another live task's record already claims.
test_persistent_collision_fails_loudly_after_retries_exhausted() {
  local rec id out status
  id=collision-persists-z2
  rec=$(make_collision_case collision-persists "$id")
  read_collision_record "$rec"
  # Force every attempt to land on WT1 by keeping WT2 identical to WT1, so the
  # collision guard can never see a clean slot regardless of attempt count.
  WT2_DIR=$WT1_DIR

  out=$(FM_TREEHOUSE_SLOT_COLLISION_RETRIES=2 run_collision_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite every attempt colliding with task $HOLDER_ID's slot"$'\n'"$out"
  assert_contains "$out" "repeatedly handed" "the failure did not explain the retry budget was exhausted"
  assert_contains "$out" "$HOLDER_ID" "the failure did not name the task holding the colliding slot"
  assert_contains "$out" "2" "the failure did not cite the configured retry budget"
  [ "$(wc -l < "$RETURN_LOG")" -eq 2 ] || fail "expected exactly 2 treehouse return calls (one per exhausted retry), got $(wc -l < "$RETURN_LOG")"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a spawn that never resolved the collision published task metadata"
  pass "a persistent slot collision exhausts the retry budget and fails loudly without publishing metadata"
}

test_collision_is_returned_and_retried_onto_a_clean_slot
test_persistent_collision_fails_loudly_after_retries_exhausted

echo "# all fm-spawn-treehouse-slot-collision tests passed"
