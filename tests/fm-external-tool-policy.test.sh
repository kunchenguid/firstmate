#!/usr/bin/env bash
# Behavior tests for ship brief external-tool authorization and harness wiring.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-external-tool-pretool-check.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-external-tool-policy)
POLICY_BRIEF="$TMP_ROOT/policy-brief.md"
fm_write_ship_brief "$POLICY_BRIEF" "external-tool policy fixture"

run_policy_form() {  # <form> <command> <out-file> <err-file>
  local form=$1 command=$2 out_file=$3 err_file=$4 payload
  case "$form" in
    claude)
      payload=$(jq -cn --arg command "$command" '{tool_name:"Bash",tool_input:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" --brief "$POLICY_BRIEF" --format claude >"$out_file" 2>"$err_file"
      ;;
    codex)
      payload=$(jq -cn --arg command "$command" '{tool_name:"Bash",tool_input:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" --brief "$POLICY_BRIEF" --format plain >"$out_file" 2>"$err_file"
      ;;
    grok)
      payload=$(jq -cn --arg command "$command" '{toolName:"run_terminal_command",toolInput:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" --brief "$POLICY_BRIEF" --format grok >"$out_file" 2>"$err_file"
      ;;
    opencode|pi)
      "$CHECK" --brief "$POLICY_BRIEF" --tool bash --input-json "$(jq -cn --arg command "$command" '{command:$command}')" >"$out_file" 2>"$err_file"
      ;;
    *) fail "unknown external-tool policy transport form: $form" ;;
  esac
}

assert_command_matrix() {  # <id> <allow|deny> <command>
  local id=$1 expected=$2 command=$3 form out_file err_file rc
  for form in claude codex grok opencode pi; do
    out_file="$TMP_ROOT/$id-$form.out"
    err_file="$TMP_ROOT/$id-$form.err"
    run_policy_form "$form" "$command" "$out_file" "$err_file"
    rc=$?
    if [ "$expected" = allow ]; then
      expect_code 0 "$rc" "$id via $form should be allowed"
      [ ! -s "$out_file" ] || fail "$id via $form allowed call wrote stdout: $(cat "$out_file")"
      [ ! -s "$err_file" ] || fail "$id via $form allowed call wrote stderr: $(cat "$err_file")"
    else
      expect_code 2 "$rc" "$id via $form should be denied"
      assert_grep '[external-tool-denied]' "$err_file" "$id via $form lacked the stable denial code"
      assert_grep 'firstmate.external-tools.v1' "$err_file" "$id via $form did not name the applicable policy"
      assert_grep 'chrome-devtools-axi' "$err_file" "$id via $form did not name the authorized primary alternative"
      assert_grep 'agent_browser' "$err_file" "$id via $form did not name the authorized native fallback"
      if [ "$form" = grok ]; then
        jq -e '.decision == "deny"' "$out_file" >/dev/null || fail "$id Grok denial lacked decision=deny"
      elif [ "$form" = claude ]; then
        [ ! -s "$out_file" ] || fail "$id Claude denial must keep stdout empty"
        jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$err_file" >/dev/null \
          || fail "$id Claude denial lacked the native hook response"
      fi
    fi
  done
  pass "external-tool policy matrix $id: $expected"
}

test_command_policy_matrix() {
  assert_command_matrix incident deny 'npx playwright install chromium'
  assert_command_matrix npm-exec deny 'npm exec -- playwright install chromium'
  assert_command_matrix pnpm-dlx deny 'pnpm dlx playwright install chromium'
  assert_command_matrix yarn-dlx deny 'yarn dlx @playwright/test install chromium'
  assert_command_matrix npx-call deny "npx -c 'playwright install chromium'"
  assert_command_matrix runner-shell deny "npm exec -- bash -lc 'playwright install chromium'"
  assert_command_matrix direct-bin deny './node_modules/.bin/playwright install chromium'
  assert_command_matrix nested-shell deny "bash -lc 'npx playwright install chromium'"
  assert_command_matrix pipeline deny 'npx playwright install chromium | tee install.log'
  assert_command_matrix redirection deny 'npx playwright install chromium >install.log 2>&1'
  assert_command_matrix package-install deny 'npm install --save-dev @playwright/test'
  assert_command_matrix python-module deny 'python -m playwright install chromium'
  assert_command_matrix python-code deny "python -c 'from playwright.sync_api import sync_playwright'"
  assert_command_matrix node-cli deny 'node node_modules/playwright/cli.js install chromium'
  assert_command_matrix node-eval deny "node -e 'require(\"puppeteer\").launch()'"
  assert_command_matrix browser-shell deny 'agent-browser open http://localhost:3000'
  assert_command_matrix browser-package deny 'apt-get install chromium'
  assert_command_matrix allowed-primary allow 'chrome-devtools-axi open http://localhost:3000'
  assert_command_matrix allowed-test allow 'npm test'
  assert_command_matrix allowed-lint allow 'pnpm lint'
  assert_command_matrix allowed-build allow 'npm run build'
  assert_command_matrix allowed-server allow 'npm run dev -- --host 127.0.0.1'
  assert_command_matrix allowed-package allow 'npm install typescript'
  assert_command_matrix data-mention allow "printf '%s\\n' 'npx playwright install chromium'"
}

