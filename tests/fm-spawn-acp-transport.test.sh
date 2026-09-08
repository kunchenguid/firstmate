#!/usr/bin/env bash
# tests/fm-spawn-acp-transport.test.sh - end-to-end coverage for
# fm-spawn.sh's opt-in `--transport acp` path: bin/fm-acp-client.sh and its
# unit suite (tests/fm-acp-client.test.sh) prove the wire contract in
# isolation, and tests/fm-crew-state.test.sh / tests/fm-send-strict.test.sh
# prove status/send consume transport=acp meta correctly, but nothing else
# drives the actual `fm-spawn.sh ... --transport acp` flag through session
# creation, meta persistence, and worker launch construction. This suite
# closes that gap with the same fake-tmux convention as
# tests/fm-backend.test.sh, plus a fake acpx on PATH.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(fm_test_tmproot fm-spawn-acp-transport)
SPAWN_HOME="$TMP_ROOT/user-home"
mkdir -p "$SPAWN_HOME"

write_spawn_brief() {  # <file> <id>
  cat > "$1" <<EOF
# Task
## Captain's intent
Exercise the ACP transport for $2.

## Firstmate spec
Verify --transport acp end to end without changing task intent.
EOF
}

make_acp_spawn_fakebin() {  # <dir> <fake-worktree-path> -> echoes fakebin dir
  local dir=$1 wt=$2 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<SH
#!/usr/bin/env bash
set -u
{ printf 'tmux'; for a in "\$@"; do printf '\\x1f%s' "\$a"; done; printf '\\n'; } >> "\${FM_TMUX_LOG:?}"
case "\${1:-}" in
  display-message)
    for a in "\$@"; do case "\$a" in *pane_current_path*) printf '%s\\n' "$wt"; exit 0 ;; esac; done
    printf 'firstmate\\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  fm_fake_exit0 "$fb" treehouse
  cat > "$fb/acpx" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --version ]; then
  printf '%s\n' 0.13.2
  exit 0
fi
printf '%s\n' "$*" >> "${FM_ACPX_LOG:?}"
SH
  chmod +x "$fb/acpx"
  printf '%s\n' "$fb"
}

test_spawn_transport_acp_ensures_session_and_writes_meta() {
  local proj wt data id state config fb log acpx_log out
  proj="$TMP_ROOT/acp-project"; wt="$TMP_ROOT/acp-wt"; data="$TMP_ROOT/acp-data"
  id="spawnacpz1"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  fb=$(make_acp_spawn_fakebin "$TMP_ROOT/acp-fake" "$wt")
  mkdir -p "$data/$id"; write_spawn_brief "$data/$id/brief.md" "$id"
  state="$TMP_ROOT/acp-state"; config="$TMP_ROOT/acp-config"
  mkdir -p "$state" "$config"
  log="$TMP_ROOT/acp-tmux.log"; acpx_log="$TMP_ROOT/acp-acpx.log"; : > "$log"; : > "$acpx_log"

  out=$(PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_TMUX_LOG="$log" FM_ACPX_LOG="$acpx_log" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --transport acp 2>&1)
  expect_code 0 "$?" "--transport acp should spawn successfully"$'\n'"$out"

  assert_grep 'transport=acp' "$state/$id.meta" "spawn must persist transport=acp to meta"
  assert_grep "session_id=fm-acp-$id" "$state/$id.meta" \
    "spawn must persist a derived session_id when none was inherited"

  assert_grep 'sessions ensure --name fm-acp-'"$id" "$acpx_log" \
    "spawn must ensure the ACPX named session before launch"

  case "$(cat "$log")" in
    *"fm-acp-client.sh"*run*claude*"$wt"*"fm-acp-$id"*) : ;;
    *) fail "the launched pane command must invoke fm-acp-client.sh run for claude against the recorded worktree/session"$'\n'"--- tmux log ---"$'\n'"$(cat "$log")" ;;
  esac

  rm -rf "/tmp/fm-$id"
  pass "fm-spawn.sh: --transport acp ensures a named ACPX session and persists transport/session_id to meta"
}

test_spawn_transport_acp_rejects_secondmate() {
  local proj id state config out
  proj="$TMP_ROOT/acp-second-project"; mkdir -p "$proj"
  id="spawnacpz2"
  state="$TMP_ROOT/acp-second-state"; config="$TMP_ROOT/acp-second-config"
  mkdir -p "$state" "$config" "$proj"

  if out=$(FM_ROOT_OVERRIDE="$ROOT" HOME="$SPAWN_HOME" \
    FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" --secondmate --transport acp 2>&1); then
    fail "--transport acp with --secondmate should be refused"$'\n'"$out"
  fi
  assert_contains "$out" "supports crewmates only, not --secondmate" \
    "the refusal must name the secondmate restriction"
  pass "fm-spawn.sh: --transport acp refuses --secondmate spawns"
}

test_spawn_transport_acp_rejects_unsupported_harness() {
  local proj id state config out
  proj="$TMP_ROOT/acp-harness-project"; mkdir -p "$proj"
  id="spawnacpz3"
  state="$TMP_ROOT/acp-harness-state"; config="$TMP_ROOT/acp-harness-config"
  mkdir -p "$state" "$config" "$proj"

  if out=$(FM_ROOT_OVERRIDE="$ROOT" HOME="$SPAWN_HOME" \
    FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" gemini --mode no-mistakes --yolo off --transport acp 2>&1); then
    fail "--transport acp with an unsupported harness should be refused"$'\n'"$out"
  fi
  assert_contains "$out" "supports only --harness claude or --harness codex" \
    "the refusal must name the harness restriction"
  pass "fm-spawn.sh: --transport acp refuses harnesses other than claude/codex"
}

test_spawn_transport_acp_ensures_session_and_writes_meta
test_spawn_transport_acp_rejects_secondmate
test_spawn_transport_acp_rejects_unsupported_harness
