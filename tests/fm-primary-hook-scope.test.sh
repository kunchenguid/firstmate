#!/usr/bin/env bash
# Behavior regression for the task-worker boundary shared by every tracked
# primary hook family. A firstmate-repo task worktree inherits these tracked
# registrations, so FM_TASK_ID must make each one inert while an unmarked
# primary session keeps the same registration active.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-primary-hook-scope)
export NODE_NO_WARNINGS=1

test_shared_primary_scope_excludes_task_workers() {
  local repo state status
  repo="$TMP_ROOT/shared-primary"
  state="$repo/state"
  fm_git_init_commit "$repo"
  mkdir -p "$repo/bin" "$state"
  printf '# Firstmate scope fixture\n' > "$repo/AGENTS.md"

  FM_TASK_ID=task-probe bash -c '. "$1"; fm_primary_scope_matches "$2" "$3"' \
    _ "$ROOT/bin/fm-primary-scope-lib.sh" "$repo" "$state" >/dev/null 2>&1
  status=$?
  [ "$status" -eq 1 ] || fail "task-worker primary-scope probe exited $status, not 1"

  # shellcheck disable=SC2016 # single quotes intentional: $1/$2/$3 expand inside the bash -c script, not here
  env -u FM_TASK_ID bash -c '. "$1"; fm_primary_scope_matches "$2" "$3"' \
    _ "$ROOT/bin/fm-primary-scope-lib.sh" "$repo" "$state" >/dev/null 2>&1
  status=$?
  [ "$status" -eq 0 ] || fail "unmarked primary-scope probe exited $status, not 0"
  pass "shared primary scope is inert for task workers and active for the primary session"
}

install_command_hook_fixture() { # <root> <registration>
  local root=$1 registration=$2 script
  mkdir -p "$root/bin" "$root/$(dirname "$registration")"
  printf '# Firstmate hook fixture\n' > "$root/AGENTS.md"
  cp "$ROOT/$registration" "$root/$registration"
  for script in fm-sessionstart-run.sh fm-arm-pretool-check.sh fm-cd-pretool-check.sh \
    fm-subagent-pretool-check.sh fm-turnend-guard.sh fm-claude-stop-autoarm.sh \
    fm-sessionstart-cursor.sh fm-turnend-guard-cursor.sh fm-sessionstart-nudge.sh \
    fm-turnend-guard-grok.sh; do
    cat > "$root/bin/$script" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$0")" >> "${FM_HOOK_CALLS:?}"
cat >/dev/null 2>&1 || true
exit 0
SH
    chmod +x "$root/bin/$script"
  done
}

run_registered_commands() { # <root> <registration> <calls> [task-id]
  local root=$1 registration=$2 calls=$3 task_id=${4-} command
  while IFS= read -r command; do
    [ -n "$command" ] || continue
    if [ -n "$task_id" ]; then
      printf '{"source":"startup"}' | (
        cd "$root" && env -u GROK_AGENT -u GROK_HOOK_EVENT -u GROK_HOOK_NAME \
          FM_TASK_ID="$task_id" FM_HOOK_CALLS="$calls" CLAUDE_PROJECT_DIR="$root" \
          CURSOR_PROJECT_DIR="$root" GROK_WORKSPACE_ROOT="$root" bash -c "$command"
      )
    else
      printf '{"source":"startup"}' | (
        cd "$root" && env -u FM_TASK_ID -u GROK_AGENT -u GROK_HOOK_EVENT -u GROK_HOOK_NAME \
          FM_HOOK_CALLS="$calls" CLAUDE_PROJECT_DIR="$root" \
          CURSOR_PROJECT_DIR="$root" GROK_WORKSPACE_ROOT="$root" bash -c "$command"
      )
    fi
  done < <(jq -r '.. | objects | select(.type? == "command") | .command' "$root/$registration")
}

assert_command_registration_scope() { # <label> <registration>
  local label=$1 registration=$2 root calls expected actual
  root="$TMP_ROOT/commands/$label"
  calls="$root/calls"
  install_command_hook_fixture "$root" "$registration"
  expected=$(jq '[.. | objects | select(.type? == "command")] | length' "$root/$registration")

  run_registered_commands "$root" "$registration" "$calls"
  actual=$(wc -l < "$calls" | tr -d ' ')
  [ "$actual" -eq "$expected" ] \
    || fail "$label primary registration invoked $actual of $expected hook commands"

  rm -f "$calls"
  run_registered_commands "$root" "$registration" "$calls" task-probe
  [ ! -e "$calls" ] || fail "$label registration invoked a primary hook under FM_TASK_ID"
  pass "$label command hooks are active in primary sessions and inert in task workers"
}

