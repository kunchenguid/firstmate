#!/usr/bin/env bash
# Tests for the tracked Pi supervision-branch extension
# (.pi/extensions/fm-branch-supervision.ts): wake dispatch acceptance and
# gating, the two-stage noise filter's second stage (verdict-driven delivery
# into main), store-first durability through the real bin/fm-branch-outcome.sh,
# the byte-stable tool order and per-home prompt_cache_key hook, the dialog
# mirror, and branch-session persistence. The Pi SDK is stubbed (scriptable
# in-process sessions); every fleet-record behavior runs the REAL bin scripts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-branch-extension)
EXT="$ROOT/.pi/extensions/fm-branch-supervision.ts"
export NODE_NO_WARNINGS=1

# Keep JavaScript heredocs outside command substitutions. Stock macOS Bash
# 3.2 reparses quotes and template literals inside that combination.
install_pi_branch_extension_fixture() {
  local repo=$1
  mkdir -p \
    "$repo/.pi/extensions/lib" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/node_modules/@earendil-works/pi-ai" \
    "$repo/node_modules/@earendil-works/pi-tui" \
    "$repo/node_modules/typebox"
  cp "$EXT" "$repo/.pi/extensions/fm-branch-supervision.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-model-picker.ts" "$repo/.pi/extensions/lib/fm-branch-model-picker.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  mkdir -p "$repo/bin"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
import { writeFileSync } from "node:fs";

export function getAgentDir() {
  return "/stub-agent-dir";
}

export function getMarkdownTheme() {
  return {};
}

export function keyHint(_keybinding, description) {
  return `ctrl+o ${description}`;
}

export class ToolExecutionComponent {
  updateResult(result) {
    this.result = result;
  }
  render() {
    return (this.result?.content ?? [])
      .filter((item) => item.type === "text")
      .flatMap((item) => item.text.split("\n"));
  }
}

export class UserMessageComponent {}

export class DynamicBorder {
  constructor(color) {
    this.color = color;
  }
  invalidate() {}
  render() {
    return ["--"];
  }
}

export class ModelRuntime {
  constructor() {
    this.models = (globalThis.__fmBranchStaticModels?.() ?? []).map((model) => ({ ...model }));
    this.authenticated = new Set(this.models.filter((model) => model.storedAuth !== false).map((model) => model.provider));
  }
  static async create() {
    const queuedError = globalThis.__fmModelRuntimeErrors?.shift();
    if (queuedError) throw new Error(queuedError);
    if (globalThis.__fmModelRuntimeError) throw new Error(globalThis.__fmModelRuntimeError);
    const runtime = new ModelRuntime();
    (globalThis.__fmModelRuntimes ??= []).push(runtime);
    return runtime;
  }
  getModel(provider, id) {
    return this.models.find((model) => model.provider === provider && model.id === id);
  }
  hasConfiguredAuth(provider) {
    return this.authenticated.has(provider);
  }
}
export class DefaultResourceLoader {
  constructor(options) {
    this.options = options;
    (globalThis.__fmLoaders ??= []).push(this);
  }
  async reload() {
    this.reloaded = true;
  }
}

export class SessionManager {
  constructor(file) {
    this.file = file;
  }
  static create(cwd, dir) {
    globalThis.__fmCreateCount = (globalThis.__fmCreateCount ?? 0) + 1;
    const sm = new SessionManager(`${dir}/created-${globalThis.__fmCreateCount}.jsonl`);
    sm.created = true;
    writeFileSync(sm.file, "");
    (globalThis.__fmSessionManagers ??= []).push(sm);
    return sm;
  }
  static open(path) {
    const sm = new SessionManager(path);
    sm.opened = true;
    (globalThis.__fmSessionManagers ??= []).push(sm);
    return sm;
  }
  getSessionFile() {
    return this.file;
  }
  buildSessionContext() {
    const model = globalThis.__fmRecordedModels?.get(this.file) ?? null;
    return { messages: model ? [{ role: "assistant", content: [], provider: model.provider, model: model.modelId }] : [], thinkingLevel: "medium", model };
  }
}

export function createBashToolDefinition(cwd, options) {
  return {
    name: "bash",
    label: "stub bash",
    description: "stub bash",
    parameters: { type: "object" },
    __cwd: cwd,
    __options: options,
    execute: async (_toolCallId, params) => {
      if (!globalThis.__fmExecuteBranchBash) return { content: [], details: undefined };
      const initial = { command: String(params.command ?? ""), cwd, env: { ...process.env } };
      const context = options.spawnHook ? options.spawnHook(initial) : initial;
      return globalThis.__fmExecuteBranchBash(context);
    },
  };
}

export async function createAgentSession(options) {
  if (globalThis.__fmCreateSessionError) throw new Error(globalThis.__fmCreateSessionError);
  globalThis.__fmCreateStarted = (globalThis.__fmCreateStarted ?? 0) + 1;
  if (globalThis.__fmCreateGate) await globalThis.__fmCreateGate;
  if (options.model && (!options.modelRuntime || !options.modelRuntime.getModel(options.model.provider, options.model.id))) {
    throw new Error(`branch runtime cannot use ${options.model.provider}/${options.model.id}`);
  }
  const session = {
    options,
    ops: [],
    disposed: false,
    async prompt(text) {
      if (globalThis.__fmPromptGate) {
        globalThis.__fmPromptStarted = true;
        await globalThis.__fmPromptGate;
      }
      session.ops.push({ kind: "prompt", text });
      (globalThis.__fmPrompts ??= []).push(text);
      await globalThis.__fmOnBranchPrompt?.({ session, text });
    },
    async sendCustomMessage(message, opts) {
      if (globalThis.__fmMirrorGate) {
        globalThis.__fmMirrorStarted = true;
        await globalThis.__fmMirrorGate;
      }
      session.ops.push({ kind: "custom", message, opts });
      (globalThis.__fmMirrors ??= []).push(message);
    },
    dispose() {
      session.disposed = true;
    },
  };
  const restoredModel = options.model
    ? { provider: options.model.provider, modelId: options.model.id }
    : globalThis.__fmRecordedModels?.get(options.sessionManager.getSessionFile());
  if (restoredModel) (globalThis.__fmRecordedModels ??= new Map()).set(options.sessionManager.getSessionFile(), restoredModel);
  (globalThis.__fmSessions ??= []).push(session);
  return { session, extensionsResult: {} };
}
JS
  cat > "$repo/node_modules/@earendil-works/pi-ai/package.json" <<'JSON'
{"name":"@earendil-works/pi-ai","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-ai/index.js" <<'JS'
// Pi's own thinking-level rules, reproduced from the installed package so the
// portable regression can drive models with different effort ceilings. The
// live guard (tests/fm-pi-branch-live-e2e.test.sh) is what proves the real
// vendor surface still behaves this way.
const EXTENDED_THINKING_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];

export function getSupportedThinkingLevels(model) {
  if (!model.reasoning) return ["off"];
  return EXTENDED_THINKING_LEVELS.filter((level) => {
    const mapped = model.thinkingLevelMap?.[level];
    if (mapped === null) return false;
    if (level === "xhigh" || level === "max") return mapped !== undefined;
    return true;
  });
}

export function clampThinkingLevel(model, level) {
  const available = getSupportedThinkingLevels(model);
  if (available.includes(level)) return level;
  const requested = EXTENDED_THINKING_LEVELS.indexOf(level);
  if (requested === -1) return available[0] ?? "off";
  for (let i = requested; i < EXTENDED_THINKING_LEVELS.length; i += 1) {
    if (available.includes(EXTENDED_THINKING_LEVELS[i])) return EXTENDED_THINKING_LEVELS[i];
  }
  for (let i = requested - 1; i >= 0; i -= 1) {
    if (available.includes(EXTENDED_THINKING_LEVELS[i])) return EXTENDED_THINKING_LEVELS[i];
  }
  return available[0] ?? "off";
}
JS
  cat > "$repo/node_modules/@earendil-works/pi-tui/package.json" <<'JSON'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Text {
  constructor(text, paddingX, paddingY) {
    this.text = text;
    this.paddingX = paddingX;
    this.paddingY = paddingY;
  }
}

export class Container {
  constructor() {
    this.children = [];
  }
  addChild(child) {
    this.children.push(child);
  }
  clear() {
    this.children = [];
  }
  render() {
    return this.children.flatMap((child) => child.render?.() ?? []);
  }
}

export class Box extends Container {
  constructor(paddingX, paddingY, bgFn) {
    super();
    this.paddingX = paddingX;
    this.paddingY = paddingY;
    this.bgFn = bgFn;
  }
  setBgFn(bgFn) {
    this.bgFn = bgFn;
  }
}

export class Input {
  constructor() {
    this.value = "";
    this.focused = false;
  }
  getValue() {
    return this.value;
  }
  setValue(value) {
    this.value = value;
  }
  handleInput(data) {
    this.value = data === "\u007f" ? this.value.slice(0, -1) : this.value + data;
  }
  invalidate() {}
  render() {
    return [this.value];
  }
}

// Records every construction so a driver can assert the rows and the visible
// bound the extension asked Pi's real SelectList for. Navigation keys arrive
// as their keybinding ids because the driver's fake keybindings manager
// matches an id against the raw key data.
export class SelectList {
  constructor(items, maxVisible, theme) {
    this.items = items;
    this.maxVisible = maxVisible;
    this.theme = theme;
    this.selectedIndex = 0;
    (globalThis.__fmPickerLists ??= []).push({ items: items.map((item) => ({ ...item })), maxVisible });
  }
  handleInput(data) {
    if (data === "tui.select.down") {
      this.selectedIndex = Math.min(this.selectedIndex + 1, this.items.length - 1);
    } else if (data === "tui.select.up") {
      this.selectedIndex = Math.max(0, this.selectedIndex - 1);
    } else if (data === "tui.select.confirm") {
      const item = this.items[this.selectedIndex];
      if (item) this.onSelect?.(item);
    } else if (data === "tui.select.cancel") {
      this.onCancel?.();
    }
  }
  getSelectedItem() {
    return this.items[this.selectedIndex] ?? null;
  }
  invalidate() {}
  render() {
    return this.items.slice(0, this.maxVisible).map((item) => item.label);
  }
}

export function fuzzyFilter(items, query, getText) {
  const needle = query.toLowerCase();
  return items.filter((item) => getText(item).toLowerCase().includes(needle));
}
JS
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties, options) {
    return { type: "object", properties, ...(options ?? {}) };
  },
  String(options) {
    return { type: "string", ...(options ?? {}) };
  },
  Number(options) {
    return { type: "number", ...(options ?? {}) };
  },
  Boolean(options) {
    return { type: "boolean", ...(options ?? {}) };
  },
  Optional(schema) {
    return { ...schema, optional: true };
  },
  Literal(value) {
    return { const: value };
  },
  Union(schemas, options) {
    return { anyOf: schemas, ...(options ?? {}) };
  },
};
JS
}

# Shared driver preamble: a fake main-session ExtensionAPI with a synchronous
# event bus (mirrors pi's EventEmitter-backed bus), captured handlers, and
# captured main-bound messages.
DRIVER_PRELUDE_FILE="$TMP_ROOT/driver-prelude.js"
cat > "$DRIVER_PRELUDE_FILE" <<'JS'
const { spawnSync } = await import("node:child_process");
const { mkdirSync, writeFileSync } = await import("node:fs");
const { pathToFileURL } = await import("node:url");

const home = process.env.FM_HOME;
const realRoot = process.env.FM_ROOT_OVERRIDE;
const approvedProject = `${home}/projects/approved`;
mkdirSync(`${home}/state`, { recursive: true });
mkdirSync(`${home}/config`, { recursive: true });
mkdirSync(approvedProject, { recursive: true });
writeFileSync(`${home}/state/branch-driver.meta`, `project=${approvedProject}\nwindow=fm-branch-driver\n`);
// Supervision is default-on for every task: no captain grant file gates it
// any more.
// The branch acts only for the session that owns the fleet lock; drivers own
// it by default, while cold-start and secondary-session scenarios opt out.
if (!process.env.FM_TEST_SKIP_LOCK) {
  writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
}

// Stubbed model surface: Pi's own catalog and selector dialog, scripted.
// registryModels is what ctx.modelRegistry serves, uiSelections queues the
// captain's answers to ctx.ui.select, and notices records what the command
// told the captain.
const registryModels = [];
const uiSelections = [];
const uiPrompts = [];
const notices = [];
const commands = new Map();
let mainModel = { provider: "anthropic", id: "main-model" };
// Main's own effort, which Pi answers through pi.getThinkingLevel(). Drivers
// change it through setMainThinkingLevel and then fire Pi's own
// thinking_level_select event, exactly as Pi does for a real /settings pick.
let mainThinkingLevel = "medium";
function setMainThinkingLevel(level) {
  mainThinkingLevel = level;
}
globalThis.__fmBranchStaticModels = () => registryModels
  .filter((model) => model.branchAvailable !== false)
  .map((model) => ({ ...model }));
const modelRegistry = {
  getAvailable: () => registryModels.filter((model) => model.mainAvailable !== false).slice(),
  find: (provider, id) => registryModels.find((model) => model.provider === provider && model.id === id),
  hasConfiguredAuth: (model) => model.mainAvailable !== false,
};
function makeCtx(extra) {
  return {
    modelRegistry,
    get model() {
      return mainModel;
    },
    ui: {
      select(title, options) {
        uiPrompts.push({ title, options });
        return Promise.resolve(uiSelections.shift());
      },
      notify(message, type) {
        notices.push({ message, type });
      },
    },
    ...(extra ?? {}),
  };
}

// A TUI-mode context whose ui.custom runs the extension's real picker
// component headlessly: the factory receives a fake renderer, a pass-through
// theme, and a keybindings manager that matches a keybinding id against the
// raw key data, and then the next queued keystroke script is fed to the
// component's own handleInput. Keystrokes are either a keybinding id
// (navigation) or literal characters (search). mainModelWrites records every
// attempt to move the captain's own model, which pinning the branch must
// never do.
const uiKeystrokes = [];
const mainModelWrites = [];
function makeTuiCtx(extra) {
  const base = makeCtx(extra);
  return {
    ...base,
    get model() {
      return mainModel;
    },
    mode: "tui",
    settingsManager: {
      setDefaultModelAndProvider(provider, id) {
        mainModelWrites.push({ provider, id });
      },
    },
    setModel(provider, id) {
      mainModelWrites.push({ provider, id });
    },
    ui: {
      ...base.ui,
      async custom(factory) {
        let result;
        let settled = false;
        const component = await factory(
          {
            requestRender() {},
          },
          { fg: (_color, text) => text, bold: (text) => text },
          { matches: (data, id) => data === id },
          (value) => {
            result = value;
            settled = true;
          },
        );
        component.render(80);
        for (const key of uiKeystrokes.shift() ?? ["tui.select.confirm"]) {
          if (settled) break;
          component.handleInput(key);
        }
        if (!settled) throw new Error("the picker script ended without a selection or a cancellation");
        return result;
      },
    },
  };
}

const busHandlers = new Map();
const bus = {
  on(channel, handler) {
    busHandlers.set(channel, [...(busHandlers.get(channel) ?? []), handler]);
    return () => {};
  },
  emit(channel, data) {
    for (const handler of busHandlers.get(channel) ?? []) handler(data);
  },
};
const piHandlers = new Map();
const sentToMain = [];
const mainUserMessages = [];
const mainTools = [];
const renderers = new Map();
const pi = {
  events: bus,
  on(event, handler) {
    piHandlers.set(event, [...(piHandlers.get(event) ?? []), handler]);
  },
  registerTool(tool) {
    mainTools.push(tool);
  },
  registerCommand(name, options) {
    commands.set(name, options);
  },
  registerMessageRenderer(customType, renderer) {
    renderers.set(customType, renderer);
  },
  sendMessage(message, options) {
    sentToMain.push({ message, options: options ?? {} });
  },
  sendUserMessage(content, options) {
    mainUserMessages.push({ content, options: options ?? {} });
  },
  getThinkingLevel() {
    if (globalThis.__fmThinkingLevelError) throw new Error(globalThis.__fmThinkingLevelError);
    return mainThinkingLevel;
  },
};
function fire(event, payload, ctx) {
  for (const handler of piHandlers.get(event) ?? []) handler(payload, ctx);
}
function makeOffer(message, projects = [approvedProject], heartbeat = false, eligible = projects.length > 0 || heartbeat) {
  const offer = {
    message,
    projects,
    heartbeat,
    eligible,
    accepted: false,
    accept() {
      offer.accepted = true;
    },
  };
  return offer;
}
function dispatch(message, projects, heartbeat, eligible) {
  const offer = makeOffer(message, projects, heartbeat, eligible);
  if (offer.eligible) {
    const row = offer.heartbeat
      ? "1\t1\theartbeat\theartbeat\theartbeat\n"
      : `1\t1\tsignal\tbranch-driver.status\t${message}\n`;
    writeFileSync(`${home}/state/.wake-queue`, row);
  }
  bus.emit("fm-branch-supervision:dispatch", offer);
  return offer;
}
async function settle(predicate, label) {
  for (let i = 0; i < 250; i += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timed out waiting for ${label}`);
}
function outcomeScript(args) {
  const result = spawnSync("bash", [`${realRoot}/bin/fm-branch-outcome.sh`, ...args], {
    encoding: "utf8",
    env: { ...process.env, FM_HOME: home, FM_STATE_OVERRIDE: `${home}/state` },
  });
  if (result.status !== 0) throw new Error(`fm-branch-outcome.sh ${args.join(" ")} failed: ${result.stderr}`);
  return (result.stdout || "").trim();
}
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
JS
DRIVER_PRELUDE=$(cat "$DRIVER_PRELUDE_FILE")

test_branch_dispatch_two_stage_filter_and_prefix_contract() {
  local repo home out status
  repo="$TMP_ROOT/dispatch-root"
  home="$TMP_ROOT/dispatch-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { pi, fire, dispatch, settle, outcomeScript, sentToMain, mainUserMessages, mainTools, renderers, home, realRoot }; })()`);
const { pi, fire, dispatch, settle, outcomeScript, sentToMain, mainUserMessages, mainTools, renderers, home, realRoot } = globalThis.__t;
import { readFileSync, writeFileSync } from "node:fs";

writeFileSync(`${home}/state/.lock`, `${process.ppid}\n`);

// 1. An accepted wake reaches the branch session, never main.
const offer = dispatch("signal: task-9 done: PR https://example.com/pr/9 checks green");
if (!offer.accepted) throw new Error("branch did not accept the wake offer");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "branch wake prompt");
const wakePrompt = globalThis.__fmPrompts[0];
if (!wakePrompt.includes("FIRSTMATE SUPERVISION WAKE: signal: task-9 done")) {
  throw new Error(`branch prompt lost the wake reason: ${wakePrompt}`);
}
if (mainUserMessages.length !== 0) throw new Error("accepted wake leaked to main as a user message");

