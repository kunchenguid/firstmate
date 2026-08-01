#!/usr/bin/env bash
# Regression test for fm-spawn.sh same-identity reclaim worktree reuse
# (bin/fm-spawn.sh, reusable_own_worktree + the treehouse-get/reuse branch).
#
# A fresh `treehouse get` chooses a pool slot by live-owner availability. After a
# crash or reboot that leaves stale owner PIDs, that slot can be one another task
# still claims (which the ownership guard then refuses), and it abandons the
# reclaiming task's own worktree and any unlanded work on it. So a same-identity
# reclaim - a spawn whose state/<id>.meta already records a still-valid isolated
# worktree that no other task claims - must resume that recorded worktree in
# place (via `cd`, without resetting it) instead of acquiring a fresh slot.
#
# This drives the real fm-spawn.sh with a fake tmux that models the two possible
# pane moves: `treehouse get` settles the pane into the pool slot the test
# designates, while `cd -- <path>` settles it into <path>. It asserts:
#   1. a reclaim whose recorded worktree is intact reuses it and records it,
#      succeeding even though a fresh get would have landed on a slot another
#      task claims;
#   2. the same collision WITHOUT a reusable meta is refused (counterfactual, so
#      case 1's success is attributable to reuse, not luck);
#   3. a fresh spawn with no prior meta still performs a normal `treehouse get`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-reuse)

# make_reuse_fakebin builds a fake tmux that tracks pane cwd in FM_FAKE_CWD_FILE:
# `treehouse get` moves the pane to FM_FAKE_TREEHOUSE_SLOT, `treehouse enter <name>`
# (the reclaim reuse command) moves it to FM_FAKE_REUSE_PATH, and the
# pane_current_path query returns the tracked cwd.
make_reuse_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
STATE=${FM_FAKE_CWD_FILE:?FM_FAKE_CWD_FILE unset}
case "$*" in
  *"#{pane_current_path}"*)
    if [ -f "$STATE" ]; then cat "$STATE"; else printf '%s\n' "${FM_FAKE_PROJECT_PATH:-}"; fi
    exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    text=""
    prev=""
    for a in "$@"; do
      [ "$a" = "Enter" ] && [ -n "$prev" ] && text="$prev"
      prev="$a"
    done
    case "$text" in
      "treehouse get") printf '%s\n' "${FM_FAKE_TREEHOUSE_SLOT:-}" > "$STATE" ;;
      "treehouse enter "*) printf '%s\n' "${FM_FAKE_REUSE_PATH:-}" > "$STATE" ;;
    esac
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_reuse_case builds a home, a project with three real worktrees (the task's
# own recorded slot, a slot another task claims, and a genuinely free slot), and
# the command-aware fake.
make_reuse_case() {
  local name=$1 case_dir home proj own collide free fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  own="$case_dir/own-wt"
  collide="$case_dir/collide-wt"
  free="$case_dir/free-wt"
  fakebin=$(make_reuse_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$own" "wt-own-$name"
  git -C "$proj" worktree add --quiet -b "wt-collide-$name" "$collide"
  git -C "$proj" worktree add --quiet -b "wt-free-$name" "$free"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$own|$collide|$free|$fakebin"
}

read_reuse_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR OWN_WT COLLIDE_WT FREE_WT FAKEBIN_DIR <<EOF
$1
EOF
}

seed_brief() {
  local id=$1
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
}

run_reuse_spawn() {
  local id=$1 slot=$2
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PROJECT_PATH="$PROJ_DIR" FM_FAKE_TREEHOUSE_SLOT="$slot" \
    FM_FAKE_REUSE_PATH="$OWN_WT" \
    FM_FAKE_CWD_FILE="$HOME_DIR/state/.fake-cwd-$id" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A reclaim whose recorded worktree is intact and unclaimed by others resumes it
# in place, even though a fresh treehouse get would have landed on a slot another
# task still claims.
test_reclaim_reuses_own_worktree() {
  local rec id out status
  id=reuse-reclaim-c1
  rec=$(make_reuse_case reuse-reclaim)
  read_reuse_record "$rec"
  seed_brief "$id"
  # The task already recorded its own worktree from a prior spawn.
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$OWN_WT" \
    "project=$PROJ_DIR" \
    "harness=codex"
  # Another still-owned task claims the slot a fresh get would hand out.
  fm_write_meta "$HOME_DIR/state/reuse-other-c2.meta" \
    "window=firstmate:fm-reuse-other-c2" \
    "worktree=$COLLIDE_WT" \
    "project=$PROJ_DIR" \
    "harness=codex"

  out=$(run_reuse_spawn "$id" "$COLLIDE_WT")
  status=$?
  expect_code 0 "$status" "reclaim should reuse its own worktree and succeed"
  assert_contains "$out" "spawned $id" "reclaim spawn did not report success"
  assert_grep "worktree=$OWN_WT" "$HOME_DIR/state/$id.meta" \
    "reclaim did not record its own reused worktree"
  assert_no_grep "worktree=$COLLIDE_WT" "$HOME_DIR/state/$id.meta" \
    "reclaim landed on the colliding slot instead of reusing its own worktree"
  pass "a same-identity reclaim resumes its own recorded worktree, avoiding a foreign-claimed slot"
}

# Counterfactual: the identical collision WITHOUT a reusable meta is refused, so
# the reclaim's success above is due to reuse, not to the slot being acceptable.
test_same_collision_without_meta_is_refused() {
  local rec id out status
  id=reuse-fresh-collide-c3
  rec=$(make_reuse_case reuse-fresh-collide)
  read_reuse_record "$rec"
  seed_brief "$id"
  fm_write_meta "$HOME_DIR/state/reuse-other-c4.meta" \
    "window=firstmate:fm-reuse-other-c4" \
    "worktree=$COLLIDE_WT" \
    "project=$PROJ_DIR" \
    "harness=codex"

  out=$(run_reuse_spawn "$id" "$COLLIDE_WT")
  status=$?
  expect_code 1 "$status" "a fresh spawn onto a foreign-claimed slot should be refused"
  assert_contains "$out" "still claims it" "refusal did not explain the ownership collision"
  pass "the same collision without a reusable meta is refused, isolating reuse as the cause"
}

# A fresh spawn with no prior meta performs a normal treehouse get onto its slot.
test_fresh_spawn_uses_treehouse_get() {
  local rec id out status
  id=reuse-fresh-free-c5
  rec=$(make_reuse_case reuse-fresh-free)
  read_reuse_record "$rec"
  seed_brief "$id"

  out=$(run_reuse_spawn "$id" "$FREE_WT")
  status=$?
  expect_code 0 "$status" "a fresh spawn onto a free slot should succeed"
  assert_contains "$out" "spawned $id" "fresh spawn did not report success"
  assert_grep "worktree=$FREE_WT" "$HOME_DIR/state/$id.meta" \
    "fresh spawn did not record the treehouse-acquired slot"
  pass "a fresh spawn with no prior meta performs a normal treehouse get"
}

test_reclaim_reuses_own_worktree
test_same_collision_without_meta_is_refused
test_fresh_spawn_uses_treehouse_get

echo "# all fm-spawn-worktree-reuse tests passed"
