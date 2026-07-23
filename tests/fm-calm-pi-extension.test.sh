#!/usr/bin/env bash
# Focused rendering, lifecycle, persistence, and interactive TUI checks for /calm.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-calm-pi-extension)
EXT="$ROOT/.pi/extensions/fm-calm.ts"
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

test_static_contract() {
  local text
  assert_present "$EXT" "tracked Pi calm extension is missing"
  text=$(cat "$EXT")
  assert_contains "$text" 'pi.registerCommand("calm"' "Pi calm extension does not register /calm"
  assert_contains "$text" 'pi.on("session_start"' "Pi calm extension does not reset on every session start"
  assert_contains "$text" 'calm = false' "Pi calm extension does not default to visible tool activity"
  assert_contains "$text" 'ctx.ui.setToolsExpanded(ctx.ui.getToolsExpanded())' "Pi calm extension does not redraw existing rows while preserving Ctrl+O state"
  assert_contains "$text" 'ctx.ui.onTerminalInput' "Pi calm extension does not scope hiding to interactive rendering"
  assert_contains "$text" 'getKeybindings().matches(data, "tui.input.submit")' "Pi calm export boundary ignores the active submit keybinding"
  assert_contains "$text" 'input !== "/share"' "Pi calm export boundary does not cover /share"
  assert_contains "$text" 'renderShell: "self"' "Pi calm extension cannot remove the complete tool shell"
  assert_contains "$text" 'built-in read images and custom/third-party tool rows stay visible' "Pi calm command description does not disclose both visibility boundaries"
  assert_contains "$text" 'built-in read images and custom/third-party tool rows remain visible' "Pi calm enabled status does not disclose both visibility boundaries"
  assert_not_contains "$text" 'appendEntry' "Pi calm extension persists its session-local toggle"
  assert_not_contains "$text" 'sendMessage' "Pi calm extension changes model context"
  for name in Read Bash Edit Write Grep Find Ls; do
    assert_contains "$text" "create${name}ToolDefinition" "Pi calm extension does not wrap the $name built-in"
  done
  pass "Pi calm extension has the default-off, redraw, seven-built-in text-row, and explicit limitation contract"
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
  [ "$version" = "0.80.10" ] || fail "Pi calm compatibility assumptions require Pi 0.80.10, found $version"

  fixture="$TMP_ROOT/renderer"
  mkdir -p "$fixture/node_modules/@earendil-works"
  cp "$EXT" "$fixture/fm-calm.ts"
  ln -s "$PI_PACKAGE_DIR" "$fixture/node_modules/@earendil-works/pi-coding-agent"
  ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$fixture/node_modules/@earendil-works/pi-tui"
  ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$fixture/node_modules/typebox"
  printf '%s\n' '{"type":"module"}' >"$fixture/package.json"

  out=$(cd "$fixture" && EXT="$fixture/fm-calm.ts" PI_PACKAGE_DIR="$PI_PACKAGE_DIR" node --input-type=module 2>&1 <<'JS'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const packageRoot = process.env.PI_PACKAGE_DIR;
const [{ ToolExecutionComponent }, { initTheme, theme }, { Text, getKeybindings, setCapabilities }, { createToolHtmlRenderer }] = await Promise.all([
  import(pathToFileURL(`${packageRoot}/dist/modes/interactive/components/tool-execution.js`).href),
  import(pathToFileURL(`${packageRoot}/dist/modes/interactive/theme/theme.js`).href),
  import(pathToFileURL(`${packageRoot}/node_modules/@earendil-works/pi-tui/dist/index.js`).href),
  import(pathToFileURL(`${packageRoot}/dist/core/export-html/tool-renderer.js`).href),
]);
initTheme("dark");
setCapabilities({ images: null, trueColor: true, hyperlinks: false });

const tools = [];
const handlers = new Map();
let calmCommand;
const pi = {
  appendEntry() {
    throw new Error("calm mode must not persist extension state");
  },
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand(name, command) {
    if (name === "calm") calmCommand = command;
  },
  registerTool(tool) {
    tools.push(tool);
  },
};
const extension = await import(`${pathToFileURL(process.env.EXT).href}?test=${Date.now()}`);
extension.default(pi);

const names = tools.map((tool) => tool.name);
const expectedNames = ["read", "bash", "edit", "write", "grep", "find", "ls"];
if (JSON.stringify(names) !== JSON.stringify(expectedNames)) {
  throw new Error(`unexpected wrapped built-ins: ${names.join(",")}`);
}
if (!calmCommand || !handlers.has("session_start")) {
  throw new Error("calm command or session lifecycle handler was not registered");
}
if (
  calmCommand.description !==
  "Toggle built-in call and text-result rows; built-in read images and custom/third-party tool rows stay visible."
) {
  throw new Error(`calm command description does not disclose both visibility boundaries: ${calmCommand.description}`);
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
let notification = "";
let editorText = "";
let terminalInputHandler;
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
    setToolsExpanded(value) {
      if (value !== expanded) throw new Error("/calm changed the ordinary Ctrl+O expansion state");
      for (const row of rows) row.actual.setExpanded(value);
      customRow.setExpanded(value);
      imageRow.setExpanded(value);
    },
    notify(message) {
      notification = message;
    },
  },
};

await handlers.get("session_start")({ reason: "startup" }, commandContext);
await calmCommand.handler("", commandContext);
async function assertStockHtmlRendering(command, submitData) {
  editorText = command;
  terminalInputHandler(submitData);
  const htmlRenderer = createToolHtmlRenderer({
    getToolDefinition: (name) => tools.find((tool) => tool.name === name),
    theme,
    cwd: process.cwd(),
  });
  for (const [name, args, result] of cases.filter(([toolName]) => toolName === "grep" || toolName === "find")) {
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
  throw new Error("calm mode incorrectly claimed or applied custom-tool coverage");
}
if (
  notification !==
  "Tool activity is hidden where supported; built-in read images and custom/third-party tool rows remain visible."
) {
  throw new Error(`unexpected hidden status: ${notification}`);
}
if (JSON.stringify(sessionEntries) !== entriesBefore) {
  throw new Error("calm mode changed session entries or model context");
}

// The image-boundary probe changed terminal capabilities after the original
// stock renders, so refresh the stock comparison under the same capabilities.
for (const { baseline } of rows) baseline.setExpanded(expanded);
await calmCommand.handler("", commandContext);
for (const { name, baseline, actual } of rows) {
  if (JSON.stringify(actual.render(100)) !== JSON.stringify(baseline.render(100))) {
    throw new Error(`${name} did not restore the expanded standard renderer`);
  }
}
if (JSON.stringify(imageRow.render(100)) !== JSON.stringify(imageVisibleBefore)) {
  throw new Error("built-in read image row did not restore its ordinary call shell and image output");
}
if (notification !== "Tool activity is visible.") {
  throw new Error(`unexpected visible status: ${notification}`);
}

for (const reason of ["startup", "new", "resume", "fork", "reload"]) {
  await calmCommand.handler("", commandContext);
  await handlers.get("session_start")({ reason }, commandContext);
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
  pass "Pi calm preserves standard rendering and execution, hides seven built-in call and text rows, keeps read images and custom rows visible, and resets per session"
}

test_interactive_terminal_e2e() {
  local project config session_file export_file default_snapshot expanded_snapshot hidden_snapshot export_snapshot restored_snapshot hash_before hash_after now version
  if ! command -v pi >/dev/null 2>&1 || ! command -v tmux >/dev/null 2>&1; then
    echo "skip: pi or tmux not found for Pi calm interactive E2E"
    return 0
  fi
  version=$(pi --version 2>/dev/null || true)
  [ "$version" = "0.80.10" ] || fail "Pi calm interactive E2E requires Pi 0.80.10, found $version"

  project="$TMP_ROOT/e2e-project"
  config="$TMP_ROOT/e2e-config"
  session_file="$TMP_ROOT/calm-session.jsonl"
  export_file="$TMP_ROOT/calm-export.html"
  default_snapshot="$TMP_ROOT/default.txt"
  expanded_snapshot="$TMP_ROOT/expanded.txt"
  hidden_snapshot="$TMP_ROOT/hidden.txt"
  export_snapshot="$TMP_ROOT/export.txt"
  restored_snapshot="$TMP_ROOT/restored.txt"
  mkdir -p "$project/.pi/extensions" "$config"
  cp "$EXT" "$project/.pi/extensions/fm-calm.ts"
  printf '%s\n' '{"tui.input.submit":"alt+s"}' >"$config/keybindings.json"
  now=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
  cat >"$session_file" <<JSON
{"type":"session","version":3,"id":"11111111-1111-4111-8111-111111111111","timestamp":"$now","cwd":"$project"}
{"type":"message","id":"a0000001","parentId":null,"timestamp":"$now","message":{"role":"user","content":[{"type":"text","text":"Show a deterministic tool example."}],"timestamp":1}}
{"type":"message","id":"a0000002","parentId":"a0000001","timestamp":"$now","message":{"role":"assistant","content":[{"type":"text","text":"I will run one command."},{"type":"toolCall","id":"call_calm_e2e","name":"bash","arguments":{"command":"printf 'CALM_E2E_OUTPUT\\n'"}}],"api":"anthropic-messages","provider":"anthropic","model":"claude-sonnet-4-5","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"toolUse","timestamp":2}}
{"type":"message","id":"a0000003","parentId":"a0000002","timestamp":"$now","message":{"role":"toolResult","toolCallId":"call_calm_e2e","toolName":"bash","content":[{"type":"text","text":"CALM_E2E_OUTPUT"}],"details":{},"isError":false,"timestamp":3}}
{"type":"message","id":"a0000004","parentId":"a0000003","timestamp":"$now","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_grep_e2e","name":"grep","arguments":{"pattern":"CALM_EXPORT_GREP","path":"."}},{"type":"toolCall","id":"call_find_e2e","name":"find","arguments":{"pattern":"CALM_EXPORT_FIND*","path":"."}}],"api":"anthropic-messages","provider":"anthropic","model":"claude-sonnet-4-5","usage":{"input":2,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":3,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"toolUse","timestamp":4}}
{"type":"message","id":"a0000005","parentId":"a0000004","timestamp":"$now","message":{"role":"toolResult","toolCallId":"call_grep_e2e","toolName":"grep","content":[{"type":"text","text":"sample.txt:1:CALM_EXPORT_GREP"}],"details":{},"isError":false,"timestamp":5}}
{"type":"message","id":"a0000006","parentId":"a0000005","timestamp":"$now","message":{"role":"toolResult","toolCallId":"call_find_e2e","toolName":"find","content":[{"type":"text","text":"CALM_EXPORT_FIND.txt"}],"details":{},"isError":false,"timestamp":6}}
{"type":"message","id":"a0000007","parentId":"a0000006","timestamp":"$now","message":{"role":"assistant","content":[{"type":"text","text":"The deterministic tool example is complete."}],"api":"anthropic-messages","provider":"anthropic","model":"claude-sonnet-4-5","usage":{"input":2,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":3,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"stop","timestamp":7}}
JSON

  tmux -L "$TMUX_SOCKET" new-session -d -s "$TMUX_SESSION" -x 120 -y 40 \
    "cd '$project' && env PI_CODING_AGENT_DIR='$config' PI_OFFLINE=1 pi --approve --no-skills --no-prompt-templates --no-context-files --session '$session_file'; rc=\$?; printf '\nPI_EXIT=%s\n' \"\$rc\"; sleep 30"
  wait_for_text "$default_snapshot" "The deterministic tool example is complete." \
    || fail "Pi calm E2E did not reach the restored session transcript"
  assert_contains "$(cat "$default_snapshot")" "CALM_E2E_OUTPUT" "calm mode was not off by default"
  assert_contains "$(cat "$default_snapshot")" "fm-calm.ts" "project-local Pi calm extension did not auto-load"
  hash_before=$(shasum -a 256 "$session_file" | awk '{print $1}')

  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" C-o
  wait_for_text "$expanded_snapshot" "escape to interrupt" \
    || fail "Ctrl+O did not retain Pi's ordinary startup and tool expansion behavior"
  assert_contains "$(cat "$expanded_snapshot")" "CALM_E2E_OUTPUT" "ordinary Ctrl+O expansion hid tool activity while calm mode was off"

  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" -l "/calm"
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" M-s
  wait_for_text "$hidden_snapshot" "Tool activity is hidden where supported; built-in read images and custom/third-party tool rows remain visible." \
    || fail "/calm did not report hidden tool activity and its visibility boundaries"
  assert_not_contains "$(cat "$hidden_snapshot")" "CALM_E2E_OUTPUT" "/calm left tool result output in the transcript"
  assert_not_contains "$(cat "$hidden_snapshot")" "CALM_EXPORT_GREP" "/calm left the grep row in the transcript"
  assert_not_contains "$(cat "$hidden_snapshot")" "CALM_EXPORT_FIND" "/calm left the find row in the transcript"
  assert_not_contains "$(cat "$hidden_snapshot")" "\$ printf" "/calm left the tool-call row in the transcript"
  assert_contains "$(cat "$hidden_snapshot")" "I will run one command." "/calm removed assistant conversation before a tool"
  assert_contains "$(cat "$hidden_snapshot")" "The deterministic tool example is complete." "/calm removed assistant conversation after a tool"

  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" -l "/export $export_file"
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" M-s
  wait_for_text "$export_snapshot" "Session exported to: $export_file" \
    || fail "/export did not complete while calm mode was on"
  node - "$export_file" <<'JS' || fail "calm-mode HTML export omitted grep or find rendering"
const html = require("node:fs").readFileSync(process.argv[2], "utf8");
const match = html.match(/<script id="session-data" type="application\/json">([^<]+)<\/script>/);
if (!match) process.exit(1);
const session = JSON.parse(Buffer.from(match[1], "base64").toString("utf8"));
for (const id of ["call_grep_e2e", "call_find_e2e"]) {
  const rendered = session.renderedTools?.[id];
  if (!rendered?.callHtml || !rendered?.resultHtmlExpanded) process.exit(1);
}
JS

  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" -l "/calm"
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" M-s
  wait_for_text "$restored_snapshot" "Tool activity is visible." \
    || fail "second /calm did not report visible tool activity"
  assert_contains "$(cat "$restored_snapshot")" "CALM_E2E_OUTPUT" "second /calm did not restore tool result output"
  assert_contains "$(cat "$restored_snapshot")" "escape to interrupt" "/calm changed the active Ctrl+O expansion state"

  hash_after=$(shasum -a 256 "$session_file" | awk '{print $1}')
  [ "$hash_before" = "$hash_after" ] || fail "/calm changed the persisted session or context data"
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" -l "/quit"
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" M-s
  pass "Pi calm text-row E2E proves remapped-submit export, default-off, hide, redraw restoration, unchanged persistence, and ordinary Ctrl+O behavior"
}

test_static_contract
test_rendering_and_session_lifecycle
test_interactive_terminal_e2e
