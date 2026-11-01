#!/usr/bin/env bash
# Behavior regression for the Claude task-worker launch and per-task skill delivery.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-claude-lean)

make_case() {
  local name=$1 id=$2
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake" claude)
  LAUNCH_LOG="$CASE_DIR/launch.log"
  fm_test_spawn_home "$HOME_DIR" claude
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  : > "$LAUNCH_LOG"
}

spawn() {
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

make_case ship lean-ship-s1
out=$(spawn lean-ship-s1 "$PROJ_DIR" --mode direct-PR --yolo off)
expect_code 0 "$?" "Claude ship should launch: $out"
launch=$(cat "$LAUNCH_LOG")
assert_contains "$launch" "--setting-sources '' --strict-mcp-config --disable-slash-commands" "worker must exclude settings and discovery"
assert_contains "$launch" "--tools Read,Bash,Edit,Write " "ship tool boundary"
assert_not_contains "$launch" "ToolSearch" "a worker without an MCP opt-in needs no tool search"
assert_contains "$launch" "--model 'opus' --effort 'medium'" "ship defaults must be explicit"
assert_contains "$launch" "--settings '$HOME_DIR/state/lean-ship-s1.claude-settings.json'" "Firstmate hooks must still load"
assert_contains "$launch" "--append-system-prompt \"\$(cat '$ROOT/.pi/fm-worker-contract.md'" "worker contract must be appended"
pass "Claude ship excludes discovered settings, tools and skills but retains Firstmate hooks and contract"

make_case scout lean-scout-s2
mkdir -p "$CASE_DIR/skills/skill with spaces"
printf '%s\n' '# Scout skill' > "$CASE_DIR/skills/skill with spaces/SKILL.md"
out=$(spawn lean-scout-s2 "$PROJ_DIR" --scout --model opus --effort high --skill "$CASE_DIR/skills/skill with spaces")
expect_code 0 "$?" "Claude scout with a skill should launch: $out"
launch=$(cat "$LAUNCH_LOG")
assert_contains "$launch" "--tools Read,Bash " "scout should be read-only"
assert_not_contains "$launch" "--tools Read,Bash,Edit" "scout must not get write tools"
assert_contains "$launch" "--model 'opus' --effort 'high'" "requested model and effort"
assert_contains "$launch" "cat '$CASE_DIR/skills/skill with spaces/SKILL.md'" "explicit skill directory must be read"
assert_not_contains "$launch" "--skill " "Claude does not support a --skill flag"
cat > "$FAKEBIN_DIR/claude" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = --append-system-prompt ]; then
    printf '%s\n' "$2" > "$FM_FAKE_CLAUDE_PROMPT"
    break
  fi
  shift
done
SH
chmod +x "$FAKEBIN_DIR/claude"
FM_FAKE_CLAUDE_PROMPT="$CASE_DIR/delivered-prompt" PATH="$FAKEBIN_DIR:$PATH" bash -c "$launch" >/dev/null \
  || fail "Claude scout launch did not execute with a synthetic skill"
assert_contains "$(cat "$CASE_DIR/delivered-prompt")" "# Scout skill" "skill content did not reach appended system prompt"
assert_contains "$(cat "$CASE_DIR/delivered-prompt")" "# Requested skill ($CASE_DIR/skills/skill with spaces/SKILL.md)" "skill location did not reach appended system prompt"
assert_contains "$(cat "$CASE_DIR/delivered-prompt")" "Stay within assigned task" "worker contract did not reach appended system prompt"
assert_not_contains "$(cat "$CASE_DIR/delivered-prompt")" "call ToolSearch again" "a worker without an MCP opt-in needs no MCP retry note"
FAKE_PROMPT_CLAUDE=$(cat "$FAKEBIN_DIR/claude")
pass "Claude scout gets only read tools, explicit model/effort and requested skill content"

for model in opus sonnet haiku; do
  make_case "model-$model" "lean-model-$model"
  out=$(spawn "lean-model-$model" "$PROJ_DIR" --scout --model "$model" --effort low)
  expect_code 0 "$?" "Claude $model scout should launch: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--setting-sources '' --strict-mcp-config --disable-slash-commands --tools Read,Bash" "$model must use the lean worker flags"
  assert_contains "$launch" "--model '$model' --effort 'low'" "$model profile must be explicit"
done
make_case model-custom lean-model-custom
out=$(spawn lean-model-custom "$PROJ_DIR" --scout --model claude-future-model --effort high)
expect_code 0 "$?" "configured Claude model should use the same launch: $out"
assert_contains "$(cat "$LAUNCH_LOG")" "--model 'claude-future-model' --effort 'high'" "arbitrary configured model must pass through"
pass "opus, sonnet, haiku and configured Claude models share one lean launch shape"

