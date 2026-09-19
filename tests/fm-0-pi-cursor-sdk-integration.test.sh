#!/usr/bin/env bash
# Guard and tool-layout checks for the fork-owned pi-cursor-sdk integration.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-0-pi-cursor-sdk-integration)
EXT="$ROOT/.pi/extensions/fm-0-pi-cursor-sdk-integration.ts"
CALM_EXT="$ROOT/.pi/extensions/fm-calm.ts"
VISIBILITY="$ROOT/.pi/extensions/lib/fm-calm-visibility.ts"
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}

test_static_contract() {
  assert_present "$EXT" "fork-owned Calm cursor-sdk shim is missing"
  local text
  text=$(cat "$EXT")
  assert_contains "$text" 'guardCalmBuiltinRegistration' "shim does not guard Calm built-in registration"
  assert_contains "$text" 'installCalmToolLayout' "shim does not install the tool-row layout adapter"
  assert_contains "$text" 'installCursorLifecycleQuiet' "shim does not install cursor lifecycle quiet"
  assert_contains "$text" 'applyDefaultPiTuningEnv' "shim does not apply default Pi tuning env"
  assert_contains "$text" 'DEFAULT_PI_TUNING_ENV' "shim does not declare default Pi tuning env"
  assert_contains "$text" 'renderShell === "self"' "shim does not recognize Calm built-in wrapper registrations"
  assert_contains "$text" 'isCursorSdkIncompleteOrErrorReplay' "shim does not detect incomplete pi-cursor-sdk replay rows"
  assert_contains "$text" 'cursor-replay-' "integration does not key off cursor-replay tool call ids"
  assert_contains "$text" 'CURSOR_INCOMPLETE_LINE' "integration does not filter incomplete Cursor thinking lines"
  assert_contains "$text" 'isCursorSdkIncompleteOrErrorReplay(instance)' "integration does not hide incomplete replay rows before Calm gating"
  pass "fork-owned pi-cursor-sdk integration keeps upstream Calm untouched"
}