// 2. Byte-stable prefix contract: same tool names in the same order, a
// generator-produced system prompt, no project resources, and the branch bash
// carries the deterministic actor identity.
const session = globalThis.__fmSessions[0];
if (JSON.stringify(session.options.tools) !== JSON.stringify(["read", "bash", "fm_branch_report"])) {
  throw new Error(`unexpected tool order: ${JSON.stringify(session.options.tools)}`);
}
const loader = globalThis.__fmLoaders[0];
for (const key of ["noExtensions", "noSkills", "noPromptTemplates", "noThemes", "noContextFiles"]) {
  if (loader.options[key] !== true) throw new Error(`branch loader must set ${key}`);
}
if (!loader.options.systemPrompt || !loader.options.systemPrompt.startsWith("You are the SUPERVISION BRANCH")) {
  throw new Error("branch system prompt is not the generator's output");
}
if (loader.options.systemPrompt.length < 4096) throw new Error("branch prompt is below the provider caching minimum");
const bashTool = session.options.customTools.find((tool) => tool.name === "bash");
const hooked = bashTool.__options.spawnHook({ command: "true", cwd: "/x", env: { PATH: "/bin" } });
if (hooked.env.FM_SUPERVISION_ACTOR !== "branch") throw new Error("branch bash does not inject the branch actor");
if (hooked.env.FM_LEASE_HOLDER_PID !== String(process.ppid)) throw new Error("branch bash does not pin the verified session-lock holder pid");

// 3. Shared per-home prompt_cache_key: overrides only payloads that already
// carry one, stable within the home.
let cacheHandler = null;
const factoryEntry = loader.options.extensionFactories[0];
const factory = typeof factoryEntry === "function" ? factoryEntry : factoryEntry.factory;
factory({ on: (event, handler) => { if (event === "before_provider_request") cacheHandler = handler; } });
if (!cacheHandler) throw new Error("branch cache-key hook not registered");
const rewriteA = cacheHandler({ type: "before_provider_request", payload: { prompt_cache_key: "session-a", model: "m" } });
const rewriteB = cacheHandler({ type: "before_provider_request", payload: { prompt_cache_key: "session-b", model: "m" } });
if (!rewriteA.prompt_cache_key.startsWith("fm-branch-")) throw new Error(`unexpected cache key: ${rewriteA.prompt_cache_key}`);
if (rewriteA.prompt_cache_key !== rewriteB.prompt_cache_key) throw new Error("branch cache key varies within one home");
if (rewriteA.model !== "m") throw new Error("cache-key hook dropped payload fields");
const untouched = cacheHandler({ type: "before_provider_request", payload: { model: "m" } });
if (untouched !== undefined) throw new Error("cache-key hook rewrote a provider payload with no prompt_cache_key");
console.log(`CACHE_KEY=${rewriteA.prompt_cache_key}`);

// 4. Two-stage filter, stage 2: routine while main is idle appends with no
// turn; routine while main is busy defers to after the captain's next prompt;
// captain-relevant appends and triggers exactly one turn. Store rows are
// written BEFORE the merge note and marked read after it.
const report = session.options.customTools.find((tool) => tool.name === "fm_branch_report");
const r1 = await report.execute("call-1", { task: "task-9", verdict: "routine", summary: "worker healthy, no action needed", wake: "signal: working" }, undefined, undefined, {});
if (r1.isError) throw new Error(`routine report failed: ${JSON.stringify(r1)}`);
if (sentToMain.length !== 1) throw new Error("routine report did not merge exactly one note");
if (sentToMain[0].message.customType !== "fm-branch-merge") throw new Error("merge note has the wrong custom type");
if (sentToMain[0].options.triggerTurn) throw new Error("routine idle merge must not trigger a turn");
if (sentToMain[0].options.deliverAs) throw new Error("routine idle merge must append immediately");
fire("agent_start", {});
await report.execute("call-2", { task: "task-9", verdict: "routine", summary: "still healthy" }, undefined, undefined, {});
if (sentToMain[1].options.deliverAs !== "nextTurn" || sentToMain[1].options.triggerTurn) {
  throw new Error(`routine busy merge must defer to nextTurn without a turn: ${JSON.stringify(sentToMain[1].options)}`);
}
fire("agent_end", {});
await report.execute("call-3", { task: "task-9", verdict: "captain", summary: "PR https://example.com/pr/9 checks green, ready for review" }, undefined, undefined, {});
if (sentToMain[2].options.triggerTurn !== true || sentToMain[2].options.deliverAs !== "followUp") {
  throw new Error(`captain merge must trigger exactly one follow-up turn: ${JSON.stringify(sentToMain[2].options)}`);
}
if (typeof sentToMain[0].message.content !== "string" || !sentToMain[0].message.content.startsWith("⛵ ")) {
  throw new Error(`routine note missing sailboat prefix: ${sentToMain[0].message.content}`);
}
if (/branch merged|\[routine\]|\[captain\]/.test(sentToMain[0].message.content)) {
  throw new Error(`routine note still has boilerplate: ${sentToMain[0].message.content}`);
}
// A routine note is rendered (display: true); a captain-facing note must
// never be printed or rendered at all - the follow-up turn triggered above
// is itself the captain-visible outcome. display: false is the exact flag
// Pi's own chat renderer and HTML export both gate on before ever calling a
// customType renderer, so this is the authoritative "never printed" proof.
if (sentToMain[0].message.display !== true) {
  throw new Error(`routine note must render: display=${sentToMain[0].message.display}`);
}
if (sentToMain[2].message.display !== false) {
  throw new Error(`captain note must never be printed or rendered: display=${sentToMain[2].message.display}`);
}
if (typeof sentToMain[2].message.content !== "string" || sentToMain[2].message.content.includes("⚓")) {
  throw new Error(`captain note must carry no anchor glyph now that it is never rendered: ${sentToMain[2].message.content}`);
}
if (!sentToMain[2].message.content.includes("task-9: PR https://example.com/pr/9")) {
  throw new Error(`captain note lost its outcome: ${sentToMain[2].message.content}`);
}
if (/branch merged|\[routine\]|\[captain\]/.test(sentToMain[2].message.content)) {
  throw new Error(`captain note still has boilerplate: ${sentToMain[2].message.content}`);
}
// What main's model actually receives. Pi keeps only `content` when it turns a
// custom message into a provider message - customType, display, and details are
// all dropped - so `content` IS the delivered payload, and these two files are
// the exact bytes main's model would read. The bash side classifies them with
// the REAL bin/fm-operational-input.sh so the protocol's own executable, not a
// pattern in this test, decides what was delivered. Pi's half of that contract
// is proven separately against the real SDK in fm-pi-branch-live-e2e.test.sh.
writeFileSync(`${home}/state/delivered-captain-note`, sentToMain[2].message.content);
writeFileSync(`${home}/state/delivered-routine-note`, sentToMain[0].message.content);
if (sentToMain.filter((sent) => sent.options.triggerTurn).length !== 1) {
  throw new Error("one captain outcome must open exactly one turn on main");
}

// The store (the owned durable contract) holds all three outcomes in order,
// and each merged note advanced the read cursor.
const rows = readFileSync(`${home}/state/branch-outcomes.jsonl`, "utf8").trim().split("\n").map((line) => JSON.parse(line));
if (rows.length !== 3) throw new Error(`expected 3 store rows, got ${rows.length}`);
if (rows[0].verdict !== "routine" || rows[2].verdict !== "captain") throw new Error("store verdicts out of order");
if (rows[0].wake !== "signal: working") throw new Error("store lost the wake reason");
if (outcomeScript(["unread"]) !== "") throw new Error("merged outcomes were not marked read");

// 5. Main-side surfaces: the on-demand store reader tool and the merge-note
// renderer.
const outcomesTool = mainTools.find((tool) => tool.name === "fm_branch_outcomes");
if (!outcomesTool) throw new Error("fm_branch_outcomes was not registered on main");
const renderTheme = {
  fg(_color, text) { return text; },
  bg(_color, text) { return text; },
  bold(text) { return text; },
};
const renderContext = { state: {}, isError: false, isPartial: false };
const stockResult = { content: [{ type: "text", text: "OUTCOME_DUMP" }] };
const calmOffCall = outcomesTool.renderCall({}, renderTheme, renderContext);
const calmOffResult = outcomesTool.renderResult(stockResult, { expanded: false, isPartial: false }, renderTheme, renderContext);
if (calmOffCall.constructor.name !== "Box" || calmOffCall.paddingX !== 1 || calmOffCall.paddingY !== 1) {
  throw new Error("fm_branch_outcomes changed its ordinary shell rendering");
}
if (calmOffResult.constructor.name !== "Container" || calmOffCall.children[0]?.text !== "fm_branch_outcomes" || calmOffCall.children[1]?.text !== "OUTCOME_DUMP") {
  throw new Error("fm_branch_outcomes changed its ordinary call or result rendering");
}
const legacyStockResult = {
  content: [{
    type: "text",
    text: Array.from({ length: 12 }, (_, index) => `LEGACY_OUTCOME_${String(index + 1).padStart(2, "0")}`).join("\n"),
  }],
};
const legacyRenderContext = { state: {}, isError: false, isPartial: false };
const legacyCall = outcomesTool.renderCall({}, renderTheme, legacyRenderContext);
outcomesTool.renderResult(legacyStockResult, { expanded: false, isPartial: false }, renderTheme, legacyRenderContext);
const collapsedLegacyText = legacyCall.children[1]?.text;
if (!collapsedLegacyText?.includes("LEGACY_OUTCOME_12") || collapsedLegacyText.includes("more lines")) {
  throw new Error("legacy all-line stock capability did not preserve collapsed Calm-off output");
}
outcomesTool.renderResult(legacyStockResult, { expanded: true, isPartial: false }, renderTheme, legacyRenderContext);
if (legacyCall.children[1]?.text !== collapsedLegacyText) {
  throw new Error("legacy all-line stock capability changed expanded Calm-off output");
}
pi.events.emit("firstmate:calm-presentation", { active: true, stockExportRendering: false });
const calmOnCall = outcomesTool.renderCall({}, renderTheme, renderContext);
const calmOnResult = outcomesTool.renderResult(stockResult, { expanded: false, isPartial: false }, renderTheme, renderContext);
if (calmOnCall.constructor.name !== "Container" || calmOnCall.render(100).length !== 0 || calmOnResult.constructor.name !== "Container" || calmOnResult.render(100).length !== 0) {
  throw new Error("fm_branch_outcomes remained visible while Calm was on");
}
pi.events.emit("firstmate:calm-presentation", { active: false, stockExportRendering: false });
if (outcomesTool.renderCall({}, renderTheme, renderContext).constructor.name !== "Box" || outcomesTool.renderResult(stockResult, { expanded: false, isPartial: false }, renderTheme, renderContext).constructor.name !== "Container") {
  throw new Error("fm_branch_outcomes did not restore ordinary rendering when Calm was turned off");
}
pi.events.emit("firstmate:calm-presentation", { active: true, stockExportRendering: true });
let exportCallFellBack = false;
let exportResultFellBack = false;
try {
  outcomesTool.renderCall({}, renderTheme, renderContext);
} catch {
  exportCallFellBack = true;
}
try {
  outcomesTool.renderResult(stockResult, { expanded: false, isPartial: false }, renderTheme, renderContext);
} catch {
  exportResultFellBack = true;
}
if (!exportCallFellBack || !exportResultFellBack) {
  throw new Error("fm_branch_outcomes replaced Pi stock export rendering");
}
const listed = await outcomesTool.execute("call-4", { recent: 2 }, undefined, undefined, {});
const listedText = listed.content[0].text;
if (listedText.split("\n").length !== 2 || !listedText.includes("checks green")) {
  throw new Error(`fm_branch_outcomes did not read the store: ${listedText}`);
}
if (!renderers.has("fm-branch-merge")) throw new Error("merge-note renderer missing");
const assertRenderedNote = (note, glyph) => {
  const fgCalls = [];
  const rendered = renderers.get("fm-branch-merge")(
    { content: note },
    { expanded: false },
    {
      fg(color, text) {
        fgCalls.push({ color, text });
        return text;
      },
    },
  );
  if (!String(rendered.text).includes(glyph)) throw new Error(`renderer dropped ${glyph}: ${rendered.text}`);
  if (String(rendered.text).includes("branch merged")) throw new Error(`renderer kept boilerplate: ${rendered.text}`);
  if (rendered.paddingX === 0 && rendered.paddingY === 0) {
    throw new Error("renderer still pads with 0,0 instead of outputPad");
  }
  if (rendered.paddingX !== 1 || rendered.paddingY !== 0) {
    throw new Error(
      `renderer padding should match real Pi messages (outputPad, 0), got ${rendered.paddingX},${rendered.paddingY}`,
    );
  }
  const glyphCalls = fgCalls.filter((call) => call.text === glyph);
  if (glyphCalls.length !== 1 || glyphCalls[0].color === "dim") {
    throw new Error(`icon ${glyph} must carry color, not dim: ${JSON.stringify(fgCalls)}`);
  }
  const restCalls = fgCalls.filter((call) => call.text !== glyph);
  if (restCalls.length === 0 || restCalls.some((call) => call.color !== "dim")) {
    throw new Error(`note remainder must be dim: ${JSON.stringify(fgCalls)}`);
  }
};
assertRenderedNote(sentToMain[0].message.content, "⛵");
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "branch dispatch, prefix contract, and two-stage filter must hold: $out"
  case "$out" in
    CACHE_KEY=fm-branch-*) ;;
    *) fail "cache key line missing from driver output: $out" ;;
  esac
  pass "branch owns accepted wakes with a stable prefix contract and verdict-driven merge delivery"

  # The delivered captain payload must identify itself to main's model. When it
  # did not, main could not tell an incoming outcome from its own earlier answer
  # and re-emitted that answer instead of relaying the outcome, silently losing
  # it. The real protocol executable is the oracle here: it decides the kind and
  # extracts the body, so this asserts delivered behavior rather than a shape
  # this test already knows.
  local kind body
  kind=$(./bin/fm-operational-input.sh kind < "$home/state/delivered-captain-note") \
    || fail "captain outcome reaches main's model as unattributed text the model cannot tell from its own answer"
  [ "$kind" = branch-outcome ] \
    || fail "captain outcome delivered as kind '$kind', not branch-outcome"
  body=$(./bin/fm-operational-input.sh body < "$home/state/delivered-captain-note") \
    || fail "captain outcome envelope carries no readable body"
  case "$body" in
    *"This is a supervision outcome delivered automatically by the supervision branch."*"It was not typed by the captain."*"task-9: PR https://example.com/pr/9"*) ;;
    *) fail "captain outcome body lost its self-description or the outcome itself: $body" ;;
  esac
  # Event ownership and conversational judgment are separate contracts. The
  # delivered instruction forbids reprocessing the fleet event but leaves main
  # free to decide how the outcome belongs in the captain conversation.
  case "$body" in
    *"The fleet event is already handled: do not re-drain, re-run, or acknowledge it."*) ;;
    *) fail "captain outcome body lost the event-ownership boundary: $body" ;;
  esac
  case "$body" in
    *"This outcome is captain-facing: give the captain a visible response now."*"Use your judgment over the wording and how to incorporate it, not whether to surface it."*) ;;
    *) fail "captain outcome body made visibility optional or removed wording judgment: $body" ;;
  esac
  case "$body" in
    *"An outcome that directly answers an explicit captain request is captain-facing"*"regardless of whether it is healthy, routine, measured, actionable, or requires a decision."*) ;;
    *) fail "captain outcome body lost the unconditional explicit-request rule: $body" ;;
  esac
  # The routine note is rendered in the TUI, and its renderer reads the glyph off
  # the front of this same string, so it must stay plain text.
  if ./bin/fm-operational-input.sh kind < "$home/state/delivered-routine-note" >/dev/null 2>&1; then
    fail "routine note must stay plain rendered text, not typed operational input"
  fi
  pass "a captain outcome reaches main's model as typed, self-describing input while routine notes stay plain"
}