make_case opt-in lean-opt-in-s5
mkdir -p "$CASE_DIR/extra dir" "$CASE_DIR/plugin dir"
printf '%s\n' '{"mcpServers":{"task-tool":{"command":"true"}}}' > "$CASE_DIR/mcp config.json"
out=$(spawn lean-opt-in-s5 "$PROJ_DIR" --scout --mcp-config "$CASE_DIR/mcp config.json" --claude-add-dir "$CASE_DIR/extra dir" --claude-plugin-dir "$CASE_DIR/plugin dir")
expect_code 0 "$?" "Claude explicit capabilities should launch: $out"
launch=$(cat "$LAUNCH_LOG")
assert_contains "$launch" "--strict-mcp-config" "explicit MCP configuration must not enable discovered servers"
assert_contains "$launch" "--mcp-config '$CASE_DIR/mcp config.json'" "named MCP configuration"
assert_contains "$launch" "--tools Read,Bash,ToolSearch " "an MCP opt-in must let the first turn wait for a connecting server"
printf '%s\n' "$FAKE_PROMPT_CLAUDE" > "$CASE_DIR/prompt-claude"; chmod +x "$CASE_DIR/prompt-claude"
mkdir -p "$CASE_DIR/prompt-bin"; mv "$CASE_DIR/prompt-claude" "$CASE_DIR/prompt-bin/claude"
FM_FAKE_CLAUDE_PROMPT="$CASE_DIR/delivered-prompt" PATH="$CASE_DIR/prompt-bin:$FAKEBIN_DIR:$PATH" bash -c "$launch" >/dev/null \
  || fail "Claude MCP opt-in launch did not execute"
assert_contains "$(cat "$CASE_DIR/delivered-prompt")" "If ToolSearch reports that a server is still connecting, call ToolSearch again" "MCP opt-in must tell the worker to keep waiting for a connecting server"
assert_contains "$(cat "$CASE_DIR/delivered-prompt")" "Stay within assigned task" "worker contract must still follow the MCP note"
assert_contains "$launch" "--add-dir '$CASE_DIR/extra dir'" "explicit extra directory"
assert_contains "$launch" "--plugin-dir '$CASE_DIR/plugin dir'" "explicit plugin directory"
assert_not_contains "$launch" '--mcp-config default' "ambient MCP servers must not load"
pass "Claude task opts into named MCPs and explicit directories without enabling discovery"

make_case opt-in-ship lean-opt-in-ship
printf '%s\n' '{"mcpServers":{"task-tool":{"command":"true"}}}' > "$CASE_DIR/mcp.json"
out=$(spawn lean-opt-in-ship "$PROJ_DIR" --mode direct-PR --yolo off --mcp-config "$CASE_DIR/mcp.json")
expect_code 0 "$?" "Claude ship with an MCP opt-in should launch: $out"
assert_contains "$(cat "$LAUNCH_LOG")" "--tools Read,Bash,Edit,Write,ToolSearch " "ship MCP opt-in must allow ToolSearch"
pass "Claude MCP opt-in lets the first turn wait for a connecting server"

make_case opt-in-batch lean-batch-a
mkdir -p "$CASE_DIR/extra dir" "$CASE_DIR/plugin dir"
printf '%s\n' '{"mcpServers":{"task-tool":{"command":"true"}}}' > "$CASE_DIR/mcp config.json"
fm_test_spawn_brief "$HOME_DIR" lean-batch-b
out=$(spawn "lean-batch-a=$PROJ_DIR" "lean-batch-b=$PROJ_DIR" --scout --mcp-config "$CASE_DIR/mcp config.json" --claude-add-dir "$CASE_DIR/extra dir" --claude-plugin-dir "$CASE_DIR/plugin dir")
expect_code 0 "$?" "Claude batch should forward explicit capabilities: $out"
launch=$(cat "$LAUNCH_LOG")
assert_contains "$launch" "--mcp-config '$CASE_DIR/mcp config.json'" "batch must forward MCP configuration"
assert_contains "$launch" "--tools Read,Bash,ToolSearch " "batch MCP opt-in must allow ToolSearch"
assert_contains "$launch" "--add-dir '$CASE_DIR/extra dir'" "batch must forward extra directories"
assert_contains "$launch" "--plugin-dir '$CASE_DIR/plugin dir'" "batch must forward plugins"
pass "Claude batch dispatch retains per-task opt-ins"

