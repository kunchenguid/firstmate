#!/usr/bin/env bash
# The claude launch template must carry the minimal tool surface, and the
# brief's tools: line must be the only thing that widens it.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-tool-surface)

write_brief() {  # <home> <id> <tools-line>
  local home=$1 id=$2
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Do the thing.

## Firstmate spec
Scout: knowledge deliverable only.
$3
EOF
}

# run_tool_surface_spawn <id> <tools-line>: drives a real non-secondmate claude
# ship spawn end to end (fake tmux, real git worktree) and captures both the
# literal launch command `tmux send-keys -l` receives and the MCP config file
# fm-spawn.sh actually writes for the task, so assertions observe behavior
# rather than fm-spawn.sh's own source text.
run_tool_surface_spawn() {
  local id=$1 tools=$2 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$id"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" "wt-$id"
  write_brief "$home" "$id" "$tools"
  : > "$launchlog"
  SPAWN_OUT=$(CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off)
  SPAWN_STATUS=$?
  LAUNCH=$(cat "$launchlog")
  MCP_CONFIG_FILE="/tmp/fm-$id/mcp.json"
}

test_no_tools_line_pins_strict_minimal_mcp_surface() {
  local id=toolsurface-none-z1
  run_tool_surface_spawn "$id" ""
  expect_code 0 "$SPAWN_STATUS" "claude spawn with no tools: line should succeed"$'\n'"$SPAWN_OUT"

  assert_contains "$LAUNCH" "--strict-mcp-config --mcp-config '$MCP_CONFIG_FILE'" \
    "launch does not pin the per-task MCP config in strict mode"
  assert_contains "$LAUNCH" "--setting-sources project,local" \
    "launch does not pin its setting sources"
  [ -f "$MCP_CONFIG_FILE" ] || fail "fm-spawn did not write the per-task MCP config"
  assert_contains "$(cat "$MCP_CONFIG_FILE")" '{"mcpServers":{}}' \
    "no tools: line should leave the MCP config empty"
  pass "no tools: line launches with a strict, empty MCP surface"
}

test_context7_extra_widens_the_written_mcp_config() {
  local id=toolsurface-context7-z1
  run_tool_surface_spawn "$id" "tools: context7"
  expect_code 0 "$SPAWN_STATUS" "claude spawn with tools: context7 should succeed"$'\n'"$SPAWN_OUT"

  [ -f "$MCP_CONFIG_FILE" ] || fail "fm-spawn did not write the per-task MCP config"
  assert_contains "$(cat "$MCP_CONFIG_FILE")" '"context7":{"command":"npx"' \
    "tools: context7 should add the context7 MCP server to the written config"
  assert_contains "$SPAWN_OUT" "tool surface: minimal + context7" \
    "spawn did not report the widened tool surface"
  pass "tools: context7 widens the written MCP config"
}

write_brief_direct() {  # <file> <tools-line>
  cat > "$1" <<EOF
# Task
## Captain's intent
Do the thing.

## Firstmate spec
Scout: knowledge deliverable only.
$2
EOF
}

FM_BRIEF_TMP="$TMP_ROOT/brief-parsing"
mkdir -p "$FM_BRIEF_TMP"

write_brief_direct "$FM_BRIEF_TMP/none.md" ""
GOT=$(fm_brief_tools "$FM_BRIEF_TMP/none.md")
if [ -z "$GOT" ]; then
  echo "ok - no tools line means no extras"
else
  echo "not ok - expected empty, got '$GOT'"; exit 1
fi

write_brief_direct "$FM_BRIEF_TMP/browser.md" "tools: browser context7"
GOT=$(fm_brief_tools "$FM_BRIEF_TMP/browser.md")
if [ "$GOT" = "browser context7" ]; then
  echo "ok - extras parsed"
else
  echo "not ok - expected 'browser context7', got '$GOT'"; exit 1
fi

write_brief_direct "$FM_BRIEF_TMP/bogus.md" "tools: browser nonsense"
GOT=$(fm_brief_tools "$FM_BRIEF_TMP/bogus.md" 2>/dev/null)
case "$GOT" in
  *nonsense*) echo "not ok - an unrecognized extra was accepted"; exit 1 ;;
  *) echo "ok - an unrecognized extra is dropped" ;;
esac

test_no_tools_line_pins_strict_minimal_mcp_surface
test_context7_extra_widens_the_written_mcp_config

echo "# all fm-spawn-tool-surface tests passed"
