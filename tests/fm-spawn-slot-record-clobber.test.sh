#!/usr/bin/env bash
# Regression test for the one pool-slot leak no cleanup command can undo.
#
# A fresh spawn publishes state/<id>.meta over whatever record is already there.
# When that record names a Treehouse pool slot the same task still holds, the
# replacement points the only record at the NEW slot, and the old slot keeps a
# claim no record names any more - so no teardown invocation can ever return it.
# bin/fm-spawn.sh refuses exactly that case; a record whose slot was already
# reassigned to someone else is not this task's to protect and must still spawn.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-slot-record-clobber)

# A home, a project, the settled worktree a fresh spawn would land in, and a
# separate Treehouse pool whose slot 1 is a real worktree of the same project.
make_clobber_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$case_dir/pool/1"
  git -C "$proj" worktree add -q --detach "$case_dir/pool/1/project"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$case_dir/pool/1/project" \
    > "$case_dir/pool/treehouse-state.json"
  fakebin=$(fm_fakebin "$case_dir/fake")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$wt"; exit 0 ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_clobber_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<REC
$1
REC
}

# Record the task as already living in pool slot 1, with <claimant> holding it.
seed_held_slot() {  # <id> <claimant>
  fm_write_meta "$HOME_DIR/state/$1.meta" \
    "window=firstmate:fm-$1" "endpoint_task_id=$1" \
    "worktree=$CASE_DIR/pool/1/project" "project=$PROJ_DIR" \
    "kind=ship" "mode=no-mistakes" "yolo=off" "spawn_gen=1"
  printf 'task=%s\nhome=%s\n' "$2" "$HOME_DIR" > "$CASE_DIR/pool/1/.fm-slot-owner"
}

run_clobber_spawn() {  # <id>
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$1" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

test_fresh_spawn_refuses_to_replace_a_record_that_still_holds_its_slot() {
  local rec id=held-slot-task out status

  rec=$(make_clobber_case clobber-refuses "$id")
  read_clobber_case "$rec"
  seed_held_slot "$id" "$id"

  set +e
  out=$(run_clobber_spawn "$id")
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a fresh spawn replaced the record that still holds this task's pool slot:"$'\n'"$out"
  assert_contains "$out" "still holds the pool slot at $CASE_DIR/pool/1/project" \
    "the refusal should name the slot the record still holds"
  assert_contains "$out" "fm-teardown.sh $id" \
    "the refusal should name the command that returns the slot"
  assert_contains "$out" "--relaunch" \
    "the refusal should name the way to resume the task instead"
  assert_grep "worktree=$CASE_DIR/pool/1/project" "$HOME_DIR/state/$id.meta" \
    "the refused spawn rewrote the record it was protecting"
  assert_grep "task=$id" "$CASE_DIR/pool/1/.fm-slot-owner" \
    "the refused spawn rewrote the slot claim"
  pass "fm-spawn: a fresh spawn refuses to replace a record that still holds its pool slot"
}

test_fresh_spawn_proceeds_when_the_recorded_slot_was_already_reassigned() {
  local rec id=reassigned-slot-task out status

  rec=$(make_clobber_case clobber-allows "$id")
  read_clobber_case "$rec"
  seed_held_slot "$id" "some-other-task"

  set +e
  out=$(run_clobber_spawn "$id")
  status=$?
  set -e
  expect_code 0 "$status" "a record whose slot was already reassigned should still spawn"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "the spawn did not record its new worktree"
  assert_grep "task=some-other-task" "$CASE_DIR/pool/1/.fm-slot-owner" \
    "the spawn rewrote another task's slot claim"
  pass "fm-spawn: a record whose pool slot was already reassigned still spawns"
}

test_fresh_spawn_refuses_to_replace_a_record_that_still_holds_its_slot_claim_unreadable() {
  local rec id=unreadable-claim-task out status

  rec=$(make_clobber_case clobber-unreadable "$id")
  read_clobber_case "$rec"
  seed_held_slot "$id" "$id"
  # Truncation IS the condition under test, so this claim file is deliberately
  # the one fixture that does not carry the shape the real writer produces.
  printf 'task=\n' > "$CASE_DIR/pool/1/.fm-slot-owner"

  set +e
  out=$(run_clobber_spawn "$id")
  status=$?
  set -e
  [ "$status" -ne 0 ] \
    || fail "a fresh spawn replaced a record whose slot claim could not be read:"$'\n'"$out"
  assert_contains "$out" "could not be read" \
    "the refusal should say the slot claim could not be read"
  assert_contains "$out" "$CASE_DIR/pool/1/project" \
    "the refusal should name the slot whose claim could not be read"
  assert_grep "worktree=$CASE_DIR/pool/1/project" "$HOME_DIR/state/$id.meta" \
    "the refused spawn rewrote the record it was protecting"
  pass "fm-spawn: a fresh spawn refuses when the held slot's claim cannot be read"
}

# Freeing a dirty slot by hand deletes the checkout, never the claim beside it,
# so the guard has to read the claim rather than the checkout: this is the exact
# state in which a republished record orphans a claim for good.
test_fresh_spawn_refuses_when_the_held_slots_checkout_was_deleted() {
  local rec id=deleted-checkout-task out status

  rec=$(make_clobber_case clobber-deleted-checkout "$id")
  read_clobber_case "$rec"
  seed_held_slot "$id" "$id"
  git -C "$PROJ_DIR" worktree remove --force "$CASE_DIR/pool/1/project"

  set +e
  out=$(run_clobber_spawn "$id")
  status=$?
  set -e
  [ "$status" -ne 0 ] \
    || fail "a fresh spawn orphaned the claim on a slot whose checkout was deleted:"$'\n'"$out"
  assert_contains "$out" "still holds the pool slot at $CASE_DIR/pool/1/project" \
    "the refusal should name the slot the record still holds"
  assert_grep "worktree=$CASE_DIR/pool/1/project" "$HOME_DIR/state/$id.meta" \
    "the refused spawn rewrote the record it was protecting"
  assert_grep "task=$id" "$CASE_DIR/pool/1/.fm-slot-owner" \
    "the refused spawn rewrote the slot claim"
  pass "fm-spawn: a held slot whose checkout was deleted still refuses a fresh spawn"
}

test_fresh_spawn_refuses_to_replace_a_record_that_still_holds_its_slot
test_fresh_spawn_proceeds_when_the_recorded_slot_was_already_reassigned
test_fresh_spawn_refuses_when_the_held_slots_checkout_was_deleted
test_fresh_spawn_refuses_to_replace_a_record_that_still_holds_its_slot_claim_unreadable