test_command_hook_families_respect_task_scope() {
  local registration label
  while IFS='|' read -r label registration; do
    assert_command_registration_scope "$label" "$registration"
  done <<'EOF'
claude|.claude/settings.json
codex|.codex/hooks.json
cursor|.cursor/hooks.json
grok-cd|.grok/hooks/fm-primary-cd-check.json
grok-pretool|.grok/hooks/fm-primary-pretool-check.json
grok-sessionstart|.grok/hooks/fm-primary-sessionstart-nudge.json
grok-turnend|.grok/hooks/fm-primary-turnend-guard.json
EOF
}

test_opencode_plugin_scope() {
  local plugin export_name mode out status
  while IFS='|' read -r plugin export_name; do
    for mode in primary worker; do
      if [ "$mode" = worker ]; then
        out=$(FM_TASK_ID=task-probe MODE="$mode" PLUGIN="$ROOT/.opencode/plugins/$plugin" \
          EXPORT_NAME="$export_name" WORKTREE="$ROOT" node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";

const mod = await import(`${pathToFileURL(process.env.PLUGIN).href}?scope=${Date.now()}`);
const client = { session: { promptAsync: async () => {} } };
const hooks = await mod[process.env.EXPORT_NAME]({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
if (process.env.MODE === "primary" && (!hooks || Object.keys(hooks).length === 0)) {
  throw new Error("unmarked primary plugin registered no hooks");
}
if (process.env.MODE === "worker" && (!hooks || Object.keys(hooks).length !== 0)) {
  throw new Error(`task worker plugin returned hooks: ${Object.keys(hooks ?? {}).join(",")}`);
}
JS
        )
      else
        out=$(env -u FM_TASK_ID MODE="$mode" PLUGIN="$ROOT/.opencode/plugins/$plugin" \
          EXPORT_NAME="$export_name" WORKTREE="$ROOT" node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";

const mod = await import(`${pathToFileURL(process.env.PLUGIN).href}?scope=${Date.now()}`);
const client = { session: { promptAsync: async () => {} } };
const hooks = await mod[process.env.EXPORT_NAME]({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
if (!hooks || Object.keys(hooks).length === 0) {
  throw new Error("unmarked primary plugin registered no hooks");
}
JS
        )
      fi
      status=$?
      expect_code 0 "$status" "OpenCode $plugin $mode scope: $out"
      [ -z "$out" ] || fail "OpenCode $plugin $mode-scope test printed output: $out"
    done
  done <<'EOF'
fm-primary-cd-check.js|FmPrimaryCdCheck
fm-primary-pretool-check.js|FmPrimaryPretoolCheck
fm-primary-sessionstart-nudge.js|FmPrimarySessionstartNudge
fm-primary-turnend-guard.js|FmPrimaryTurnendGuard
fm-primary-watch-arm.js|FmPrimaryWatchArm
EOF
  pass "OpenCode primary plugins are active in primary sessions and inert in task workers"
}

install_extension_fixture() { # <fixture>
  local fixture=$1
  mkdir -p "$fixture/.pi" "$fixture/.omp" \
    "$fixture/node_modules/@earendil-works/pi-ai" \
    "$fixture/node_modules/@earendil-works/pi-coding-agent" \
    "$fixture/node_modules/@earendil-works/pi-tui" \
    "$fixture/node_modules/typebox"
  cp -R "$ROOT/.pi/extensions" "$fixture/.pi/extensions"
  cp -R "$ROOT/.omp/extensions" "$fixture/.omp/extensions"
  printf '{"type":"module"}\n' > "$fixture/package.json"
  printf '{"name":"@earendil-works/pi-ai","type":"module","exports":"./index.js"}\n' \
    > "$fixture/node_modules/@earendil-works/pi-ai/package.json"
  cat > "$fixture/node_modules/@earendil-works/pi-ai/index.js" <<'JS'
export const clampThinkingLevel = (_model, level) => level;
export const getSupportedThinkingLevels = () => ["low"];
JS
  printf '{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}\n' \
    > "$fixture/node_modules/@earendil-works/pi-coding-agent/package.json"
  cat > "$fixture/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
class Component {
  addChild() {}
  clear() {}
  render() { return []; }
  setBgFn() {}
}
export class AssistantMessageComponent { updateContent() {} }
export class UserMessageComponent { render() { return []; } }
export class InteractiveMode { addMessageToChat() {} }
export class DefaultResourceLoader extends Component {}
export class DynamicBorder extends Component {}
export class ModelRuntime extends Component {}
export class SessionManager extends Component {}
export class ToolExecutionComponent extends Component {}
export const createAgentSession = async () => ({});
const tool = (name) => () => ({
  name,
  parameters: {},
  execute: async () => ({ content: [] }),
  renderCall: () => new Component(),
  renderResult: () => new Component(),
});
export const createBashToolDefinition = tool("bash");
export const createEditToolDefinition = tool("edit");
export const createFindToolDefinition = tool("find");
export const createGrepToolDefinition = tool("grep");
export const createLsToolDefinition = tool("ls");
export const createReadToolDefinition = tool("read");
export const createWriteToolDefinition = tool("write");
export const getAgentDir = () => process.cwd();
export const keyHint = () => "key";
export const getMarkdownTheme = () => ({});
JS
  printf '{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}\n' \
    > "$fixture/node_modules/@earendil-works/pi-tui/package.json"
  cat > "$fixture/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
class Component {
  addChild() {}
  clear() {}
  render() { return []; }
  setBgFn() {}
}
export class Box extends Component {}
export class Container extends Component {}
export class Input extends Component {}
export class SelectList extends Component {}
export class Text extends Component {}
export const fuzzyFilter = (items) => items;
export const getKeybindings = () => ({ matches: () => false });
JS
  printf '{"name":"typebox","type":"module","exports":"./index.js"}\n' \
    > "$fixture/node_modules/typebox/package.json"
  cat > "$fixture/node_modules/typebox/index.js" <<'JS'
export const Type = new Proxy({}, { get: () => (..._args) => ({}) });
JS
}

assert_extension_scope() { # <fixture> <extension>
  local fixture=$1 extension=$2 mode out status
  for mode in primary worker; do
    if [ "$mode" = worker ]; then
      out=$(FM_TASK_ID=task-probe MODE="$mode" EXT="$fixture/$extension" \
        FM_HOME="$fixture/home-worker" node --input-type=module 2>&1 <<'JS'
import { mkdirSync } from "node:fs";
import { pathToFileURL } from "node:url";

mkdirSync(`${process.env.FM_HOME}/state`, { recursive: true });
const mod = await import(`${pathToFileURL(process.env.EXT).href}?scope=${Date.now()}`);
const calls = [];
const pi = {
  events: {
    emit() {},
    on(name) { calls.push(`events:${name}`); },
  },
  getAllTools() { return []; },
  on(name) { calls.push(`on:${name}`); },
  registerCommand(name) { calls.push(`command:${name}`); },
  registerEntryRenderer(name) { calls.push(`renderer:${name}`); },
  registerTool(tool) { calls.push(`tool:${tool?.name ?? "unknown"}`); },
  sendMessage() {},
  sendUserMessage() {},
};

await mod.default(pi);
if (process.env.MODE === "worker" && calls.length !== 0) {
  throw new Error(`task worker extension registered: ${calls.join(",")}`);
}
JS
      )
    else
      out=$(env -u FM_TASK_ID MODE="$mode" EXT="$fixture/$extension" \
        FM_HOME="$fixture/home-primary" node --input-type=module 2>&1 <<'JS'
import { mkdirSync } from "node:fs";
import { pathToFileURL } from "node:url";

mkdirSync(`${process.env.FM_HOME}/state`, { recursive: true });
const mod = await import(`${pathToFileURL(process.env.EXT).href}?scope=${Date.now()}`);
const calls = [];
const pi = {
  events: {
    emit() {},
    on(name) { calls.push(`events:${name}`); },
  },
  getAllTools() { return []; },
  on(name) { calls.push(`on:${name}`); },
  registerCommand(name) { calls.push(`command:${name}`); },
  registerEntryRenderer(name) { calls.push(`renderer:${name}`); },
  registerTool(tool) { calls.push(`tool:${tool?.name ?? "unknown"}`); },
  sendMessage() {},
  sendUserMessage() {},
};

await mod.default(pi);
if (calls.length === 0) throw new Error("unmarked primary extension registered nothing");
JS
      )
    fi
    status=$?
    expect_code 0 "$status" "$extension $mode scope: $out"
    [ -z "$out" ] || fail "$extension $mode-scope test printed output: $out"
  done
}

test_pi_and_omp_extension_scope() {
  local fixture extension
  fixture="$TMP_ROOT/extensions"
  install_extension_fixture "$fixture"
  for extension in \
    .pi/extensions/fm-branch-supervision.ts \
    .pi/extensions/fm-calm.ts \
    .pi/extensions/fm-primary-pi-watch.ts \
    .pi/extensions/fm-primary-turnend-guard.ts \
    .omp/extensions/fm-primary-omp-watch.ts \
    .omp/extensions/fm-primary-turnend-guard.ts; do
    assert_extension_scope "$fixture" "$extension"
  done
  pass "Pi and omp primary extensions are active in primary sessions and inert in task workers"
}

test_shared_primary_scope_excludes_task_workers
test_command_hook_families_respect_task_scope
test_opencode_plugin_scope
test_pi_and_omp_extension_scope
