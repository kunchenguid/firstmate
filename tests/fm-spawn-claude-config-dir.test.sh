#!/usr/bin/env bash
# Behavior tests for the claude crewmate CLAUDE_CONFIG_DIR launch knob (#599).
#
# On a multi-account machine the default ~/.claude can be empty/unauthenticated,
# so a bare-`claude` crewmate lands on the login wall and never starts. The local,
# gitignored config/crew-config-dir file names the config dir a claude crewmate
# should authenticate with; when set, fm-spawn prefixes the claude launch command
# with `CLAUDE_CONFIG_DIR=<dir> `. These tests drive a real claude ship spawn
# through fm-spawn.sh with a fake tmux that records the literal launch string, and
# pin both directions:
#   1. config/crew-config-dir set  -> the launch gains the CLAUDE_CONFIG_DIR prefix.
#   2. config/crew-config-dir absent -> NO prefix, i.e. byte-identical prior
#      behavior (bare `claude`, default config dir).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-ccd)

# A fake tmux that satisfies fm-spawn's tmux backend and records the literal
# launch string. The launch command is the only send-keys call that uses `-l`
# (fm_backend_tmux_send_literal); the `treehouse get` and GOTMPDIR sends use the
# text-line form (trailing Enter, no -l) and the final Enter uses send_key, so
# capturing the argument after `-l` isolates the launch string. The pane-path
# query returns FM_FAKE_PANE_PATH so worktree discovery resolves immediately.
make_spawn_fakebin() {
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
  new-window) printf '@1\n'; exit 0 ;;
  list-windows|has-session|new-session|set-window-option|kill-window) exit 0 ;;
  send-keys)
    prev=
    for a in "$@"; do
      [ "$prev" = "-l" ] && printf '%s' "$a" > "${FM_SEND_LOG:?}"
      prev=$a
    done
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

# Build one isolated case (home + project + worktree + fakebin), returning its
# fields. Each case gets a fresh id so state/data never collide across cases.
make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="ccd-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

# Drive a real claude ship spawn and echo the recorded launch string.
run_claude_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5 send_log=$6 out
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_SEND_LOG="$send_log" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" claude 2>&1) || { echo "SPAWN-FAILED: $out" >&2; return 1; }
  cat "$send_log"
}

test_config_dir_adds_prefix() {
  local rec case_dir home proj wt fakebin id send_log ccd launch
  rec=$(make_spawn_case with-knob)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  ccd="$case_dir/alt-claude-home"
  printf '%s\n' "$ccd" > "$home/config/crew-config-dir"
  send_log="$case_dir/launch.log"

  launch=$(run_claude_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$send_log") \
    || fail "claude spawn with config/crew-config-dir failed"

  # The prefix must sit between the ghost-text env var and the claude verb, with
  # the config dir shell-quoted (single quotes, no special chars in the path).
  case "$launch" in
    "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CONFIG_DIR='$ccd' claude --dangerously-skip-permissions "*) : ;;
    *) fail "launch missing CLAUDE_CONFIG_DIR prefix"$'\n'"--- launch ---"$'\n'"$launch" ;;
  esac
  pass "config/crew-config-dir prefixes the claude launch with CLAUDE_CONFIG_DIR"
}

test_absent_knob_is_backward_compatible() {
  local rec case_dir home proj wt fakebin id send_log launch
  rec=$(make_spawn_case no-knob)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  # No config/crew-config-dir file: the launch must be identical to prior behavior.
  send_log="$case_dir/launch.log"

  launch=$(run_claude_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$send_log") \
    || fail "claude spawn without config/crew-config-dir failed"

  assert_not_contains "$launch" "CLAUDE_CONFIG_DIR" "absent knob must not add a CLAUDE_CONFIG_DIR prefix"
  case "$launch" in
    "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions "*) : ;;
    *) fail "absent knob changed the bare-claude launch prefix"$'\n'"--- launch ---"$'\n'"$launch" ;;
  esac
  pass "absent config/crew-config-dir keeps the bare-claude launch byte-identical"
}

test_config_dir_adds_prefix
test_absent_knob_is_backward_compatible
