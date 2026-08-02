#!/usr/bin/env bash
# Focused activation and public TUI behavior checks for ask_user_questions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-ask-user-tui.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
EXT="$ROOT/.pi/extensions/fm-ask-user-tui.ts"
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}

if ! command -v node >/dev/null 2>&1; then
  echo "skip: node not found for ask_user_questions tests"
  exit 0
fi
if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
  echo "skip: installed @earendil-works/pi-coding-agent package not found"
  exit 0
fi

prepare_fixture() {
  local name=$1 fixture=$TMP_ROOT/$1
  git clone -q "$ROOT" "$fixture"
  mkdir -p "$fixture/.pi/extensions" "$fixture/config" "$fixture/node_modules/@earendil-works"
  cp "$EXT" "$fixture/.pi/extensions/fm-ask-user-tui.ts"
  printf '%s\n' '{"type":"module"}' > "$fixture/package.json"
  ln -s "$PI_PACKAGE_DIR" "$fixture/node_modules/@earendil-works/pi-coding-agent"
  ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$fixture/node_modules/@earendil-works/pi-tui"
  ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$fixture/node_modules/typebox"
  printf '%s\n' "$fixture"
}

run_node() {
  local fixture=$1 script=$2
  shift 2
  (cd "$fixture" && env "$@" node --experimental-strip-types "$script")
}

typecheck_extension() {
  if ! command -v tsc >/dev/null 2>&1; then
    echo "skip: tsc not found for ask_user_questions typecheck"
    return 0
  fi

  if [ ! -d "$PI_PACKAGE_DIR/node_modules/typebox" ] || \
    [ ! -d "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" ] || \
    [ ! -d "$PI_PACKAGE_DIR/node_modules/@types/node" ]; then
    echo "skip: installed Pi package is missing pi-tui, typebox, or Node declarations"
    return 0
  fi

  local type_root="$TMP_ROOT/typecheck"
  mkdir -p "$type_root/node_modules/@earendil-works" "$type_root/node_modules/@types"
  cp "$EXT" "$type_root/fm-ask-user-tui.ts"
  ln -s "$PI_PACKAGE_DIR" "$type_root/node_modules/@earendil-works/pi-coding-agent"
  ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$type_root/node_modules/@earendil-works/pi-tui"
  ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$type_root/node_modules/typebox"
  ln -s "$PI_PACKAGE_DIR/node_modules/@types/node" "$type_root/node_modules/@types/node"
  printf '%s\n' '{"type":"module"}' > "$type_root/package.json"
  cat > "$type_root/tsconfig.json" <<'JSON'
{
  "compilerOptions": {
    "allowImportingTsExtensions": true,
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "noEmit": true,
    "skipLibCheck": true,
    "strict": true,
    "target": "ES2022",
    "types": ["node"]
  },
  "include": ["fm-ask-user-tui.ts"]
}
JSON
  (cd "$type_root" && tsc -p tsconfig.json) || fail "ask_user_questions failed strict Pi typecheck"
  pass "ask_user_questions passes strict no-emit typecheck against installed Pi"
}

typecheck_extension

cat > "$TMP_ROOT/activation-probe.mjs" <<'JS'
import { pathToFileURL } from "node:url";

const extension = await import(`${pathToFileURL(process.env.ASK_USER_EXTENSION).href}?case=${process.env.ASK_USER_CASE}`);
const handlers = new Map();
const tools = [];
const pi = {
  on(name, handler) {
    handlers.set(name, handler);
  },
  registerTool(tool) {
    tools.push(tool);
  },
};
extension.default(pi);
if (tools.length !== 0) throw new Error("the extension registered a tool before session_start");
const sessionStart = handlers.get("session_start");
if (!sessionStart) throw new Error("the extension did not register its lifecycle handler");
await sessionStart({ reason: "startup" }, { cwd: process.cwd(), mode: process.env.ASK_USER_MODE });
const expected = Number(process.env.ASK_USER_EXPECTED_TOOLS);
if (tools.length !== expected) {
  throw new Error(`expected ${expected} registered tools, received ${tools.length}`);
}
if (expected === 1) {
  if (tools[0].name !== "ask_user_questions") throw new Error("unexpected tool name");
  if (!tools[0].promptSnippet || !tools[0].promptGuidelines?.length) {
    throw new Error("searchable tool metadata is incomplete");
  }
}
process.stdout.write(`activation ${process.env.ASK_USER_CASE}: ${tools.length}\n`);
JS