make_case auto lean-auto-s3
printf 'auto\n' > "$HOME_DIR/config/claude-permission-mode"
out=$(spawn lean-auto-s3 "$PROJ_DIR" --mode direct-PR --yolo off)
expect_code 0 "$?" "Claude auto worker should launch: $out"
launch=$(cat "$LAUNCH_LOG")
assert_contains "$launch" "--permission-mode auto" "auto permission mode must survive lean launch"
assert_contains "$launch" "--tools Read,Bash,Edit,Write" "auto mode still limits available tools"
pass "Claude auto posture restricts tools"

make_case invalid lean-invalid-s4
out=$(spawn lean-invalid-s3 "$PROJ_DIR" --mode direct-PR --yolo off --skill "$CASE_DIR/missing.md" 2>&1)
expect_code 1 "$?" "missing skill must refuse"
assert_contains "$out" "does not exist" "missing skill refusal"
assert_absent "$HOME_DIR/state/lean-invalid-s3.meta" "invalid skill must not provision"
[ ! -s "$LAUNCH_LOG" ] || fail "invalid skill still launched"
pass "invalid Claude skill refuses before provisioning"

for flag in mcp-config claude-add-dir claude-plugin-dir; do
  make_case "invalid-$flag" "lean-bad-$flag"
  out=$(spawn "lean-bad-$flag" "$PROJ_DIR" --scout --"$flag" "$CASE_DIR/missing" 2>&1)
  expect_code 1 "$?" "missing --$flag must refuse"
  assert_contains "$out" "--$flag" "missing --$flag must name the flag"
  assert_absent "$HOME_DIR/state/lean-bad-$flag.meta" "invalid $flag must not provision"
  [ ! -s "$LAUNCH_LOG" ] || fail "invalid $flag still launched"
done
make_case unsupported lean-unsupported-s6
out=$(spawn lean-unsupported-s6 "$PROJ_DIR" --scout --harness codex --mcp-config "$CASE_DIR/missing" 2>&1)
expect_code 1 "$?" "non-Claude worker must refuse Claude capabilities"
assert_contains "$out" "only to Claude ship and scout workers" "non-Claude capabilities must refuse"
pass "invalid and unsupported Claude opt-ins refuse before provisioning"

make_case guards lean-guards-s7
commit_project_claude() {
  git -C "$PROJ_DIR" add .claude
  git -C "$PROJ_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "$1"
  git -C "$PROJ_DIR" push -q origin main
}
mkdir -p "$HOME_DIR/user-home/.claude" "$PROJ_DIR/.claude"
printf '%s\n' '{"enabledPlugins":{"x@y":true},"hooks":{"PreToolUse":[{"matcher":"Read","hooks":[{"type":"command","command":"user-guard"}]}],"SessionStart":[{"hooks":[{"type":"command","command":"user-banner"}]}]},"permissions":{"deny":["Read(./.env)"]}}' \
  > "$HOME_DIR/user-home/.claude/settings.json"
printf '%s\n' '{"hooks":{"PostToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"project-guard"}]}],"Stop":[{"hooks":[{"type":"command","command":"project-stop"}]}]},"permissions":{"deny":["Bash(rm:*)"]}}' \
  > "$PROJ_DIR/.claude/settings.json"
commit_project_claude guards
out=$(spawn lean-guards-s7 "$PROJ_DIR" --scout)
expect_code 0 "$?" "Claude worker with user and project guards should launch: $out"
settings="$HOME_DIR/state/lean-guards-s7.claude-settings.json"
[ "$(jq -c '[.hooks.PreToolUse[].hooks[].command | select(. == "user-guard")]' "$settings")" = '["user-guard"]' ] \
  || fail "user PreToolUse guard was not carried: $(cat "$settings")"
[ "$(jq -c '[.hooks.PostToolUse[].hooks[].command | select(. == "project-guard")]' "$settings")" = '["project-guard"]' ] \
  || fail "project PostToolUse guard was not carried: $(cat "$settings")"
[ "$(jq -c '.permissions.deny' "$settings")" = '["Read(./.env)","Bash(rm:*)"]' ] \
  || fail "deny rules were not carried: $(cat "$settings")"
[ "$(jq -c '[.hooks.SessionStart, .enabledPlugins, (.hooks.Stop // [] | map(.hooks[].command) | index("project-stop"))]' "$settings")" = '[null,null,null]' ] \
  || fail "non-guard settings leaked into the lean worker: $(cat "$settings")"