test_github_tool_authorization() {
  local out rc
  "$CHECK" --brief "$POLICY_BRIEF" --command 'gh-axi repo view owner/name' \
    || fail "authorized gh-axi command was denied"
  out=$("$CHECK" --brief "$POLICY_BRIEF" --command 'gh repo view owner/name' 2>&1); rc=$?
  expect_code 2 "$rc" "unlisted gh client must be denied"
  assert_contains "$out" "requested github shell tool 'gh'" "GitHub denial did not name the requested client"
  assert_contains "$out" "authorized alternatives: shell: gh-axi" "GitHub denial did not name gh-axi"
  pass "GitHub external clients follow the brief shell authorization"
}

test_native_agent_browser_authorization() {
  local out rc restricted="$TMP_ROOT/restricted.md"
  "$CHECK" --brief "$POLICY_BRIEF" --tool agent_browser --input-json '{}' \
    || fail "authorized native agent_browser fallback was denied"
  cat > "$restricted" <<'EOF'
```firstmate-external-tools
{"schema":"firstmate.external-tools.v1","shell":{"allow":["gh-axi","chrome-devtools-axi"]},"native":{"allow":[]}}
```
EOF
  out=$("$CHECK" --brief "$restricted" --tool agent_browser --input-json '{}' 2>&1); rc=$?
  expect_code 2 "$rc" "native agent_browser must be denied when absent from the brief policy"
  assert_contains "$out" "requested browser native tool 'agent_browser'" \
    "native fallback denial did not name the requested tool and channel"
  pass "native agent_browser follows the brief's native authorization"
}

test_generated_briefs_own_policy() {
  local home="$TMP_ROOT/brief-home" brief scout_brief
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" generated-policy sample >/dev/null
  brief="$home/data/generated-policy/brief.md"
  "$CHECK" --brief "$brief" --validate || fail "generated ship brief policy did not validate"
  assert_grep '```firstmate-external-tools' "$brief" "generated ship brief lacks the machine-readable policy fence"
  assert_grep 'Never drive browser automation through a shell command' "$brief" \
    "generated ship brief lost the human-readable browser boundary"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" generated-scout-policy sample --scout >/dev/null
  scout_brief="$home/data/generated-scout-policy/brief.md"
  "$CHECK" --brief "$scout_brief" --validate || fail "generated scout brief policy did not validate"
  assert_grep 'Never drive browser automation through a shell command' "$scout_brief" \
    "generated scout brief lost the human-readable browser boundary"
  pass "generated ship and promotable scout briefs share one readable machine policy"
}

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:?}"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse pi-signed kimi cursor-agent
  printf '%s\n' "$fakebin"
}