run_activation_case() {
  local name=$1 mode=$2 expected=$3 fixture output
  fixture=$(prepare_fixture "$name")
  if [ "$name" = marker-valid ]; then
    : > "$fixture/config/ask-user-tui"
  elif [ "$name" = marker-symlink ]; then
    : > "$fixture/config/marker-target"
    ln -s marker-target "$fixture/config/ask-user-tui"
  elif [ "$name" = secondmate-home ]; then
    : > "$fixture/config/ask-user-tui"
    printf '%s\n' secondmate > "$fixture/.fm-secondmate-home"
  elif [ "$name" = ambient-fm-home-only ]; then
    mkdir -p "$TMP_ROOT/ambient-home/config"
    : > "$TMP_ROOT/ambient-home/config/ask-user-tui"
  fi

  output=$(run_node "$fixture" "$TMP_ROOT/activation-probe.mjs" \
    ASK_USER_EXTENSION="$fixture/.pi/extensions/fm-ask-user-tui.ts" \
    ASK_USER_CASE="$name" \
    ASK_USER_MODE="$mode" \
    ASK_USER_EXPECTED_TOOLS="$expected" \
    FM_HOME="$TMP_ROOT/ambient-home") || fail "activation case $name failed: $output"
  assert_contains "$output" "activation $name: $expected" "activation case $name returned the wrong registration result"
}

run_activation_case marker-valid tui 1
run_activation_case marker-absent tui 0
run_activation_case marker-symlink tui 0
run_activation_case secondmate-home tui 0
run_activation_case rpc-mode rpc 0
run_activation_case print-mode print 0
run_activation_case json-mode json 0
run_activation_case ambient-fm-home-only tui 0

worker_root=$(prepare_fixture worker-root)
: > "$worker_root/config/ask-user-tui"
worker_worktree="$TMP_ROOT/worker-worktree"
git -C "$worker_root" worktree add -q -b ask-user-worker "$worker_worktree"
mkdir -p "$worker_worktree/.pi/extensions" "$worker_worktree/config" "$worker_worktree/node_modules/@earendil-works"
cp "$EXT" "$worker_worktree/.pi/extensions/fm-ask-user-tui.ts"
printf '%s\n' '{"type":"module"}' > "$worker_worktree/package.json"
ln -s "$PI_PACKAGE_DIR" "$worker_worktree/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$worker_worktree/node_modules/@earendil-works/pi-tui"
ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$worker_worktree/node_modules/typebox"
: > "$worker_worktree/config/ask-user-tui"
worker_output=$(run_node "$worker_worktree" "$TMP_ROOT/activation-probe.mjs" \
  ASK_USER_EXTENSION="$worker_worktree/.pi/extensions/fm-ask-user-tui.ts" \
  ASK_USER_CASE=worker-worktree \
  ASK_USER_MODE=tui \
  ASK_USER_EXPECTED_TOOLS=0) || fail "worker worktree activation test failed: $worker_output"
assert_contains "$worker_output" "activation worker-worktree: 0" "worker worktree registered the primary-only tool"

git -C "$worker_root" worktree remove -f "$worker_worktree"
pass "activation requires a regular marker in the plain primary checkout and rejects absence, symlink, secondmate, worker, RPC, print, JSON, and FM_HOME-only cases"

cat > "$TMP_ROOT/behavior-probe.mjs" <<'JS'
import { initTheme } from "@earendil-works/pi-coding-agent";
import { CURSOR_MARKER, visibleWidth } from "@earendil-works/pi-tui";
import extension from "./.pi/extensions/fm-ask-user-tui.ts";

initTheme("dark");
const handlers = new Map();
const tools = [];
const calls = [];
const pi = {
  on(name, handler) {
    const current = handlers.get(name) ?? [];
    current.push(handler);
    handlers.set(name, current);
  },
  registerTool(tool) {
    tools.push(tool);
  },
  appendEntry() {
    throw new Error("ask_user_questions must not append session state");
  },
  registerCommand() {
    throw new Error("ask_user_questions must not register a command");
  },
  registerShortcut() {
    throw new Error("ask_user_questions must not register a shortcut");
  },
};
extension(pi);
if (tools.length !== 0) throw new Error("tool registered before the session start event");
await handlers.get("session_start")[0]({ reason: "startup" }, { cwd: process.cwd(), mode: "tui" });
if (tools.length !== 1) throw new Error("eligible TUI did not register one tool");
const tool = tools[0];
if (tool.name !== "ask_user_questions") throw new Error("wrong registered tool");
for (const reason of ["reload", "new", "resume", "fork"]) {
  await handlers.get("session_start")[0]({ reason }, { cwd: process.cwd(), mode: "tui" });
}
if (tools.length !== 1 || handlers.get("session_start").length !== 1) {
  throw new Error("session lifecycle duplicated the tool or handler");
}
if (handlers.has("session_shutdown")) throw new Error("shutdown registered an unnecessary handler");

