#!/usr/bin/env bash
set -u
ROOT="/Users/ian.brown/.no-mistakes/worktrees/dead8800c2e5/01M499QZ3YHTGMGYH8MYDM93H9"
. "$ROOT/tests/fixtures.sh"
TMPROOT=$(fm_test_tmproot managed-approvals-test)

pass_count=0
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; pass_count=$((pass_count+1)); }
assert_contains() { case "$1" in *"$2"*) : ;; *) fail "$3 (missing: '$2')"; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "$3 (unexpected: '$2')"; ;; *) : ;; esac; }

setup_home() {
  local home=$1 harness=$2
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
}

setup_brief() {
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" << EOF
# Task
## Captain's intent
test intent

## Firstmate spec
Test scenario.
EOF
}

setup_fakebin() {
  local fakebin
  fakebin=$(fm_fakebin "$1")
  fm_test_fake_tmux_spawn "$fakebin"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$home/.gitignore"
  git -C "$home" init -q -b main
}

run_spawn_ship() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  local spawn_home="$home/user-home"; mkdir -p "$spawn_home"
  CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PI_VERSION=0.84.0 \
  FM_FAKE_CURSOR_MODELS='' FM_FAKE_CURSOR_LIST_STATUS=0 GROK_HOME="$home/grok-home" \
  FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$spawn_home" \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
  FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
  PATH="$fakebin:$PATH" \
  "$ROOT/bin/fm-spawn.sh" "$@" --mode no-mistakes --yolo off 2>&1
}

run_spawn_plain() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  local spawn_home="$home/user-home"; mkdir -p "$spawn_home"
  CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PI_VERSION=0.84.0 \
  FM_FAKE_CURSOR_MODELS='' FM_FAKE_CURSOR_LIST_STATUS=0 GROK_HOME="$home/grok-home" \
  FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$spawn_home" \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
  FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
  PATH="$fakebin:$PATH" \
  "$ROOT/bin/fm-spawn.sh" "$@" 2>&1
}

# S1: Codex crewmate uses --approve-for-me
{
  tdir="$TMPROOT/s1"
  home="$tdir/home"; launchlog="$tdir/launch.log"
  fakebin=$(setup_fakebin "$tdir/fake")
  setup_home "$home" codex
  fm_git_worktree "$tdir/proj" "$tdir/wt" "wt-s1"
  setup_brief "$home" "codex-crew-t1"
  run_spawn_ship "$home" "$tdir/wt" "$fakebin" "$launchlog" "codex-crew-t1" "$tdir/proj" >/dev/null
  launch=$(cat "$launchlog")
  assert_contains "$launch" "--approve-for-me" "codex crewmate must use --approve-for-me"
  assert_not_contains "$launch" "--dangerously-bypass-approvals-and-sandbox" "codex crewmate must not use old bypass flag"
  assert_contains "$launch" "--disable hooks" "codex crewmate must still disable hooks"
  assert_contains "$launch" "notify=" "codex crewmate must keep turn-end notify"
  pass "codex crewmate uses --approve-for-me, disables hooks, and keeps turn-end"
}

# S2: Claude no config → --permission-mode auto
{
  tdir="$TMPROOT/s2"
  home="$tdir/home"; launchlog="$tdir/launch.log"
  fakebin=$(setup_fakebin "$tdir/fake")
  setup_home "$home" claude
  fm_git_worktree "$tdir/proj" "$tdir/wt" "wt-s2"
  setup_brief "$home" "claude-def-t2"
  run_spawn_ship "$home" "$tdir/wt" "$fakebin" "$launchlog" "claude-def-t2" "$tdir/proj" >/dev/null
  launch=$(cat "$launchlog")
  assert_contains "$launch" "--permission-mode auto" "claude default must use --permission-mode auto"
  assert_not_contains "$launch" "--dangerously-skip-permissions" "claude default must not use bypass"
  pass "claude defaults to --permission-mode auto when no config file present"
}

# S3: Claude explicit 'auto' = absent
{
  tdir="$TMPROOT/s3"
  home="$tdir/home"; launchlog="$tdir/launch.log"
  fakebin=$(setup_fakebin "$tdir/fake")
  setup_home "$home" claude
  printf 'auto\n' > "$home/config/claude-permission-mode"
  fm_git_worktree "$tdir/proj" "$tdir/wt" "wt-s3"
  setup_brief "$home" "claude-auto-t3"
  run_spawn_ship "$home" "$tdir/wt" "$fakebin" "$launchlog" "claude-auto-t3" "$tdir/proj" >/dev/null
  launch=$(cat "$launchlog")
  assert_contains "$launch" "--permission-mode auto" "claude explicit auto must use --permission-mode auto"
  assert_not_contains "$launch" "--dangerously-skip-permissions" "claude explicit auto must not use bypass"
  pass "claude explicit 'auto' config matches absent-file behavior"
}

# S4: Claude explicit 'bypass' → --dangerously-skip-permissions
{
  tdir="$TMPROOT/s4"
  home="$tdir/home"; launchlog="$tdir/launch.log"
  fakebin=$(setup_fakebin "$tdir/fake")
  setup_home "$home" claude
  printf 'bypass\n' > "$home/config/claude-permission-mode"
  fm_git_worktree "$tdir/proj" "$tdir/wt" "wt-s4"
  setup_brief "$home" "claude-bypass-t4"
  run_spawn_ship "$home" "$tdir/wt" "$fakebin" "$launchlog" "claude-bypass-t4" "$tdir/proj" >/dev/null
  launch=$(cat "$launchlog")
  assert_contains "$launch" "--dangerously-skip-permissions" "claude bypass must use --dangerously-skip-permissions"
  assert_not_contains "$launch" "--permission-mode auto" "claude bypass must not use auto mode"
  pass "claude explicit 'bypass' config opts into --dangerously-skip-permissions"
}

# S5: Codex secondmate uses --approve-for-me (keeps hooks)
{
  tdir="$TMPROOT/s5"
  home="$tdir/home"; launchlog="$tdir/launch.log"
  fakebin=$(setup_fakebin "$tdir/fake")
  setup_home "$home" codex
  sm="$tdir/secondmate-home"
  make_seeded_secondmate_home "$sm" "codex-2mate-t5"
  fm_git_worktree "$tdir/proj" "$tdir/wt" "wt-s5"
  setup_brief "$home" "codex-2mate-t5"
  run_spawn_plain "$home" "$tdir/wt" "$fakebin" "$launchlog" "codex-2mate-t5" "$sm" --secondmate >/dev/null
  launch=$(cat "$launchlog")
  assert_contains "$launch" "--approve-for-me" "codex secondmate must use --approve-for-me"
  assert_not_contains "$launch" "--dangerously-bypass-approvals-and-sandbox" "codex secondmate must not use old bypass"
  assert_not_contains "$launch" "--disable hooks" "codex secondmate must keep hooks enabled"
  pass "codex secondmate uses --approve-for-me while keeping hooks on"
}

echo ""
echo "All $pass_count scenarios passed."
