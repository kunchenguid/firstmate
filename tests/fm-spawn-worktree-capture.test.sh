#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh treehouse worktree capture.
#
# Regression coverage for the intermittent bad-worktree bug: the pane's cwd is
# polled after `treehouse get`, and treehouse's fresh subshell sources ~/.zshrc.
# An rc that momentarily cd's elsewhere (oh-my-zsh's update check runs
# `cd "$ZSH"` = ~/.oh-my-zsh) can be sampled by that poll. Such a cwd is a real
# git repo distinct from the project, so the old differs-from-primary check
# accepted it and recorded worktree=~/.oh-my-zsh, breaking teardown and defeating
# isolation. The fix requires a captured cwd to share the project repository's
# git common-dir; an unrelated repo is skipped and polling continues.
#
# These drive fm-spawn through meta writing with a fake tmux pane whose
# pane_current_path first returns an unrelated git repo (the transient capture),
# then the genuine project worktree. A real isolated worktree via fm_git_worktree
# gives the accept case; a separate `git init` repo gives the reject case.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-capture)

# Fake tmux: pane_current_path returns FM_FAKE_TRANSIENT_PATH for the first
# FM_FAKE_TRANSIENT_COUNT reads (an unrelated repo, simulating the ~/.oh-my-zsh
# capture), then FM_FAKE_PANE_PATH (the real worktree). A per-run counter file
# makes the sequence stateful across the capture loop's polls.
make_capture_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    n=0
    if [ -n "${FM_FAKE_PANE_COUNTER:-}" ]; then
      [ -f "$FM_FAKE_PANE_COUNTER" ] && n=$(cat "$FM_FAKE_PANE_COUNTER")
      printf '%s\n' "$((n + 1))" > "$FM_FAKE_PANE_COUNTER"
    fi
    if [ "$n" -lt "${FM_FAKE_TRANSIENT_COUNT:-0}" ]; then
      printf '%s\n' "${FM_FAKE_TRANSIENT_PATH:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_capture_case <name> <id> sets CASE_DIR/HOME_DIR/PROJ_DIR/WT_DIR/
# UNREL_DIR/FAKEBIN_DIR/COUNTER_FILE for one spawn. PROJ_DIR + WT_DIR are a real
# repo and its worktree (same common-dir); UNREL_DIR is a separate git repo
# standing in for the transient ~/.oh-my-zsh cwd (different common-dir).
make_capture_case() {
  local name=$1 id=$2
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  UNREL_DIR="$CASE_DIR/unrelated"
  COUNTER_FILE="$CASE_DIR/pane-counter"
  FAKEBIN_DIR=$(make_capture_fakebin "$CASE_DIR/fake")
  mkdir -p "$HOME_DIR/data/$id" "$HOME_DIR/state" "$HOME_DIR/config"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  touch "$HOME_DIR/state/.last-watcher-beat"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  fm_git_init_commit "$UNREL_DIR"
}

run_capture_spawn() {
  local transient_path=$1 transient_count=$2 id=$3
  : > "$COUNTER_FILE"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" GROK_HOME="$HOME_DIR/grok-home" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_COUNTER="$COUNTER_FILE" \
    FM_FAKE_TRANSIENT_PATH="$transient_path" FM_FAKE_TRANSIENT_COUNT="$transient_count" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" 2>&1
}

# The transient unrelated repo is sampled first, then the genuine worktree. The
# capture must skip the unrelated repo and record the worktree, not the first
# differs-from-primary cwd it sees.
test_transient_unrelated_cwd_is_skipped() {
  local id out status meta
  id=capture-transient-z1
  make_capture_case capture-transient "$id"

  out=$(run_capture_spawn "$UNREL_DIR" 1 "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed after skipping a transient unrelated cwd"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "worktree=$WT_DIR" "$meta" "capture recorded a worktree other than the real project worktree"
  assert_no_grep "worktree=$UNREL_DIR" "$meta" "capture wrongly recorded the transient unrelated repo as the worktree"
  pass "a transient unrelated git repo is skipped and the real project worktree is captured"
}

# A cwd that never leaves an unrelated repo is never accepted: the capture times
# out and refuses rather than launching against a foreign worktree. A short
# poll budget keeps the timeout path fast without changing the default.
test_persistent_unrelated_cwd_refuses() {
  local id out status
  id=capture-persistent-z2
  make_capture_case capture-persistent "$id"

  # FM_FAKE_TRANSIENT_COUNT larger than the poll budget => every poll returns the
  # unrelated repo. FM_SPAWN_WT_POLL_TRIES/SLEEP keep the timeout path quick.
  : > "$COUNTER_FILE"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" GROK_HOME="$HOME_DIR/grok-home" \
    FM_FAKE_PANE_PATH="$UNREL_DIR" FM_FAKE_PANE_COUNTER="$COUNTER_FILE" \
    FM_FAKE_TRANSIENT_PATH="$UNREL_DIR" FM_FAKE_TRANSIENT_COUNT=999 \
    FM_SPAWN_WT_POLL_TRIES=3 FM_SPAWN_WT_POLL_SLEEP=0 \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" 2>&1)
  status=$?
  expect_code 1 "$status" "spawn should refuse when only an unrelated repo is ever the pane cwd"
  assert_contains "$out" "did not enter a worktree" "refusal did not report the capture timeout"
  pass "a cwd that never becomes a project worktree is refused, not launched"
}

# The genuine worktree from the first poll (no transient) is accepted unchanged,
# guarding against a regression that would reject real treehouse worktrees.
test_genuine_worktree_captured() {
  local id out status meta
  id=capture-genuine-z3
  make_capture_case capture-genuine "$id"

  out=$(run_capture_spawn "$UNREL_DIR" 0 "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed on a genuine project worktree from the first poll"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "worktree=$WT_DIR" "$meta" "genuine project worktree was not captured on the first poll"
  pass "a genuine project worktree is accepted on the first poll"
}

test_transient_unrelated_cwd_is_skipped
test_persistent_unrelated_cwd_refuses
test_genuine_worktree_captured

echo "# all fm-spawn-worktree-capture tests passed"
