#!/usr/bin/env bash
# Focused rendering, lifecycle, persistence, and interactive TUI checks for /calm.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-calm-pi-extension)
EXT="$ROOT/.pi/extensions/fm-calm.ts"
SHORTCUT_EXT="$ROOT/.pi/extensions/fm-captains-call-shortcut.ts"
ASSISTANT_LAYOUT="$ROOT/.pi/extensions/lib/fm-calm-assistant-layout.ts"
OPERATIONAL_USER_LAYOUT="$ROOT/.pi/extensions/lib/fm-calm-operational-user-layout.ts"
COMPATIBILITY="$ROOT/.pi/extensions/lib/fm-calm-compatibility.ts"
VISIBILITY="$ROOT/.pi/extensions/lib/fm-calm-visibility.ts"
WATCH_EXT="$ROOT/.pi/extensions/fm-primary-pi-watch.ts"
OPERATIONAL_INPUT="$ROOT/bin/fm-operational-input.sh"
PI_OPERATIONAL_INPUT="$ROOT/.pi/extensions/lib/fm-operational-input.ts"
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
TMUX_SOCKET="fm-calm-$$"
TMUX_SESSION="fm-calm-e2e"
PI_COMPAT_VERSIONS="0.81.1 0.82.0 0.82.1"

require_pi_compat_version() {
  local version=$1 context=$2
  case " $PI_COMPAT_VERSIONS " in
    *" $version "*) return 0 ;;
    *) fail "$context requires Pi $PI_COMPAT_VERSIONS, found $version" ;;
  esac
}

