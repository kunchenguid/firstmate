#!/usr/bin/env bash
# Focused rendering, lifecycle, persistence, and interactive TUI checks for /calm.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-calm-pi-extension)
EXT="$ROOT/.pi/extensions/fm-calm.ts"
VISIBILITY="$ROOT/.pi/extensions/lib/fm-calm-visibility.ts"
WATCH_EXT="$ROOT/.pi/extensions/fm-primary-pi-watch.ts"
OPERATIONAL_INPUT="$ROOT/bin/fm-operational-input.sh"
PI_OPERATIONAL_INPUT="$ROOT/.pi/extensions/lib/fm-operational-input.ts"
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
TMUX_SOCKET="fm-calm-$$"
TMUX_SESSION="fm-calm-e2e"

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

test_static_contract() {
  local text visibility watch operational
  assert_present "$EXT" "tracked Pi calm extension is missing"
  assert_present "$VISIBILITY" "tracked Pi calm visibility policy is missing"
  text=$(cat "$EXT")
  visibility=$(cat "$VISIBILITY")
  watch=$(cat "$WATCH_EXT")
  operational=$(cat "$PI_OPERATIONAL_INPUT")
  assert_contains "$text" 'pi.registerCommand("calm"' "Pi calm extension does not register /calm"
  assert_contains "$text" 'pi.on("session_start"' "Pi calm extension does not reset on every session start"
  assert_contains "$text" 'setCalmPresentation(false)' "Pi calm extension does not default to stock transcript presentation"
  assert_contains "$text" 'ctx.ui.setToolsExpanded(!expanded)' "Pi calm extension does not redraw existing custom entries"
  assert_contains "$text" 'ctx.ui.setToolsExpanded(expanded)' "Pi calm extension does not restore Ctrl+O state after redraw"
  assert_not_contains "$text" 'ctx.navigateTree' "Pi calm extension reconstructs the transcript and drops transient diagnostics"
  assert_contains "$visibility" 'mountingSyntheticPresentation' "Pi calm visibility policy cannot mount entries received while hidden"
  assert_contains "$visibility" 'options.redrawPresentation' "Pi calm synthetic delivery does not retain mounted hidden entries"
  assert_contains "$text" 'ctx.ui.setWorkingVisible(!active)' "Pi calm extension does not hide the live working row"
  assert_contains "$text" 'ctx.ui.setHiddenThinkingLabel(active ? "" : undefined)' "Pi calm extension does not hide collapsed thinking labels"
  assert_contains "$text" 'pi.on("input"' "Pi calm extension does not classify input-origin Firstmate injections"
  assert_contains "$text" 'ctx.ui.onTerminalInput' "Pi calm extension does not scope export rendering to terminal submissions"
  assert_contains "$text" 'getKeybindings().matches(data, "tui.input.submit")' "Pi calm export boundary ignores the active submit keybinding"
  assert_contains "$text" 'input !== "/share"' "Pi calm export boundary does not cover /share"
  assert_contains "$text" 'FIRSTMATE_PI_LAUNCH_BRIEF_ENV' "Pi calm extension does not consume authoritative launch-brief origin"
  assert_contains "$text" 'renderShell: "self"' "Pi calm extension cannot remove complete built-in tool shells"
  assert_contains "$visibility" 'CALM_VISIBLE_CLASSES' "Pi calm policy does not centralize its visibility allowlist"
  assert_contains "$visibility" 'classifyFirstmateSyntheticInput' "Pi calm policy does not centralize synthetic-input classification"
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
  pass "Pi calm extension has one default-off visibility policy, supported redraw controls, and the Firstmate watcher-tool integration"
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
  [ "$version" = "0.81.1" ] || fail "Pi calm compatibility assumptions require Pi 0.81.1, found $version"

  fixture="$TMP_ROOT/renderer"
  mkdir -p "$fixture/home" "$fixture/lib" "$fixture/node_modules/@earendil-works"
  cp "$EXT" "$fixture/fm-calm.ts"
  cp "$VISIBILITY" "$fixture/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$fixture/lib/fm-operational-input.ts"
  cp "$WATCH_EXT" "$fixture/fm-primary-pi-watch.ts"
  ln -s "$PI_PACKAGE_DIR" "$fixture/node_modules/@earendil-works/pi-coding-agent"
  ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$fixture/node_modules/@earendil-works/pi-tui"
  ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$fixture/node_modules/typebox"
  printf '%s\n' '{"type":"module"}' >"$fixture/package.json"

  out=$(cd "$fixture" && EXT="$fixture/fm-calm.ts" WATCH_EXT="$fixture/fm-primary-pi-watch.ts" FM_HOME="$fixture/home" FM_OPERATIONAL_INPUT_SCRIPT="$OPERATIONAL_INPUT" PI_PACKAGE_DIR="$PI_PACKAGE_DIR" node --input-type=module 2>&1 <<'JS'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const packageRoot = process.env.PI_PACKAGE_DIR;
const [{ CustomEntryComponent }, { ToolExecutionComponent }, { initTheme, theme }, { Text, getKeybindings, setCapabilities }, { createToolHtmlRenderer }] = await Promise.all([
  import(pathToFileURL(`${packageRoot}/dist/modes/interactive/components/custom-entry.js`).href),
  import(pathToFileURL(`${packageRoot}/dist/modes/interactive/components/tool-execution.js`).href),
  import(pathToFileURL(`${packageRoot}/dist/modes/interactive/theme/theme.js`).href),
  import(pathToFileURL(`${packageRoot}/node_modules/@earendil-works/pi-tui/dist/index.js`).href),
  import(pathToFileURL(`${packageRoot}/dist/core/export-html/tool-renderer.js`).href),
]);
initTheme("dark");
setCapabilities({ images: null, trueColor: true, hyperlinks: false });
const launchBrief = "You are the persistent secondmate.\nRead the charter and wait.";
writeFileSync("launch-brief.md", `${launchBrief}\n`);
process.env.FM_FIRSTMATE_PI_LAUNCH_BRIEF = `${process.cwd()}/launch-brief.md`;

const tools = [];
const handlers = new Map();
const entryRenderers = new Map();
const appendedEntries = [];
const mountedPresentationComponents = [];
const sentMessages = [];
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
  appendEntry(customType, data) {
    const entry = { customType, data };
    appendedEntries.push(entry);
    const renderer = entryRenderers.get(customType);
    if (!renderer) return;
    const component = new CustomEntryComponent(entry, renderer);
    component.setExpanded(expanded);
    if (component.hasContent()) mountedPresentationComponents.push(component);
  },
  sendMessage(message, options) {
    sentMessages.push({ message, options });
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

const names = tools.map((tool) => tool.name);
const expectedNames = ["read", "bash", "edit", "write", "grep", "find", "ls"];
if (JSON.stringify(names) !== JSON.stringify(expectedNames)) {
  throw new Error(`unexpected wrapped built-ins: ${names.join(",")}`);
}
if (!calmCommand || !handlers.has("session_start") || !handlers.has("input")) {
  throw new Error("calm command, input classifier, or session lifecycle handler was not registered");
}
if (
  calmCommand.description !==
  "Toggle Firstmate's supported conversation-only transcript presentation."
) {
  throw new Error(`unexpected calm command description: ${calmCommand.description}`);
}

for (const itemClass of visibility.CALM_TRANSCRIPT_CLASSES) {
  const visible = visibility.calmTranscriptClassIsVisible(itemClass);
  const expected = itemClass === "genuine-user-prompt" || itemClass === "genuine-agent-response";
  if (visible !== expected) {
    throw new Error(`Calm allowlist classified ${itemClass} as visible=${visible}`);
  }
}
const watcherBody =
  "FIRSTMATE WATCHER WAKE: signal: /tmp/probe.status\n\n" +
  "Run bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.";
const turnEndBody =
  "TURN WOULD END BLIND - supervision is off. " +
  "The watcher cycle is missing, failed, or unhealthy. " +
  "Follow the harness recovery instruction below before ending the turn.\n\n" +
  "watcher: FAILED - probe";
const currentBodies = new Map([
  ["session-start", "CURRENT_SESSION_START_BODY"],
  ["watcher", watcherBody],
  ["turn-end-guard", turnEndBody],
  ["away-supervisor", "CURRENT_AWAY_BODY"],
  ["from-firstmate", "corr=0123456789abcdef CURRENT_ROUTED_BODY"],
  ["launch-brief", launchBrief],
]);
const positiveSyntheticFixtures = [...currentBodies].map(([kind, body]) => [
  kind,
  visibility.encodeFirstmateOperationalInput(kind, body),
]);
for (const [kind, content] of positiveSyntheticFixtures) {
  if (visibility.classifyFirstmateSyntheticInput(content, "extension") !== kind) {
    throw new Error(`current Firstmate fixture was not classified as ${kind}`);
  }
}
const watcherMessage = positiveSyntheticFixtures.find(([kind]) => kind === "watcher")[1];
const legacyUntyped = `\u2063FIRSTMATE_OP: ${watcherBody}`;
if (visibility.classifyFirstmateSyntheticInput(legacyUntyped, "interactive") !== "legacy-operational") {
  throw new Error("landed untyped FIRSTMATE_OP input was falsely assigned a current subtype");
}
const legacyFixtures = [
  ["session-start", "Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions."],
  ["watcher", watcherBody],
  ["turn-end-guard", turnEndBody],
  ["away-supervisor", "\u2063Supervisor escalate (1 event(s)): done"],
];
for (const [kind, content] of legacyFixtures) {
  if (visibility.classifyFirstmateSyntheticInput(content, "interactive") !== kind) {
    throw new Error(`isolated legacy fixture was not classified as ${kind}`);
  }
}
if (visibility.classifyFirstmateSyntheticInput(launchBrief, "interactive", launchBrief) !== "launch-brief") {
  throw new Error("legacy env-identified Pi launch brief was not classified");
}
if (visibility.classifyFirstmateSyntheticInput(launchBrief, "interactive") !== undefined) {
  throw new Error("unmarked genuine text matching a brief was hidden without its source binding");
}
const nearMissGenuineFixtures = [
  "Run bin/fm-session-start.sh now, exactly once, before executing any other instructions.",
  "FIRSTMATE WATCHER WAKE: can you explain this phrase?",
  "FIRSTMATE WATCHER WAKE: signal: /tmp/probe.status\n\nRun bin/fm-wake-drain.sh when convenient.",
  "TURN WOULD END BLIND - can you make this warning friendlier?",
  "Supervisor escalate (1 event(s)): is this wording clear?",
  "[fm-from-firstmate] inspect this visible label",
  "FIRSTMATE_OP: v1 watcher",
  "\u2063Captain-authored arbitrary invisible-separator text",
  `Captain quote: ${positiveSyntheticFixtures[0][1]}`,
  "Captain quote: Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.",
];
for (const content of nearMissGenuineFixtures) {
  if (visibility.classifyFirstmateSyntheticInput(content, "interactive") !== undefined) {
    throw new Error(`genuine near-miss input was hidden: ${content}`);
  }
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

let expanded = true;
let editorText = "";
let terminalInputHandler;
let workingVisible;
let hiddenThinkingLabel = "unset";
const statuses = new Map();
const sessionEntries = [{ type: "message", message: { role: "toolResult", content: "kept" } }];
const entriesBefore = JSON.stringify(sessionEntries);
const commandContext = {
  sessionManager: { getEntries: () => sessionEntries },
  ui: {
    getEditorText: () => editorText,
    getToolsExpanded: () => expanded,
    onTerminalInput(handler) {
      terminalInputHandler = handler;
      return () => {
        if (terminalInputHandler === handler) terminalInputHandler = undefined;
      };
    },
    setHiddenThinkingLabel(value) {
      hiddenThinkingLabel = value;
    },
    setStatus(key, value) {
      statuses.set(key, value);
    },
    setToolsExpanded(value) {
      expanded = value;
      for (const row of rows) row.actual.setExpanded(value);
      watchActual.setExpanded(value);
      customRow.setExpanded(value);
      imageRow.setExpanded(value);
      for (const component of mountedPresentationComponents) {
        component.setExpanded(value);
      }
    },
    setWorkingVisible(value) {
      workingVisible = value;
    },
  },
};

await handlers.get("session_start")[0]({ reason: "startup" }, commandContext);
if (workingVisible !== true || hiddenThinkingLabel !== undefined) {
  throw new Error("session start did not restore Pi's stock working and thinking presentation");
}
const inputHandler = handlers.get("input")[0];
const launchBriefResult = await inputHandler({
  text: launchBrief,
  images: undefined,
  source: "interactive",
  streamingBehavior: undefined,
}, commandContext);
if (
  launchBriefResult?.action !== "handled" ||
  appendedEntries.length !== 1 ||
  sentMessages.length !== 1 ||
  sentMessages[0].message.details.kind !== "launch-brief" ||
  sentMessages[0].message.content !== launchBrief
) {
  throw new Error("Pi positional launch brief was not consumed through its exact origin path");
}
const repeatedBriefResult = await inputHandler({
  text: launchBrief,
  images: undefined,
  source: "interactive",
  streamingBehavior: undefined,
}, commandContext);
if (
  repeatedBriefResult?.action !== "continue" ||
  appendedEntries.length !== 1 ||
  sentMessages.length !== 1
) {
  throw new Error("consumed launch origin hid a later genuine matching prompt");
}
const syntheticResult = await inputHandler({
  text: watcherMessage,
  images: undefined,
  source: "extension",
  streamingBehavior: "followUp",
}, commandContext);
if (
  syntheticResult?.action !== "handled" ||
  appendedEntries.length !== 2 ||
  sentMessages.length !== 2
) {
  throw new Error("known Firstmate synthetic input was not rerouted through controllable delivery");
}
if (
  sentMessages[1].message.content !== watcherMessage ||
  sentMessages[1].message.display !== false ||
  sentMessages[1].options.triggerTurn !== true ||
  sentMessages[1].options.deliverAs !== "followUp"
) {
  throw new Error("synthetic input delivery or context semantics changed");
}
const presentationRenderer = entryRenderers.get("firstmate-synthetic-input-presentation");
if (!presentationRenderer) throw new Error("synthetic presentation renderer was not registered");
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
  throw new Error("Calm-off synthetic presentation did not use a stock user-message row");
}
const nearMissResult = await inputHandler({
  text: nearMissGenuineFixtures[1],
  images: undefined,
  source: "interactive",
  streamingBehavior: undefined,
}, commandContext);
if (
  nearMissResult?.action !== "continue" ||
  appendedEntries.length !== 2 ||
  sentMessages.length !== 2
) {
  throw new Error("genuine near-miss input was intercepted");
}

await calmCommand.handler("", commandContext);
if (expanded !== true || workingVisible !== false || hiddenThinkingLabel !== "" || statuses.get("firstmate-calm") !== "calm transcript") {
  throw new Error("Calm did not apply its supported working, thinking, and footer presentation controls");
}
presentationComponent.setExpanded(!expanded);
if (presentationComponent.hasContent() || presentationComponent.render(100).length !== 0) {
  throw new Error("Calm left a synthetic Firstmate presentation row or spacer visible");
}
for (const { name, actual } of rows) {
  if (actual.render(100).length !== 0) {
    throw new Error(`${name} was not hidden before export rendering`);
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
if (JSON.stringify(sessionEntries) !== entriesBefore) {
  throw new Error("calm mode changed session entries or model context");
}

const activeWatcherMessage = visibility.encodeFirstmateOperationalInput(
  "watcher",
  "FIRSTMATE WATCHER WAKE: signal: /tmp/active-probe.status\n\n" +
    "Run bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.",
);
const activeSyntheticResult = await inputHandler({
  text: activeWatcherMessage,
  images: undefined,
  source: "extension",
  streamingBehavior: "followUp",
}, commandContext);
if (
  activeSyntheticResult?.action !== "handled" ||
  appendedEntries.length !== 3 ||
  sentMessages.length !== 3
) {
  throw new Error("synthetic input received while Calm was active was not delivered");
}
const activePresentationComponent = new CustomEntryComponent(
  appendedEntries[2],
  presentationRenderer,
);
activePresentationComponent.setExpanded(expanded);
if (
  activePresentationComponent.hasContent() ||
  activePresentationComponent.render(100).length !== 0 ||
  mountedPresentationComponents.length !== 3 ||
  mountedPresentationComponents[2].hasContent() ||
  mountedPresentationComponents[2].render(100).length !== 0
) {
  throw new Error("synthetic input received while Calm was active left a row or blank gap");
}

for (const { baseline } of rows) baseline.setExpanded(expanded);
await calmCommand.handler("", commandContext);
if (
  mountedPresentationComponents.length !== 3 ||
  !mountedPresentationComponents.some((component) =>
    component.render(100).join("\n").includes("/tmp/active-probe.status")
  )
) {
  throw new Error("turning Calm off did not restore the mounted synthetic row received while active");
}
for (const { name, baseline, actual } of rows) {
  if (JSON.stringify(actual.render(100)) !== JSON.stringify(baseline.render(100))) {
    throw new Error(`${name} did not restore the expanded standard renderer`);
  }
}
if (JSON.stringify(imageRow.render(100)) !== JSON.stringify(imageVisibleBefore)) {
  throw new Error("built-in read image row did not restore its ordinary call shell and image output");
}
if (JSON.stringify(watchActual.render(100)) !== JSON.stringify(watchBaseline.render(100))) {
  throw new Error("fm_watch_arm_pi did not restore its stock call/result shell");
}
if (workingVisible !== true || hiddenThinkingLabel !== undefined || statuses.get("firstmate-calm") !== undefined) {
  throw new Error("turning Calm off did not restore stock presentation controls");
}
presentationComponent.setExpanded(expanded);
if (
  !presentationComponent.hasContent() ||
  !presentationComponent.render(100).join("\n").includes("FIRSTMATE WATCHER WAKE")
) {
  throw new Error("turning Calm off did not restore synthetic user-row presentation");
}

for (const reason of ["startup", "new", "resume", "fork", "reload"]) {
  await calmCommand.handler("", commandContext);
  await handlers.get("session_start")[0]({ reason }, commandContext);
  for (const row of rows) row.actual.setExpanded(expanded);
  for (const { name, baseline, actual } of rows) {
    if (JSON.stringify(actual.render(100)) !== JSON.stringify(baseline.render(100))) {
      throw new Error(`${reason} session did not begin with calm mode off for ${name}`);
    }
  }
}

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
  pass "Pi calm centralizes transcript visibility, preserves execution/export data, hides built-ins plus fm_watch_arm_pi and Firstmate injections, and resets per session"
}

test_interactive_terminal_e2e() {
  local project config session_file export_file export_dom default_snapshot expanded_snapshot hidden_snapshot active_before_snapshot active_hidden_snapshot active_hidden_boundary export_snapshot restored_snapshot hash_before hash_after now version chrome chrome_pid chrome_wait active_wait active_screen_wait
  if ! command -v pi >/dev/null 2>&1 || ! command -v tmux >/dev/null 2>&1; then
    echo "skip: pi or tmux not found for Pi calm interactive E2E"
    return 0
  fi
  version=$(pi --version 2>/dev/null || true)
  [ "$version" = "0.81.1" ] || fail "Pi calm interactive E2E requires Pi 0.81.1, found $version"

  project="$TMP_ROOT/e2e-project"
  config="$TMP_ROOT/e2e-config"
  session_file="$TMP_ROOT/calm-session.jsonl"
  export_file="$TMP_ROOT/calm-export.html"
  export_dom="$TMP_ROOT/calm-export-dom.html"
  default_snapshot="$TMP_ROOT/default.txt"
  expanded_snapshot="$TMP_ROOT/expanded.txt"
  hidden_snapshot="$TMP_ROOT/hidden.txt"
  active_before_snapshot="$TMP_ROOT/active-before.txt"
  active_hidden_snapshot="$TMP_ROOT/active-hidden.txt"
  active_hidden_boundary="$TMP_ROOT/active-hidden-boundary.txt"
  export_snapshot="$TMP_ROOT/export.txt"
  restored_snapshot="$TMP_ROOT/restored.txt"
  mkdir -p "$project/.pi/extensions/lib" "$project/bin" "$project/state" "$config"
  fm_git_init_commit "$project"
  : > "$project/AGENTS.md"
  cp "$EXT" "$project/.pi/extensions/fm-calm.ts"
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
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { encodeFirstmateOperationalInput } from "./lib/fm-calm-visibility.ts";

export default function (pi: ExtensionAPI): void {
  pi.registerCommand("calm-diagnostic-e2e", {
    description: "Add the Calm transient diagnostic fixture.",
    handler: async (_args, ctx) => {
      ctx.ui.notify("CALM_TRANSIENT_DIAGNOSTIC", "warning");
    },
  });
  pi.registerCommand("calm-inject-e2e", {
    description: "Inject one current Calm operational kind.",
    handler: async (args) => {
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
      await pi.sendUserMessage(encodeFirstmateOperationalInput(kind, body), {
        deliverAs: "followUp",
      });
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
{"type":"message","id":"a0000012","parentId":"a0000011","timestamp":"$now","message":{"role":"assistant","content":[{"type":"text","text":"The deterministic tool example is complete."}],"api":"anthropic-messages","provider":"anthropic","model":"claude-sonnet-4-5","usage":{"input":2,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":3,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"stop","timestamp":12}}
JSON

  tmux -L "$TMUX_SOCKET" new-session -d -s "$TMUX_SESSION" -x 180 -y 44 \
    "cd '$project' && env PI_CODING_AGENT_DIR='$config' FM_OPERATIONAL_INPUT_SCRIPT='$OPERATIONAL_INPUT' PI_OFFLINE=1 pi --approve --no-skills --no-prompt-templates --no-context-files --session '$session_file'; rc=\$?; printf '\nPI_EXIT=%s\n' \"\$rc\"; sleep 30"
  wait_for_text "$default_snapshot" "The deterministic tool example is complete." \
    || fail "Pi calm E2E did not reach the restored session transcript"
  assert_contains "$(cat "$default_snapshot")" "CALM_E2E_OUTPUT" "calm mode was not off by default"
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

  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" -l "/calm"
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" M-s
  wait_for_text "$hidden_snapshot" "calm transcript" \
    || fail "/calm did not activate its footer status"
  assert_not_contains "$(cat "$hidden_snapshot")" "CALM_E2E_OUTPUT" "/calm left tool result output in the transcript"
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
    while ! grep -Fq "$needle" "$session_file" 2>/dev/null && [ "$active_wait" -lt 120 ]; do
      sleep 0.05
      active_wait=$((active_wait + 1))
    done
    grep -Fq "$needle" "$session_file" \
      || fail "current operational kind $kind was not received while Calm was active"
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
  entry.type === "custom_message" &&
  entry.customType === "firstmate-synthetic-input" &&
  [...expected.keys()].some((needle) => entry.content?.includes(needle))
);
if (current.length !== expected.size) {
  throw new Error(`expected ${expected.size} current entries, found ${current.length}: ${JSON.stringify(current)}`);
}
for (const [needle, kind] of expected) {
  const entry = current.find((candidate) => candidate.content.includes(needle));
  if (!entry || entry.display !== false || entry.details?.kind !== kind) {
    throw new Error(`expected ${needle} as ${kind}, found ${JSON.stringify(entry)}`);
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
    assert_not_contains "$(cat "$active_hidden_snapshot")" "$hidden" "Calm showed current operational kind $hidden"
  done
  assert_contains "$(cat "$active_hidden_snapshot")" "Warning: CALM_TRANSIENT_DIAGNOSTIC" "synthetic arrival lost its preceding transient diagnostic"
  assert_contains "$(cat "$active_hidden_snapshot")" " Error:" "synthetic delivery did not produce a transient provider diagnostic"
  awk '/Warning: CALM_TRANSIENT_DIAGNOSTIC/ { capture = 1 } capture { print } / Error:/ { exit }' \
    "$active_hidden_snapshot" >"$active_hidden_boundary"
  [ "$(wc -l <"$active_hidden_boundary" | tr -d ' ')" -eq 3 ] \
    || fail "Calm left a blank transcript gap between diagnostics around a synthetic row received while active"
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
if (!messages) process.exit(1);
if (!/<div class="user-message"[^>]*>[\s\S]*Show a deterministic tool example\./.test(messages)) process.exit(1);
if (!/<div class="assistant-message"[^>]*>[\s\S]*The deterministic tool example is complete\./.test(messages)) process.exit(1);
if (messages.includes('<div class="hook-message"')) process.exit(1);
if (messages.includes("[firstmate-synthetic-input]")) process.exit(1);
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
  assert_contains "$(cat "$restored_snapshot")" "escape to interrupt" "/calm changed the active Ctrl+O expansion state"

  hash_after=$(shasum -a 256 "$session_file" | awk '{print $1}')
  [ "$hash_before" = "$hash_after" ] || fail "/calm changed the persisted session or context data"
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" -l "/quit"
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" M-s
  pass "Pi calm native E2E shows only genuine prompts and final responses while hiding every exactly typed current operational kind and preserving exports, persistence, and Ctrl+O"
}

test_static_contract
test_rendering_and_session_lifecycle
test_interactive_terminal_e2e