make_spawn_case() {  # <name> <harness>
  local name=$1 harness=$2 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/spawn-$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  id="policy-$name"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$case_dir/grok"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_write_ship_brief "$home/data/$id/brief.md" "spawn adapter fixture $harness"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/tmux.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

run_spawn_case() {  # <record> [spawn extras...]
  local record=$1 case_dir home proj wt fakebin id
  shift
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$record
EOF
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_PANE_PATH="$wt" FM_FAKE_TMUX_LOG="$case_dir/tmux.log" \
    TMUX='fake,1,0' GROK_HOME="$case_dir/grok" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" "$@" 2>&1
}

read_spawn_record() {
  # shellcheck disable=SC2034 # The shared record shape exposes fields used by selected adapter cases.
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR SPAWN_ID <<EOF
$1
EOF
}

hook_denies_incident() {  # <command>
  local command=$1 payload out rc
  payload=$(jq -cn --arg command 'npx playwright install chromium' '{tool_name:"Bash",tool_input:{command:$command}}')
  out=$(printf '%s' "$payload" | sh -c "$command" 2>&1); rc=$?
  expect_code 2 "$rc" "spawn-installed hook must deny the reproduced incident"
  assert_contains "$out" "requested browser shell tool 'playwright'" \
    "spawn-installed hook denial did not name Playwright"
}

run_pi_policy_extension() {  # <extension> <tool> <input-json>
  EXT_PATH=$1 TOOL_NAME=$2 TOOL_INPUT=$3 node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
const handlers = {};
mod.default({ on: (name, fn) => { handlers[name] = fn; } });
const result = await handlers.tool_call({
  type: "tool_call",
  toolName: process.env.TOOL_NAME,
  input: JSON.parse(process.env.TOOL_INPUT),
});
process.stdout.write(JSON.stringify(result));
EOF
}

test_spawn_installs_each_verified_harness_adapter() {
  local rec out rc settings hook plugin ext result token payload

  rec=$(make_spawn_case claude claude); read_spawn_record "$rec"
  out=$(run_spawn_case "$rec"); rc=$?
  expect_code 0 "$rc" "Claude policy spawn should succeed: $out"
  settings="$WT_DIR/.claude/settings.local.json"
  hook=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$settings")
  hook_denies_incident "$hook"

  rec=$(make_spawn_case codex codex); read_spawn_record "$rec"
  out=$(run_spawn_case "$rec"); rc=$?
  expect_code 0 "$rc" "Codex policy spawn should succeed: $out"
  assert_contains "$(cat "$CASE_DIR/tmux.log")" '--dangerously-bypass-hook-trust' \
    "Codex ship did not activate its pre-launch project hook without a trust gap"
  hook=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$WT_DIR/.codex/hooks.json")
  hook_denies_incident "$hook"

  rec=$(make_spawn_case opencode opencode); read_spawn_record "$rec"
  out=$(run_spawn_case "$rec"); rc=$?
  expect_code 0 "$rc" "OpenCode policy spawn should succeed: $out"
  plugin="$WT_DIR/.opencode/plugins/fm-external-tool-policy.js"
  PLUGIN_PATH="$plugin" node --input-type=module 2>&1 <<'EOF' >/dev/null || rc=$?
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.PLUGIN_PATH).href);
const hooks = await mod.FmExternalToolPolicy({});
let denied = false;
try {
  await hooks["tool.execute.before"]({ tool: "bash" }, { args: { command: "npx playwright install chromium" } });
} catch (error) {
  denied = String(error.message).includes("playwright");
}
if (!denied) process.exit(1);
EOF
  expect_code 0 "${rc:-0}" "OpenCode generated plugin did not throw before the denied tool call"
  unset rc

  for harness in pi pi-signed; do
    rec=$(make_spawn_case "$harness" "$harness"); read_spawn_record "$rec"
    out=$(run_spawn_case "$rec"); rc=$?
    expect_code 0 "$rc" "$harness policy spawn should succeed: $out"
    ext="$HOME_DIR/state/$SPAWN_ID.pi-ext.ts"
    result=$(run_pi_policy_extension "$ext" bash '{"command":"npx playwright install chromium"}') \
      || fail "$harness generated extension could not execute: $result"
    assert_contains "$result" '"block":true' "$harness generated extension did not block the incident"
    result=$(run_pi_policy_extension "$ext" agent_browser '{}') \
      || fail "$harness generated extension rejected the authorized native fallback: $result"
    [ "$result" = '{}' ] || fail "$harness native fallback should be allowed, got: $result"
  done

  rec=$(make_spawn_case grok grok); read_spawn_record "$rec"
  out=$(run_spawn_case "$rec"); rc=$?
  expect_code 0 "$rc" "Grok policy spawn should succeed: $out"
  token=$(cat "$HOME_DIR/state/$SPAWN_ID.grok-tool-policy-token")
  payload=$(jq -cn --arg command 'npx playwright install chromium' '{toolName:"run_terminal_command",toolInput:{command:$command}}')
  out=$(printf '%s' "$payload" | env FM_EXTERNAL_TOOL_POLICY_TOKEN="$token" \
    GROK_WORKSPACE_ROOT="$WT_DIR" bash "$CASE_DIR/grok/hooks/fm-external-tool-policy.sh" 2>"$CASE_DIR/grok.err"); rc=$?
  expect_code 2 "$rc" "Grok global hook must deny the incident"
  jq -e '.decision == "deny" and (.reason | contains("playwright"))' <<<"$out" >/dev/null \
    || fail "Grok global hook did not return its native deny object: $out"

  pass "spawn installs working external-tool policy adapters for every interceptable harness"
}