cleanup() {
  if command -v tmux >/dev/null 2>&1; then
    tmux -L "$TMUX_SOCKET" kill-server 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup EXIT

wait_for_text() {
  local file=$1 text=$2 i=0
  while [ "$i" -lt 120 ]; do
    tmux -L "$TMUX_SOCKET" capture-pane -p -t "$TMUX_SESSION" -S - >"$file" 2>/dev/null || true
    grep -Fq "$text" "$file" 2>/dev/null && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

find_chrome() {
  local candidate
  if [ -n "${FM_CHROME_BIN:-}" ] && [ -x "$FM_CHROME_BIN" ]; then
    printf '%s\n' "$FM_CHROME_BIN"
    return 0
  fi
  for candidate in \
    google-chrome \
    google-chrome-stable \
    chromium \
    chromium-browser \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  do
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done
  return 1
}

test_captains_call_shortcut_input_contract() {
  local fixture out status version
  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    echo "skip: node or npm not found for Pi Captain's Call shortcut test"
    return 0
  fi
  if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
    echo "skip: installed @earendil-works/pi-coding-agent package not found"
    return 0
  fi
  version=$(node -p "require('$PI_PACKAGE_DIR/package.json').version")
  require_pi_compat_version "$version" "Pi Captain's Call shortcut input contract"

  fixture="$TMP_ROOT/captains-call-shortcut"
  mkdir -p \
    "$fixture/project/.pi/extensions" \
    "$fixture/project/.agents/skills/bearings" \
    "$fixture/project/node_modules/@earendil-works"
  cp "$SHORTCUT_EXT" "$fixture/project/.pi/extensions/fm-captains-call-shortcut.ts"
  printf '%s\n' '{"type":"module"}' >"$fixture/project/package.json"
  printf '%s\n' '---' 'name: bearings' 'description: fixture' '---' '# Bearings fixture' \
    >"$fixture/project/.agents/skills/bearings/SKILL.md"
  ln -s "$PI_PACKAGE_DIR" "$fixture/project/node_modules/@earendil-works/pi-coding-agent"

  out=$(cd "$fixture/project" && \
    EXT="$fixture/project/.pi/extensions/fm-captains-call-shortcut.ts" \
    SKILL="$fixture/project/.agents/skills/bearings/SKILL.md" \
    node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";

const extension = await import(`${pathToFileURL(process.env.EXT).href}?test=${Date.now()}`);
let inputHandler;
let commands;
let inventoryReads = 0;
const notifications = [];
const validCommand = {
  name: "skill:bearings",
  source: "skill",
  sourceInfo: {
    path: process.env.SKILL,
    source: "local",
    scope: "project",
    origin: "top-level",
    baseDir: process.env.SKILL.replace(/\/SKILL\.md$/, ""),
  },
};
const pi = {
  getCommands() {
    inventoryReads += 1;
    return commands;
  },
  on(name, handler) {
    if (name === "input") inputHandler = handler;
  },
};
extension.default(pi);
if (!inputHandler) throw new Error("shortcut extension did not register an input handler");
const ctx = {
  ui: {
    notify(message, level) {
      notifications.push({ message, level });
    },
  },
};
const invoke = (text, source = "interactive", images, streamingBehavior) =>
  inputHandler({ type: "input", text, source, images, streamingBehavior }, ctx);

commands = [validCommand];
for (const [text, streamingBehavior] of [
  ["s", undefined],
  ["S", undefined],
  [" \t s \n", "steer"],
  ["\nS\t", "followUp"],
]) {
  const result = await invoke(text, "interactive", undefined, streamingBehavior);
  if (result?.action !== "transform" || result.text !== "/skill:bearings captains-call-only") {
    throw new Error(`exact interactive shortcut did not transform: ${JSON.stringify({ text, result })}`);
  }
}
const readsAfterExact = inventoryReads;
for (const event of [
  ["", "interactive", undefined],
  ["ss", "interactive", undefined],
  ["status", "interactive", undefined],
  ["s now", "interactive", undefined],
  ["/s", "interactive", undefined],
  ["ordinary s text", "interactive", undefined],
  ["s", "rpc", undefined],
  ["S", "extension", undefined],
  ["s", "interactive", [{ type: "image", data: "fixture", mimeType: "image/png" }]],
]) {
  const result = await invoke(...event);
  if (result?.action !== "continue") {
    throw new Error(`non-exact or non-interactive input changed: ${JSON.stringify({ event, result })}`);
  }
}
if (inventoryReads !== readsAfterExact) {
  throw new Error("non-qualifying input consulted the command inventory");
}

for (const invalidCommands of [
  [],
  [{ ...validCommand, name: "bearings" }],
  [{ ...validCommand, source: "prompt" }],
  [{ ...validCommand, sourceInfo: { ...validCommand.sourceInfo, scope: "user" } }],
  [{ ...validCommand, sourceInfo: { ...validCommand.sourceInfo, path: `${process.env.SKILL}.wrong` } }],
]) {
  commands = invalidCommands;
  const before = notifications.length;
  const result = await invoke("s");
  if (result?.action !== "handled" || notifications.length !== before + 1) {
    throw new Error(`missing or invalid Bearings provenance was not rejected once: ${JSON.stringify({ invalidCommands, result, notifications })}`);
  }
  const notice = notifications.at(-1);
  if (notice.level !== "error" || !notice.message.includes("Bearings")) {
    throw new Error(`missing or invalid Bearings provenance lacked one actionable error: ${JSON.stringify(notice)}`);
  }
}
JS
)
  status=$?
  [ "$status" -eq 0 ] || fail "Pi Captain's Call shortcut input contract failed: $out"
  [ -z "$out" ] || fail "Pi Captain's Call shortcut input contract printed output: $out"
  pass "Pi Captain's Call shortcut transforms only exact image-free interactive s/S input and verifies project skill provenance"
}

test_captains_call_shortcut_real_pi_expansion() {
  local project config home prompt commands_file out status version mode heading_count pane i
  if ! command -v pi >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
    echo "skip: pi or node not found for real Pi Captain's Call shortcut expansion test"
    return 0
  fi
  version=$(pi --version 2>/dev/null || true)
  require_pi_compat_version "$version" "real Pi Captain's Call shortcut expansion"

  project="$TMP_ROOT/captains-call-real-pi/project"
  config="$TMP_ROOT/captains-call-real-pi/config"
  home="$TMP_ROOT/captains-call-real-pi/home"
  prompt="$TMP_ROOT/captains-call-real-pi/expanded-prompt.txt"
  commands_file="$TMP_ROOT/captains-call-real-pi/commands.json"
  mkdir -p \
    "$project/.pi/extensions" \
    "$project/.agents/skills/bearings" \
    "$project/node_modules/@earendil-works" \
    "$config" "$home/data" "$home/state" "$home/config" "$home/projects"
  fm_git_init_commit "$project"
  cp "$SHORTCUT_EXT" "$project/.pi/extensions/fm-captains-call-shortcut.ts"
  cp "$ROOT/.agents/skills/bearings/SKILL.md" "$project/.agents/skills/bearings/SKILL.md"
  ln -s "$PI_PACKAGE_DIR" "$project/node_modules/@earendil-works/pi-coding-agent"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' >"$home/data/backlog.md"
  cat >"$project/probe-provider.ts" <<'TS'
import { writeFileSync } from "node:fs";
import {
  type AssistantMessage,
  createAssistantMessageEventStream,
} from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI): void {
  pi.on("input", () => {
    writeFileSync(process.env.PROBE_COMMANDS!, JSON.stringify(pi.getCommands(), null, 2), "utf8");
    return { action: "continue" };
  });
  pi.on("before_agent_start", (event) => {
    writeFileSync(process.env.PROBE_PROMPT!, event.prompt, "utf8");
  });
  pi.registerProvider("captains-call-probe", {
    baseUrl: "http://127.0.0.1/unused",
    apiKey: "test-only",
    api: "captains-call-probe-api",
    models: [{
      id: "deterministic",
      name: "Captain's Call shortcut probe",
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 4096,
      maxTokens: 128,
    }],
    streamSimple(model) {
      const stream = createAssistantMessageEventStream();
      const text = process.env.PROBE_MODE === "actionable"
        ? "## Captain's Call\n\n- Choose the release route."
        : "## Captain's Call\n\nNothing needs your action right now.";
      const output: AssistantMessage = {
        role: "assistant",
        content: [],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: {
          input: 0,
          output: 0,
          cacheRead: 0,
          cacheWrite: 0,
          totalTokens: 0,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
        },
        stopReason: "stop",
        timestamp: Date.now(),
      };
      queueMicrotask(() => {
        stream.push({ type: "start", partial: output });
        const block = { type: "text" as const, text: "" };
        output.content.push(block);
        stream.push({ type: "text_start", contentIndex: 0, partial: output });
        block.text = text;
        stream.push({ type: "text_delta", contentIndex: 0, delta: text, partial: output });
        stream.push({ type: "text_end", contentIndex: 0, content: text, partial: output });
        stream.push({ type: "done", reason: "stop", message: output });
        stream.end();
      });
      return stream;
    },
  });
}
TS

  for mode in empty actionable; do
    out=$(cd "$project" && \
      env FM_HOME="$home" PI_CODING_AGENT_DIR="$config" PI_OFFLINE=1 \
        PROBE_PROMPT="$prompt" PROBE_COMMANDS="$commands_file" PROBE_MODE="$mode" \
        pi --approve --no-session --no-context-files --no-prompt-templates --no-tools \
          -e ./probe-provider.ts --provider captains-call-probe --model deterministic \
          --thinking off -p '  S  ' 2>&1)
    status=$?
    [ "$status" -eq 0 ] || fail "real Pi Captain's Call $mode expansion failed: $out"
    [ -f "$prompt" ] \
      || fail "real Pi did not start the transformed turn; commands: $(cat "$commands_file" 2>/dev/null || printf unavailable)"
    assert_contains "$(cat "$prompt")" '<skill name="bearings"' "real Pi expanded the Bearings skill"
    tail -c 64 "$prompt" | grep -Fq $'</skill>\n\ncaptains-call-only' \
      || fail "real Pi did not append the exact captains-call-only argument: $(tail -c 160 "$prompt")"
    heading_count=$(printf '%s\n' "$out" | grep -c '^## ' || true)
    [ "$heading_count" -eq 1 ] || fail "Captain's Call-only $mode output rendered $heading_count sections: $out"
    assert_contains "$out" "## Captain's Call" "Captain's Call-only $mode heading"
    assert_not_contains "$out" "## Recently Landed" "Captain's Call-only $mode output included Recently Landed"
    assert_not_contains "$out" "## Underway" "Captain's Call-only $mode output included Underway"
    assert_not_contains "$out" "## Charted Next" "Captain's Call-only $mode output included Charted Next"
    if [ "$mode" = empty ]; then
      assert_contains "$out" "Nothing needs your action right now." "Captain's Call-only empty state"
    else
      assert_contains "$out" "Choose the release route." "Captain's Call-only actionable row"
    fi
  done

  if command -v tmux >/dev/null 2>&1; then
    rm -f "$prompt" "$commands_file"
    tmux -L "$TMUX_SOCKET" kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    tmux -L "$TMUX_SOCKET" new-session -d -s "$TMUX_SESSION" -x 100 -y 32 \
      "cd '$project' && env FM_HOME='$home' PI_CODING_AGENT_DIR='$config' PI_OFFLINE=1 PROBE_PROMPT='$prompt' PROBE_COMMANDS='$commands_file' PROBE_MODE=empty pi --approve --no-session --no-context-files --no-prompt-templates --no-tools -e ./probe-provider.ts --provider captains-call-probe --model deterministic --thinking off; rc=\$?; printf '\nPI_EXIT=%s\n' \"\$rc\"; sleep 20"
    i=0
    pane=""
    while [ "$i" -lt 120 ]; do
      pane=$(tmux -L "$TMUX_SOCKET" capture-pane -p -t "$TMUX_SESSION" -S - 2>/dev/null || true)
      printf '%s\n' "$pane" | grep -Fq 'probe-provider.ts' && break
      sleep 0.05
      i=$((i + 1))
    done
    printf '%s\n' "$pane" | grep -Fq 'probe-provider.ts' \
      || fail "real Pi Captain's Call TUI did not reach the ready composer: $pane"
    tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" -l '  S  '
    tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" Enter
    i=0
    while [ "$i" -lt 240 ]; do
      pane=$(tmux -L "$TMUX_SOCKET" capture-pane -p -t "$TMUX_SESSION" -S - 2>/dev/null || true)
      printf '%s\n' "$pane" | grep -Fq 'Nothing needs your action right now.' && break
      sleep 0.05
      i=$((i + 1))
    done
    printf '%s\n' "$pane" | grep -Fq 'Nothing needs your action right now.' \
      || fail "real Pi Captain's Call TUI did not render the empty state: $pane"
    printf '%s\n' "$pane" | grep -Fq "Captain's Call" \
      || fail "real Pi Captain's Call TUI did not render its heading: $pane"
    assert_not_contains "$pane" "Recently Landed" "real Pi Captain's Call TUI included Recently Landed"
    assert_not_contains "$pane" "Underway" "real Pi Captain's Call TUI included Underway"
    assert_not_contains "$pane" "Charted Next" "real Pi Captain's Call TUI included Charted Next"
    [ -f "$prompt" ] || fail "real Pi Captain's Call TUI did not start the transformed turn"
    tail -c 64 "$prompt" | grep -Fq $'</skill>\n\ncaptains-call-only' \
      || fail "real Pi Captain's Call TUI lost the exact mode argument: $(tail -c 160 "$prompt")"
    tmux -L "$TMUX_SOCKET" kill-session -t "$TMUX_SESSION" 2>/dev/null || true
  else
    echo "skip: tmux not found for real Pi Captain's Call TUI submission"
  fi

  if find "$home/data" -maxdepth 1 -name 'status-report-*.md' -print | grep -q .; then
    fail "Captain's Call-only expansion created a dated report"
  fi
  if [ -d "$home/.lavish" ] && find "$home/.lavish" -type f -print | grep -q .; then
    fail "Captain's Call-only expansion created a browser artifact"
  fi
  pass "real Pi 0.82.1 print and TUI paths expand the shortcut argument and render only Captain's Call without report or browser writes"
}

test_static_contract() {
  local text assistant_layout operational_user_layout visibility watch operational
  assert_present "$EXT" "tracked Pi calm extension is missing"
  assert_present "$ASSISTANT_LAYOUT" "tracked Pi Calm assistant-layout adapter is missing"
  assert_present "$OPERATIONAL_USER_LAYOUT" "tracked Pi Calm operational-user layout adapter is missing"
  assert_present "$COMPATIBILITY" "tracked Pi Calm compatibility preflight is missing"
  assert_present "$VISIBILITY" "tracked Pi calm visibility policy is missing"
  text=$(cat "$EXT")
  assistant_layout=$(cat "$ASSISTANT_LAYOUT")
  operational_user_layout=$(cat "$OPERATIONAL_USER_LAYOUT")
  visibility=$(cat "$VISIBILITY")
  watch=$(cat "$WATCH_EXT")
  operational=$(cat "$PI_OPERATIONAL_INPUT")
  assert_contains "$text" 'pi.registerCommand("calm"' "Pi calm extension does not register /calm"
  assert_contains "$text" 'pi.on("session_start"' "Pi calm extension does not restore presentation on every session start"
  assert_contains "$text" 'loadCalmPreference()' "Pi calm extension does not restore the home-persistent toggle choice"
  assert_contains "$text" 'persistCalmPreference(active)' "Pi calm extension does not persist the captain's toggle choice"
  assert_contains "$text" 'calmCompatibilityFailure(VERSION' "Pi calm extension does not certify the installed Pi before changing presentation"
  assert_contains "$text" 'ctx.ui.setToolsExpanded(!expanded)' "Pi calm extension does not redraw existing custom entries"
  assert_contains "$text" 'ctx.ui.setToolsExpanded(expanded)' "Pi calm extension does not restore Ctrl+O state after redraw"
  assert_not_contains "$text" 'ctx.navigateTree' "Pi calm extension reconstructs the transcript and drops transient diagnostics"
  assert_not_contains "$visibility" 'deliverFirstmateSyntheticInput' "Pi calm visibility policy can still replace operational input semantics"
  assert_not_contains "$visibility" 'classifyFirstmateSyntheticInput' "Pi calm visibility policy still classifies operational input for interception"
  assert_contains "$text" 'ctx.ui.setWorkingVisible(true)' "Pi calm extension does not preserve Pi's live working row"
  assert_not_contains "$text" 'ctx.ui.setWorkingVisible(!active)' "Pi calm extension still hides Pi's live working row"
  assert_contains "$text" 'ctx.ui.setHiddenThinkingLabel(active ? "" : undefined)' "Pi calm extension does not hide collapsed thinking labels"
  assert_contains "$text" 'installCalmAssistantLayout()' "Pi Calm extension does not install its zero-height assistant layout"
  assert_contains "$text" 'installCalmOperationalUserLayout()' "Pi Calm extension does not install its operational-user layout"
  assert_contains "$assistant_layout" 'AssistantMessageComponent.prototype.updateContent' "Pi Calm assistant layout does not control the exported component presentation path"
  assert_contains "$assistant_layout" 'block.type !== "thinking"' "Pi Calm assistant layout does not remove thinking from its presentation copy"
  assert_contains "$operational_user_layout" 'InteractiveMode.prototype' "Pi Calm operational-user layout does not control the transcript owner"
  assert_contains "$operational_user_layout" 'classifyFirstmateCurrentOperationalText(text)' "Pi Calm operational-user layout bypasses canonical current classification"
  assert_contains "$operational_user_layout" 'text.includes("\u2063")' "Pi Calm operational-user layout spawns its classifier for ordinary captain rows"
  assert_contains "$operational_user_layout" '"\u2063Supervisor escalate ("' "Pi Calm operational-user layout lost the narrow legacy marker"
  assert_contains "$operational_user_layout" 'hidesOperationalInput()' "Pi Calm operational-user row does not use presentation-only hiding"
  assert_not_contains "$operational_user_layout" 'FIRSTMATE_OP: ' "Pi Calm operational-user layout duplicates the canonical marker grammar"
  assert_not_contains "$text" 'calm transcript' "Pi calm extension still adds a persistent Calm status row"
  assert_not_contains "$text" 'pi.on("input"' "Pi calm extension still intercepts semantic input"
  assert_not_contains "$text" 'sendMessage' "Pi calm extension still replaces user-role input with custom context"
  assert_contains "$text" 'ctx.ui.onTerminalInput' "Pi calm extension does not scope export rendering to terminal submissions"
  assert_contains "$text" 'getKeybindings().matches(data, "tui.input.submit")' "Pi calm export boundary ignores the active submit keybinding"
  assert_contains "$text" 'input !== "/share"' "Pi calm export boundary does not cover /share"
  assert_not_contains "$text" 'FIRSTMATE_PI_LAUNCH_BRIEF_ENV' "Pi calm presentation still depends on launch-input provenance"
  assert_contains "$text" 'renderShell: "self"' "Pi calm extension cannot remove complete built-in tool shells"
  assert_contains "$visibility" 'CALM_VISIBLE_CLASSES' "Pi calm policy does not centralize its visibility allowlist"
  assert_contains "$operational" 'fm-operational-input.sh' "Pi adapter does not delegate to the canonical cross-language owner"
  assert_not_contains "$visibility" 'FIRSTMATE WATCHER WAKE:' "current Calm classification still matches watcher payload prose"
  assert_not_contains "$visibility" 'TURN WOULD END BLIND' "current Calm classification still matches turn-end payload prose"
  # shellcheck disable=SC2016 # Backticks are literal prompt markup.
  assert_not_contains "$visibility" 'Run `bin/fm-session-start.sh`' "current Calm classification still matches session-start payload prose"
  assert_not_contains "$visibility" 'FIRSTMATE_OP: ' "current Calm classification duplicates the canonical marker grammar"
  assert_contains "$watch" 'calmHides("assistant-tool-call")' "Firstmate watcher tool does not participate in Calm presentation"
  assert_contains "$watch" 'renderShell: "self"' "Firstmate watcher tool cannot remove its complete shell"
  for name in Read Bash Edit Write Grep Find Ls; do
    assert_contains "$text" "create${name}ToolDefinition" "Pi calm extension does not wrap the $name built-in"
  done
  pass "Pi calm extension is presentation-only with one persisted visibility choice, no Calm status row, native working visibility, supported redraw controls, and the Firstmate watcher-tool integration"
}

test_home_resolution() {
  local fixture out status version
  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    echo "skip: node or npm not found for Pi calm home-resolution test"
    return 0
  fi
  if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
    echo "skip: installed @earendil-works/pi-coding-agent package not found"
    return 0
  fi
  version=$(node -p "require('$PI_PACKAGE_DIR/package.json').version")
  require_pi_compat_version "$version" "Pi calm compatibility assumptions"

  fixture="$TMP_ROOT/home-resolution"
  mkdir -p \
    "$fixture/project/.pi/extensions/lib" \
    "$fixture/project/node_modules/@earendil-works" \
    "$fixture/override" \
    "$fixture/launch-cwd"
  cp "$EXT" "$fixture/project/.pi/extensions/fm-calm.ts"
  cp "$ASSISTANT_LAYOUT" "$fixture/project/.pi/extensions/lib/fm-calm-assistant-layout.ts"
  cp "$OPERATIONAL_USER_LAYOUT" "$fixture/project/.pi/extensions/lib/fm-calm-operational-user-layout.ts"
  cp "$COMPATIBILITY" "$fixture/project/.pi/extensions/lib/fm-calm-compatibility.ts"
  cp "$VISIBILITY" "$fixture/project/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$PI_OPERATIONAL_INPUT" "$fixture/project/.pi/extensions/lib/fm-operational-input.ts"
  ln -s "$PI_PACKAGE_DIR" "$fixture/project/node_modules/@earendil-works/pi-coding-agent"
  ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$fixture/project/node_modules/@earendil-works/pi-tui"
  ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$fixture/project/node_modules/typebox"
  printf '%s\n' '{"type":"module"}' >"$fixture/project/package.json"

  out=$(cd "$fixture/launch-cwd" && \
    EXT="$fixture/project/.pi/extensions/fm-calm.ts" \
    OVERRIDE_HOME="$fixture/override" \
    EXTENSION_HOME="$fixture/project" \
    node --input-type=module 2>&1 <<'JS'
import { existsSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const extension = await import(`${pathToFileURL(process.env.EXT).href}?home=${Date.now()}`);

function registerCalm() {
  const handlers = new Map();
  let calmCommand;
  const pi = {
    events: {
      emit() {},
      on() {},
    },
    on(event, handler) {
      handlers.set(event, handler);
    },
    registerCommand(name, command) {
      if (name === "calm") calmCommand = command;
    },
    registerEntryRenderer() {},
    registerTool() {},
  };
  extension.default(pi);
  if (!calmCommand || !handlers.has("session_start")) {
    throw new Error("Calm extension did not register its command and session handler");
  }
  return { calmCommand, sessionStart: handlers.get("session_start") };
}

const context = {
  ui: {
    getEditorText() {
      return "";
    },
    getToolsExpanded() {
      return false;
    },
    onTerminalInput() {
      return () => {};
    },
    notify() {},
    setHiddenThinkingLabel() {},
    setStatus() {},
    setToolsExpanded() {},
    setWorkingVisible() {},
  },
};

delete process.env.FM_HOME;
delete process.env.FM_CONFIG_OVERRIDE;
process.env.FM_ROOT_OVERRIDE = process.env.OVERRIDE_HOME;
let calm = registerCalm();
calm.sessionStart({ reason: "startup" }, context);
await calm.calmCommand.handler("on", context);
if (readFileSync(`${process.env.OVERRIDE_HOME}/config/calm`, "utf8") !== "on\n") {
  throw new Error("Calm ignored FM_ROOT_OVERRIDE when FM_HOME was unset");
}

delete process.env.FM_ROOT_OVERRIDE;
calm = registerCalm();
calm.sessionStart({ reason: "startup" }, context);
await calm.calmCommand.handler("on", context);
if (readFileSync(`${process.env.EXTENSION_HOME}/config/calm`, "utf8") !== "on\n") {
  throw new Error("Calm did not derive the Firstmate home from its extension path");
}
if (existsSync(`${process.cwd()}/config/calm`)) {
  throw new Error("Calm wrote its preference under Pi's launch directory");
}
JS
)
  status=$?
  [ "$status" -eq 0 ] || fail "Pi calm home resolution failed: $out"
  [ -z "$out" ] || fail "Pi calm home-resolution test printed output: $out"
  pass "Pi calm resolves its persistent home independently of Pi's launch directory"
}

test_compatibility_fallback() {
  local fixture out status version
  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    echo "skip: node or npm not found for Pi Calm compatibility test"
    return 0
  fi
  if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
    echo "skip: installed @earendil-works/pi-coding-agent package not found"
    return 0
  fi
  version=$(node -p "require('$PI_PACKAGE_DIR/package.json').version")
  require_pi_compat_version "$version" "Pi Calm compatibility fallback"

  fixture="$TMP_ROOT/compatibility"
  mkdir -p "$fixture/home" "$fixture/lib" "$fixture/node_modules/@earendil-works"
  cp "$EXT" "$fixture/fm-calm.ts"
  cp "$ASSISTANT_LAYOUT" "$fixture/lib/fm-calm-assistant-layout.ts"
  cp "$OPERATIONAL_USER_LAYOUT" "$fixture/lib/fm-calm-operational-user-layout.ts"
  cp "$COMPATIBILITY" "$fixture/lib/fm-calm-compatibility.ts"
  cp "$VISIBILITY" "$fixture/lib/fm-calm-visibility.ts"
  cp "$PI_OPERATIONAL_INPUT" "$fixture/lib/fm-operational-input.ts"
  ln -s "$PI_PACKAGE_DIR" "$fixture/node_modules/@earendil-works/pi-coding-agent"
  ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$fixture/node_modules/@earendil-works/pi-tui"
  ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$fixture/node_modules/typebox"
  printf '%s\n' '{"type":"module"}' >"$fixture/package.json"

  out=$(cd "$fixture" && EXT="$fixture/fm-calm.ts" FM_HOME="$fixture/home" node --input-type=module 2>&1 <<'JS'
import { existsSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { AssistantMessageComponent } from "@earendil-works/pi-coding-agent";
import { calmCompatibilityFailure } from "./lib/fm-calm-compatibility.ts";

const complete = {
  assistantLayout: true,
  operationalUserLayout: true,
  builtInRenderers: ["read", "bash", "edit", "write", "grep", "find", "ls"],
};
if (calmCompatibilityFailure("0.82.1", complete) !== undefined) {
  throw new Error("Pi 0.82.1 was not certified by the compatibility owner");
}
if (!calmCompatibilityFailure("0.82.2", complete)?.includes("unsupported")) {
  throw new Error("an uncertified Pi patch did not fall back as unsupported");
}
if (!calmCompatibilityFailure("0.82.1", { ...complete, assistantLayout: false })?.includes("AssistantMessageComponent")) {
  throw new Error("a missing renderer seam did not fail compatibility preflight");
}

const originalUpdateContent = AssistantMessageComponent.prototype.updateContent;
AssistantMessageComponent.prototype.updateContent = undefined;
const handlers = new Map();
const tools = [];
const notifications = [];
let calmCommand;
const pi = {
  events: { emit() {}, on() {} },
  on(name, handler) { handlers.set(name, handler); },
  registerCommand(name, command) { if (name === "calm") calmCommand = command; },
  registerEntryRenderer() {},
  registerTool(tool) { tools.push(tool); },
};
const extension = await import(`${pathToFileURL(process.env.EXT).href}?fallback=${Date.now()}`);
extension.default(pi);
AssistantMessageComponent.prototype.updateContent = originalUpdateContent;
if (tools.length !== 0) {
  throw new Error("compatibility failure partially registered Calm tool overrides");
}
if (!calmCommand || !handlers.has("session_start")) {
  throw new Error("compatibility fallback lost the Calm command or session warning owner");
}
const context = {
  ui: {
    getEditorText: () => "",
    getToolsExpanded: () => false,
    notify(message, level) { notifications.push({ message, level }); },
    onTerminalInput: () => () => {},
    setHiddenThinkingLabel() {},
    setStatus() {},
    setToolsExpanded() {},
    setWorkingVisible() {},
  },
};
handlers.get("session_start")({}, context);
handlers.get("session_start")({}, context);
if (
  notifications.length !== 1 ||
  notifications[0].level !== "warning" ||
  !notifications[0].message.includes("stock rendering is active") ||
  !notifications[0].message.includes("Update Firstmate")
) {
  throw new Error(`compatibility fallback warning was not single and actionable: ${JSON.stringify(notifications)}`);
}
await calmCommand.handler("on", context);
if (existsSync(`${process.env.FM_HOME}/config/calm`)) {
  throw new Error("disabled Calm persisted an on preference on an uncertified renderer");
}
JS
)
  status=$?
  [ "$status" -eq 0 ] || fail "Pi Calm compatibility fallback failed: $out"
  [ -z "$out" ] || fail "Pi Calm compatibility fallback printed output: $out"
  pass "Pi 0.82.1 is explicitly certified and unsupported or missing renderer surfaces fall back atomically to stock rendering"
}

test_rendering_and_session_lifecycle() {
  local fixture out status version
  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    echo "skip: node or npm not found for Pi calm renderer test"
    return 0
  fi
  if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
    echo "skip: installed @earendil-works/pi-coding-agent package not found"
    return 0
  fi
  version=$(node -p "require('$PI_PACKAGE_DIR/package.json').version")
  require_pi_compat_version "$version" "Pi calm compatibility assumptions"

  fixture="$TMP_ROOT/renderer"
  mkdir -p "$fixture/home" "$fixture/lib" "$fixture/node_modules/@earendil-works"
  cp "$EXT" "$fixture/fm-calm.ts"
  cp "$ASSISTANT_LAYOUT" "$fixture/lib/fm-calm-assistant-layout.ts"
  cp "$OPERATIONAL_USER_LAYOUT" "$fixture/lib/fm-calm-operational-user-layout.ts"
  cp "$COMPATIBILITY" "$fixture/lib/fm-calm-compatibility.ts"
  cp "$VISIBILITY" "$fixture/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$fixture/lib/fm-operational-input.ts"
  cp "$WATCH_EXT" "$fixture/fm-primary-pi-watch.ts"
  ln -s "$PI_PACKAGE_DIR" "$fixture/node_modules/@earendil-works/pi-coding-agent"
  ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$fixture/node_modules/@earendil-works/pi-tui"
  ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$fixture/node_modules/typebox"
  printf '%s\n' '{"type":"module"}' >"$fixture/package.json"
  cat >"$fixture/operational-input-probe.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1-}" >>"$FM_OPERATIONAL_INPUT_CALLS"
exec "$FM_OPERATIONAL_INPUT_OWNER" "$@"
SH
  chmod +x "$fixture/operational-input-probe.sh"

  out=$(cd "$fixture" && EXT="$fixture/fm-calm.ts" WATCH_EXT="$fixture/fm-primary-pi-watch.ts" FM_HOME="$fixture/home" FM_OPERATIONAL_INPUT_SCRIPT="$fixture/operational-input-probe.sh" FM_OPERATIONAL_INPUT_OWNER="$OPERATIONAL_INPUT" FM_OPERATIONAL_INPUT_CALLS="$fixture/operational-input-calls" PI_PACKAGE_DIR="$PI_PACKAGE_DIR" node --input-type=module 2>&1 <<'JS'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const packageRoot = process.env.PI_PACKAGE_DIR;
const [{ AssistantMessageComponent }, { CustomEntryComponent }, { ToolExecutionComponent }, { UserMessageComponent }, { InteractiveMode }, { initTheme, theme }, { Text, getKeybindings, setCapabilities }, { createToolHtmlRenderer }] = await Promise.all([
  import(pathToFileURL(`${packageRoot}/dist/modes/interactive/components/assistant-message.js`).href),
  import(pathToFileURL(`${packageRoot}/dist/modes/interactive/components/custom-entry.js`).href),
  import(pathToFileURL(`${packageRoot}/dist/modes/interactive/components/tool-execution.js`).href),
  import(pathToFileURL(`${packageRoot}/dist/modes/interactive/components/user-message.js`).href),
  import(pathToFileURL(`${packageRoot}/dist/modes/interactive/interactive-mode.js`).href),
  import(pathToFileURL(`${packageRoot}/dist/modes/interactive/theme/theme.js`).href),
  import(pathToFileURL(`${packageRoot}/node_modules/@earendil-works/pi-tui/dist/index.js`).href),
  import(pathToFileURL(`${packageRoot}/dist/core/export-html/tool-renderer.js`).href),
]);
initTheme("dark");
setCapabilities({ images: null, trueColor: true, hyperlinks: false });

const tools = [];
const handlers = new Map();
const entryRenderers = new Map();
const eventListeners = new Map();
let calmCommand;
const pi = {
  events: {
    emit(name, data) {
      for (const listener of eventListeners.get(name) ?? []) listener(data);
    },
    on(name, listener) {
      const listeners = eventListeners.get(name) ?? [];
      listeners.push(listener);
      eventListeners.set(name, listeners);
    },
  },
  on(event, handler) {
    const eventHandlers = handlers.get(event) ?? [];
    eventHandlers.push(handler);
    handlers.set(event, eventHandlers);
  },
  registerCommand(name, command) {
    if (name === "calm") calmCommand = command;
  },
  registerEntryRenderer(customType, renderer) {
    entryRenderers.set(customType, renderer);
  },
  registerTool(tool) {
    tools.push(tool);
  },
};
const extension = await import(`${pathToFileURL(process.env.EXT).href}?test=${Date.now()}`);
extension.default(pi);
const visibility = await import(`${pathToFileURL(`${process.cwd()}/lib/fm-calm-visibility.ts`).href}?policy=${Date.now()}`);
const operationalInput = await import(`${pathToFileURL(`${process.cwd()}/lib/fm-operational-input.ts`).href}?input=${Date.now()}`);

const names = tools.map((tool) => tool.name);
const expectedNames = ["read", "bash", "edit", "write", "grep", "find", "ls"];
if (JSON.stringify(names) !== JSON.stringify(expectedNames)) {
  throw new Error(`unexpected wrapped built-ins: ${names.join(",")}`);
}
if (!calmCommand || !handlers.has("session_start")) {
  throw new Error("calm command or session lifecycle handler was not registered");
}
if (handlers.has("input")) {
  throw new Error("Calm registered a semantic input interceptor");
}
if (
  calmCommand.description !==
  "Set, clear, inspect, or toggle Firstmate's supported conversation presentation."
) {
  throw new Error(`unexpected calm command description: ${calmCommand.description}`);
}

for (const itemClass of visibility.CALM_TRANSCRIPT_CLASSES) {
  const visible = visibility.calmTranscriptClassIsVisible(itemClass);
  const expected =
    itemClass === "genuine-user-prompt" ||
    itemClass === "genuine-agent-response" ||
    itemClass === "working-status";
  if (visible !== expected) {
    throw new Error(`Calm allowlist classified ${itemClass} as visible=${visible}`);
  }
}
const watcherBody =
  "FIRSTMATE WATCHER WAKE: signal: /tmp/probe.status\n\n" +
  "Run bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.";
const watcherMessage = operationalInput.encodeFirstmateOperationalInput("watcher", watcherBody);
const legacyAwayMessage = "\u2063Supervisor escalate (legacy presentation compatibility)";
const operationalHistory = [];
const operationalChat = {
  children: [new Text("VISIBLE_PREDECESSOR", 0, 0)],
  addChild(component) {
    this.children.push(component);
  },
};
const operationalMode = {
  chatContainer: operationalChat,
  editor: { addToHistory: (value) => operationalHistory.push(value) },
  getMarkdownThemeWithSettings: () => undefined,
  getUserMessageText: (message) => typeof message.content === "string"
    ? message.content
    : message.content.filter((item) => item.type === "text").map((item) => item.text).join(""),
  outputPad: 1,
};
const callsBeforePlainReplay = readFileSync(process.env.FM_OPERATIONAL_INPUT_CALLS, "utf8");
const plainReplayChat = {
  children: [],
  addChild(component) {
    this.children.push(component);
  },
};
for (let index = 0; index < 50; index += 1) {
  InteractiveMode.prototype.addMessageToChat.call(
    { ...operationalMode, chatContainer: plainReplayChat },
    { role: "user", content: `ORDINARY_REPLAY_${index}` },
  );
}
if (readFileSync(process.env.FM_OPERATIONAL_INPUT_CALLS, "utf8") !== callsBeforePlainReplay) {
  throw new Error("ordinary replay rows invoked operational subprocess classification");
}
InteractiveMode.prototype.addMessageToChat.call(
  operationalMode,
  { role: "user", content: [{ type: "text", text: watcherMessage }] },
  { populateHistory: true },
);
InteractiveMode.prototype.addMessageToChat.call(
  operationalMode,
  { role: "user", content: legacyAwayMessage },
);
const operationalComponent = operationalChat.children[1];
const legacyOperationalComponent = operationalChat.children[2];
const stockOperationalComponent = new UserMessageComponent(watcherMessage, undefined, 1);
const expectedCalmOffOperationalRows = ["", ...stockOperationalComponent.render(100)];
if (JSON.stringify(operationalComponent.render(100)) !== JSON.stringify(expectedCalmOffOperationalRows)) {
  throw new Error("Calm-off operational user rendering changed from Pi stock rows");
}
if (operationalHistory.length !== 1 || operationalHistory[0] !== watcherMessage) {
  throw new Error("operational user presentation changed Pi input history behavior");
}

writeFileSync("sample.txt", "alpha\n");
const cases = [
  ["read", { path: "sample.txt" }, { content: [{ type: "text", text: "alpha" }], details: {}, isError: false }],
  ["bash", { command: "printf 'CALM_RENDER_OUTPUT\\n'" }, { content: [{ type: "text", text: "CALM_RENDER_OUTPUT" }], details: {}, isError: false }],
  ["edit", { path: "sample.txt", edits: [{ oldText: "alpha", newText: "beta" }] }, { content: [{ type: "text", text: "Successfully replaced 1 block(s) in sample.txt." }], details: { diff: "-alpha\n+beta", patch: "", firstChangedLine: 1 }, isError: false }],
  ["write", { path: "sample.txt", content: "beta\n" }, { content: [{ type: "text", text: "Successfully wrote 5 bytes to sample.txt" }], details: undefined, isError: false }],
  ["grep", { pattern: "alpha", path: "." }, { content: [{ type: "text", text: "sample.txt:1:alpha" }], details: {}, isError: false }],
  ["find", { pattern: "*.txt", path: "." }, { content: [{ type: "text", text: "sample.txt" }], details: {}, isError: false }],
  ["ls", { path: "." }, { content: [{ type: "text", text: "sample.txt" }], details: {}, isError: false }],
];
const renderUi = { requestRender() {} };
const rows = [];
for (const [name, args, result] of cases) {
  const wrapped = tools.find((tool) => tool.name === name);
  const baseline = new ToolExecutionComponent(name, `baseline-${name}`, args, { showImages: false }, undefined, renderUi, process.cwd());
  const actual = new ToolExecutionComponent(name, `wrapped-${name}`, args, { showImages: false }, wrapped, renderUi, process.cwd());
  for (const row of [baseline, actual]) {
    row.markExecutionStarted();
    row.setArgsComplete();
    row.updateResult(result);
  }
  const collapsedExpected = baseline.render(100);
  const collapsedActual = actual.render(100);
  if (JSON.stringify(collapsedActual) !== JSON.stringify(collapsedExpected)) {
    throw new Error(`${name} collapsed rendering changed while calm mode was off`);
  }
  baseline.setExpanded(true);
  actual.setExpanded(true);
  const expandedExpected = baseline.render(100);
  const expandedActual = actual.render(100);
  if (JSON.stringify(expandedActual) !== JSON.stringify(expandedExpected)) {
    throw new Error(`${name} expanded rendering changed while calm mode was off`);
  }
  rows.push({ name, baseline, actual });
}

const watchPi = {
  ...pi,
  appendEntry() {},
  sendMessage() {},
  registerCommand() {},
  registerEntryRenderer() {},
};
const watchExtension = await import(`${pathToFileURL(process.env.WATCH_EXT).href}?test=${Date.now()}`);
watchExtension.default(watchPi);
const watchTool = tools.find((tool) => tool.name === "fm_watch_arm_pi");
if (!watchTool) throw new Error("Firstmate watcher extension did not register fm_watch_arm_pi");
const stockWatchTool = { ...watchTool };
delete stockWatchTool.renderCall;
delete stockWatchTool.renderResult;
delete stockWatchTool.renderShell;
const watchArgs = {};
const watchResult = {
  content: [{ type: "text", text: "watcher: started Pi extension arm child 1" }],
  details: { ok: true, message: "watcher: started Pi extension arm child 1" },
  isError: false,
};
const watchBaseline = new ToolExecutionComponent(
  "fm_watch_arm_pi",
  "watch-baseline",
  watchArgs,
  { showImages: false },
  stockWatchTool,
  renderUi,
  process.cwd(),
);
const watchActual = new ToolExecutionComponent(
  "fm_watch_arm_pi",
  "watch-actual",
  watchArgs,
  { showImages: false },
  watchTool,
  renderUi,
  process.cwd(),
);
for (const row of [watchBaseline, watchActual]) {
  row.markExecutionStarted();
  row.setArgsComplete();
  row.updateResult(watchResult);
}
if (JSON.stringify(watchActual.render(100)) !== JSON.stringify(watchBaseline.render(100))) {
  throw new Error("Firstmate watcher tool changed stock rendering while Calm was off");
}

function completedErrorRow(name, id, args, definition) {
  const row = new ToolExecutionComponent(
    name,
    id,
    args,
    { showImages: false },
    definition,
    renderUi,
    process.cwd(),
  );
  row.markExecutionStarted();
  row.setArgsComplete();
  row.updateResult({
    content: [{ type: "text", text: "CALM_TECHNICAL_FAILURE_RAW_EVIDENCE" }],
    details: { ok: false, message: "CALM_TECHNICAL_FAILURE_RAW_EVIDENCE" },
    isError: true,
  });
  return row;
}
const bashTool = tools.find((tool) => tool.name === "bash");
const stockBashTool = { ...bashTool };
delete stockBashTool.renderCall;
delete stockBashTool.renderResult;
delete stockBashTool.renderShell;
const errorBaseline = completedErrorRow("bash", "error-baseline", { command: "exit 7" }, stockBashTool);
const errorActual = completedErrorRow("bash", "error-actual", { command: "exit 7" }, bashTool);
const watchErrorBaseline = completedErrorRow("fm_watch_arm_pi", "watch-error-baseline", {}, stockWatchTool);
const watchErrorActual = completedErrorRow("fm_watch_arm_pi", "watch-error-actual", {}, watchTool);
if (JSON.stringify(errorActual.render(100)) !== JSON.stringify(errorBaseline.render(100))) {
  throw new Error("built-in technical error changed stock rendering while Calm was off");
}
if (JSON.stringify(watchErrorActual.render(100)) !== JSON.stringify(watchErrorBaseline.render(100))) {
  throw new Error("watcher technical error changed stock rendering while Calm was off");
}

const customDefinition = {
  name: "third_party_tool",
  label: "Third party tool",
  description: "Custom-tool boundary probe",
  parameters: { type: "object", properties: {} },
  renderShell: "self",
  async execute() {
    return { content: [{ type: "text", text: "CUSTOM_RESULT" }], details: {} };
  },
  renderCall() {
    return new Text("CUSTOM_CALL", 0, 0);
  },
  renderResult() {
    return new Text("CUSTOM_RESULT", 0, 0);
  },
};
const customRow = new ToolExecutionComponent(
  "third_party_tool",
  "custom-row",
  {},
  { showImages: false },
  customDefinition,
  renderUi,
  process.cwd(),
);
customRow.markExecutionStarted();
customRow.setArgsComplete();
customRow.updateResult({ content: [{ type: "text", text: "CUSTOM_RESULT" }], details: {}, isError: false });

setCapabilities({ images: "iterm2", trueColor: true, hyperlinks: true });
const imageRow = new ToolExecutionComponent(
  "read",
  "read-image-row",
  { path: "pixel.png" },
  { showImages: true },
  tools.find((tool) => tool.name === "read"),
  renderUi,
  process.cwd(),
);
imageRow.markExecutionStarted();
imageRow.setArgsComplete();
imageRow.updateResult({
  content: [
    {
      type: "image",
      data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
      mimeType: "image/png",
    },
  ],
  details: {},
  isError: false,
});
imageRow.setExpanded(true);
const imageVisibleBefore = imageRow.render(100);
if (!imageVisibleBefore.join("\n").includes("\x1b]1337;File=")) {
  throw new Error("image-capable Pi fixture did not render the built-in read image boundary");
}

const assistantBase = {
  role: "assistant",
  api: "calm-render-test",
  provider: "calm-render-test",
  model: "deterministic",
  usage: {
    input: 0,
    output: 0,
    cacheRead: 0,
    cacheWrite: 0,
    totalTokens: 0,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
  },
  stopReason: "stop",
  timestamp: 1,
};
const assistantTextOnly = new AssistantMessageComponent({
  ...assistantBase,
  content: [{ type: "text", text: "VISIBLE_ASSISTANT_TEXT" }],
}, true);
const assistantThinkingText = new AssistantMessageComponent({
  ...assistantBase,
  content: [
    { type: "thinking", thinking: "HIDDEN_FINAL_THINKING" },
    { type: "text", text: "VISIBLE_ASSISTANT_TEXT" },
  ],
}, true);
const assistantThinkingTool = new AssistantMessageComponent({
  ...assistantBase,
  content: [
    { type: "thinking", thinking: "HIDDEN_TOOL_THINKING" },
    { type: "toolCall", id: "assistant-layout-tool", name: "read", arguments: { path: "sample.txt" } },
  ],
  stopReason: "toolUse",
}, true);
if (!assistantThinkingText.render(100).join("\n").includes("Thinking...")) {
  throw new Error("stock collapsed-thinking fixture did not render before Calm was active");
}

const assistantComponents = [assistantTextOnly, assistantThinkingText, assistantThinkingTool];
let expanded = true;
let editorText = "";
let terminalInputHandler;
let workingVisible;
let hiddenThinkingLabel = "unset";
const notifications = [];
const statuses = new Map();
const sessionEntries = [{ type: "message", message: { role: "toolResult", content: "kept" } }];
const entriesBefore = JSON.stringify(sessionEntries);
const commandContext = {
  sessionManager: { getEntries: () => sessionEntries },
  ui: {
    getEditorText: () => editorText,
    notify(message, level) {
      notifications.push({ message, level });
    },
    getToolsExpanded: () => expanded,
    onTerminalInput(handler) {
      terminalInputHandler = handler;
      return () => {
        if (terminalInputHandler === handler) terminalInputHandler = undefined;
      };
    },
    setHiddenThinkingLabel(value) {
      hiddenThinkingLabel = value;
      for (const component of assistantComponents) {
        component.setHiddenThinkingLabel(value ?? "Thinking...");
      }
    },
    setStatus(key, value) {
      statuses.set(key, value);
    },
    setToolsExpanded(value) {
      expanded = value;
      for (const row of rows) row.actual.setExpanded(value);
      watchActual.setExpanded(value);
      errorActual.setExpanded(value);
      watchErrorActual.setExpanded(value);
      customRow.setExpanded(value);
      imageRow.setExpanded(value);
    },
    setWorkingVisible(value) {
      workingVisible = value;
    },
  },
};

commandContext.ui.setToolsExpanded(false);
for (const { baseline } of rows) baseline.setExpanded(false);
watchBaseline.setExpanded(false);
errorBaseline.setExpanded(false);
watchErrorBaseline.setExpanded(false);
await handlers.get("session_start")[0]({ reason: "startup" }, commandContext);
if (workingVisible !== true || hiddenThinkingLabel !== "") {
  throw new Error("an absent preference did not default to Calm on after Pi 0.82.1 certification");
}
if (existsSync(`${process.env.FM_HOME}/config/calm`)) {
  throw new Error("the absent Calm default unexpectedly persisted a preference file");
}
const visibleDefaultRows = rows
  .filter(({ actual }) => actual.render(100).length !== 0)
  .map(({ name, actual }) => `${name}:${JSON.stringify(actual.render(100))}`);
if (visibleDefaultRows.length > 0) {
  throw new Error(`the absent Calm default did not collapse known built-in rows: ${visibleDefaultRows.join(";")}`);
}
await calmCommand.handler("status", commandContext);
if (!notifications.at(-1)?.message.includes("Calm is on") || existsSync(`${process.env.FM_HOME}/config/calm`)) {
  throw new Error("/calm status changed or misreported the absent default");
}
await calmCommand.handler("off", commandContext);
if (hiddenThinkingLabel !== undefined || readFileSync(`${process.env.FM_HOME}/config/calm`, "utf8") !== "off\n") {
  throw new Error("/calm off did not persist and apply the explicit stock-rendering preference");
}
await handlers.get("session_start")[0]({ reason: "resume" }, commandContext);
if (hiddenThinkingLabel !== undefined || readFileSync(`${process.env.FM_HOME}/config/calm`, "utf8") !== "off\n") {
  throw new Error("an explicit Calm off preference did not win across session restart");
}
await calmCommand.handler("status", commandContext);
if (!notifications.at(-1)?.message.includes("Calm is off")) {
  throw new Error("/calm status misreported the explicit off preference");
}
await calmCommand.handler("on", commandContext);
if (hiddenThinkingLabel !== "" || readFileSync(`${process.env.FM_HOME}/config/calm`, "utf8") !== "on\n") {
  throw new Error("/calm on did not persist and apply Calm");
}
await calmCommand.handler("off", commandContext);
const preferenceBeforeInvalidCommand = readFileSync(`${process.env.FM_HOME}/config/calm`, "utf8");
await calmCommand.handler("unexpected", commandContext);
if (
  readFileSync(`${process.env.FM_HOME}/config/calm`, "utf8") !== preferenceBeforeInvalidCommand ||
  !notifications.at(-1)?.message.includes("Usage: /calm")
) {
  throw new Error("an invalid /calm argument changed state or omitted usage guidance");
}
const presentationRenderer = entryRenderers.get("firstmate-synthetic-input-presentation");
if (!presentationRenderer) throw new Error("legacy synthetic presentation renderer was not registered");
const presentationEntry = {
  customType: "firstmate-synthetic-input-presentation",
  data: { content: watcherMessage, kind: "watcher" },
};
const presentationComponent = new CustomEntryComponent(presentationEntry, presentationRenderer);
presentationComponent.setExpanded(expanded);
if (
  !presentationComponent.hasContent() ||
  !presentationComponent.render(100).join("\n").includes("FIRSTMATE WATCHER WAKE")
) {
  throw new Error("Calm-off legacy synthetic presentation did not use a stock user-message row");
}

await calmCommand.handler("", commandContext);
if (expanded !== false || workingVisible !== true || hiddenThinkingLabel !== "" || statuses.get("firstmate-calm") !== undefined) {
  throw new Error("Calm did not preserve working visibility or apply its thinking and footer presentation controls");
}
if (readFileSync(`${process.env.FM_HOME}/config/calm`, "utf8") !== "on\n") {
  throw new Error("Calm did not persist the active choice in the effective Firstmate home");
}
presentationComponent.setExpanded(!expanded);
if (presentationComponent.hasContent() || presentationComponent.render(100).length !== 0) {
  throw new Error("Calm left a synthetic Firstmate presentation row or spacer visible");
}
if (operationalComponent.render(100).length !== 0) {
  throw new Error("Calm left a current operational user row or its leading spacer visible");
}
if (legacyOperationalComponent.render(100).length !== 0) {
  throw new Error("Calm left the supported bare-marker legacy user row visible");
}
const operationalNearMisses = [
  {
    content: `Captain quote: ${watcherMessage}`,
    visible: "Captain quote:",
  },
  {
    content: "FIRSTMATE_OP: v1 watcher: ASCII_ONLY_CAPTAIN_MESSAGE",
    visible: "ASCII_ONLY_CAPTAIN_MESSAGE",
  },
  {
    content: `Ordinary captain text before ${watcherMessage}`,
    visible: "Ordinary captain text before",
  },
  {
    content: "\u2063ordinary captain text after an unrelated separator",
    visible: "ordinary captain text after an unrelated separator",
  },
  {
    content: "\u2063FIRSTMATE_OP: legacy untyped captain message",
    visible: "legacy untyped captain message",
  },
  {
    content: "Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.",
    visible: "before executing any other instructions",
  },
  {
    content:
      "FIRSTMATE WATCHER WAKE: captain-authored legacy-shaped message\n\n" +
      "Run bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.",
    visible: "captain-authored legacy-shaped message",
  },
  {
    content:
      "TURN WOULD END BLIND - supervision is off. The watcher cycle is missing, failed, or unhealthy. " +
      "Follow the harness recovery instruction below before ending the turn.\n\n" +
      "captain-authored legacy-shaped message",
    visible: "captain-authored legacy-shaped message",
  },
  {
    content: [
      { type: "text", text: watcherMessage },
      { type: "image", data: "ignored-by-text-renderer", mimeType: "image/png" },
    ],
    visible: "FIRSTMATE WATCHER WAKE",
  },
];
for (const nearMiss of operationalNearMisses) {
  const chat = {
    children: [new Text("VISIBLE_PREDECESSOR", 0, 0)],
    addChild(component) {
      this.children.push(component);
    },
  };
  InteractiveMode.prototype.addMessageToChat.call(
    { ...operationalMode, chatContainer: chat },
    { role: "user", content: nearMiss.content },
  );
  const rendered = chat.children.flatMap((component) => component.render(180)).join("\n");
  if (!rendered.includes(nearMiss.visible)) {
    throw new Error(`Calm hid an operational near miss: ${nearMiss.visible}`);
  }
}
for (const { name, actual } of rows) {
  if (actual.render(100).length !== 0) {
    throw new Error(`${name} was not hidden before export rendering`);
  }
}
for (const [label, row] of [["built-in", errorActual], ["watcher", watchErrorActual]]) {
  const collapsedFailure = row.render(100);
  if (
    collapsedFailure.filter((line) => line !== "").length !== 1 ||
    !collapsedFailure.join("\n").includes("Technical step failed") ||
    !collapsedFailure.join("\n").includes("shows evidence") ||
    collapsedFailure.join("\n").includes("CALM_TECHNICAL_FAILURE_RAW_EVIDENCE")
  ) {
    throw new Error(`${label} collapsed failure did not retain exactly one concise reveal hint: ${JSON.stringify(collapsedFailure)}`);
  }
}
for (const { baseline } of rows) baseline.setExpanded(true);
watchBaseline.setExpanded(true);
errorBaseline.setExpanded(true);
watchErrorBaseline.setExpanded(true);
commandContext.ui.setToolsExpanded(true);
for (const { name, baseline, actual } of rows) {
  if (JSON.stringify(actual.render(100)) !== JSON.stringify(baseline.render(100))) {
    throw new Error(`${name} Ctrl+O expansion did not restore complete stock rendering`);
  }
}
if (JSON.stringify(watchActual.render(100)) !== JSON.stringify(watchBaseline.render(100))) {
  throw new Error("fm_watch_arm_pi Ctrl+O expansion did not restore complete stock rendering");
}
if (JSON.stringify(errorActual.render(100)) !== JSON.stringify(errorBaseline.render(100))) {
  throw new Error("built-in Ctrl+O expansion did not restore complete stock error evidence");
}
if (JSON.stringify(watchErrorActual.render(100)) !== JSON.stringify(watchErrorBaseline.render(100))) {
  throw new Error("watcher Ctrl+O expansion did not restore complete stock error evidence");
}
for (const { baseline } of rows) baseline.setExpanded(false);
watchBaseline.setExpanded(false);
errorBaseline.setExpanded(false);
watchErrorBaseline.setExpanded(false);
commandContext.ui.setToolsExpanded(false);
for (const { name, actual } of rows) {
  if (actual.render(100).length !== 0) {
    throw new Error(`${name} did not return to zero height after a second Ctrl+O`);
  }
}
for (const [label, row] of [["built-in", errorActual], ["watcher", watchErrorActual]]) {
  if (row.render(100).filter((line) => line !== "").length !== 1) {
    throw new Error(`${label} failure hint did not survive the expanded-to-collapsed round trip`);
  }
}
async function assertStockHtmlRendering(command, submitData) {
  editorText = command;
  terminalInputHandler(submitData);
  const htmlRenderer = createToolHtmlRenderer({
    getToolDefinition: (name) => tools.find((tool) => tool.name === name),
    theme,
    cwd: process.cwd(),
  });
  const exportCases = [
    ...cases.filter(([toolName]) => toolName === "grep" || toolName === "find"),
    ["fm_watch_arm_pi", watchArgs, watchResult],
  ];
  for (const [name, args, result] of exportCases) {
    const toolCallId = `${command}-${name}`;
    const callHtml = htmlRenderer.renderCall(toolCallId, name, args);
    const resultHtml = htmlRenderer.renderResult(
      toolCallId,
      name,
      result.content,
      result.details,
      result.isError,
    );
    if (!callHtml || !resultHtml?.expanded) {
      throw new Error(`${name} disappeared from ${command} HTML while calm mode was on`);
    }
  }
  editorText = "";
  await new Promise((resolve) => setTimeout(resolve, 0));
}

await assertStockHtmlRendering("/export calm.html", "\r");
getKeybindings().setUserBindings({ "tui.input.submit": "alt+s" });
editorText = "/export remapped.html";
terminalInputHandler("\r");
const unmatchedRenderer = createToolHtmlRenderer({
  getToolDefinition: (name) => tools.find((tool) => tool.name === name),
  theme,
  cwd: process.cwd(),
});
if (unmatchedRenderer.renderCall("unmatched-submit", "grep", { pattern: "alpha", path: "." })) {
  throw new Error("ordinary non-submit input activated HTML export rendering");
}
editorText = "";
await assertStockHtmlRendering("/share", "\x1bs");
for (const { name, actual } of rows) {
  const rendered = actual.render(100);
  if (rendered.length !== 0) {
    throw new Error(`${name} left residual tool rows while calm mode was on: ${JSON.stringify(rendered)}`);
  }
}
const calmImageOutput = imageRow.render(100).join("\n");
if (!calmImageOutput.includes("\x1b]1337;File=")) {
  throw new Error("calm mode hid the disclosed built-in read image boundary");
}
if (calmImageOutput.includes("pixel.png")) {
  throw new Error("calm mode left the built-in read call shell beside the disclosed image output");
}
if (!customRow.render(100).join("\n").includes("CUSTOM_CALL")) {
  throw new Error("calm mode incorrectly claimed or applied generic custom-tool coverage");
}
if (watchActual.render(100).length !== 0) {
  throw new Error("Calm left the fm_watch_arm_pi call/result shell visible");
}
if (assistantThinkingTool.render(100).length !== 0) {
  throw new Error("Calm-hidden thinking beside a tool call retained vertical height");
}
if (JSON.stringify(assistantThinkingText.render(100)) !== JSON.stringify(assistantTextOnly.render(100))) {
  throw new Error("Calm-hidden thinking changed final assistant row geometry");
}
assistantThinkingTool.setHideThinkingBlock(false);
if (!assistantThinkingTool.render(100).join("\n").includes("HIDDEN_TOOL_THINKING")) {
  throw new Error("expanding thinking did not restore the original reasoning content");
}
assistantThinkingTool.setHideThinkingBlock(true);
if (assistantThinkingTool.render(100).length !== 0) {
  throw new Error("collapsing thinking again restored residual Calm rows");
}
if (JSON.stringify(sessionEntries) !== entriesBefore) {
  throw new Error("calm mode changed session entries or model context");
}

for (const { baseline } of rows) baseline.setExpanded(expanded);
watchBaseline.setExpanded(expanded);
errorBaseline.setExpanded(expanded);
watchErrorBaseline.setExpanded(expanded);
await calmCommand.handler("", commandContext);
presentationComponent.setExpanded(expanded);
if (
  !presentationComponent.hasContent() ||
  !presentationComponent.render(100).join("\n").includes("FIRSTMATE WATCHER WAKE")
) {
  throw new Error("turning Calm off did not restore a legacy synthetic presentation row");
}
if (JSON.stringify(operationalComponent.render(100)) !== JSON.stringify(expectedCalmOffOperationalRows)) {
  throw new Error("turning Calm off did not restore byte-identical operational user rows and spacing");
}
if (!legacyOperationalComponent.render(100).join("\n").includes("legacy presentation compatibility")) {
  throw new Error("turning Calm off did not restore the supported legacy operational row");
}
for (const { name, baseline, actual } of rows) {
  if (JSON.stringify(actual.render(100)) !== JSON.stringify(baseline.render(100))) {
    throw new Error(`${name} did not restore the expanded standard renderer`);
  }
}
const restoredImageOutput = imageRow.render(100).join("\n");
if (!restoredImageOutput.includes("pixel.png") || !restoredImageOutput.includes("\x1b]1337;File=")) {
  throw new Error("built-in read image row did not restore its ordinary call shell and image output");
}
if (JSON.stringify(watchActual.render(100)) !== JSON.stringify(watchBaseline.render(100))) {
  throw new Error("fm_watch_arm_pi did not restore its stock call/result shell");
}
if (JSON.stringify(errorActual.render(100)) !== JSON.stringify(errorBaseline.render(100))) {
  throw new Error("turning Calm off did not restore the stock built-in error row");
}
if (JSON.stringify(watchErrorActual.render(100)) !== JSON.stringify(watchErrorBaseline.render(100))) {
  throw new Error("turning Calm off did not restore the stock watcher error row");
}
if (workingVisible !== true || hiddenThinkingLabel !== undefined || statuses.get("firstmate-calm") !== undefined) {
  throw new Error("turning Calm off did not restore stock presentation controls");
}
if (!assistantThinkingTool.render(100).join("\n").includes("Thinking...")) {
  throw new Error("turning Calm off did not restore the collapsed thinking label");
}
if (readFileSync(`${process.env.FM_HOME}/config/calm`, "utf8") !== "off\n") {
  throw new Error("Calm did not persist the inactive choice in the effective Firstmate home");
}
presentationComponent.setExpanded(expanded);
if (
  !presentationComponent.hasContent() ||
  !presentationComponent.render(100).join("\n").includes("FIRSTMATE WATCHER WAKE")
) {
  throw new Error("turning Calm off did not restore synthetic user-row presentation");
}

await calmCommand.handler("", commandContext);
for (const reason of ["startup", "new", "resume", "fork", "reload"]) {
  await handlers.get("session_start")[0]({ reason }, commandContext);
  for (const row of rows) row.actual.setExpanded(expanded);
  for (const { name, actual } of rows) {
    if (actual.render(100).length !== 0) {
      throw new Error(`${reason} session did not retain the active Calm choice for ${name}`);
    }
  }
  if (workingVisible !== true || hiddenThinkingLabel !== "" || statuses.get("firstmate-calm") !== undefined) {
    throw new Error(`${reason} session did not retain gapless Calm presentation with native working visibility`);
  }
}
await calmCommand.handler("", commandContext);

const readWrapper = tools.find((tool) => tool.name === "read");
const { createReadToolDefinition } = await import(pathToFileURL(`${packageRoot}/dist/index.js`).href);
const originalRead = createReadToolDefinition(process.cwd());
const executeContext = { cwd: process.cwd() };
const [originalResult, wrappedResult] = await Promise.all([
  originalRead.execute("original-read", { path: "sample.txt" }, undefined, undefined, executeContext),
  readWrapper.execute("wrapped-read", { path: "sample.txt" }, undefined, undefined, executeContext),
]);
if (JSON.stringify(wrappedResult) !== JSON.stringify(originalResult)) {
  throw new Error("calm wrapper changed built-in read execution or result data");
}
JS
)
  status=$?
  [ "$status" -eq 0 ] || fail "Pi calm renderer and lifecycle contract failed: $out"
  [ -z "$out" ] || fail "Pi calm renderer test printed output: $out"
  pass "Pi calm centralizes transcript visibility, preserves execution/export data, keeps native working visible, and persists its choice across session starts"
}

test_operational_followup_turn_e2e() {
  local project home config sessions version label case_name calm_state expected_notifications session_file pane i captain_line handled_line geometry_gap exact_session
  if ! command -v pi >/dev/null 2>&1 || ! command -v tmux >/dev/null 2>&1; then
    echo "skip: pi or tmux not found for Pi operational follow-up E2E"
    return 0
  fi
  version=$(pi --version 2>/dev/null || true)
  require_pi_compat_version "$version" "Pi operational follow-up E2E"

  project="$TMP_ROOT/followup-project"
  home="$TMP_ROOT/followup-home"
  config="$TMP_ROOT/followup-config"
  sessions="$TMP_ROOT/followup-sessions"
  mkdir -p "$project/.pi/extensions/lib" "$home/config" "$config" "$sessions"
  fm_git_init_commit "$project"
  cp "$EXT" "$project/.pi/extensions/fm-calm.ts"
  cp "$ASSISTANT_LAYOUT" "$project/.pi/extensions/lib/fm-calm-assistant-layout.ts"
  cp "$OPERATIONAL_USER_LAYOUT" "$project/.pi/extensions/lib/fm-calm-operational-user-layout.ts"
  cp "$COMPATIBILITY" "$project/.pi/extensions/lib/fm-calm-compatibility.ts"
  cp "$VISIBILITY" "$project/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$PI_OPERATIONAL_INPUT" "$project/.pi/extensions/lib/fm-operational-input.ts"
  printf '%s\n' '{"followUpMode":"all"}' >"$config/settings.json"

  cat >"$project/followup-e2e.ts" <<'TS'
import {
  type AssistantMessage,
  createAssistantMessageEventStream,
} from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { encodeFirstmateOperationalInput } from "./.pi/extensions/lib/fm-operational-input.ts";

let phase: "idle" | "captain" | "monitor" = "idle";
let label = "";
let adjacent = false;
let latestInputRole: "user" | "custom" | undefined;

const EXACT_WATCHER_INPUT =
  "\u2063FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: signal: /home/fixture/github/kunchenguid/firstmate/state/oss-triage-t4.status\n\n" +
  "Run bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.";

function monitorInput(suffix: "ONE" | "TWO"): string {
  if (label === "exact_watcher" && suffix === "ONE") return EXACT_WATCHER_INPUT;
  if (label === "legacy_away" && suffix === "ONE") {
    return "\u2063Supervisor escalate (LEGACY_AWAY_E2E)";
  }
  return encodeFirstmateOperationalInput("watcher", `MONITOR_${label}_${suffix}`);
}

function contentText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((item): item is { type: "text"; text: string } =>
      typeof item === "object" && item !== null &&
      (item as { type?: unknown }).type === "text" &&
      typeof (item as { text?: unknown }).text === "string")
    .map((item) => item.text)
    .join("\n");
}

export default function (pi: ExtensionAPI): void {
  pi.on("message_start", (event) => {
    if (event.message.role === "user" || event.message.role === "custom") {
      latestInputRole = event.message.role;
    }
    if (event.message.role !== "assistant" || phase !== "captain") return;
    phase = "monitor";
    pi.sendUserMessage(monitorInput("ONE"), { deliverAs: "followUp" });
    if (adjacent) {
      pi.sendUserMessage(monitorInput("TWO"), { deliverAs: "followUp" });
    }
  });

  pi.registerProvider("followup-e2e", {
    baseUrl: "http://127.0.0.1/unused",
    apiKey: "test-only",
    api: "followup-e2e-api",
    models: [{
      id: "deterministic",
      name: "Deterministic operational follow-up regression",
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 4096,
      maxTokens: 128,
    }],
    streamSimple(model, context) {
      const stream = createAssistantMessageEventStream();
      const allUserText = context.messages
        .filter((message) => message.role === "user")
        .map((message) => contentText(message.content))
        .join("\n");
      const responseText = latestInputRole === "custom"
        ? `CAPTAIN_ANSWER_${label}`
        : allUserText.includes(monitorInput("ONE"))
          ? adjacent && allUserText.includes(monitorInput("TWO"))
            ? `MONITOR_HANDLED_${label}_ONE_TWO`
            : `MONITOR_HANDLED_${label}_ONE`
          : `CAPTAIN_ANSWER_${label}`;
      const output: AssistantMessage = {
        role: "assistant",
        content: [],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: {
          input: 0,
          output: 0,
          cacheRead: 0,
          cacheWrite: 0,
          totalTokens: 0,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
        },
        stopReason: "stop",
        timestamp: Date.now(),
      };
      queueMicrotask(() => {
        stream.push({ type: "start", partial: output });
        const block = { type: "text" as const, text: responseText };
        output.content.push(block);
        stream.push({ type: "text_start", contentIndex: 0, partial: output });
        stream.push({ type: "text_delta", contentIndex: 0, delta: responseText, partial: output });
        stream.push({ type: "text_end", contentIndex: 0, content: responseText, partial: output });
        stream.push({ type: "done", reason: "stop", message: output });
        stream.end();
      });
      return stream;
    },
  });

  pi.registerCommand("followup-e2e", {
    description: "Run one captain prompt followed by typed monitoring input.",
    handler: async (args, ctx) => {
      const [nextLabel, shape] = args.trim().split(/\s+/);
      if (!nextLabel) throw new Error("missing follow-up E2E label");
      const model = ctx.modelRegistry.find("followup-e2e", "deterministic");
      if (!model || !(await pi.setModel(model))) throw new Error("follow-up E2E model unavailable");
      label = nextLabel;
      adjacent = shape === "adjacent";
      phase = "captain";
      pi.sendUserMessage(`CAPTAIN_PROMPT_${label}`);
    },
  });
}
TS

  run_followup_case() {
    case_name=$1
    calm_state=$2
    label=$3
    expected_notifications=$4
    local session_arg=${5:-}
    local shape=${6:-single}
    local extensions

    tmux -L "$TMUX_SOCKET" kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    if [ "$calm_state" = absent ]; then
      rm -f "$home/config/calm"
      extensions='-e ./followup-e2e.ts'
    elif [ "$calm_state" = default ]; then
      rm -f "$home/config/calm"
      extensions='-e ./.pi/extensions/fm-calm.ts -e ./followup-e2e.ts'
    else
      printf '%s\n' "$calm_state" >"$home/config/calm"
      extensions='-e ./.pi/extensions/fm-calm.ts -e ./followup-e2e.ts'
    fi
    if [ -z "$session_arg" ]; then
      session_arg="--session-dir '$sessions/$label'"
      mkdir -p "$sessions/$label"
    else
      session_arg="--session '$session_arg'"
    fi

    tmux -L "$TMUX_SOCKET" new-session -d -s "$TMUX_SESSION" -x 160 -y 36 \
      "cd '$project' && env FM_HOME='$home' PI_CODING_AGENT_DIR='$config' FM_OPERATIONAL_INPUT_SCRIPT='$OPERATIONAL_INPUT' PI_OFFLINE=1 pi --approve --no-context-files --no-skills --no-prompt-templates --no-extensions $extensions $session_arg; rc=\$?; printf '\nPI_EXIT=%s\n' \"\$rc\"; sleep 20"
    i=0
    while [ "$i" -lt 120 ]; do
      pane=$(tmux -L "$TMUX_SOCKET" capture-pane -p -t "$TMUX_SESSION" -S - 2>/dev/null || true)
      printf '%s\n' "$pane" | grep -Fq 'followup-e2e.ts' && break
      sleep 0.05
      i=$((i + 1))
    done
    printf '%s\n' "$pane" | grep -Fq 'followup-e2e.ts' \
      || fail "Pi follow-up $case_name case ($label) did not reach the ready composer"

    tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" -l "/followup-e2e $label $shape"
    tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" Enter
    i=0
    while [ "$i" -lt 240 ]; do
      session_file=$(find "$sessions" -type f -name '*.jsonl' -exec grep -l "CAPTAIN_PROMPT_$label" {} + 2>/dev/null | head -1 || true)
      if [ -n "$session_file" ] && grep -Fq "MONITOR_HANDLED_${label}_ONE" "$session_file"; then
        break
      fi
      sleep 0.05
      i=$((i + 1))
    done
    if [ -z "$session_file" ] || ! grep -Fq "MONITOR_HANDLED_${label}_ONE" "$session_file"; then
      fail "Pi follow-up $label case did not process the monitoring notification"
    fi

    pane=$(tmux -L "$TMUX_SOCKET" capture-pane -p -t "$TMUX_SESSION" -S - 2>/dev/null || true)
    [ "$(printf '%s\n' "$pane" | grep -Fc "CAPTAIN_ANSWER_$label" || true)" -eq 1 ] \
      || fail "Pi follow-up $label case rendered a duplicate captain answer"
    assert_contains "$pane" "CAPTAIN_PROMPT_$label" "Pi follow-up $label case hid the genuine captain prompt"
    assert_contains "$pane" "MONITOR_HANDLED_${label}_ONE" "Pi follow-up $label case did not render the intended processing result"
    if [ "$calm_state" = on ] || [ "$calm_state" = default ]; then
      assert_not_contains "$pane" "MONITOR_${label}_ONE" "Pi follow-up $label case rendered a Calm-hidden operational user row"
      if [ "$label" = exact_watcher ]; then
        assert_not_contains "$pane" "FIRSTMATE WATCHER WAKE: signal: /home/fixture/github/kunchenguid/firstmate/state/oss-triage-t4.status" \
          "Pi exact watcher case rendered the Calm-hidden authoritative payload"
        assert_not_contains "$pane" "Run bin/fm-wake-drain.sh first and handle the queued wake." \
          "Pi exact watcher case rendered the Calm-hidden drain instruction"
      elif [ "$label" = legacy_away ]; then
        assert_not_contains "$pane" "LEGACY_AWAY_E2E" \
          "Pi legacy-away case rendered the narrowly supported Calm-hidden input"
      fi
      if [ "$expected_notifications" -eq 2 ]; then
        assert_not_contains "$pane" "MONITOR_${label}_TWO" "Pi follow-up $label case rendered the adjacent Calm-hidden operational row"
      fi
      captain_line=$(printf '%s\n' "$pane" | grep -Fn "CAPTAIN_ANSWER_$label" | tail -1 | cut -d: -f1)
      handled_line=$(printf '%s\n' "$pane" | grep -Fn "MONITOR_HANDLED_${label}_ONE" | tail -1 | cut -d: -f1)
      geometry_gap=$((handled_line - captain_line))
      [ "$geometry_gap" -eq 2 ] \
        || fail "Pi follow-up $label case consumed $geometry_gap rows between neighboring assistant text instead of the two-row visible-only geometry"
    else
      assert_contains "$pane" "MONITOR_${label}_ONE" "Pi follow-up $label case lost the Calm-off operational user row"
      if [ "$expected_notifications" -eq 2 ]; then
        assert_contains "$pane" "MONITOR_${label}_TWO" "Pi follow-up $label case lost the adjacent Calm-off operational user row"
      fi
    fi

    node - "$session_file" "$label" "$expected_notifications" <<'JS' \
      || fail "Pi follow-up $label persisted the wrong turn or input semantics"
const fs = require("node:fs");
const [file, label, expectedRaw] = process.argv.slice(2);
const expected = Number(expectedRaw);
const entries = fs.readFileSync(file, "utf8").trim().split("\n").map(JSON.parse);
const text = (content) => typeof content === "string"
  ? content
  : (content ?? []).filter((item) => item.type === "text").map((item) => item.text).join("\n");
const captainPrompt = `CAPTAIN_PROMPT_${label}`;
const captainAnswer = `CAPTAIN_ANSWER_${label}`;
const handled = expected === 2
  ? `MONITOR_HANDLED_${label}_ONE_TWO`
  : `MONITOR_HANDLED_${label}_ONE`;
const expectedOperationalTexts = Array.from({ length: expected }, (_, index) => {
  const suffix = index === 0 ? "ONE" : "TWO";
  return label === "exact_watcher" && suffix === "ONE"
    ? "\u2063FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: signal: /home/fixture/github/kunchenguid/firstmate/state/oss-triage-t4.status\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned."
    : label === "legacy_away" && suffix === "ONE"
      ? "\u2063Supervisor escalate (LEGACY_AWAY_E2E)"
      : `\u2063FIRSTMATE_OP: v1 watcher: MONITOR_${label}_${suffix}`;
});
const matching = entries.filter((entry) => {
  const entryText = entry.type === "message"
    ? text(entry.message.content)
    : entry.type === "custom_message"
      ? text(entry.content)
      : "";
  return entryText.includes(label) || expectedOperationalTexts.includes(entryText);
});
const userEntries = matching.filter((entry) => entry.type === "message" && entry.message.role === "user");
const customEntries = matching.filter((entry) => entry.type === "custom_message");
const assistantEntries = matching.filter((entry) => entry.type === "message" && entry.message.role === "assistant");
const assistantText = assistantEntries.map((entry) => text(entry.message.content));
if (customEntries.length !== 0) throw new Error(`operational input was rerouted: ${JSON.stringify(customEntries)}`);
if (userEntries.length !== expected + 1) throw new Error(`expected ${expected + 1} user inputs, found ${userEntries.length}`);
if (text(userEntries[0].message.content) !== captainPrompt) throw new Error("genuine captain prompt changed");
for (let index = 1; index <= expected; index += 1) {
  const exact = expectedOperationalTexts[index - 1];
  if (text(userEntries[index].message.content) !== exact) throw new Error(`operational origin changed: ${text(userEntries[index].message.content)}`);
}
if (assistantText.filter((value) => value === captainAnswer).length !== 1) {
  throw new Error(`captain answer count changed: ${JSON.stringify(assistantText)}`);
}
if (assistantText.filter((value) => value === handled).length !== 1) {
  throw new Error(`monitor processing count changed: ${JSON.stringify(assistantText)}`);
}
if (assistantEntries.length !== 2) throw new Error(`expected one captain and one processing turn, found ${assistantEntries.length}`);
const positions = matching.map((entry) => entries.indexOf(entry));
if (positions.some((position, index) => index > 0 && position <= positions[index - 1])) {
  throw new Error(`turn ordering changed: ${positions.join(",")}`);
}
JS

    if [ "$calm_state" = on ] || [ "$calm_state" = off ]; then
      [ "$(cat "$home/config/calm")" = "$calm_state" ] \
        || fail "Pi follow-up $label case changed the persisted Calm choice"
    elif [ "$calm_state" = default ]; then
      [ ! -e "$home/config/calm" ] \
        || fail "Pi follow-up $label case persisted a default Calm choice without a toggle"
    fi
    tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" -l '/quit'
    tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" Enter
    sleep 0.2
    tmux -L "$TMUX_SOCKET" kill-session -t "$TMUX_SESSION" 2>/dev/null || true
  }

  replay_exact_case() {
    tmux -L "$TMUX_SOCKET" kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    printf '%s\n' on >"$home/config/calm"
    tmux -L "$TMUX_SOCKET" new-session -d -s "$TMUX_SESSION" -x 160 -y 36 \
      "cd '$project' && env FM_HOME='$home' PI_CODING_AGENT_DIR='$config' FM_OPERATIONAL_INPUT_SCRIPT='$OPERATIONAL_INPUT' PI_OFFLINE=1 pi --approve --no-context-files --no-skills --no-prompt-templates --no-extensions -e ./.pi/extensions/fm-calm.ts -e ./followup-e2e.ts --session '$exact_session'; rc=\$?; printf '\nPI_EXIT=%s\n' \"\$rc\"; sleep 20"
    i=0
    while [ "$i" -lt 120 ]; do
      pane=$(tmux -L "$TMUX_SOCKET" capture-pane -p -t "$TMUX_SESSION" -S - 2>/dev/null || true)
      printf '%s\n' "$pane" | grep -Fq 'MONITOR_HANDLED_exact_watcher_ONE' && break
      sleep 0.05
      i=$((i + 1))
    done
    assert_contains "$pane" "CAPTAIN_PROMPT_exact_watcher" "Pi restart lost the genuine captain prompt"
    assert_contains "$pane" "MONITOR_HANDLED_exact_watcher_ONE" "Pi restart lost the operational processing response"
    assert_not_contains "$pane" "FIRSTMATE WATCHER WAKE: signal: /home/fixture/github/kunchenguid/firstmate/state/oss-triage-t4.status" \
      "Pi restart replayed the Calm-hidden exact watcher row"
    captain_line=$(printf '%s\n' "$pane" | grep -Fn 'CAPTAIN_ANSWER_exact_watcher' | tail -1 | cut -d: -f1)
    handled_line=$(printf '%s\n' "$pane" | grep -Fn 'MONITOR_HANDLED_exact_watcher_ONE' | tail -1 | cut -d: -f1)
    geometry_gap=$((handled_line - captain_line))
    [ "$geometry_gap" -eq 2 ] \
      || fail "Pi restart replay consumed $geometry_gap rows between neighboring assistant text"
    node - "$exact_session" <<'JS' || fail "Pi restart replay changed exact watcher persistence"
const fs = require("node:fs");
const entries = fs.readFileSync(process.argv[2], "utf8").trim().split("\n").map(JSON.parse);
const text = (content) => typeof content === "string"
  ? content
  : (content ?? []).filter((item) => item.type === "text").map((item) => item.text).join("");
const exact = "\u2063FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: signal: /home/fixture/github/kunchenguid/firstmate/state/oss-triage-t4.status\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.";
const users = entries.filter((entry) => entry.type === "message" && entry.message.role === "user" && text(entry.message.content) === exact);
const responses = entries.filter((entry) => entry.type === "message" && entry.message.role === "assistant" && text(entry.message.content) === "MONITOR_HANDLED_exact_watcher_ONE");
if (users.length !== 1 || responses.length !== 1) {
  throw new Error(`restart changed exactly-once entries: users=${users.length} responses=${responses.length}`);
}
JS
    tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" -l '/quit'
    tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" Enter
    sleep 0.2
    tmux -L "$TMUX_SOCKET" kill-session -t "$TMUX_SESSION" 2>/dev/null || true
  }

  run_followup_case loaded-on on loaded_on 1
  run_followup_case exact-watcher on exact_watcher 1
  exact_session=$session_file
  replay_exact_case
  run_followup_case legacy-away on legacy_away 1
  run_followup_case loaded-off off loaded_off 1
  run_followup_case loaded-default default loaded_default 1
  run_followup_case extension-absent absent absent 1
  run_followup_case adjacent on adjacent 2 '' adjacent
  run_followup_case restart-before on restart_before 1
  local restart_session=$session_file
  run_followup_case restart-after on restart_after 1 "$restart_session"
  pass "Pi operational follow-up E2E processes exact user-role notifications once while Calm on and the absent default hide current and adjacent rows, explicit off renders them, and restart preserves semantics"
}

test_hidden_block_geometry_e2e() {
  local project home config sessions session_file snapshot expanded_snapshot calm_off_snapshot restarted_snapshot
  local version skill_line final_line gap i hash_before hash_after
  if ! command -v pi >/dev/null 2>&1 || ! command -v tmux >/dev/null 2>&1; then
    echo "skip: pi or tmux not found for Pi Calm hidden-block geometry E2E"
    return 0
  fi
  version=$(pi --version 2>/dev/null || true)
  require_pi_compat_version "$version" "Pi Calm hidden-block geometry E2E"

  project="$TMP_ROOT/geometry-project"
  home="$TMP_ROOT/geometry-home"
  config="$TMP_ROOT/geometry-config"
  sessions="$TMP_ROOT/geometry-sessions"
  snapshot="$TMP_ROOT/geometry-calm-on.txt"
  expanded_snapshot="$TMP_ROOT/geometry-expanded.txt"
  calm_off_snapshot="$TMP_ROOT/geometry-calm-off.txt"
  restarted_snapshot="$TMP_ROOT/geometry-restarted.txt"
  mkdir -p \
    "$project/.agents/skills/ahoy" \
    "$project/.pi/extensions/lib" \
    "$home/config" \
    "$config/home" \
    "$sessions"
  fm_git_init_commit "$project"
  cp "$EXT" "$project/.pi/extensions/fm-calm.ts"
  cp "$ASSISTANT_LAYOUT" "$project/.pi/extensions/lib/fm-calm-assistant-layout.ts"
  cp "$OPERATIONAL_USER_LAYOUT" "$project/.pi/extensions/lib/fm-calm-operational-user-layout.ts"
  cp "$COMPATIBILITY" "$project/.pi/extensions/lib/fm-calm-compatibility.ts"
  cp "$VISIBILITY" "$project/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$PI_OPERATIONAL_INPUT" "$project/.pi/extensions/lib/fm-operational-input.ts"
  printf '%s\n' on >"$home/config/calm"
  printf '%s\n' '{"hideThinkingBlock":true,"terminal":{"clearOnShrink":false}}' >"$config/settings.json"
  printf '%s\n' 'tool result one' >"$project/probe-one.txt"
  printf '%s\n' 'tool result two' >"$project/probe-two.txt"
  cat >"$project/.agents/skills/ahoy/SKILL.md" <<'MD'
---
name: ahoy
description: Deterministic Calm hidden-block geometry probe.
---

# Ahoy

Read both probe files, then return the final response.
MD
  cat >"$project/geometry-provider.ts" <<'TS'
import {
  createFauxCore,
  fauxAssistantMessage,
  fauxThinking,
  fauxText,
  fauxToolCall,
} from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI): void {
  const faux = createFauxCore({
    api: "calm-geometry-e2e-api",
    provider: "calm-geometry-e2e",
    models: [{
      id: "deterministic",
      name: "Calm hidden-block geometry E2E",
      reasoning: true,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 4096,
      maxTokens: 128,
    }],
    tokenSize: { min: 1, max: 1 },
  });
  faux.setResponses([
    fauxAssistantMessage([
      fauxThinking("CALM_GEOMETRY_THINKING_ONE"),
      fauxToolCall("read", { path: "probe-one.txt" }, { id: "calm_geometry_read_one" }),
    ], { stopReason: "toolUse" }),
    fauxAssistantMessage([
      fauxThinking("CALM_GEOMETRY_THINKING_TWO"),
      fauxToolCall("read", { path: "probe-two.txt" }, { id: "calm_geometry_read_two" }),
    ], { stopReason: "toolUse" }),
    fauxAssistantMessage([
      fauxThinking("CALM_GEOMETRY_FINAL_THINKING"),
      fauxText("CALM_GEOMETRY_FINAL\n\n- visible row one\n- visible row two"),
    ]),
  ]);
  pi.registerProvider("calm-geometry-e2e", {
    baseUrl: "http://127.0.0.1/unused",
    apiKey: "test-only",
    api: faux.api,
    models: faux.models,
    streamSimple: faux.streamSimple,
  });
  pi.registerCommand("calm-geometry-e2e", {
    description: "Select the deterministic Calm hidden-block geometry model.",
    handler: async (_args, ctx) => {
      const model = ctx.modelRegistry.find("calm-geometry-e2e", "deterministic");
      if (!model || !(await pi.setModel(model))) {
        throw new Error("Calm hidden-block geometry model unavailable");
      }
    },
  });
}
TS

  start_geometry_pi() {
    local session_arg=$1
    tmux -L "$TMUX_SOCKET" kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    tmux -L "$TMUX_SOCKET" new-session -d -s "$TMUX_SESSION" -x 100 -y 44 \
      "cd '$project' && env HOME='$config/home' FM_HOME='$home' PI_CODING_AGENT_DIR='$config' PI_OFFLINE=1 pi --approve --no-context-files --no-prompt-templates --no-extensions -e ./.pi/extensions/fm-calm.ts -e ./geometry-provider.ts $session_arg; rc=\$?; printf '\nPI_EXIT=%s\n' \"\$rc\"; sleep 20"
  }

  capture_geometry_viewport() {
    local file=$1
    tmux -L "$TMUX_SOCKET" capture-pane -p -t "$TMUX_SESSION" >"$file" 2>/dev/null
  }

  wait_for_geometry_text() {
    local file=$1 text=$2 attempt=0
    while [ "$attempt" -lt 120 ]; do
      capture_geometry_viewport "$file" || true
      grep -Fq "$text" "$file" 2>/dev/null && return 0
      sleep 0.05
      attempt=$((attempt + 1))
    done
    return 1
  }

  assert_geometry_gap() {
    local file=$1 label=$2
    skill_line=$(grep -n -m1 '\[skill\] ahoy' "$file" | cut -d: -f1)
    final_line=$(grep -n -m1 'CALM_GEOMETRY_FINAL' "$file" | cut -d: -f1)
    [ -n "$skill_line" ] && [ -n "$final_line" ] \
      || fail "$label did not render the collapsed skill row and final assistant response"
    gap=$((final_line - skill_line - 1))
    [ "$gap" -eq 2 ] \
      || fail "$label left $gap rows between the collapsed skill row and final response instead of the two standard visible-row separators"
  }

  start_geometry_pi "--session-dir '$sessions'"
  wait_for_geometry_text "$snapshot" "geometry-provider.ts" \
    || fail "Pi Calm hidden-block geometry E2E did not reach the ready composer"
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" -l '/calm-geometry-e2e'
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" Enter
  sleep 0.1
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" -l '/skill:ahoy'
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" Enter
  wait_for_geometry_text "$snapshot" "visible row two" \
    || fail "Pi Calm hidden-block geometry E2E did not complete the /skill:ahoy turn"
  i=0
  while [ "$i" -lt 120 ]; do
    capture_geometry_viewport "$snapshot"
    tail -12 "$snapshot" | grep -Fq "Working..." || break
    sleep 0.05
    i=$((i + 1))
  done
  assert_contains "$(cat "$snapshot")" "[skill] ahoy" "Calm hid the collapsed skill header"
  assert_contains "$(cat "$snapshot")" "CALM_GEOMETRY_FINAL" "Calm hid the final assistant response"
  assert_not_contains "$(cat "$snapshot")" "Thinking..." "Calm left a collapsed thinking label visible"
  assert_not_contains "$(cat "$snapshot")" "probe-one.txt" "Calm left a tool-call row visible"
  assert_not_contains "$(cat "$snapshot")" "tool result one" "Calm left a tool-result row visible"
  assert_geometry_gap "$snapshot" "completed native Calm /skill:ahoy turn"

  session_file=$(find "$sessions" -type f -name '*.jsonl' -exec grep -l 'CALM_GEOMETRY_FINAL' {} + 2>/dev/null | head -1 || true)
  [ -n "$session_file" ] || fail "Pi Calm hidden-block geometry E2E did not persist its session"
  hash_before=$(shasum -a 256 "$session_file" | awk '{print $1}')
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" C-o
  wait_for_geometry_text "$expanded_snapshot" "tool result one" \
    || fail "Ctrl+O did not restore the complete stock tool result while Calm remained on"
  assert_contains "$(cat "$expanded_snapshot")" "probe-one.txt" "Ctrl+O did not restore the complete stock tool call while Calm remained on"
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" C-o
  i=0
  while [ "$i" -lt 120 ]; do
    capture_geometry_viewport "$snapshot"
    if ! grep -Fq "probe-one.txt" "$snapshot" && ! grep -Fq "tool result one" "$snapshot"; then
      break
    fi
    sleep 0.05
    i=$((i + 1))
  done
  assert_not_contains "$(cat "$snapshot")" "probe-one.txt" "a second Ctrl+O did not collapse the stock tool call"
  assert_not_contains "$(cat "$snapshot")" "tool result one" "a second Ctrl+O did not collapse the stock tool result"
  hash_after=$(shasum -a 256 "$session_file" | awk '{print $1}')
  [ "$hash_before" = "$hash_after" ] || fail "Ctrl+O re-executed work or changed persisted evidence"

  for width in 80 160; do
    tmux -L "$TMUX_SOCKET" resize-window -t "$TMUX_SESSION" -x "$width" -y 44
    wait_for_geometry_text "$snapshot" "CALM_GEOMETRY_FINAL" \
      || fail "Calm lost the final response at width $width"
    assert_not_contains "$(cat "$snapshot")" "probe-one.txt" "Calm restored a collapsed tool row at width $width"
  done
  tmux -L "$TMUX_SOCKET" resize-window -t "$TMUX_SESSION" -x 100 -y 44

  grep -Fq 'CALM_GEOMETRY_THINKING_ONE' "$session_file" \
    || fail "Calm removed hidden thinking from persisted history"
  grep -Fq 'tool result one' "$session_file" \
    || fail "Calm removed hidden tool results from persisted history"

  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" C-t
  wait_for_geometry_text "$expanded_snapshot" "CALM_GEOMETRY_THINKING_ONE" \
    || fail "thinking expansion did not restore Calm-hidden reasoning"
  assert_not_contains "$(cat "$expanded_snapshot")" "probe-one.txt" "thinking expansion restored Calm-hidden tool rows"
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" C-t
  i=0
  while [ "$i" -lt 120 ]; do
    capture_geometry_viewport "$snapshot"
    grep -Fq "CALM_GEOMETRY_THINKING_ONE" "$snapshot" || break
    sleep 0.05
    i=$((i + 1))
  done
  assert_not_contains "$(cat "$snapshot")" "CALM_GEOMETRY_THINKING_ONE" "collapsing thinking restored hidden-row output"
  assert_geometry_gap "$snapshot" "re-collapsed native Calm transcript"

  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" -l '/calm'
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" Enter
  wait_for_geometry_text "$calm_off_snapshot" "probe-one.txt" \
    || fail "turning Calm off did not restore the tool-call row"
  assert_contains "$(cat "$calm_off_snapshot")" "Thinking..." "turning Calm off did not restore collapsed thinking labels"
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" -l '/calm'
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" Enter
  i=0
  while [ "$i" -lt 120 ]; do
    capture_geometry_viewport "$snapshot"
    if ! grep -Fq "probe-one.txt" "$snapshot" && ! grep -Fq "Thinking..." "$snapshot"; then
      break
    fi
    sleep 0.05
    i=$((i + 1))
  done
  assert_geometry_gap "$snapshot" "Calm redraw of existing transcript"

  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" -l '/quit'
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" Enter
  sleep 0.2
  tmux -L "$TMUX_SOCKET" kill-session -t "$TMUX_SESSION" 2>/dev/null || true
  start_geometry_pi "--session '$session_file'"
  wait_for_geometry_text "$restarted_snapshot" "visible row two" \
    || fail "Pi did not restore the Calm hidden-block geometry session"
  assert_not_contains "$(cat "$restarted_snapshot")" "Thinking..." "restart restored a collapsed thinking label under Calm"
  assert_not_contains "$(cat "$restarted_snapshot")" "probe-one.txt" "restart restored a tool-call row under Calm"
  assert_geometry_gap "$restarted_snapshot" "restarted native Calm transcript"
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" -l '/quit'
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" Enter
  sleep 0.2
  tmux -L "$TMUX_SOCKET" kill-session -t "$TMUX_SESSION" 2>/dev/null || true
  pass "Pi Calm native /skill:ahoy geometry keeps collapsed thinking and successful tools at zero height across 80, 100, and 160 columns while Ctrl+O restores stock evidence without re-execution"
}

test_interactive_terminal_e2e() {
  local project config home session_file export_file export_dom default_snapshot expanded_snapshot hidden_snapshot active_before_snapshot active_hidden_snapshot export_snapshot restored_snapshot working_snapshot working_response_snapshot restarted_snapshot resumed_restored_snapshot hash_before hash_after now version chrome chrome_pid chrome_wait active_wait active_screen_wait
  if ! command -v pi >/dev/null 2>&1 || ! command -v tmux >/dev/null 2>&1; then
    echo "skip: pi or tmux not found for Pi calm interactive E2E"
    return 0
  fi
  version=$(pi --version 2>/dev/null || true)
  require_pi_compat_version "$version" "Pi calm interactive E2E"

  project="$TMP_ROOT/e2e-project"
  config="$TMP_ROOT/e2e-config"
  home="$TMP_ROOT/e2e-home"
  session_file="$TMP_ROOT/calm-session.jsonl"
  export_file="$TMP_ROOT/calm-export.html"
  export_dom="$TMP_ROOT/calm-export-dom.html"
  default_snapshot="$TMP_ROOT/default.txt"
  expanded_snapshot="$TMP_ROOT/expanded.txt"
  hidden_snapshot="$TMP_ROOT/hidden.txt"
  active_before_snapshot="$TMP_ROOT/active-before.txt"
  active_hidden_snapshot="$TMP_ROOT/active-hidden.txt"
  export_snapshot="$TMP_ROOT/export.txt"
  restored_snapshot="$TMP_ROOT/restored.txt"
  working_snapshot="$TMP_ROOT/working.txt"
  working_response_snapshot="$TMP_ROOT/working-response.txt"
  restarted_snapshot="$TMP_ROOT/restarted.txt"
  resumed_restored_snapshot="$TMP_ROOT/resumed-restored.txt"
  mkdir -p "$project/.pi/extensions/lib" "$project/bin" "$project/state" "$config" "$home/config"
  fm_git_init_commit "$project"
  : > "$project/AGENTS.md"
  cp "$EXT" "$project/.pi/extensions/fm-calm.ts"
  cp "$ASSISTANT_LAYOUT" "$project/.pi/extensions/lib/fm-calm-assistant-layout.ts"
  cp "$OPERATIONAL_USER_LAYOUT" "$project/.pi/extensions/lib/fm-calm-operational-user-layout.ts"
  cp "$COMPATIBILITY" "$project/.pi/extensions/lib/fm-calm-compatibility.ts"
  cp "$VISIBILITY" "$project/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$project/.pi/extensions/lib/fm-operational-input.ts"
  cp "$WATCH_EXT" "$project/.pi/extensions/fm-primary-pi-watch.ts"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$project/.pi/extensions/fm-primary-turnend-guard.ts"
  cp \
    "$ROOT/bin/fm-sessionstart-nudge.sh" \
    "$ROOT/bin/fm-primary-scope-lib.sh" \
    "$ROOT/bin/fm-gate-refuse-lib.sh" \
    "$ROOT/bin/fm-operational-input.sh" \
    "$project/bin/"
  chmod +x "$project/bin/"*.sh
  cat >"$project/.pi/extensions/fm-calm-e2e-inject.ts" <<'TS'
import {
  type AssistantMessage,
  createAssistantMessageEventStream,
} from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.ts";

export default function (pi: ExtensionAPI): void {
  pi.registerProvider("calm-e2e", {
    baseUrl: "http://127.0.0.1/unused",
    apiKey: "test-only",
    api: "calm-e2e-api",
    models: [
      {
        id: "delayed",
        name: "Delayed Calm working-row fixture",
        reasoning: false,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 4096,
        maxTokens: 128,
      },
      {
        id: "operational-error",
        name: "Calm gapless operational-row fixture",
        reasoning: false,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 4096,
        maxTokens: 128,
      },
    ],
    streamSimple(model, _context, options) {
      const stream = createAssistantMessageEventStream();
      const output: AssistantMessage = {
        role: "assistant",
        content: [],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: {
          input: 0,
          output: 0,
          cacheRead: 0,
          cacheWrite: 0,
          totalTokens: 0,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
        },
        stopReason: "stop",
        timestamp: Date.now(),
      };
      void (async () => {
        if (model.id === "operational-error") {
          await new Promise((resolve) => setTimeout(resolve, 25));
          output.stopReason = "error";
          output.errorMessage = "CALM_OPERATIONAL_E2E_ERROR";
          stream.push({ type: "error", reason: "error", error: output });
          stream.end();
          return;
        }
        await new Promise((resolve) => setTimeout(resolve, 1500));
        if (options?.signal?.aborted) {
          output.stopReason = "aborted";
          stream.push({ type: "error", reason: "aborted", error: output });
          stream.end();
          return;
        }
        stream.push({ type: "start", partial: output });
        const block = { type: "text" as const, text: "" };
        output.content.push(block);
        stream.push({ type: "text_start", contentIndex: 0, partial: output });
        block.text = "CALM_WORKING_E2E_RESPONSE";
        stream.push({ type: "text_delta", contentIndex: 0, delta: block.text, partial: output });
        stream.push({ type: "text_end", contentIndex: 0, content: block.text, partial: output });
        stream.push({ type: "done", reason: "stop", message: output });
        stream.end();
      })();
      return stream;
    },
  });

  pi.registerCommand("calm-diagnostic-e2e", {
    description: "Add the Calm transient diagnostic fixture.",
    handler: async (_args, ctx) => {
      ctx.ui.notify("CALM_TRANSIENT_DIAGNOSTIC", "warning");
    },
  });
  pi.registerCommand("calm-inject-e2e", {
    description: "Inject one current Calm operational kind.",
    handler: async (args, ctx) => {
      const fixtures = new Map([
        ["watcher", "CURRENT_WATCHER_E2E /tmp/active-probe.status"],
        ["turn-end-guard", "CURRENT_TURN_END_E2E"],
        ["away-supervisor", "CURRENT_AWAY_E2E"],
        ["from-firstmate", "corr=0123456789abcdef CURRENT_FROM_FIRSTMATE_E2E"],
        ["launch-brief", "CURRENT_LAUNCH_BRIEF_E2E"],
      ] as const);
      const kind = args.trim() as Parameters<typeof encodeFirstmateOperationalInput>[0];
      const body = fixtures.get(kind);
      if (!body) throw new Error(`unknown current operational kind: ${kind}`);
      const model = ctx.modelRegistry.find("calm-e2e", "operational-error");
      if (!model || !(await pi.setModel(model))) {
        throw new Error("could not select the deterministic Calm operational-error model");
      }
      await pi.sendUserMessage(encodeFirstmateOperationalInput(kind, body), {
        deliverAs: "followUp",
      });
    },
  });
  pi.registerCommand("calm-working-e2e", {
    description: "Start the delayed native Working-row fixture.",
    handler: async (_args, ctx) => {
      const model = ctx.modelRegistry.find("calm-e2e", "delayed");
      if (!model || !(await pi.setModel(model))) {
        throw new Error("could not select the deterministic Calm E2E model");
      }
      await pi.sendUserMessage("CALM_WORKING_E2E_PROMPT");
    },
  });
}
TS
  printf '%s\n' '{"tui.input.submit":"alt+s"}' >"$config/keybindings.json"
  printf '%s\n' '{"hideThinkingBlock":true}' >"$config/settings.json"
  now=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
  cat >"$session_file" <<JSON
{"type":"session","version":3,"id":"11111111-1111-4111-8111-111111111111","timestamp":"$now","cwd":"$project"}
{"type":"message","id":"a0000001","parentId":null,"timestamp":"$now","message":{"role":"user","content":[{"type":"text","text":"Show a deterministic tool example."}],"timestamp":1}}
{"type":"message","id":"a0000002","parentId":"a0000001","timestamp":"$now","message":{"role":"assistant","content":[{"type":"thinking","thinking":"first internal reasoning block"},{"type":"text","text":"I will run one command."},{"type":"toolCall","id":"call_calm_e2e","name":"bash","arguments":{"command":"printf 'CALM_E2E_OUTPUT\\n'"}}],"api":"anthropic-messages","provider":"anthropic","model":"claude-sonnet-4-5","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"toolUse","timestamp":2}}
{"type":"message","id":"a0000003","parentId":"a0000002","timestamp":"$now","message":{"role":"toolResult","toolCallId":"call_calm_e2e","toolName":"bash","content":[{"type":"text","text":"CALM_E2E_OUTPUT"}],"details":{},"isError":false,"timestamp":3}}
{"type":"message","id":"a0000004","parentId":"a0000003","timestamp":"$now","message":{"role":"assistant","content":[{"type":"thinking","thinking":"second internal reasoning block"},{"type":"toolCall","id":"call_grep_e2e","name":"grep","arguments":{"pattern":"CALM_EXPORT_GREP","path":"."}},{"type":"toolCall","id":"call_find_e2e","name":"find","arguments":{"pattern":"CALM_EXPORT_FIND*","path":"."}}],"api":"anthropic-messages","provider":"anthropic","model":"claude-sonnet-4-5","usage":{"input":2,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":3,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"toolUse","timestamp":4}}
{"type":"message","id":"a0000005","parentId":"a0000004","timestamp":"$now","message":{"role":"toolResult","toolCallId":"call_grep_e2e","toolName":"grep","content":[{"type":"text","text":"sample.txt:1:CALM_EXPORT_GREP"}],"details":{},"isError":false,"timestamp":5}}
{"type":"message","id":"a0000006","parentId":"a0000005","timestamp":"$now","message":{"role":"toolResult","toolCallId":"call_find_e2e","toolName":"find","content":[{"type":"text","text":"CALM_EXPORT_FIND.txt"}],"details":{},"isError":false,"timestamp":6}}
{"type":"message","id":"a0000007","parentId":"a0000006","timestamp":"$now","message":{"role":"assistant","content":[{"type":"thinking","thinking":"third internal reasoning block"},{"type":"toolCall","id":"call_watch_e2e","name":"fm_watch_arm_pi","arguments":{}}],"api":"anthropic-messages","provider":"anthropic","model":"claude-sonnet-4-5","usage":{"input":2,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":3,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"toolUse","timestamp":7}}
{"type":"message","id":"a0000008","parentId":"a0000007","timestamp":"$now","message":{"role":"toolResult","toolCallId":"call_watch_e2e","toolName":"fm_watch_arm_pi","content":[{"type":"text","text":"watcher: started Pi extension arm child 1"}],"details":{"ok":true,"message":"watcher: started Pi extension arm child 1"},"isError":false,"timestamp":8}}
{"type":"custom","id":"a0000009","parentId":"a0000008","timestamp":"$now","customType":"firstmate-synthetic-input-presentation","data":{"content":"FIRSTMATE WATCHER WAKE: signal: /tmp/probe.status\\n\\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.","kind":"watcher"}}
{"type":"custom_message","id":"a0000010","parentId":"a0000009","timestamp":"$now","customType":"firstmate-synthetic-input","content":"FIRSTMATE WATCHER WAKE: signal: /tmp/probe.status\\n\\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.","display":false,"details":{"kind":"watcher"}}
{"type":"message","id":"a0000011","parentId":"a0000010","timestamp":"$now","message":{"role":"user","content":[{"type":"text","text":"FIRSTMATE WATCHER WAKE: can you explain this phrase?"}],"timestamp":11}}
{"type":"message","id":"a0000012","parentId":"a0000011","timestamp":"$now","message":{"role":"user","content":[{"type":"text","text":"Captain quote: \u2063FIRSTMATE_OP: v1 watcher: QUOTED_CURRENT_NEAR_MISS"}],"timestamp":12}}
{"type":"message","id":"a0000013","parentId":"a0000012","timestamp":"$now","message":{"role":"user","content":[{"type":"text","text":"FIRSTMATE_OP: v1 watcher: ASCII_ONLY_NEAR_MISS"}],"timestamp":13}}
{"type":"message","id":"a0000014","parentId":"a0000013","timestamp":"$now","message":{"role":"user","content":[{"type":"text","text":"Ordinary captain text before \u2063FIRSTMATE_OP: v1 watcher: EMBEDDED_CURRENT_NEAR_MISS"}],"timestamp":14}}
{"type":"message","id":"a0000015","parentId":"a0000014","timestamp":"$now","message":{"role":"user","content":[{"type":"text","text":"\u2063ordinary captain text after unrelated separator"}],"timestamp":15}}
{"type":"message","id":"a0000016","parentId":"a0000015","timestamp":"$now","message":{"role":"assistant","content":[{"type":"text","text":"The deterministic tool example is complete."}],"api":"anthropic-messages","provider":"anthropic","model":"claude-sonnet-4-5","usage":{"input":2,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":3,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"stop","timestamp":16}}
JSON

  printf '%s\n' off >"$home/config/calm"
  tmux -L "$TMUX_SOCKET" new-session -d -s "$TMUX_SESSION" -x 180 -y 44 \
    "cd '$project' && env FM_HOME='$home' PI_CODING_AGENT_DIR='$config' FM_OPERATIONAL_INPUT_SCRIPT='$OPERATIONAL_INPUT' PI_OFFLINE=1 pi --approve --no-skills --no-prompt-templates --no-context-files --session '$session_file'; rc=\$?; printf '\nPI_EXIT=%s\n' \"\$rc\"; sleep 30"
  wait_for_text "$default_snapshot" "The deterministic tool example is complete." \
    || fail "Pi calm E2E did not reach the restored session transcript"
  assert_contains "$(cat "$default_snapshot")" "CALM_E2E_OUTPUT" "an explicit Calm off preference did not restore stock tool output"
  assert_contains "$(cat "$default_snapshot")" "fm_watch_arm_pi" "Calm-off transcript did not show the Firstmate watcher tool"
  assert_contains "$(cat "$default_snapshot")" "FIRSTMATE WATCHER WAKE: signal: /tmp/probe.status" "Calm-off transcript did not show the synthetic Firstmate presentation row"
  assert_contains "$(cat "$default_snapshot")" "Thinking..." "reasoning fixture did not render Pi's collapsed thinking label"
  assert_contains "$(cat "$default_snapshot")" "fm-calm.ts" "project-local Pi calm extension did not auto-load"
  # shellcheck disable=SC2016 # Backticks are literal prompt markup.
  assert_not_contains "$(cat "$default_snapshot")" 'Run `bin/fm-session-start.sh` now' \
    "native session-start context unexpectedly rendered while Calm was off"
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" C-o
  wait_for_text "$expanded_snapshot" "escape to interrupt" \
    || fail "Ctrl+O did not retain Pi's ordinary startup and tool expansion behavior"
  assert_contains "$(cat "$expanded_snapshot")" "CALM_E2E_OUTPUT" "ordinary Ctrl+O expansion hid tool activity while calm mode was off"
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" C-o
  sleep 0.1

  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" -l "/calm"
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" M-s
  active_screen_wait=0
  while [ "$active_screen_wait" -lt 120 ]; do
    tmux -L "$TMUX_SOCKET" capture-pane -p -t "$TMUX_SESSION" >"$hidden_snapshot"
    if ! grep -Fq "CALM_E2E_OUTPUT" "$hidden_snapshot" &&
      ! grep -Fq "/calm" "$hidden_snapshot"; then
      break
    fi
    sleep 0.05
    active_screen_wait=$((active_screen_wait + 1))
  done
  assert_not_contains "$(cat "$hidden_snapshot")" "CALM_E2E_OUTPUT" "/calm left tool result output in the transcript"
  assert_not_contains "$(cat "$hidden_snapshot")" "calm transcript" "/calm added a persistent Calm status row"
  [ "$(cat "$home/config/calm")" = on ] || fail "/calm did not persist its active choice"
  assert_not_contains "$(cat "$hidden_snapshot")" "CALM_EXPORT_GREP" "/calm left the grep row in the transcript"
  assert_not_contains "$(cat "$hidden_snapshot")" "CALM_EXPORT_FIND" "/calm left the find row in the transcript"
  assert_not_contains "$(cat "$hidden_snapshot")" "\$ printf" "/calm left the tool-call row in the transcript"
  assert_not_contains "$(cat "$hidden_snapshot")" "Thinking..." "/calm left collapsed thinking labels in the transcript"
  assert_not_contains "$(cat "$hidden_snapshot")" "fm_watch_arm_pi" "/calm left the Firstmate watcher tool call shell in the transcript"
  assert_not_contains "$(cat "$hidden_snapshot")" "watcher: started Pi extension arm child" "/calm left the Firstmate watcher tool result in the transcript"
  assert_not_contains "$(cat "$hidden_snapshot")" "FIRSTMATE WATCHER WAKE: signal: /tmp/probe.status" "/calm left a synthetic Firstmate user-role presentation in the transcript"
  assert_not_contains "$(cat "$hidden_snapshot")" "Tool activity is hidden where supported" "/calm appended its own command-status row"
  assert_contains "$(cat "$hidden_snapshot")" "Show a deterministic tool example." "/calm removed a genuine user prompt"
  assert_contains "$(cat "$hidden_snapshot")" "FIRSTMATE WATCHER WAKE: can you explain this phrase?" "/calm hid a genuine near-miss user prompt"
  for near_miss in \
    QUOTED_CURRENT_NEAR_MISS \
    ASCII_ONLY_NEAR_MISS \
    EMBEDDED_CURRENT_NEAR_MISS \
    "ordinary captain text after unrelated separator"
  do
    assert_contains "$(cat "$hidden_snapshot")" "$near_miss" "/calm hid the genuine operational near miss $near_miss"
  done
  assert_contains "$(cat "$hidden_snapshot")" "I will run one command." "/calm removed assistant conversation before a tool"
  assert_contains "$(cat "$hidden_snapshot")" "The deterministic tool example is complete." "/calm removed assistant conversation after a tool"

  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" -l "/calm-diagnostic-e2e"
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" M-s
  active_screen_wait=0
  while [ "$active_screen_wait" -lt 120 ]; do
    tmux -L "$TMUX_SOCKET" capture-pane -p -t "$TMUX_SESSION" >"$active_before_snapshot"
    if grep -Fq "Warning: CALM_TRANSIENT_DIAGNOSTIC" "$active_before_snapshot" &&
      ! grep -Fq "/calm-diagnostic-e2e" "$active_before_snapshot"; then
      break
    fi
    sleep 0.05
    active_screen_wait=$((active_screen_wait + 1))
  done
  assert_contains "$(cat "$active_before_snapshot")" "Warning: CALM_TRANSIENT_DIAGNOSTIC" "transient diagnostic fixture was not shown"
  assert_not_contains "$(cat "$active_before_snapshot")" "/calm-diagnostic-e2e" "transient diagnostic command did not leave the editor"

  for fixture in \
    "watcher|CURRENT_WATCHER_E2E" \
    "turn-end-guard|CURRENT_TURN_END_E2E" \
    "away-supervisor|CURRENT_AWAY_E2E" \
    "from-firstmate|CURRENT_FROM_FIRSTMATE_E2E" \
    "launch-brief|CURRENT_LAUNCH_BRIEF_E2E"
  do
    kind=${fixture%%|*}
    needle=${fixture#*|}
    tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" -l "/calm-inject-e2e $kind"
    tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" M-s
    active_wait=0
    while ! grep -F '"role":"user"' "$session_file" 2>/dev/null |
      grep -Fq "$needle" && [ "$active_wait" -lt 120 ]; do
      sleep 0.05
      active_wait=$((active_wait + 1))
    done
    grep -F '"role":"user"' "$session_file" |
      grep -Fq "$needle" \
      || fail "current operational kind $kind did not retain user-role delivery while Calm was active"
    sleep 0.1
  done
  node - "$session_file" <<'JS' || fail "native Pi did not preserve every exact current operational kind"
const fs = require("node:fs");
const entries = fs.readFileSync(process.argv[2], "utf8").trim().split("\n").map(JSON.parse);
const nativeSessionStart = entries.find((entry) =>
  entry.type === "custom_message" &&
  entry.customType === "firstmate-sessionstart-nudge"
);
if (
  !nativeSessionStart ||
  nativeSessionStart.display !== false ||
  nativeSessionStart.details?.kind !== "session-start" ||
  !nativeSessionStart.content?.startsWith("\u2063FIRSTMATE_OP: v1 session-start: ")
) {
  throw new Error(`native session-start provenance was not retained: ${JSON.stringify(nativeSessionStart)}`);
}
const expected = new Map([
  ["CURRENT_WATCHER_E2E", "watcher"],
  ["CURRENT_TURN_END_E2E", "turn-end-guard"],
  ["CURRENT_AWAY_E2E", "away-supervisor"],
  ["CURRENT_FROM_FIRSTMATE_E2E", "from-firstmate"],
  ["CURRENT_LAUNCH_BRIEF_E2E", "launch-brief"],
]);
const current = entries.filter((entry) =>
  entry.type === "message" &&
  entry.message?.role === "user" &&
  [...expected.keys()].some((needle) => JSON.stringify(entry.message.content).includes(needle))
);
if (current.length !== expected.size) {
  throw new Error(`expected ${expected.size} user-role current entries, found ${current.length}: ${JSON.stringify(current)}`);
}
for (const [needle, kind] of expected) {
  const entry = current.find((candidate) => JSON.stringify(candidate.message.content).includes(needle));
  const text = entry?.message.content?.find((item) => item.type === "text")?.text;
  const exactEnvelope = kind === "from-firstmate"
    ? text?.startsWith("[fm-from-firstmate]\u2063corr=0123456789abcdef ")
    : text?.startsWith(`\u2063FIRSTMATE_OP: v1 ${kind}: `);
  if (!entry || !exactEnvelope) {
    throw new Error(`expected exact user-role ${needle} as ${kind}, found ${JSON.stringify(entry)}`);
  }
}
JS
  active_screen_wait=0
  while [ "$active_screen_wait" -lt 120 ]; do
    tmux -L "$TMUX_SOCKET" capture-pane -p -t "$TMUX_SESSION" >"$active_hidden_snapshot"
    if grep -Fq " Error:" "$active_hidden_snapshot" &&
      ! grep -Fq "/calm-inject-e2e" "$active_hidden_snapshot"; then
      break
    fi
    sleep 0.05
    active_screen_wait=$((active_screen_wait + 1))
  done
  assert_not_contains "$(cat "$active_hidden_snapshot")" "/calm-inject-e2e" "synthetic lifecycle command did not leave the editor"
  # shellcheck disable=SC2016 # Backticks are literal prompt markup.
  assert_not_contains "$(cat "$active_hidden_snapshot")" 'Run `bin/fm-session-start.sh` now' \
    "Calm showed the native session-start operational input"
  for hidden in \
    CURRENT_WATCHER_E2E \
    CURRENT_TURN_END_E2E \
    CURRENT_AWAY_E2E \
    CURRENT_FROM_FIRSTMATE_E2E \
    CURRENT_LAUNCH_BRIEF_E2E
  do
    assert_not_contains "$(cat "$active_hidden_snapshot")" "$hidden" "Calm rendered operational input $hidden"
  done
  assert_contains "$(cat "$active_hidden_snapshot")" "Warning: CALM_TRANSIENT_DIAGNOSTIC" "operational arrival lost its preceding transient diagnostic"
  assert_contains "$(cat "$active_hidden_snapshot")" " Error:" "operational delivery did not produce a transient provider diagnostic"
  hash_before=$(shasum -a 256 "$session_file" | awk '{print $1}')

  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" -l "/export $export_file"
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" M-s
  wait_for_text "$export_snapshot" "Session exported to: $export_file" \
    || fail "/export did not complete while calm mode was on"
  node - "$export_file" <<'JS' || fail "calm-mode HTML export lost tool data or persisted synthetic provenance"
const html = require("node:fs").readFileSync(process.argv[2], "utf8");
const match = html.match(/<script id="session-data" type="application\/json">([^<]+)<\/script>/);
if (!match) process.exit(1);
const session = JSON.parse(Buffer.from(match[1], "base64").toString("utf8"));
for (const id of ["call_grep_e2e", "call_find_e2e", "call_watch_e2e"]) {
  const rendered = session.renderedTools?.[id];
  if (!rendered?.callHtml || !rendered?.resultHtmlExpanded) process.exit(1);
}
const entries = session.session?.entries ?? session.entries ?? [];
const serialized = JSON.stringify(entries);
if (!serialized.includes("firstmate-synthetic-input") || !serialized.includes("/tmp/probe.status")) process.exit(1);
const synthetic = entries.find((entry) => entry.type === "custom_message" && entry.customType === "firstmate-synthetic-input");
if (!synthetic || synthetic.display) process.exit(1);
JS
  chrome=$(find_chrome) || fail "Chrome or Chromium is required for rendered export DOM assertions"
  "$chrome" \
    --headless=new \
    --disable-gpu \
    --no-sandbox \
    --user-data-dir="$TMP_ROOT/chrome-profile" \
    --virtual-time-budget=2000 \
    --dump-dom \
    "file://$export_file" >"$export_dom" 2>/dev/null &
  chrome_pid=$!
  chrome_wait=0
  while kill -0 "$chrome_pid" 2>/dev/null && [ "$chrome_wait" -lt 100 ]; do
    grep -Fq '</html>' "$export_dom" 2>/dev/null && break
    sleep 0.1
    chrome_wait=$((chrome_wait + 1))
  done
  kill "$chrome_pid" 2>/dev/null || true
  wait "$chrome_pid" 2>/dev/null || true
  grep -Fq '</html>' "$export_dom" 2>/dev/null \
    || fail "could not render calm-mode HTML export DOM"
  node - "$export_dom" <<'JS' || fail "rendered export DOM violated the Calm conversation boundary"
const dom = require("node:fs").readFileSync(process.argv[2], "utf8");
const messages = dom.match(/<div id="messages">([\s\S]*?)<\/main>/)?.[1];
const tree = dom.match(/<div[^>]*id="tree-container"[^>]*>([\s\S]*?)<div[^>]*id="tree-status"/)?.[1];
if (!messages || !tree) process.exit(1);
if (!/<div class="user-message"[^>]*>[\s\S]*Show a deterministic tool example\./.test(messages)) process.exit(1);
if (!/<div class="assistant-message"[^>]*>[\s\S]*The deterministic tool example is complete\./.test(messages)) process.exit(1);
if (messages.includes('<div class="hook-message"')) process.exit(1);
if (messages.includes("[firstmate-synthetic-input]")) process.exit(1);
for (const current of ["CURRENT_WATCHER_E2E", "CURRENT_TURN_END_E2E", "CURRENT_AWAY_E2E", "CURRENT_FROM_FIRSTMATE_E2E", "CURRENT_LAUNCH_BRIEF_E2E"]) {
  if (!messages.includes(current)) process.exit(1);
}
if (!tree.includes("firstmate-synthetic-input") || !tree.includes("/tmp/probe.status")) process.exit(1);
JS

  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" -l "/calm"
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" M-s
  wait_for_text "$restored_snapshot" "CALM_E2E_OUTPUT" \
    || fail "second /calm did not restore tool result output"
  wait_for_text "$restored_snapshot" "/tmp/active-probe.status" \
    || fail "second /calm did not restore a synthetic row received while Calm was active"
  assert_contains "$(cat "$restored_snapshot")" "fm_watch_arm_pi" "second /calm did not restore the Firstmate watcher tool shell"
  assert_contains "$(cat "$restored_snapshot")" "FIRSTMATE WATCHER WAKE: signal: /tmp/probe.status" "second /calm did not restore the synthetic Firstmate user row"
  for restored in \
    CURRENT_WATCHER_E2E \
    CURRENT_TURN_END_E2E \
    CURRENT_AWAY_E2E \
    CURRENT_FROM_FIRSTMATE_E2E \
    CURRENT_LAUNCH_BRIEF_E2E
  do
    assert_contains "$(cat "$restored_snapshot")" "$restored" "second /calm did not restore current operational kind $restored"
  done
  assert_contains "$(cat "$restored_snapshot")" "Warning: CALM_TRANSIENT_DIAGNOSTIC" "second /calm dropped a transient diagnostic"
  assert_contains "$(cat "$restored_snapshot")" " Error:" "second /calm dropped the synthetic delivery diagnostic"
  assert_not_contains "$(cat "$restored_snapshot")" "Navigated to selected point" "second /calm added a navigation status row"
  assert_contains "$(cat "$restored_snapshot")" "Thinking..." "second /calm did not restore Pi's collapsed thinking labels"
  hash_after=$(shasum -a 256 "$session_file" | awk '{print $1}')
  [ "$hash_before" = "$hash_after" ] || fail "/calm changed the persisted session or context data"

  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" -l "/calm"
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" M-s
  active_screen_wait=0
  while [ "$active_screen_wait" -lt 120 ]; do
    tmux -L "$TMUX_SOCKET" capture-pane -p -t "$TMUX_SESSION" >"$working_snapshot"
    if ! grep -Fq "CALM_E2E_OUTPUT" "$working_snapshot" &&
      ! grep -Fq "/calm" "$working_snapshot"; then
      break
    fi
    sleep 0.05
    active_screen_wait=$((active_screen_wait + 1))
  done
  [ "$(cat "$home/config/calm")" = on ] || fail "third /calm did not persist the active choice"

  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" -l "/calm-working-e2e"
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" M-s
  active_screen_wait=0
  while [ "$active_screen_wait" -lt 120 ]; do
    tmux -L "$TMUX_SOCKET" capture-pane -p -t "$TMUX_SESSION" >"$working_snapshot"
    if grep -Fq "Working..." "$working_snapshot"; then
      break
    fi
    sleep 0.025
    active_screen_wait=$((active_screen_wait + 1))
  done
  assert_contains "$(cat "$working_snapshot")" "Working..." "Calm hid Pi's built-in Working row during a real provider wait"
  assert_not_contains "$(cat "$working_snapshot")" "calm transcript" "the real provider wait showed a persistent Calm status row"
  assert_not_contains "$(cat "$working_snapshot")" "FIRSTMATE WATCHER WAKE: signal: /tmp/probe.status" "the real provider wait restored a hidden operational row"
  wait_for_text "$working_response_snapshot" "CALM_WORKING_E2E_RESPONSE" \
    || fail "the deterministic provider did not settle after proving Pi's Working row"

  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" -l "/quit"
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" M-s
  wait_for_text "$working_response_snapshot" "PI_EXIT=0" \
    || fail "Pi did not exit cleanly before the Calm persistence restart"
  tmux -L "$TMUX_SOCKET" kill-session -t "$TMUX_SESSION" 2>/dev/null || true

  tmux -L "$TMUX_SOCKET" new-session -d -s "$TMUX_SESSION" -x 180 -y 44 \
    "cd '$project' && env FM_HOME='$home' PI_CODING_AGENT_DIR='$config' FM_OPERATIONAL_INPUT_SCRIPT='$OPERATIONAL_INPUT' PI_OFFLINE=1 pi --approve --no-skills --no-prompt-templates --no-context-files --session '$session_file'; rc=\$?; printf '\nPI_EXIT=%s\n' \"\$rc\"; sleep 30"
  wait_for_text "$restarted_snapshot" "CALM_WORKING_E2E_RESPONSE" \
    || fail "Pi did not restore the persisted session after restart"
  assert_not_contains "$(cat "$restarted_snapshot")" "CALM_E2E_OUTPUT" "restart/resume reset Calm and restored a tool row"
  assert_not_contains "$(cat "$restarted_snapshot")" "fm_watch_arm_pi" "restart/resume reset Calm and restored the Firstmate watcher tool"
  assert_not_contains "$(cat "$restarted_snapshot")" "FIRSTMATE WATCHER WAKE: signal: /tmp/probe.status" "restart/resume reset Calm and restored a legacy presentation row"
  for hidden in \
    CURRENT_WATCHER_E2E \
    CURRENT_TURN_END_E2E \
    CURRENT_AWAY_E2E \
    CURRENT_FROM_FIRSTMATE_E2E \
    CURRENT_LAUNCH_BRIEF_E2E
  do
    assert_not_contains "$(cat "$restarted_snapshot")" "$hidden" "restart/resume rendered operational input $hidden"
  done
  assert_not_contains "$(cat "$restarted_snapshot")" "calm transcript" "restart/resume added a persistent Calm status row"
  assert_contains "$(cat "$restarted_snapshot")" "CALM_WORKING_E2E_PROMPT" "restart/resume removed a genuine user prompt"
  assert_contains "$(cat "$restarted_snapshot")" "CALM_WORKING_E2E_RESPONSE" "restart/resume removed a genuine assistant response"
  [ "$(cat "$home/config/calm")" = on ] || fail "restart/resume changed the persisted active choice"

  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" -l "/calm"
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" M-s
  wait_for_text "$resumed_restored_snapshot" "CALM_E2E_OUTPUT" \
    || fail "/calm after restart did not restore ordinary transcript rows"
  [ "$(cat "$home/config/calm")" = off ] || fail "/calm after restart did not persist the inactive choice"
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" -l "/quit"
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" M-s
  pass "Pi Calm native E2E keeps Working and captain turns visible, honors explicit off, hides exact operational rows when enabled, survives restart, and preserves export evidence"
}

test_captains_call_shortcut_input_contract
test_captains_call_shortcut_real_pi_expansion
test_static_contract
test_home_resolution
test_compatibility_fallback
test_rendering_and_session_lifecycle
test_operational_followup_turn_e2e
test_hidden_block_geometry_e2e
test_interactive_terminal_e2e