test_requested_healthy_outcome_and_unsolicited_routine_outcome_delivery() {
  local repo home out status
  repo="$TMP_ROOT/requested-outcome-root"
  home="$TMP_ROOT/requested-outcome-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, sentToMain, outcomeScript, mainTools, home, realRoot }; })()`);
const { fire, dispatch, settle, sentToMain, outcomeScript, mainTools, home, realRoot } = globalThis.__t;
import { existsSync, readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";

const fleetOperations = [];
globalThis.__fmExecuteBranchBash = async (context) => {
  const actor = spawnSync(
    "bash",
    ["-c", '. "$1"; fm_lease_actor', "_", `${realRoot}/bin/fm-lease-lib.sh`],
    { encoding: "utf8", cwd: context.cwd, env: context.env },
  );
  if (actor.status !== 0) throw new Error(`branch bash actor resolution failed: ${actor.stderr}`);
  const result = spawnSync("bash", ["-c", context.command], {
    encoding: "utf8",
    cwd: context.cwd,
    env: context.env,
  });
  fleetOperations.push({ command: context.command, actor: actor.stdout.trim(), status: result.status });
  return {
    content: [{ type: "text", text: `${result.stdout}${result.stderr}` }],
    details: { stdout: result.stdout, stderr: result.stderr, exitCode: result.status, actor: actor.stdout.trim() },
    isError: result.status !== 0,
  };
};

async function runFleetCommand(session, args) {
  const bash = session.options.customTools.find((tool) => tool.name === "bash");
  const command = ["bin/fm-wake-drain.sh", ...args].join(" ");
  const result = await bash.execute(`fleet-${fleetOperations.length}`, { command }, undefined, undefined, {});
  if (result.isError) throw new Error(`fleet command failed: ${JSON.stringify(result)}`);
  return result.details;
}

function directlyRequestsResourceReport(mirror) {
  const latestCaptain = mirror.at(-1) ?? "";
  const words = new Set(latestCaptain.toLowerCase().split(/[^a-z0-9]+/).filter(Boolean));
  const requestsDelivery = ["give", "provide", "send", "show"].some((word) => words.has(word));
  const namesReport = ["report", "status", "measurement"].some((word) => words.has(word));
  const namesResources = ["resource", "resources", "cpu", "memory"].some((word) => words.has(word));
  return requestsDelivery && namesReport && namesResources;
}

globalThis.__fmOnBranchPrompt = async ({ session }) => {
  const mirror = session.ops
    .filter((op) => op.kind === "custom" && op.message.customType === "fm-main-mirror")
    .map((op) => op.message.content);
  const directlyRequested = directlyRequestsResourceReport(mirror);
  const drained = await runFleetCommand(session, []);
  const ack = drained.stderr.match(/--ack-through ([0-9]+) --recovery-generation ([A-Za-z0-9._-]+)/);
  if (!ack) throw new Error(`drain did not return its acknowledgement command: ${drained.stderr}`);
  const report = session.options.customTools.find((tool) => tool.name === "fm_branch_report");
  const verdictDescription = report.parameters.properties.verdict.description;
  if (!verdictDescription.includes("unconditionally") ||
      !verdictDescription.includes("directly answers an explicit captain request") ||
      !verdictDescription.includes("regardless of whether it is healthy, routine, measured, actionable, or requires a decision")) {
    throw new Error(`branch provider received conflicting verdict semantics: ${verdictDescription}`);
  }
  const result = await report.execute(
    `resource-result-${fleetOperations.length}`,
    {
      task: "task-resource",
      verdict: directlyRequested ? "captain" : "routine",
      summary: "healthy resource report: CPU 12%, memory 41%",
      wake: "signal: healthy resource result",
    },
    undefined,
    undefined,
    {},
  );
  if (result.isError) throw new Error(`branch report failed: ${JSON.stringify(result)}`);
  await runFleetCommand(session, ["--ack-through", ack[1], "--recovery-generation", ack[2]]);
};

const explicitRequest = "Please give me a fresh mini system-resource report.";
const longRequests = [
  `${explicitRequest}${" head context".repeat(500)}`,
  `${"middle context ".repeat(250)}${explicitRequest}${" middle context".repeat(250)}`,
  `${"tail context ".repeat(500)}${explicitRequest}`,
];
const requestedPrompts = [...longRequests, "FIRSTMATE give me a fresh system-resource report."];
// Match Pi's real AgentSession.prompt ordering: before_agent_start receives
// the expanded prompt before _runAgentPrompt appends its user message to the
// SessionManager. Keeping entries stale at the hook boundary is the regression.
const entries = [];
const mainCtx = {
  model: { provider: "anthropic", id: "main-model" },
  sessionManager: {
    getSessionFile: () => `${home}/main.jsonl`,
    getEntries: () => entries,
  },
};
const operational = spawnSync(
  "bash",
  [`${realRoot}/bin/fm-operational-input.sh`, "encode", "watcher"],
  { encoding: "utf8", input: "operational watcher injection" },
);
if (operational.status !== 0) throw new Error(`could not create operational input: ${operational.stderr}`);
fire("before_agent_start", { prompt: operational.stdout }, mainCtx);
entries.push({ type: "message", message: { role: "user", content: operational.stdout } });
const unsolicitedPrompt = "Please keep responses concise while monitoring the fleet.";
fire("before_agent_start", { prompt: unsolicitedPrompt }, mainCtx);
entries.push({ type: "message", message: { role: "user", content: unsolicitedPrompt } });
fire("agent_start", {}, mainCtx);
fire("agent_end", {}, mainCtx);
const legacyOperational = "⁣FIRSTMATE_OP: give me a fresh system-resource report.";
fire("before_agent_start", { prompt: legacyOperational }, mainCtx);
entries.push({ type: "message", message: { role: "user", content: legacyOperational } });
fire("agent_start", {}, mainCtx);
const unsolicited = dispatch("signal: healthy resource result");
if (!unsolicited.accepted) throw new Error("branch did not accept the unsolicited result");
await settle(() => fleetOperations.length === 2, "unsolicited result acknowledgement");
if (sentToMain.length !== 1 || sentToMain[0].options.triggerTurn) {
  throw new Error(`unsolicited healthy result opened a main turn: ${JSON.stringify(sentToMain)}`);
}
const sailboat = sentToMain[0];
if (sailboat.message.display !== true || !sailboat.message.content.startsWith("⛵ task-resource:")) {
  throw new Error(`unsolicited healthy result was not a rendered sailboat note: ${JSON.stringify(sailboat)}`);
}

const outcomes = mainTools.find((tool) => tool.name === "fm_branch_outcomes");
if (!outcomes) throw new Error("main did not receive its outcome-reading permission surface");
const visibleToMain = await outcomes.execute("main-reads-sailboat", { recent: 1 }, undefined, undefined, {});
const mainOutcomeText = visibleToMain.content.map((item) => item.text ?? "").join("\n");
if (visibleToMain.isError || !mainOutcomeText.includes("healthy resource report: CPU 12%, memory 41%")) {
  throw new Error(`main could not use the sailboat content through its existing permission path: ${JSON.stringify(visibleToMain)}`);
}
if (fleetOperations.length !== 2) throw new Error("main's outcome read reprocessed the fleet event");

for (let index = 0; index < requestedPrompts.length; index += 1) {
  const content = requestedPrompts[index];
  if (index < longRequests.length && content.length <= 4000) {
    throw new Error(`request fixture ${index} did not exceed the mirror bound`);
  }
  fire("before_agent_start", { prompt: content }, mainCtx);
  // Pi persists this only after every before_agent_start handler has returned.
  entries.push({ type: "message", message: { role: "user", content } });
  fire("agent_start", {}, mainCtx);
  const requested = dispatch("signal: healthy resource result");
  if (!requested.accepted) throw new Error(`branch did not accept requested result ${index}`);
  await settle(() => fleetOperations.length === 4 + (index * 2), `requested result ${index} acknowledgement`);
  const deliveredRequestMirror = globalThis.__fmSessions[0].ops
    .filter((op) => op.kind === "custom" && op.message.customType === "fm-main-mirror")
    .at(-1)?.message.content;
  if (deliveredRequestMirror !== `[captain] ${content}`) {
    throw new Error(`pre-turn-end mirror changed long captain request ${index}`);
  }
  const turns = sentToMain.filter((sent) => sent.options.triggerTurn === true);
  if (turns.length !== index + 1 || turns.at(-1).options.deliverAs !== "followUp") {
    throw new Error(`requested result ${index} did not open exactly one main turn: ${JSON.stringify(sentToMain)}`);
  }
}
const mirroredCaptainText = globalThis.__fmSessions[0].ops
  .filter((op) => op.kind === "custom" && op.message.customType === "fm-main-mirror")
  .map((op) => op.message.content);
for (const content of [unsolicitedPrompt, ...requestedPrompts]) {
  const copies = mirroredCaptainText.filter((text) => text === `[captain] ${content}`).length;
  if (copies !== 1) throw new Error(`current captain prompt was mirrored ${copies} times instead of once`);
}
if (mirroredCaptainText.some((text) =>
  text.includes("operational watcher injection") || text.includes("FIRSTMATE_OP: give me a fresh system-resource report")
)) {
  throw new Error("canonical current or legacy operational input entered captain mirror context");
}
if ((globalThis.__fmPrompts ?? []).length !== 5) throw new Error("a handled fleet wake was rerun");
if (sentToMain.length !== 5) throw new Error(`one result was reprocessed into ${sentToMain.length} main messages`);
if (fleetOperations.length !== 10 || fleetOperations.some((operation) => operation.status !== 0)) {
  throw new Error(`fleet event ownership repeated or failed work: ${JSON.stringify(fleetOperations)}`);
}
if (fleetOperations.some((operation) => operation.actor !== "branch")) {
  throw new Error(`main took fleet-event ownership: ${JSON.stringify(fleetOperations)}`);
}
if (existsSync(`${home}/state/.wake-queue`) && readFileSync(`${home}/state/.wake-queue`, "utf8") !== "") {
  throw new Error("acknowledged fleet wake remained queued for another owner");
}
const rows = readFileSync(`${home}/state/branch-outcomes.jsonl`, "utf8").trim().split("\n").map((line) => JSON.parse(line));
if (rows.length !== 5 || rows[0].verdict !== "routine" || rows.slice(1).some((row) => row.verdict !== "captain")) {
  throw new Error(`provider classifications were not recorded once in order: ${JSON.stringify(rows)}`);
}
if (outcomeScript(["unread"]) !== "") throw new Error("merged outcomes remained unread for redelivery");
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "requested and unsolicited healthy outcomes must follow their distinct public delivery paths: $out"
  pass "requested and unsolicited healthy outcomes keep distinct delivery and event ownership"
}

test_captain_outcome_encoding_failure_delivers_plain_instruction() {
  local repo home out status
  repo="$TMP_ROOT/encoding-fallback-root"
  home="$TMP_ROOT/encoding-fallback-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_OPERATIONAL_INPUT_SCRIPT="$repo/bin/missing-operational-input" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { dispatch, settle, sentToMain }; })()`);
const { dispatch, settle, sentToMain } = globalThis.__t;

if (!dispatch("signal: encoding fallback probe").accepted) {
  throw new Error("branch did not accept the encoding-fallback wake");
}
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "encoding-fallback branch prompt");
const session = globalThis.__fmSessions[0];
const report = session.options.customTools.find((tool) => tool.name === "fm_branch_report");
const result = await report.execute(
  "encoding-fallback",
  { task: "task-fallback", verdict: "captain", summary: "PR https://example.com/pr/fallback is ready" },
  undefined,
  undefined,
  {},
);
if (result.isError) throw new Error(`fallback report failed: ${JSON.stringify(result)}`);
if (sentToMain.length !== 1) throw new Error(`fallback delivered ${sentToMain.length} notes instead of one`);
const delivered = sentToMain[0];
if (delivered.message.display !== false) throw new Error("fallback captain note became visible");
if (delivered.options.triggerTurn !== true || delivered.options.deliverAs !== "followUp") {
  throw new Error(`fallback changed turn delivery: ${JSON.stringify(delivered.options)}`);
}
if (delivered.message.content.includes("FIRSTMATE_OP:")) {
  throw new Error(`fallback unexpectedly carried an envelope: ${delivered.message.content}`);
}
if (!delivered.message.content.includes("The fleet event is already handled: do not re-drain, re-run, or acknowledge it.") ||
    !delivered.message.content.includes("This outcome is captain-facing: give the captain a visible response now.") ||
    !delivered.message.content.includes("Use your judgment over the wording and how to incorporate it, not whether to surface it.") ||
    !delivered.message.content.includes("task-fallback: PR https://example.com/pr/fallback is ready")) {
  throw new Error(`fallback lost its instruction or outcome: ${delivered.message.content}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "captain outcome encoding failure must degrade to plain instructed delivery: $out"
  pass "a broken operational encoder still delivers one invisible instructed captain outcome as a follow-up"
}

test_branch_cache_key_is_per_home_stable() {
  local repo home_a home_b key_a1 key_a2 key_b
  repo="$TMP_ROOT/cache-key-root"
  home_a="$TMP_ROOT/cache-key-home-a"
  home_b="$TMP_ROOT/cache-key-home-b"
  mkdir -p "$home_a/state" "$home_a/config" "$home_b/state" "$home_b/config"
  install_pi_branch_extension_fixture "$repo"
  probe() {
    PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" \
      DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { dispatch, settle }; })()`);
const { dispatch, settle } = globalThis.__t;
dispatch("signal: cache probe");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "branch wake prompt");
const loader = globalThis.__fmLoaders[0];
const entry = loader.options.extensionFactories[0];
let handler = null;
(typeof entry === "function" ? entry : entry.factory)({ on: (e, h) => { if (e === "before_provider_request") handler = h; } });
const rewritten = handler({ type: "before_provider_request", payload: { prompt_cache_key: "x" } });
console.log(rewritten.prompt_cache_key);
process.exit(0);
EOF
  }
  key_a1=$(probe "$home_a") || fail "cache-key probe A1 failed: $key_a1"
  key_a2=$(probe "$home_a") || fail "cache-key probe A2 failed: $key_a2"
  key_b=$(probe "$home_b") || fail "cache-key probe B failed: $key_b"
  [ -n "$key_a1" ] || fail "empty cache key from probe A1"
  [ "$key_a1" = "$key_a2" ] || fail "cache key not stable across branch sessions in one home: $key_a1 vs $key_a2"
  [ "$key_a1" != "$key_b" ] || fail "cache key does not separate homes: $key_a1"
  pass "branch prompt_cache_key is stable per home across sessions and distinct between homes"
}

test_branch_default_on_heartbeat_afk_and_fallback() {
  local repo broken home out status
  repo="$TMP_ROOT/gating-root"
  broken="$TMP_ROOT/gating-broken-root"
  home="$TMP_ROOT/gating-home"
  mkdir -p "$home/state" "$home/config" "$broken/bin"
  install_pi_branch_extension_fixture "$repo"
  cp "$ROOT/bin/fm-lease.sh" "$ROOT/bin/fm-lease-lib.sh" "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-wake-grant.sh" "$broken/bin/"
  cat > "$broken/bin/fm-branch-prompt.sh" <<'SH'
#!/usr/bin/env bash
echo "synthetic generator failure" >&2
exit 1
SH
  chmod +x "$broken/bin/fm-branch-prompt.sh"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { dispatch, fire, settle, home, sentToMain }; })()`);
const { dispatch, fire, settle, home, sentToMain } = globalThis.__t;
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";

// Default-on: with no config/pi-supervision-branch grant file present at
// all (this driver never writes one), a task-scoped wake is still accepted
// and activation still runs.
if (existsSync(`${home}/config/pi-supervision-branch`)) {
  throw new Error("test fixture unexpectedly wrote a grant file");
}
fire("session_start", {});
if (!dispatch("signal: default-on task wake").accepted) {
  throw new Error("a task-scoped wake was refused with no grant file present");
}
if (!existsSync(`${home}/state/.pi-branch-extension-loaded`)) {
  throw new Error("default-on activation did not write the diagnostic marker");
}
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "default-on task wake prompt");

// The real watcher emits a bare heartbeat only after its cheap bash scan has
// flagged a fleet pass as possibly captain-relevant. The branch accepts that
// wake without a resolved project and performs the deeper review.
if (!dispatch("heartbeat", [], true, true).accepted) {
  throw new Error("eligible heartbeat offer was refused");
}
if (dispatch("heartbeat", [], true, false).accepted) {
  throw new Error("heartbeat with a main-owned queue row was accepted");
}
await settle(() => (globalThis.__fmPrompts ?? []).length === 2, "heartbeat wake prompt");

// The branch can downgrade its deeper review to a silent routine outcome or
// escalate a captain-worthy finding into one main turn.
const heartbeatSession = globalThis.__fmSessions[globalThis.__fmSessions.length - 1];
const heartbeatReport = heartbeatSession.options.customTools.find((tool) => tool.name === "fm_branch_report");
await heartbeatReport.execute(
  "heartbeat-noop",
  { task: "fleet", verdict: "routine", summary: "fleet reviewed, nothing changed", silent: true },
  undefined,
  undefined,
  {},
);
const noopMerge = sentToMain[sentToMain.length - 1];
if (noopMerge.options.triggerTurn) throw new Error("a no-op heartbeat pass must not open a main turn");
if (noopMerge.message.display !== false) throw new Error("a no-op heartbeat pass must not render a merge note");
const storedNoop = readFileSync(`${home}/state/branch-outcomes.jsonl`, "utf8")
  .trim()
  .split("\n")
  .map((line) => JSON.parse(line))
  .find((row) => row.task === "fleet" && row.summary === "fleet reviewed, nothing changed");
if (!storedNoop || storedNoop.verdict !== "routine" || storedNoop.silent !== true) {
  throw new Error("the silent no-op heartbeat disposition was not stored durably");
}
await heartbeatReport.execute(
  "fleet-routine-action",
  { task: "fleet", verdict: "routine", summary: "reconciled the backlog after completed work" },
  undefined,
  undefined,
  {},
);
const fleetRoutineMerge = sentToMain[sentToMain.length - 1];
if (fleetRoutineMerge.message.display !== true) throw new Error("a fleet routine action must render");
if (!fleetRoutineMerge.message.content.startsWith("⛵ fleet: reconciled the backlog after completed work")) {
  throw new Error(`fleet routine action note changed: ${fleetRoutineMerge.message.content}`);
}
await heartbeatReport.execute(
  "task-routine",
  { task: "task-9", verdict: "routine", summary: "worker healthy, no action needed" },
  undefined,
  undefined,
  {},
);
const taskRoutineMerge = sentToMain[sentToMain.length - 1];
if (taskRoutineMerge.message.display !== true) throw new Error("a task-scoped routine outcome must render");
if (!taskRoutineMerge.message.content.startsWith("⛵ task-9: worker healthy, no action needed")) {
  throw new Error(`task-scoped routine note changed: ${taskRoutineMerge.message.content}`);
}
await heartbeatReport.execute(
  "heartbeat-finding",
  { task: "fleet", verdict: "captain", summary: "task-2 has been stuck for an hour" },
  undefined,
  undefined,
  {},
);
const captainMerge = sentToMain[sentToMain.length - 1];
if (captainMerge.options.triggerTurn !== true) throw new Error("a captain-worthy heartbeat finding must open a main turn");
if (captainMerge.message.display !== false) throw new Error("the heartbeat captain-facing note must not be printed");

// Every other fleet-wide or unresolvable wake (empty projects, not a
// heartbeat) still keeps the wake-to-main path.
if (dispatch("check: unresolved fleet event", []).accepted) {
  throw new Error("branch accepted an unscoped, non-heartbeat fleet wake");
}

// Away mode still owns supervision regardless of default-on eligibility.
writeFileSync(`${home}/state/.afk`, "");
if (dispatch("signal: while afk").accepted) throw new Error("branch accepted a wake during away mode");
rmSync(`${home}/state/.afk`);
if (!dispatch("signal: gates cleared").accepted) throw new Error("branch refused a wake with gates cleared");
await settle(() => (globalThis.__fmPrompts ?? []).length === 3, "branch wake prompts");
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "default-on eligibility, heartbeat routing, and afk gating must bind: $out"

  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$TMP_ROOT/gating-home-2" FM_ROOT_OVERRIDE="$broken" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { dispatch, settle, mainUserMessages }; })()`);