const reloadHandlers = new Map();
const reloadTools = [];
const reloadPi = {
  on(name, handler) {
    reloadHandlers.set(name, handler);
  },
  registerTool(tool) {
    reloadTools.push(tool);
  },
};
extension(reloadPi);
await reloadHandlers.get("session_start")({ reason: "reload" }, { cwd: process.cwd(), mode: "tui" });
await reloadHandlers.get("session_start")({ reason: "new" }, { cwd: process.cwd(), mode: "tui" });
if (reloadTools.length !== 1 || reloadHandlers.get("session_start") === undefined) {
  throw new Error("reload created duplicate tools or lost the lifecycle handler");
}

let palette = "";
const theme = {
  fg(_color, text) {
    return `${palette}${text}`;
  },
  bg(_color, text) {
    return `${palette}${text}`;
  },
  bold(text) {
    return `${palette}${text}`;
  },
};
const tui = {
  terminal: { rows: 28 },
  requestRender() {
    calls.push("render");
  },
};

function assertWidth(lines, width, label) {
  for (const line of lines) {
    if (visibleWidth(line) > width) throw new Error(`${label} exceeded width ${width}: ${line}`);
  }
}

async function runQuestions(params, keys, options = {}) {
  let component;
  let initialLines = [];
  const ui = {
    custom(factory) {
      return new Promise((resolve) => {
        component = factory(tui, theme, {}, resolve);
        component.focused = true;
        initialLines = component.render(options.initialWidth ?? 100);
        assertWidth(initialLines, options.initialWidth ?? 100, "initial render");
        if (options.onComponent) options.onComponent(component, initialLines);
        if (options.abort) {
          setTimeout(() => options.abort.abort(), 0);
        }
        for (const key of keys) component.handleInput?.(key);
      });
    },
  };
  const result = await tool.execute("probe", params, options.abort?.signal, undefined, {
    cwd: process.cwd(),
    mode: "tui",
    ui,
  });
  return { result, initialLines, component };
}

const structured = await runQuestions(
  {
    questions: [
      {
        id: "choice-question",
        header: "Choice",
        question: "Choose one path.",
        options: [
          { id: "option-alpha", label: "Alpha", description: "Low migration cost.", recommended: true, preview: "# Alpha\n\nUse **Alpha**." },
          { id: "option-beta", label: "Beta", description: "Higher migration cost." },
        ],
      },
      {
        id: "multi-question",
        header: "Many",
        question: "Choose several paths.",
        allowMultiple: true,
        allowFreeText: false,
        options: [
          { id: "option-x", label: "X" },
          { id: "option-y", label: "Y" },
        ],
      },
    ],
  },
  ["\r", " ", "\u001b[B", " ", "\r", "\r"],
  {
    initialWidth: 100,
    onComponent(component, initialLines) {
      const initial = initialLines.join("\n");
      if (!initial.includes("Preview") || !initial.includes("Alpha")) throw new Error("Markdown preview or option missing");
      if (!initial.includes("recommended") || !initial.includes("○")) throw new Error("recommendation was not visible without preselection");
      palette = "THEME_CHANGED:";
      component.invalidate();
      const invalidated = component.render(100).join("\n");
      if (!invalidated.includes("THEME_CHANGED:")) throw new Error("theme invalidation did not rebuild rendered content");
      assertWidth(component.render(12), 12, "narrow render");
    },
  },
);
const structuredJson = JSON.stringify(structured.result);
if (!structuredJson.includes("option-alpha") || !structuredJson.includes("option-x") || !structuredJson.includes("option-y")) {
  throw new Error(`structured result lost stable IDs: ${structuredJson}`);
}
if (structured.result.details.cancelled) throw new Error("structured answer was marked cancelled");

const freeText = await runQuestions(
  { questions: [{ id: "free-question", question: "Write an answer.", options: [], allowFreeText: true }] },
  ["h", "i", "\r", "\r"],
  {
    initialWidth: 80,
    onComponent(_component, initialLines) {
      if (!initialLines.some((line) => line.includes(CURSOR_MARKER))) throw new Error("focused free-text editor did not expose IME cursor marker");
    },
  },
);
if (freeText.result.details.response?.answers[0]?.freeText !== "hi") throw new Error("free text was not returned");
if (!JSON.stringify(freeText.result).includes("free-question")) throw new Error("free-text result lost question id");

