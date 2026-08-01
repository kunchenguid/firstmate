#!/usr/bin/env bash
# Regression test for the fm-spawn.sh worktree-ownership guard
# (bin/fm-spawn.sh, worktree_meta_claimant + validate_spawn_worktree).
#
# The worktree pool (treehouse, or any provider) keys slot reuse off live-agent
# presence, not recorded task ownership: a crash- or reboot-orphaned but still
# owned slot reads as "empty" and gets handed to a new spawn, which resets its
# branch and destroys that task's unlanded work (observed 2026-07-21, when a
# treehouse status false-"empty" let a new spawn reset an in-flight task's slot
# to detached HEAD). state/<id>.meta ownership outlives the agent process, so
# fm-spawn must REFUSE a slot that any OTHER task's metadata still claims,
# independent of whether an agent is live in it.
#
# This test drives the real fm-spawn.sh with a fake tmux whose pane settles into
# a worktree, and asserts:
#   1. a pre-existing state/<other>.meta claiming that worktree makes the spawn
#      refuse loudly, leave the claimant's meta untouched, and never write the
#      new task's meta or launch it;
#   2. a claimant that records a DIFFERENT worktree does not trip the guard, so
#      an ordinary distinct-slot spawn still succeeds.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-claim-guard)

# make_claim_fakebin <dir>: a fake tmux whose pane_current_path always returns
# FM_FAKE_PANE_PATH (the settled worktree), plus a no-op treehouse.
make_claim_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
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

# make_claim_case <name>: build a home, a project with a real worktree (the
# settled slot the pane moves into), and a second real checkout standing in for
# a DIFFERENT worktree another task could own. Echoes a pipe-joined record.
make_claim_case() {
  local name=$1 case_dir home proj wt other_wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  other_wt="$case_dir/other-wt"
  fakebin=$(make_claim_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$other_wt"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$other_wt|$fakebin"
}

read_claim_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR OTHER_WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

seed_task_brief() {
  local id=$1
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
}

run_claim_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A worktree another task's metadata still claims must not be reused: the spawn
# refuses, names the owning task, leaves that task's meta intact, and never
# records or launches the new task.
test_meta_claimed_slot_is_refused() {
  local rec owner_id new_id out status
  owner_id=claim-owner-a1
  new_id=claim-new-a2
  rec=$(make_claim_case claim-refuse)
  read_claim_record "$rec"
  seed_task_brief "$new_id"
  # The still-owned in-flight task records the settled worktree as its slot.
  fm_write_meta "$HOME_DIR/state/$owner_id.meta" \
    "window=firstmate:fm-$owner_id" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=codex"

  out=$(run_claim_spawn "$new_id")
  status=$?
  expect_code 1 "$status" "spawn should refuse a meta-claimed worktree"
  assert_contains "$out" "still claims it" "refusal did not explain the ownership collision"
  assert_contains "$out" "$owner_id" "refusal did not name the owning task"
  assert_absent "$HOME_DIR/state/$new_id.meta" \
    "new task's meta was written despite the refusal"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$owner_id.meta" \
    "owning task's meta was disturbed by the refused spawn"
  pass "a worktree another task's metadata still claims is refused, not silently reused"
}

# A claimant that records a DIFFERENT worktree must not trip the guard: an
# ordinary spawn into a genuinely free slot still succeeds.
test_distinct_slot_claim_does_not_false_refuse() {
  local rec owner_id new_id out status
  owner_id=claim-owner-b1
  new_id=claim-new-b2
  rec=$(make_claim_case claim-allow)
  read_claim_record "$rec"
  seed_task_brief "$new_id"
  # Another task owns a DIFFERENT worktree; the new slot is genuinely free.
  fm_write_meta "$HOME_DIR/state/$owner_id.meta" \
    "window=firstmate:fm-$owner_id" \
    "worktree=$OTHER_WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=codex"

  out=$(run_claim_spawn "$new_id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when no task claims the resolved slot"
  assert_contains "$out" "spawned $new_id" "spawn did not report success for a free slot"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$new_id.meta" \
    "meta did not record the settled worktree for a free-slot spawn"
  pass "a claimant owning a different worktree does not false-refuse a free slot"
}

test_meta_claimed_slot_is_refused
test_distinct_slot_claim_does_not_false_refuse

echo "# all fm-spawn-worktree-claim-guard tests passed"