test_guard_and_layout() {
  local fixture out status
  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    echo "skip: node or npm not found for Calm cursor-sdk shim test"
    return 0
  fi
  if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
    echo "skip: installed @earendil-works/pi-coding-agent package not found"
    return 0
  fi
  if [ ! -f "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui/package.json" ]; then
    echo "skip: pi-tui package not found beside pi-coding-agent"
    return 0
  fi
  fixture="$TMP_ROOT/shim"
  mkdir -p "$fixture/lib" "$fixture/node_modules/@earendil-works"
  cp "$EXT" "$fixture/fm-0-pi-cursor-sdk-integration.ts"
  cp "$CALM_EXT" "$fixture/fm-calm.ts"
  cp "$VISIBILITY" "$fixture/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-pi-cursor-calm-assistant-layout.ts" "$fixture/lib/fm-pi-cursor-calm-assistant-layout.ts"
  cp "$ROOT/.pi/extensions/lib/fm-cursor-replay-execute.ts" "$fixture/lib/fm-cursor-replay-execute.ts"
  cp "$ROOT/.pi/extensions/lib/fm-pi-cursor-calm-operational-user-layout.ts" "$fixture/lib/fm-pi-cursor-calm-operational-user-layout.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship.ts" "$fixture/lib/fm-calm-working-ship.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship-sprite.ts" "$fixture/lib/fm-calm-working-ship-sprite.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$fixture/lib/fm-operational-input.ts"
  ln -s "$PI_PACKAGE_DIR" "$fixture/node_modules/@earendil-works/pi-coding-agent"
  ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$fixture/node_modules/@earendil-works/pi-tui"
  ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$fixture/node_modules/typebox"
  printf '%s\n' '{"type":"module"}' >"$fixture/package.json"

  out=$(cd "$fixture" && \
    SHIM="$fixture/fm-0-pi-cursor-sdk-integration.ts" \
    CALM="$fixture/fm-calm.ts" \
    PI_PACKAGE_DIR="$PI_PACKAGE_DIR" \
    node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
import { Text } from "@earendil-works/pi-tui";

const packageRoot = process.env.PI_PACKAGE_DIR;
const [{ ToolExecutionComponent }, { initTheme }, { setCapabilities }] = await Promise.all([
  import(pathToFileURL(`${packageRoot}/dist/modes/interactive/components/tool-execution.js`).href),
  import(pathToFileURL(`${packageRoot}/dist/modes/interactive/theme/theme.js`).href),
  import(pathToFileURL(`${packageRoot}/node_modules/@earendil-works/pi-tui/dist/index.js`).href),
]);
initTheme("dark");
setCapabilities({ images: null, trueColor: true, hyperlinks: false });

const tools = [];
const handlers = new Map();
const pi = {
  events: { emit() {}, on() {} },
  on(event, handler) {
    const eventHandlers = handlers.get(event) ?? [];
    eventHandlers.push(handler);
    handlers.set(event, eventHandlers);
  },
  registerCommand() {},
  registerEntryRenderer() {},
  registerTool(tool) {
    tools.push(tool);
  },
};

const shim = await import(`${pathToFileURL(process.env.SHIM).href}?shim=${Date.now()}`);
shim.default(pi);

const calm = await import(`${pathToFileURL(process.env.CALM).href}?calm=${Date.now()}`);
calm.default(pi);

const calmBuiltIns = tools.filter((tool) =>
  ["read", "bash", "edit", "write", "grep", "find", "ls"].includes(tool.name),
);
if (calmBuiltIns.length !== 0) {
  throw new Error(`Calm still registered built-ins: ${calmBuiltIns.map((tool) => tool.name).join(",")}`);
}

const replayDefinition = {
  name: "read",
  label: "Read",
  description: "replay probe",
  parameters: {},
  async execute() {
    return { content: [{ type: "text", text: "secret" }], details: {} };
  },
  renderCall() {
    return new Text("REPLAY_CALL secret", 0, 0);
  },
  renderResult() {
    return new Text("REPLAY_RESULT secret", 0, 0);
  },
};
pi.registerTool(replayDefinition);

const visibility = await import(pathToFileURL(`${process.cwd()}/lib/fm-calm-visibility.ts`).href);
visibility.setCalmPresentation(true);

const replayRow = new ToolExecutionComponent(
  "read",
  "cursor-replay-read",
  { path: "sample.txt" },
  { showImages: false },
  replayDefinition,
  { requestRender() {} },
  process.cwd(),
);
replayRow.markExecutionStarted();
replayRow.setArgsComplete();
replayRow.updateResult({
  content: [{ type: "text", text: "secret" }],
  details: {},
  isError: false,
});
if (replayRow.render(100).length !== 0) {
  throw new Error("Calm shim did not hide a pi-cursor-sdk replay tool row");
}

const cursorDefinition = {
  name: "cursor",
  label: "Cursor",
  description: "cursor activity replay",
  parameters: {},
  async execute() {
    return { content: [{ type: "text", text: "noise" }], details: {} };
  },
  renderCall(args, theme) {
    return new Text(`CURSOR_CALL ${args.activityTitle ?? ""}`, 0, 0);
  },
  renderResult(result) {
    return new Text(`CURSOR_RESULT ${result.content?.[0]?.text ?? ""}`, 0, 0);
  },
};

const incompleteRow = new ToolExecutionComponent(
  "cursor",
  "cursor-replay-shell-incomplete",
  { activityTitle: "Cursor shell", activitySummary: "missing completion", incomplete: true },
  { showImages: false },
  cursorDefinition,
  { requestRender() {} },
  process.cwd(),
);
incompleteRow.markExecutionStarted();
incompleteRow.setArgsComplete();
incompleteRow.updateResult({
  content: [{ type: "text", text: "Cursor shell did not complete\nmissing completion" }],
  details: {
    variant: "activity",
    title: "Cursor shell did not complete",
    summary: "missing completion",
  },
  isError: true,
});
if (incompleteRow.render(100).length !== 0) {
  throw new Error("Calm shim did not hide an incomplete pi-cursor-sdk cursor replay row");
}

const hungMcp = {
  name: "pi__web_search",
  label: "Search",
  description: "mcp replay probe",
  parameters: {},
  async execute() {
    return new Promise(() => {});
  },
};
pi.registerTool(hungMcp);
const hungResult = hungMcp.execute("cursor-replay-mcp", {}, undefined, undefined, {});
const watchdogTimeout = new Promise((_, reject) => {
  setTimeout(() => reject(new Error("hung mcp cursor-replay was not completed")), 2000);
});
try {
  await Promise.race([hungResult, watchdogTimeout]);
  throw new Error("hung mcp cursor-replay resolved instead of failing the tool");
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  if (!message.includes("did not complete")) throw error;
}
JS
)
  status=$?
  [ "$status" -eq 0 ] || fail "Calm cursor-sdk shim test failed: $out"
  [ -z "$out" ] || fail "Calm cursor-sdk shim test printed output: $out"
  pass "Calm cursor-sdk shim blocks Calm built-in registration and hides replay tool rows"
}

test_static_contract
test_guard_and_layout