[ "$(jq -r '.feedbackDrafts' "$settings")" = off ] || fail "Firstmate policy keys were lost: $(cat "$settings")"
pass "Claude worker keeps user and project tool guards and deny rules without other settings"

make_case bad-guards lean-bad-guards-s8
mkdir -p "$PROJ_DIR/.claude"
printf '%s\n' '{not json' > "$PROJ_DIR/.claude/settings.json"
commit_project_claude bad-guards
out=$(spawn lean-bad-guards-s8 "$PROJ_DIR" --scout 2>&1)
expect_code 1 "$?" "malformed guard layer must refuse"
assert_contains "$out" "could not carry Claude guard hooks" "malformed guard layer refusal"
[ ! -s "$LAUNCH_LOG" ] || fail "malformed guard layer still launched"
pass "malformed Claude settings layer refuses rather than dropping guards"

# The status line is the only model/effort display a lean worker has, because
# it runs without a status bar. A secondmate keeps its full primary session and
# so must not receive it.
make_case statusline lean-status-s9
out=$(spawn lean-status-s9 "$PROJ_DIR" --mode direct-PR --yolo off)
expect_code 0 "$?" "Claude ship should launch for the status line check: $out"
settings="$HOME_DIR/state/lean-status-s9.claude-settings.json"
[ "$(jq -r '.statusLine.type' "$settings")" = command ] || fail "task worker settings lack a command statusLine: $(cat "$settings")"
status_cmd=$(jq -r '.statusLine.command' "$settings")
[ -n "$status_cmd" ] && [ "$status_cmd" != null ] || fail "task worker statusLine has no command: $(cat "$settings")"
assert_not_contains "$status_cmd" "cost" "status line must stay model and effort only"
status_line() { printf '%s' "$1" | bash -c "$status_cmd"; }
[ "$(status_line '{"model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"effort":{"level":"high"},"cost":{"total_cost_usd":1}}')" = "Opus 5.5 · high" ] \
  || fail "status line did not print model and effort"
[ "$(status_line '{"model":{"display_name":"Haiku 5.5"},"effort":{"level":null}}')" = "Haiku 5.5" ] \
  || fail "status line must drop the effort part when the level is null"
[ "$(status_line '{"model":{"display_name":"Haiku 5.5"}}')" = "Haiku 5.5" ] \
  || fail "status line must drop the effort part when effort is absent"
pass "lean task worker settings carry a model and effort statusLine that prints only those"

SM_CASE="$TMP_ROOT/statusline-sm"
SM_HOME_DIR="$SM_CASE/home"
SM_ID=lean-status-sm
SM_WT="$SM_CASE/secondmate"
SM_FAKEBIN=$(fm_test_make_spawn_fakebin "$SM_CASE/fake" claude)
fm_test_spawn_home "$SM_HOME_DIR" claude
mkdir -p "$SM_WT/bin" "$SM_WT/data" "$SM_HOME_DIR/data/$SM_ID"
printf '# Firstmate\n' > "$SM_WT/AGENTS.md"
printf '%s\n' "$SM_ID" > "$SM_WT/.fm-secondmate-home"
printf 'charter\n' > "$SM_WT/data/charter.md"
printf 'charter brief\n' > "$SM_HOME_DIR/data/$SM_ID/brief.md"
mkdir -p "$SM_HOME_DIR/user-home"
out=$(env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$SM_HOME_DIR" HOME="$SM_HOME_DIR/user-home" CLAUDE_CONFIG_DIR='' \
  FM_STATE_OVERRIDE="$SM_HOME_DIR/state" FM_DATA_OVERRIDE="$SM_HOME_DIR/data" \
  FM_PROJECTS_OVERRIDE="$SM_HOME_DIR/projects" FM_CONFIG_OVERRIDE="$SM_HOME_DIR/config" \
  FM_SPAWN_NO_GUARD=1 FM_FAKE_LAUNCH_LOG="$SM_CASE/launch.log" FM_FAKE_PANE_PATH="$SM_WT" TMUX="fake,1,0" \
  PATH="$SM_FAKEBIN:$PATH" "$ROOT/bin/fm-spawn.sh" "$SM_ID" "$SM_WT" --secondmate 2>&1)
sm_settings="$SM_HOME_DIR/state/$SM_ID.claude-settings.json"
[ -f "$sm_settings" ] || fail "secondmate wrote no settings file: $out"
[ "$(jq -r 'has("statusLine")' "$sm_settings")" = false ] || fail "secondmate must keep its own status line: $(cat "$sm_settings")"
pass "Claude secondmate settings carry no statusLine"

echo "all fm-spawn-claude-lean tests passed"