test_spawn_refuses_uninterceptable_harnesses_before_endpoint_creation() {
  local rec out rc
  rec=$(make_spawn_case kimi kimi); read_spawn_record "$rec"
  out=$(run_spawn_case "$rec"); rc=$?
  [ "$rc" -ne 0 ] || fail "Kimi ship spawn must refuse without reliable pre-tool interception"
  assert_contains "$out" "no reliable pre-tool interception is verified" "Kimi refusal did not name the missing guarantee"
  [ ! -s "$CASE_DIR/tmux.log" ] || fail "Kimi refusal created or touched a runtime endpoint"

  rec=$(make_spawn_case cursor pi); read_spawn_record "$rec"
  out=$(run_spawn_case "$rec" "cursor-agent --force"); rc=$?
  [ "$rc" -ne 0 ] || fail "raw Cursor ship spawn must refuse as an unverified adapter"
  assert_contains "$out" "no verified external-tool policy adapter" "Cursor refusal did not name the missing policy adapter"
  [ ! -s "$CASE_DIR/tmux.log" ] || fail "Cursor refusal created or touched a runtime endpoint"
  pass "Kimi and Cursor ship paths refuse before endpoint creation when interception is unverified"
}

test_scout_promotion_requires_live_policy_enforcement() {
  local rec out rc
  rec=$(make_spawn_case protected-scout pi); read_spawn_record "$rec"
  out=$(run_spawn_case "$rec" --scout); rc=$?
  expect_code 0 "$rc" "protected scout spawn should succeed: $out"
  assert_grep 'external_tool_policy=enforced' "$HOME_DIR/state/$SPAWN_ID.meta" \
    "protected scout spawn did not record its enforcement receipt"
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" "$ROOT/bin/fm-promote.sh" "$SPAWN_ID" 2>&1); rc=$?
  expect_code 0 "$rc" "protected scout promotion should succeed: $out"
  assert_grep 'kind=ship' "$HOME_DIR/state/$SPAWN_ID.meta" "protected scout did not become a ship"

  rec=$(make_spawn_case unprotected-scout pi); read_spawn_record "$rec"
  printf 'adapter-verification scout without a declared tool policy\n' > "$HOME_DIR/data/$SPAWN_ID/brief.md"
  out=$(run_spawn_case "$rec" "custom-agent --flag" --scout); rc=$?
  expect_code 0 "$rc" "unprotected raw scout should remain available for adapter verification: $out"
  assert_no_grep 'external_tool_policy=enforced' "$HOME_DIR/state/$SPAWN_ID.meta" \
    "raw scout falsely recorded policy enforcement"
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" "$ROOT/bin/fm-promote.sh" "$SPAWN_ID" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "unprotected raw scout was promoted into a ship"
  assert_contains "$out" "cannot be promoted into an unprotected ship" \
    "unprotected promotion refusal did not name the safety consequence"
  assert_grep 'kind=scout' "$HOME_DIR/state/$SPAWN_ID.meta" "refused promotion changed the scout kind"
  pass "only scouts with live external-tool enforcement can be promoted in place"
}

test_spawn_refuses_missing_policy_before_endpoint_creation() {
  local rec out rc
  rec=$(make_spawn_case missing-policy pi); read_spawn_record "$rec"
  printf 'legacy brief without machine policy\n' > "$HOME_DIR/data/$SPAWN_ID/brief.md"
  out=$(run_spawn_case "$rec"); rc=$?
  [ "$rc" -ne 0 ] || fail "ship spawn accepted a brief without machine-readable authorization"
  assert_contains "$out" "no valid machine-readable external-tool policy" \
    "missing-policy refusal did not identify the invalid brief"
  [ ! -s "$CASE_DIR/tmux.log" ] || fail "missing-policy refusal created or touched a runtime endpoint"
  pass "spawn validates the brief policy before creating the worker endpoint"
}

test_command_policy_matrix
test_github_tool_authorization
test_native_agent_browser_authorization
test_generated_briefs_own_policy
test_spawn_installs_each_verified_harness_adapter
test_spawn_refuses_uninterceptable_harnesses_before_endpoint_creation
test_scout_promotion_requires_live_policy_enforcement
test_spawn_refuses_missing_policy_before_endpoint_creation

echo "all fm-external-tool-policy tests passed"