const { dispatch, settle, mainUserMessages } = globalThis.__t;

// A branch that cannot come up must degrade to today's behavior: the accepted
// wake falls back to main with the failure named, and later wakes are no
// longer accepted (no wake is ever lost).
if (!dispatch("signal: first wake").accepted) throw new Error("first offer was not accepted");
await settle(() => mainUserMessages.length === 1, "fallback delivery to main");
const fallback = mainUserMessages[0].content;
if (!fallback.includes("FIRSTMATE WATCHER WAKE: signal: first wake")) throw new Error(`fallback lost the wake: ${fallback}`);
if (!fallback.includes("Supervision branch unavailable")) throw new Error(`fallback did not name the branch failure: ${fallback}`);
if (mainUserMessages[0].options.deliverAs !== "followUp") throw new Error("fallback must deliver as a follow-up");
if (dispatch("signal: second wake").accepted) throw new Error("broken branch kept accepting wakes");
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "broken-branch fallback must return wakes to main: $out"
  pass "branch default-on eligibility (task-scoped, heartbeat, afk) binds and a broken branch falls back to main"
}

test_branch_predrain_recheck_keeps_a_heartbeat_a_co_present_check_arrives_under() {
  local repo home out status
  repo="$TMP_ROOT/predrain-recheck-root"
  home="$TMP_ROOT/predrain-recheck-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { dispatch, fire, home, mainUserMessages }; })()`);
const { dispatch, fire, home, mainUserMessages } = globalThis.__t;
import { appendFileSync, readFileSync } from "node:fs";

fire("session_start", {});
let releasePrompt;
globalThis.__fmPromptGate = new Promise((resolve) => { releasePrompt = resolve; });
const offer = dispatch("heartbeat", [], true, true);
if (!offer.accepted) throw new Error("eligible heartbeat offer was not accepted");
// A main-only notice arrives between offer acceptance and the branch's own
// drain. It must not carry the fleet review into the captain's chat.
appendFileSync(`${home}/state/.wake-queue`, "2\t2\tcheck\tx-inbox\tcheck: pending x mention\n");
for (let i = 0; i < 250 && !globalThis.__fmPromptStarted && mainUserMessages.length === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (mainUserMessages.length !== 0) {
  throw new Error(`a co-present check row rode the heartbeat into main: ${JSON.stringify(mainUserMessages)}`);
}
if (!globalThis.__fmPromptStarted) {
  throw new Error("the branch was never prompted even though the heartbeat stayed eligible");
}
const snapshot = readFileSync(`${home}/state/.branch-eligible-rows`, "utf8").trim().split("\n");
if (!snapshot.includes("1")) throw new Error(`eligible-row snapshot omitted the heartbeat row: ${snapshot}`);
if (snapshot.includes("2")) throw new Error(`eligible-row snapshot granted the main-owned row: ${snapshot}`);
releasePrompt();
const queue = readFileSync(`${home}/state/.wake-queue`, "utf8");
if (!queue.includes("\theartbeat\t") || !queue.includes("\tcheck\t")) {
  throw new Error(`the pre-drain recheck mutated the queued set: ${queue}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "a co-present check row must not carry a heartbeat review into main: $out"
  pass "a heartbeat review survives a check row arriving before its drain"
}

# The non-heartbeat half of the same recheck: a check-kind row that arrives
# after a signal/stale offer is accepted must stay main-owned WITHOUT bouncing
# the branch's own eligible row back to main
# (docs/watcher-continuity.md "Per-actor acknowledgement"). A check row is
# main-owned in every mode, so the heartbeat case proven above and this one
# resolve the same way.
test_branch_predrain_recheck_excludes_new_main_owned_row_without_deferring_eligible_work() {
  local repo home out status
  repo="$TMP_ROOT/predrain-partial-root"
  home="$TMP_ROOT/predrain-partial-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { dispatch, fire, home, mainUserMessages }; })()`);
const { dispatch, fire, home, mainUserMessages } = globalThis.__t;
import { appendFileSync, existsSync, readFileSync } from "node:fs";

fire("session_start", {});
let releasePrompt;
globalThis.__fmPromptGate = new Promise((resolve) => { releasePrompt = resolve; });
const offer = dispatch("signal: task-local wake");
if (!offer.accepted) throw new Error("eligible task-local offer was not accepted");
// A main-only notice arrives while main is still finishing its own earlier
// turn - unacked, still sitting in the queue - between offer acceptance and
// the branch's own drain.
appendFileSync(`${home}/state/.wake-queue`, "2\t2\tcheck\tx-inbox\tcheck: pending x mention\n");
for (let i = 0; i < 250 && !globalThis.__fmPromptStarted && mainUserMessages.length === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (mainUserMessages.length !== 0) {
  throw new Error(`a co-present main-owned row bounced the whole mixed queue to main: ${JSON.stringify(mainUserMessages)}`);
}
if (!globalThis.__fmPromptStarted) {
  throw new Error("the branch was never prompted even though its own row stayed eligible");
}
const snapshot = readFileSync(`${home}/state/.branch-eligible-rows`, "utf8").trim().split("\n");
if (!snapshot.includes("1")) throw new Error(`eligible-row snapshot omitted the task-local row: ${snapshot}`);
if (snapshot.includes("2")) throw new Error(`eligible-row snapshot granted the main-owned row: ${snapshot}`);
const queue = readFileSync(`${home}/state/.wake-queue`, "utf8");
if (!queue.includes("\tcheck\tx-inbox\t")) {
  throw new Error(`the main-owned row must remain queued for main, untouched: ${queue}`);
}
releasePrompt();
for (let i = 0; i < 250 && (globalThis.__fmPrompts ?? []).length === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
for (let i = 0; i < 250 && existsSync(`${home}/state/.branch-eligible-rows`); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (existsSync(`${home}/state/.branch-eligible-rows`)) {
  throw new Error("settled branch prompt retained its row grant");
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "pre-drain eligibility re-check must exclude only the new main-owned row: $out"
  pass "pre-drain eligibility re-check excludes a newly main-owned row without deferring eligible work"
}

test_settled_branch_prompt_releases_unacknowledged_grant() {
  local repo home out status
  repo="$TMP_ROOT/settled-grant-root"
  home="$TMP_ROOT/settled-grant-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { dispatch, fire, home, realRoot }; })()`);
const { dispatch, fire, home, realRoot } = globalThis.__t;
const { spawnSync } = await import("node:child_process");
const { existsSync } = await import("node:fs");

fire("session_start", {});
if (!dispatch("signal: unacknowledged branch wake").accepted) {
  throw new Error("eligible wake was not accepted");
}
for (let i = 0; i < 250 && (globalThis.__fmPrompts ?? []).length === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if ((globalThis.__fmPrompts ?? []).length !== 1) throw new Error("branch prompt did not settle");
for (let i = 0; i < 250 && existsSync(`${home}/state/.branch-eligible-rows`); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (existsSync(`${home}/state/.branch-eligible-rows`)) {
  throw new Error("settled prompt left its unacknowledged grant active");
}
const drain = spawnSync("bash", [`${realRoot}/bin/fm-wake-drain.sh`], {
  encoding: "utf8",
  env: { ...process.env, FM_HOME: home, FM_STATE_OVERRIDE: `${home}/state`, FM_ROOT_OVERRIDE: realRoot },
});
if (drain.status !== 0) throw new Error(`main drain failed after grant release: ${drain.stderr}`);
if (!drain.stdout.includes("\tsignal\tbranch-driver.status\t")) {
  throw new Error(`main could not replay the unacknowledged branch row: ${drain.stdout}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "settled branch turns must release residual grants for main replay: $out"
  pass "a settled branch turn releases an unacknowledged grant for main replay"
}

test_main_owned_grant_result_falls_back_to_main() {
  local repo home out status
  repo="$TMP_ROOT/main-owned-fallback-root"
  home="$TMP_ROOT/main-owned-fallback-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { dispatch, fire, home, mainUserMessages }; })()`);
const { dispatch, fire, home, mainUserMessages } = globalThis.__t;
import { writeFileSync } from "node:fs";

fire("session_start", {});
const offer = dispatch("signal: interrupted main claim");
if (!offer.accepted) throw new Error("eligible wake was not accepted before the ownership recheck");
writeFileSync(`${home}/state/.main-eligible-rows`, "1\n");
for (let i = 0; i < 250 && mainUserMessages.length === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if ((globalThis.__fmPrompts ?? []).length !== 0) {
  throw new Error("branch prompted for a row already claimed by main");
}
if (mainUserMessages.length !== 1) {
  throw new Error(`main-owned row was silently absorbed: ${JSON.stringify(mainUserMessages)}`);
}
if (!String(mainUserMessages[0].content).includes("FIRSTMATE WATCHER WAKE: signal: interrupted main claim")) {
  throw new Error(`fallback lost the durable wake: ${mainUserMessages[0].content}`);
}
if (mainUserMessages[0].options.deliverAs !== "followUp") {
  throw new Error("main-owned fallback was not delivered as a follow-up");
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "a main-owned grant result must still deliver the wake to main: $out"
  pass "a stale main claim cannot silently suppress later wake delivery"
}

test_branch_predrain_recheck_noops_already_drained_wake() {
  local repo home out status
  repo="$TMP_ROOT/predrain-empty-root"
  home="$TMP_ROOT/predrain-empty-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { dispatch, fire, home, mainUserMessages }; })()`);
const { dispatch, fire, home, mainUserMessages } = globalThis.__t;
import { writeFileSync } from "node:fs";

fire("session_start", {});
let releaseFirst;
globalThis.__fmPromptGate = new Promise((resolve) => {
  releaseFirst = resolve;
});
if (!dispatch("signal: first queued wake").accepted) throw new Error("first wake was not accepted");
for (let i = 0; i < 250 && !globalThis.__fmPromptStarted; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (!globalThis.__fmPromptStarted) throw new Error("first branch prompt did not start");
if (!dispatch("heartbeat", [], true, true).accepted) throw new Error("queued heartbeat was not accepted");
writeFileSync(`${home}/state/.wake-queue`, "");
releaseFirst();
for (let i = 0; i < 250 && (globalThis.__fmPrompts ?? []).length < 1; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
await new Promise((resolve) => setTimeout(resolve, 50));
if ((globalThis.__fmPrompts ?? []).length !== 1) {
  throw new Error(`already-drained wake prompted again: ${JSON.stringify(globalThis.__fmPrompts ?? [])}`);
}
if (mainUserMessages.length !== 0) {
  throw new Error(`already-drained wake fell back to main: ${JSON.stringify(mainUserMessages)}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "an already-drained serialized wake must no-op without main fallback: $out"
  pass "pre-drain eligibility re-check no-ops an already-drained wake"
}

test_branch_mirror_filters_order_and_cursor() {
  local repo home out status
  repo="$TMP_ROOT/mirror-root"
  home="$TMP_ROOT/mirror-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, home }; })()`);
const { fire, dispatch, settle, home } = globalThis.__t;
import { existsSync, readFileSync } from "node:fs";

const entries = [
  { type: "message", message: { role: "user", content: `never merge task-7 without my word ${"h".repeat(5000)} old-history-tail` } },
  { type: "message", message: { role: "assistant", content: [{ type: "text", text: "aye, holding task-7" }, { type: "toolCall", id: "t1" }] } },
  { type: "message", message: { role: "user", content: "⁣FIRSTMATE_OP: v1 watcher: operational injection" } },
  { type: "message", message: { role: "toolResult", content: "tool output stays in main" } },
  { type: "custom", message: { role: "custom", customType: "fm-branch-merge", content: "merged note" } },
  { type: "compaction", summary: "compacted" },
  { type: "message", message: { role: "user", content: `pad ${"x".repeat(5000)}\ntail: retain this request` } },
];
const ctx = {
  sessionManager: {
    getSessionFile: () => `${home}/main-1.jsonl`,
    getEntries: () => entries,
  },
};

// Dialog collected at main's turn_end, delivered into the branch BEFORE the
// next wake, tagged and filtered: no tool traffic, no operational injections,
// no merge notes, long messages capped.
fire("turn_end", {}, ctx);
dispatch("signal: after mirror");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "branch wake prompt");
const session = globalThis.__fmSessions[0];
const kinds = session.ops.map((op) => op.kind);
if (JSON.stringify(kinds) !== JSON.stringify(["custom", "custom", "custom", "prompt"])) {
  throw new Error(`mirror must land before the wake: ${JSON.stringify(kinds)}`);
}
const mirrored = session.ops.filter((op) => op.kind === "custom").map((op) => op.message);
if (mirrored.some((m) => m.customType !== "fm-main-mirror")) throw new Error("mirror used the wrong custom type");
if (mirrored.some((m) => m.display !== false)) throw new Error("mirrored context must be silent");
if (!mirrored[0].content.startsWith("[captain] never merge task-7 without my word") ||
    !mirrored[0].content.includes("[mirror truncated:") ||
    !mirrored[0].content.endsWith("old-history-tail")) {
  throw new Error(`older captain history was not bounded: ${mirrored[0].content}`);
}
if (mirrored[1].content !== "[main] aye, holding task-7") throw new Error(`bad main mirror: ${mirrored[1].content}`);
if (mirrored[2].content !== `[captain] ${entries[6].message.content}`) {
  throw new Error("current captain dialog was not preserved completely");
}
if (mirrored.some((m) => m.content.includes("operational injection") || m.content.includes("tool output") || m.content.includes("merged note"))) {
  throw new Error("mirror leaked operational, tool, or merge-note traffic");
}

// The durable cursor advances: a second turn_end mirrors only NEW dialog.
entries.push({ type: "message", message: { role: "user", content: "actually, task-7 may merge when green" } });
fire("turn_end", {}, ctx);
await settle(() => session.ops.filter((op) => op.kind === "custom").length === 4, "incremental mirror");
const latest = session.ops[session.ops.length - 1];
if (latest.message.content !== "[captain] actually, task-7 may merge when green") {
  throw new Error(`incremental mirror re-sent old dialog or lost the new line: ${latest.message.content}`);
}
if (!existsSync(`${home}/state/.branch-mirror-cursor`)) throw new Error("mirror cursor is not durable");
const cursor = JSON.parse(readFileSync(`${home}/state/.branch-mirror-cursor`, "utf8"));
if (cursor.file !== `${home}/main-1.jsonl` || cursor.index !== entries.length) {
  throw new Error(`cursor did not advance with the session file: ${JSON.stringify(cursor)}`);
}

// A replacement main session re-anchors: dialog mirrors from its start.
const ctx2 = {
  sessionManager: {
    getSessionFile: () => `${home}/main-2.jsonl`,
    getEntries: () => [{ type: "message", message: { role: "user", content: "fresh session standing order" } }],
  },
};
fire("turn_end", {}, ctx2);
await settle(() => session.ops.filter((op) => op.kind === "custom").length === 5, "replacement-session mirror");
const fresh = session.ops[session.ops.length - 1];
if (fresh.message.content !== "[captain] fresh session standing order") {
  throw new Error(`replacement session did not re-anchor the mirror: ${fresh.message.content}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "mirror filtering, ordering, and cursor must hold: $out"
  pass "dialog mirror filters tool and operational traffic, lands before wakes, and keeps a durable cursor"
}

test_branch_session_persists_across_process_restarts() {
  local repo home out status
  repo="$TMP_ROOT/persist-root"
  home="$TMP_ROOT/persist-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  run_once() {
    PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { dispatch, settle }; })()`);
const { dispatch, settle } = globalThis.__t;
dispatch("signal: persistence probe");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "branch wake prompt");
const sm = globalThis.__fmSessionManagers[0];
console.log(`${sm.opened ? "opened" : "created"} ${sm.getSessionFile()}`);
process.exit(0);
EOF
  }
  out=$(run_once) || fail "first branch session run failed: $out"
  # Path.join normalizes the doubled slash macOS TMPDIR introduces, so match
  # on the home-relative tail rather than the raw $home prefix.
  case "$out" in
    "created "*"/persist-home/state/branch-session/"*.jsonl) ;;
    *) fail "first run did not create a session under state/branch-session: $out" ;;
  esac
  first_file=${out#created }
  [ -f "$home/state/.branch-session" ] || fail "branch session pointer was not recorded"
  out=$(run_once) || fail "second branch session run failed: $out"
  [ "$out" = "opened $first_file" ] \
    || fail "restart did not reopen the persistent branch session (got: $out; want: opened $first_file)"
  pass "branch session persists across process restarts through the recorded pointer"
}

test_branch_model_pin_applies_and_absent_pin_keeps_the_default() {
  local repo home out status
  repo="$TMP_ROOT/modelpin-root"
  home="$TMP_ROOT/modelpin-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, makeCtx, registryModels, home }; })()`);
const { fire, dispatch, settle, makeCtx, registryModels, home } = globalThis.__t;
import { rmSync, writeFileSync } from "node:fs";

registryModels.push({ provider: "anthropic", id: "main-model" }, { provider: "openai", id: "cheap-1" });

// 1. No pin and main's model not known yet: the build falls back to the
// pre-feature path of passing no override rather than refusing to build, so
// a wake is never lost over model choice.
fire("session_start", {});
dispatch("signal: main model unknown");
await settle(() => (globalThis.__fmSessions ?? []).length === 1, "unknown-main-model branch build");
if ("model" in globalThis.__fmSessions[0].options) {
  throw new Error("an unknown main model must fall back to passing no model override");
}

// 2. No pin, main's model known: the branch follows MAIN's own model,
// applied explicitly.
fire("session_shutdown", {});
fire("session_start", {}, makeCtx());
dispatch("signal: unpinned probe");
await settle(() => (globalThis.__fmSessions ?? []).length === 2, "unpinned branch build");
const unpinned = globalThis.__fmSessions[1].options.model;
if (!unpinned || unpinned.provider !== "anthropic" || unpinned.id !== "main-model") {
  throw new Error(`an absent pin must follow main's own model: ${JSON.stringify(unpinned)}`);
}

// 3. Pin present: the very next build carries exactly that model, resolved
// out of Pi's own catalog.
writeFileSync(`${home}/config/supervision-branch-model`, "openai/cheap-1\n");
fire("session_shutdown", {});
fire("session_start", {}, makeCtx());
dispatch("signal: pinned probe");
await settle(() => (globalThis.__fmSessions ?? []).length === 3, "pinned branch build");
const pinned = globalThis.__fmSessions[2].options.model;
if (!pinned || pinned.provider !== "openai" || pinned.id !== "cheap-1") {
  throw new Error(`pinned build did not use the pinned model: ${JSON.stringify(pinned)}`);
}

// 4. The reopen path (/new, /resume, /fork, reload all replace the session
// in-process) reopens the SAME persistent branch conversation and still
// applies the pin.
fire("session_shutdown", {});
fire("session_start", {}, makeCtx());
dispatch("signal: reopened probe");
await settle(() => (globalThis.__fmSessions ?? []).length === 4, "reopened branch build");
const reopened = globalThis.__fmSessions[3].options.model;
if (!reopened || reopened.provider !== "openai" || reopened.id !== "cheap-1") {
  throw new Error(`reopened build did not use the pinned model: ${JSON.stringify(reopened)}`);
}
const manager = globalThis.__fmSessions[3].options.sessionManager;
if (!manager.opened) throw new Error("reopen did not continue the persistent branch conversation");

// 5. Clearing the pin makes the REOPENED branch follow main again. This is
// the case Pi's own session restore would otherwise get wrong: the branch
// conversation still records the pinned model, so only an explicit override
// keeps "follow main" honest.
rmSync(`${home}/config/supervision-branch-model`);
fire("session_shutdown", {});
fire("session_start", {}, makeCtx());
dispatch("signal: unpinned again");
await settle(() => (globalThis.__fmSessions ?? []).length === 5, "post-clear branch build");
const cleared = globalThis.__fmSessions[4];
if (!cleared.options.sessionManager.opened) {
  throw new Error("the post-clear build must still reopen the persistent branch conversation");
}
if (cleared.options.model?.id === "cheap-1") {
  throw new Error("clearing the pin left the branch on the previously pinned model");
}
if (cleared.options.model?.provider !== "anthropic" || cleared.options.model?.id !== "main-model") {
  throw new Error(`clearing the pin did not return the branch to main's model: ${JSON.stringify(cleared.options.model)}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "the current pin state must decide the model on every branch build: $out"
  pass "the current pin state binds every branch create and reopen, and clearing it returns the branch to main's model"
}

test_unpinned_branch_follows_main_model_changes_live() {
  local repo home out status
  repo="$TMP_ROOT/model-live-root"
  home="$TMP_ROOT/model-live-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, makeCtx, registryModels, home }; })()`);
const { fire, dispatch, settle, makeCtx, registryModels, home } = globalThis.__t;
import { readFileSync, writeFileSync } from "node:fs";

registryModels.push(
  { provider: "anthropic", id: "main-model" },
  { provider: "anthropic", id: "replacement-model" },
  { provider: "openai", id: "cheap-1" },
);
fire("session_start", {}, makeCtx());
dispatch("signal: before main model change");
await settle(() => (globalThis.__fmSessions ?? []).length === 1, "initial unpinned branch build");
const original = globalThis.__fmSessions[0];
if (original.options.model?.id !== "main-model") throw new Error("the unpinned branch did not start on main's model");

fire("model_select", { model: { provider: "anthropic", id: "replacement-model" } });
await settle(() => original.disposed, "live unpinned branch release");
dispatch("signal: after main model change");
await settle(() => (globalThis.__fmSessions ?? []).length === 2, "replacement unpinned branch build");
const following = globalThis.__fmSessions[1];
if (following.options.model?.id !== "replacement-model") {
  throw new Error(`the unpinned branch did not follow main's model change: ${JSON.stringify(following.options.model)}`);
}

writeFileSync(`${home}/config/supervision-branch-model`, "openai/cheap-1\n");
fire("session_shutdown", {});
fire("session_start", {}, makeCtx());
dispatch("signal: establish pinned branch");
await settle(() => (globalThis.__fmSessions ?? []).length === 3, "pinned branch build");
const pinned = globalThis.__fmSessions[2];
if (pinned.options.model?.id !== "cheap-1") throw new Error("the pinned branch did not use its pin");
const promptsBefore = pinned.ops.filter((op) => op.kind === "prompt").length;

fire("model_select", { model: { provider: "anthropic", id: "replacement-model" } });
dispatch("signal: pinned after main model change");
await settle(() => pinned.ops.filter((op) => op.kind === "prompt").length === promptsBefore + 1, "pinned branch wake");
if (pinned.disposed || globalThis.__fmSessions.length !== 3) {
  throw new Error("a main model change replaced the pinned branch");
}
if (readFileSync(`${home}/config/supervision-branch-model`, "utf8") !== "openai/cheap-1\n") {
  throw new Error("a main model change disturbed the supervision pin");
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "unpinned branches must follow main model changes while pins remain authoritative: $out"
  pass "unpinned branches follow main model changes live while pinned branches stay fixed"
}

test_supervision_model_command_persists_and_rebinds_the_live_branch() {
  local repo home out status
  repo="$TMP_ROOT/modelcmd-root"
  home="$TMP_ROOT/modelcmd-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, makeCtx, commands, registryModels, uiSelections, uiPrompts, notices, home }; })()`);
const { fire, dispatch, settle, makeCtx, commands, registryModels, uiSelections, uiPrompts, notices, home } = globalThis.__t;
import { existsSync, readFileSync, statSync } from "node:fs";

registryModels.push(
  { provider: "anthropic", id: "main-model" },
  { provider: "openai-codex", id: "cheap-oauth", authKind: "oauth" },
  { provider: "dynamic", id: "extension-only", branchAvailable: false },
);
const command = commands.get("supervision-model");
if (!command) throw new Error("the supervision-model command was not registered");

fire("session_start", {}, makeCtx());
dispatch("signal: before the pick");
await settle(() => (globalThis.__fmSessions ?? []).length === 1, "pre-pick branch build");
const firstSession = globalThis.__fmSessions[0];
if (firstSession.options.model?.id !== "main-model") {
  throw new Error(`the branch started on something other than main's model before any pick: ${JSON.stringify(firstSession.options.model)}`);
}

// The picker offers Pi's branch-runnable catalog plus following main, and the
// captain's pick is persisted as the one-line config value.
uiSelections.push("openai-codex/cheap-oauth");
await command.handler("", makeCtx());
const offered = uiPrompts[0];
if (offered.options[0] !== "Follow main (anthropic/main-model)") {
  throw new Error(`the picker must offer following main first: ${JSON.stringify(offered.options)}`);
}
if (!offered.options.includes("openai-codex/cheap-oauth") || !offered.options.includes("anthropic/main-model")) {
  throw new Error(`the picker omitted a model available to the isolated branch: ${JSON.stringify(offered.options)}`);
}
if (offered.options.includes("dynamic/extension-only")) {
  throw new Error(`the picker offered a main-session-only provider: ${JSON.stringify(offered.options)}`);
}
const pinFile = `${home}/config/supervision-branch-model`;
if (readFileSync(pinFile, "utf8") !== "openai-codex/cheap-oauth\n") {
  throw new Error(`unexpected persisted pin: ${JSON.stringify(readFileSync(pinFile, "utf8"))}`);
}
if ((statSync(pinFile).mode & 0o777) !== 0o600) throw new Error("the pin must be written private to the operator");
if (!notices.some((notice) => notice.message.includes("openai-codex/cheap-oauth"))) {
  throw new Error(`the captain was not told which model the branch now uses: ${JSON.stringify(notices)}`);
}

// The live branch is released, so the pick binds on the next wake instead of
// waiting for a session replacement - and the same persistent conversation
// comes back under the new model.
await settle(() => firstSession.disposed, "live branch release after the pick");
dispatch("signal: after the pick");
await settle(() => (globalThis.__fmSessions ?? []).length === 2, "post-pick branch build");
const repinned = globalThis.__fmSessions[1];
if (!repinned.options.model || repinned.options.model.id !== "cheap-oauth") {
  throw new Error(`the pick did not bind the next branch build: ${JSON.stringify(repinned.options.model)}`);
}
if (repinned.options.model.authKind !== "oauth") {
  throw new Error(`the branch runtime changed the stored OAuth credential semantics: ${JSON.stringify(repinned.options.model)}`);
}
if (!repinned.options.sessionManager.opened) throw new Error("the pick must keep the branch conversation, not start a new one");

// Following main again clears the file and actually returns the branch to
// main's model, rather than letting the reopened session restore the pin.
const clearNoticeCount = notices.length;
uiSelections.push("Follow main (anthropic/main-model)");
await command.handler("", makeCtx());
if (existsSync(pinFile)) throw new Error("following main must remove the pin file");
const clearNotices = notices.slice(clearNoticeCount);
if (clearNotices.length !== 1 || clearNotices[0].type !== "info" || !clearNotices[0].message.includes("anthropic/main-model")) {
  throw new Error(`following main did not report the model actually applied: ${JSON.stringify(clearNotices)}`);
}
await settle(() => repinned.disposed, "live branch release after clearing");
dispatch("signal: after clearing");
await settle(() => (globalThis.__fmSessions ?? []).length === 3, "post-clear branch build");
const followed = globalThis.__fmSessions[2].options.model;
if (followed?.id === "cheap-oauth") throw new Error("following main left the branch on the cleared pin's model");
if (followed?.provider !== "anthropic" || followed?.id !== "main-model") {
  throw new Error(`following main did not apply main's own model: ${JSON.stringify(followed)}`);
}

// A pick made while the old-model branch build is in flight invalidates that
// build. The accepted wake continues on a second build under the newest pin.
uiSelections.push("Follow main (anthropic/main-model)");
await command.handler("", makeCtx());
let releaseCreate;
globalThis.__fmCreateGate = new Promise((resolve) => { releaseCreate = resolve; });
const createsBeforeRace = globalThis.__fmCreateStarted;
dispatch("signal: model race");
await settle(() => globalThis.__fmCreateStarted === createsBeforeRace + 1, "in-flight old-model build");
uiSelections.push("openai-codex/cheap-oauth");
await command.handler("", makeCtx());
releaseCreate();
await settle(() => (globalThis.__fmSessions ?? []).length === 5, "replacement build after in-flight pick");
const staleBuild = globalThis.__fmSessions[3];
const winningBuild = globalThis.__fmSessions[4];
if (!staleBuild.disposed || staleBuild.options.model?.id === "cheap-oauth") {
  throw new Error("the in-flight old-model build was adopted after the pick");
}
if (winningBuild.options.model?.id !== "cheap-oauth") {
  throw new Error(`the newest pin did not win the in-flight build race: ${JSON.stringify(winningBuild.options.model)}`);
}
await settle(() => (globalThis.__fmPrompts ?? []).some((prompt) => prompt.includes("signal: model race")), "raced wake prompt");

// A cancelled picker changes nothing.
uiSelections.push(undefined);
await command.handler("", makeCtx());
if (readFileSync(pinFile, "utf8") !== "openai-codex/cheap-oauth\n") throw new Error("a cancelled picker must not change the pin");

// If the isolated runtime cannot load, the old pin remains and no success
// notification is emitted.
const noticeCount = notices.length;
globalThis.__fmModelRuntimeError = "synthetic stored-credential load failure";
await command.handler("", makeCtx());
delete globalThis.__fmModelRuntimeError;
if (readFileSync(pinFile, "utf8") !== "openai-codex/cheap-oauth\n") throw new Error("an unapplied model replaced the working pin");
const newNotices = notices.slice(noticeCount);
if (newNotices.length !== 1 || newNotices[0].type !== "error") {
  throw new Error(`an unapplied model emitted a success notification: ${JSON.stringify(newNotices)}`);
}

// If the picker loads but resolving main after Follow main fails, the pin is
// cleared and the captain receives an honest warning rather than a rejection
// or a false success notice.
const clearFailureNoticeCount = notices.length;
globalThis.__fmModelRuntimeErrors = [null, "synthetic post-clear runtime failure"];
uiSelections.push("Follow main (anthropic/main-model)");
await command.handler("", makeCtx());
if (existsSync(pinFile)) throw new Error("following main did not clear the pin before its resolution warning");
const clearFailureNotices = notices.slice(clearFailureNoticeCount);
if (
  clearFailureNotices.length !== 1 ||
  clearFailureNotices[0].type !== "warning" ||
  !clearFailureNotices[0].message.includes("synthetic post-clear runtime failure")
) {
  throw new Error(`post-clear resolution failure was not reported honestly: ${JSON.stringify(clearFailureNotices)}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "the supervision-model command must persist the pick and rebind the live branch: $out"
  pass "supervision-model command persists the captain's pick and rebinds the live branch"
}

test_branch_effort_pin_applies_and_absent_pin_follows_main() {
  local repo home out status
  repo="$TMP_ROOT/effortpin-root"
  home="$TMP_ROOT/effortpin-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, makeCtx, registryModels, setMainThinkingLevel, home }; })()`);
const { fire, dispatch, settle, makeCtx, registryModels, setMainThinkingLevel, home } = globalThis.__t;
import { rmSync, writeFileSync } from "node:fs";

// main-model reasons up to Pi's "high"; deep-1 also maps xhigh and max.
registryModels.push(
  { provider: "anthropic", id: "main-model", reasoning: true },
  { provider: "openai", id: "deep-1", reasoning: true, thinkingLevelMap: { xhigh: "xhigh", max: "max" } },
);
const effortPin = `${home}/config/supervision-branch-effort`;
const modelPin = `${home}/config/supervision-branch-model`;
function rebuild(reason, expected) {
  fire("session_shutdown", {});
  fire("session_start", {}, makeCtx());
  dispatch(`signal: ${reason}`);
  return settle(() => (globalThis.__fmSessions ?? []).length === expected, `${reason} branch build`);
}

// 1. No effort pin: the branch applies MAIN's own current effort explicitly,
// so a reopened conversation cannot restore the level it last ran under.
fire("session_start", {}, makeCtx());
dispatch("signal: unpinned effort");
await settle(() => (globalThis.__fmSessions ?? []).length === 1, "unpinned-effort branch build");
if (globalThis.__fmSessions[0].options.thinkingLevel !== "medium") {
  throw new Error(`an absent effort pin must follow main's own effort: ${globalThis.__fmSessions[0].options.thinkingLevel}`);
}

// 2. An effort-only pin binds the next build and leaves the model following
// main, so the two pins are independently expressible.
writeFileSync(effortPin, "low\n");
await rebuild("effort-only pin", 2);
const effortOnly = globalThis.__fmSessions[1].options;
if (effortOnly.thinkingLevel !== "low") {
  throw new Error(`the effort pin did not bind the build: ${effortOnly.thinkingLevel}`);
}
if (effortOnly.model?.id !== "main-model") {
  throw new Error(`an effort-only pin must leave the model following main: ${JSON.stringify(effortOnly.model)}`);
}

// 3. The reopen path applies the effort pin too, over whatever the restored
// branch conversation recorded.
await rebuild("effort pin reopen", 3);
if (globalThis.__fmSessions[2].options.thinkingLevel !== "low") {
  throw new Error(`the reopened build dropped the effort pin: ${globalThis.__fmSessions[2].options.thinkingLevel}`);
}
if (!globalThis.__fmSessions[2].options.sessionManager.opened) {
  throw new Error("the effort-pinned reopen must continue the persistent branch conversation");
}

// 4. A model-only pin leaves the effort following main, the mirror image of
// case 2.
rmSync(effortPin);
writeFileSync(modelPin, "openai/deep-1\n");
setMainThinkingLevel("high");
await rebuild("model-only pin", 4);
const modelOnly = globalThis.__fmSessions[3].options;
if (modelOnly.model?.id !== "deep-1") throw new Error("the model-only pin did not bind the build");
if (modelOnly.thinkingLevel !== "high") {
  throw new Error(`a model-only pin must leave the effort following main: ${modelOnly.thinkingLevel}`);
}

// 5. Clearing the effort pin is the case Pi's own restore would get wrong:
// the branch conversation still records the pinned level, so main's current
// effort has to be applied explicitly rather than merely omitted.
writeFileSync(effortPin, "max\n");
await rebuild("effort repinned", 5);
if (globalThis.__fmSessions[4].options.thinkingLevel !== "max") {
  throw new Error(`deep-1 must accept Pi's max level: ${globalThis.__fmSessions[4].options.thinkingLevel}`);
}
rmSync(effortPin);
setMainThinkingLevel("minimal");
await rebuild("effort cleared", 6);
if (globalThis.__fmSessions[5].options.thinkingLevel === "max") {
  throw new Error("clearing the effort pin left the branch on the previously pinned level");
}
if (globalThis.__fmSessions[5].options.thinkingLevel !== "minimal") {
  throw new Error(`clearing the effort pin did not return the branch to main's effort: ${globalThis.__fmSessions[5].options.thinkingLevel}`);
}

// 6. Pi owns the clamp: a pinned level the branch's model cannot run becomes
// that model's nearest supported level instead of refusing the branch.
rmSync(modelPin);
writeFileSync(effortPin, "max\n");
await rebuild("clamped effort pin", 7);
const clamped = globalThis.__fmSessions[6].options;
if (clamped.model?.id !== "main-model") throw new Error("the clamp probe must run on main's own model");
if (clamped.thinkingLevel !== "high") {
  throw new Error(`an unsupported pinned level must clamp to the model's nearest level: ${clamped.thinkingLevel}`);
}

// 7. A token Pi does not recognize is no pin at all, exactly like an
// unparseable model pin, and never a silent downgrade to no reasoning.
writeFileSync(effortPin, "deep-thought\n");
setMainThinkingLevel("medium");
await rebuild("unrecognized effort pin", 8);
if (globalThis.__fmSessions[7].options.thinkingLevel !== "medium") {
  throw new Error(`an unrecognized effort token must behave as no pin: ${globalThis.__fmSessions[7].options.thinkingLevel}`);
}

// 8. When Pi cannot report main's own effort either, the build falls back to
// passing no effort override at all rather than losing the wake.
rmSync(effortPin);
globalThis.__fmThinkingLevelError = "synthetic unbound extension runtime";
await rebuild("unknown main effort", 9);
delete globalThis.__fmThinkingLevelError;
if ("thinkingLevel" in globalThis.__fmSessions[8].options) {
  throw new Error("an unknowable main effort must fall back to passing no effort override");
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "the current effort pin state must decide the branch effort on every build: $out"
  pass "the effort pin binds every branch create and reopen, and clearing it returns the branch to main's effort"
}

test_unpinned_branch_follows_main_effort_changes_live() {
  local repo home out status
  repo="$TMP_ROOT/effort-live-root"
  home="$TMP_ROOT/effort-live-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, makeCtx, registryModels, setMainThinkingLevel, home }; })()`);
const { fire, dispatch, settle, makeCtx, registryModels, setMainThinkingLevel, home } = globalThis.__t;
import { readFileSync, writeFileSync } from "node:fs";

registryModels.push({ provider: "anthropic", id: "main-model", reasoning: true });
const effortPin = `${home}/config/supervision-branch-effort`;

fire("session_start", {}, makeCtx());
dispatch("signal: before main effort change");
await settle(() => (globalThis.__fmSessions ?? []).length === 1, "initial branch build");
const original = globalThis.__fmSessions[0];
if (original.options.thinkingLevel !== "medium") throw new Error("the unpinned branch did not start on main's effort");

// A mid-session effort change releases the live branch, so the next wake
// reopens the same conversation at main's new effort without waiting for a
// session replacement.
setMainThinkingLevel("high");
fire("thinking_level_select", { level: "high", previousLevel: "medium" });
await settle(() => original.disposed, "live branch release after main's effort change");
dispatch("signal: after main effort change");
await settle(() => (globalThis.__fmSessions ?? []).length === 2, "post-change branch build");
const following = globalThis.__fmSessions[1];
if (following.options.thinkingLevel !== "high") {
  throw new Error(`the unpinned branch did not follow main's effort change: ${following.options.thinkingLevel}`);
}
if (!following.options.sessionManager.opened) {
  throw new Error("following main's effort must keep the persistent branch conversation");
}

// A pinned branch is authoritative: main's effort changes leave both the live
// branch and the stored pin alone.
writeFileSync(effortPin, "minimal\n");
fire("session_shutdown", {});
fire("session_start", {}, makeCtx());
dispatch("signal: pinned effort");
await settle(() => (globalThis.__fmSessions ?? []).length === 3, "pinned effort branch build");
const pinned = globalThis.__fmSessions[2];
if (pinned.options.thinkingLevel !== "minimal") throw new Error("the pinned branch did not use its effort pin");

setMainThinkingLevel("high");
fire("thinking_level_select", { level: "high", previousLevel: "minimal" });
dispatch("signal: pinned after main effort change");
await new Promise((resolve) => setTimeout(resolve, 50));
if (pinned.disposed) throw new Error("a main effort change replaced the effort-pinned branch");
if (readFileSync(effortPin, "utf8") !== "minimal\n") {
  throw new Error("a main effort change disturbed the supervision effort pin");
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "unpinned branches must follow main effort changes while pins remain authoritative: $out"
  pass "unpinned branches follow main effort changes live while pinned branches stay fixed"
}

test_supervision_model_picker_is_bounded_searchable_and_branch_only() {
  local repo home out status
  repo="$TMP_ROOT/pickerux-root"
  home="$TMP_ROOT/pickerux-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, makeCtx, makeTuiCtx, commands, registryModels, uiSelections, uiKeystrokes, mainModelWrites, home }; })()`);
const { fire, makeCtx, makeTuiCtx, commands, registryModels, uiSelections, uiKeystrokes, mainModelWrites, home } = globalThis.__t;
import { readFileSync } from "node:fs";

// A catalog long enough that rendering it whole would run off a terminal,
// plus one distinctively named model to search for and one model the
// isolated branch runtime cannot run.
registryModels.push({ provider: "anthropic", id: "main-model" });
for (let i = 1; i <= 30; i += 1) registryModels.push({ provider: "anthropic", id: `bulk-model-${i}` });
registryModels.push({ provider: "openai-codex", id: "cheap-oauth", authKind: "oauth" });
registryModels.push({ provider: "dynamic", id: "extension-only", branchAvailable: false });

const command = commands.get("supervision-model");
if (!command) throw new Error("the supervision-model command was not registered");
fire("session_start", {}, makeCtx());

// The captain types a search query and confirms the one row it leaves.
globalThis.__fmPickerLists = [];
uiKeystrokes.push(["c", "h", "e", "a", "p", "tui.select.confirm"]);
uiSelections.push(undefined); // the effort step is cancelled, leaving that choice alone
await command.handler("", makeTuiCtx());

const lists = globalThis.__fmPickerLists;
if (lists.length < 2) throw new Error(`typing a query must rebuild the list: ${JSON.stringify(lists.map((l) => l.items.length))}`);
const opened = lists[0];
if (opened.maxVisible !== 10) {
  throw new Error(`the model list must stay bounded rather than rendering every row: maxVisible=${opened.maxVisible}`);
}
if (opened.items[0].label !== "Follow main (anthropic/main-model)") {
  throw new Error(`following main must be the first row: ${JSON.stringify(opened.items.slice(0, 2))}`);
}
if (opened.items.length !== 33) {
  throw new Error(`the opened list must offer following main plus every branch-runnable model: ${opened.items.length}`);
}
if (opened.items.some((item) => item.label.includes("extension-only"))) {
  throw new Error("the picker widened past the branch runtime's eligibility filter");
}
const filtered = lists[lists.length - 1];
if (filtered.items.length !== 1 || filtered.items[0].value !== "openai-codex/cheap-oauth") {
  throw new Error(`the search query did not narrow the list: ${JSON.stringify(filtered.items)}`);
}

// The pick lands on the supervision branch alone.
if (readFileSync(`${home}/config/supervision-branch-model`, "utf8") !== "openai-codex/cheap-oauth\n") {
  throw new Error("the searched-for pick was not persisted as the supervision branch model");
}
if (mainModelWrites.length !== 0) {
  throw new Error(`pinning the branch moved the captain's own model: ${JSON.stringify(mainModelWrites)}`);
}
if (makeCtx().model.id !== "main-model") throw new Error("the captain's own conversation model changed");

// A query that matches following main keeps that row first, and escape
// leaves every choice standing.
globalThis.__fmPickerLists = [];
uiKeystrokes.push(["m", "a", "i", "n", "tui.select.cancel"]);
await command.handler("", makeTuiCtx());
const mainQuery = globalThis.__fmPickerLists[globalThis.__fmPickerLists.length - 1];
if (mainQuery.items[0].label !== "Follow main (anthropic/main-model)") {
  throw new Error(`a matching query must keep following main first: ${JSON.stringify(mainQuery.items.slice(0, 2))}`);
}
if (mainQuery.items.length < 2) throw new Error("a matching query dropped the models it also matched");
if (readFileSync(`${home}/config/supervision-branch-model`, "utf8") !== "openai-codex/cheap-oauth\n") {
  throw new Error("cancelling the picker changed the standing pin");
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "the model picker must be bounded, searchable, and branch-only: $out"
  pass "supervision-model opens a bounded searchable list, follow main first, and pins the branch alone"
}

test_branch_model_picker_keeps_follow_main_first_under_ranking() {
  local repo out status
  repo="$TMP_ROOT/pickerlib-root"
  mkdir -p "$repo/.pi/extensions/lib"
  cp "$ROOT/.pi/extensions/lib/fm-branch-model-picker.ts" "$repo/.pi/extensions/lib/fm-branch-model-picker.ts"
  LIB="$repo/.pi/extensions/lib/fm-branch-model-picker.ts" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const { buildBranchModelItems, filterBranchPickerItems, BRANCH_PICKER_MAX_VISIBLE, FOLLOW_MAIN_VALUE } = await import(
  pathToFileURL(process.env.LIB).href
);

const items = buildBranchModelItems("Follow main (anthropic/main-model)", ["anthropic/main-model", "openai/mainly-cheap"], null);
if (items[0].value !== FOLLOW_MAIN_VALUE) throw new Error("following main must be built as the first row");
if (items[0].description !== "current") throw new Error("an absent pin must mark following main as the current choice");
if (items[2].description !== undefined) throw new Error("a model that is not pinned must not be marked current");

const pinned = buildBranchModelItems("Follow main (anthropic/main-model)", ["anthropic/main-model"], "anthropic/main-model");
if (pinned[0].description !== undefined) throw new Error("a pinned branch must not mark following main as current");
if (pinned[1].description !== "current") throw new Error("the pinned model must be marked as the current choice");

// A ranking filter is free to sort a better match ahead of following main;
// the picker must still show following main first whenever it matches.
const rankReversing = (list, query, getText) =>
  list.filter((item) => getText(item).toLowerCase().includes(query.toLowerCase())).reverse();
const matched = filterBranchPickerItems(items, "main", rankReversing);
if (matched[0].value !== FOLLOW_MAIN_VALUE) {
  throw new Error(`ranking moved following main out of first place: ${JSON.stringify(matched)}`);
}
if (matched.length !== 3) throw new Error(`a matching query dropped rows it should keep: ${JSON.stringify(matched)}`);

const narrowed = filterBranchPickerItems(items, "openai", rankReversing);
if (narrowed.length !== 1 || narrowed[0].value !== "openai/mainly-cheap") {
  throw new Error(`a query that excludes following main must drop it: ${JSON.stringify(narrowed)}`);
}
const unfiltered = filterBranchPickerItems(items, "   ", rankReversing);
if (unfiltered.length !== items.length || unfiltered[0].value !== FOLLOW_MAIN_VALUE) {
  throw new Error("an empty query must keep the built order");
}
if (BRANCH_PICKER_MAX_VISIBLE !== 10) throw new Error("the picker must keep a bounded visible row count");
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "the picker's ordering and filtering must hold: $out"
  pass "branch model picker keeps follow main first and filters the eligible catalog"
}

test_supervision_model_command_picks_effort_after_the_model() {
  local repo home out status
  repo="$TMP_ROOT/effortcmd-root"
  home="$TMP_ROOT/effortcmd-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, makeCtx, commands, registryModels, uiSelections, uiPrompts, notices, setMainThinkingLevel, home }; })()`);
const { fire, dispatch, settle, makeCtx, commands, registryModels, uiSelections, uiPrompts, notices, setMainThinkingLevel, home } = globalThis.__t;
import { existsSync, readFileSync, statSync } from "node:fs";

// main-model reasons up to Pi's "high"; deep-1 also maps xhigh and max, so
// the two models genuinely offer different menus.
registryModels.push(
  { provider: "anthropic", id: "main-model", reasoning: true },
  { provider: "openai", id: "deep-1", reasoning: true, thinkingLevelMap: { xhigh: "xhigh", max: "max" } },
  { provider: "openai", id: "shallow-1", reasoning: true },
);
const command = commands.get("supervision-model");
const effortPin = `${home}/config/supervision-branch-effort`;
const modelPin = `${home}/config/supervision-branch-model`;
fire("session_start", {}, makeCtx());

// One command, two steps in order: the model picker, then an effort picker
// built from Pi's own supported levels for the model just chosen.
uiSelections.push("openai/deep-1", "xhigh");
await command.handler("", makeCtx());
if (uiPrompts.length !== 2) throw new Error(`the command must show the model picker then the effort picker: ${uiPrompts.length}`);
if (!uiPrompts[0].title.startsWith("Supervision branch model")) {
  throw new Error(`the first step must be the model picker: ${uiPrompts[0].title}`);
}
const effortStep = uiPrompts[1];
if (!effortStep.title.startsWith("Supervision branch effort")) {
  throw new Error(`the second step must be the effort picker: ${effortStep.title}`);
}
if (effortStep.options[0] !== "Follow main (medium)") {
  throw new Error(`the effort picker must offer following main first: ${JSON.stringify(effortStep.options)}`);
}
if (JSON.stringify(effortStep.options.slice(1)) !== JSON.stringify(["off", "minimal", "low", "medium", "high", "xhigh", "max"])) {
  throw new Error(`the effort picker must offer Pi's own levels for the chosen model: ${JSON.stringify(effortStep.options)}`);
}
if (readFileSync(effortPin, "utf8") !== "xhigh\n") {
  throw new Error(`unexpected persisted effort pin: ${JSON.stringify(readFileSync(effortPin, "utf8"))}`);
}
if ((statSync(effortPin).mode & 0o777) !== 0o600) throw new Error("the effort pin must be written private to the operator");
if (readFileSync(modelPin, "utf8") !== "openai/deep-1\n") throw new Error("the model pick was not persisted alongside the effort pick");
const bothNotice = notices[notices.length - 1];
if (!bothNotice.message.includes("openai/deep-1") || !bothNotice.message.includes("xhigh")) {
  throw new Error(`the captain was not told both applied choices: ${JSON.stringify(bothNotice)}`);
}

// Both choices bind the next branch build together.
dispatch("signal: after both picks");
await settle(() => (globalThis.__fmSessions ?? []).length === 1, "branch build after both picks");
const both = globalThis.__fmSessions[0].options;
if (both.model?.id !== "deep-1" || both.thinkingLevel !== "xhigh") {
  throw new Error(`the picks did not bind the branch build: ${JSON.stringify({ model: both.model?.id, effort: both.thinkingLevel })}`);
}

// The effort picker's menu follows the model chosen in the SAME invocation,
// not the model the branch was running a moment ago: main-model stops at
// Pi's "high", so xhigh and max disappear.
uiSelections.push("Follow main (anthropic/main-model)", "high");
await command.handler("", makeCtx());
const narrowed = uiPrompts[uiPrompts.length - 1];
if (narrowed.options.includes("xhigh") || narrowed.options.includes("max")) {
  throw new Error(`the effort menu did not follow the model just chosen: ${JSON.stringify(narrowed.options)}`);
}
if (!narrowed.title.includes("now: xhigh")) {
  throw new Error(`the effort picker must show the standing pin: ${narrowed.title}`);
}
if (readFileSync(effortPin, "utf8") !== "high\n") throw new Error("the second effort pick was not persisted");
if (existsSync(modelPin)) throw new Error("following main did not clear the model pin");

// Cancelling the effort step leaves the standing effort choice alone while
// the model pick made in the same invocation still applies, and the captain
// is told what the branch will actually run at.
const cancelNoticeCount = notices.length;
uiSelections.push("openai/deep-1");
await command.handler("", makeCtx());
if (readFileSync(effortPin, "utf8") !== "high\n") throw new Error("a cancelled effort step changed the standing effort pin");
if (readFileSync(modelPin, "utf8") !== "openai/deep-1\n") throw new Error("a cancelled effort step discarded the model pick");
const cancelNotices = notices.slice(cancelNoticeCount);
if (cancelNotices.length !== 1 || cancelNotices[0].type !== "info" || !cancelNotices[0].message.includes("high")) {
  throw new Error(`a cancelled effort step must still report the standing effort: ${JSON.stringify(cancelNotices)}`);
}

// Following main for effort clears the pin and reports main's own level.
const followNoticeCount = notices.length;
uiSelections.push("openai/deep-1", "Follow main (medium)");
await command.handler("", makeCtx());
if (existsSync(effortPin)) throw new Error("following main must remove the effort pin file");
const followNotices = notices.slice(followNoticeCount);
if (followNotices.length !== 1 || !followNotices[0].message.includes("Effort follows main (medium)")) {
  throw new Error(`following main for effort was not reported honestly: ${JSON.stringify(followNotices)}`);
}

// Honest reporting when Pi's own clamp will lower a standing pin: "max" is
// offered on deep-1, but moving the branch back to main-model, which tops out
// at Pi's "high", must be reported as the level the branch will really run at
// rather than as the raw pin - and the captain's raw pick is kept, so
// returning to deep-1 restores it.
uiSelections.push("openai/deep-1", "max");
await command.handler("", makeCtx());
if (readFileSync(effortPin, "utf8") !== "max\n") throw new Error("the max effort pick was not persisted");
const clampNoticeCount = notices.length;
uiSelections.push("Follow main (anthropic/main-model)");
await command.handler("", makeCtx());
const clampNotices = notices.slice(clampNoticeCount);
if (clampNotices.length !== 1 || !clampNotices[0].message.includes("Effort: max, which this model runs at high.")) {
  throw new Error(`a clamped standing effort pin was not reported honestly: ${JSON.stringify(clampNotices)}`);
}
if (readFileSync(effortPin, "utf8") !== "max\n") throw new Error("reporting a clamp rewrote the captain's raw effort pick");
dispatch("signal: clamped build");
await settle(() => (globalThis.__fmSessions ?? []).length === 2, "clamped branch build");
if (globalThis.__fmSessions[1].options.thinkingLevel !== "high") {
  throw new Error(`the clamped build did not run at the reported level: ${globalThis.__fmSessions[1].options.thinkingLevel}`);
}

// When main's model cannot be resolved, the effort step derives Pi's level
// set from the model recorded by the persistent branch conversation.
uiSelections.push("openai/shallow-1", "max");
await command.handler("", makeCtx());
dispatch("signal: record shallow branch model");
await settle(() => (globalThis.__fmSessions ?? []).length === 3, "shallow branch build");
registryModels.find((model) => model.id === "main-model").branchAvailable = false;
const restoredNoticeCount = notices.length;
uiSelections.push("Follow main (anthropic/main-model)");
await command.handler("", makeCtx());
const restoredPicker = uiPrompts[uiPrompts.length - 1];
if (JSON.stringify(restoredPicker.options.slice(1)) !== JSON.stringify(["off", "minimal", "low", "medium", "high"])) {
  throw new Error(`the unresolved-main picker did not use Pi's levels for the recorded branch model: ${JSON.stringify(restoredPicker.options)}`);
}
const restoredNotices = notices.slice(restoredNoticeCount);
if (restoredNotices.length !== 1 || !restoredNotices[0].message.includes("Effort: max, which this model runs at high.")) {
  throw new Error(`the recorded branch model did not make clamp reporting honest: ${JSON.stringify(restoredNotices)}`);
}

// If neither main nor the recorded branch model can be resolved, no invented
// catalog is offered and the report says the applied level is unknown.
registryModels.find((model) => model.id === "shallow-1").branchAvailable = false;
const unknownNoticeCount = notices.length;
uiSelections.push("Follow main (anthropic/main-model)");
await command.handler("", makeCtx());
const unknownPicker = uiPrompts[uiPrompts.length - 1];
if (JSON.stringify(unknownPicker.options) !== JSON.stringify(["Follow main (medium)"])) {
  throw new Error(`the unknown-model picker invented effort levels: ${JSON.stringify(unknownPicker.options)}`);
}
const unknownNotices = notices.slice(unknownNoticeCount);
if (unknownNotices.length !== 1 || !unknownNotices[0].message.includes("cannot be determined")) {
  throw new Error(`the unknown effective effort was reported as applied: ${JSON.stringify(unknownNotices)}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "the effort step must follow the model step and persist independently: $out"
  pass "supervision-model runs an effort picker after the model picker and persists both independently"
}

test_unusable_model_pin_falls_back_to_main() {
  local repo home out status
  repo="$TMP_ROOT/modelbad-root"
  home="$TMP_ROOT/modelbad-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, makeCtx, registryModels, mainUserMessages, home }; })()`);
const { fire, dispatch, settle, makeCtx, registryModels, mainUserMessages, home } = globalThis.__t;
import { writeFileSync } from "node:fs";

registryModels.push(
  { provider: "anthropic", id: "main-model" },
  { provider: "dynamic", id: "extension-only", branchAvailable: false },
);

// A pin the isolated branch runtime cannot hand back is never a silent
// downgrade onto main's model, even when main's session knows that model.
writeFileSync(`${home}/config/supervision-branch-model`, "dynamic/extension-only\n");
fire("session_start", {}, makeCtx());
dispatch("signal: unusable pin probe");
await settle(() => mainUserMessages.length === 1, "fallback to main");
const delivered = mainUserMessages[0].content;
if (!delivered.includes("dynamic/extension-only") || !delivered.includes("supervision model pin")) {
  throw new Error(`the fallback did not name the unusable pin: ${delivered}`);
}
if ((globalThis.__fmSessions ?? []).length !== 0) throw new Error("an unusable pin must not build a branch session");

// An unparseable file is simply no pin, so supervision keeps working and the
// branch follows main's own model.
writeFileSync(`${home}/config/supervision-branch-model`, "not-a-model-reference\n");
fire("session_shutdown", {});
fire("session_start", {}, makeCtx());
dispatch("signal: unparseable pin probe");
await settle(() => (globalThis.__fmSessions ?? []).length === 1, "unparseable-pin branch build");
const unparseable = globalThis.__fmSessions[0].options.model;
if (unparseable?.provider !== "anthropic" || unparseable?.id !== "main-model") {
  throw new Error(`an unparseable pin must be treated as no pin and follow main: ${JSON.stringify(unparseable)}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "an unusable model pin must fall back to main and an unparseable one must be no pin: $out"
  pass "an unusable model pin falls back to main and an unparseable one is treated as no pin"
}

test_replacement_activation_cleans_leases_and_retries_failure() {
  local repo home fakebin out status real_bash
  repo="$TMP_ROOT/activation-root"
  home="$TMP_ROOT/activation-home"
  fakebin="$home/fakebin"
  real_bash=$(command -v bash)
  mkdir -p "$home/state" "$home/config" "$fakebin"
  install_pi_branch_extension_fixture "$repo"
  cat > "$fakebin/bash" <<'SH'
#!/bin/sh
if [ "$1" = "$FM_TEST_LEASE_SCRIPT" ] && [ ! -e "$FM_TEST_FAIL_MARKER" ]; then
  : > "$FM_TEST_FAIL_MARKER"
  exit 7
fi
exec "$FM_TEST_REAL_BASH" "$@"
SH
  chmod +x "$fakebin/bash"
  PATH="$fakebin:$PATH" PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TEST_REAL_BASH="$real_bash" FM_TEST_LEASE_SCRIPT="$ROOT/bin/fm-lease.sh" \
    FM_TEST_FAIL_MARKER="$home/state/release-failed-once" DRIVER_PRELUDE="$DRIVER_PRELUDE" \
    node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, home, realRoot }; })()`);
const { fire, dispatch, settle, home } = globalThis.__t;
import { existsSync, writeFileSync } from "node:fs";

writeFileSync(`${home}/state/.lease-task-old`, `branch\t${process.pid}\t123\n`);

fire("session_start", {});
if (!existsSync(`${home}/state/.lease-task-old`)) throw new Error("failed activation incorrectly committed lease cleanup");
const offer = dispatch("signal: retry activation");
if (!offer.accepted) throw new Error("later boundary did not retry failed activation");
if (existsSync(`${home}/state/.lease-task-old`)) throw new Error("replacement activation did not clean the prior branch lease");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "post-retry wake prompt");
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "replacement activation must clean leases and retry failures: $out"
  pass "replacement activation cleans old branch leases and retries failed cleanup"
}

test_cold_start_activates_after_lock_acquisition() {
  local repo home out status
  repo="$TMP_ROOT/coldstart-root"
  home="$TMP_ROOT/coldstart-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TEST_SKIP_LOCK=1 DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { dispatch, settle, home }; })()`);
const { dispatch, settle, home } = globalThis.__t;
import { existsSync, writeFileSync } from "node:fs";

// An ordinary cold Pi start: session_start fires BEFORE the session acquires
// the fleet lock (fm-sessionstart-run.sh acquires it later). Ownership must
// be evaluated lazily per action, never latched at session_start.
if (dispatch("signal: before lock").accepted) throw new Error("branch accepted a wake before the lock existed");
if (existsSync(`${home}/state/.pi-branch-extension-loaded`)) {
  throw new Error("branch wrote its marker before owning the lock");
}
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
if (!dispatch("signal: after lock").accepted) throw new Error("branch refused a wake after the lock was acquired");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "post-lock branch wake prompt");
if (!existsSync(`${home}/state/.pi-branch-extension-loaded`)) {
  throw new Error("owned activation did not write the diagnostic marker");
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "cold-start lazy lock-ownership activation must hold: $out"
  pass "branch activates on a cold start once the lock is acquired, never before"
}

test_queued_actions_recheck_lock_ownership() {
  local repo home out status
  repo="$TMP_ROOT/queued-ownership-root"
  home="$TMP_ROOT/queued-ownership-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, home, mainUserMessages }; })()`);
const { fire, dispatch, settle, home, mainUserMessages } = globalThis.__t;
import { existsSync, unlinkSync } from "node:fs";

let releasePrompt;
globalThis.__fmPromptGate = new Promise((resolve) => { releasePrompt = resolve; });
if (!dispatch("signal: active wake").accepted) throw new Error("first wake was not accepted");
await settle(() => globalThis.__fmPromptStarted === true, "blocked first prompt");
if (!dispatch("signal: queued wake").accepted) throw new Error("queued wake was not accepted");
const entries = [{ type: "message", message: { role: "user", content: "queued mirror must stay undelivered" } }];
fire("turn_end", {}, {
  sessionManager: { getSessionFile: () => `${home}/main.jsonl`, getEntries: () => entries },
});
unlinkSync(`${home}/state/.lock`);
releasePrompt();
await settle(() => mainUserMessages.length === 1, "lost-ownership fallback");
if (!mainUserMessages[0].content.includes("FIRSTMATE WATCHER WAKE: signal: queued wake")) {
  throw new Error(`queued wake did not fall back to main: ${mainUserMessages[0].content}`);
}
await new Promise((resolve) => setTimeout(resolve, 25));
const session = globalThis.__fmSessions[0];
if (session.ops.some((op) => op.kind === "custom")) throw new Error("queued mirror appended after lock ownership was lost");
if (existsSync(`${home}/state/.branch-mirror-cursor`)) throw new Error("queued mirror advanced its cursor after lock ownership was lost");
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "queued branch actions must recheck lock ownership: $out"
  pass "queued wakes and mirrors stop mutating branch state after lock ownership is lost"
}

test_stale_generation_boundaries_are_side_effect_free() {
  local repo home out status
  repo="$TMP_ROOT/stale-boundaries-root"
  home="$TMP_ROOT/stale-boundaries-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, home, sentToMain }; })()`);
const { fire, dispatch, settle, home, sentToMain } = globalThis.__t;
import { existsSync, readFileSync } from "node:fs";

if (!dispatch("signal: establish old branch").accepted) throw new Error("old branch wake was not accepted");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "old branch prompt");
const oldSession = globalThis.__fmSessions[0];
const oldReport = oldSession.options.customTools.find((tool) => tool.name === "fm_branch_report");
const oldBash = oldSession.options.customTools.find((tool) => tool.name === "bash");

let releaseMirror;
globalThis.__fmMirrorGate = new Promise((resolve) => { releaseMirror = resolve; });
const oldEntries = [{ type: "message", message: { role: "user", content: "old generation mirror" } }];
fire("turn_end", {}, {
  sessionManager: { getSessionFile: () => `${home}/old-main.jsonl`, getEntries: () => oldEntries },
});
await settle(() => globalThis.__fmMirrorStarted === true, "blocked old mirror delivery");
fire("session_shutdown", {});
fire("session_start", {});
const newEntries = [{ type: "message", message: { role: "user", content: "new generation mirror" } }];
fire("turn_end", {}, {
  sessionManager: { getSessionFile: () => `${home}/new-main.jsonl`, getEntries: () => newEntries },
});

const reportResult = await oldReport.execute(
  "stale-report",
  { task: "task-stale", verdict: "captain", summary: "must not append or merge" },
  undefined,
  undefined,
  {},
);
if (!reportResult.isError) throw new Error("stale report tool was not refused");
let bashRefused = false;
try {
  oldBash.__options.spawnHook({
    command: "bin/fm-lease.sh claim task-stale --actor branch",
    cwd: home,
    env: {},
  });
} catch {
  bashRefused = true;
}
if (!bashRefused) throw new Error("stale bash tool was not refused");
if (existsSync(`${home}/state/branch-outcomes.jsonl`)) throw new Error("stale report appended an outcome");
if (existsSync(`${home}/state/.lease-task-stale`)) throw new Error("stale bash claimed a lease");
if (sentToMain.length !== 0) throw new Error("stale report merged a note into main");

releaseMirror();
await new Promise((resolve) => setTimeout(resolve, 25));
if (!dispatch("signal: establish replacement branch").accepted) throw new Error("replacement wake was not accepted");
await settle(() => (globalThis.__fmPrompts ?? []).length === 2, "replacement branch prompt");
await settle(
  () => (globalThis.__fmMirrors ?? []).some((message) => message.content === "[captain] new generation mirror"),
  "replacement mirror delivery",
);
const cursor = JSON.parse(readFileSync(`${home}/state/.branch-mirror-cursor`, "utf8"));
if (cursor.file !== `${home}/new-main.jsonl` || cursor.index !== 1) {
  throw new Error(`stale mirror continuation changed the replacement cursor: ${JSON.stringify(cursor)}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "stale branch boundaries must perform no side effects: $out"
  pass "stale reports, shells, mirrors, cursors, leases, and prompts perform no side effects"
}

test_secondary_session_stays_inert() {
  local repo home out status foreign_pid
  repo="$TMP_ROOT/secondary-root"
  home="$TMP_ROOT/secondary-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  # The fleet lock is owned by ANOTHER live process that is NOT in the
  # driver's ancestry (a sibling sleeper), so the driver is a secondary
  # session: it must accept nothing, write no marker, and release no leases.
  sleep 60 &
  foreign_pid=$!
  printf 'branch\t%s\t123\n' "$foreign_pid" > "$home/state/.lease-task-x"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TEST_SKIP_LOCK=1 FM_TEST_LOCK_PID=$foreign_pid DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { dispatch, home }; })()`);
const { dispatch, home } = globalThis.__t;
import { existsSync, writeFileSync } from "node:fs";
writeFileSync(`${home}/state/.lock`, `${process.env.FM_TEST_LOCK_PID}\n`);
if (dispatch("signal: secondary probe").accepted) throw new Error("secondary session accepted a wake it does not own");
if (existsSync(`${home}/state/.pi-branch-extension-loaded`)) {
  throw new Error("secondary session wrote the primary's marker");
}
if (!existsSync(`${home}/state/.lease-task-x`)) {
  throw new Error("secondary session released the primary's branch lease");
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  kill "$foreign_pid" 2>/dev/null || true
  expect_code 0 "$status" "a secondary session must stay inert: $out"
  pass "a Pi session that does not own the lock accepts nothing and mutates no branch state"
}

test_rebind_remirrors_undelivered_dialog_from_durable_cursor() {
  local repo home out status
  repo="$TMP_ROOT/rebind-root"
  home="$TMP_ROOT/rebind-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, home }; })()`);
const { fire, home } = globalThis.__t;
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

// Instance A collects dialog at turn_end while no branch exists yet (nothing
// delivered, durable cursor unmoved), then the extension instance is replaced
// (/new, /resume, reload). The replacement must reconstruct exclusively from
// the durable cursor and re-mirror the undelivered dialog - never drop it.
const entries = [
  { type: "message", message: { role: "user", content: "standing order: never merge task-7" } },
];
const ctx = {
  sessionManager: { getSessionFile: () => `${home}/main-1.jsonl`, getEntries: () => entries },
};
fire("turn_end", {}, ctx);
fire("session_shutdown", {});

// Replacement instance: fresh import simulates Pi rebinding the extension.
const replacementHandlers = new Map();
const replacementBus = {
  on(channel, handler) {
    replacementHandlers.set(channel, [...(replacementHandlers.get(channel) ?? []), handler]);
    return () => {};
  },
  emit(channel, data) {
    for (const handler of replacementHandlers.get(channel) ?? []) handler(data);
  },
};
const replacementPiHandlers = new Map();
const replacementPi = {
  events: replacementBus,
  on(event, handler) {
    replacementPiHandlers.set(event, [...(replacementPiHandlers.get(event) ?? []), handler]);
  },
  registerTool() {},
  registerCommand() {},
  registerMessageRenderer() {},
  sendMessage() {},
  sendUserMessage() {},
};
const replacement = await import(`${pathToFileURL(process.env.PLUGIN).href}?rebind=1`);
replacement.default(replacementPi);
for (const handler of replacementPiHandlers.get("session_start") ?? []) handler({}, ctx);
for (const handler of replacementPiHandlers.get("turn_end") ?? []) handler({}, ctx);
writeFileSync(`${home}/state/.wake-queue`, "1\t1\tsignal\tbranch-driver.status\tsignal: after rebind\n");
const offer = {
  message: "signal: after rebind",
  projects: [`${home}/projects/approved`],
  heartbeat: false,
  eligible: true,
  accepted: false,
  accept() {
    offer.accepted = true;
  },
};
replacementBus.emit("fm-branch-supervision:dispatch", offer);
if (!offer.accepted) throw new Error("replacement instance refused the wake");
for (let i = 0; i < 250; i += 1) {
  const mirrors = (globalThis.__fmMirrors ?? []).map((m) => m.content);
  if (mirrors.includes("[captain] standing order: never merge task-7")) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const mirrors = (globalThis.__fmMirrors ?? []).map((m) => m.content);
if (!mirrors.includes("[captain] standing order: never merge task-7")) {
  throw new Error(`replacement dropped undelivered dialog: ${JSON.stringify(mirrors)}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "rebind must re-mirror undelivered dialog from the durable cursor: $out"
  pass "an extension rebind re-mirrors undelivered dialog instead of dropping it"
}

# Direct unit coverage of fm-branch-dispatch.ts's classification, independent
# of the Pi SDK stub: every legitimately main-only class (docs/pi-supervision-
# branch.md) stays excluded from eligibleSeqs no matter its check-kind key,
# a mixed queue keeps its task-local rows eligible without those main-only
# rows vetoing the scan, and the eligible-row snapshot writer names exactly
# the eligible set.
test_branch_dispatch_classifies_main_only_rows_and_writes_the_eligible_snapshot() {
  local repo home out status
  repo="$TMP_ROOT/dispatch-classify-root"
  home="$TMP_ROOT/dispatch-classify-home"
  mkdir -p "$repo/.pi/extensions/lib" "$home/state" "$home/projects/approved"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-model-picker.ts" "$repo/.pi/extensions/lib/fm-branch-model-picker.ts"
  printf 'project=%s/projects/approved\nwindow=fm-window\n' "$home" > "$home/state/task-a.meta"
  LIB="$repo/.pi/extensions/lib/fm-branch-dispatch.ts" FM_HOME="$home" GRANT="$ROOT/bin/fm-wake-grant.sh" \
    node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { readFileSync, writeFileSync } from "node:fs";

const { activateEligibleRowsOwner, scopeForUnreadWake, writeEligibleRowsSnapshot, releaseEligibleRowsSnapshot, BRANCH_ELIGIBLE_ROWS_FILE } =
  await import(pathToFileURL(process.env.LIB).href);
const state = `${process.env.FM_HOME}/state`;
const project = `${process.env.FM_HOME}/projects/approved`;

// Every legitimately main-only class is a check-kind row under a different
// key; classification never looks at the key, only the kind, so one
// representative per named class is sufficient coverage.
const mainOnlyRows = [
  "1\t1\tcheck\tx-inbox\tcheck: pending x mention",
  "1\t1\tcheck\tsome-poll.check.sh\tcheck: some-poll.check.sh: merged",
  "1\t1\tcheck\tunauthenticated-state-checks\tcheck: rejected unauthenticated state checks",
];
for (const row of mainOnlyRows) {
  writeFileSync(`${state}/.wake-queue`, row);
  const scope = scopeForUnreadWake(state, false);
  if (scope.eligible || scope.eligibleSeqs.length !== 0) {
    throw new Error(`a main-only class was offered to the branch: ${row} -> ${JSON.stringify(scope)}`);
  }
  if (scope.corrupted) throw new Error(`an ordinary main-only row must not read as corrupted: ${row}`);
}

writeFileSync(
  `${state}/.wake-queue`,
  [
    "1\t1\tcheck\tx-inbox",
    "1\t2\tsignal\ttask-a.status\tsignal: task-a.status",
  ].join("\n"),
);
const truncated = scopeForUnreadWake(state, false);
if (!truncated.corrupted || truncated.eligible || truncated.eligibleSeqs.length !== 0) {
  throw new Error(`a four-field queue row was not classified as corruption: ${JSON.stringify(truncated)}`);
}

// A mixed queue: the main-only row (seq 1) never vetoes the task-local rows
// (seq 2, 3) - the reproduction from the task.
writeFileSync(
  `${state}/.wake-queue`,
  [
    "1\t1\tcheck\tx-inbox\tcheck: pending x mention",
    "1\t2\tsignal\ttask-a.status\tsignal: task-a.status",
    "1\t3\tstale\tfm-window\tstale: fm-window",
  ].join("\n"),
);
const mixed = scopeForUnreadWake(state, false);
if (!mixed.eligible) throw new Error(`mixed queue with eligible task-local rows must stay eligible: ${JSON.stringify(mixed)}`);
if (mixed.eligibleSeqs.slice().sort().join(",") !== "2,3") {
  throw new Error(`eligibleSeqs must name exactly the task-local rows: ${JSON.stringify(mixed)}`);
}
if (!mixed.projects.includes(project)) {
  throw new Error(`eligible project context lost: ${JSON.stringify(mixed.projects)}`);
}

if (!activateEligibleRowsOwner(state, process.env.GRANT, process.pid, "fixture")) {
  throw new Error("branch owner activation failed");
}
if (writeEligibleRowsSnapshot(state, mixed.eligibleSeqs, process.env.GRANT, "fixture") !== "published") {
  throw new Error("snapshot write reported failure");
}
const snapshot = readFileSync(`${state}/${BRANCH_ELIGIBLE_ROWS_FILE}`, "utf8").trim().split("\n");
if (snapshot.join(",") !== "2,3") throw new Error(`snapshot did not name exactly the eligible rows: ${snapshot}`);

// An empty eligible set is refused rather than clearing the snapshot to
// nothing - a caller must never overwrite a live snapshot with an empty one.
if (writeEligibleRowsSnapshot(state, [], process.env.GRANT, "fixture") !== "error") {
  throw new Error("an empty eligible set must not be written");
}
if (!releaseEligibleRowsSnapshot(state, process.env.GRANT, "fixture")) throw new Error("snapshot release failed");
writeFileSync(`${state}/.main-eligible-rows`, "2\n");
if (writeEligibleRowsSnapshot(state, ["2"], process.env.GRANT, "fixture") !== "main-owned") {
  throw new Error("a row already claimed by main was not reported as main-owned");
}

// A heartbeat is not vetoed or ridden into main by a co-present check row.
// The check row is permanently main-owned in every mode, so it is excluded
// from the claim rather than deferring a fleet review that has nothing to do
// with it - the captain's reproduction.
writeFileSync(
  `${state}/.wake-queue`,
  [
    "1\t1\tcheck\tx-inbox\tcheck: pending x mention",
    "1\t2\theartbeat\theartbeat\theartbeat",
    "1\t3\tsignal\ttask-a.status\tsignal: task-a.status",
  ].join("\n"),
);
const heartbeatMixed = scopeForUnreadWake(state, true);
if (!heartbeatMixed.eligible || heartbeatMixed.corrupted) {
  throw new Error(`a co-present check row rode a heartbeat into main: ${JSON.stringify(heartbeatMixed)}`);
}
if (heartbeatMixed.eligibleSeqs.slice().sort().join(",") !== "2,3") {
  throw new Error(`a heartbeat claim must cover every branch-ownable row and no check row: ${JSON.stringify(heartbeatMixed)}`);
}

// All-or-nothing is unchanged in what it actually guarantees: a heartbeat
// review takes every branch-ownable row or none of them, so a row this scan
// cannot resolve still defers the whole review to main.
writeFileSync(
  `${state}/.wake-queue`,
  [
    "1\t1\theartbeat\theartbeat\theartbeat",
    "1\t2\tsignal\tno-such-task.status\tsignal: no-such-task.status",
  ].join("\n"),
);
const heartbeatUnresolvable = scopeForUnreadWake(state, true);
if (heartbeatUnresolvable.eligible || !heartbeatUnresolvable.corrupted) {
  throw new Error(`an unresolvable row must still defer a heartbeat review: ${JSON.stringify(heartbeatUnresolvable)}`);
}
writeFileSync(
  `${state}/.wake-queue`,
  [
    "1\t1\theartbeat\theartbeat\theartbeat",
    "1\t2\tinvented\tsomething\tinvented: not a kind fm_wake_append emits",
  ].join("\n"),
);
const heartbeatUnknownKind = scopeForUnreadWake(state, true);
if (heartbeatUnknownKind.eligible || !heartbeatUnknownKind.corrupted) {
  throw new Error(`an unknown row kind must still defer a heartbeat review: ${JSON.stringify(heartbeatUnknownKind)}`);
}

// A queue holding nothing but main-only rows leaves a heartbeat with nothing
// to hand over, so it is not offered rather than granted an empty claim.
writeFileSync(`${state}/.wake-queue`, "1\t1\tcheck\tx-inbox\tcheck: pending x mention");
const heartbeatNothingOwnable = scopeForUnreadWake(state, true);
if (heartbeatNothingOwnable.eligible || heartbeatNothingOwnable.eligibleSeqs.length !== 0) {
  throw new Error(`a heartbeat was offered with no branch-ownable row: ${JSON.stringify(heartbeatNothingOwnable)}`);
}
if (heartbeatNothingOwnable.corrupted) {
  throw new Error(`a purely main-only queue is ordinary absence, not a fault: ${JSON.stringify(heartbeatNothingOwnable)}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "main-only classification and eligible-row snapshot contract must hold: $out"
  pass "scopeForUnreadWake excludes every main-only class without vetoing eligible task-local rows, and writes the eligible snapshot"
}

# The model picker's bounded scrolling and its search ranking are Pi's own
# SelectList and fuzzyFilter, so the guarantee only holds while the installed
# Pi still exports them and still bounds what it renders. Stubs cannot answer
# that, so this runs against the real package and skips when it is absent.
test_real_pi_picker_primitives_stay_bounded_and_searchable() {
  if ! command -v node >/dev/null 2>&1; then
    echo "skip: node not found for the Pi picker primitives test"
    return
  fi
  local package_dir fixture original_dir out status
  package_dir=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
  if [ ! -f "$package_dir/package.json" ]; then
    echo "skip: installed @earendil-works/pi-coding-agent package not found"
    return
  fi
  fixture="$TMP_ROOT/real-picker-primitives"
  mkdir -p "$fixture/lib" "$fixture/node_modules/@earendil-works"
  cp "$ROOT/.pi/extensions/lib/fm-branch-model-picker.ts" "$fixture/lib/fm-branch-model-picker.ts"
  ln -s "$package_dir" "$fixture/node_modules/@earendil-works/pi-coding-agent"
  ln -s "$package_dir/node_modules/@earendil-works/pi-tui" "$fixture/node_modules/@earendil-works/pi-tui"
  original_dir=$PWD
  cd "$fixture" || fail "could not enter the Pi picker primitives fixture"
  LIB="$fixture/lib/fm-branch-model-picker.ts" PI_VERSION_FILE="$package_dir/package.json" \
    node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";

const version = JSON.parse(readFileSync(process.env.PI_VERSION_FILE, "utf8")).version;
const { Input, SelectList, fuzzyFilter } = await import("@earendil-works/pi-tui");
const { DynamicBorder } = await import("@earendil-works/pi-coding-agent");
for (const [name, value] of [
  ["Input", Input],
  ["SelectList", SelectList],
  ["fuzzyFilter", fuzzyFilter],
  ["DynamicBorder", DynamicBorder],
]) {
  if (typeof value !== "function") {
    throw new Error(`installed pi ${version} no longer exports ${name}, which the supervision model picker renders through`);
  }
}

const { buildBranchModelItems, filterBranchPickerItems, BRANCH_PICKER_MAX_VISIBLE } = await import(
  pathToFileURL(process.env.LIB).href
);
const labels = Array.from({ length: 40 }, (_, i) => `anthropic/bulk-model-${i + 1}`);
labels.push("openai-codex/cheap-oauth");
const items = buildBranchModelItems("Follow main (anthropic/main-model)", labels, null);

// Pi's own list renders a bounded window plus at most one scroll indicator,
// which is what keeps a long catalog inside the dialog.
const passthrough = (text) => text;
const list = new SelectList(items, BRANCH_PICKER_MAX_VISIBLE, {
  selectedPrefix: passthrough,
  selectedText: passthrough,
  description: passthrough,
  scrollInfo: passthrough,
  noMatch: passthrough,
});
const lines = list.render(80);
if (lines.length > BRANCH_PICKER_MAX_VISIBLE + 1) {
  throw new Error(`installed pi ${version} rendered ${lines.length} rows for ${items.length} models instead of a bounded window`);
}
if (!lines[0].includes("Follow main")) {
  throw new Error(`installed pi ${version} did not render the first row the picker opens on`);
}

// Pi's own fuzzy ranking drives the search box, and following main stays first.
const searched = filterBranchPickerItems(items, "cheap", fuzzyFilter);
if (searched.length !== 1 || searched[0].value !== "openai-codex/cheap-oauth") {
  throw new Error(`installed pi ${version} fuzzy search did not narrow the catalog: ${JSON.stringify(searched)}`);
}
const mainSearch = filterBranchPickerItems(items, "main", fuzzyFilter);
if (mainSearch.length === 0 || mainSearch[0].label !== "Follow main (anthropic/main-model)") {
  throw new Error(`installed pi ${version} fuzzy ranking moved following main out of first place`);
}

// The search box is Pi's own single-line input.
const input = new Input();
input.handleInput("c");
input.handleInput("h");
if (input.getValue() !== "ch") {
  throw new Error(`installed pi ${version} Input no longer accumulates typed characters for the picker's search box`);
}
JS
  status=$?
  cd "$original_dir" || fail "could not leave the Pi picker primitives fixture"
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "the installed Pi must still provide the picker's bounded searchable primitives: $out"
  [ -z "$out" ] || fail "Pi picker primitives test printed output: $out"
  pass "the installed Pi still bounds the picker's list and ranks its search"
}

test_outcomes_tool_uses_stock_execution_and_export_consumers() {
  if ! command -v node >/dev/null 2>&1; then
    echo "skip: node not found for Pi outcomes rendering test"
    return
  fi
  local package_dir fixture out status
  package_dir=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
  if [ ! -f "$package_dir/package.json" ]; then
    echo "skip: installed @earendil-works/pi-coding-agent package not found"
    return
  fi
  fixture="$TMP_ROOT/stock-render-consumers"
  mkdir -p "$fixture/.pi/extensions/lib" "$fixture/node_modules/@earendil-works"
  cp "$EXT" "$fixture/.pi/extensions/fm-branch-supervision.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$fixture/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-model-picker.ts" "$fixture/.pi/extensions/lib/fm-branch-model-picker.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$fixture/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$fixture/.pi/extensions/lib/fm-operational-input.ts"
  ln -s "$package_dir" "$fixture/node_modules/@earendil-works/pi-coding-agent"
  ln -s "$package_dir/node_modules/@earendil-works/pi-tui" "$fixture/node_modules/@earendil-works/pi-tui"
  ln -s "$package_dir/node_modules/@earendil-works/pi-ai" "$fixture/node_modules/@earendil-works/pi-ai"
  ln -s "$package_dir/node_modules/typebox" "$fixture/node_modules/typebox"

  out=$(cd "$fixture" && EXT="$fixture/.pi/extensions/fm-branch-supervision.ts" PI_PACKAGE_DIR="$package_dir" node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";

const packageRoot = process.env.PI_PACKAGE_DIR;
const [{ ToolExecutionComponent }, { createToolHtmlRenderer }, { initTheme, theme }] = await Promise.all([
  import(pathToFileURL(`${packageRoot}/dist/modes/interactive/components/tool-execution.js`).href),
  import(pathToFileURL(`${packageRoot}/dist/core/export-html/tool-renderer.js`).href),
  import(pathToFileURL(`${packageRoot}/dist/modes/interactive/theme/theme.js`).href),
]);
initTheme("dark");

const listeners = new Map();
const tools = [];
const pi = {
  events: {
    on(name, listener) {
      listeners.set(name, [...(listeners.get(name) ?? []), listener]);
    },
    emit(name, data) {
      for (const listener of listeners.get(name) ?? []) listener(data);
    },
  },
  on() {},
  registerCommand() {},
  registerMessageRenderer() {},
  registerTool(tool) { tools.push(tool); },
  sendMessage() {},
  sendUserMessage() {},
};
const extension = await import(`${pathToFileURL(process.env.EXT).href}?consumer=${Date.now()}`);
extension.default(pi);
const actualDefinition = tools.find((tool) => tool.name === "fm_branch_outcomes");
if (!actualDefinition) throw new Error("fm_branch_outcomes was not registered");
const stockDefinition = { ...actualDefinition };
delete stockDefinition.renderShell;
delete stockDefinition.renderCall;
delete stockDefinition.renderResult;

const args = { recent: 2 };
const result = {
  content: [{
    type: "text",
    text: [
      "\x1b[31mOUTCOME_ONE\x1b[0m",
      "OUT\u0000COME_TWO\uFFF9",
      "OUTCOME_THREE",
      "OUTCOME_FOUR",
      "OUTCOME_FIVE",
      "OUTCOME_SIX",
      "OUTCOME_SEVEN",
      "OUTCOME_EIGHT",
      "OUTCOME_NINE",
      "OUTCOME_TEN",
      "OUTCOME_ELEVEN",
      "OUTCOME_TWELVE",
    ].join("\r\n"),
  }],
  details: { ok: true },
  isError: false,
};
const ui = { requestRender() {} };
const stockRow = new ToolExecutionComponent("fm_branch_outcomes", "stock", args, { showImages: false }, stockDefinition, ui, process.cwd());
const actualRow = new ToolExecutionComponent("fm_branch_outcomes", "actual", args, { showImages: false }, actualDefinition, ui, process.cwd());
for (const row of [stockRow, actualRow]) {
  row.markExecutionStarted();
  row.setArgsComplete();
  row.updateResult(result);
}
const collapsedStock = stockRow.render(100);
const collapsedActual = actualRow.render(100);
if (JSON.stringify(collapsedActual) !== JSON.stringify(collapsedStock)) {
  throw new Error("Calm-off ToolExecutionComponent rendering differs from Pi stock");
}
const collapsedText = collapsedStock.join("\n");
if (collapsedText.includes("OUTCOME_TWELVE") || !collapsedText.includes("more lines") || !collapsedText.includes("to expand")) {
  throw new Error("stock rendering fixture did not exercise its collapsed preview and expansion hint");
}
stockRow.setExpanded(true);
actualRow.setExpanded(true);
const expandedStock = stockRow.render(100);
const expandedActual = actualRow.render(100);
if (JSON.stringify(expandedActual) !== JSON.stringify(expandedStock)) {
  throw new Error("expanded Calm-off ToolExecutionComponent rendering differs from Pi stock");
}
if (!expandedStock.join("\n").includes("OUTCOME_TWELVE") || JSON.stringify(expandedStock) === JSON.stringify(collapsedStock)) {
  throw new Error("stock rendering fixture did not exercise expanded output");
}
pi.events.emit("firstmate:calm-presentation", { active: true, stockExportRendering: false });
actualRow.invalidate();
if (actualRow.render(100).length !== 0) {
  throw new Error("Calm-on ToolExecutionComponent row remained visible");
}
pi.events.emit("firstmate:calm-presentation", { active: false, stockExportRendering: false });
actualRow.invalidate();
if (JSON.stringify(actualRow.render(100)) !== JSON.stringify(stockRow.render(100))) {
  throw new Error("ToolExecutionComponent rendering did not restore after live toggle");
}

pi.events.emit("firstmate:calm-presentation", { active: true, stockExportRendering: true });
const stockHtml = createToolHtmlRenderer({ getToolDefinition: () => stockDefinition, theme, cwd: process.cwd() });
const actualHtml = createToolHtmlRenderer({ getToolDefinition: () => actualDefinition, theme, cwd: process.cwd() });
const stockCall = stockHtml.renderCall("stock-html", "fm_branch_outcomes", args);
const actualCall = actualHtml.renderCall("actual-html", "fm_branch_outcomes", args);
const stockResult = stockHtml.renderResult("stock-html", "fm_branch_outcomes", result.content, result.details, false);
const actualResult = actualHtml.renderResult("actual-html", "fm_branch_outcomes", result.content, result.details, false);
if (actualCall !== undefined || actualResult !== undefined || stockCall !== undefined || stockResult !== undefined) {
  throw new Error("stock export rendering did not delegate to Pi's structured fallback");
}
JS
  )
  status=$?
  expect_code 0 "$status" "Pi outcomes rendering consumers must preserve stock behavior: $out"
  [ -z "$out" ] || fail "Pi outcomes rendering consumer test printed output: $out"
  pass "fm_branch_outcomes hides through ToolExecutionComponent while Calm-off and HTML export stay stock"
}

test_outcomes_tool_uses_stock_execution_and_export_consumers
test_real_pi_picker_primitives_stay_bounded_and_searchable
test_branch_dispatch_two_stage_filter_and_prefix_contract
test_requested_healthy_outcome_and_unsolicited_routine_outcome_delivery
test_captain_outcome_encoding_failure_delivers_plain_instruction
test_branch_dispatch_classifies_main_only_rows_and_writes_the_eligible_snapshot
test_branch_cache_key_is_per_home_stable
test_branch_default_on_heartbeat_afk_and_fallback
test_branch_predrain_recheck_keeps_a_heartbeat_a_co_present_check_arrives_under
test_branch_predrain_recheck_excludes_new_main_owned_row_without_deferring_eligible_work
test_settled_branch_prompt_releases_unacknowledged_grant
test_main_owned_grant_result_falls_back_to_main
test_branch_predrain_recheck_noops_already_drained_wake
test_branch_mirror_filters_order_and_cursor
test_branch_session_persists_across_process_restarts
test_branch_model_pin_applies_and_absent_pin_keeps_the_default
test_unpinned_branch_follows_main_model_changes_live
test_supervision_model_command_persists_and_rebinds_the_live_branch
test_supervision_model_picker_is_bounded_searchable_and_branch_only
test_branch_model_picker_keeps_follow_main_first_under_ranking
test_branch_effort_pin_applies_and_absent_pin_follows_main
test_unpinned_branch_follows_main_effort_changes_live
test_supervision_model_command_picks_effort_after_the_model
test_unusable_model_pin_falls_back_to_main
test_replacement_activation_cleans_leases_and_retries_failure
test_cold_start_activates_after_lock_acquisition
test_queued_actions_recheck_lock_ownership
test_stale_generation_boundaries_are_side_effect_free
test_secondary_session_stays_inert
test_rebind_remirrors_undelivered_dialog_from_durable_cursor