const emptyFreeText = await runQuestions(
  { questions: [{ id: "empty-question", question: "Write an answer.", options: [], allowFreeText: true }] },
  ["\r", "\u001b"],
);
if (!emptyFreeText.result.details.cancelled || emptyFreeText.result.details.aborted) throw new Error("empty free text did not cancel explicitly");
if (!emptyFreeText.result.content[0].text.includes("cancelled")) throw new Error("empty free text cancellation was not explicit");

const cancelled = await runQuestions(
  { questions: [{ id: "cancel-question", question: "Choose.", options: [{ id: "cancel-option", label: "Option" }] }] },
  ["\u001b"],
);
if (!cancelled.result.details.cancelled || cancelled.result.details.response !== null) throw new Error("Escape invented or retained an answer");

const abort = new AbortController();
const interrupted = await runQuestions(
  { questions: [{ id: "abort-question", question: "Choose.", options: [{ id: "abort-option", label: "Option" }] }] },
  [],
  { abort },
);
if (!interrupted.result.details.cancelled || !interrupted.result.details.aborted) throw new Error("Abort did not return explicit interruption");

let customCalled = false;
const malformed = await tool.execute(
  "malformed",
  { questions: [{ id: "bad", question: "Bad options", allowFreeText: false, options: [{ id: "dup", label: "One" }, { id: "dup", label: "Two" }] }] },
  undefined,
  undefined,
  {
    cwd: process.cwd(),
    mode: "tui",
    ui: { custom() { customCalled = true; throw new Error("malformed input opened the TUI"); } },
  },
);
if (!malformed.details?.cancelled || !malformed.details.error) throw new Error("malformed options were not rejected");
if (customCalled) throw new Error("malformed options opened the TUI");

const emptyQuestions = await tool.execute(
  "empty",
  { questions: [] },
  undefined,
  undefined,
  {
    cwd: process.cwd(),
    mode: "tui",
    ui: { custom() { throw new Error("empty input opened the TUI"); } },
  },
);
if (!emptyQuestions.details.cancelled || !emptyQuestions.details.error) throw new Error("empty question input was not rejected");

const malformedPreview = await tool.execute(
  "bad-preview",
  { questions: [{ id: "bad-preview", question: "Bad preview", allowFreeText: false, options: [{ id: "bad", label: "Bad", preview: 42 }] }] },
  undefined,
  undefined,
  {
    cwd: process.cwd(),
    mode: "tui",
    ui: { custom() { throw new Error("malformed preview opened the TUI"); } },
  },
);
if (!malformedPreview.details.cancelled || !malformedPreview.details.error) throw new Error("malformed preview was not rejected");

const nonTui = await tool.execute(
  "non-tui",
  { questions: [{ id: "non-tui", question: "No UI", options: [{ id: "option", label: "Option" }] }] },
  undefined,
  undefined,
  {
    cwd: process.cwd(),
    mode: "rpc",
    ui: { custom() { throw new Error("non-TUI mode opened the TUI"); } },
  },
);
if (!nonTui.details.cancelled || !nonTui.details.error) throw new Error("non-TUI execution was not rejected");

const renderCall = tool.renderCall(
  { questions: [{ id: "q", question: "Q", options: [{ id: "o", label: "O" }] }] },
  theme,
  {},
);
assertWidth(renderCall.render(8), 8, "renderCall");
const renderResult = tool.renderResult(
  structured.result,
  { expanded: false, isPartial: false },
  theme,
  {},
);
assertWidth(renderResult.render(32), 32, "renderResult");

if (calls.length === 0) throw new Error("TUI state changes never requested a render");
process.stdout.write("behavior: structured, multi-select, free text, preview, cancellation, abort, IME, width, theme, reload, and malformed input passed\n");
JS

behavior_fixture=$(prepare_fixture behavior)
: > "$behavior_fixture/config/ask-user-tui"
cp "$TMP_ROOT/behavior-probe.mjs" "$behavior_fixture/behavior-probe.mjs"
behavior_output=$(run_node "$behavior_fixture" "$behavior_fixture/behavior-probe.mjs" \
  ASK_USER_EXTENSION="$behavior_fixture/.pi/extensions/fm-ask-user-tui.ts") || fail "behavior probe failed: $behavior_output"
assert_contains "$behavior_output" "behavior: structured" "behavior probe did not complete"
pass "public TUI behavior returns stable IDs and explicit cancellation without authority or session side effects"
pass "deterministic disposable-primary demo path covers narrow and wide rendering for PX08"
