#!/usr/bin/env bash
# Regression coverage for fm-spawn.sh's inline credential-config assignments.
# A backend creates a fresh shell or terminal, so the assignment must travel in
# the final launch command rather than relying on the spawning shell's exports.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-spawn-config-inherit)
SPAWN="$ROOT/bin/fm-spawn.sh"

make_fakebin() {  # <dir> -> fakebin
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TMUX_RECORD:?}"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:?}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
  new-window) printf '@spawn-window\n' ;;
  list-windows|has-session|new-session|send-keys|set-window-option) : ;;
esac
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_repo() {  # <path> -> git repository path
  local repo=$1
  mkdir -p "$repo"
  git -C "$repo" init -q
  printf 'fixture\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm fixture
  printf '%s\n' "$repo"
}

make_secondmate_home() {  # <home> <id>
  local home=$1 id=$2
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/bin"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf '# firstmate fixture\n' > "$home/AGENTS.md"
  printf 'secondmate brief\n' > "$home/data/charter.md"
}

run_spawn() {  # <home> <id> <project-or-home> <harness> [--secondmate]
  local home=$1 id=$2 target=$3 harness=$4 kind=${5:-}
  if [ "$kind" != --secondmate ]; then
    mkdir -p "$home/data/$id"
    printf 'crew brief\n' > "$home/data/$id/brief.md"
  fi
  PI_CODING_AGENT_DIR="$PI_DIR" CLAUDE_CONFIG_DIR="$CLAUDE_DIR" \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_PANE_PATH="$WORKTREE" FM_TMUX_RECORD="$RECORD" TMUX='fake,1,0' \
    PATH="$FAKEBIN:$PATH" \
    "$SPAWN" "$id" "$target" "$harness" --backend tmux ${kind:+"$kind"} >/dev/null
}

test_credential_config_reaches_crew_and_secondmate() {
  local home secondmate project
  home="$TMP_ROOT/home"
  secondmate="$TMP_ROOT/secondmate"
  project=$(make_repo "$TMP_ROOT/project")
  WORKTREE="$TMP_ROOT/worktree"
  git -C "$project" worktree add -q --detach "$WORKTREE" >/dev/null 2>&1
  PI_DIR="$TMP_ROOT/captain/pi-agent"
  CLAUDE_DIR="$TMP_ROOT/captain/claude"
  mkdir -p "$PI_DIR" "$CLAUDE_DIR" "$home/data"
  PI_DIR=$(cd "$PI_DIR" && pwd -P)
  CLAUDE_DIR=$(cd "$CLAUDE_DIR" && pwd -P)
  make_secondmate_home "$secondmate" pi-secondmate
  make_secondmate_home "$TMP_ROOT/secondmate-claude" claude-secondmate
  RECORD="$TMP_ROOT/tmux.log"
  : > "$RECORD"
  FAKEBIN=$(make_fakebin "$TMP_ROOT/fake")

  run_spawn "$home" pi-crew "$project" pi
  run_spawn "$home" claude-crew "$project" claude
  run_spawn "$home" pi-secondmate "$secondmate" pi --secondmate
  run_spawn "$home" claude-secondmate "$TMP_ROOT/secondmate-claude" claude --secondmate

  assert_grep "PI_CODING_AGENT_DIR='$PI_DIR'" "$RECORD" \
    "Pi crew and secondmate launches must carry the primary Pi config directory"
  assert_grep "CLAUDE_CONFIG_DIR='$CLAUDE_DIR'" "$RECORD" \
    "Claude crew and secondmate launches must carry the primary Claude config directory"
  assert_not_contains "$(cat "$RECORD")" 'PI_CODING_AGENT_DIR='"$PI_DIR"' codex' \
    "unrelated harnesses must not receive Pi config assignments"
  pass "fm-spawn: Pi and Claude config directories reach crew and secondmate launch shells"
}

test_credential_config_reaches_crew_and_secondmate

echo "# all fm-spawn-config-inherit tests passed"
