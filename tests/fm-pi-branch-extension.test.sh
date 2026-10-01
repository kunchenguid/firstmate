#!/usr/bin/env bash
# Tests for the tracked Pi supervision-branch extension
# (.pi/extensions/fm-branch-supervision.ts): wake dispatch acceptance and
# gating, the two-stage noise filter's second stage (verdict-driven delivery
# into main), store-first durability through the real bin/fm-branch-outcome.sh,
# the byte-stable tool order and per-home prompt_cache_key hook, the dialog
# mirror, and the per-main-session branch conversation. The Pi SDK is stubbed
# (scriptable in-process sessions); every fleet-record behavior runs the REAL
# bin scripts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-branch-extension)
EXT="$ROOT/.pi/extensions/fm-branch-supervision.ts"
export NODE_NO_WARNINGS=1
# The Pi release whose stock renderer stopped supplying an implicit reset at
# multiline boundaries, which is the contract this file's renderer cases
# compare against.
PI_STOCK_RENDER_FLOOR=0.84.4

# Semantic-version floor for a version string this file already holds (Pi's
# package.json field). bin/fm-bootstrap.sh's tool_version_at_least is the same
# rule for a tool it invokes itself; this is the string-shaped form, kept here
# rather than in tests/lib.sh because this is its only consumer and every test
# sources that library. It is deliberately as strict: a version that is not
# exactly one major.minor.patch triple never satisfies a floor it was not
# checked against.
pi_version_at_least() {  # <version> <min-version>
  local version=$1 min=$2 parts major minor patch extra
  local min_major min_minor min_patch min_extra
  parts=$(printf '%s\n' "$version" | sed -nE 's/.*[vV]?([0-9]+)\.([0-9]+)\.([0-9]+).*/\1 \2 \3/p' | head -n 1)
  IFS=' ' read -r major minor patch extra <<< "$parts"
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$min"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}

# Keep JavaScript heredocs outside command substitutions. Stock macOS Bash
# 3.2 reparses quotes and template literals inside that combination.
install_pi_branch_extension_fixture() {
  local repo=$1
  mkdir -p \
    "$repo/.pi/extensions/lib" \
    "$repo/stub-agent-dir/npm/node_modules/pi-openai-codex-compat/extensions" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/node_modules/@earendil-works/pi-ai" \
    "$repo/node_modules/@earendil-works/pi-tui" \
    "$repo/node_modules/typebox"
  cp "$EXT" "$repo/.pi/extensions/fm-branch-supervision.ts"
  cp "$ROOT/.pi/extensions/fm-periodic-stow.ts" "$repo/.pi/extensions/fm-periodic-stow.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$repo/.pi/extensions/lib/fm-native-contract.ts"
  cp "$ROOT/.pi/extensions/lib/fm-task-continuation.ts" "$repo/.pi/extensions/lib/fm-task-continuation.ts"
  cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$repo/.pi/extensions/lib/fm-async-exec.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-model-picker.ts" "$repo/.pi/extensions/lib/fm-branch-model-picker.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/.pi/extensions/lib/fm-feishu-native-channel.ts" "$repo/.pi/extensions/lib/fm-feishu-native-channel.ts"
  mkdir -p "$repo/bin"
  cp "$ROOT/bin/fm-short-notification.mjs" "$repo/bin/fm-short-notification.mjs"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  cp "$ROOT/bin/fm-feishu-state.mjs" "$repo/bin/fm-feishu-state.mjs"
  chmod +x "$repo/bin/fm-operational-input.sh"
  cat > "$repo/stub-agent-dir/npm/node_modules/pi-openai-codex-compat/package.json" <<'JSON'
{
  "name": "pi-openai-codex-compat",
  "version": "0.0.16",
  "peerDependencies": {
    "@earendil-works/pi-coding-agent": ">=0.87.0 <0.88.0"
  },
  "pi": {
    "extensions": ["./extensions/index.ts"]
  }
}
JSON
  cat > "$repo/stub-agent-dir/npm/node_modules/pi-openai-codex-compat/extensions/index.ts" <<'TS'
export default function registerCompat(pi) {
  pi.on("session_start", () => {
    globalThis.__fmLifecycle ??= [];
    globalThis.__fmLifecycle.push("compat-session-start");
    globalThis.__fmCompatNativeCompactionReady = true;
    globalThis.__fmCompatProviderRegistered = true;
    if (globalThis.__fmCompatStartupError) throw new Error(globalThis.__fmCompatStartupError);
    // Match the real package's attempt to add its Codex-only tools. The SDK
    // allowlist must keep every one of them outside the supervision branch.
    pi.setActiveTools([
      ...pi.getActiveTools(),
      "apply_patch",
      "image_gen.imagegen",
      "web.run",
      "edit",
      "write",
    ]);
  });
}
TS
  export FM_TEST_AGENT_DIR="$repo/stub-agent-dir"
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

export const VERSION = globalThis.__fmPiVersion ?? "0.87.1";

export function getAgentDir() {
  return process.env.FM_TEST_AGENT_DIR ?? "/stub-agent-dir";
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
    this.registeredProviderConfigs = new Map();
    // Like the real runtime, a registered provider's credentials are only
    // known once refresh() has run for it; registration alone is provisional.
    this.pendingAuth = new Set();
  }
  static async create() {
    const queuedError = globalThis.__fmModelRuntimeErrors?.shift();
    if (queuedError) throw new Error(queuedError);
    if (globalThis.__fmModelRuntimeError) throw new Error(globalThis.__fmModelRuntimeError);
    const runtime = new ModelRuntime();
    (globalThis.__fmModelRuntimes ??= []).push(runtime);
    return runtime;
  }
  registerProvider(providerId, config) {
    this.registeredProviderConfigs.set(providerId, config);
    for (const model of config.models ?? []) {
      this.models.push({ ...model, provider: providerId });
    }
    if (config.oauth || config.apiKey) this.pendingAuth.add(providerId);
  }
  async refresh(options) {
    for (const providerId of options?.providers ?? this.pendingAuth) {
      if (this.pendingAuth.delete(providerId)) this.authenticated.add(providerId);
    }
  }
  getModel(provider, id) {
    return this.models.find((model) => model.provider === provider && model.id === id);
  }
  hasConfiguredAuth(provider) {
    return this.authenticated.has(provider);
  }
}
export class SettingsManager {
  static create(cwd, agentDir, options = {}) {
    (globalThis.__fmSettingsLoads ??= []).push({ cwd, agentDir, options });
    let settings = {};
    const errors = [];
    try {
      if (existsSync(`${agentDir}/settings.json`)) settings = JSON.parse(readFileSync(`${agentDir}/settings.json`, "utf8"));
    } catch (error) { errors.push({ scope: "global", error }); }
    return { getGlobalSettings: () => structuredClone(settings), drainErrors: () => errors };
  }
  static inMemory(settings = {}, options = {}) {
    return { settings, options, isProjectTrusted: () => options.projectTrusted === true };
  }
}
export class DefaultPackageManager {
  constructor(options) {
    this.options = options;
    (globalThis.__fmPackageManagers ??= []).push(this);
  }
  getInstalledPath(source, scope) {
    (globalThis.__fmPackageLookups ??= []).push({ source, scope });
    if (globalThis.__fmCompatAbsent) return undefined;
    const path = `${this.options.agentDir}/npm/node_modules/pi-openai-codex-compat`;
    return existsSync(path) ? path : undefined;
  }
  async resolveExtensionSources(sources, options) {
    (globalThis.__fmPackageResolutions ??= []).push({ sources: [...sources], options: options ?? {} });
    if (globalThis.__fmCompatResolveError) throw new Error(globalThis.__fmCompatResolveError);
    const root = this.getInstalledPath(sources[0], "user");
    return {
      extensions: root
        ? [{ path: `${root}/extensions/index.ts`, enabled: true, metadata: { source: sources[0], scope: "user", origin: "package", baseDir: root }, ...globalThis.__fmCompatResolutionOverride }]
        : [],
      skills: [],
      prompts: [],
      themes: [],
    };
  }
}
export class DefaultResourceLoader {
  constructor(options) {
    this.options = options;
    (globalThis.__fmLoaders ??= []).push(this);
  }
  async reload() {
    if (globalThis.__fmCompatLoadError && this.options.additionalExtensionPaths?.length) {
      this.extensionsResult = {
        extensions: [],
        errors: [{ path: this.options.additionalExtensionPaths[0], error: globalThis.__fmCompatLoadError }],
        runtime: {},
      };
      this.reloaded = true;
      return;
    }
    this.extensionsResult = {
      extensions: (this.options.additionalExtensionPaths ?? []).map((path) => ({ path })),
      errors: [],
      runtime: {},
    };
    this.reloaded = true;
  }
  getExtensions() {
    return this.extensionsResult ?? { extensions: [], errors: [], runtime: {} };
  }
}

export class SessionManager {
  constructor(file) {
    this.file = file;
    this.entries = [];
  }
  static create(cwd, dir) {
    globalThis.__fmCreateCount = (globalThis.__fmCreateCount ?? 0) + 1;
    const sm = new SessionManager(`${dir}/created-${process.pid}-${globalThis.__fmCreateCount}.jsonl`);
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
  getEntries() {
    return this.entries;
  }
  appendCustomEntry(customType, data) {
    const entry = { type: "custom", id: `branch-entry-${this.entries.length}`, parentId: this.entries.at(-1)?.id ?? null,
      timestamp: new Date().toISOString(), customType, data };
    this.entries.push(entry);
    appendFileSync(this.file, `${JSON.stringify(entry)}\n`);
    return entry.id;
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
  const persistMessages = (messages) => {
    const tracked = [...messages];
    tracked.push = (...items) => {
      for (const message of items) options.sessionManager.getEntries().push({ type: "message", message });
      return Array.prototype.push.apply(tracked, items);
    };
    return tracked;
  };
  let branchMessages = persistMessages(globalThis.__fmInitialBranchMessages ?? []);
  for (const message of branchMessages) options.sessionManager.getEntries().push({ type: "message", message });
  const session = {
    options,
    ops: [],
    get messages() {
      return branchMessages;
    },
    set messages(messages) {
      branchMessages = persistMessages(messages);
    },
    disposed: false,
    streaming: false,
    get isStreaming() {
      return session.streaming;
    },
    async prompt(text) {
      session.streaming = true;
      globalThis.__fmPromptStarts = (globalThis.__fmPromptStarts ?? 0) + 1;
      globalThis.__fmLifecycle ??= [];
      globalThis.__fmLifecycle.push("prompt");
      if (globalThis.__fmPromptGate) {
        globalThis.__fmPromptStarted = true;
        await globalThis.__fmPromptGate;
      }
      session.ops.push({ kind: "prompt", text });
      (globalThis.__fmPrompts ??= []).push(text);
      session.messages.push({ role: "user", content: text });
      await globalThis.__fmOnBranchPrompt?.({ session, text });
      session.streaming = false;
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
    async abort() {
      session.aborted = true;
      (globalThis.__fmLifecycle ??= []).push("abort");
      await globalThis.__fmAbortAction?.();
      session.streaming = false;
    },
    async waitForIdle() {
      session.waitedForIdle = true;
      (globalThis.__fmLifecycle ??= []).push("wait-for-idle");
      if (session.streaming) await globalThis.__fmPromptGate;
    },
    async bindExtensions(bindings) {
      session.bound = true;
      globalThis.__fmLifecycle ??= [];
      globalThis.__fmLifecycle.push("bind-extensions");
      if (globalThis.__fmBindExtensionsError) throw new Error(globalThis.__fmBindExtensionsError);
      if (options.resourceLoader.options.additionalExtensionPaths?.length) {
        if (globalThis.__fmCompatStartupError) {
          bindings.onError?.({
            extensionPath: options.resourceLoader.options.additionalExtensionPaths[0],
            event: "session_start",
            error: globalThis.__fmCompatStartupError,
          });
        } else {
          globalThis.__fmLifecycle.push("compat-session-start");
          globalThis.__fmCompatNativeCompactionReady = true;
          globalThis.__fmCompatProviderRegistered = true;
          session.activeTools = globalThis.__fmCompatActiveTools ?? session.activeTools.filter((name) => options.tools.includes(name));
        }
      }
    },
    getActiveToolNames() {
      return [...session.activeTools];
    },
    setActiveToolsByName(names) {
      if (globalThis.__fmRefuseToolRestore) return;
      session.activeTools = names.filter((name) => options.tools.includes(name));
    },
    activeTools: [...options.tools],
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
  Array(items) { return { type: "array", items }; },
  Null() { return { type: "null" }; },
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
const { appendFileSync, mkdirSync, writeFileSync } = await import("node:fs");
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
  getRegisteredProviderConfig: (providerId) => globalThis.__fmExtensionProviderConfigs?.get(providerId),
  getRegisteredProviderIds: () => [...(globalThis.__fmExtensionProviderConfigs?.keys() ?? [])],
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
const entryRenderers = new Map();
const mainEntries = [];
const mainSessionManager = {
  getSessionFile: () => `${home}/main.jsonl`,
  getEntries: () => mainEntries,
};
const defaultSessionCtx = { model: mainModel, modelRegistry, sessionManager: mainSessionManager };
let activeMainSession = mainSessionManager;
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
  registerEntryRenderer(customType, renderer) {
    entryRenderers.set(customType, renderer);
  },
  appendEntry(customType, data) {
    activeMainSession.getEntries().push({ type: "custom", customType, data });
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
// Pi's own extension runner awaits every handler in turn
// (dist/core/extensions/runner.js emit), so this driver does too: a handler
// that awaits a subprocess must be allowed to finish before the driver
// asserts on what it did.
async function fire(event, payload, ctx) {
  const eventCtx = ctx;
  if (eventCtx?.sessionManager) activeMainSession = eventCtx.sessionManager;
  for (const handler of piHandlers.get(event) ?? []) await handler(payload, eventCtx);
}
let nextOfferToken = 0;
function makeOffer(message, projects = [approvedProject], heartbeat = false, eligible = projects.length > 0 || heartbeat, seq = 1) {
  const offer = {
    token: `test-${process.pid}-${++nextOfferToken}`,
    message,
    projects,
    heartbeat,
    eligible,
    eligibleSeqs: eligible ? [String(seq)] : [],
    eligibleTasks: eligible && !heartbeat ? ["branch-driver"] : [],
    taskBySeq: eligible && !heartbeat ? { [String(seq)]: "branch-driver" } : {},
    declineReason: "no-listener",
    accepted: false,
    settlement: Promise.resolve(),
    accept(settlement = Promise.resolve()) {
      offer.accepted = true;
      offer.declineReason = "";
      offer.settlement = settlement;
    },
    decline(reason) {
      if (!offer.accepted) offer.declineReason = reason;
    },
  };
  return offer;
}
function dispatch(message, projects, heartbeat, eligible, seq = 1, append = false) {
  const offer = makeOffer(message, projects, heartbeat, eligible, seq);
  if (offer.eligible) {
    const row = offer.heartbeat
      ? `1\t${seq}\theartbeat\theartbeat\theartbeat\n`
      : `1\t${seq}\tsignal\tbranch-driver.status\t${message}\n`;
    if (append) appendFileSync(`${home}/state/.wake-queue`, row);
    else writeFileSync(`${home}/state/.wake-queue`, row);
  }
  bus.emit("fm-branch-supervision:dispatch", offer);
  return offer;
}
function dispatchThroughWatcher(message, projects, heartbeat, eligible, seq = 1, append = false) {
  const offer = dispatch(message, projects, heartbeat, eligible, seq, append);
  if (!offer.accepted) {
    pi.sendUserMessage(`FIRSTMATE WATCHER WAKE: ${message}`, { deliverAs: "followUp" });
    return offer;
  }
  void offer.settlement.catch((error) => {
    pi.sendUserMessage(
      `FIRSTMATE WATCHER WAKE: ${message}\n\nSupervision branch unavailable, falling back to main: ${error instanceof Error ? error.message : String(error)}`,
      { deliverAs: "followUp" },
    );
  });
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
await eval(`(async () => { ${prelude}; globalThis.__t = { pi, fire, dispatch, settle, outcomeScript, sentToMain, mainUserMessages, mainTools, renderers, entryRenderers, mainEntries, defaultSessionCtx, home, realRoot }; })()`);
const { pi, fire, dispatch, settle, outcomeScript, sentToMain, mainUserMessages, mainTools, renderers, entryRenderers, mainEntries, defaultSessionCtx, home, realRoot } = globalThis.__t;
import { readFileSync, writeFileSync } from "node:fs";

writeFileSync(`${home}/state/.lock`, `${process.ppid}\n`);
await fire("session_start", {}, defaultSessionCtx);

// 1. An accepted wake reaches the branch session, never main. Keep the
// scripted turn open until its durable report below, matching a real Pi prompt
// whose tool calls complete before session.prompt() settles.
let finishWakePrompt;
globalThis.__fmOnBranchPrompt = () => new Promise((resolve) => { finishWakePrompt = resolve; });
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
if (JSON.stringify(session.options.tools) !== JSON.stringify(["read", "bash", "fm_task_continuation", "fm_branch_report"])) {
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
// captain-relevant persists a visible entry with no model turn. Store rows are
// written before delivery and marked read only after it.
const report = session.options.customTools.find((tool) => tool.name === "fm_branch_report");
const r1 = await report.execute("call-1", { task: "branch-driver", verdict: "routine", summary: "worker healthy, no action needed", wake: "signal: working" }, undefined, undefined, {});
if (r1.isError) throw new Error(`routine report failed: ${JSON.stringify(r1)}`);
finishWakePrompt();
// Reports below are made outside any wake prompt (as a real Pi turn cannot):
// wait for the wake to settle so its task scope has been cleared.
await offer.settlement;
globalThis.__fmOnBranchPrompt = undefined;
if (sentToMain.length !== 1) throw new Error("routine report did not merge exactly one note");
if (sentToMain[0].message.customType !== "fm-branch-merge") throw new Error("merge note has the wrong custom type");
if (sentToMain[0].options.triggerTurn) throw new Error("routine idle merge must not trigger a turn");
if (sentToMain[0].options.deliverAs) throw new Error("routine idle merge must append immediately");
await fire("agent_start", {});
await report.execute("call-2", { task: "task-9", verdict: "routine", summary: "still healthy" }, undefined, undefined, {});
if (sentToMain[1].options.deliverAs !== "nextTurn" || sentToMain[1].options.triggerTurn) {
  throw new Error(`routine busy merge must defer to nextTurn without a turn: ${JSON.stringify(sentToMain[1].options)}`);
}
await fire("agent_end", {});
await report.execute("call-3", { task: "task-9", verdict: "captain", summary: "PR https://example.com/pr/9 checks green, ready for review" }, undefined, undefined, {});
// A captain outcome opens exactly ONE sequence-keyed processing turn: a
// hidden, typed request that names the sequence/task identity. The exact
// summary remains in the visible sequence-keyed entry instead of being loaded
// again on every processing retry.
const processingRequests = sentToMain.filter((sent) => sent.message.customType === "fm-branch-process");
if (processingRequests.length !== 1) throw new Error(`captain delivery opened ${processingRequests.length} processing requests, not exactly one`);
const processingRequest = processingRequests[0];
if (processingRequest.options.triggerTurn !== true || processingRequest.options.deliverAs !== "followUp") {
  throw new Error(`the processing request must open one follow-up turn: ${JSON.stringify(processingRequest.options)}`);
}
if (processingRequest.message.display !== false) throw new Error("the processing request must stay hidden: the visible entry is the display");
if (!processingRequest.message.content.includes("[seq 3] task=task-9") || processingRequest.message.content.includes("PR https://example.com/pr/9")) {
  throw new Error(`the processing request did not project to identity-only content: ${processingRequest.message.content}`);
}
if (sentToMain.some((sent) => sent.options.triggerTurn && sent.message.customType !== "fm-branch-process")) {
  throw new Error("an unkeyed turn opened on main");
}
if (sentToMain.length !== 3) throw new Error(`captain delivery changed routine delivery: ${JSON.stringify(sentToMain)}`);
writeFileSync(`${home}/state/delivered-processing-request`, processingRequest.message.content);
if (typeof sentToMain[0].message.content !== "string" || !sentToMain[0].message.content.startsWith("⛵ ")) {
  throw new Error(`routine note missing sailboat prefix: ${sentToMain[0].message.content}`);
}
if (/branch merged|\[routine\]|\[captain\]/.test(sentToMain[0].message.content)) {
  throw new Error(`routine note still has boilerplate: ${sentToMain[0].message.content}`);
}
// A routine note is rendered as a custom message. A captain outcome is a
// versioned custom session entry whose exact store summary is its payload.
if (sentToMain[0].message.display !== true) {
  throw new Error(`routine note must render: display=${sentToMain[0].message.display}`);
}
writeFileSync(`${home}/state/delivered-routine-note`, sentToMain[0].message.content);
const captainEntries = mainEntries.filter((entry) => entry.customType === "fm-branch-visible-outcome");
if (captainEntries.length !== 1) throw new Error(`captain delivery count was ${captainEntries.length}, not 1`);
const captainRecord = captainEntries[0].data;
if (captainRecord.version !== 1 || captainRecord.seq !== 3 || captainRecord.task !== "task-9" || captainRecord.verdict !== "captain") {
  throw new Error(`captain entry lost its identity: ${JSON.stringify(captainRecord)}`);
}
if (captainRecord.summary !== "PR https://example.com/pr/9 checks green, ready for review") {
  throw new Error(`captain entry changed the exact summary: ${captainRecord.summary}`);
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
if (!entryRenderers.has("fm-branch-visible-outcome")) throw new Error("visible captain-outcome renderer missing");
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
const captainRendered = entryRenderers.get("fm-branch-visible-outcome")(
  captainEntries[0],
  { expanded: false },
  renderTheme,
);
if (captainRendered.text !== "⚓ [seq 3] task-9: PR https://example.com/pr/9 checks green, ready for review") {
  throw new Error(`captain renderer changed the exact visible outcome: ${captainRendered.text}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "branch dispatch, prefix contract, and two-stage filter must hold: $out"
  case "$out" in
    CACHE_KEY=fm-branch-*) ;;
    *) fail "cache key line missing from driver output: $out" ;;
  esac
  pass "branch owns accepted wakes with a stable prefix and deterministic verdict-driven delivery"

  # The processing request must identify itself to main's model through the
  # real protocol executable: it is typed branch-outcome input whose body names
  # the sequence/task anchor, the acknowledgement tool, and the fact that
  # nothing but that acknowledgement closes it. Routine notes remain
  # plain rendered text rather than typed operational input.
  local kind body
  kind=$(./bin/fm-operational-input.sh kind < "$home/state/delivered-processing-request") \
    || fail "the processing request reaches main's model as unattributed text"
  [ "$kind" = branch-outcome ] || fail "the processing request was delivered as kind '$kind', not branch-outcome"
  body=$(./bin/fm-operational-input.sh body < "$home/state/delivered-processing-request") \
    || fail "the processing request envelope carries no readable body"
  case "$body" in
    *"delivered automatically by the supervision branch."*"It was not typed by the captain."*"call fm_branch_outcomes with exactly those sequences"*"[seq 3] task=task-9"*) ;;
    *) fail "the processing request body lost its self-description or outcome identity: $body" ;;
  esac
  case "$body" in
    *"PR https://example.com/pr/9 checks green, ready for review"*) fail "the processing request redundantly loaded the exact summary already held by the visible anchor: $body" ;;
  esac
  case "$body" in
    *"do not re-drain, re-run, or acknowledge the wake."*"call fm_branch_processed with through=3 exactly once."*"never counts as processing."*) ;;
    *) fail "the processing request body lost the event-ownership boundary or the sequence-bound acknowledgement duty: $body" ;;
  esac
  if ./bin/fm-operational-input.sh kind < "$home/state/delivered-routine-note" >/dev/null 2>&1; then
    fail "routine note must stay plain rendered text, not typed operational input"
  fi
  pass "a captain outcome reaches main's model as one typed, sequence-keyed processing request while routine notes stay plain"
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
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, sentToMain, mainEntries, outcomeScript, mainTools, home, realRoot }; })()`);
const { fire, dispatch, settle, sentToMain, mainEntries, outcomeScript, mainTools, home, realRoot } = globalThis.__t;
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
  if (!verdictDescription.includes("Verdict: routine or captain") ||
      !verdictDescription.includes("one owner of the rule") ||
      verdictDescription.includes("unconditionally")) {
    throw new Error(`branch provider received conflicting verdict semantics: ${verdictDescription}`);
  }
  const result = await report.execute(
    `resource-result-${fleetOperations.length}`,
    {
      task: "branch-driver",
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
await fire("before_agent_start", { prompt: operational.stdout }, mainCtx);
entries.push({ type: "message", message: { role: "user", content: operational.stdout } });
const unsolicitedPrompt = "Please keep responses concise while monitoring the fleet.";
await fire("before_agent_start", { prompt: unsolicitedPrompt }, mainCtx);
entries.push({ type: "message", message: { role: "user", content: unsolicitedPrompt } });
await fire("agent_start", {}, mainCtx);
await fire("agent_end", {}, mainCtx);
const legacyOperational = "⁣FIRSTMATE_OP: give me a fresh system-resource report.";
await fire("before_agent_start", { prompt: legacyOperational }, mainCtx);
entries.push({ type: "message", message: { role: "user", content: legacyOperational } });
await fire("agent_start", {}, mainCtx);
const unsolicited = dispatch("signal: healthy resource result");
if (!unsolicited.accepted) throw new Error("branch did not accept the unsolicited result");
await settle(() => fleetOperations.length === 2, "unsolicited result acknowledgement");
if (sentToMain.length !== 1 || sentToMain[0].options.triggerTurn) {
  throw new Error(`unsolicited healthy result opened a main turn: ${JSON.stringify(sentToMain)}`);
}
const sailboat = sentToMain[0];
if (sailboat.message.display !== true || !sailboat.message.content.startsWith("⛵ branch-driver:")) {
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
  await fire("before_agent_start", { prompt: content }, mainCtx);
  // Pi persists this only after every before_agent_start handler has returned.
  entries.push({ type: "message", message: { role: "user", content } });
  await fire("agent_start", {}, mainCtx);
  const requested = dispatch("signal: healthy resource result");
  if (!requested.accepted) throw new Error(`branch did not accept requested result ${index}`);
  await settle(() => fleetOperations.length === 4 + (index * 2), `requested result ${index} acknowledgement`);
  const deliveredRequestMirror = globalThis.__fmSessions[0].ops
    .filter((op) => op.kind === "custom" && op.message.customType === "fm-main-mirror")
    .at(-1)?.message.content;
  if (deliveredRequestMirror !== `[captain] ${content}`) {
    throw new Error(`pre-turn-end mirror changed long captain request ${index}`);
  }
  const visible = entries.filter((entry) => entry.customType === "fm-branch-visible-outcome");
  if (visible.length !== index + 1 || visible.at(-1).data.summary !== "healthy resource report: CPU 12%, memory 41%") {
    throw new Error(`requested result ${index} did not persist one exact visible outcome: ${JSON.stringify(visible)}`);
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
let processingRequests = sentToMain.filter((sent) => sent.message.customType === "fm-branch-process");
if (sentToMain.length !== 1 + processingRequests.length) {
  throw new Error(`captain results entered model delivery as unkeyed messages: ${JSON.stringify(sentToMain)}`);
}
if (processingRequests.length !== 1 || processingRequests[0].options.triggerTurn !== true) {
  throw new Error(`captain results re-sent while the first keyed request was pending: ${JSON.stringify(processingRequests)}`);
}
await fire("agent_settled", {}, mainCtx);
processingRequests = sentToMain.filter((sent) => sent.message.customType === "fm-branch-process");
if (processingRequests.length !== 2 || processingRequests[1].options.triggerTurn !== true) {
  throw new Error(`the widened captain sequence set did not open one keyed turn at the run boundary: ${JSON.stringify(processingRequests)}`);
}
for (let seq = 2; seq <= 5; seq += 1) {
  if (!processingRequests[1].message.content.includes(`[seq ${seq}] task=branch-driver`)) {
    throw new Error(`the widened processing request lost seq ${seq}: ${processingRequests[1].message.content}`);
  }
}
if (processingRequests[1].message.content.includes("healthy resource report: CPU 12%, memory 41%")) {
  throw new Error(`the widened processing request reloaded repeated summary content: ${processingRequests[1].message.content}`);
}
if (!processingRequests[1].message.content.includes("through=5")) {
  throw new Error(`the widened processing request lost its highest acknowledgement key: ${processingRequests[1].message.content}`);
}
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

test_captain_outcome_is_exactly_once_across_crash_reload_and_unrelated_response() {
  local repo home out status
  repo="$TMP_ROOT/visible-outcome-recovery-root"
  home="$TMP_ROOT/visible-outcome-recovery-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, sentToMain, mainEntries, entryRenderers, outcomeScript, defaultSessionCtx }; })()`);
const { fire, sentToMain, mainEntries, entryRenderers, outcomeScript, defaultSessionCtx } = globalThis.__t;

// Incident topology: compaction leaves stale framing, then the immediately
// preceding assistant repeats an unrelated retry update. Neither can satisfy
// or alter a completed branch outcome because no model response is delivery.
mainEntries.push(
  { type: "compaction", summary: "Last user request: retry Gmail intake." },
  { type: "message", message: { role: "assistant", content: "The retry safe-stopped; diagnosis is underway." } },
);
const summary1 = "Completed diagnosis: the cursor trusted an unrelated assistant response.";
const seq1 = Number(outcomeScript(["append", "--task", "email-intake", "--verdict", "captain", "--summary", summary1]));
// Crash boundary: appendEntry persisted, but mark-read did not happen.
mainEntries.push({
  type: "custom",
  customType: "fm-branch-visible-outcome",
  data: { version: 1, seq: seq1, task: "email-intake", verdict: "captain", summary: summary1, silent: false },
});
await fire("session_start", {}, defaultSessionCtx);
if (outcomeScript(["unread"]) !== "") throw new Error("reload did not advance the cursor after finding the persisted entry");

const summary2 = "Second completed request stayed exact while main was streaming.";
const seq2 = Number(outcomeScript(["append", "--task", "task-busy", "--verdict", "captain", "--summary", summary2]));
await fire("agent_start", {});
await fire("session_shutdown", {});
await fire("session_start", {}, defaultSessionCtx);
await fire("agent_end", {});
const visible = mainEntries.filter((entry) => entry.customType === "fm-branch-visible-outcome");
if (visible.length !== 2 || visible[0].data.seq !== seq1 || visible[1].data.seq !== seq2) {
  throw new Error(`reload recovery was not sequence-keyed and exactly once: ${JSON.stringify(visible)}`);
}
if (visible[0].data.summary !== summary1 || visible[1].data.summary !== summary2) {
  throw new Error(`visible delivery changed an exact stored summary: ${JSON.stringify(visible)}`);
}
if (sentToMain.some((sent) => sent.message.customType !== "fm-branch-process")) {
  throw new Error(`captain recovery queued an unkeyed model message: ${JSON.stringify(sentToMain)}`);
}
// Recovery re-presents every still-unprocessed sequence in one keyed request.
const recovered = sentToMain.at(-1)?.message.content ?? "";
if (!recovered.includes(`[seq ${seq1}] task=email-intake`) || !recovered.includes(`[seq ${seq2}] task=task-busy`)) {
  throw new Error(`reload did not re-present the unprocessed outcomes for processing: ${recovered}`);
}
if (recovered.includes(summary1) || recovered.includes(summary2)) {
  throw new Error(`reload redundantly hydrated exact visible summaries: ${recovered}`);
}

// A second reload sees the cursor and must stay idempotent.
await fire("session_shutdown", {});
await fire("session_start", {}, defaultSessionCtx);
if (mainEntries.filter((entry) => entry.customType === "fm-branch-visible-outcome").length !== 2) {
  throw new Error("a second reload duplicated a visible captain outcome");
}
const rendered = entryRenderers.get("fm-branch-visible-outcome")(
  visible[0],
  { expanded: false },
  { fg: (_color, text) => text },
);
if (rendered.text !== `⚓ [seq ${seq1}] email-intake: ${summary1}`) {
  throw new Error(`renderer did not preserve exact outcome text: ${rendered.text}`);
}

// A reused sequence with different content cannot be treated as delivery.
const seq3 = Number(outcomeScript(["append", "--task", "task-conflict", "--verdict", "captain", "--summary", "authoritative summary"]));
mainEntries.push({
  type: "custom",
  customType: "fm-branch-visible-outcome",
  data: { version: 1, seq: seq3, task: "task-conflict", verdict: "captain", summary: "different summary", silent: false },
});
await fire("session_shutdown", {});
await fire("session_start", {}, defaultSessionCtx);
if (!outcomeScript(["unread"]).includes('"seq":3')) {
  throw new Error("conflicting sequence content advanced the cursor instead of failing closed");
}
if (mainEntries.filter((entry) => entry.customType === "fm-branch-visible-outcome" && entry.data.seq === seq3).length !== 1) {
  throw new Error("conflicting sequence content caused another entry to be appended");
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "captain outcome recovery must be deterministic across crash, reload, and stale assistant context: $out"
  pass "captain outcomes are exact and exactly once across crash, reload, busy main, compaction, and an unrelated assistant response"
}

test_captain_outcome_processing_turn_is_sequence_keyed_and_re_presented() {
  local repo home out status
  repo="$TMP_ROOT/processing-turn-root"
  home="$TMP_ROOT/processing-turn-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, sentToMain, mainEntries, mainTools, outcomeScript, defaultSessionCtx, home, bus }; })()`);
const { fire, dispatch, settle, sentToMain, mainEntries, mainTools, outcomeScript, defaultSessionCtx, home, bus } = globalThis.__t;
import { readFileSync, writeFileSync } from "node:fs";

const requests = () => sentToMain.filter((sent) => sent.message.customType === "fm-branch-process");
const unprocessedSeqs = () => outcomeScript(["unprocessed"]).split("\n").filter(Boolean).map((line) => JSON.parse(line).seq);
const runOf = async (fn) => { await fire("agent_start", {}); await fn?.(); await fire("agent_end", {}); await fire("agent_settled", {}); };

// A home upgraded with outcomes that were delivered before the processed
// marker existed treats them as processed once, at the first reconciliation:
// its history is not re-presented to the captain.
const legacy = Number(outcomeScript(["append", "--task", "legacy", "--verdict", "captain", "--summary", "delivered before processing existed"]));
outcomeScript(["mark-read", "--through", String(legacy)]);
mainEntries.push({ type: "custom", customType: "fm-branch-visible-outcome", data: { version: 1, seq: legacy, task: "legacy", verdict: "captain", summary: "delivered before processing existed", silent: false } });
await fire("session_start", {}, defaultSessionCtx);
if (requests().length !== 0) throw new Error(`the upgrade migration re-presented already-delivered history: ${JSON.stringify(sentToMain)}`);
if (readFileSync(`${home}/state/.branch-outcomes-processed`, "utf8").trim() !== String(legacy)) {
  throw new Error("the processed marker was not initialized at the read cursor on first reconciliation");
}

// A routine outcome never opens a processing turn. Keep the scripted prompt
// open through its report, as the real AgentSession does for tool execution.
let finishRoutinePrompt;
globalThis.__fmOnBranchPrompt = () => new Promise((resolve) => { finishRoutinePrompt = resolve; });
const routineOffer = dispatch("signal: routine wake");
if (!routineOffer.accepted) throw new Error("branch refused the routine wake");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "routine branch prompt");
const session = globalThis.__fmSessions[0];
const report = session.options.customTools.find((tool) => tool.name === "fm_branch_report");
await report.execute("routine", { task: "branch-driver", verdict: "routine", summary: "worker healthy" }, undefined, undefined, {});
finishRoutinePrompt();
// The reports below are made outside any wake prompt: wait for the wake to
// settle so its task scope has been cleared.
await routineOffer.settlement;
globalThis.__fmOnBranchPrompt = undefined;
const routineSeq = JSON.parse(outcomeScript(["list", "--recent", "1"])).seq;
await runOf();
if (requests().length !== 0) throw new Error("a routine outcome opened a processing turn");

// An actionable (captain) outcome: exactly one keyed request while main is idle.
const decision = "worker needs a scope decision: option A skip the stage, option B re-implement it";
const first = await report.execute("captain-1", { task: "task-d", verdict: "captain", summary: decision }, undefined, undefined, {});
if (first.isError) throw new Error(`captain report failed: ${JSON.stringify(first)}`);
const seq = JSON.parse(outcomeScript(["list", "--recent", "1"])).seq;
if (requests().length !== 1) throw new Error(`captain delivery opened ${requests().length} requests, not 1`);
const request = requests()[0];
if (request.options.triggerTurn !== true || request.options.deliverAs !== "followUp" || request.message.display !== false) {
  throw new Error(`the processing request must be one hidden follow-up turn: ${JSON.stringify(request)}`);
}
if (!request.message.content.includes(`[seq ${seq}] task=task-d`) || request.message.content.includes(decision)) throw new Error(`the request did not preserve identity-only projection: ${request.message.content}`);
if (JSON.stringify(unprocessedSeqs()) !== JSON.stringify([seq])) throw new Error(`delivery did not leave seq ${seq} unprocessed: ${unprocessedSeqs()}`);

// Case A (timeline report 2026-08-31): the turn returns an EMPTY assistant
// message. The processed marker must not move, and the same sequence is
// presented again at the run boundary.
await runOf(() => mainEntries.push({ type: "message", message: { role: "assistant", content: [] } }));
if (JSON.stringify(unprocessedSeqs()) !== JSON.stringify([seq])) throw new Error("an empty answer advanced the processed marker");
if (requests().length !== 2) throw new Error(`an empty answer did not re-present the outcome: ${requests().length} requests`);
if (requests()[1].options.triggerTurn !== true) throw new Error("the first re-presentation must open its own turn");
if (!requests()[1].message.content.includes(`[seq ${seq}] task=task-d`) || requests()[1].message.content.includes(decision)) throw new Error("the re-presentation changed the identity-only outcome reference");

// Case B: the turn repeats an unrelated prior answer. Same result: the marker
// holds, and the request is presented again - now riding the captain's next
// prompt because the triggered budget for this sequence set is spent.
await runOf(() => mainEntries.push({ type: "message", message: { role: "assistant", content: "The retry safe-stopped; diagnosis is underway." } }));
if (JSON.stringify(unprocessedSeqs()) !== JSON.stringify([seq])) throw new Error("an unrelated answer advanced the processed marker");
if (requests().length !== 3) throw new Error(`an unrelated answer did not re-present the outcome: ${requests().length} requests`);
if (requests()[2].options.deliverAs !== "nextTurn" || requests()[2].options.triggerTurn) {
  throw new Error(`after the triggered budget the request must ride the next prompt: ${JSON.stringify(requests()[2].options)}`);
}
// A quiet settle with the copy still queued does not queue a duplicate.
await fire("agent_settled", {});
if (requests().length !== 3) throw new Error("a duplicate next-turn copy was queued");
// The captain's next prompt consumes that copy; settling unacknowledged queues one more.
await runOf(() => mainEntries.push({ type: "message", message: { role: "assistant", content: "Captain, shipshape." } }));
if (requests().length !== 4 || requests()[3].options.deliverAs !== "nextTurn") throw new Error("the outcome stopped being re-presented on later prompts");
if (JSON.stringify(unprocessedSeqs()) !== JSON.stringify([seq])) throw new Error("a paraphrase advanced the processed marker");

// A session replacement re-presents with a fresh triggered budget.
await fire("session_shutdown", {});
await fire("session_start", {}, defaultSessionCtx);
if (requests().length !== 5 || requests()[4].options.triggerTurn !== true) throw new Error("session start did not re-present the unprocessed outcome with its own turn");
if (mainEntries.filter((entry) => entry.customType === "fm-branch-visible-outcome" && entry.data.seq === seq).length !== 1) {
  throw new Error("re-presentation duplicated the visible entry");
}
// Simulate a compacted/recovered main context that no longer contains the
// visible anchor. The identity-only request must recover the exact row from the
// durable store and cannot treat the missing anchor as witnessed evidence.
const visibleIndex = mainEntries.findIndex((entry) => entry.customType === "fm-branch-visible-outcome" && entry.data.seq === seq);
mainEntries.splice(visibleIndex, 1);

// Only the sequence-bound acknowledgement closes it.
const nativeTools = new Map();
const messageTypes = new Set();
bus.emit("firstmate:native-tools", {
  register: (tool) => nativeTools.set(tool.name, tool),
  allowMessageType: (type) => messageTypes.add(type),
});
if ([...nativeTools.keys()].sort().join(",") !== "fm_branch_outcomes,fm_branch_processed,fm_task_continuation") throw new Error("native discovery exposed unrelated tools");
for (const tool of mainTools) {
  if (nativeTools.get(tool.name)?.execute !== tool.execute) throw new Error("native controls lost the original guards");
}
if ([...messageTypes].sort().join(",") !== "firstmate-sessionstart-nudge,fm-branch-merge,fm-branch-process,fm-heartbeat-request,fm-stow-request,fm-task-continuation") throw new Error("operational message allowlist changed");
const processed = nativeTools.get("fm_branch_processed");
if (!processed) throw new Error("main did not receive its acknowledgement tool");
const routineAck = await processed.execute("ack-routine", { through: routineSeq }, undefined, undefined, {});
if (!routineAck.isError || !routineAck.content.some((item) => item.type === "text" && item.text.includes("not an unprocessed captain outcome"))) {
  throw new Error(`a routine-sequence acknowledgement was not clearly refused: ${JSON.stringify(routineAck)}`);
}
if (JSON.stringify(unprocessedSeqs()) !== JSON.stringify([seq])) throw new Error("a routine-sequence acknowledgement closed the open captain sequence");
const tooFar = await processed.execute("ack-too-far", { through: seq + 100 }, undefined, undefined, {});
if (!tooFar.isError) throw new Error("an acknowledgement beyond the read cursor was accepted");
if (JSON.stringify(unprocessedSeqs()) !== JSON.stringify([seq])) throw new Error("a refused acknowledgement moved the marker");
const unseen = await processed.execute("ack-unseen", { through: seq }, undefined, undefined, {});
if (!unseen.isError || !unseen.content.some((item) => item.type === "text" && item.text.includes("load exact durable outcome evidence first"))) {
  throw new Error(`an unseen compacted outcome could be acknowledged: ${JSON.stringify(unseen)}`);
}
if (JSON.stringify(unprocessedSeqs()) !== JSON.stringify([seq])) throw new Error("an unseen-evidence refusal moved the marker");
const outcomes = nativeTools.get("fm_branch_outcomes");
const exact = await outcomes.execute("read-exact", { sequences: String(seq) }, undefined, undefined, {});
const exactText = exact.content.map((item) => item.text ?? "").join("\n");
if (exact.isError || !exactText.includes(`"seq":${seq}`) || !exactText.includes(decision)) {
  throw new Error(`exact durable outcome recovery failed after anchor compaction: ${JSON.stringify(exact)}`);
}
await fire("session_compact", {});
const compactedAck = await processed.execute("ack-after-compact", { through: seq }, undefined, undefined, {});
if (!compactedAck.isError || !compactedAck.content.some((item) => item.type === "text" && item.text.includes("load exact durable outcome evidence first"))) {
  throw new Error(`compaction preserved stale acknowledgement evidence: ${JSON.stringify(compactedAck)}`);
}
if (JSON.stringify(unprocessedSeqs()) !== JSON.stringify([seq])) throw new Error("a post-compaction evidence refusal moved the marker");
const reloaded = await outcomes.execute("read-exact-after-compact", { sequences: String(seq) }, undefined, undefined, {});
const reloadedText = reloaded.content.map((item) => item.text ?? "").join("\n");
if (reloaded.isError || !reloadedText.includes(`"seq":${seq}`) || !reloadedText.includes(decision)) {
  throw new Error(`exact durable outcome reload failed after compaction: ${JSON.stringify(reloaded)}`);
}
const ack = await processed.execute("ack", { through: seq }, undefined, undefined, {});
if (ack.isError) throw new Error(`acknowledgement failed: ${JSON.stringify(ack)}`);
if (unprocessedSeqs().length !== 0) throw new Error("the acknowledgement did not close the sequence");
const before = requests().length;
await runOf();
if (requests().length !== before) throw new Error("an acknowledged outcome was presented again");

// Two newer captain outcomes in a row: the second does not overlap a request
// still pending its run boundary, and the widened request appears at that
// boundary. A partial acknowledgement keeps the newer sequence open.
// The replacement session rebuilt the branch, so its report tool is the new
// session's; the old session's tool is generation-refused by design.
const stale = await report.execute("captain-stale", { task: "task-e", verdict: "captain", summary: "must be refused" }, undefined, undefined, {});
if (!stale.isError) throw new Error("a replaced branch session's report tool was accepted");
let finishReplacementPrompt;
globalThis.__fmOnBranchPrompt = () => new Promise((resolve) => { finishReplacementPrompt = resolve; });
const replacementOffer = dispatch("signal: after replacement");
if (!replacementOffer.accepted) throw new Error("branch refused a wake after the replacement");
await settle(() => (globalThis.__fmSessions ?? []).length === 2, "replacement branch session");
const report2 = globalThis.__fmSessions[1].options.customTools.find((tool) => tool.name === "fm_branch_report");
const beforePair = requests().length;
const second = await report2.execute("captain-2", { task: "branch-driver", verdict: "captain", summary: "PR https://example.com/pr/e is ready for review" }, undefined, undefined, {});
if (second.isError) throw new Error(`second captain report failed: ${JSON.stringify(second)}`);
finishReplacementPrompt();
// The next report is made outside the wake prompt: wait for the wake to
// settle so its task scope has been cleared.
await replacementOffer.settlement;
globalThis.__fmOnBranchPrompt = undefined;
const seqE = seq + 1;
const seqF = seq + 2;
if (requests().length !== beforePair + 1 || !requests().at(-1).message.content.includes(`[seq ${seqE}] task=branch-driver`)) {
  throw new Error("the first newer captain outcome did not open its processing request");
}
const third = await report2.execute("captain-3", { task: "task-f", verdict: "captain", summary: "worker blocked on a missing credential" }, undefined, undefined, {});
if (third.isError) throw new Error(`third captain report failed: ${JSON.stringify(third)}`);
if (requests().length !== beforePair + 1) throw new Error("a widened sequence re-sent while the earlier request was pending");
const unlisted = await processed.execute("ack-unlisted", { through: seqF }, undefined, undefined, {});
if (!unlisted.isError || !unlisted.content.some((item) => item.type === "text" && item.text.includes("not listed in the active processing request"))) {
  throw new Error(`an unlisted newer sequence was not clearly refused: ${JSON.stringify(unlisted)}`);
}
if (JSON.stringify(unprocessedSeqs()) !== JSON.stringify([seqE, seqF])) {
  throw new Error(`an unlisted acknowledgement closed outcomes: ${unprocessedSeqs()}`);
}
await runOf();
if (requests().length !== beforePair + 2) throw new Error("the widened sequence was not presented at the run boundary");
const latest = requests().at(-1).message.content;
if (!latest.includes(`[seq ${seqE}] task=branch-driver`) || !latest.includes(`[seq ${seqF}] task=task-f`) || !latest.includes(`through=${seqF}`)) {
  throw new Error(`the widened request did not cover every unprocessed sequence with the highest key: ${latest}`);
}
const exactPair = await outcomes.execute("read-exact-pair", { sequences: `${seqE},${seqF}` }, undefined, undefined, {});
const exactPairText = exactPair.content.map((item) => item.text ?? "").join("\n");
if (exactPair.isError || !exactPairText.includes(`"seq":${seqE}`) || !exactPairText.includes(`"seq":${seqF}`)
    || !exactPairText.includes("PR https://example.com/pr/e is ready for review")
    || !exactPairText.includes("worker blocked on a missing credential")) {
  throw new Error(`exact multi-outcome recovery failed: ${JSON.stringify(exactPair)}`);
}
const beforePairRepeat = requests().length;
await runOf();
if (requests().length !== beforePairRepeat + 1 || requests().at(-1).options.triggerTurn !== true) {
  throw new Error("the second presentation of the widened sequence set did not open its own turn");
}
const partial = await processed.execute("ack-partial", { through: seqE }, undefined, undefined, {});
if (partial.isError) throw new Error(`partial acknowledgement failed: ${JSON.stringify(partial)}`);
if (JSON.stringify(unprocessedSeqs()) !== JSON.stringify([seqF])) throw new Error(`a partial acknowledgement did not keep the newer sequence open: ${unprocessedSeqs()}`);
const beforeF = requests().length;
await runOf();
if (
  requests().length !== beforeF + 1 ||
  requests().at(-1).options.triggerTurn !== true ||
  requests().at(-1).options.deliverAs !== "followUp" ||
  !requests().at(-1).message.content.includes(`[seq ${seqF}] task=task-f`)
) {
  throw new Error("the changed remaining sequence set did not restart its triggered presentation budget");
}
const done = await processed.execute("ack-final", { through: seqF }, undefined, undefined, {});
if (done.isError || unprocessedSeqs().length !== 0) throw new Error("the final acknowledgement did not close the newer sequence");

// A session that does not own the fleet lock cannot acknowledge anything.
writeFileSync(`${home}/state/.lock`, "1\n");
const foreign = await processed.execute("ack-foreign", { through: seqF }, undefined, undefined, {});
if (!foreign.isError) throw new Error("a session without lock ownership acknowledged an outcome");
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "captain outcomes must be processed through a sequence-bound acknowledgement and re-presented until then: $out"
  pass "a captain outcome opens one sequence-keyed processing turn, survives empty and unrelated answers, is re-presented at run end and session start, and closes only on its acknowledgement"
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
  cp "$ROOT/bin/fm-branch-outcome.sh" "$ROOT/bin/fm-classify-lib.sh" \
    "$ROOT/bin/fm-lease.sh" "$ROOT/bin/fm-lease-lib.sh" "$ROOT/bin/fm-timeout-lib.sh" \
    "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-wake-grant.sh" "$broken/bin/"
  cat > "$broken/bin/fm-branch-prompt.sh" <<'SH'
#!/usr/bin/env bash
echo "synthetic generator failure" >&2
exit 1
SH
  chmod +x "$broken/bin/fm-branch-prompt.sh"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { dispatch, fire, settle, home, sentToMain, mainEntries, defaultSessionCtx }; })()`);
const { dispatch, fire, settle, home, sentToMain, mainEntries, defaultSessionCtx } = globalThis.__t;
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";

// Default-on: with no config/pi-supervision-branch grant file present at
// all (this driver never writes one), a task-scoped wake is still accepted
// and activation still runs.
if (existsSync(`${home}/config/pi-supervision-branch`)) {
  throw new Error("test fixture unexpectedly wrote a grant file");
}
await fire("session_start", {}, defaultSessionCtx);
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
const captainEntries = mainEntries.filter((entry) => entry.customType === "fm-branch-visible-outcome");
if (captainEntries.length !== 1 || captainEntries[0].data.summary !== "task-2 has been stuck for an hour") {
  throw new Error(`captain-worthy heartbeat finding was not persisted visibly: ${JSON.stringify(captainEntries)}`);
}
if (sentToMain.some((sent) => sent.options.triggerTurn && sent.message.customType !== "fm-branch-process")) {
  throw new Error("heartbeat outcome delivery opened an unkeyed model turn");
}
if (!sentToMain.some((sent) => sent.message.customType === "fm-branch-process" && sent.message.content.includes("task=fleet") && !sent.message.content.includes("task-2 has been stuck for an hour"))) {
  throw new Error("a captain-worthy heartbeat finding did not open its identity-only keyed processing turn");
}

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

// A branch that cannot come up rejects the accepted offer's settlement so the
// watcher retains delivery ownership and can route the durable wake to main.
// Later wakes are no longer accepted and therefore take that same watcher path
// directly (no wake is ever lost or independently delivered twice).
const firstOffer = dispatch("signal: first wake");
if (!firstOffer.accepted) throw new Error("first offer was not accepted");
const firstFailure = await firstOffer.settlement.then(
  () => null,
  (error) => error,
);
if (!(firstFailure instanceof Error) || !firstFailure.message.includes("synthetic generator failure")) {
  throw new Error(`branch settlement did not expose the startup failure: ${String(firstFailure)}`);
}
if (mainUserMessages.length !== 0) throw new Error("branch bypassed watcher-owned fallback delivery");
if (dispatch("signal: second wake").accepted) throw new Error("broken branch kept accepting wakes");
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "broken-branch settlement must return delivery ownership to the watcher: $out"
  pass "branch default-on eligibility (task-scoped, heartbeat, afk) binds and a broken branch rejects to watcher fallback"
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

await fire("session_start", {});
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

# The report tool refuses a task the wake being handled never named: the
# refused-ack loop's ghost reports were typed from memory about a task whose
# records teardown had already removed, while the prompt was a stale row for
# another pane. A signal or stale wake may report only the tasks its rows
# resolve to, with fleet refused too; a heartbeat review is unscoped and
# refuses nothing by task id. The wake's own task still goes through, and
# nothing refused ever reaches the durable store.
test_branch_report_refuses_a_task_the_wake_did_not_name() {
  local repo home out status
  repo="$TMP_ROOT/ghost-report-root"
  home="$TMP_ROOT/ghost-report-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { dispatch, fire, home, settle, approvedProject, defaultSessionCtx }; })()`);
const { dispatch, fire, home, settle, approvedProject, defaultSessionCtx } = globalThis.__t;
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { pathToFileURL } from "node:url";

// A second live task the wake does not name, plus the memory of a task whose
// records are already gone.
writeFileSync(`${home}/state/other-task.meta`, `project=${approvedProject}\nwindow=default:wX:p1\n`);
await fire("session_start", {}, defaultSessionCtx);

let finish;
globalThis.__fmOnBranchPrompt = () => new Promise((resolve) => { finish = resolve; });
if (!dispatch("signal: task-local wake").accepted) throw new Error("branch refused the task-local wake");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "task-local branch prompt");
const session = globalThis.__fmSessions[globalThis.__fmSessions.length - 1];
const report = session.options.customTools.find((tool) => tool.name === "fm_branch_report");
const ghost = await report.execute("ghost", { task: "other-task", verdict: "captain", summary: "PR ready to merge" }, undefined, undefined, {});
if (!ghost.isError || !ghost.content[0].text.includes("names branch-driver, not other-task")) {
  throw new Error(`a report for a live task the wake never named was not refused: ${JSON.stringify(ghost)}`);
}
const gone = await report.execute("gone", { task: "retired-task", verdict: "captain", summary: "PR ready to merge" }, undefined, undefined, {});
if (!gone.isError) throw new Error(`a report for a task with no record was not refused: ${JSON.stringify(gone)}`);
const fleet = await report.execute("fleet", { task: "fleet", verdict: "routine", summary: "fleet-wide note" }, undefined, undefined, {});
if (!fleet.isError || !fleet.content[0].text.includes("never fleet")) {
  throw new Error(`a fleet-wide report was not refused during a task-local wake: ${JSON.stringify(fleet)}`);
}
const named = await report.execute("named", { task: "branch-driver", verdict: "routine", summary: "worker healthy" }, undefined, undefined, {});
if (named.isError) throw new Error(`the wake's own task was refused: ${JSON.stringify(named)}`);
finish();
await settle(() => !existsSync(`${home}/state/.branch-eligible-rows`), "task-local grant release");

// A heartbeat review is not scoped by task: it may report any task id, a
// task whose records are already gone, and fleet.
globalThis.__fmOnBranchPrompt = () => new Promise((resolve) => { finish = resolve; });
if (!dispatch("heartbeat", [], true, true).accepted) throw new Error("branch refused the heartbeat");
await settle(() => (globalThis.__fmPrompts ?? []).length === 2, "heartbeat branch prompt");
const heartbeatSession = globalThis.__fmSessions[globalThis.__fmSessions.length - 1];
const heartbeatReport = heartbeatSession.options.customTools.find((tool) => tool.name === "fm_branch_report");
const live = await heartbeatReport.execute("live", { task: "other-task", verdict: "routine", summary: "worker healthy" }, undefined, undefined, {});
if (live.isError) throw new Error(`a heartbeat report for a live task was refused: ${JSON.stringify(live)}`);
const goneInReview = await heartbeatReport.execute("gone-in-review", { task: "retired-task", verdict: "captain", summary: "PR merged and cleaned up" }, undefined, undefined, {});
if (goneInReview.isError) throw new Error(`a heartbeat report for a task with no record was refused: ${JSON.stringify(goneInReview)}`);
const fleetInReview = await heartbeatReport.execute("fleet-in-review", { task: "fleet", verdict: "routine", summary: "fleet-wide note" }, undefined, undefined, {});
if (fleetInReview.isError) throw new Error(`a fleet-wide report was refused during a heartbeat review: ${JSON.stringify(fleetInReview)}`);
finish();

const stored = readFileSync(`${home}/state/branch-outcomes.jsonl`, "utf8").trim().split("\n").map((line) => JSON.parse(line).task);
if (JSON.stringify(stored) !== JSON.stringify(["branch-driver", "other-task", "retired-task", "fleet"])) {
  throw new Error(`refused reports reached the durable store: ${JSON.stringify(stored)}`);
}

// The classification owner names the tasks behind each eligible row: a
// signal row by its status-log key, a stale row by the endpoint a task's
// metadata records.
const lib = await import(pathToFileURL(`${dirname(process.env.PLUGIN)}/lib/fm-branch-dispatch.ts`).href);
writeFileSync(`${home}/state/.wake-queue`, [
  "1\t1\tsignal\tbranch-driver.status\tsignal: done",
  "2\t2\tstale\tdefault:wX:p1\tstale: default:wX:p1 (idle 378s)",
  "3\t3\tcheck\tmerge-poll\tcheck: merged",
].join("\n") + "\n");
const scope = lib.scopeForUnreadWake(`${home}/state`, false);
if (JSON.stringify([...scope.eligibleTasks].sort()) !== JSON.stringify(["branch-driver", "other-task"])) {
  throw new Error(`eligible rows resolved to the wrong tasks: ${JSON.stringify(scope)}`);
}
if (JSON.stringify(scope.eligibleSeqs) !== JSON.stringify(["1", "2"])) {
  throw new Error(`the main-owned check row leaked into the branch claim: ${JSON.stringify(scope)}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "the report tool must refuse tasks the wake never named: $out"
  pass "fm_branch_report refuses a task the wake did not name, fleet included, while a heartbeat is unscoped"
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

await fire("session_start", {});
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

# A needs-decision signal wakes main independently, but it must not veto an
# already accepted routine delivery at the branch's pre-drain recheck. The
# grant serializes the actors: branch owns only the routine row, while the
# decision row remains main-owned. If the prompted branch then fails, rejecting
# the settlement releases the grant so watcher fallback can replay both rows.
test_branch_predrain_needs_decision_keeps_routine_row_branch_eligible() {
  local repo home out status
  repo="$TMP_ROOT/predrain-needs-decision-root"
  home="$TMP_ROOT/predrain-needs-decision-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { bus, fire, home, makeOffer, realRoot }; })()`);
const { bus, fire, home, makeOffer, realRoot } = globalThis.__t;
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";

fire("session_start", {});
writeFileSync(
  `${home}/state/.wake-queue`,
  "1\t1\tsignal\tbranch-driver.status\tsignal: routine progress\n" +
    "2\t2\tsignal\tdecision-task.status\tneeds-decision: decision-task.status\n",
);
let releasePrompt;
globalThis.__fmPromptGate = new Promise((resolve) => { releasePrompt = resolve; });
const offer = makeOffer("signal: branch-driver.status");
bus.emit("fm-branch-supervision:dispatch", offer);
if (!offer.accepted) throw new Error("branch refused the routine offer before its mixed-queue recheck");
for (let i = 0; i < 250 && !globalThis.__fmPromptStarted; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (!globalThis.__fmPromptStarted) {
  throw new Error(`a co-present needs-decision row vetoed the accepted routine branch prompt: ${await Promise.race([offer.settlement.then(() => "settled", e => String(e)), Promise.resolve("still pending")])}`);
}
const snapshot = readFileSync(`${home}/state/.branch-eligible-rows`, "utf8").trim().split("\n");
if (!snapshot.includes("1") || snapshot.includes("2")) {
  throw new Error(`mixed queue granted the wrong rows to branch: ${snapshot}`);
}
releasePrompt();
const failure = await offer.settlement.then(() => null, (error) => error);
if (!(failure instanceof Error) || !failure.message.includes("produced no durable outcome")) {
  throw new Error(`accepted wake settled without delivery instead of rejecting to fallback: ${String(failure)}`);
}
if (existsSync(`${home}/state/.branch-eligible-rows`)) {
  throw new Error("failed branch prompt retained its routine-row grant");
}
const drain = spawnSync("bash", [`${realRoot}/bin/fm-wake-drain.sh`], {
  encoding: "utf8",
  env: { ...process.env, FM_HOME: home, FM_STATE_OVERRIDE: `${home}/state`, FM_ROOT_OVERRIDE: realRoot },
});
if (drain.status !== 0) throw new Error(`main fallback drain failed: ${drain.stderr}`);
if (!drain.stdout.includes("\t1\tsignal\tbranch-driver.status\t") ||
    !drain.stdout.includes("\t2\tsignal\tdecision-task.status\t")) {
  throw new Error(`fallback did not receive the released mixed queue: ${drain.stdout}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "a mixed needs-decision recheck must keep routine branch delivery live: $out"
  pass "a co-present needs-decision row neither vetoes nor falsely settles routine branch delivery"
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
await eval(`(async () => { ${prelude}; globalThis.__t = { dispatch, fire, home, realRoot, mainUserMessages }; })()`);
const { dispatch, fire, home, realRoot, mainUserMessages } = globalThis.__t;
const { spawnSync } = await import("node:child_process");
const { existsSync } = await import("node:fs");

await fire("session_start", {});
const offer = dispatch("signal: unacknowledged branch wake");
if (!offer.accepted) throw new Error("eligible wake was not accepted");
for (let i = 0; i < 250 && (globalThis.__fmPrompts ?? []).length === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if ((globalThis.__fmPrompts ?? []).length !== 1) throw new Error("branch prompt did not settle");
const failure = await offer.settlement.then(
  () => null,
  (error) => error,
);
if (!(failure instanceof Error) || !failure.message.includes("produced no durable outcome")) {
  throw new Error(`settled prompt did not reject delivery ownership: ${String(failure)}`);
}
if (mainUserMessages.length !== 0) throw new Error("branch bypassed watcher-owned fallback delivery");
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
  pass "a settled branch turn without a durable outcome falls back and releases its grant for main replay"
}

test_busy_branch_declines_an_unowned_ida_result() {
  local repo home out status
  repo="$TMP_ROOT/busy-ida-fallback-root"
  home="$TMP_ROOT/busy-ida-fallback-home"
  mkdir -p "$home/state/procevent-inbox" "$home/state/remote-tasks/ida-task" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { bus, dispatch, fire, home, makeOffer, settle }; })()`);
const { bus, dispatch, fire, home, makeOffer, settle } = globalThis.__t;
import { appendFileSync, chmodSync, readFileSync, writeFileSync } from "node:fs";

const privateWrite = (path, content) => {
  writeFileSync(path, content, { mode: 0o600 });
  chmodSync(path, 0o600);
};
const state = `${home}/state`;
const task = "ida-task";
const source = `ida-${task}`;
const marker = "firstmate:ida-task:0123456789abcdef";
privateWrite(`${state}/${task}.meta`,
  `kind=scout\nexecutor=remote-agent\nprovider=ida\ntask_type=research\nremote_state=${state}/remote-tasks/${task}\n`);
privateWrite(`${state}/remote-tasks/${task}/state.json`, JSON.stringify({
  schema: "fm-remote-agent-task-state.v1", task_id: task, executor: "remote-agent", provider: "ida",
  task_type: "research", phase: "terminal-success", revision: 2,
  instruction_file: `${home}/data/${task}/instructions.txt`,
  instruction_sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  outcome: "succeeded", error_class: null, waiter: "terminal", result_availability: "available",
  result_path: `${state}/remote-tasks/${task}/artifacts/observation.json`, report_path: `${home}/data/${task}/report.md`,
  provider_state: { region: "sg", identity: "user", session_marker: marker, session_id: "70001", task_id: "80001" },
}));
privateWrite(`${state}/procevent-inbox/${source}.7.adapter`, "ida\n");
privateWrite(`${state}/procevent-inbox/${source}.7.result`, JSON.stringify({
  schema: "fm-ida-observation.v1", task_id: task, provider: "ida", region: "sg", kind: "session",
  session_marker: marker, session_id: "70001", task_id_remote: "80001", provider_status: "completed",
  terminal: true, ambiguous: false, result_availability: "available", result_kind: "text",
  answer: "verified result", artifact_reference: null, error_class: null,
}));

await fire("session_start", {});
let releasePrompt;
globalThis.__fmPromptGate = new Promise((resolve) => { releasePrompt = resolve; });
const active = dispatch("signal: task-local wake");
if (!active.accepted) throw new Error("the setup wake was not accepted");
await settle(() => globalThis.__fmPromptStarted === true, "active branch prompt");
const activeRows = readFileSync(`${state}/.branch-eligible-rows`, "utf8").trim().split("\n");
if (!activeRows.includes("1")) throw new Error(`the active branch did not own its setup row: ${activeRows}`);

appendFileSync(`${state}/.wake-queue`, `1\t2\tcheck\tprocevent:${source}:7\tcheck: procevent ida ${source} 7\n`);
const idaOffer = makeOffer(`check: procevent ida ${source} 7`, [], false, true);
idaOffer.idaResultRows = ["2"];
bus.emit("fm-branch-supervision:dispatch", idaOffer);
if (idaOffer.accepted) throw new Error("a busy branch accepted an iDA row outside its live grant");
if (readFileSync(`${state}/.branch-eligible-rows`, "utf8").trim() !== "1") {
  throw new Error("the declined iDA result changed the active row grant");
}

releasePrompt();
const failure = await active.settlement.then(() => null, (error) => error);
if (!(failure instanceof Error) || !failure.message.includes("produced no durable outcome")) {
  throw new Error(`setup wake did not finish through its expected no-report fallback: ${String(failure)}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "a busy branch must leave an unowned iDA result on the main fallback path: $out"
  pass "a busy supervision branch declines an iDA result outside its live row grant"
}

test_post_construction_provider_error_falls_back_latches_and_recovers_on_cooldown() {
  local repo home out status
  repo="$TMP_ROOT/provider-error-root"
  home="$TMP_ROOT/provider-error-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { pi, makeOffer, dispatch, fire, settle, home, mainUserMessages, sentToMain }; })()`);
const { pi, makeOffer, dispatch, fire, settle, home, mainUserMessages, sentToMain } = globalThis.__t;
import { existsSync } from "node:fs";

let now = 1_000_000;
Date.now = () => now;
const entries = [];
await fire("session_start", {}, {
  sessionManager: {
    getSessionFile: () => `${home}/main.jsonl`,
    getEntries: () => entries,
  },
});
globalThis.__fmInitialBranchMessages = Array.from({ length: 100 }, (_, index) => ({
  role: index % 2 === 0 ? "user" : "assistant",
  content: `old context ${index}`,
  ...(index % 2 === 0 ? {} : { stopReason: "stop" }),
}));
let attempt = 0;
let releaseFailedProbe;
globalThis.__fmOnBranchPrompt = async ({ session }) => {
  attempt += 1;
  if (attempt === 1) {
    session.messages = [
      { role: "assistant", content: "compaction summary", stopReason: "stop" },
      ...Array.from({ length: 10 }, (_, index) => ({ role: "user", content: `retained ${index}` })),
    ];
  }
  if (attempt === 2 || attempt === 6 || attempt === 8) {
    const report = session.options.customTools.find((tool) => tool.name === "fm_branch_report");
    const summary = attempt === 2
      ? "healthy branch turn reset the provider-error streak"
      : attempt === 6
        ? "cooldown probe recovered the branch"
        : "post-recovery report proved the provider-error streak was clear";
    const recorded = await report.execute(
      `healthy-${attempt}`,
      { task: "branch-driver", verdict: "routine", summary },
      undefined,
      undefined,
      {},
    );
    if (recorded.isError) throw new Error(`healthy report failed: ${JSON.stringify(recorded)}`);
    session.messages.push({ role: "assistant", content: [], stopReason: "stop" });
    return;
  }
  if (attempt === 5) {
    const report = session.options.customTools.find((tool) => tool.name === "fm_branch_report");
    const recorded = await report.execute(
      "reported-before-provider-error",
      { task: "branch-driver", verdict: "routine", summary: "durable report preceded a failed continuation" },
      undefined,
      undefined,
      {},
    );
    if (recorded.isError) throw new Error(`pre-error report failed: ${JSON.stringify(recorded)}`);
    await new Promise((resolve) => { releaseFailedProbe = resolve; });
  }
  session.messages.push({
    role: "assistant",
    content: [],
    stopReason: "error",
    errorMessage: "429: Monthly usage limit reached",
  });
};

const first = dispatch("signal: c1 provider error");
if (!first.accepted) throw new Error("first provider-error wake was not accepted after branch construction");
const firstFailure = await first.settlement.then(() => null, (error) => error);
if (!(firstFailure instanceof Error) ||
    !firstFailure.message.includes("provider failed after construction") ||
    !firstFailure.message.includes("429: Monthly usage limit reached")) {
  throw new Error(`provider-error settlement lost the settled error turn: ${String(firstFailure)}`);
}

if (mainUserMessages.length !== 0) throw new Error("branch bypassed watcher-owned fallback delivery");
if (existsSync(`${home}/state/.branch-eligible-rows`)) {
  throw new Error("provider-error fallback left the claimed row grant active");
}

const healthy = dispatch("signal: healthy branch turn");
if (!healthy.accepted) throw new Error("one provider error latched the branch prematurely");
await healthy.settlement;
await settle(() => attempt === 2 && sentToMain.length === 1, "healthy branch report");
if (mainUserMessages.length !== 0) throw new Error("a healthy reported turn fell back to main");

const third = dispatch("signal: provider error after reset");
if (!third.accepted) throw new Error("a successful report did not reset the consecutive provider-error streak");
const thirdFailure = await third.settlement.then(() => null, (error) => error);
if (!(thirdFailure instanceof Error) || !thirdFailure.message.includes("provider failed after construction")) {
  throw new Error(`provider error after reset did not reject settlement: ${String(thirdFailure)}`);
}
const fourth = dispatch("signal: consecutive provider error");
if (!fourth.accepted) throw new Error("the branch latched before the second consecutive provider error settled");
const fourthFailure = await fourth.settlement.then(() => null, (error) => error);
if (!(fourthFailure instanceof Error) || !fourthFailure.message.includes("provider failed after construction")) {
  throw new Error(`consecutive provider error did not reject settlement: ${String(fourthFailure)}`);
}

const fifth = dispatch("signal: branch must now defer directly to main");
if (fifth.accepted) throw new Error("two consecutive provider errors did not latch the broken branch");
await new Promise((resolve) => setTimeout(resolve, 50));
if (attempt !== 4 || mainUserMessages.length !== 0) {
  throw new Error(`latched branch still prompted or emitted its own fallback: attempts=${attempt} fallbacks=${mainUserMessages.length}`);
}
const pauseNotes = sentToMain.filter((sent) => sent.message.content.includes("Supervision branch paused after repeated provider errors"));
if (pauseNotes.length !== 1 || pauseNotes[0].message.content.includes("\n")) {
  throw new Error(`the first latch must surface exactly one one-line note: ${JSON.stringify(pauseNotes)}`);
}

// No provider attempt occurs inside the first five-minute cooldown. Exactly
// one probe is accepted when it elapses, and all other wakes remain on main
// even while that probe is still in flight.
now += (5 * 60 * 1000) - 1;
if (dispatch("signal: still inside first cooldown").accepted) {
  throw new Error("the latched branch re-probed before its first cooldown elapsed");
}
now += 1;
const failedProbe = dispatch("signal: first cooldown probe");
if (!failedProbe.accepted) throw new Error("the branch did not accept one probe after its cooldown elapsed");
await settle(() => attempt === 5 && typeof releaseFailedProbe === "function", "in-flight failed cooldown probe");
if (sentToMain.some((sent) => sent.message.content.includes("Supervision branch recovered after a successful cooldown probe"))) {
  throw new Error("a durable report cleared the latch before its prompt settled");
}
const duringProbe = makeOffer("signal: main owns wakes during a branch probe");
pi.events.emit("fm-branch-supervision:dispatch", duringProbe);
if (duringProbe.accepted) throw new Error("a second wake entered the branch while its one cooldown probe was in flight");
releaseFailedProbe();
const failedProbeError = await failedProbe.settlement.then(() => null, (error) => error);
if (!(failedProbeError instanceof Error) || !failedProbeError.message.includes("provider failed after construction")) {
  throw new Error(`failed cooldown probe did not reject settlement: ${String(failedProbeError)}`);
}
if (mainUserMessages.length !== 0) throw new Error("failed cooldown probe bypassed watcher-owned fallback delivery");
if (existsSync(`${home}/state/.branch-eligible-rows`)) {
  throw new Error("failed cooldown probe left the claimed row grant active");
}

// The failed probe doubles the cooldown from five to ten minutes. Five more
// minutes are not enough, but the next five admit exactly one recovery probe.
now += 5 * 60 * 1000;
if (dispatch("signal: inside extended cooldown").accepted) {
  throw new Error("a failed probe did not extend the next cooldown beyond five minutes");
}
now += 5 * 60 * 1000;
const recoveryProbe = dispatch("signal: recovery probe after extended cooldown");
if (!recoveryProbe.accepted) throw new Error("the branch did not re-probe after the extended cooldown elapsed");
await settle(() => attempt === 6 && sentToMain.some((sent) => sent.message.content.includes("cooldown probe recovered the branch")), "successful recovery probe");
// The recovery note is emitted when the wake SETTLES, which is after the
// report note the condition above waits for.
await recoveryProbe.settlement;
if (mainUserMessages.length !== 0) throw new Error("a successful recovery probe also fell back to main");
const recoveryNotes = sentToMain.filter((sent) => sent.message.content.includes("Supervision branch recovered after a successful cooldown probe"));
if (recoveryNotes.length !== 1 || recoveryNotes[0].message.content.includes("\n")) {
  throw new Error(`recovery must surface exactly one one-line note: ${JSON.stringify(recoveryNotes)}`);
}

// The durable report cleared both the latch and the old streak: one new
// provider error falls back but does not latch, so a following wake still
// reaches the branch and can report successfully.
const afterRecoveryError = dispatch("signal: first provider error after recovery");
if (!afterRecoveryError.accepted) throw new Error("the successful probe did not clear the branch latch");
const afterRecoveryFailure = await afterRecoveryError.settlement.then(() => null, (error) => error);
if (!(afterRecoveryFailure instanceof Error) || !afterRecoveryFailure.message.includes("provider failed after construction")) {
  throw new Error(`first post-recovery provider error did not reject settlement: ${String(afterRecoveryFailure)}`);
}
if (mainUserMessages.length !== 0) throw new Error("post-recovery provider error bypassed watcher-owned fallback delivery");
if (existsSync(`${home}/state/.branch-eligible-rows`)) {
  throw new Error("post-recovery provider error left the claimed row grant active");
}
const afterRecoveryHealthy = dispatch("signal: healthy turn after one post-recovery error");
if (!afterRecoveryHealthy.accepted) throw new Error("the successful probe did not clear the provider-error streak");
await settle(() => attempt === 8 && sentToMain.some((sent) => sent.message.content.includes("post-recovery report proved")), "post-recovery healthy report");
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "provider errors must latch, cool down, re-probe once, back off, and recover through a durable report: $out"
  pass "provider-error latches cool down, re-probe once with backoff, and recover through a durable report"
}

test_transient_reconcile_failure_recovers_without_reset_and_persistent_failures_back_off() {
  local repo home fakebin out status real_bash
  repo="$TMP_ROOT/reconcile-recovery-root"
  home="$TMP_ROOT/reconcile-recovery-home"
  fakebin="$home/fakebin"
  real_bash=$(command -v bash)
  mkdir -p "$home/state" "$home/config" "$fakebin"
  install_pi_branch_extension_fixture "$repo"
  cat > "$fakebin/bash" <<'SH'
#!/bin/sh
if [ "$1" = "$FM_TEST_OUTCOME_SCRIPT" ] && [ "$2" = unread ]; then
  remaining=$(cat "$FM_TEST_FAIL_COUNT" 2>/dev/null || printf '0')
  if [ "$remaining" -gt 0 ]; then
    printf '%s\n' "$((remaining - 1))" > "$FM_TEST_FAIL_COUNT"
    echo "injected unread failure" >&2
    exit 9
  fi
fi
exec "$FM_TEST_REAL_BASH" "$@"
SH
  chmod +x "$fakebin/bash"
  PATH="$fakebin:$PATH" PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TEST_REAL_BASH="$real_bash" FM_TEST_OUTCOME_SCRIPT="$ROOT/bin/fm-branch-outcome.sh" \
    FM_TEST_FAIL_COUNT="$home/state/unread-fail-count" FM_BRANCH_RECONCILE_RETRY_BASE_MS=250 \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { dispatch, fire, home, defaultSessionCtx }; })()`);
const { dispatch, fire, home, defaultSessionCtx } = globalThis.__t;
import { readFileSync, writeFileSync } from "node:fs";

let now = 1_000_000;
Date.now = () => now;
await fire("session_start", {}, defaultSessionCtx);
let reports = 0;
globalThis.__fmOnBranchPrompt = async ({ session }) => {
  const report = session.options.customTools.find((tool) => tool.name === "fm_branch_report");
  const result = await report.execute(
    `reconcile-recovery-${++reports}`,
    { task: "branch-driver", verdict: "routine", summary: `reconcile recovery ${reports}` },
    undefined,
    undefined,
    {},
  );
  if (result.isError) throw new Error(`recovery report failed: ${JSON.stringify(result)}`);
  session.messages.push({ role: "assistant", content: [], stopReason: "stop" });
};

writeFileSync(process.env.FM_TEST_FAIL_COUNT, "1\n");
await fire("turn_end", {}, defaultSessionCtx);
const recovered = dispatch("signal: recovered after one unread failure");
if (!recovered.accepted) throw new Error(`one-shot reconcile failure did not admit a recovery offer: ${recovered.declineReason}`);
await recovered.settlement;
if (reports !== 1 || (globalThis.__fmPrompts ?? []).length !== 1) {
  throw new Error(`one-shot recovery did not process exactly once: reports=${reports} prompts=${globalThis.__fmPrompts?.length}`);
}

writeFileSync(process.env.FM_TEST_FAIL_COUNT, "2\n");
await fire("turn_end", {}, defaultSessionCtx);
const failedProbe = dispatch("signal: repeated reconcile failure");
if (!failedProbe.accepted) throw new Error("the first retry boundary was not admitted");
const failure = await failedProbe.settlement.then(() => null, (error) => error);
if (!(failure instanceof Error) || !failure.message.includes("reconcile unread supervision outcomes")) {
  throw new Error(`persistent reconcile failure was not surfaced: ${String(failure)}`);
}
const duringBackoff = dispatch("signal: inside reconcile backoff");
if (duringBackoff.accepted || duringBackoff.declineReason !== "reconcile-unhealthy") {
  throw new Error(`persistent reconcile failure did not back off: ${JSON.stringify(duringBackoff)}`);
}
now += 250;
writeFileSync(process.env.FM_TEST_FAIL_COUNT, "0\n");
const afterBackoff = dispatch("signal: recovered after reconcile backoff");
if (!afterBackoff.accepted) throw new Error(`reconcile recovery probe was not admitted: ${afterBackoff.declineReason}`);
await afterBackoff.settlement;
if (reports !== 2 || (globalThis.__fmPrompts ?? []).length !== 2) {
  throw new Error(`reconcile recovery replayed or lost work: reports=${reports} prompts=${globalThis.__fmPrompts?.length}`);
}

const trace = readFileSync(`${home}/state/.supervision-routing.jsonl`, "utf8").trim().split("\n").map((line) => JSON.parse(line));
if (!trace.some((row) => row.stage === "reconcile" && row.reason === "failed") ||
  !trace.some((row) => row.stage === "settlement" && row.reason === "reported-and-released")) {
  throw new Error(`routing trace did not explain failure and recovery: ${JSON.stringify(trace)}`);
}
if (JSON.stringify(trace).includes("reconcile recovery") || JSON.stringify(trace).includes("injected unread failure")) {
  throw new Error(`routing trace leaked report or subprocess text: ${JSON.stringify(trace)}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "transient reconcile health must recover while persistent failures back off: $out"
  pass "one-shot reconcile failure recovers on an ordinary offer, persistent failures back off, and trace data stays bounded and redacted"
}

test_selection_change_does_not_corrupt_inflight_provider_state() {
  local repo home out status
  repo="$TMP_ROOT/provider-selection-race-root"
  home="$TMP_ROOT/provider-selection-race-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { dispatch, fire, settle, home, mainUserMessages }; })()`);
const { dispatch, fire, settle, home, mainUserMessages } = globalThis.__t;

const entries = [];
const mainSession = {
  getSessionFile: () => `${home}/main.jsonl`,
  getEntries: () => entries,
};
await fire("session_start", {}, { sessionManager: mainSession });
entries.push({ type: "message", message: { role: "user", content: "context waiting for the branch mirror" } });
await fire("turn_end", {}, { sessionManager: mainSession });

let releaseMirror;
globalThis.__fmMirrorGate = new Promise((resolve) => { releaseMirror = resolve; });
let attempt = 0;
globalThis.__fmOnBranchPrompt = async ({ session }) => {
  attempt += 1;
  if (attempt === 3) {
    const report = session.options.customTools.find((tool) => tool.name === "fm_branch_report");
    const recorded = await report.execute(
      "healthy-after-selection",
      { task: "branch-driver", verdict: "routine", summary: "replacement branch remains available" },
      undefined,
      undefined,
      {},
    );
    if (recorded.isError) throw new Error(`healthy report failed: ${JSON.stringify(recorded)}`);
    session.messages.push({ role: "assistant", content: [], stopReason: "stop" });
    return;
  }
  session.messages.push({
    role: "assistant",
    content: [],
    stopReason: "error",
    errorMessage: "429: provider unavailable",
  });
};

const stale = dispatch("signal: provider error during model selection");
if (!stale.accepted) throw new Error("in-flight wake was not accepted");
await settle(() => globalThis.__fmMirrorStarted === true, "pending branch mirror");
await fire("model_select", { model: { provider: "anthropic", id: "replacement-model" } });
releaseMirror();
const staleFailure = await stale.settlement.then(() => null, (error) => error);
if (!(staleFailure instanceof Error) ||
    !staleFailure.message.includes("provider failed after construction") ||
    staleFailure.message.includes("no durable transcript")) {
  throw new Error(`selection change detached the in-flight transcript: ${String(staleFailure)}`);
}
if (mainUserMessages.length !== 0) throw new Error("branch bypassed watcher-owned fallback delivery");

globalThis.__fmMirrorGate = null;
const replacementError = dispatch("signal: first replacement provider error");
if (!replacementError.accepted) throw new Error("replacement branch was unavailable after selection");
const replacementFailure = await replacementError.settlement.then(() => null, (error) => error);
if (!(replacementFailure instanceof Error) || !replacementFailure.message.includes("provider failed after construction")) {
  throw new Error(`replacement provider error did not reject settlement: ${String(replacementFailure)}`);
}

const healthy = dispatch("signal: replacement branch recovery");
if (!healthy.accepted) throw new Error("stale provider error polluted the replacement failure streak");
await healthy.settlement;
await settle(() => attempt === 3, "replacement branch recovery");
if (mainUserMessages.length !== 0) throw new Error("healthy replacement turn fell back to main");
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "selection changes must preserve in-flight transcript and isolate provider streaks: $out"
  pass "selection changes preserve in-flight transcript ownership and reset provider-error streaks"
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
await eval(`(async () => { ${prelude}; globalThis.__t = { bus, fire, home, mainUserMessages }; })()`);
const { bus, fire, home, mainUserMessages } = globalThis.__t;
import { writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { pathToFileURL } from "node:url";
const lib = await import(pathToFileURL(`${dirname(process.env.PLUGIN)}/lib/fm-branch-dispatch.ts`).href);
await fire("session_start", {});
writeFileSync(`${home}/state/.wake-queue`, "1\t1\tsignal\tbranch-driver.status\trace\n");
const scope = lib.scopeForUnreadWake(`${home}/state`, false);
const offer = lib.createBranchDispatchOffer("signal: branch-driver.status", [], false, lib.dispositionForWakeTrigger("signal: branch-driver.status", scope).eligible, [], "claim-race", scope.eligibleSeqs, scope.eligibleTasks, scope.taskBySeq);
bus.emit("fm-branch-supervision:dispatch", offer);
if (!offer.accepted) throw new Error("eligible wake was not accepted before the ownership recheck");
writeFileSync(`${home}/state/.main-eligible-rows`, "1\n");
const failure = await offer.settlement.then(
  () => null,
  (error) => error,
);
if (!(failure instanceof Error) || !failure.message.includes("already claimed by main")) {
  throw new Error(`main-owned claim did not reject branch settlement: ${String(failure)}`);
}
if ((globalThis.__fmPrompts ?? []).length !== 0) {
  throw new Error("branch prompted for a row already claimed by main");
}
if (mainUserMessages.length !== 0) {
  throw new Error(`branch bypassed watcher-owned fallback delivery: ${JSON.stringify(mainUserMessages)}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "a main-owned grant result must reject to watcher delivery: $out"
  pass "a stale main claim returns the durable wake to watcher delivery"
}

test_branch_admission_rechecks_retirement_and_endpoint_reuse() {
  local repo home out status
  repo="$TMP_ROOT/admission-identity-root"
  home="$TMP_ROOT/admission-identity-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { bus, fire, home, realRoot }; })()`);
const { bus, fire, home } = globalThis.__t;
import { unlinkSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { pathToFileURL } from "node:url";

const lib = await import(pathToFileURL(`${dirname(process.env.PLUGIN)}/lib/fm-branch-dispatch.ts`).href);
const state = `${home}/state`;
await fire("session_start", {});

function classifiedOffer(message) {
  const scope = lib.scopeForUnreadWake(state, false);
  const disposition = lib.dispositionForWakeTrigger(message, scope);
  return lib.createBranchDispatchOffer(
    message,
    scope.projects,
    false,
    disposition.eligible,
    [],
    `identity-${message.includes("reuse") ? "reuse" : "retire"}`,
    scope.eligibleSeqs,
    scope.eligibleTasks,
    scope.taskBySeq,
  );
}

// The admitted row remains durable but its metadata retires before the
// serialized pre-grant recheck. That is a fallback, not an already-drained
// no-op, and the branch must never prompt or grant it.
writeFileSync(`${state}/.wake-queue`, "1\t41\tstale\tfm-branch-driver\tstale: retire after admission\n");
const retired = classifiedOffer("stale: fm-branch-driver");
bus.emit("fm-branch-supervision:dispatch", retired);
if (!retired.accepted) throw new Error(`retirement probe was not admitted: ${retired.declineReason}`);
unlinkSync(`${state}/branch-driver.meta`);
const retiredFailure = await retired.settlement.then(() => null, (error) => error);
if (!(retiredFailure instanceof Error) || !retiredFailure.message.includes("admitted row retired")) {
  throw new Error(`retirement after admission did not fall back: ${String(retiredFailure)}`);
}
if ((globalThis.__fmPrompts ?? []).length !== 0) throw new Error("retired admitted row reached a branch prompt");

// Recreate the original mapping, classify, then transfer the same endpoint to
// a different task before the pre-grant read. Matching seq alone is not enough:
// the admitted task identity must still match exactly.
writeFileSync(`${state}/branch-driver.meta`, `project=${home}/projects/approved\nwindow=fm-branch-driver\n`);
writeFileSync(`${state}/.wake-queue`, "1\t42\tstale\tfm-branch-driver\tstale: endpoint reuse\n");
const reused = classifiedOffer("stale: fm-branch-driver reuse");
if (!reused.eligible || reused.taskBySeq["42"] !== "branch-driver") {
  throw new Error(`endpoint reuse fixture did not capture original identity: ${JSON.stringify(reused)}`);
}
bus.emit("fm-branch-supervision:dispatch", reused);
if (!reused.accepted) throw new Error(`endpoint-reuse probe was not admitted: ${reused.declineReason}`);
writeFileSync(`${state}/branch-driver.meta`, `project=${home}/projects/approved\nwindow=fm-retired-window\n`);
writeFileSync(`${state}/replacement-task.meta`, `project=${home}/projects/approved\nwindow=fm-branch-driver\n`);
const reuseFailure = await reused.settlement.then(() => null, (error) => error);
if (!(reuseFailure instanceof Error) || !reuseFailure.message.includes("task generation changed")) {
  throw new Error(`endpoint reuse did not fail the identity fence: ${String(reuseFailure)}`);
}
if ((globalThis.__fmPrompts ?? []).length !== 0) throw new Error("reused endpoint reached a branch prompt");
if (await import("node:fs").then(({ existsSync }) => existsSync(`${state}/.branch-eligible-rows`))) {
  throw new Error("failed identity recheck left a branch grant behind");
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "retirement and endpoint reuse after admission must fail the exact identity fence: $out"
  pass "branch admission rejects task retirement and endpoint reuse before granting work"
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

await fire("session_start", {});
let releaseFirst;
globalThis.__fmPromptGate = new Promise((resolve) => {
  releaseFirst = resolve;
});
globalThis.__fmOnBranchPrompt = async ({ session }) => {
  const report = session.options.customTools.find((tool) => tool.name === "fm_branch_report");
  await report.execute(
    "first-drained-elsewhere",
    { task: "branch-driver", verdict: "routine", summary: "the accepted wake was already reconciled" },
    undefined,
    undefined,
    {},
  );
};
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
await fire("turn_end", {}, ctx);
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
await fire("turn_end", {}, ctx);
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
await fire("turn_end", {}, ctx2);
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

test_branch_mirror_reanchors_for_the_new_session_branch_conversation() {
  local repo home out status
  repo="$TMP_ROOT/mirror-reanchor-root"
  home="$TMP_ROOT/mirror-reanchor-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, makeCtx, home }; })()`);
const { fire, dispatch, settle, makeCtx, home } = globalThis.__t;
import { readFileSync } from "node:fs";

// One main session file throughout: a /resume or reload keeps main's own
// session, which is exactly the case where the durable cursor would otherwise
// hide already-mirrored dialog from the session's new branch conversation.
const entries = [{ type: "message", message: { role: "user", content: "standing order: never merge task-7" } }];
const ctx = makeCtx({
  sessionManager: { getSessionFile: () => `${home}/main-1.jsonl`, getEntries: () => entries },
});
const mirrorsOf = (session) => session.ops.filter((op) => op.kind === "custom").map((op) => op.message.content);

await fire("session_start", {}, ctx);
await fire("turn_end", {}, ctx);
dispatch("signal: first session");
await settle(() => (globalThis.__fmSessions ?? []).length === 1, "first branch build");
const first = globalThis.__fmSessions[0];
if (JSON.stringify(mirrorsOf(first)) !== JSON.stringify(["[captain] standing order: never merge task-7"])) {
  throw new Error(`the first branch conversation did not receive the session's dialog: ${JSON.stringify(mirrorsOf(first))}`);
}
const cursor = JSON.parse(readFileSync(`${home}/state/.branch-mirror-cursor`, "utf8"));
if (cursor.file !== `${home}/main-1.jsonl` || cursor.index !== entries.length) {
  throw new Error(`the durable cursor did not advance with delivery: ${JSON.stringify(cursor)}`);
}

// The reload starts a new branch conversation, so the mirror re-anchors to the
// current main session's start and that conversation receives the whole
// session's dialog, not only what arrived after the cursor.
entries.push({ type: "message", message: { role: "user", content: "and hold task-9 too" } });
await fire("session_shutdown", {});
await fire("session_start", {}, ctx);
await fire("turn_end", {}, ctx);
dispatch("signal: second session");
await settle(() => (globalThis.__fmSessions ?? []).length === 2, "second branch build");
const second = globalThis.__fmSessions[1];
if (second.options.sessionManager.opened) throw new Error("the reload continued the previous branch conversation");
const expected = ["[captain] standing order: never merge task-7", "[captain] and hold task-9 too"];
if (JSON.stringify(mirrorsOf(second)) !== JSON.stringify(expected)) {
  throw new Error(`the new branch conversation lost the session's earlier dialog: ${JSON.stringify(mirrorsOf(second))}`);
}

// Inside that session the cursor keeps working: later dialog mirrors once.
entries.push({ type: "message", message: { role: "user", content: "task-9 may merge when green" } });
await fire("turn_end", {}, ctx);
await settle(() => mirrorsOf(second).length === 3, "incremental mirror after the re-anchor");
if (mirrorsOf(second)[2] !== "[captain] task-9 may merge when green") {
  throw new Error(`the incremental mirror re-sent dialog or lost the new line: ${JSON.stringify(mirrorsOf(second))}`);
}
await settle(
  () => JSON.parse(readFileSync(`${home}/state/.branch-mirror-cursor`, "utf8")).index === entries.length,
  "durable cursor after the re-anchor",
);
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "a new session's branch conversation must receive that session's dialog from its start: $out"
  pass "the dialog mirror re-anchors for each session's new branch conversation and stays incremental within it"
}

test_branch_session_is_new_at_every_main_session_start() {
  local repo home out status first_pointer
  repo="$TMP_ROOT/fresh-session-root"
  home="$TMP_ROOT/fresh-session-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, makeCtx, home }; })()`);
const { fire, dispatch, settle, makeCtx, home } = globalThis.__t;
import { readFileSync } from "node:fs";

const pointerFile = `${home}/state/.branch-session`;
const readPointer = () => readFileSync(pointerFile, "utf8").trim();

// 1. The first wake of a session opens the branch conversation and records it.
await fire("session_start", {}, makeCtx());
dispatch("signal: first session probe");
await settle(() => (globalThis.__fmSessions ?? []).length === 1, "first branch build");
const first = globalThis.__fmSessions[0].options.sessionManager;
if (first.opened) throw new Error("the first branch build reopened a recorded conversation");
if (readPointer() !== first.getSessionFile()) {
  throw new Error(`the pointer does not name the live branch conversation: ${readPointer()}`);
}

// 2. WITHIN one main session the conversation persists: a model or effort
// change drops the live branch and the next wake continues the same file.
await fire("thinking_level_select", { level: "high", previousLevel: "medium" });
await settle(() => globalThis.__fmSessions[0].disposed, "live branch release inside the session");
dispatch("signal: same session probe");
await settle(() => (globalThis.__fmSessions ?? []).length === 2, "same-session rebuild");
const continued = globalThis.__fmSessions[1].options.sessionManager;
if (!continued.opened || continued.getSessionFile() !== first.getSessionFile()) {
  throw new Error(`a rebuild inside one session must continue that session's conversation: ${continued.getSessionFile()}`);
}

// 3. A main session start - /new here, and identically /resume, /fork, or a
// reload - starts a NEW branch conversation. The recorded pointer is not
// reopened, and it follows the new conversation instead.
await fire("session_shutdown", {});
await fire("session_start", {}, makeCtx());
dispatch("signal: new session probe");
await settle(() => (globalThis.__fmSessions ?? []).length === 3, "post-session-start branch build");
const replacement = globalThis.__fmSessions[2].options.sessionManager;
if (replacement.opened) throw new Error("a main session start reopened the previous branch conversation");
if (replacement.getSessionFile() === first.getSessionFile()) {
  throw new Error("a main session start reused the previous branch conversation file");
}
if (readPointer() !== replacement.getSessionFile()) {
  throw new Error(`the pointer did not follow the new branch conversation: ${readPointer()}`);
}
console.log(readPointer());
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "a main session start must start a new branch conversation: $out"
  first_pointer=$(tail -n 1 "$TMP_ROOT/node-output")
  case "$first_pointer" in
    */fresh-session-home/state/branch-session/*.jsonl) ;;
    *) fail "the branch conversation was not recorded under state/branch-session: $first_pointer" ;;
  esac
  # A restart is a main session start too: the recorded conversation from the
  # previous process is left on disk and never becomes the live one.
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TEST_PRIOR_POINTER="$first_pointer" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, makeCtx, home }; })()`);
const { fire, dispatch, settle, makeCtx, home } = globalThis.__t;
import { existsSync, readFileSync } from "node:fs";

const prior = process.env.FM_TEST_PRIOR_POINTER;
if (!existsSync(prior)) throw new Error("the previous process left no recorded branch conversation to guard against");
if (readFileSync(`${home}/state/.branch-session`, "utf8").trim() !== prior) {
  throw new Error("the restart did not start from the previous process's recorded pointer");
}

await fire("session_start", {}, makeCtx());
dispatch("signal: restart probe");
await settle(() => (globalThis.__fmSessions ?? []).length === 1, "restart branch build");
const restarted = globalThis.__fmSessions[0].options.sessionManager;
if (restarted.opened) throw new Error("the restart reopened the recorded branch conversation");
if (restarted.getSessionFile() === prior) throw new Error("the restart reused the recorded branch conversation file");
if (readFileSync(`${home}/state/.branch-session`, "utf8").trim() !== restarted.getSessionFile()) {
  throw new Error("the restart did not repoint the record at its new branch conversation");
}
if (!existsSync(prior)) throw new Error("the previous conversation file was destroyed instead of left behind");
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "a restart must start a new branch conversation instead of reopening the recorded one: $out"
  pass "every main session start begins a new branch conversation while one session keeps its own"
}

test_codex_branch_initializes_only_the_compat_package_before_prompting() {
  local mode repo home out status
  mode=supported
    repo="$TMP_ROOT/codex-compat-$mode-root"
    home="$TMP_ROOT/codex-compat-$mode-home"
    mkdir -p "$home/state" "$home/config"
    install_pi_branch_extension_fixture "$repo"
    PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      COMPAT_MODE="$mode" DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
globalThis.__fmPiVersion = "9.9.9";
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, makeCtx, registryModels, home }; })()`);
const { fire, dispatch, settle, makeCtx, registryModels, home } = globalThis.__t;
import { existsSync, readFileSync, writeFileSync } from "node:fs";

const mode = process.env.COMPAT_MODE;
const path = `${process.env.FM_TEST_AGENT_DIR}/npm/node_modules/pi-openai-codex-compat/package.json`;
const manifest = JSON.parse(readFileSync(path, "utf8"));
if (manifest.version !== "0.0.16") throw new Error(`fixture has the wrong compatibility version: ${manifest.version}`);
manifest.version = "8.8.8";
writeFileSync(path, JSON.stringify(manifest));
const globalSettings = {
  transport: "sse", websocketConnectTimeoutMs: 7000, httpIdleTimeoutMs: 23000,
  httpProxy: "http://127.0.0.1:9", defaultModel: "another-model", defaultThinkingLevel: "high",
  packages: ["npm:unwanted"], extensions: ["unwanted"], skills: ["unwanted"], prompts: ["unwanted"], themes: ["unwanted"],
};
writeFileSync(`${process.env.FM_TEST_AGENT_DIR}/settings.json`, JSON.stringify(globalSettings));
// The same observed startup state must restore the guarded bash independent
// of release strings, while a package retaining it needs no adaptation.
if (mode !== "stable") globalThis.__fmCompatActiveTools = ["read", "fm_task_continuation", "fm_branch_report"];

registryModels.push(
  { provider: "anthropic", id: "main-model", api: "anthropic-messages" },
  { provider: "openai-codex", id: "codex-branch", api: "openai-codex-responses" },
);
writeFileSync(`${home}/config/supervision-branch-model`, "openai-codex/codex-branch\n");
fire("session_start", {}, makeCtx());
await new Promise((resolve) => setTimeout(resolve, 25));
if (existsSync(`${home}/state/.branch-session`) || (globalThis.__fmSessions ?? []).length) {
  throw new Error("Codex branch was created before its first eligible notification");
}
dispatch("signal: codex compat create");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "Codex branch prompt");

const session = globalThis.__fmSessions[0];
const loader = globalThis.__fmLoaders[0];
const packagePath = `${process.env.FM_TEST_AGENT_DIR}/npm/node_modules/pi-openai-codex-compat/extensions/index.ts`;
if (JSON.stringify(loader.options.additionalExtensionPaths) !== JSON.stringify([packagePath])) {
  throw new Error(`the Codex branch loaded the wrong explicit extension set: ${JSON.stringify(loader.options.additionalExtensionPaths)}`);
}
for (const key of ["noExtensions", "noSkills", "noPromptTemplates", "noThemes", "noContextFiles"]) {
  if (loader.options[key] !== true) throw new Error(`Codex compatibility weakened ${key}`);
}
if (!session.bound || !globalThis.__fmCompatNativeCompactionReady || !globalThis.__fmCompatProviderRegistered) {
  throw new Error("the compatibility extension did not complete session_start");
}
if (session.options.settingsManager !== loader.options.settingsManager) {
  throw new Error("the Codex branch loader and AgentSession did not share the isolated settings manager");
}
const snapshot = session.options.settingsManager;
for (const key of ["transport", "websocketConnectTimeoutMs", "httpIdleTimeoutMs", "httpProxy"]) {
  if (snapshot.settings[key] !== globalSettings[key]) throw new Error(`branch lost global ${key}`);
}
for (const key of ["packages", "extensions", "skills", "prompts", "themes"]) {
  if (JSON.stringify(snapshot.settings[key]) !== "[]") throw new Error(`branch retained configured ${key}`);
}
if (snapshot.isProjectTrusted() || globalThis.__fmSettingsLoads.some((load) => load.options.projectTrusted !== false)) {
  throw new Error("branch settings trusted the project");
}
const lifecycle = globalThis.__fmLifecycle ?? [];
if (lifecycle.indexOf("compat-session-start") < 0 || lifecycle.indexOf("compat-session-start") > lifecycle.indexOf("prompt")) {
  throw new Error(`the branch prompted before compatibility initialization: ${JSON.stringify(lifecycle)}`);
}
if (JSON.stringify(session.getActiveToolNames()) !== JSON.stringify(["read", "bash", "fm_task_continuation", "fm_branch_report"])) {
  throw new Error(`compatibility startup escaped the branch tool allowlist: ${JSON.stringify(session.getActiveToolNames())}`);
}
if (JSON.stringify(globalThis.__fmPackageLookups) !== JSON.stringify([
  { source: "npm:pi-openai-codex-compat", scope: "user" },
  { source: "npm:pi-openai-codex-compat", scope: "user" },
])) {
  throw new Error(`the branch did not resolve the installed user package exactly: ${JSON.stringify(globalThis.__fmPackageLookups)}`);
}
if (JSON.stringify(globalThis.__fmPackageResolutions) !== JSON.stringify([
  { sources: ["npm:pi-openai-codex-compat"], options: {} },
])) {
  throw new Error(`the branch used the wrong package-manager resolution: ${JSON.stringify(globalThis.__fmPackageResolutions)}`);
}

// A replacement main session starts the upstream-required fresh branch
// conversation, resolves the package afresh, and initializes it before that
// new conversation's first prompt too.
fire("session_shutdown", {});
fire("session_start", {}, makeCtx());
dispatch("signal: codex compat reopen");
await settle(() => (globalThis.__fmPrompts ?? []).length === 2, "reopened Codex branch prompt");
const reopened = globalThis.__fmSessions[1];
if (reopened.options.settingsManager === snapshot || reopened.options.settingsManager.settings.transport !== "sse") {
  throw new Error("branch rebuild did not read a fresh global snapshot");
}
if (!reopened.options.sessionManager.created || !reopened.bound) {
  throw new Error("the replacement Codex branch did not bind compatibility onto its fresh persistent session");
}
const secondCompat = (globalThis.__fmLifecycle ?? []).lastIndexOf("compat-session-start");
const secondPrompt = (globalThis.__fmLifecycle ?? []).lastIndexOf("prompt");
if (secondCompat < 0 || secondCompat > secondPrompt) {
  throw new Error(`the reopened branch prompted before compatibility initialization: ${JSON.stringify(globalThis.__fmLifecycle)}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
    expect_code 0 "$status" "Codex branch compatibility initialization must precede every prompt: $out"
  pass "Codex branch initializes with non-pinned Pi and compatibility versions without widening tools"
}

test_non_codex_branch_does_not_depend_on_the_compat_package() {
  local repo home out status
  repo="$TMP_ROOT/non-codex-root"
  home="$TMP_ROOT/non-codex-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
globalThis.__fmCompatAbsent = true;
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, makeCtx, registryModels }; })()`);
const { fire, dispatch, settle, makeCtx, registryModels } = globalThis.__t;
import { writeFileSync } from "node:fs";
writeFileSync(`${process.env.FM_TEST_AGENT_DIR}/settings.json`, JSON.stringify({ transport: "sse", websocketConnectTimeoutMs: 7000 }));
registryModels.push({ provider: "anthropic", id: "main-model", api: "anthropic-messages" });
fire("session_start", {}, makeCtx());
dispatch("signal: ordinary branch");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "non-Codex branch prompt");
if ((globalThis.__fmPackageLookups ?? []).length !== 0 || (globalThis.__fmPackageResolutions ?? []).length !== 0) {
  throw new Error("a non-Codex branch attempted to resolve the optional compatibility package");
}
if (globalThis.__fmSessions[0].bound) throw new Error("non-Codex branch startup behavior changed");
const settings = globalThis.__fmSessions[0].options.settingsManager;
if (settings !== globalThis.__fmLoaders[0].options.settingsManager || settings.isProjectTrusted() ||
    settings.settings.transport !== "sse" || settings.settings.websocketConnectTimeoutMs !== 7000) {
  throw new Error("non-Codex branch did not share an isolated global snapshot");
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "non-Codex branches must remain independent of the compatibility package: $out"
  pass "non-Codex branch startup remains unchanged when pi-openai-codex-compat is absent"
}

test_codex_compat_package_failures_return_the_wake_to_main() {
  local mode repo home out status
  for mode in settings absent malformed identity no-entry multiple-entries outside-entry resolve wrong-source wrong-scope wrong-origin wrong-path load startup unexpected-tools unrestorable-bash; do
    repo="$TMP_ROOT/codex-failure-$mode-root"
    home="$TMP_ROOT/codex-failure-$mode-home"
    mkdir -p "$home/state" "$home/config"
    install_pi_branch_extension_fixture "$repo"
    PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      DRIVER_PRELUDE="$DRIVER_PRELUDE" FAILURE_MODE="$mode" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const mode = process.env.FAILURE_MODE;
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatchThroughWatcher, settle, makeCtx, registryModels, mainUserMessages, home }; })()`);
const { fire, dispatchThroughWatcher, settle, makeCtx, registryModels, mainUserMessages, home } = globalThis.__t;
import { readFileSync, writeFileSync } from "node:fs";
const manifest = `${process.env.FM_TEST_AGENT_DIR}/npm/node_modules/pi-openai-codex-compat/package.json`;
if (mode === "absent") globalThis.__fmCompatAbsent = true;
if (mode === "settings") writeFileSync(`${process.env.FM_TEST_AGENT_DIR}/settings.json`, "{not-json\n");
if (mode === "malformed") writeFileSync(manifest, "{not-json\n");
const metadata = {
  name: mode === "identity" ? "another-package" : "pi-openai-codex-compat",
  version: "local-build",
  peerDependencies: { "@earendil-works/pi-coding-agent": "not-semver" },
  pi: { extensions: mode === "no-entry" ? [] : mode === "multiple-entries" ?
    ["./extensions/index.ts", "./extensions/extra.ts"] : mode === "outside-entry" ?
    ["../outside.ts"] : ["./extensions/index.ts"] },
};
if (["identity", "no-entry", "multiple-entries", "outside-entry"].includes(mode)) {
  writeFileSync(manifest, JSON.stringify(metadata));
}
if (mode.startsWith("wrong-")) {
  globalThis.__fmCompatResolutionOverride = mode === "wrong-path" ? { path: "/outside/index.ts" } :
    { metadata: { source: "npm:pi-openai-codex-compat", scope: "user", origin: "package",
      [mode.slice(6)]: "untrusted" } };
}
if (mode === "unexpected-tools") globalThis.__fmCompatActiveTools = ["read", "fm_task_continuation", "fm_branch_report", "exec_command"];
if (mode === "unrestorable-bash") {
  globalThis.__fmCompatActiveTools = ["read", "fm_task_continuation", "fm_branch_report"];
  globalThis.__fmRefuseToolRestore = true;
}
if (mode === "resolve") globalThis.__fmCompatResolveError = "synthetic resolver failure";
if (mode === "load") globalThis.__fmCompatLoadError = "synthetic extension load failure";
if (mode === "startup") globalThis.__fmCompatStartupError = "synthetic session_start failure";
registryModels.push({ provider: "openai-codex", id: "codex-branch", api: "openai-codex-responses" });
writeFileSync(`${home}/config/supervision-branch-model`, "openai-codex/codex-branch\n");
fire("session_start", {}, makeCtx());
const offer = dispatchThroughWatcher(`signal: ${mode} compatibility failure`);
if (!offer.accepted) throw new Error(`${mode}: branch did not accept the wake before safe construction fallback`);
await settle(() => mainUserMessages.length === 1, `${mode} fallback`);
if (!mainUserMessages[0].content.includes("Supervision branch unavailable, falling back to main:")) {
  throw new Error(`${mode}: fallback omitted the safe-return reason: ${mainUserMessages[0].content}`);
}
if ((globalThis.__fmPromptStarts ?? 0) !== 0) {
  throw new Error(`${mode}: a Codex branch prompted without a fully initialized compatibility package`);
}
if (mode === "startup" && !globalThis.__fmSessions?.[0]?.disposed) {
  throw new Error("startup: the partially initialized branch session was not disposed");
}
process.exit(0);
EOF
    status=$?
    out=$(cat "$TMP_ROOT/node-output")
    expect_code 0 "$status" "Codex compatibility $mode failure must fail closed: $out"
  done
  pass "package identity, provenance, containment, startup, and unexpected-tool failures return Codex wakes to main before prompting"
}

test_supervision_reset_aborts_rotates_and_reanchors_without_touching_main_or_feishu() {
  local repo home out status
  repo="$TMP_ROOT/reset-root"
  home="$TMP_ROOT/reset-home"
  mkdir -p "$home/state" "$home/config" "$home/data/feishu/bindings"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, dispatchThroughWatcher, settle, makeCtx, commands, registryModels, mainEntries, mainSessionManager, mainUserMessages, notices, home }; })()`);
const { fire, dispatch, dispatchThroughWatcher, settle, makeCtx, commands, registryModels, mainEntries, mainSessionManager, mainUserMessages, notices, home } = globalThis.__t;
import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";

registryModels.push({ provider: "anthropic", id: "main-model", api: "anthropic-messages" });
mainEntries.push({ type: "message", message: { role: "user", content: "old mirrored order" } });
const feishuBinding = `${home}/data/feishu/bindings/active.json`;
writeFileSync(feishuBinding, '{"binding_id":"must-stay-byte-identical"}\n');
const feishuBefore = readFileSync(feishuBinding, "utf8");
const mainBefore = mainSessionManager;
fire("session_start", {}, makeCtx({ sessionManager: mainSessionManager }));

let releasePrompt;
globalThis.__fmPromptGate = new Promise((resolve) => { releasePrompt = resolve; });
globalThis.__fmAbortAction = () => releasePrompt();
const activeResetOffer = dispatchThroughWatcher("signal: active work reset");
if (!activeResetOffer.accepted) throw new Error("active reset fixture was not accepted");
await settle(() => globalThis.__fmSessions?.[0]?.isStreaming === true, "active branch prompt");
const oldSession = globalThis.__fmSessions[0];
const oldPointer = readFileSync(`${home}/state/.branch-session`, "utf8").trim();
if (!existsSync(`${home}/state/.branch-eligible-rows`)) throw new Error("active reset fixture has no row grant");
writeFileSync(`${home}/state/.lease-task-reset`, `branch\t${process.pid}\t123\n`);
// This line arrived after the old branch's last mirror flush. Reset must
// re-anchor past it instead of replaying the old oversized conversation.
mainEntries.push({ type: "message", message: { role: "assistant", content: "old tail before reset" } });

const command = commands.get("supervision-reset");
if (!command) throw new Error("the supervision-reset command was not registered");
await command.handler("", makeCtx({ sessionManager: mainSessionManager }));
await activeResetOffer.settlement.then(() => null, () => null);
if (!oldSession.aborted || !oldSession.waitedForIdle || !oldSession.disposed) {
  throw new Error("reset did not abort, quiesce, and dispose the active branch session");
}
if (existsSync(`${home}/state/.branch-eligible-rows`)) throw new Error("reset retained the active row grant");
if (existsSync(`${home}/state/.lease-task-reset`)) throw new Error("reset retained a branch task lease");
if (existsSync(`${home}/state/.branch-session`)) throw new Error("reset retained the old session pointer");
if (existsSync(oldPointer)) throw new Error("reset did not rotate the old session file");
const archives = readdirSync(`${home}/state/branch-session`).filter((name) => name.includes(".reset-") && name.endsWith(".archived"));
if (archives.length !== 1 || !existsSync(`${home}/state/branch-session/${archives[0]}`)) {
  throw new Error(`reset did not preserve one rotated session archive: ${JSON.stringify(archives)}`);
}
const cursor = JSON.parse(readFileSync(`${home}/state/.branch-mirror-cursor`, "utf8"));
if (cursor.file !== `${home}/main.jsonl` || cursor.index !== mainEntries.length) {
  throw new Error(`reset did not re-anchor main mirroring: ${JSON.stringify(cursor)}`);
}
if (mainSessionManager !== mainBefore || readFileSync(feishuBinding, "utf8") !== feishuBefore) {
  throw new Error("reset changed the captain's main session or Feishu binding");
}
if (!notices.some((notice) => notice.type === "info" && notice.message.includes("next supervision wake"))) {
  throw new Error(`reset did not report deferred fresh creation: ${JSON.stringify(notices)}`);
}

// No replacement is created by the command. The next eligible wake creates a
// new persistent session and receives only dialog after the reset anchor.
if (globalThis.__fmSessions.length !== 1) throw new Error("reset eagerly created a replacement branch");
writeFileSync(`${home}/state/.wake-queue`, "");
delete globalThis.__fmPromptGate;
delete globalThis.__fmAbortAction;
globalThis.__fmOnBranchPrompt = async () => {
  const report = globalThis.__fmSessions[1].options.customTools.find((tool) => tool.name === "fm_branch_report");
  const result = await report.execute("reset-fresh", {
    task: "branch-driver", verdict: "routine", summary: "fresh session handled", wake: "signal: fresh work after reset",
  });
  if (result.isError) throw new Error(`fresh-session report failed: ${JSON.stringify(result)}`);
};
mainEntries.push({ type: "message", message: { role: "user", content: "new order after reset" } });
fire("turn_end", {}, makeCtx({ sessionManager: mainSessionManager }));
if (!dispatch("signal: fresh work after reset", undefined, undefined, undefined, 2).accepted) {
  throw new Error("fresh wake after reset was not accepted");
}
await settle(() => globalThis.__fmSessions?.length === 2 && (globalThis.__fmPrompts ?? []).length === 2, "fresh branch prompt");
const freshSession = globalThis.__fmSessions[1];
const freshPointer = readFileSync(`${home}/state/.branch-session`, "utf8").trim();
if (!freshSession.options.sessionManager.created || freshPointer === oldPointer || !existsSync(freshPointer)) {
  throw new Error("the next wake did not create a fresh persistent branch session");
}
const mirrors = freshSession.ops.filter((op) => op.kind === "custom").map((op) => op.message.content);
if (JSON.stringify(mirrors) !== JSON.stringify(["[captain] new order after reset"])) {
  throw new Error(`fresh branch replayed pre-reset main history: ${JSON.stringify(mirrors)}`);
}
if (mainUserMessages.length !== 1 || !String(mainUserMessages[0].content).includes("signal: active work reset")) {
  throw new Error(`aborted work did not return safely to main exactly once: ${JSON.stringify(mainUserMessages)}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "supervision reset must quiesce, rotate, release ownership, and start fresh without moving main or Feishu: $out"
  pass "supervision-reset safely aborts active work, rotates history, releases ownership, and re-anchors the next branch"
}

test_repeated_supervision_reset_before_the_next_wake_releases_the_absent_grant_vacuously() {
  local repo home out status
  repo="$TMP_ROOT/repeated-reset-root"
  home="$TMP_ROOT/repeated-reset-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, makeCtx, commands, registryModels, mainEntries, mainSessionManager, notices, home }; })()`);
const { fire, dispatch, settle, makeCtx, commands, registryModels, mainEntries, mainSessionManager, notices, home } = globalThis.__t;
import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";

registryModels.push({ provider: "anthropic", id: "main-model", api: "anthropic-messages" });
fire("session_start", {}, makeCtx({ sessionManager: mainSessionManager }));

let releasePrompt;
globalThis.__fmPromptGate = new Promise((resolve) => { releasePrompt = resolve; });
globalThis.__fmAbortAction = () => releasePrompt();
if (!dispatch("signal: repeated reset probe").accepted) throw new Error("repeated-reset fixture was not accepted");
await settle(() => globalThis.__fmSessions?.[0]?.isStreaming === true, "active branch prompt");
if (!existsSync(`${home}/state/.branch-eligible-rows`)) throw new Error("repeated-reset fixture published no row grant");
if (!existsSync(`${home}/state/.branch-eligible-owner`)) throw new Error("repeated-reset fixture activated no grant owner");
mainEntries.push({ type: "message", message: { role: "assistant", content: "tail before the first reset" } });

const command = commands.get("supervision-reset");
if (!command) throw new Error("the supervision-reset command was not registered");
const resetCompletions = () =>
  notices.filter((notice) => notice.type === "info" && notice.message.includes("next supervision wake")).length;
await command.handler("", makeCtx({ sessionManager: mainSessionManager }));
if (resetCompletions() !== 1) throw new Error(`the first reset did not complete: ${JSON.stringify(notices)}`);
if (existsSync(`${home}/state/.branch-eligible-rows`) || existsSync(`${home}/state/.branch-eligible-owner`)) {
  throw new Error("the first reset left grant files behind");
}

mainEntries.push({ type: "message", message: { role: "assistant", content: "newer tail between resets" } });
await command.handler("", makeCtx({ sessionManager: mainSessionManager }));
if (notices.some((notice) => notice.type === "error")) {
  throw new Error(`a repeated reset before any new wake failed: ${JSON.stringify(notices)}`);
}
if (resetCompletions() !== 2) throw new Error(`the repeated reset did not complete: ${JSON.stringify(notices)}`);
if (existsSync(`${home}/state/.branch-eligible-rows`) || existsSync(`${home}/state/.branch-eligible-owner`)) {
  throw new Error("the repeated reset left grant files behind");
}
if (existsSync(`${home}/state/.branch-session`)) throw new Error("the repeated reset recreated a session pointer");
const cursor = JSON.parse(readFileSync(`${home}/state/.branch-mirror-cursor`, "utf8"));
if (cursor.file !== `${home}/main.jsonl` || cursor.index !== mainEntries.length) {
  throw new Error(`the repeated reset lost the mirror anchor: ${JSON.stringify(cursor)}`);
}
const archives = readdirSync(`${home}/state/branch-session`).filter((name) => name.includes(".reset-") && name.endsWith(".archived"));
if (archives.length !== 1) throw new Error(`the repeated reset touched the archived history: ${JSON.stringify(archives)}`);

writeFileSync(`${home}/state/.wake-queue`, "");
delete globalThis.__fmAbortAction;
globalThis.__fmPromptGate = new Promise(() => {});
fire("turn_end", {}, makeCtx({ sessionManager: mainSessionManager }));
if (!dispatch("signal: fresh work after repeated reset", undefined, undefined, undefined, 2).accepted) {
  throw new Error("the wake after a repeated reset was not accepted");
}
await settle(() => globalThis.__fmSessions?.length === 2 && globalThis.__fmSessions[1].isStreaming === true, "fresh branch prompt");
if (!existsSync(`${home}/state/.branch-eligible-rows`) || !existsSync(`${home}/state/.branch-eligible-owner`)) {
  throw new Error("the fresh wake after a repeated reset did not acquire a row grant");
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "a repeated supervision reset before any new wake must release the absent grant vacuously and stay healthy: $out"
  pass "a repeated supervision reset before any new wake releases the absent grant vacuously"
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
await fire("session_start", {});
dispatch("signal: main model unknown");
await settle(() => (globalThis.__fmSessions ?? []).length === 1, "unknown-main-model branch build");
if ("model" in globalThis.__fmSessions[0].options) {
  throw new Error("an unknown main model must fall back to passing no model override");
}

// 2. No pin, main's model known: the branch follows MAIN's own model,
// applied explicitly.
await fire("session_shutdown", {});
await fire("session_start", {}, makeCtx());
dispatch("signal: unpinned probe");
await settle(() => (globalThis.__fmSessions ?? []).length === 2, "unpinned branch build");
const unpinned = globalThis.__fmSessions[1].options.model;
if (!unpinned || unpinned.provider !== "anthropic" || unpinned.id !== "main-model") {
  throw new Error(`an absent pin must follow main's own model: ${JSON.stringify(unpinned)}`);
}

// 3. Pin present: the very next build carries exactly that model, resolved
// out of Pi's own catalog.
writeFileSync(`${home}/config/supervision-branch-model`, "openai/cheap-1\n");
await fire("session_shutdown", {});
await fire("session_start", {}, makeCtx());
dispatch("signal: pinned probe");
await settle(() => (globalThis.__fmSessions ?? []).length === 3, "pinned branch build");
const pinned = globalThis.__fmSessions[2].options.model;
if (!pinned || pinned.provider !== "openai" || pinned.id !== "cheap-1") {
  throw new Error(`pinned build did not use the pinned model: ${JSON.stringify(pinned)}`);
}

// 4. The session-replacement path (/new, /resume, /fork, reload all replace
// the session in-process) builds a NEW branch conversation and still applies
// the pin.
await fire("session_shutdown", {});
await fire("session_start", {}, makeCtx());
dispatch("signal: replacement probe");
await settle(() => (globalThis.__fmSessions ?? []).length === 4, "replacement branch build");
const replaced = globalThis.__fmSessions[3].options.model;
if (!replaced || replaced.provider !== "openai" || replaced.id !== "cheap-1") {
  throw new Error(`the replacement build did not use the pinned model: ${JSON.stringify(replaced)}`);
}
const manager = globalThis.__fmSessions[3].options.sessionManager;
if (manager.opened) throw new Error("a session replacement continued the previous branch conversation");

// 5. Clearing the pin makes the next branch follow main again. Pi's own
// session restore is what would otherwise get this wrong wherever a branch
// conversation IS continued (a model or effort change inside one session),
// because that conversation still records the pinned model, so only an
// explicit override keeps "follow main" honest.
rmSync(`${home}/config/supervision-branch-model`);
await fire("session_shutdown", {});
await fire("session_start", {}, makeCtx());
dispatch("signal: unpinned again");
await settle(() => (globalThis.__fmSessions ?? []).length === 5, "post-clear branch build");
const cleared = globalThis.__fmSessions[4];
if (cleared.options.model?.id === "cheap-1") {
  throw new Error("clearing the pin left the branch on the previously pinned model");
}
if (cleared.options.model?.provider !== "anthropic" || cleared.options.model?.id !== "main-model") {
  throw new Error(`clearing the pin did not return the branch to main's model: ${JSON.stringify(cleared.options.model)}`);
}
// A native main must use an explicit independent ordinary-Pi branch.
registryModels.push({ provider: "openai-codex", id: "gpt-6-astra" });
await fire("session_shutdown", {});
await fire("session_start", {}, makeCtx({ model: { provider: "codex-native", id: "gpt-6-astra" } }));
dispatch("signal: native main ordinary branch");
await settle(() => (globalThis.__fmSessions ?? []).length === 6, "native-main branch build");
const nativeBranch = globalThis.__fmSessions[5].options.model;
if (nativeBranch?.provider !== "openai-codex" || nativeBranch?.id !== "gpt-6-astra") {
  throw new Error(`native main inherited an unsafe branch runtime: ${JSON.stringify(nativeBranch)}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "the current pin state must decide the model on every branch build: $out"
  pass "the current pin state binds every branch build, and clearing it returns the branch to main's model"
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
await fire("session_start", {}, makeCtx());
dispatch("signal: before main model change");
await settle(() => (globalThis.__fmSessions ?? []).length === 1, "initial unpinned branch build");
const original = globalThis.__fmSessions[0];
if (original.options.model?.id !== "main-model") throw new Error("the unpinned branch did not start on main's model");

await fire("model_select", { model: { provider: "anthropic", id: "replacement-model" } });
await settle(() => original.disposed, "live unpinned branch release");
dispatch("signal: after main model change");
await settle(() => (globalThis.__fmSessions ?? []).length === 2, "replacement unpinned branch build");
const following = globalThis.__fmSessions[1];
if (following.options.model?.id !== "replacement-model") {
  throw new Error(`the unpinned branch did not follow main's model change: ${JSON.stringify(following.options.model)}`);
}

writeFileSync(`${home}/config/supervision-branch-model`, "openai/cheap-1\n");
await fire("session_shutdown", {});
await fire("session_start", {}, makeCtx());
dispatch("signal: establish pinned branch");
await settle(() => (globalThis.__fmSessions ?? []).length === 3, "pinned branch build");
const pinned = globalThis.__fmSessions[2];
if (pinned.options.model?.id !== "cheap-1") throw new Error("the pinned branch did not use its pin");
const promptsBefore = pinned.ops.filter((op) => op.kind === "prompt").length;

await fire("model_select", { model: { provider: "anthropic", id: "replacement-model" } });
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

await fire("session_start", {}, makeCtx());
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

// Under a codex-native main, Follow main reports the ordinary openai-codex
// model the next build actually runs, and the picker never offers the main
// native provider itself.
registryModels.push({ provider: "codex-native", id: "gpt-6-astra" }, { provider: "openai-codex", id: "gpt-6-astra" });
const nativeCtx = makeCtx({ model: { provider: "codex-native", id: "gpt-6-astra" } });
const nativePromptCount = uiPrompts.length;
const nativeNoticeCount = notices.length;
uiSelections.push("Follow main (codex-native/gpt-6-astra)");
await command.handler("", nativeCtx);
const nativeOffer = uiPrompts[nativePromptCount];
if (nativeOffer.options[0] !== "Follow main (codex-native/gpt-6-astra)" || nativeOffer.options.includes("codex-native/gpt-6-astra")) {
  throw new Error(`the picker must offer following a native main without offering its native provider: ${JSON.stringify(nativeOffer.options)}`);
}
const nativeNotices = notices.slice(nativeNoticeCount);
if (nativeNotices.length !== 1 || nativeNotices[0].type !== "info" || !nativeNotices[0].message.includes("openai-codex/gpt-6-astra")) {
  throw new Error(`following a native main did not report the ordinary Pi model the build uses: ${JSON.stringify(nativeNotices)}`);
}
dispatch("signal: native follow");
await settle(() => (globalThis.__fmSessions ?? []).length === 6, "native-main follow build");
const nativeFollowed = globalThis.__fmSessions[5].options.model;
if (nativeFollowed?.provider !== "openai-codex" || nativeFollowed?.id !== "gpt-6-astra") {
  throw new Error(`the build did not run the model the picker reported: ${JSON.stringify(nativeFollowed)}`);
}

// When that ordinary model is unavailable, the picker reports the refusal the
// next build enforces instead of claiming the branch keeps a recorded model.
registryModels.splice(registryModels.findIndex((model) => model.provider === "openai-codex" && model.id === "gpt-6-astra"), 1);
const refusalNoticeCount = notices.length;
uiSelections.push("Follow main (codex-native/gpt-6-astra)");
await command.handler("", nativeCtx);
const refusalNotices = notices.slice(refusalNoticeCount);
if (
  refusalNotices.length !== 1 ||
  refusalNotices[0].type !== "warning" ||
  !refusalNotices[0].message.includes("refuses to build") ||
  refusalNotices[0].message.includes("keeps the model its own session recorded")
) {
  throw new Error(`following an unavailable native main did not report the build refusal: ${JSON.stringify(refusalNotices)}`);
}
const refusedOffer = dispatch("signal: native follow refused");
const refusal = await refusedOffer.settlement.then(() => null, (error) => error);
if (!(refusal instanceof Error) || !refusal.message.includes("refuses to build")) {
  throw new Error(`the build did not refuse as the picker reported: ${String(refusal)}`);
}
if (globalThis.__fmSessions.length !== 6) throw new Error("a refused native follow still built a branch");
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
async function rebuild(reason, expected) {
  await fire("session_shutdown", {});
  await fire("session_start", {}, makeCtx());
  dispatch(`signal: ${reason}`);
  return settle(() => (globalThis.__fmSessions ?? []).length === expected, `${reason} branch build`);
}

// 1. No effort pin: the branch applies MAIN's own current effort explicitly,
// so a reopened conversation cannot restore the level it last ran under.
await fire("session_start", {}, makeCtx());
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

// 3. A session replacement applies the effort pin too, on the new branch
// conversation it starts.
await rebuild("effort pin replacement", 3);
if (globalThis.__fmSessions[2].options.thinkingLevel !== "low") {
  throw new Error(`the replacement build dropped the effort pin: ${globalThis.__fmSessions[2].options.thinkingLevel}`);
}
if (globalThis.__fmSessions[2].options.sessionManager.opened) {
  throw new Error("a session replacement continued the previous branch conversation");
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
  pass "the effort pin binds every branch build, and clearing it returns the branch to main's effort"
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

await fire("session_start", {}, makeCtx());
dispatch("signal: before main effort change");
await settle(() => (globalThis.__fmSessions ?? []).length === 1, "initial branch build");
const original = globalThis.__fmSessions[0];
if (original.options.thinkingLevel !== "medium") throw new Error("the unpinned branch did not start on main's effort");

// A mid-session effort change releases the live branch, so the next wake
// reopens the same conversation at main's new effort without waiting for a
// session replacement.
setMainThinkingLevel("high");
await fire("thinking_level_select", { level: "high", previousLevel: "medium" });
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
await fire("session_shutdown", {});
await fire("session_start", {}, makeCtx());
dispatch("signal: pinned effort");
await settle(() => (globalThis.__fmSessions ?? []).length === 3, "pinned effort branch build");
const pinned = globalThis.__fmSessions[2];
if (pinned.options.thinkingLevel !== "minimal") throw new Error("the pinned branch did not use its effort pin");

setMainThinkingLevel("high");
await fire("thinking_level_select", { level: "high", previousLevel: "minimal" });
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
await fire("session_start", {}, makeCtx());

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
await fire("session_start", {}, makeCtx());

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
// set from the model recorded by the most recent branch conversation.
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
await fire("session_start", {}, makeCtx());
const unusableOffer = dispatch("signal: unusable pin probe");
if (!unusableOffer.accepted) throw new Error("unusable-pin wake was not initially accepted");
const unusableFailure = await unusableOffer.settlement.then(
  () => null,
  (error) => error,
);
if (
  !(unusableFailure instanceof Error) ||
  !unusableFailure.message.includes("dynamic/extension-only") ||
  !unusableFailure.message.includes("supervision model pin")
) {
  throw new Error(`the rejected settlement did not name the unusable pin: ${String(unusableFailure)}`);
}
if (mainUserMessages.length !== 0) throw new Error("branch bypassed watcher-owned fallback delivery");
if ((globalThis.__fmSessions ?? []).length !== 0) throw new Error("an unusable pin must not build a branch session");

// An unparseable file is simply no pin, so supervision keeps working and the
// branch follows main's own model.
writeFileSync(`${home}/config/supervision-branch-model`, "not-a-model-reference\n");
await fire("session_shutdown", {});
await fire("session_start", {}, makeCtx());
dispatch("signal: unparseable pin probe");
await settle(() => (globalThis.__fmSessions ?? []).length === 1, "unparseable-pin branch build");
const unparseable = globalThis.__fmSessions[0].options.model;
if (unparseable?.provider !== "anthropic" || unparseable?.id !== "main-model") {
  throw new Error(`an unparseable pin must be treated as no pin and follow main: ${JSON.stringify(unparseable)}`);
}
// Even a registered native provider cannot be selected by the independent
// supervision session: its persistent native thread belongs to main.
registryModels.push({ provider: "codex-native", id: "gpt-6-astra" });
writeFileSync(`${home}/config/supervision-branch-model`, "codex-native/gpt-6-astra\n");
await fire("session_shutdown", {});
await fire("session_start", {}, makeCtx());
const nativeOffer = dispatch("signal: native branch pin refused");
const nativeFailure = await nativeOffer.settlement.then(() => null, (error) => error);
if (!(nativeFailure instanceof Error) || !nativeFailure.message.includes("ordinary Pi provider")) {
  throw new Error(`native branch pin was not explicitly refused: ${String(nativeFailure)}`);
}
if (globalThis.__fmSessions.length !== 1) throw new Error("native pin built a shared native branch");
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "an unusable model pin must reject to watcher delivery and an unparseable one must be no pin: $out"
  pass "an unusable model pin rejects to watcher fallback and an unparseable one is treated as no pin"
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

await fire("session_start", {});
if (!existsSync(`${home}/state/.lease-task-old`)) throw new Error("failed activation incorrectly committed lease cleanup");
const offer = dispatch("signal: retry activation");
if (!offer.accepted) throw new Error("later boundary did not retry failed activation");
// Activation runs as the accepted wake's first settlement step, so its lease
// cleanup is observable once that wake has reached the branch.
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "post-retry wake prompt");
if (existsSync(`${home}/state/.lease-task-old`)) throw new Error("replacement activation did not clean the prior branch lease");
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
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, home, mainEntries, outcomeScript, defaultSessionCtx }; })()`);
const { fire, dispatch, settle, home, mainEntries, outcomeScript, defaultSessionCtx } = globalThis.__t;
import { existsSync, writeFileSync } from "node:fs";

const summary = "Recovered the stored captain result after cold startup.";
const seq = Number(outcomeScript(["append", "--task", "cold-result", "--verdict", "captain", "--summary", summary]));
await fire("session_start", {}, defaultSessionCtx);
if (mainEntries.some((entry) => entry.customType === "fm-branch-visible-outcome")) {
  throw new Error("captain outcome was delivered before lock ownership");
}
if (dispatch("signal: before lock").accepted) throw new Error("branch accepted a wake before the lock existed");
if (existsSync(`${home}/state/.pi-branch-extension-loaded`)) {
  throw new Error("branch wrote its marker before owning the lock");
}
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
await fire("turn_end", {}, defaultSessionCtx);
const visible = mainEntries.filter((entry) => entry.customType === "fm-branch-visible-outcome");
if (visible.length !== 1 || visible[0].data.seq !== seq || visible[0].data.summary !== summary) {
  throw new Error(`post-lock turn_end did not recover the exact captain outcome: ${JSON.stringify(visible)}`);
}
if (outcomeScript(["unread"]) !== "") throw new Error("post-lock turn_end did not advance the outcome cursor");
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
const queuedOffer = dispatch("signal: queued wake");
if (!queuedOffer.accepted) throw new Error("queued wake was not accepted");
const queuedFailure = queuedOffer.settlement.then(
  () => null,
  (error) => error,
);
const entries = [{ type: "message", message: { role: "user", content: "queued mirror must stay undelivered" } }];
await fire("turn_end", {}, {
  sessionManager: { getSessionFile: () => `${home}/main.jsonl`, getEntries: () => entries },
});
unlinkSync(`${home}/state/.lock`);
releasePrompt();
const failure = await queuedFailure;
if (!(failure instanceof Error) || !failure.message.includes("no longer owns the fleet lock")) {
  throw new Error(`queued wake did not reject to watcher fallback: ${String(failure)}`);
}
if (mainUserMessages.length !== 0) throw new Error("branch bypassed watcher-owned fallback delivery");
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
await fire("turn_end", {}, {
  sessionManager: { getSessionFile: () => `${home}/old-main.jsonl`, getEntries: () => oldEntries },
});
await settle(() => globalThis.__fmMirrorStarted === true, "blocked old mirror delivery");
await fire("session_shutdown", {});
await fire("session_start", {});
const newEntries = [{ type: "message", message: { role: "user", content: "new generation mirror" } }];
await fire("turn_end", {}, {
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
await fire("turn_end", {}, ctx);
await fire("session_shutdown", {});

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
  settlement: Promise.resolve(),
  accept(settlement = Promise.resolve()) {
    offer.accepted = true;
    offer.settlement = settlement;
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
  cp "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$repo/.pi/extensions/lib/fm-native-contract.ts"
  cp "$ROOT/.pi/extensions/lib/fm-task-continuation.ts" "$repo/.pi/extensions/lib/fm-task-continuation.ts"
  cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$repo/.pi/extensions/lib/fm-async-exec.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-model-picker.ts" "$repo/.pi/extensions/lib/fm-branch-model-picker.ts"
  printf 'project=%s/projects/approved\nwindow=fm-window\n' "$home" > "$home/state/task-a.meta"
  LIB="$repo/.pi/extensions/lib/fm-branch-dispatch.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" GRANT="$ROOT/bin/fm-wake-grant.sh" \
    node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { syncBuiltinESMExports } from "node:module";
import fs, { mkdirSync, readFileSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";

const originalReadFileSync = fs.readFileSync;
let countedStatusPath = "";
let countedStatusReads = 0;
fs.readFileSync = function(path, ...args) {
  if (String(path) === countedStatusPath) countedStatusReads += 1;
  return originalReadFileSync.call(this, path, ...args);
};
syncBuiltinESMExports();

const { activateEligibleRowsOwner, scopeForUnreadWake, scopeForUnreadWakeWithLifecycle, dispositionForWakeTrigger, writeEligibleRowsSnapshot, releaseEligibleRowsSnapshot, BRANCH_ELIGIBLE_ROWS_FILE } =
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

// A needs-decision signal row is a main-only class too, marked by payload
// rather than kind (docs/pi-supervision-branch.md "Autonomy"): it is excluded
// from eligibleSeqs and named in needsDecisionKeys. A later stale row under the
// task's window alias remains individually claimable, while task-identity
// precedence keeps its complete wake on main until the decision row is read.
writeFileSync(
  `${state}/.wake-queue`,
  [
    "1\t1\tsignal\ttask-a.status\tneeds-decision: task-a.status",
    "1\t2\tstale\tfm-window\tstale: later routine reminder",
  ].join("\n"),
);
const needsDecisionMixed = scopeForUnreadWake(state, false);
if (!needsDecisionMixed.eligible) {
  throw new Error(`an unread needs-decision row must not erase a later stale row: ${JSON.stringify(needsDecisionMixed)}`);
}
if (needsDecisionMixed.eligibleSeqs.join(",") !== "2") {
  throw new Error(`a needs-decision row must be excluded from eligibleSeqs: ${JSON.stringify(needsDecisionMixed)}`);
}
if (needsDecisionMixed.needsDecisionKeys.join(",") !== "task-a.status") {
  throw new Error(`needsDecisionKeys must name the excluded row: ${JSON.stringify(needsDecisionMixed)}`);
}
if (needsDecisionMixed.taskByWakeKey["task-a.status"] !== "task-a" ||
  needsDecisionMixed.taskByWakeKey["fm-window"] !== "task-a") {
  throw new Error(`status and stale aliases did not resolve to one task: ${JSON.stringify(needsDecisionMixed)}`);
}
if (needsDecisionMixed.corrupted) {
  throw new Error(`a needs-decision row must not read as corrupted: ${JSON.stringify(needsDecisionMixed)}`);
}

// A queue holding only a needs-decision row is ordinary main-only absence,
// exactly like a queue holding only a check row.
writeFileSync(`${state}/.wake-queue`, "1\t1\tsignal\ttask-a.status\tneeds-decision: task-a.status");
const needsDecisionOnly = scopeForUnreadWake(state, false);
if (needsDecisionOnly.eligible || needsDecisionOnly.eligibleSeqs.length !== 0 || needsDecisionOnly.corrupted) {
  throw new Error(`a needs-decision-only queue must be ordinary main-only absence: ${JSON.stringify(needsDecisionOnly)}`);
}

mkdirSync(`${process.env.FM_HOME}/data`, { recursive: true });
writeFileSync(`${process.env.FM_HOME}/.tasks.toml`, 'backend="markdown"\n[markdown]\npath="data/backlog.md"\n');
writeFileSync(`${process.env.FM_HOME}/data/backlog.md`, "## In flight\n\n## Queued\n\n## Done\n");
let command = spawnSync(`${process.env.FM_ROOT_OVERRIDE}/bin/fm-tasks-axi.sh`,
  ["add", "task-a", "Keep the accepted behavior unchanged", "--kind", "ship", "--body", "Original scope.", "--start"],
  { encoding: "utf8", env: { ...process.env, FM_HOME: process.env.FM_HOME } });
if (command.status !== 0) throw new Error(`task fixture failed: ${command.stderr}`);
mkdirSync(`${process.env.FM_HOME}/data/task-a`, { recursive: true });
writeFileSync(`${process.env.FM_HOME}/data/task-a/brief.md`, "Keep the accepted behavior unchanged.\n");
command = spawnSync(`${process.env.FM_ROOT_OVERRIDE}/bin/fm-task-state.sh`, ["progress", "task-a"],
  { encoding: "utf8", env: { ...process.env, FM_HOME: process.env.FM_HOME } });
if (command.status !== 0) throw new Error(`progress fixture read failed: ${command.stderr}`);
const progress = JSON.parse(command.stdout);
command = spawnSync(`${process.env.FM_ROOT_OVERRIDE}/bin/fm-task-state.sh`, ["update-progress", "task-a",
  "--expected-token", progress.record_token, "--progress", JSON.stringify({ acceptance: "The existing contract passes",
    current_state: "Validation requested a review decision", remaining_gap: "The finding is unresolved",
    next_step: "Classify the finding against the accepted intent" })],
  { encoding: "utf8", env: { ...process.env, FM_HOME: process.env.FM_HOME, FM_SUPERVISION_ACTOR: "main" } });
if (command.status !== 0) throw new Error(`progress fixture update failed: ${command.stderr}`);

writeFileSync(`${state}/task-a.status`, "needs-decision [key=product-scope]: choose a broader product contract\n");
const genuineDecision = await scopeForUnreadWakeWithLifecycle(process.env.FM_ROOT_OVERRIDE, process.env.FM_HOME, state, false);
if (genuineDecision.reviewableDecisionTasks.length !== 0 || genuineDecision.scope.eligible ||
    genuineDecision.scope.needsDecisionKeys.join(",") !== "task-a.status") {
  throw new Error(`compact fields moved a genuine decision away from MAIN: ${JSON.stringify(genuineDecision)}`);
}

const findingPath = `${process.env.FM_HOME}/data/task-a/nm-run-review-findings.txt`;
writeFileSync(findingPath, "NM-1: restore the already accepted behavior\n");
writeFileSync(`${state}/task-a.status`, `needs-decision [key=nm-run-review]: ask-user findings=NM-1 file=${findingPath}\n`);
const reviewableDecision = await scopeForUnreadWakeWithLifecycle(process.env.FM_ROOT_OVERRIDE, process.env.FM_HOME, state, false);
if (reviewableDecision.reviewableDecisionTasks.join(",") !== "task-a" || !reviewableDecision.scope.eligible ||
    reviewableDecision.scope.eligibleSeqs.join(",") !== "1" || reviewableDecision.scope.needsDecisionKeys.length !== 0) {
  throw new Error(`an exact no-mistakes decision snapshot did not reach bounded branch review: ${JSON.stringify(reviewableDecision)}`);
}

// A captain-held task's bounded stale recheck is itself a decision wake. It is
// excluded while an unrelated routine row remains independently branch-owned.
writeFileSync(`${state}/task-a.status`, "captain-held [key=route]: awaiting the captain\n \t \n");
writeFileSync(
  `${state}/.wake-queue`,
  [
    "1\t1\tstale\tfm-window\tstale: fm-window (awaiting the captain)",
    "1\t2\tsignal\ttask-a.status\tsignal: routine follow-up",
  ].join("\n"),
);
const captainHeldMixed = scopeForUnreadWake(state, false);
if (!captainHeldMixed.eligible || captainHeldMixed.eligibleSeqs.join(",") !== "2") {
  throw new Error(`a captain-held stale row was offered to the branch: ${JSON.stringify(captainHeldMixed)}`);
}
if (captainHeldMixed.needsDecisionKeys.join(",") !== "fm-window") {
  throw new Error(`the captain-held stale key was not marked main-owned: ${JSON.stringify(captainHeldMixed)}`);
}

writeFileSync(`${state}/task-a.status`, "captain-held [key=route]: awaiting a second captain reminder\n \n");
writeFileSync(
  `${state}/.wake-queue`,
  [
    "1\t1\tstale\tfm-window\tstale: fm-window (first reminder)",
    "1\t2\tstale\tfm-window\tstale: fm-window (second reminder)",
    "1\t3\tsignal\ttask-a.status\tsignal: routine follow-up",
  ].join("\n"),
);
countedStatusPath = `${state}/task-a.status`;
countedStatusReads = 0;
const repeatedCaptainHeld = scopeForUnreadWake(state, false);
if (countedStatusReads !== 1) {
  throw new Error(`one status was read ${countedStatusReads} times for repeated stale rows`);
}
if (!repeatedCaptainHeld.eligible || repeatedCaptainHeld.eligibleSeqs.join(",") !== "3" ||
  repeatedCaptainHeld.needsDecisionKeys.join(",") !== "fm-window,fm-window") {
  throw new Error(`repeated stale reminders changed classification: ${JSON.stringify(repeatedCaptainHeld)}`);
}
const repeatedCaptainHeldNextScan = scopeForUnreadWake(state, false);
if (countedStatusReads !== 1 || repeatedCaptainHeldNextScan.needsDecisionKeys.join(",") !== "fm-window,fm-window") {
  throw new Error(`an unchanged status was not reused across scans: reads=${countedStatusReads} scope=${JSON.stringify(repeatedCaptainHeldNextScan)}`);
}
writeFileSync(`${state}/task-a.status`, "captain-held [key=route]: awaiting the captain\nworking: resumed after answer\n");
const changedCaptainHeld = scopeForUnreadWake(state, false);
if (countedStatusReads !== 2 || changedCaptainHeld.eligibleSeqs.join(",") !== "1,2,3" ||
  changedCaptainHeld.needsDecisionKeys.length !== 0) {
  throw new Error(`a changed status did not invalidate its cached decision: reads=${countedStatusReads} scope=${JSON.stringify(changedCaptainHeld)}`);
}
countedStatusPath = "";
writeFileSync(
  `${state}/.wake-queue`,
  [
    "1\t1\tstale\tfm-window\tstale: fm-window (awaiting the captain)",
    "1\t2\tsignal\ttask-a.status\tsignal: routine follow-up",
  ].join("\n"),
);

// A later unrelated status does not mask a still-open durable decision. The
// stale row remains main-owned while the routine signal stays branch-owned.
writeFileSync(
  `${state}/task-a.status`,
  "needs-decision [key=cleanup]: choose destructive cleanup\nworking: routine follow-up\n",
);
const openDecisionMixed = scopeForUnreadWake(state, false);
if (!openDecisionMixed.eligible || openDecisionMixed.eligibleSeqs.join(",") !== "2") {
  throw new Error(`an open-decision stale row was offered to the branch: ${JSON.stringify(openDecisionMixed)}`);
}
if (openDecisionMixed.needsDecisionKeys.join(",") !== "fm-window") {
  throw new Error(`the open-decision stale key was not marked main-owned: ${JSON.stringify(openDecisionMixed)}`);
}

process.env.FM_CLASSIFY_RESOLVE_VERB = "answered";
writeFileSync(
  `${state}/task-a.status`,
  "needs-decision [key=cleanup]: choose destructive cleanup\nanswered [key=cleanup]: remove generated files\n",
);
const customResolved = scopeForUnreadWake(state, false);
if (!customResolved.eligible || customResolved.eligibleSeqs.slice().sort().join(",") !== "1,2" ||
  customResolved.needsDecisionKeys.length !== 0) {
  throw new Error(`a custom resolution verb left the stale decision open: ${JSON.stringify(customResolved)}`);
}

process.env.FM_CLASSIFY_CAPTAIN_HELD_VERB = "awaiting-captain";
writeFileSync(`${state}/task-a.status`, "awaiting-captain [key=cleanup]: awaiting the captain\n");
const customHeld = scopeForUnreadWake(state, false);
if (!customHeld.eligible || customHeld.eligibleSeqs.join(",") !== "2" ||
  customHeld.needsDecisionKeys.join(",") !== "fm-window") {
  throw new Error(`a custom captain-held verb was offered to the branch: ${JSON.stringify(customHeld)}`);
}
delete process.env.FM_CLASSIFY_RESOLVE_VERB;
delete process.env.FM_CLASSIFY_CAPTAIN_HELD_VERB;

process.env.FM_CLASSIFY_RESERVED_KEY_PREFIXES = "secret-";
writeFileSync(
  `${state}/task-a.status`,
  "needs-decision [key=review-x]: choose destructive cleanup\nworking: routine follow-up\n",
);
const customReservedPrefixes = scopeForUnreadWake(state, false);
if (!customReservedPrefixes.eligible || customReservedPrefixes.eligibleSeqs.join(",") !== "2" ||
  customReservedPrefixes.needsDecisionKeys.join(",") !== "fm-window") {
  throw new Error(`configured reserved prefixes lost an open stale decision: ${JSON.stringify(customReservedPrefixes)}`);
}
delete process.env.FM_CLASSIFY_RESERVED_KEY_PREFIXES;

writeFileSync(`${state}/symlink-target.status`, "needs-decision: external choice\n");
unlinkSync(`${state}/task-a.status`);
symlinkSync(`${state}/symlink-target.status`, `${state}/task-a.status`);
const symlinkedStatus = scopeForUnreadWake(state, false);
if (!symlinkedStatus.corrupted || symlinkedStatus.eligible || symlinkedStatus.needsDecisionKeys.length !== 0) {
  throw new Error(`a symlinked status file influenced stale routing: ${JSON.stringify(symlinkedStatus)}`);
}
unlinkSync(`${state}/task-a.status`);
writeFileSync(`${state}/task-a.status`, "working: routine work\n");

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

if (!(await activateEligibleRowsOwner(state, process.env.GRANT, process.pid, "fixture"))) {
  throw new Error("branch owner activation failed");
}
if ((await writeEligibleRowsSnapshot(state, mixed.eligibleSeqs, process.env.GRANT, "fixture")) !== "published") {
  throw new Error("snapshot write reported failure");
}
const snapshot = readFileSync(`${state}/${BRANCH_ELIGIBLE_ROWS_FILE}`, "utf8").trim().split("\n");
if (snapshot.join(",") !== "2,3") throw new Error(`snapshot did not name exactly the eligible rows: ${snapshot}`);

// An empty eligible set is refused rather than clearing the snapshot to
// nothing - a caller must never overwrite a live snapshot with an empty one.
if ((await writeEligibleRowsSnapshot(state, [], process.env.GRANT, "fixture")) !== "error") {
  throw new Error("an empty eligible set must not be written");
}
if (!(await releaseEligibleRowsSnapshot(state, process.env.GRANT, "fixture"))) throw new Error("snapshot release failed");
writeFileSync(`${state}/.main-eligible-rows`, "2\n");
if ((await writeEligibleRowsSnapshot(state, ["2"], process.env.GRANT, "fixture")) !== "main-owned") {
  throw new Error("a row already claimed by main was not reported as main-owned");
}
unlinkSync(`${state}/.main-eligible-rows`);

// A MAIN claim is row-local: old claimed rows cannot poison an unrelated
// new task's grant. The same task/endpoint trigger remains conservatively MAIN.
const { strict: assert } = await import("node:assert");
writeFileSync(`${state}/task-b.meta`, `project=${project}\nwindow=fm-b\n`);
const mixedClaims = "1\t1\tsignal\ttask-a.status\told\n1\t2\tsignal\ttask-b.status\tnew\n";
writeFileSync(`${state}/.wake-queue`, mixedClaims);
writeFileSync(`${state}/.main-eligible-rows`, "1\n");
const claimed = scopeForUnreadWake(state, false);
assert.deepEqual(claimed.eligibleSeqs, ["2"]);
assert.deepEqual(claimed.eligibleTasks, ["task-b"]);
assert.deepEqual(claimed.taskBySeq, {"2":"task-b"});
assert.equal(dispositionForWakeTrigger("signal: task-b.status", claimed).eligible, true);
for (const trigger of ["signal: task-a.status", "stale: fm-window", "signal: task-b.status task-a.status"]) {
  assert.equal(dispositionForWakeTrigger(trigger, claimed).reason, "main-owned-trigger");
}
writeFileSync(`${state}/.wake-queue`, mixedClaims + "1\t3\theartbeat\theartbeat\theartbeat\n1\t4\tcheck\tcheck-key\tcheck: exact-check\n");
writeFileSync(`${state}/.main-eligible-rows`, "1\n3\n4\n");
const claimedKinds = scopeForUnreadWake(state, true);
assert.deepEqual(claimedKinds.eligibleSeqs, ["2"]);
assert.equal(dispositionForWakeTrigger("heartbeat", claimedKinds).reason, "main-owned-trigger");
assert.equal(dispositionForWakeTrigger("check: exact-check", claimedKinds).reason, "main-owned-trigger");
writeFileSync(`${state}/.wake-queue`, mixedClaims);
// Absent is the supported empty record. Present empty, duplicate, malformed,
// symlink and directory records never grant speculative ownership.
for (const raw of ["", "1\n1\n", "1\n\n", "1\r\n", "bad\n"]) {
  writeFileSync(`${state}/.main-eligible-rows`, raw);
  assert.equal(scopeForUnreadWake(state, false).corrupted, true, JSON.stringify(raw));
}
unlinkSync(`${state}/.main-eligible-rows`);
assert.deepEqual(scopeForUnreadWake(state, false).eligibleSeqs, ["1", "2"]);
symlinkSync(`${state}/missing-claim`, `${state}/.main-eligible-rows`);
assert.equal(scopeForUnreadWake(state, false).corrupted, true);
unlinkSync(`${state}/.main-eligible-rows`);
fs.mkdirSync(`${state}/.main-eligible-rows`);
assert.equal(scopeForUnreadWake(state, false).corrupted, true);
fs.rmdirSync(`${state}/.main-eligible-rows`);
// A concurrent replacement during the read is uncertain, never a partial set.
writeFileSync(`${state}/.main-eligible-rows`, "1\n");
fs.readFileSync = function(path, ...args) {
  const value = originalReadFileSync.call(this, path, ...args);
  if (String(path) === `${state}/.main-eligible-rows`) {
    writeFileSync(`${state}/replacement-claim`, "1\n2\n");
    fs.renameSync(`${state}/replacement-claim`, `${state}/.main-eligible-rows`);
  }
  return value;
};
syncBuiltinESMExports();
assert.equal(scopeForUnreadWake(state, false).corrupted, true);
fs.readFileSync = originalReadFileSync; syncBuiltinESMExports();
// Claim 2 after the scan: final locked publication still refuses the entire
// previously eligible set. No partial grant and no queue mutation.
assert.equal(await writeEligibleRowsSnapshot(state, claimed.eligibleSeqs, process.env.GRANT, "fixture"), "main-owned");
assert.equal(fs.existsSync(`${state}/${BRANCH_ELIGIBLE_ROWS_FILE}`), false);
assert.equal(readFileSync(`${state}/.wake-queue`, "utf8"), mixedClaims);
writeFileSync(`${state}/.main-eligible-rows`, "1\n");
assert.equal(await writeEligibleRowsSnapshot(state, claimed.eligibleSeqs, process.env.GRANT, "fixture"), "published");
assert.equal(readFileSync(`${state}/${BRANCH_ELIGIBLE_ROWS_FILE}`, "utf8"), "2\n");
const env = {...process.env, FM_STATE_OVERRIDE:state, FM_SUPERVISION_ACTOR:"branch"};
const drainScript = process.env.GRANT.replace(/fm-wake-grant.sh$/, "fm-wake-drain.sh");
const drain = spawnSync("bash", [drainScript], {env, encoding:"utf8"});
assert.equal(drain.status, 0, drain.stderr);
assert.ok(drain.stdout.includes("\t2\tsignal\ttask-b.status\t"));
assert.ok(!drain.stdout.includes("\t1\tsignal\ttask-a.status\t"));
const ack = drain.stderr.match(/--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)/);
assert.ok(ack, drain.stderr);
assert.equal(ack[1], "2");
const consumed = spawnSync("bash", [drainScript, "--ack-through", ack[1], "--recovery-generation", ack[2]], {env, encoding:"utf8"});
assert.equal(consumed.status, 0, consumed.stderr);
assert.equal(readFileSync(`${state}/.wake-queue`, "utf8"), mixedClaims.split("\n")[0]+"\n");
assert.equal(readFileSync(`${state}/.main-eligible-rows`, "utf8"), "1\n");
assert.equal(await releaseEligibleRowsSnapshot(state, process.env.GRANT, "fixture"), true);
unlinkSync(`${state}/.main-eligible-rows`);

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

  // A retired task's structurally valid row is main-only evidence. It stays
  // durable while the heartbeat takes the complete safe subset.
writeFileSync(
  `${state}/.wake-queue`,
  [
    "1\t1\theartbeat\theartbeat\theartbeat",
    "1\t2\tsignal\tno-such-task.status\tsignal: no-such-task.status",
  ].join("\n"),
);
const heartbeatUnresolvable = scopeForUnreadWake(state, true);
  if (!heartbeatUnresolvable.eligible || heartbeatUnresolvable.corrupted ||
    heartbeatUnresolvable.eligibleSeqs.join(",") !== "1" ||
    heartbeatUnresolvable.unresolvedRows.map((row) => row.seq).join(",") !== "2") {
    throw new Error(`an unresolved row polluted the heartbeat safe subset: ${JSON.stringify(heartbeatUnresolvable)}`);
}

  // The retained two-row counterexample: the old task stays main-only while
  // the unrelated live task remains branch-eligible.
  writeFileSync(
    `${state}/.wake-queue`,
    [
      "1\t21903\tsignal\tretired-task.turn-ended\tsignal: retired-task.turn-ended",
      "1\t21914\tstale\tfm-window\tstale: fm-window",
    ].join("\n"),
  );
  const retiredAndLive = scopeForUnreadWake(state, false);
  if (retiredAndLive.corrupted || retiredAndLive.eligibleSeqs.join(",") !== "21914" ||
    retiredAndLive.unresolvedRows.map((row) => row.seq).join(",") !== "21903") {
    throw new Error(`the retained old-task/live-task counterexample did not isolate the old row: ${JSON.stringify(retiredAndLive)}`);
  }
  writeFileSync(`${state}/.wake-queue`, "1\t21903\tsignal\tretired-task.turn-ended\tsignal: retired-task.turn-ended");
  const retiredOnly = scopeForUnreadWake(state, false);
  if (retiredOnly.eligible || retiredOnly.corrupted || retiredOnly.unresolvedRows.length !== 1) {
    throw new Error(`an old task alone was not preserved as main-only evidence: ${JSON.stringify(retiredOnly)}`);
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

test_branch_dispatch_routes_only_identity_bound_ida_results() {
  local repo home out status
  repo="$TMP_ROOT/dispatch-ida-root"
  home="$TMP_ROOT/dispatch-ida-home"
  mkdir -p "$repo/.pi/extensions/lib" "$home/state/procevent-inbox" \
    "$home/state/remote-tasks/ida-task" "$home/projects/approved"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$repo/.pi/extensions/lib/fm-async-exec.ts"
  LIB="$repo/.pi/extensions/lib/fm-branch-dispatch.ts" FM_HOME="$home" \
    node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
import { chmodSync, readFileSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { scopeForUnreadWake } = await import(pathToFileURL(process.env.LIB).href);
const state = `${process.env.FM_HOME}/state`;
const task = "ida-task";
const source = `ida-${task}`;
const marker = "firstmate:ida-task:0123456789abcdef";
const privateWrite = (path, content) => {
  writeFileSync(path, content, { mode: 0o600 });
  chmodSync(path, 0o600);
};
const observation = (localTask = task) => JSON.stringify({
  schema: "fm-ida-observation.v1",
  task_id: localTask,
  provider: "ida",
  region: "sg",
  kind: "session",
  session_marker: marker,
  session_id: "70001",
  task_id_remote: "80001",
  terminal: true,
  ambiguous: false,
  result_availability: "available",
  result_kind: "text",
  answer: "verified result",
  error_class: null,
});
const writeCapture = (seq, body = observation(), adapter = "ida\n") => {
  privateWrite(`${state}/procevent-inbox/${source}.${seq}.result`, body);
  privateWrite(`${state}/procevent-inbox/${source}.${seq}.adapter`, adapter);
};
const writeMeta = (provider = "ida") => privateWrite(
  `${state}/${task}.meta`,
  `kind=scout\nexecutor=remote-agent\nprovider=${provider}\ntask_type=research\nremote_state=${state}/remote-tasks/${task}\n`,
);
writeMeta();
privateWrite(`${state}/task-a.meta`, `project=${process.env.FM_HOME}/projects/approved\nwindow=fm-window\n`);
privateWrite(`${state}/remote-tasks/${task}/state.json`, JSON.stringify({
  schema: "fm-remote-agent-task-state.v1",
  task_id: task,
  executor: "remote-agent",
  provider: "ida",
  task_type: "research",
  phase: "terminal-success",
  revision: 2,
  instruction_file: `${process.env.FM_HOME}/data/${task}/instructions.txt`,
  instruction_sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  outcome: "succeeded",
  error_class: null,
  waiter: "terminal",
  result_availability: "available",
  result_path: `${state}/remote-tasks/${task}/artifacts/observation.json`,
  report_path: `${process.env.FM_HOME}/data/${task}/report.md`,
  provider_state: { region: "sg", identity: "user", session_marker: marker, session_id: "70001", task_id: "80001" },
}));
writeCapture("1");
writeCapture("2");
privateWrite(`${state}/procevent-inbox/${source}.1.handled`, "handled\n");

// Out-of-order captures, a repeated capture notification, and a runner-applied
// result all remain task-scoped branch work. An unrelated check remains main-
// owned while an ordinary signal remains independently eligible.
privateWrite(`${state}/.wake-queue`, [
  `1\t1\tcheck\tprocevent:${source}:2\tcheck: procevent ida ${source} 2`,
  `1\t2\tcheck\tprocevent:${source}:1\tcheck: procevent ida ${source} 1`,
  `1\t3\tcheck\tprocevent:${source}:2\tcheck: procevent ida ${source} 2`,
  "1\t4\tsignal\ttask-a.status\tsignal: task-a.status",
  "1\t5\tcheck\tx-inbox\tcheck: pending x mention",
].join("\n") + "\n");
const mixed = scopeForUnreadWake(state, false);
if (mixed.eligibleSeqs.join(",") !== "1,2,3,4") {
  throw new Error(`valid iDA captures or the unrelated signal were not scoped exactly: ${JSON.stringify(mixed)}`);
}
if (JSON.stringify([...mixed.eligibleTasks].sort()) !== JSON.stringify(["ida-task", "task-a"])) {
  throw new Error(`iDA result resolved to the wrong task scope: ${JSON.stringify(mixed)}`);
}
if (mixed.eligibleIdaResults.map((result) => result.trigger).join("|") !==
    `check: procevent ida ${source} 2|check: procevent ida ${source} 1|check: procevent ida ${source} 2`) {
  throw new Error(`iDA trigger identity was not preserved exactly: ${JSON.stringify(mixed)}`);
}

const assertMainFallback = (label, row) => {
  privateWrite(`${state}/.wake-queue`, `${row}\n1\t9\tsignal\ttask-a.status\tsignal: task-a.status\n`);
  const scope = scopeForUnreadWake(state, false);
  if (scope.corrupted || scope.eligibleSeqs.join(",") !== "9" || scope.eligibleIdaResults.length !== 0) {
    throw new Error(`${label} did not stay on the safe main path: ${JSON.stringify(scope)}`);
  }
};

assertMainFallback("mismatched queue key", `1\t1\tcheck\tprocevent:${source}:9\tcheck: procevent ida ${source} 1`);
assertMainFallback("mismatched source task", `1\t1\tcheck\tprocevent:ida-other:1\tcheck: procevent ida ida-other 1`);
assertMainFallback("path-unsafe task", "1\t1\tcheck\tprocevent:ida-../escape:1\tcheck: procevent ida ida-../escape 1");

writeMeta("aime");
assertMainFallback("mismatched metadata provider", `1\t1\tcheck\tprocevent:${source}:1\tcheck: procevent ida ${source} 1`);
writeMeta();

writeCapture("1", observation("other-task"));
assertMainFallback("mismatched result task", `1\t1\tcheck\tprocevent:${source}:1\tcheck: procevent ida ${source} 1`);
writeCapture("1");

writeCapture("1", observation(), "aime\n");
assertMainFallback("mismatched captured adapter", `1\t1\tcheck\tprocevent:${source}:1\tcheck: procevent ida ${source} 1`);
writeCapture("1");

unlinkSync(`${state}/procevent-inbox/${source}.1.result`);
symlinkSync(`${state}/procevent-inbox/${source}.2.result`, `${state}/procevent-inbox/${source}.1.result`);
assertMainFallback("symlinked captured result", `1\t1\tcheck\tprocevent:${source}:1\tcheck: procevent ida ${source} 1`);
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "only exact task-scoped iDA result identities may enter branch supervision: $out"
  pass "identity-bound iDA results route to the branch while malformed or mismatched notifications stay on main"
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
  local package_dir package_version fixture out status
  package_dir=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
  if [ ! -f "$package_dir/package.json" ]; then
    echo "skip: installed @earendil-works/pi-coding-agent package not found"
    return
  fi
  # This case compares the extension's own renderers against Pi's stock
  # rendering, so its verdict is only meaningful against the vendor contract
  # those renderers target: since Pi 0.84.4 the stock renderer no longer
  # supplies an implicit reset at multiline boundaries, and the extension
  # emits that reset itself. An older installed Pi still supplies it, so the
  # two legitimately differ there and a comparison would report a defect that
  # is really a version skew. Name the version and skip rather than degrade
  # quietly; a package whose version cannot be read at all is still a failure.
  package_version=$(node -p 'require(process.argv[1]).version || ""' "$package_dir/package.json" 2>/dev/null || printf '')
  [ -n "$package_version" ] \
    || fail "installed @earendil-works/pi-coding-agent has no readable version at $package_dir"
  if ! pi_version_at_least "$package_version" "$PI_STOCK_RENDER_FLOOR"; then
    echo "skip: installed Pi $package_version predates the stock renderer contract $PI_STOCK_RENDER_FLOOR this case compares against"
    return
  fi
  fixture="$TMP_ROOT/stock-render-consumers"
  mkdir -p "$fixture/.pi/extensions/lib" "$fixture/node_modules/@earendil-works"
  cp "$EXT" "$fixture/.pi/extensions/fm-branch-supervision.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$fixture/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$fixture/.pi/extensions/lib/fm-native-contract.ts"
  cp "$ROOT/.pi/extensions/lib/fm-task-continuation.ts" "$fixture/.pi/extensions/lib/fm-task-continuation.ts"
  cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$fixture/.pi/extensions/lib/fm-async-exec.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-model-picker.ts" "$fixture/.pi/extensions/lib/fm-branch-model-picker.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$fixture/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$fixture/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/.pi/extensions/lib/fm-feishu-native-channel.ts" "$fixture/.pi/extensions/lib/fm-feishu-native-channel.ts"
  mkdir -p "$fixture/bin"
  cp "$ROOT/bin/fm-short-notification.mjs" "$fixture/bin/fm-short-notification.mjs"
  cp "$ROOT/bin/fm-feishu-state.mjs" "$fixture/bin/fm-feishu-state.mjs"
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

# The delivery path runs on Pi's single JS thread, so a delivery that blocks
# it is a delivery the captain sees as a frozen TUI. These three cover what
# moving that work off the thread must not cost: responsiveness during a
# delivery, and the ordering, exactly-once, and cancellation guarantees that
# the single thread used to provide for free.
test_delivery_keeps_the_event_loop_live_and_ordered() {
  local repo home out status
  repo="$TMP_ROOT/delivery-responsiveness-root"
  home="$TMP_ROOT/delivery-responsiveness-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, outcomeScript, sentToMain, mainEntries, defaultSessionCtx }; })()`);
const { fire, dispatch, settle, outcomeScript, sentToMain, mainEntries, defaultSessionCtx } = globalThis.__t;

await fire("session_start", {}, defaultSessionCtx);
let finishWakePrompt;
globalThis.__fmOnBranchPrompt = () => new Promise((resolve) => { finishWakePrompt = resolve; });
const offer = dispatch("signal: branch-driver working");
if (!offer.accepted) throw new Error("branch did not accept the wake offer");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "branch wake prompt");
const report = globalThis.__fmSessions[0].options.customTools.find((tool) => tool.name === "fm_branch_report");

// A repeating timer is the event loop's own liveness: it cannot tick while
// the single JS thread is blocked, which is exactly what the TUI's repaint
// and key echo cannot do either. Ticks observed WHILE one outcome is being
// delivered are therefore the responsiveness this delivery preserves.
function loopProbe(intervalMs) {
  let ticks = 0;
  let worstGapMs = 0;
  let last = process.hrtime.bigint();
  const timer = setInterval(() => {
    const now = process.hrtime.bigint();
    const gap = Number(now - last) / 1e6;
    if (gap > worstGapMs) worstGapMs = gap;
    last = now;
    ticks += 1;
  }, intervalMs);
  return {
    reset() { ticks = 0; worstGapMs = 0; last = process.hrtime.bigint(); },
    stop() { clearInterval(timer); },
    get ticks() { return ticks; },
    get worstGapMs() { return worstGapMs; },
  };
}

const probe = loopProbe(5);
await new Promise((resolve) => setTimeout(resolve, 40));
probe.reset();
const idleStart = process.hrtime.bigint();
await new Promise((resolve) => setTimeout(resolve, 120));
const idleWallMs = Number(process.hrtime.bigint() - idleStart) / 1e6;
const idleWorstGapMs = probe.worstGapMs;

async function timedDelivery(callId, params) {
  probe.reset();
  const started = process.hrtime.bigint();
  const result = await report.execute(callId, params, undefined, undefined, {});
  const wallMs = Number(process.hrtime.bigint() - started) / 1e6;
  return { result, wallMs, ticks: probe.ticks, worstGapMs: probe.worstGapMs };
}

const routine = await timedDelivery("live-routine", { task: "branch-driver", verdict: "routine", summary: "routine outcome during a live loop" });
if (routine.result.isError) throw new Error(`routine delivery failed: ${JSON.stringify(routine.result)}`);
const captain = await timedDelivery("live-captain", { task: "branch-driver", verdict: "captain", summary: "captain outcome during a live loop" });
if (captain.result.isError) throw new Error(`captain delivery failed: ${JSON.stringify(captain.result)}`);
probe.stop();

// Two independent signals, so neither a fast machine nor a slow one can make
// this vacuous. First: the loop must actually run during the delivery. A
// delivery built on synchronous subprocesses ticks zero times no matter how
// fast the host is, because nothing else can run at all.
for (const [label, measured] of [["routine", routine], ["captain", captain]]) {
  if (measured.ticks < 4) {
    throw new Error(`${label} delivery blocked the event loop: ${measured.ticks} ticks in ${measured.wallMs.toFixed(1)} ms`);
  }
  // Second: the longest single stall must be a MINORITY of the delivery it
  // happens inside. Stated as a fraction rather than a millisecond budget on
  // purpose - a loaded machine that descheduled this process would inflate an
  // absolute budget into a false failure, while it inflates the delivery's own
  // wall time too, so the fraction stays meaningful. A delivery built on
  // synchronous subprocesses sits near 1.0 here whatever the load.
  const stallBudgetMs = Math.max(measured.wallMs * 0.5, idleWorstGapMs * 4);
  if (measured.worstGapMs > stallBudgetMs) {
    throw new Error(
      `${label} delivery stalled the event loop for ${measured.worstGapMs.toFixed(1)} ms of its own ${measured.wallMs.toFixed(1)} ms (budget ${stallBudgetMs.toFixed(1)} ms, idle jitter ${idleWorstGapMs.toFixed(1)} ms over ${idleWallMs.toFixed(0)} ms)`,
    );
  }
}

// Interleaving: six outcomes reported without waiting for each other must
// still reach the store and main in sequence order, each exactly once. The
// captain rows also prove the visible entries land in the same order.
const many = await Promise.all(
  Array.from({ length: 6 }, (_, index) => report.execute(
    `interleaved-${index}`,
    {
      task: "branch-driver",
      verdict: index % 2 === 0 ? "routine" : "captain",
      summary: `interleaved outcome ${index}`,
    },
    undefined,
    undefined,
    {},
  )),
);
finishWakePrompt();
await offer.settlement;
for (const [index, result] of many.entries()) {
  if (result.isError) throw new Error(`interleaved delivery ${index} failed: ${JSON.stringify(result)}`);
}

const stored = outcomeScript(["list", "--recent", "50"]).split("\n").filter(Boolean).map((line) => JSON.parse(line));
const interleaved = stored.filter((row) => row.summary.startsWith("interleaved outcome "));
if (interleaved.length !== 6) {
  throw new Error(`interleaved deliveries did not store exactly six rows: ${JSON.stringify(interleaved.map((row) => row.summary))}`);
}
const seqs = interleaved.map((row) => row.seq);
if (seqs.slice().sort((a, b) => a - b).join(",") !== seqs.join(",")) {
  throw new Error(`stored sequences are not monotonic: ${seqs}`);
}
if (new Set(seqs).size !== seqs.length) throw new Error(`a sequence was reused: ${seqs}`);

const deliveredRoutine = sentToMain
  .filter((sent) => sent.message.customType === "fm-branch-merge" && sent.message.content.includes("interleaved outcome "))
  .map((sent) => sent.message.content);
const routineSummaries = interleaved.filter((row) => row.verdict === "routine").map((row) => `⛵ branch-driver: ${row.summary}`);
if (deliveredRoutine.join("|") !== routineSummaries.join("|")) {
  throw new Error(`routine notes lost, duplicated, or reordered: ${JSON.stringify(deliveredRoutine)} vs ${JSON.stringify(routineSummaries)}`);
}
const deliveredCaptain = mainEntries
  .filter((entry) => entry.customType === "fm-branch-visible-outcome" && entry.data.summary.startsWith("interleaved outcome "))
  .map((entry) => entry.data.seq);
const captainSeqs = interleaved.filter((row) => row.verdict === "captain").map((row) => row.seq);
if (deliveredCaptain.join(",") !== captainSeqs.join(",")) {
  throw new Error(`captain entries lost, duplicated, or reordered: ${deliveredCaptain} vs ${captainSeqs}`);
}
// Everything delivered is recorded as read, so a later reconciliation cannot
// deliver any of it a second time.
if (outcomeScript(["unread"]) !== "") throw new Error("delivered outcomes were left unread");
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "delivery must keep the event loop live and stay ordered: $out"
  pass "outcome delivery keeps the event loop running and interleaved reports stay ordered and exactly once"
}

test_session_replacement_during_delivery_neither_loses_nor_duplicates() {
  local repo home fakebin out status real_ps
  repo="$TMP_ROOT/delivery-replacement-root"
  home="$TMP_ROOT/delivery-replacement-home"
  fakebin="$home/fakebin"
  real_ps=$(command -v ps)
  mkdir -p "$home/state" "$home/config" "$fakebin"
  install_pi_branch_extension_fixture "$repo"
  cat > "$fakebin/ps" <<'SH'
#!/bin/sh
if [ -f "$FM_TEST_PS_ARM" ]; then
  rm -f "$FM_TEST_PS_ARM"
  : > "$FM_TEST_PS_ENTERED"
  while [ ! -f "$FM_TEST_PS_RELEASE" ]; do sleep 0.01; done
fi
exec "$FM_TEST_REAL_PS" "$@"
SH
  chmod +x "$fakebin/ps"
  PATH="$fakebin:$PATH" PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TEST_REAL_PS="$real_ps" FM_TEST_PS_ARM="$home/state/ps-arm" \
    FM_TEST_PS_ENTERED="$home/state/ps-entered" FM_TEST_PS_RELEASE="$home/state/ps-release" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, outcomeScript, sentToMain, mainEntries, home }; })()`);
const { fire, dispatch, settle, outcomeScript, sentToMain, mainEntries, home } = globalThis.__t;
import { existsSync, writeFileSync } from "node:fs";

const firstEntries = [];
const firstCtx = {
  sessionManager: { getSessionFile: () => `${home}/first.jsonl`, getEntries: () => firstEntries },
};
const secondEntries = [];
const secondCtx = {
  sessionManager: { getSessionFile: () => `${home}/second.jsonl`, getEntries: () => secondEntries },
};

// Use the live parent as lock owner so each ownership check must traverse at
// least one real ps subprocess; a self-owned lock would return before the
// asynchronous boundary this regression needs to hold open.
writeFileSync(`${home}/state/.lock`, `${process.ppid}\n`);
await fire("session_start", {}, firstCtx);
let finishWakePrompt;
globalThis.__fmOnBranchPrompt = () => new Promise((resolve) => { finishWakePrompt = resolve; });
const offer = dispatch("signal: branch-driver working");
if (!offer.accepted) throw new Error("branch did not accept the wake offer");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "branch wake prompt");
const report = globalThis.__fmSessions[0].options.customTools.find((tool) => tool.name === "fm_branch_report");
const toolGeneration = 1;

// A delivery that is still in flight when the captain replaces the session
// (/new, /resume, /fork, reload) must stop acting into the replaced session.
writeFileSync(process.env.FM_TEST_PS_ARM, "");
const inFlight = report.execute(
  "replaced-mid-delivery",
  { task: "branch-driver", verdict: "captain", summary: "reported as the session was replaced" },
  undefined,
  undefined,
  {},
);
await settle(() => existsSync(process.env.FM_TEST_PS_ENTERED), "in-flight ownership subprocess");
await fire("session_shutdown", {});
const replacementStart = fire("session_start", {}, secondCtx);
writeFileSync(process.env.FM_TEST_PS_RELEASE, "");
await replacementStart;
const replaced = await inFlight;
if (!replaced.isError) {
  throw new Error(`a report from the replaced session was accepted: ${JSON.stringify(replaced)}`);
}

// Nothing was delivered into either session's transcript by that refused
// report, and nothing was stored for it either: the refusal happened before
// the durable append, so there is no orphan row.
const storedAfter = outcomeScript(["list", "--recent", "50"]).split("\n").filter(Boolean).map((line) => JSON.parse(line));
if (storedAfter.some((row) => row.summary === "reported as the session was replaced")) {
  throw new Error("a report refused for a replaced session still reached the durable store");
}
if (firstEntries.length !== 0 || secondEntries.length !== 0 || sentToMain.length !== 0) {
  throw new Error("a report refused for a replaced session still delivered something visible");
}
finishWakePrompt();
await offer.settlement.then(() => null, () => null);

// A row that WAS stored but not yet delivered when the session was replaced
// is not lost: the new session's own reconciliation delivers it exactly once,
// into the new transcript, and advances the cursor past it.
const orphanSeq = Number(outcomeScript(["append", "--task", "branch-driver", "--verdict", "captain", "--summary", "stored before the replacement"]));
await fire("session_shutdown", {});
const thirdEntries = [];
await fire("session_start", {}, {
  sessionManager: { getSessionFile: () => `${home}/third.jsonl`, getEntries: () => thirdEntries },
});
const recovered = thirdEntries.filter((entry) => entry.customType === "fm-branch-visible-outcome");
if (recovered.length !== 1 || recovered[0].data.seq !== orphanSeq) {
  throw new Error(`the replacement session did not deliver the stored row exactly once: ${JSON.stringify(recovered)}`);
}
if (outcomeScript(["unread"]) !== "") throw new Error("the replacement session did not advance the read cursor");

// Reconciling again delivers nothing further: the cursor, not the transcript,
// is what stops a second delivery.
await fire("turn_end", {}, {
  sessionManager: { getSessionFile: () => `${home}/third.jsonl`, getEntries: () => thirdEntries },
});
if (thirdEntries.filter((entry) => entry.customType === "fm-branch-visible-outcome").length !== 1) {
  throw new Error("a later reconciliation delivered the same captain outcome twice");
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "a session replaced mid-delivery must neither lose nor duplicate an outcome: $out"
  pass "a session replaced mid-delivery cancels cleanly and the stored outcome still arrives exactly once"
}

test_store_failure_during_delivery_neither_loses_nor_duplicates() {
  local repo home fakebin out status real_bash
  repo="$TMP_ROOT/delivery-store-failure-root"
  home="$TMP_ROOT/delivery-store-failure-home"
  fakebin="$home/fakebin"
  real_bash=$(command -v bash)
  mkdir -p "$home/state" "$home/config" "$fakebin"
  install_pi_branch_extension_fixture "$repo"
  # Fails exactly the store subcommand the arming file names, once, so the
  # delivery meets a real failing script rather than a stubbed return value.
  # The driver arms it through that file because the extension snapshots its
  # child environment when it loads.
  cat > "$fakebin/bash" <<'SH'
#!/bin/sh
armed=$(cat "$FM_TEST_FAIL_ARM" 2>/dev/null || printf '')
if [ -n "$armed" ] && [ "$1" = "$FM_TEST_OUTCOME_SCRIPT" ] && [ "$2" = "$armed" ]; then
  : > "$FM_TEST_FAIL_ARM"
  echo "injected store failure" >&2
  exit 9
fi
exec "$FM_TEST_REAL_BASH" "$@"
SH
  chmod +x "$fakebin/bash"
  PATH="$fakebin:$PATH" PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TEST_REAL_BASH="$real_bash" FM_TEST_OUTCOME_SCRIPT="$ROOT/bin/fm-branch-outcome.sh" \
    FM_TEST_FAIL_ARM="$home/state/store-fail-arm" DRIVER_PRELUDE="$DRIVER_PRELUDE" \
    node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, outcomeScript, sentToMain, mainEntries, defaultSessionCtx }; })()`);
const { fire, dispatch, settle, outcomeScript, sentToMain, mainEntries, defaultSessionCtx } = globalThis.__t;
import { writeFileSync } from "node:fs";

const failArm = process.env.FM_TEST_FAIL_ARM;
const armStoreFailure = (subcommand) => writeFileSync(failArm, subcommand);
await fire("session_start", {}, defaultSessionCtx);
let finishWakePrompt;
globalThis.__fmOnBranchPrompt = () => new Promise((resolve) => { finishWakePrompt = resolve; });
const offer = dispatch("signal: branch-driver working");
if (!offer.accepted) throw new Error("branch did not accept the wake offer");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "branch wake prompt");
const report = globalThis.__fmSessions[0].options.customTools.find((tool) => tool.name === "fm_branch_report");

// 1. The durable append fails: the failure surfaces to the branch, and
// nothing is delivered, because nothing was ever stored.
armStoreFailure("append");
const appendFailed = await report.execute("append-fails", { task: "branch-driver", verdict: "routine", summary: "append must fail" }, undefined, undefined, {});
if (!appendFailed.isError || !appendFailed.content[0].text.includes("outcome store append failed")) {
  throw new Error(`a failed append did not surface as an error: ${JSON.stringify(appendFailed)}`);
}
if (sentToMain.length !== 0 || mainEntries.length !== 0) throw new Error("a failed append still delivered something visible");
if (outcomeScript(["list", "--recent", "50"]) !== "") throw new Error("a failed append still left a stored row");

// 2. The cursor advance fails AFTER the row is durable and delivered. The
// branch is told, the row stays in the store exactly once, and the next
// reconciliation completes the delivery rather than losing it.
armStoreFailure("mark-read");
const markFailed = await report.execute("mark-read-fails", { task: "branch-driver", verdict: "captain", summary: "cursor advance must fail" }, undefined, undefined, {});
if (!markFailed.isError || !markFailed.content[0].text.includes("visible delivery or cursor advancement failed")) {
  throw new Error(`a failed cursor advance did not surface as an error: ${JSON.stringify(markFailed)}`);
}
const afterFailure = outcomeScript(["list", "--recent", "50"]).split("\n").filter(Boolean).map((line) => JSON.parse(line));
if (afterFailure.length !== 1 || afterFailure[0].summary !== "cursor advance must fail") {
  throw new Error(`the durable row was lost or duplicated by the failed cursor advance: ${JSON.stringify(afterFailure)}`);
}
const failedSeq = afterFailure[0].seq;
if (outcomeScript(["unread"]) === "") throw new Error("a failed cursor advance still marked the row read");

// 3. Recovery: the same row is delivered exactly once and the cursor now
// advances, so nothing is lost and nothing is doubled.
armStoreFailure("");
await fire("turn_end", {}, defaultSessionCtx);
const visible = mainEntries.filter((entry) => entry.customType === "fm-branch-visible-outcome" && entry.data.seq === failedSeq);
if (visible.length !== 1) {
  throw new Error(`the recovered captain outcome is not present exactly once: ${JSON.stringify(visible)}`);
}
if (outcomeScript(["unread"]) !== "") throw new Error("recovery did not advance the read cursor");
await fire("turn_end", {}, defaultSessionCtx);
if (mainEntries.filter((entry) => entry.customType === "fm-branch-visible-outcome" && entry.data.seq === failedSeq).length !== 1) {
  throw new Error("a later reconciliation delivered the recovered outcome a second time");
}
finishWakePrompt();
await offer.settlement.then(() => null, () => null);
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "a store failure during delivery must neither lose nor duplicate an outcome: $out"
  pass "a failing store script surfaces to the branch and its outcome is neither lost nor delivered twice"
}

# The failure boundary the async conversion had to leave exactly as it found
# it: a routine note is delivered and then its cursor write fails. Routine
# notes carry no sequence key, so the next reconciliation delivers the same
# note again - a KNOWN PRE-EXISTING limitation of the routine delivery
# representation, tracked as fm-pi-routine-delivery-idempotency-followup-r1,
# not something moving the work off Pi's render thread introduced. This pins
# the exact shape (one re-delivery, never more, nothing lost) so a future
# change cannot quietly worsen it, and pins the captain row's sequence-keyed
# deduplication that makes the two paths differ.
test_mark_read_failure_keeps_routine_redelivery_and_captain_deduplication() {
  local repo home fakebin out status real_bash
  repo="$TMP_ROOT/mark-read-failure-shape-root"
  home="$TMP_ROOT/mark-read-failure-shape-home"
  fakebin="$home/fakebin"
  real_bash=$(command -v bash)
  mkdir -p "$home/state" "$home/config" "$fakebin"
  install_pi_branch_extension_fixture "$repo"
  cat > "$fakebin/bash" <<'SH'
#!/bin/sh
armed=$(cat "$FM_TEST_FAIL_ARM" 2>/dev/null || printf '')
if [ -n "$armed" ] && [ "$1" = "$FM_TEST_OUTCOME_SCRIPT" ] && [ "$2" = "$armed" ]; then
  : > "$FM_TEST_FAIL_ARM"
  echo "injected store failure" >&2
  exit 9
fi
exec "$FM_TEST_REAL_BASH" "$@"
SH
  chmod +x "$fakebin/bash"
  PATH="$fakebin:$PATH" PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TEST_REAL_BASH="$real_bash" FM_TEST_OUTCOME_SCRIPT="$ROOT/bin/fm-branch-outcome.sh" \
    FM_TEST_FAIL_ARM="$home/state/store-fail-arm" DRIVER_PRELUDE="$DRIVER_PRELUDE" \
    node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, outcomeScript, sentToMain, mainEntries, defaultSessionCtx }; })()`);
const { fire, dispatch, settle, outcomeScript, sentToMain, mainEntries, defaultSessionCtx } = globalThis.__t;
import { writeFileSync } from "node:fs";

const failArm = process.env.FM_TEST_FAIL_ARM;
const armStoreFailure = (subcommand) => writeFileSync(failArm, subcommand);
const storedRows = () => outcomeScript(["list", "--recent", "50"]).split("\n").filter(Boolean).map((line) => JSON.parse(line));
const routineCopies = (summary) => sentToMain.filter(
  (sent) => sent.message.customType === "fm-branch-merge" && sent.message.content.includes(summary),
).length;
const captainCopies = (seq) => mainEntries.filter(
  (entry) => entry.customType === "fm-branch-visible-outcome" && entry.data.seq === seq,
).length;

await fire("session_start", {}, defaultSessionCtx);
let finishWakePrompt;
globalThis.__fmOnBranchPrompt = () => new Promise((resolve) => { finishWakePrompt = resolve; });
const offer = dispatch("signal: branch-driver working");
if (!offer.accepted) throw new Error("branch did not accept the wake offer");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "branch wake prompt");
const report = globalThis.__fmSessions[0].options.customTools.find((tool) => tool.name === "fm_branch_report");

// A routine note is delivered, then its cursor write fails.
const routineSummary = "routine note whose cursor write fails";
armStoreFailure("mark-read");
const routineFailed = await report.execute("routine-mark-read-fails", { task: "branch-driver", verdict: "routine", summary: routineSummary }, undefined, undefined, {});
if (!routineFailed.isError || !routineFailed.content[0].text.includes("visible delivery or cursor advancement failed")) {
  throw new Error(`a failed routine cursor advance did not surface as an error: ${JSON.stringify(routineFailed)}`);
}

if (routineCopies(routineSummary) !== 1) {
  throw new Error(`the routine note was not delivered exactly once before the cursor failure: ${routineCopies(routineSummary)}`);
}
let stored = storedRows();
if (stored.length !== 1) throw new Error(`the failed cursor write changed the store: ${JSON.stringify(stored)}`);
if (outcomeScript(["unread"]) === "") throw new Error("a failed cursor write still marked the routine row read");

// The next reconciliation re-delivers it, because a routine note has no
// sequence-keyed record to recognize. That second copy is the pre-existing
// limitation; what must hold is that it is exactly one more, and that the
// store and cursor recover.
armStoreFailure("");
await fire("turn_end", {}, defaultSessionCtx);
if (routineCopies(routineSummary) !== 2) {
  throw new Error(`recovery did not re-deliver the routine note exactly once: ${routineCopies(routineSummary)}`);
}
if (outcomeScript(["unread"]) !== "") throw new Error("recovery did not advance the cursor past the routine row");
stored = storedRows();
if (stored.length !== 1) throw new Error(`recovery changed the stored routine row: ${JSON.stringify(stored)}`);

// Once the cursor is past it, no further reconciliation delivers it again:
// the duplication window is the failed write, not an unbounded repeat.
await fire("turn_end", {}, defaultSessionCtx);
if (routineCopies(routineSummary) !== 2) {
  throw new Error(`the routine note kept being re-delivered after the cursor advanced: ${routineCopies(routineSummary)}`);
}

// The same failure on a captain row does NOT duplicate: its visible entry is
// keyed by store sequence, so the re-run recognizes its own earlier write.
const captainSummary = "captain outcome whose cursor write fails";
armStoreFailure("mark-read");
const captainFailed = await report.execute("captain-mark-read-fails", { task: "branch-driver", verdict: "captain", summary: captainSummary }, undefined, undefined, {});
if (!captainFailed.isError) throw new Error(`a failed captain cursor advance did not surface as an error: ${JSON.stringify(captainFailed)}`);
const captainSeq = storedRows().find((row) => row.summary === captainSummary).seq;
if (captainCopies(captainSeq) !== 1) throw new Error(`the captain entry was not written exactly once: ${captainCopies(captainSeq)}`);
armStoreFailure("");
await fire("turn_end", {}, defaultSessionCtx);
if (captainCopies(captainSeq) !== 1) {
  throw new Error(`recovery duplicated the captain entry: ${captainCopies(captainSeq)}`);
}
if (outcomeScript(["unread"]) !== "") throw new Error("recovery did not advance the cursor past the captain row");
if (storedRows().length !== 2) throw new Error(`the store lost or duplicated a row across both failures: ${JSON.stringify(storedRows())}`);

// The durable cursor, not this session, is what closes both windows: a new
// main session reconciles and re-delivers neither of them.
finishWakePrompt();
await offer.settlement.then(() => null, () => null);
await fire("session_start", {}, defaultSessionCtx);
if (routineCopies(routineSummary) !== 2 || captainCopies(captainSeq) !== 1) {
  throw new Error(`a new session re-delivered an already-read outcome: routine=${routineCopies(routineSummary)} captain=${captainCopies(captainSeq)}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "a failed cursor write must keep the routine re-delivery shape and the captain deduplication: $out"
  pass "a failed cursor write re-delivers a routine note exactly once more while a captain outcome stays deduplicated"
}

test_expired_delegation_refuses_bound_branch_report() {
  local repo home out status
  repo="$TMP_ROOT/expired-delegation-report-root"
  home="$TMP_ROOT/expired-delegation-report-home"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
await eval(`(async () => { ${process.env.DRIVER_PRELUDE}; globalThis.__t = { fire, dispatch, outcomeScript, defaultSessionCtx, home, realRoot }; })()`);
const { fire, dispatch, outcomeScript, defaultSessionCtx, home, realRoot } = globalThis.__t;
const { createHash } = await import("node:crypto");
const { chmodSync, mkdirSync, readFileSync, writeFileSync } = await import("node:fs");
const { spawnSync } = await import("node:child_process");
const task = "branch-driver";
const taskDir = `${home}/data/${task}`;
mkdirSync(taskDir, { recursive: true });
writeFileSync(`${taskDir}/brief.md`, "Continue the authorized task and report its result.\n");
writeFileSync(`${home}/state/${task}.meta`, `project=${home}/projects/approved\nwindow=fm-branch-driver\nspawn_gen=g1\n`);
const run = (args) => spawnSync(`${realRoot}/bin/fm-task-state.sh`, args, {
  encoding: "utf8",
  env: { ...process.env, FM_HOME: home, FM_STATE_OVERRIDE: `${home}/state`, FM_SUPERVISION_ACTOR: "main" },
});
let result = run(["enroll", task]);
if (result.status !== 0) throw new Error(result.stderr);
const lifecyclePath = `${taskDir}/lifecycle.json`;
const record = JSON.parse(readFileSync(lifecyclePath, "utf8"));
record.schema = "fm-task-lifecycle.v2";
record.precheck = null;
record.delegation = {
  revision: 1,
  issuer: "main",
  authority_ref: `${taskDir}/brief.md`,
  authority_sha256: createHash("sha256").update(readFileSync(`${taskDir}/brief.md`)).digest("hex"),
  allowed: ["inspect", "precheck", "observe-receipt"],
  edges: [],
  expires_at: "2099-01-01T00:00:00Z",
  revoked: false,
};
const proposal = `${home}/data/delegation-proposal.json`;
writeFileSync(proposal, JSON.stringify(record));
chmodSync(proposal, 0o600);
result = run(["reconcile", task, "--expected-revision", String(record.revision), "--record", proposal]);
if (result.status !== 0) throw new Error(result.stderr);

await fire("session_start", {}, defaultSessionCtx);
let reportResult;
globalThis.__fmOnBranchPrompt = async ({ session }) => {
  const report = session.options.customTools.find((tool) => tool.name === "fm_branch_report");
  const actualNow = Date.now;
  Date.now = () => Date.parse("2100-01-01T00:00:00Z");
  try {
    reportResult = await report.execute("expired-result", {
      task,
      verdict: "routine",
      summary: "late delegated result",
    }, undefined, undefined, {});
  } finally {
    Date.now = actualNow;
  }
};
const offer = dispatch("signal: delegated task result");
if (!offer.accepted) throw new Error("delegated wake was not accepted");
await offer.settlement.then(() => null, () => null);
if (!reportResult?.isError || !reportResult.content[0].text.includes("invalidated this branch result")) {
  throw new Error(`expired delegation report was not refused: ${JSON.stringify(reportResult)}`);
}

if (outcomeScript(["list", "--recent", "50"]) !== "") {
  throw new Error("expired delegation report reached the durable outcome store");
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "an expired delegation must refuse its bound branch report: $out"
  pass "expired delegation refuses a bound branch report before storage"
}

test_compact_progress_drives_branch_same_worker_continuation() {
  local repo home out status
  repo="$TMP_ROOT/compact-branch-root"
  home="$TMP_ROOT/compact-branch-home"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
await eval(`(async () => { ${process.env.DRIVER_PRELUDE}; globalThis.__t = { pi, fire, settle, sentToMain, defaultSessionCtx, home, realRoot }; })()`);
const { pi, fire, settle, sentToMain, defaultSessionCtx, home, realRoot } = globalThis.__t;
const { appendFileSync, chmodSync, mkdirSync, readFileSync, readdirSync, writeFileSync } = await import("node:fs");
const { spawnSync } = await import("node:child_process");

mkdirSync(`${home}/state`, { recursive: true });
mkdirSync(`${home}/data`, { recursive: true });
writeFileSync(`${home}/state/.lock`, `${process.ppid}\n`);
writeFileSync(`${home}/.tasks.toml`, 'backend="markdown"\n[markdown]\npath="data/backlog.md"\n');
writeFileSync(`${home}/data/backlog.md`, "## In flight\n\n## Queued\n\n## Done\n");
mkdirSync(`${home}/fakebin`, { recursive: true });
writeFileSync(`${home}/fakebin/herdr`, `#!/bin/sh
case "$1 $2" in
  "status --json") printf '%s\\n' '{"client":{"version":"0.7.4","protocol":16},"server":{"running":false}}' ;;
  *) exit 1 ;;
esac
`);
chmodSync(`${home}/fakebin/herdr`, 0o755);
process.env.PATH = `${home}/fakebin:${process.env.PATH}`;
const run = (script, args, actor = "main", extra = {}) => spawnSync(`${realRoot}/bin/${script}`, args, {
  encoding: "utf8",
  env: { ...process.env, FM_HOME: home, FM_STATE_OVERRIDE: `${home}/state`,
    FM_DATA_OVERRIDE: `${home}/data`, FM_SUPERVISION_ACTOR: actor, ...extra },
});
let result = run("fm-tasks-axi.sh", ["add", "viewer", "Make the viewer responsive", "--kind", "ship",
  "--body", "Keep the existing task identity.", "--start"]);
if (result.status !== 0) throw new Error(result.stderr);
writeFileSync(`${home}/state/viewer.meta`, `window=fixture:w1:p1\nendpoint_task_id=viewer\nproject=${home}/project\nbackend=herdr\nherdr_session=fixture\nherdr_workspace_id=w1\nherdr_tab_id=w1:t1\nherdr_pane_id=w1:p1\nharness=pi\nkind=ship\nspawn_gen=g1\n`);
mkdirSync(`${home}/data/viewer`, { recursive: true });
writeFileSync(`${home}/data/viewer/brief.md`, "# Task\n## Captain's intent\nMake the viewer responsive.\n");
writeFileSync(`${home}/state/other.meta`, `window=fixture:w1:p2\nendpoint_task_id=other\nproject=${home}/project\nbackend=herdr\nherdr_session=fixture\nherdr_workspace_id=w1\nherdr_tab_id=w1:t2\nherdr_pane_id=w1:p2\nharness=pi\nkind=ship\nspawn_gen=g1\n`);
let progress = run("fm-task-state.sh", ["progress", "viewer"]);
if (progress.status !== 0) throw new Error(progress.stderr);
let record = JSON.parse(progress.stdout);
const fields = {
  acceptance: "The same worker completes no-mistakes and MAIN verifies the requested behavior",
  current_state: "Implementation checkpoint 4826e2b4 is committed",
  remaining_gap: "The same worker has not started ordinary no-mistakes",
  next_step: "Tell the existing viewer worker to start no-mistakes on checkpoint 4826e2b4",
};
result = run("fm-task-state.sh", ["update-progress", "viewer", "--expected-token", record.record_token,
  "--progress", JSON.stringify(fields)]);
if (result.status !== 0) throw new Error(result.stderr);
record = JSON.parse(result.stdout);

const entries = [];
const mainFile = `${home}/main.jsonl`;
writeFileSync(mainFile, JSON.stringify({ type: "session", version: 3, id: "compact-branch" }) + "\n");
Object.assign(defaultSessionCtx, { isIdle: () => true, hasPendingMessages: () => false,
  hasUI: false, ui: { getEditorText: () => "" } });
Object.assign(defaultSessionCtx.sessionManager, { getSessionFile: () => mainFile,
  getSessionId: () => "compact-branch", getLeafId: () => entries.at(-1)?.id,
  getBranch: () => entries, getEntries: () => entries });
pi.appendEntry = (customType, data) => {
  const entry = { type: "custom", id: `main-${entries.length}`, parentId: entries.at(-1)?.id ?? null,
    timestamp: new Date().toISOString(), customType, data };
  entries.push(entry);
  appendFileSync(mainFile, JSON.stringify(entry) + "\n");
  return entry.id;
};
(await import(`${realRoot}/.pi/extensions/fm-periodic-stow.ts`)).default(pi);

const routed = [];
globalThis.__fmExecuteBranchBash = async (context) => {
  routed.push({ command: context.command, actor: context.env.FM_SUPERVISION_ACTOR });
  const executed = spawnSync("bash", ["-c", context.command], {
    cwd: context.cwd, env: { ...context.env, PATH: `${home}/fakebin:${context.env.PATH}` }, encoding: "utf8",
  });
  if (executed.status !== 0) {
    return { content: [{ type: "text", text: executed.stderr }], details: undefined, isError: true };
  }
  if (promptCount < 3) {
    appendFileSync(`${home}/state/viewer.status`, "working: no-mistakes started by the existing worker\n");
  }
  return { content: [{ type: "text", text: executed.stdout || "instruction durably queued" }], details: undefined };
};
let promptCount = 0;
let readResult;
let deniedUpdate;
let reportResult;
let scopedRefusal;
globalThis.__fmOnBranchPrompt = async ({ session, text }) => {
  promptCount += 1;
  const expectedStep = [
    fields.next_step,
    "Tell the existing viewer worker to continue the same no-mistakes run after its intermediate review",
    "Arm the PR check for https://github.com/acme/viewer/pull/7",
  ][promptCount - 1];
  if (!text.includes("FIRSTMATE TASK CONTINUATION: viewer") || !text.includes(expectedStep) ||
      text.includes("authority_ref") || text.includes('"evidence"')) {
    throw new Error(`compact admission was incomplete or rich: ${text}`);
  }
  const continuation = session.options.customTools.find((tool) => tool.name === "fm_task_continuation");
  const report = session.options.customTools.find((tool) => tool.name === "fm_branch_report");
  const bash = session.options.customTools.find((tool) => tool.name === "bash");
  readResult = await continuation.execute("read", { action: "read", task: "viewer" });
  if (readResult.isError || JSON.parse(readResult.content[0].text).next_step !== expectedStep) {
    throw new Error(`bound compact read failed: ${JSON.stringify(readResult)}`);
  }
  deniedUpdate = await continuation.execute("update", { action: "patch", task: "viewer" });
  if (!deniedUpdate.isError || !deniedUpdate.content[0].text.includes("permits read only")) {
    throw new Error(`branch gained progress-write authority: ${JSON.stringify(deniedUpdate)}`);
  }
  scopedRefusal = await bash.execute("cross-scope", { command: `${realRoot}/bin/fm-send.sh other 'Unrelated steer.'` });
  if (!scopedRefusal.isError || !scopedRefusal.content[0].text.includes("outside this exact branch admission")) {
    throw new Error(`compact admission escaped its canonical task: ${JSON.stringify(scopedRefusal)}`);
  }
  const command = promptCount === 3
    ? `${realRoot}/bin/fm-pr-check.sh viewer https://github.com/acme/viewer/pull/7`
    : `${realRoot}/bin/fm-send.sh viewer '${promptCount === 1 ? "Load crewmate-no-mistakes and start the existing checkpoint." : "Continue the same no-mistakes run after its intermediate review."}'`;
  const sent = await bash.execute("continue", { command });
  if (sent.isError) throw new Error(`same-worker route failed: ${JSON.stringify(sent)}`);
  reportResult = await report.execute("report", { task: "viewer", verdict: "routine", silent: true,
    summary: promptCount === 3 ? "The PR check was armed for the ready implementation." :
      "The existing worker received the authorized no-mistakes continuation." });
  if (reportResult.isError) throw new Error(`continuation report failed: ${JSON.stringify(reportResult)}`);
};

await fire("session_start", {}, defaultSessionCtx);
pi.appendEntry("fixture-seed", {});
const beforeMain = sentToMain.length;
await fire("agent_before_settle", {}, defaultSessionCtx);
try { await settle(() => promptCount === 1 && reportResult, "compact branch continuation"); }
catch (error) {
  const outcomes = (() => { try { return readFileSync(`${home}/state/branch-outcomes.jsonl`, "utf8"); } catch { return ""; } })();
  const trace = (() => { try { return readFileSync(`${home}/state/.supervision-routing.jsonl`, "utf8"); } catch { return ""; } })();
  throw new Error(`${error}; prompts=${promptCount} routed=${JSON.stringify(routed)} outcomes=${outcomes} trace=${trace}`);
}
const viewerRoutes = routed.filter((item) => item.command.includes("fm-send.sh viewer"));
if (viewerRoutes.length !== 1 || viewerRoutes[0].actor !== "branch") {
  throw new Error(`next step did not use the existing same-worker owner: ${JSON.stringify(routed)}`);
}
const inbox = readdirSync(`${home}/state/viewer.inbox`).filter((name) => name.endsWith(".msg"));
if (inbox.length !== 1 || !readFileSync(`${home}/state/viewer.inbox/${inbox[0]}`, "utf8").includes("start the existing checkpoint")) {
  throw new Error(`same-worker inbox receipt missing: ${JSON.stringify(inbox)}`);
}
if (sentToMain.length !== beforeMain + 1 ||
    !sentToMain.at(-1)?.message?.content?.includes("existing worker received the authorized no-mistakes continuation")) {
  throw new Error(`material continuation did not reach MAIN: ${JSON.stringify(sentToMain)}`);
}
if (!entries.some((entry) => entry.customType === "fm-continuation-branch-delivery")) {
  throw new Error("MAIN session lacks the compact branch delivery receipt");
}
if (globalThis.__fmSessions[0].options.sessionManager.getEntries().some((entry) =>
  entry.customType === "fm-task-continuation-settlement" && entry.data.record_token === record.record_token)) {
  throw new Error("material continuation was retained only in the branch session");
}
if (readFileSync(`${home}/data/backlog.md`, "utf8").match(/firstmate-progress:v1/g)?.length !== 1) {
  throw new Error("continuation created a second active progress record");
}
if (readFileSync(`${home}/data/backlog.md`, "utf8").includes("no-mistakes started by")) {
  throw new Error("branch overwrote MAIN-owned progress");
}

// A healthy running executor suppresses a second prompt and every-command
// progress write. The status event is executor-owned evidence, not a task-row
// progress mutation.
await fire("agent_before_settle", {}, defaultSessionCtx);
await new Promise((resolve) => setTimeout(resolve, 100));
if (promptCount !== 1 || routed.filter((item) => item.command.includes("fm-send.sh viewer")).length !== 1) throw new Error("healthy execution replayed the continuation");
if (sentToMain.length !== beforeMain + 1) throw new Error("healthy unchanged execution notified MAIN");

// A material intermediate result is recorded once by MAIN. Its new token
// admits one further same-worker action without reviving the old admission.
progress = run("fm-task-state.sh", ["progress", "viewer"]);
record = JSON.parse(progress.stdout);
const intermediate = { ...fields,
  current_state: "No-mistakes returned an intermediate review result",
  remaining_gap: "The same run still has authorized review corrections and later gates",
  next_step: "Tell the existing viewer worker to continue the same no-mistakes run after its intermediate review",
};
result = run("fm-task-state.sh", ["update-progress", "viewer", "--expected-token", record.record_token,
  "--progress", JSON.stringify(intermediate)]);
if (result.status !== 0) throw new Error(`MAIN intermediate progress update failed: ${result.stderr}`);
record = JSON.parse(result.stdout);
writeFileSync(`${home}/state/viewer.status`, "done: intermediate no-mistakes review result\n");
await fire("agent_before_settle", {}, defaultSessionCtx);
await settle(() => promptCount === 2 &&
  routed.filter((item) => item.command.includes("fm-send.sh viewer")).length === 2 &&
  sentToMain.length === beforeMain + 2,
  "intermediate same-worker continuation");
const messages = readdirSync(`${home}/state/viewer.inbox`).filter((name) => name.endsWith(".msg"));
if (messages.length !== 2) throw new Error(`intermediate continuation did not create one new inbox receipt: ${JSON.stringify(messages)}`);
if (sentToMain.length !== beforeMain + 2) throw new Error("intermediate material continuation did not reach MAIN once");

progress = run("fm-task-state.sh", ["progress", "viewer"]);
record = JSON.parse(progress.stdout);
const prCheck = { ...intermediate,
  current_state: "The implementation and focused validation are ready for PR monitoring",
  remaining_gap: "The PR check has not been armed",
  next_step: "Arm the PR check for https://github.com/acme/viewer/pull/7",
};
result = run("fm-task-state.sh", ["update-progress", "viewer", "--expected-token", record.record_token,
  "--progress", JSON.stringify(prCheck)]);
if (result.status !== 0) throw new Error(`MAIN PR-check progress update failed: ${result.stderr}`);
record = JSON.parse(result.stdout);
const statusBeforePrCheck = readFileSync(`${home}/state/viewer.status`, "utf8");
const inboxBeforePrCheck = readdirSync(`${home}/state/viewer.inbox`).filter((name) => name.endsWith(".msg")).sort();
await fire("agent_before_settle", {}, defaultSessionCtx);
await settle(() => promptCount === 3 &&
  routed.filter((item) => item.command.includes("fm-pr-check.sh viewer")).length === 1 &&
  sentToMain.length === beforeMain + 3,
  "PR-check-only continuation");
if (readFileSync(`${home}/state/viewer.status`, "utf8") !== statusBeforePrCheck ||
    JSON.stringify(readdirSync(`${home}/state/viewer.inbox`).filter((name) => name.endsWith(".msg")).sort()) !== JSON.stringify(inboxBeforePrCheck)) {
  throw new Error("PR-check fixture unexpectedly changed status or inbox state");
}
if (!readFileSync(`${home}/state/viewer.meta`, "utf8").includes("pr=https://github.com/acme/viewer/pull/7") ||
    !readFileSync(`${home}/state/viewer.pr-poll`, "utf8").includes("https://github.com/acme/viewer/pull/7") ||
    !readFileSync(`${home}/state/viewer.pr-poll-registration`, "utf8").trim() ||
    !readFileSync(`${home}/state/viewer.check.sh`, "utf8").trim()) {
  throw new Error("PR-check owner did not publish its resumable task state");
}
if (sentToMain.length !== beforeMain + 3 ||
    !sentToMain.at(-1)?.message?.content?.includes("PR check was armed for the ready implementation")) {
  throw new Error(`metadata-only PR-check continuation did not reach MAIN: ${JSON.stringify(sentToMain)}`);
}
if (globalThis.__fmSessions[0].options.sessionManager.getEntries().some((entry) =>
  entry.customType === "fm-task-continuation-settlement" && entry.data.record_token === record.record_token)) {
  throw new Error("metadata-only PR-check continuation was retained only in the branch session");
}

// Only MAIN performs final semantic acceptance after the fixture's requested
// outcome is satisfied. Empty gap/next step removes the task from monitoring.
progress = run("fm-task-state.sh", ["progress", "viewer"]);
record = JSON.parse(progress.stdout);
const accepted = { ...intermediate, current_state: "All requested checks passed and MAIN reviewed the artifact",
  remaining_gap: "", next_step: "" };
result = run("fm-task-state.sh", ["update-progress", "viewer", "--expected-token", record.record_token,
  "--progress", JSON.stringify(accepted)]);
if (result.status !== 0) throw new Error(`MAIN final acceptance update failed: ${result.stderr}`);
await fire("agent_before_settle", {}, defaultSessionCtx);
await new Promise((resolve) => setTimeout(resolve, 100));
if (promptCount !== 3 || routed.filter((item) => item.command.includes("fm-send.sh viewer")).length !== 2 ||
    routed.filter((item) => item.command.includes("fm-pr-check.sh viewer")).length !== 1 || sentToMain.length !== beforeMain + 3) {
  throw new Error("accepted goal remained active or interrupted MAIN");
}

console.log("compact continuation delivered inbox and metadata-only resume changes to MAIN, kept unchanged execution quiet, and stopped only after MAIN acceptance");
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "compact progress branch continuation: $out"
  pass "$out"
}

test_branch_native_continuation_is_scoped_compact_and_material_only() {
  local repo home out status
  repo="$TMP_ROOT/native-continuation-root"; home="$TMP_ROOT/native-continuation-home"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
await eval(`(async () => { ${process.env.DRIVER_PRELUDE}; globalThis.__t = { pi, fire, settle, outcomeScript, sentToMain, defaultSessionCtx, mainTools, home, realRoot }; })()`);
const { pi, fire, settle, outcomeScript, sentToMain, defaultSessionCtx, mainTools, home, realRoot } = globalThis.__t;
const { createHash } = await import("node:crypto");
const { appendFileSync, mkdirSync, readFileSync, writeFileSync } = await import("node:fs");
const { spawnSync } = await import("node:child_process");
const entries=[], mainFile=`${home}/main.jsonl`;
writeFileSync(mainFile,JSON.stringify({type:"session",version:3,id:"native-continuation"})+'\n');
Object.assign(defaultSessionCtx,{isIdle:()=>true,hasPendingMessages:()=>false,hasUI:false,ui:{getEditorText:()=>""}});
Object.assign(defaultSessionCtx.sessionManager,{getSessionId:()=>"native-continuation",getLeafId:()=>entries.at(-1)?.id,getBranch:()=>entries,getEntries:()=>entries});
pi.appendEntry=(customType,data)=>{const entry={type:"custom",id:`entry-${entries.length}`,parentId:entries.at(-1)?.id??null,timestamp:new Date().toISOString(),customType,data};entries.push(entry);appendFileSync(mainFile,JSON.stringify(entry)+'\n');return entry.id;};
(await import(`${realRoot}/.pi/extensions/fm-periodic-stow.ts`)).default(pi);
const task="routine";mkdirSync(`${home}/data/${task}`,{recursive:true});
writeFileSync(`${home}/data/${task}/brief.md`,"Retain the unchanged goal and report only material evidence.\n");
writeFileSync(`${home}/state/${task}.meta`,"spawn_gen=g1\nkind=ship\nexecutor=local-agent\n");
writeFileSync(`${home}/data/policy-authority.md`,"Standing routine branch authority for this isolated fixture.\n");
writeFileSync(`${home}/data/historical-report.md`,"Rollout is inactive pending landing, reload and policy enablement.\n");
writeFileSync(`${home}/data/current-readback.md`,"Rollout is enabled after reload and the exact task grant is active.\n");
writeFileSync(`${home}/data/readback-action.md`,"Inspect data/current-readback.md and retain final semantic acceptance for MAIN.\n");
const sha=path=>createHash("sha256").update(readFileSync(path)).digest("hex");
const run=args=>spawnSync(`${realRoot}/bin/fm-task-state.sh`,args,{encoding:"utf8",env:{...process.env,FM_HOME:home,FM_STATE_OVERRIDE:`${home}/state`,FM_DATA_OVERRIDE:`${home}/data`,FM_CONFIG_OVERRIDE:`${home}/config`,FM_SUPERVISION_ACTOR:"main"}});
let result=run(["enroll",task]);if(result.status!==0)throw Error(result.stderr);
const policy={schema:"fm-task-continuation-policy.v1",revision:0,issuer:"main",enabled:true,authority_ref:"data/policy-authority.md",authority_sha256:sha(`${home}/data/policy-authority.md`),allowed:["inspect","precheck","steer-same-intent","observe-receipt"],expires_at:"2099-01-01T00:00:00Z"};
writeFileSync(`${home}/data/policy.json`,JSON.stringify(policy),{mode:0o600});result=run(["continuation-policy","--expected-revision","0","--record",`${home}/data/policy.json`]);if(result.status!==0)throw Error(result.stderr);
result=run(["refresh",task]);if(result.status!==0)throw Error(result.stderr);
const mainNative=mainTools.find(tool=>tool.name==="fm_task_continuation");
if(!mainNative)throw Error("main native continuation tool absent");
const inspected=await mainNative.execute("seed-inspect",{action:"inspect",task,evidence:[`data/${task}/brief.md`,"data/current-readback.md","data/readback-action.md"]},undefined,undefined,defaultSessionCtx);
if(inspected.isError)throw Error(`seed inspect refused ${JSON.stringify(inspected)}`);
const basis=JSON.parse(inspected.content[0].text).basis;
const assessed=await mainNative.execute("seed-assess",{action:"assess",task,basis,judgment:{disposition:"open",outcome:"Rollout enabled; current branch readback remains pending.",remaining_gap:"Inspect the prepared current-session readback, then preserve final semantic acceptance for MAIN.",authority_ref:`data/${task}/brief.md`,evidence:[`data/${task}/brief.md`,`data/current-readback.md`],next_action:{kind:"readback",payload_ref:"data/readback-action.md",recheck_at:"2000-01-01T00:00:00Z",deadline:"2099-01-01T00:00:00Z",attempt_limit:2}}},undefined,undefined,defaultSessionCtx);
if(assessed.isError)throw Error(`seed assessment refused ${JSON.stringify(assessed)}`);
const seedObservation=run(["observe",task]);if(seedObservation.status!==0)throw Error(`seed observation refused ${seedObservation.stderr}`);
let nativeCalls=0,compactNoChanges=0,material,currentReadback,promptCount=0;
globalThis.__fmOnBranchPrompt=async({session,text})=>{
 promptCount++;
 const native=session.options.customTools.find(tool=>tool.name==="fm_task_continuation"),report=session.options.customTools.find(tool=>tool.name==="fm_branch_report");
 if(!native||!report)throw Error("branch-native tools absent");const admitted=JSON.parse(text.slice(text.lastIndexOf("\n{")+1));
 if(admitted.assessment?.remaining_gap!=="Inspect the prepared current-session readback, then preserve final semantic acceptance for MAIN."||admitted.next_action?.kind!=="readback"||admitted.next_action?.payload_ref!=="data/readback-action.md")throw Error(`current lifecycle context omitted ${JSON.stringify(admitted)}`);
 const selectEvidence=context=>context.next_action?.phase==="prepared"?context.next_action.payload_ref:context.observation?.state==="pending"?"data/historical-report.md":null;
 if(selectEvidence({...admitted,assessment:undefined,next_action:undefined})!=="data/historical-report.md")throw Error("masked counterfactual did not reproduce stale historical selection");
 if(selectEvidence(admitted)!=="data/readback-action.md")throw Error("current action did not displace historical rollout text");
 if(selectEvidence({observation:{state:"waiting"},assessment:{remaining_gap:"unchanged dependency"},next_action:null})!==null)throw Error("unchanged healthy wait requested a native call");
 currentReadback=await native.execute("current-readback",{action:"inspect",task,evidence:[...new Set([admitted.assessment.authority_ref,...admitted.assessment.evidence.map(item=>item.ref),admitted.next_action.payload_ref])]});nativeCalls++;
 if(currentReadback.isError)throw Error(`current readback refused ${JSON.stringify(currentReadback)}`);const current=JSON.parse(currentReadback.content[0].text);
 if(current.assessment?.remaining_gap!==admitted.assessment.remaining_gap||current.next_action?.id!==admitted.next_action.id)throw Error(`current readback lost canonical action ${JSON.stringify(current)}`);
 const wrong=await native.execute("wrong",{action:"observe",task:"other"});if(!wrong.isError||!wrong.content[0].text.includes("outside this exact branch admission"))throw Error("scope escaped");
 for(let i=0;i<5;i++){const observed=await native.execute(`same-${i}`,{action:"observe",task});nativeCalls++;const body=JSON.parse(observed.content[0].text);if(observed.isError||body.change!=="none"||body.assessment||body.delegation)throw Error(`noncompact ${JSON.stringify(observed)}`);compactNoChanges++;}
 const patch={delegation_revision:admitted.delegation.revision,precheck:{delegation_revision:admitted.delegation.revision,basis_key:admitted.observation.basis_key,conclusion:"needs-evidence",checks:[{criterion:"brief: verified milestone",result:"missing",evidence:[]}],summary:"No verified milestone yet; retain the unchanged gap without another action."}};
 material=await native.execute("material",{action:"patch",task,expected_revision:admitted.revision,patch_json:JSON.stringify(patch)});nativeCalls++;
 if(material.isError)throw Error(`material refused ${JSON.stringify(material)}`);const changed=JSON.parse(material.content[0].text);if(changed.change!=="material"||changed.precheck?.conclusion!=="needs-evidence")throw Error(`lost delta ${JSON.stringify(material)}`);
 const reported=await report.execute("report",{task,verdict:"routine",summary:"Routine evidence unchanged; retained the existing gap without MAIN bookkeeping."});if(reported.isError)throw Error(JSON.stringify(reported));
};
await fire("session_start",{},defaultSessionCtx);pi.appendEntry("fixture-seed",{});const before=sentToMain.length;
await fire("agent_before_settle",{},defaultSessionCtx);
try { await settle(()=>outcomeScript(["list","--recent","10"]).includes("Routine evidence unchanged"),"native report"); }
catch (error) { throw Error(`${error}; seedObservation=${seedObservation.stdout.trim()} outcomes=${outcomeScript(["list","--recent","10"])} promptCount=${promptCount} nativeCalls=${nativeCalls} sessions=${globalThis.__fmSessions?.length}`); }
if(sentToMain.length!==before)throw Error("routine work opened MAIN");
if(nativeCalls!==7||compactNoChanges!==5||!material||!currentReadback)throw Error("tool counts changed");
const record=JSON.parse(readFileSync(`${home}/data/${task}/lifecycle.json`));if(record.delegation.policy_revision!==1||record.precheck?.conclusion!=="needs-evidence")throw Error("material delta missing");
console.log(JSON.stringify({main_model_turns:0,main_tools:0,branch_native_tools:nativeCalls,current_readback_tools:1,no_change_native_tools:compactNoChanges,material_native_tools:1,healthy_wait_extra_tools:0,branch_reports:1}));
process.exit(0);
EOF
  status=$?; out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "branch-native continuation scope/delta boundary: $out"
  pass "$out"
}

test_extension_registered_provider_resolves_in_the_branch() {
  local repo home out status
  repo="$TMP_ROOT/extprov-root"
  home="$TMP_ROOT/extprov-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, makeCtx, registryModels, uiSelections, uiPrompts, notices, commands, home }; })()`);
const { fire, dispatch, settle, makeCtx, registryModels, uiSelections, uiPrompts, notices, commands, home } = globalThis.__t;
import { readFileSync, writeFileSync } from "node:fs";

// An extension-registered provider exists only in main's registry, never in
// the isolated branch runtime's static catalog. Registering its config on
// main's registry is what makes it resolvable for the branch.
registryModels.push(
  { provider: "anthropic", id: "main-model" },
  // Available in main's registry but absent from the branch runtime's static
  // catalog, exactly like a provider an extension registered at runtime.
  { provider: "devin", id: "swe-1-7", branchAvailable: false },
);
globalThis.__fmExtensionProviderConfigs = new Map([
  [
    "devin",
    {
      name: "Devin (Cognition)",
      api: "devin-cloud",
      baseUrl: "https://server.codeium.com",
      models: [{ id: "swe-1-7", name: "SWE 1.7", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 200000, maxTokens: 8192 }],
      oauth: { name: "Devin (Cognition / Windsurf)", login: async () => ({}), refreshToken: async (c) => c, getApiKey: (c) => c.access },
      streamSimple: () => {},
    },
  ],
]);

await fire("session_start", {}, makeCtx());

// The picker must offer the extension-registered model: it is available in
// main's registry and resolvable in the branch runtime once its registration
// is copied across.
const command = commands.get("supervision-model");
if (!command) throw new Error("the supervision-model command was not registered");
uiSelections.push("devin/swe-1-7");
await command.handler("", makeCtx());
const offered = uiPrompts[0];
if (!offered.options.includes("devin/swe-1-7")) {
  throw new Error(`the picker must offer an extension-registered provider the branch can run: ${JSON.stringify(offered.options)}`);
}
if (readFileSync(`${home}/config/supervision-branch-model`, "utf8") !== "devin/swe-1-7\n") {
  throw new Error("the extension-registered pick was not persisted");
}
dispatch("signal: extension provider pin");
await settle(() => (globalThis.__fmSessions ?? []).length === 1, "pinned extension-provider branch build");
const pinned = globalThis.__fmSessions[0].options.model;
if (!pinned || pinned.provider !== "devin" || pinned.id !== "swe-1-7") {
  throw new Error(`the extension-registered pin did not bind the branch: ${JSON.stringify(pinned)}`);
}
// Copying the provider registration must not loosen the branch's isolation:
// the devin-pinned session still loads no extensions, skills, or context files.
const pinnedLoader = globalThis.__fmLoaders.at(-1);
for (const key of ["noExtensions", "noSkills", "noContextFiles"]) {
  if (pinnedLoader.options[key] !== true) throw new Error(`devin-pinned branch loader must keep ${key}`);
}

// Without the registration, the same pin is unavailable and the branch
// refuses to build rather than silently downgrading.
globalThis.__fmExtensionProviderConfigs = new Map();
await fire("session_shutdown", {});
await fire("session_start", {}, makeCtx());
const unregisteredOffer = dispatch("signal: unregistered provider pin");
if (!unregisteredOffer.accepted) throw new Error("unregistered-pin wake was not initially accepted");
const unregisteredFailure = await unregisteredOffer.settlement.then(
  () => null,
  (error) => error,
);
if (
  !(unregisteredFailure instanceof Error) ||
  !unregisteredFailure.message.includes("devin/swe-1-7") ||
  !unregisteredFailure.message.includes("supervision model pin")
) {
  throw new Error(`the unregistered pin did not reject with its own name: ${String(unregisteredFailure)}`);
}
if ((globalThis.__fmSessions ?? []).length !== 1) throw new Error("an unregistered pin must not build a second branch session");
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "an extension-registered provider must resolve in the isolated branch runtime: $out"
  pass "an extension-registered provider resolves in the isolated branch runtime"
}

continuation_ui_boundary_case() {
  local repo home out rc mode=$1
  repo="$TMP_ROOT/continuation-ui-root-$mode"; home="$TMP_ROOT/continuation-ui-home-$mode"
  install_pi_branch_extension_fixture "$repo"
  mkdir -p "$home/state" "$home/data/task"
  printf 'Verify UI-safe continuation.\n' >"$home/data/task/brief.md"
  cat >"$repo/bin/fm-task-state.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = observe ]; then touch "$FM_HOME/observing"; sleep 0.3; fi
exec "$REAL_ROOT/bin/fm-task-state.sh" "$@"
SH
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/"
  set +e
  out=$(FM_TEST_CONTINUATION_DELIVERY="$mode" PLUGIN="$repo/.pi/extensions/lib/fm-task-continuation.ts" REAL_ROOT="$ROOT" FM_ROOT_OVERRIDE="$repo" FM_HOME="$home" node --input-type=module 2>&1 <<'JS'
import {appendFileSync,existsSync,readFileSync,writeFileSync,mkdirSync,unlinkSync} from 'node:fs';
const home=process.env.FM_HOME,handlers=new Map(),events=new Map(),sent=[],entries=[];
const mode=process.env.FM_TEST_CONTINUATION_DELIVERY;
let blocking=false,idle=mode!=='settle';
const file=home+'/session.jsonl';
writeFileSync(home+'/state/.lock',process.pid+'\n');
writeFileSync(file,JSON.stringify({type:'session',id:'ui-regression',version:3})+'\n');
const ctx={isIdle:()=>idle,hasPendingMessages:()=>false,hasUI:false,ui:{getEditorText:()=>''},sessionManager:{getSessionFile:()=>file,getSessionId:()=> 'ui-regression',getLeafId:()=>entries.at(-1)?.id,getBranch:()=>entries,getEntries:()=>entries}};
function persist(row){row={...row,id:'e'+entries.length,parentId:entries.at(-1)?.id??null,timestamp:new Date().toISOString()};entries.push(row);appendFileSync(file,JSON.stringify(row)+'\n');}
const pi={on:(name,fn)=>handlers.set(name,[...(handlers.get(name)||[]),fn]),events:{on:(name,fn)=>events.set(name,[...(events.get(name)||[]),fn]),emit:(name,arg)=>{for(const fn of events.get(name)||[])fn(arg)}},registerTool(){},registerCommand(){},sendMessage:(message,options)=>{sent.push({message,options,blocking});persist({type:'custom_message',...message});},appendEntry:(customType,data)=>persist({type:'custom',customType,data})};
const fire=async(name)=>{const results=[];for(const fn of handlers.get(name)||[])results.push(await fn({},ctx));return results;};
const wait=async(predicate)=>{const until=Date.now()+10000;while(!predicate()&&Date.now()<until)await new Promise(r=>setTimeout(r,10));if(!predicate())throw Error('timed out');};
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const {installTaskContinuation}=await import(process.env.PLUGIN);
const periodic=(await import(process.env.REAL_ROOT+'/.pi/extensions/fm-periodic-stow.ts')).default;
const continuation=installTaskContinuation(pi,{root:process.env.FM_ROOT_OVERRIDE,home,state:home+'/state',owns:()=>true});
periodic(pi);
await fire('session_start');
await continuation.preserve(['task']);
const record=()=>JSON.parse(readFileSync(home+'/data/task/lifecycle.json'));
pi.events.emit('firstmate:heartbeat-tick',{});await sleep(100);
if(existsSync(home+'/observing'))throw Error('cold session without leaf claimed a receiver');
pi.appendEntry('seed',{});
const settling=mode==='settle'?fire('agent_before_settle'):Promise.resolve([]);
if(mode!=='settle')pi.events.emit('firstmate:heartbeat-tick',{});
await wait(()=>existsSync(home+'/observing'));
blocking=true;await fire('ui_prompt_start');
await wait(()=>record().coordination);
if((await settling).some(x=>x?.continue===true))throw Error('settle crossed blocking UI boundary');
idle=true;
await sleep(700);
if(sent.length)throw Error('notification crossed blocking UI boundary');
const budget=Object.values(record().coordination.budgets)[0];
if(budget.attempts!==1||!budget.reserved)throw Error('deferred reservation lost');
await fire('session_shutdown');await fire('session_start');
await fire('ui_prompt_start');
pi.events.emit('firstmate:heartbeat-tick',{});await sleep(1000);
if(sent.length||Object.values(record().coordination.budgets)[0].attempts!==1)throw Error('reload lost guard or reset budget');
blocking=false;await fire('ui_prompt_end');
pi.events.emit('firstmate:heartbeat-tick',{});
await wait(()=>sent.length===1);
if(sent[0].blocking||sent[0].message.details.admissions[0]!==budget.reserved)throw Error('safe release replaced reservation');
pi.events.emit('firstmate:heartbeat-tick',{});await sleep(1000);
if(sent.length!==1||Object.values(record().coordination.budgets)[0].attempts!==1)throw Error('safe release duplicated admission');
await fire('session_shutdown');await fire('session_start');
pi.events.emit('firstmate:heartbeat-tick',{});await sleep(1000);
if(sent.length!==1)throw Error('delivered reservation replayed after reload');
mkdirSync(home+'/data/task2');writeFileSync(home+'/data/task2/brief.md','Verify generation fencing.');
await continuation.preserve(['task2']);
unlinkSync(home+'/observing');
pi.events.emit('firstmate:heartbeat-tick',{});await wait(()=>existsSync(home+'/observing'));
await fire('session_shutdown');await fire('session_start');await sleep(1000);
if(sent.length!==1)throw Error('old asynchronous readback notified the replacement generation');
pi.events.emit('firstmate:heartbeat-tick',{});await wait(()=>sent.length===2);
if(!sent[1].message.content.includes('task2: pending'))throw Error('new generation lost pending task');
await fire('session_shutdown');
console.log(mode+': UI race deferred one durable admission; release delivered it once; reload preserved guard, receipt and budget');
JS
  )
  rc=$?
  set -e
  expect_code 0 "$rc" "continuation UI boundary: $out"
  pass "$out"
}

test_native_compact_continuation_with_installed_session_manager() {
  local repo home sdk
  sdk="${FM_PI_PACKAGE_DIR:-$(npm root -g)/@earendil-works/pi-coding-agent}"
  if [ ! -f "$sdk/dist/index.js" ]; then
    printf 'skip: semantic native workflow requires installed Pi SDK\n'
    return
  fi
  repo="$TMP_ROOT/semantic-native-root"
  home="$TMP_ROOT/semantic-native-home"
  install_pi_branch_extension_fixture "$repo"
  cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
  printf '#!/bin/sh\nprintf "watcher: healthy pid=1 (beacon 0s)\\n"\n' > "$repo/bin/fm-watch-arm.sh"
  # shellcheck disable=SC2016 # The fixture wrapper expands these values when it runs.
  printf '#!/bin/sh\nexec "$REAL_ROOT/bin/fm-task-state.sh" "$@"\n' > "$repo/bin/fm-task-state.sh"
  chmod +x "$repo/bin/fm-watch-arm.sh"
  chmod +x "$repo/bin/fm-task-state.sh"
  FM_HOME="$home" FM_NATIVE_SDK="$sdk" REAL_ROOT="$ROOT" \
    FM_ROOT_OVERRIDE="$repo" FM_NATIVE_WATCH_PLUGIN="$repo/.pi/extensions/fm-primary-pi-watch.ts" \
    PLUGIN="$repo/.pi/extensions/lib/fm-task-continuation.ts" \
    node "$ROOT/tests/lifecycle-native.mjs" || fail "installed SDK compact continuation workflow failed"
}

test_continuation_defers_reserved_admission_at_ui_boundary() {
  continuation_ui_boundary_case heartbeat
  continuation_ui_boundary_case settle
}

test_continuation_retries_definite_send_failure_and_isolates_stale_tasks() {
  local repo home out rc
  repo="$TMP_ROOT/continuation-failure-root"; home="$TMP_ROOT/continuation-failure-home"
  install_pi_branch_extension_fixture "$repo"
  mkdir -p "$home/state" "$home/data/healthy-one"
  printf 'Keep the first healthy task progressing.\n' >"$home/data/healthy-one/brief.md"
  cat >"$repo/bin/fm-task-state.sh" <<'SH'
#!/usr/bin/env bash
exec "$REAL_ROOT/bin/fm-task-state.sh" "$@"
SH
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/"
  set +e
  out=$(PLUGIN="$repo/.pi/extensions/lib/fm-task-continuation.ts" REAL_ROOT="$ROOT" FM_ROOT_OVERRIDE="$repo" FM_HOME="$home" node --input-type=module 2>&1 <<'JS'
import {createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {appendFileSync,mkdirSync,readFileSync,writeFileSync} from 'node:fs';
const home=process.env.FM_HOME,handlers=new Map(),events=new Map(),entries=[],effects=[];
const file=home+'/session.jsonl';
let sendMode='fail-before';
writeFileSync(home+'/state/.lock',process.pid+'\n');
writeFileSync(file,JSON.stringify({type:'session',id:'failure-regression',version:3})+'\n');
const ctx={isIdle:()=>true,hasPendingMessages:()=>false,hasUI:false,ui:{getEditorText:()=>''},sessionManager:{getSessionFile:()=>file,getSessionId:()=> 'failure-regression',getLeafId:()=>entries.at(-1)?.id,getBranch:()=>entries,getEntries:()=>entries}};
function persist(row){row={...row,id:'e'+entries.length,parentId:entries.at(-1)?.id??null,timestamp:new Date().toISOString()};entries.push(row);appendFileSync(file,JSON.stringify(row)+'\n');return row;}
const pi={on:(name,fn)=>handlers.set(name,[...(handlers.get(name)||[]),fn]),events:{on:(name,fn)=>events.set(name,[...(events.get(name)||[]),fn]),emit:(name,arg)=>{for(const fn of events.get(name)||[])fn(arg)}},registerTool(){},registerCommand(){},appendEntry:(customType,data)=>persist({type:'custom',customType,data}),sendMessage(message,options){
  if(sendMode==='fail-before')throw Error('definite pre-delivery refusal');
  effects.push({message,options});persist({type:'custom_message',...message});
  if(sendMode==='persist-throw')throw Error('transport result uncertain after persistence');
}};
const fire=async(name)=>{for(const fn of handlers.get(name)||[])await fn({},ctx);};
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const wait=async(predicate,label)=>{const until=Date.now()+10000;while(!predicate()&&Date.now()<until)await sleep(10);if(!predicate())throw Error('timed out: '+label);};
const tickUntil=async(predicate,label)=>{const until=Date.now()+10000;while(!predicate()&&Date.now()<until){pi.events.emit('firstmate:heartbeat-tick',{});await sleep(25);}if(!predicate())throw Error('timed out: '+label);};
const record=task=>JSON.parse(readFileSync(`${home}/data/${task}/lifecycle.json`));
const sha=path=>createHash('sha256').update(readFileSync(path)).digest('hex');
const {installTaskContinuation}=await import(process.env.PLUGIN);
const periodic=(await import(process.env.REAL_ROOT+'/.pi/extensions/fm-periodic-stow.ts')).default;
const continuation=installTaskContinuation(pi,{root:process.env.FM_ROOT_OVERRIDE,home,state:home+'/state',owns:()=>true});
periodic(pi);
await fire('session_start');pi.appendEntry('seed',{});
await continuation.preserve(['healthy-one']);
pi.events.emit('firstmate:heartbeat-tick',{});
await wait(()=>record('healthy-one').coordination,'failed submission reservation');
await sleep(100);
if(effects.length)throw Error('definite pre-delivery failure produced an effect');
sendMode='success';pi.events.emit('firstmate:heartbeat-tick',{});
await wait(()=>effects.length===1,'successful retry');
const firstAdmission=effects[0].message.details.admissions[0];
pi.events.emit('firstmate:heartbeat-tick',{});await sleep(300);
if(effects.length!==1||effects[0].message.details.admissions[0]!==firstAdmission)throw Error('successful retry was not delivered exactly once');

for(const task of ['healthy-two','stale']){mkdirSync(`${home}/data/${task}`);writeFileSync(`${home}/data/${task}/brief.md`,task+' initial brief\n');}
await continuation.preserve(['healthy-two','stale']);
writeFileSync(`${home}/data/stale/brief.md`,'stale changed brief\n');
continuation.capture('Already collected input must continue through this batch.','batch-input');
const receiptCursor=()=>entries.filter(e=>e.customType==='fm-continuation-receipt').at(-1)?.data.next_cursor;
const cursorBefore=receiptCursor();
pi.events.emit('firstmate:heartbeat-tick',{});
await wait(()=>effects.some(e=>e.message.details?.kind==='lifecycle-reconciliation'),'stale reconciliation');
const reconciliation=effects.find(e=>e.message.details?.kind==='lifecycle-reconciliation');
if(reconciliation.message.details.task!=='stale'||!reconciliation.message.content.includes('explicit reconciliation required'))throw Error('stale task did not surface a scoped reconciliation obligation');
if(record('stale').coordination)throw Error('stale task invented a coordination receiver');
const cursorAfterReconciliation=receiptCursor();
if(cursorAfterReconciliation===cursorBefore)throw Error('stale observation did not advance the bounded cursor');

sendMode='persist-throw';pi.events.emit('firstmate:heartbeat-tick',{});
await wait(()=>effects.some(e=>e.message.customType==='fm-task-continuation'&&e.message.content.includes('healthy-two: pending')),'healthy batch after stale task');
const batch=effects.find(e=>e.message.customType==='fm-task-continuation'&&e.message.content.includes('healthy-two: pending'));
if(batch.message.content.includes('Already collected input must continue through this batch.'))throw Error('chat became a task continuation goal');
if(!record('healthy-two').coordination)throw Error('stale task prevented healthy task coordination');
const effectCount=effects.length;
sendMode='success';pi.events.emit('firstmate:heartbeat-tick',{});await sleep(500);
if(effects.length!==effectCount)throw Error('uncertain persisted delivery was replayed');
if(receiptCursor()===cursorAfterReconciliation)throw Error('healthy follow-up did not keep the bounded cursor moving');

await fire('session_shutdown');await fire('session_start');await fire('session_compact');
pi.events.emit('firstmate:heartbeat-tick',{});await sleep(300);
if(effects.length!==effectCount)throw Error('reload or compaction replayed delivered reconciliation');
const reconciliationPace=entries.filter(e=>e.customType==='fm-continuation-input-pacing'&&e.data.id==='reconcile:stale').at(-1);
if(!reconciliationPace?.data.escalatedAt||reconciliationPace.data.recoveryAttempts!==0)throw Error('delivered reconciliation did not retain paced responsibility');
reconciliationPace.data.recoveryAfter=Date.now()-1;
await fire('session_shutdown');await fire('session_start');
await tickUntil(()=>effects.some(e=>e.message.details?.kind==='lifecycle-reconciliation'&&e.message.details.admissions.some(id=>id.startsWith('r.'))),'paced reconciliation recovery');
const recovery=effects.findLast(e=>e.message.details?.kind==='lifecycle-reconciliation'&&e.message.details.admissions.some(id=>id.startsWith('r.')));
if(!recovery.message.details.tasks.includes('stale')||!recovery.message.content.includes('Persistent recovery:'))throw Error('unchanged refusal lost persistent recovery responsibility');
const recoveryCount=effects.length;
await fire('session_shutdown');await fire('session_start');await fire('session_compact');
pi.events.emit('firstmate:heartbeat-tick',{});await sleep(300);
if(effects.length!==recoveryCount)throw Error('reload or compaction replayed delivered reconciliation recovery');

const stale=record('stale'),brief=`${home}/data/stale/brief.md`;
stale.brief_sha256=sha(brief);
stale.assessment.outcome='Changed brief explicitly reconciled; execution remains pending.';
stale.assessment.remaining_gap='Coordinate the reconciled task through its canonical lifecycle.';
stale.assessment.authority_ref=brief;
stale.assessment.evidence=[{ref:brief,sha256:sha(brief)}];
const proposal=`${home}/data/stale-reconciliation.json`;
writeFileSync(proposal,JSON.stringify(stale),{mode:0o600});
const reconciled=spawnSync(`${process.env.REAL_ROOT}/bin/fm-task-state.sh`,['reconcile','stale','--expected-revision',String(stale.revision),'--record',proposal],{env:{...process.env,FM_SUPERVISION_ACTOR:'main'},encoding:'utf8'});
if(reconciled.status!==0)throw Error(`actual reconciliation refused: ${reconciled.stderr}`);
await tickUntil(()=>effects.slice(recoveryCount).some(e=>e.message.customType==='fm-task-continuation'&&e.message.content.includes('stale: pending')),'canonical progress after reconciliation');
if(effects.slice(recoveryCount).some(e=>e.message.details?.kind==='lifecycle-reconciliation'&&e.message.details.tasks.includes('stale')))throw Error('successful observation retained stale reconciliation recovery');

for(const task of ['changed-generation','ambiguous-identity','healthy-three']){
  mkdirSync(`${home}/data/${task}`);writeFileSync(`${home}/data/${task}/brief.md`,task+' brief\n');
}
writeFileSync(`${home}/state/changed-generation.meta`,'spawn_gen=g1\n');
writeFileSync(`${home}/state/ambiguous-identity.meta`,'spawn_gen=g1\n');
await continuation.preserve(['changed-generation','ambiguous-identity','healthy-three']);
writeFileSync(`${home}/state/changed-generation.meta`,'spawn_gen=g2\n');
writeFileSync(`${home}/state/ambiguous-identity.meta`,'spawn_gen=g1\nspawn_gen=g1\n');
const refusalStart=effects.length;
await tickUntil(()=>effects.slice(refusalStart).some(e=>e.message.details?.kind==='lifecycle-reconciliation'),'generation and identity refusals');
const refusals=effects.slice(refusalStart).find(e=>e.message.details?.kind==='lifecycle-reconciliation');
if(!refusals.message.details.tasks.includes('changed-generation')||!refusals.message.content.includes('stale execution generation'))throw Error('changed-generation refusal was weakened');
if(!refusals.message.details.tasks.includes('ambiguous-identity')||!refusals.message.content.includes('duplicate execution identity'))throw Error('ambiguous-identity refusal was weakened');
if(record('changed-generation').coordination||record('ambiguous-identity').coordination)throw Error('refused identities invented canonical receivers');
await tickUntil(()=>effects.slice(refusalStart).some(e=>e.message.customType==='fm-task-continuation'&&e.message.content.includes('healthy-three: pending')),'healthy neighbor after identity refusals');
await fire('session_shutdown');
console.log('send failures dedupe; stale reconciliation recovers across reload and compaction while strict refusals preserve healthy progress');
JS
  )
  rc=$?
  set -e
  expect_code 0 "$rc" "continuation delivery failure and stale batch: $out"
  pass "$out"
}

test_continuation_defers_pending_short_receipt_at_public_boundary() {
  local repo home out rc
  repo="$TMP_ROOT/continuation-short-root"; home="$TMP_ROOT/continuation-short-home"
  install_pi_branch_extension_fixture "$repo"
  mkdir -p "$home/state" "$home/data/a-reserved" "$home/data/b-unrelated"
  printf 'Preserve a short-owned operation without replay.\n' >"$home/data/a-reserved/brief.md"
  printf 'Continue unrelated task processing.\n' >"$home/data/b-unrelated/brief.md"
  cat >"$repo/bin/fm-task-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "${1:-}" "${2:-}" >> "$FM_HOME/lifecycle-calls"
if [ "${1:-}" = coordinate ] && [ "${2:-}" = a-reserved ] && [ ! -e "$FM_HOME/injected" ]; then
  : > "$FM_HOME/injected"
  printf '{"fixture":"pending receipt"}\n' > "$FM_STATE_OVERRIDE/.short-operation-a-reserved.json"
fi
exec "$REAL_ROOT/bin/fm-task-state.sh" "$@"
SH
  chmod +x "$repo/bin/fm-task-state.sh"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/"
  set +e
  out=$(PLUGIN="$repo/.pi/extensions/lib/fm-task-continuation.ts" REAL_ROOT="$ROOT" FM_ROOT_OVERRIDE="$repo" FM_HOME="$home" node --input-type=module 2>&1 <<'JS'
import {appendFileSync,readFileSync,rmSync,writeFileSync} from 'node:fs';
const home=process.env.FM_HOME,handlers=new Map(),events=new Map(),entries=[];
const file=home+'/session.jsonl';
writeFileSync(home+'/state/.lock',process.pid+'\n');
writeFileSync(file,JSON.stringify({type:'session',id:'short-boundary',version:3})+'\n');
const ctx={isIdle:()=>true,hasPendingMessages:()=>false,hasUI:false,ui:{getEditorText:()=>''},sessionManager:{getSessionFile:()=>file,getSessionId:()=> 'short-boundary',getLeafId:()=>entries.at(-1)?.id,getBranch:()=>entries,getEntries:()=>entries}};
function persist(row){row={...row,id:'e'+entries.length,parentId:entries.at(-1)?.id??null,timestamp:new Date().toISOString()};entries.push(row);appendFileSync(file,JSON.stringify(row)+'\n');return row;}
const pi={on:(name,fn)=>handlers.set(name,[...(handlers.get(name)||[]),fn]),events:{on:(name,fn)=>events.set(name,[...(events.get(name)||[]),fn]),emit:(name,arg)=>{for(const fn of events.get(name)||[])fn(arg)}},registerTool(){},registerCommand(){},sendMessage(){throw Error('idle notification was not expected');},appendEntry:(customType,data)=>persist({type:'custom',customType,data})};
const fire=async(name)=>{const results=[];for(const fn of handlers.get(name)||[])results.push(await fn({type:name,entries:[],continue:false,context:{},outcome:'completed'},ctx));return results;};
const persistDrafts=results=>{for(const entry of results.filter(Boolean).flatMap(result=>result.entries||[]))persist(entry);};
const record=task=>JSON.parse(readFileSync(`${home}/data/${task}/lifecycle.json`));
const calls=()=>readFileSync(home+'/lifecycle-calls','utf8').trim().split('\n');
const {installTaskContinuation}=await import(process.env.PLUGIN);
const periodic=(await import(process.env.REAL_ROOT+'/.pi/extensions/fm-periodic-stow.ts')).default;
const continuation=installTaskContinuation(pi,{root:process.env.FM_ROOT_OVERRIDE,home,state:home+'/state',owns:()=>true});
periodic(pi);
await fire('session_start');pi.appendEntry('seed',{});
await continuation.preserve(['a-reserved','b-unrelated']);

// This is the public Pi boundary that produced the incident. The fixture adds
// the operation reservation after observe and before coordinate, reproducing
// the real TOCTOU without calling a private continuation helper.
const first=await fire('agent_before_settle');persistDrafts(first);
if(!first.some(result=>result?.continue))throw Error('unrelated task did not continue after the short receipt appeared');
if(record('a-reserved').coordination)throw Error('short-owned task invented a coordination receipt');
if(!record('b-unrelated').coordination)throw Error('unrelated task was not coordinated');
const pace=entries.filter(entry=>entry.customType==='fm-continuation-input-pacing'&&entry.data.id==='ownership:a-reserved').at(-1);
if(!pace?.data.key||pace.data.attempts!==1||pace.data.after<=Date.now())throw Error('temporary ownership was not durably paced');
if(calls().filter(call=>call==='coordinate a-reserved').length!==1)throw Error('reservation race was retried inside one boundary');

await fire('session_shutdown');await fire('session_start');
const reservedCallCount=calls().filter(call=>call.endsWith(' a-reserved')).length;
const paced=await fire('agent_before_settle');persistDrafts(paced);
if(calls().filter(call=>call.endsWith(' a-reserved')).length!==reservedCallCount)throw Error('restart bypassed the durable ownership backoff');

// Make the existing heartbeat-owned retry due while the live reservation is
// still present. It must remain a quiet deferral, not become an exception or
// an invented completion.
pi.appendEntry('fm-continuation-input-pacing',{id:'ownership:a-reserved',key:pace.data.key,attempts:pace.data.attempts,after:0});
await fire('session_shutdown');await fire('session_start');
const retryStarted=Date.now();
const stillOwned=await fire('agent_before_settle');persistDrafts(stillOwned);
if(stillOwned.some(result=>result?.continue&&JSON.stringify(result).includes('a-reserved')))throw Error('live short owner produced a continuation admission');
if(record('a-reserved').coordination)throw Error('live short owner was accepted without a receipt');
const retriedPace=entries.filter(entry=>entry.customType==='fm-continuation-input-pacing'&&entry.data.id==='ownership:a-reserved').at(-1);
if(retriedPace.data.attempts!==2||retriedPace.data.after<=pace.data.after||retriedPace.data.after<retryStarted+59000)throw Error(`repeated ownership did not increase durable backoff: ${JSON.stringify(retriedPace.data)}`);

// Once the fixture's reservation is released, the same public boundary may
// coordinate the unfinished task exactly once. No operation effect is ever
// called by this test or by the continuation extension.
rmSync(home+'/state/.short-operation-a-reserved.json');
const latest=entries.filter(entry=>entry.customType==='fm-continuation-input-pacing'&&entry.data.id==='ownership:a-reserved').at(-1);
pi.appendEntry('fm-continuation-input-pacing',{id:'ownership:a-reserved',key:latest.data.key,attempts:latest.data.attempts,after:0});
await fire('session_shutdown');await fire('session_start');
const releasedCoordinateCount=calls().filter(call=>call==='coordinate a-reserved').length;
const released=await fire('agent_before_settle');persistDrafts(released);
if(!released.some(result=>result?.continue&&JSON.stringify(result).includes('a-reserved: pending')))throw Error('released reservation did not resume its unfinished task');
if(!record('a-reserved').coordination)throw Error('released task lacks the canonical coordination receipt');
if(calls().filter(call=>call==='coordinate a-reserved').length!==releasedCoordinateCount+1)throw Error('released task did not coordinate exactly once');
if(calls().some(call=>/^(merge|cleanup) /.test(call)))throw Error('continuation replayed an operation effect');
console.log('public agent_before_settle keeps pending short ownership durable and paced; unrelated work continues; release resumes once without replay');
process.exit(0);
JS
  )
  rc=$?
  set -e
  expect_code 0 "$rc" "pending short receipt public event boundary: $out"
  pass "$out"
}

test_continuation_survives_ack_compaction_and_unrelated_input() {
  local repo home out rc
  repo="$TMP_ROOT/continuation-root"; home="$TMP_ROOT/continuation-home"
  install_pi_branch_extension_fixture "$repo"
  set +e
  out=$(PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module 2>&1 <<'JS'
await eval(`(async () => { ${process.env.DRIVER_PRELUDE}; globalThis.test = {fire, outcomeScript, mainTools, defaultSessionCtx, sentToMain, home, piHandlers, bus, pi}; })()`);
const {fire, outcomeScript, mainTools, defaultSessionCtx, sentToMain, home, piHandlers, bus, pi} = globalThis.test;
const {appendFileSync, mkdirSync, writeFileSync, readFileSync} = await import('node:fs');
const {spawnSync} = await import('node:child_process');
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const entries=[];
const file=`${home}/main.jsonl`;
writeFileSync(file,JSON.stringify({type:'session',version:3,id:'test-session'})+'\n');
Object.assign(defaultSessionCtx,{isIdle:()=>true,hasPendingMessages:()=>false,hasUI:false,ui:{getEditorText:()=>''}});
Object.assign(defaultSessionCtx.sessionManager,{getSessionId:()=> 'test-session',getLeafId:()=>entries.at(-1)?.id,
  getBranch:()=>entries,getEntries:()=>entries});
pi.appendEntry=(customType,data)=>{const e={type:'custom',id:`entry-${entries.length}`,parentId:entries.at(-1)?.id??null,customType,data};entries.push(e);appendFileSync(file,JSON.stringify(e)+'\n');};
pi.appendEntry('test-seed',{});
const periodic=await import(`${process.env.FM_ROOT_OVERRIDE}/.pi/extensions/fm-periodic-stow.ts`);
periodic.default(pi);
await fire('session_start', {}, defaultSessionCtx);
mkdirSync(`${home}/data/prerequisite`,{recursive:true});
writeFileSync(`${home}/data/prerequisite/brief.md`,'Apply prerequisite; verify operational acceptance.');
writeFileSync(`${home}/state/prerequisite.meta`,'spawn_gen=g1\nkind=ship\n');
const seq=Number(outcomeScript(['append','--task','prerequisite','--verdict','captain','--summary','Merged prerequisite needs an operator.']));
await fire('turn_end',{},defaultSessionCtx);
await fire('agent_settled',{},defaultSessionCtx);
const reader=mainTools.find(t=>t.name==='fm_branch_outcomes');
const ack=mainTools.find(t=>t.name==='fm_branch_processed');
await reader.execute('read',{sequences:String(seq)});
const result=await ack.execute('ack',{through:seq});
if(result.isError) throw Error(JSON.stringify(result));
if(outcomeScript(['unprocessed'])!=='') throw Error('presentation acknowledgement was not consumed');
const path=`${home}/data/prerequisite/lifecycle.json`;
if(JSON.parse(readFileSync(path)).disposition!=='open') throw Error('ack erased pending goal');

async function beforeSettle() {
  const results=[];
  for(const handler of piHandlers.get('agent_before_settle')||[]) results.push(await handler({},defaultSessionCtx));
  for(const entry of results.filter(Boolean).flatMap(r=>r.entries||[])) {
    const persisted={...entry,id:`entry-${entries.length}`,timestamp:new Date().toISOString()};
    entries.push(persisted);appendFileSync(file,JSON.stringify(persisted)+'\n');
  }
  return {continued:results.some(r=>r?.continue===true),content:results.filter(Boolean).flatMap(r=>r.entries||[]).map(e=>e.content).join('\n')};
}
const first=await beforeSettle();
if(!first.continued || !first.content.includes('prerequisite: pending')) throw Error(`missing continuation: ${JSON.stringify(first)}`);
const ignored=await beforeSettle();
if(ignored.continued) throw Error('settle bypassed persistent backoff');
const received=JSON.parse(readFileSync(path));
if(received.disposition!=='open' || received.coordination.receiver.owner!=='fm-periodic-stow') throw Error('settle did not retain actual coordinator receipt');
const continuationMessages=()=>sentToMain.filter(sent=>sent.message.customType==='fm-task-continuation');
async function waitForMessages(count) {
  for(let i=0;i<250 && continuationMessages().length<count;i+=1) await new Promise(resolve=>setTimeout(resolve,10));
  if(continuationMessages().length<count) throw Error(`missing continuation notification ${count}: ${JSON.stringify(continuationMessages())}`);
}
await fire('agent_settled',{},defaultSessionCtx);
bus.emit('firstmate:heartbeat-tick');
await new Promise(resolve=>setTimeout(resolve,100));
if(continuationMessages().length) throw Error('tick bypassed settlement admission budget');
await new Promise(resolve=>setTimeout(resolve,30_100));
const second=await beforeSettle();
if(!second.continued) throw Error('second paced admission missing');
const exhausted=await beforeSettle();
if(!exhausted.continued) throw Error('exhausted task did not start executable main coordination');
if(!exhausted.content.includes('Continuation needs executable main coordination:')) throw Error('exhausted task was silently abandoned');
const escalationEntries=()=>entries.filter(e=>e.customType==='fm-task-continuation-escalation');
if(escalationEntries().length!==1 || !escalationEntries()[0].display) throw Error('missing visible native escalation');
await beforeSettle();
const escalated=JSON.parse(readFileSync(path));
if(!Object.values(escalated.coordination.budgets)[0].escalated_at_ms || escalated.next_action!==null) throw Error('escalation readback missing or invented task action');
await fire('session_shutdown',{},defaultSessionCtx);
await fire('session_start',{},defaultSessionCtx);
if((await beforeSettle()).continued) throw Error('reload reset task budget or duplicated executable escalation');
if(escalationEntries().length!==1) throw Error('reload duplicated escalation');
await fire('session_compact',{},defaultSessionCtx);
await fire('before_agent_start',{prompt:'Separate request B: explain configuration.'},defaultSessionCtx);
const next=await beforeSettle();
if(next.continued) throw Error('ordinary question became an independent continuation');
if(escalationEntries().length!==1) throw Error('compaction or chat duplicated task escalation');
const tool=mainTools.find(t=>t.name==='fm_task_continuation');
const listing=JSON.parse((await tool.execute('list',{action:'list'},undefined,undefined,defaultSessionCtx)).content[0].text);
if(listing.pending_updates.length || 'inputs' in listing) throw Error('chat acquired input bookkeeping');
if(JSON.parse(readFileSync(path)).disposition!=='open') throw Error('retry budget exhaustion closed goal');
// Unchanged evidence survives exhausted ordinary attempts. Only the existing
// heartbeat may deliver a later recovery, and UI safety still takes priority.
const recoveryDue=Object.values(JSON.parse(readFileSync(path)).coordination.budgets)[0].recovery_not_before_ms;
let draft='draft';defaultSessionCtx.ui.getEditorText=()=>draft;
await new Promise(resolve=>setTimeout(resolve,Math.max(0,recoveryDue-Date.now()+100)));
if((await beforeSettle()).continued) throw Error('settle immediately executed paced recovery');
const reservedRecovery=Object.values(JSON.parse(readFileSync(path)).coordination.budgets)[0];
if(reservedRecovery.attempts!==2||reservedRecovery.recovery_attempts!==1||!reservedRecovery.recovery_reserved) throw Error('recovery reset original attempts or lost reservation');
bus.emit('firstmate:heartbeat-tick');await new Promise(resolve=>setTimeout(resolve,500));
if(sentToMain.some(x=>x.message.details?.admissions?.includes(reservedRecovery.recovery_reserved))) throw Error('recovery interrupted editor input');
const originalSend=pi.sendMessage;
pi.sendMessage=(message,options)=>{
 originalSend(message,options);
 const persisted={type:'custom_message',...message,id:`entry-${entries.length}`,timestamp:new Date().toISOString()};
 entries.push(persisted);appendFileSync(file,JSON.stringify(persisted)+'\n');
};
draft='';bus.emit('firstmate:heartbeat-tick');
for(let i=0;i<200&&!sentToMain.some(x=>x.message.details?.admissions?.includes(reservedRecovery.recovery_reserved));i++) await new Promise(r=>setTimeout(r,10));
if(!sentToMain.some(x=>x.message.details?.admissions?.includes(reservedRecovery.recovery_reserved)&&x.options.triggerTurn)) throw Error('paced recovery did not start an executable turn');
await beforeSettle();
await fire('session_shutdown',{},defaultSessionCtx);await fire('session_start',{},defaultSessionCtx);
await fire('session_compact',{},defaultSessionCtx);
if((await beforeSettle()).continued) throw Error('reload/compaction replayed recovery');
const recovered=Object.values(JSON.parse(readFileSync(path)).coordination.budgets)[0];
if(recovered.attempts!==2||recovered.recovery_attempts!==1||recovered.recovery_reserved||recovered.recovery_not_before_ms<=Date.now()+110000) throw Error('recovery did not retain separate durable backoff');
// A material observation changes the fingerprint and earns one fresh check.
const r=JSON.parse(readFileSync(path));r.assessment.remaining_gap='Apply now-authorized prerequisite, then validate.';
writeFileSync(`${home}/data/proposal.json`,JSON.stringify(r),{mode:0o600});
const cmd=spawnSync(`${process.env.FM_ROOT_OVERRIDE}/bin/fm-task-state.sh`,['reconcile','prerequisite','--expected-revision',String(r.revision),'--record',`${home}/data/proposal.json`],{env:{...process.env,FM_SUPERVISION_ACTOR:'main'},encoding:'utf8'});
if(cmd.status!==0) throw Error(cmd.stderr);
if(!(await beforeSettle()).content.includes('prerequisite: pending')) throw Error('new actionable evidence suppressed');
if((await beforeSettle()).continued) throw Error('changed evidence bypassed backoff on repeat');
// A real bound dependency stays silent; its release triggers one exact check.
const {createHash}=await import('node:crypto');
const sha=(p)=>createHash('sha256').update(readFileSync(p)).digest('hex');
writeFileSync(`${home}/data/release`,'awaiting exact authorization');
const blocked=JSON.parse(readFileSync(path));
blocked.next_action_seq=2;
blocked.next_action={id:'prerequisite.g1.a1',kind:'wait',phase:'prepared',expected_execution_generation:'g1',attempts:0,attempt_limit:2,
  recheck_at:'2026-01-01T00:00:00Z',deadline:'2099-01-01T00:00:00Z',payload_ref:'data/release',payload_sha256:sha(`${home}/data/release`),receipt_ref:null,
  continuation:{type:'blocker',owner:'dependency-owner',dependency:'exact operation authorization',release_ref:'data/release',release_sha256:sha(`${home}/data/release`),recovery_trigger:'evidence-change'}};
writeFileSync(`${home}/data/proposal.json`,JSON.stringify(blocked));
const block=spawnSync(`${process.env.FM_ROOT_OVERRIDE}/bin/fm-task-state.sh`,['reconcile','prerequisite','--expected-revision',String(blocked.revision),'--record',`${home}/data/proposal.json`],{env:{...process.env,FM_SUPERVISION_ACTOR:'main'},encoding:'utf8'});
if(block.status!==0) throw Error(block.stderr);

if((await beforeSettle()).continued) throw Error('genuine unchanged blocker resumed');
writeFileSync(`${home}/data/release`,'exact authorization recorded');
if(!(await beforeSettle()).content.includes('dependency evidence changed')) throw Error('dependency release lost continuation');
if((await beforeSettle()).continued) throw Error('released dependency bypassed backoff on repeat');
writeFileSync(`${home}/data/release`,'awaiting exact authorization');
writeFileSync(`${home}/data/acceptance`,'Requested prerequisite and acceptance checks verified by main.');
const acceptedReceipt=spawnSync(`${process.env.FM_ROOT_OVERRIDE}/bin/fm-task-state.sh`,['action','prerequisite','--action-id',blocked.next_action.id,'--phase','refused','--receipt-ref','data/acceptance','--receipt-sha256',sha(`${home}/data/acceptance`)],{env:{...process.env,FM_SUPERVISION_ACTOR:'main'},encoding:'utf8'});
if(acceptedReceipt.status!==0) throw Error(acceptedReceipt.stderr);
const accepted=JSON.parse(readFileSync(path));
accepted.disposition='accepted';accepted.assessment.remaining_gap='';accepted.assessment.outcome='Requested prerequisite verified';
accepted.assessment.evidence.push({ref:'data/acceptance',sha256:sha(`${home}/data/acceptance`)});
writeFileSync(`${home}/data/proposal.json`,JSON.stringify(accepted));
const accept=spawnSync(`${process.env.FM_ROOT_OVERRIDE}/bin/fm-task-state.sh`,['reconcile','prerequisite','--expected-revision',String(accepted.revision),'--record',`${home}/data/proposal.json`],{env:{...process.env,FM_SUPERVISION_ACTOR:'main'},encoding:'utf8'});
if(accept.status!==0) throw Error(accept.stderr);
if((await beforeSettle()).continued) throw Error('semantic acceptance remained settlement-blocked');

await fire('session_shutdown',{},defaultSessionCtx);
console.log('continuation survived ack, compaction and later input; changed evidence rechecks once, unchanged waits stay quiet');
process.exit(0);
JS
  )
  rc=$?
  set -e
  expect_code 0 "$rc" "continuation extension public behavior: $out"
  pass "$out"
}

test_short_task_success_reaches_main_with_authenticated_body() {
  local repo home out status
  repo="$TMP_ROOT/short-result-root"
  home="$TMP_ROOT/short-result-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  set +e
  out=$(PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { pi, fire, settle, sentToMain, mainEntries, mainTools, defaultSessionCtx, home, bus, realRoot }; })()`);
const { pi, fire, settle, sentToMain, mainEntries, mainTools, defaultSessionCtx, home, bus, realRoot } = globalThis.__t;
import { mkdirSync, unlinkSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
const { ShortAgents } = await import(pathToFileURL(join(realRoot, "bin/fm-short-agent.mjs")).href);

writeFileSync(`${home}/state/.lock`, `${process.ppid}\n`);
await fire("session_start", {}, defaultSessionCtx);
const service = new ShortAgents(home, realRoot);
const seed = (character, summary, operations, receipt, state = "completed") => {
  const id = `short-${character.repeat(64)}`;
  const dir = service.dir(id);
  mkdirSync(dir, { recursive: true });
  const nonce = `nonce-${character}`;
  const input = { key: `key-${character}`, goal: "fixture", acceptance: "fixture", provider: "fixture", model: "fixture", materials: [], ...(operations ? { operations } : {}) };
  writeFileSync(join(dir, "request.json"), `${JSON.stringify({ version: 2, id, input, materials: [], acceptedAt: Date.now(), nonce, sdk: "/unused" })}\n`);
  writeFileSync(join(dir, "result.json"), `${JSON.stringify({ id, state, summary, finishedAt: Date.now(), evidence: dir })}\n`);
  if (receipt) writeFileSync(join(dir, "operation-0.receipt.json"), `${JSON.stringify({ id, nonce, index: 0, action: "sync", state: "completed", at: Date.now(), executor: { pid: 1 }, evidence: { head: "a".repeat(40) } })}\n`);
  return { id, dir };
};
const requests = () => sentToMain.filter((sent) => sent.message.customType === "fm-branch-process");
const acknowledge = mainTools.find((tool) => tool.name === "fm_branch_processed");
const outcomes = mainTools.find((tool) => tool.name === "fm_branch_outcomes");

const analysis = seed("a", "Measured 42 from m1; no caveats.");
await service.notify(analysis.id);
bus.emit("firstmate:outcomes-ready", {});
await settle(() => requests().length === 1, "direct read-only ShortTask result");
let request = requests().at(-1);
if (!request.message.content.includes("Authenticated ShortTask result:") || !request.message.content.includes("Measured 42 from m1; no caveats.")) throw new Error(`MAIN did not receive the read-only result body: ${request.message.content}`);
if (!request.message.content.includes("do not call fm_branch_outcomes")) throw new Error("direct ShortTask result still demanded a lookup");
let visible = mainEntries.filter((entry) => entry.customType === "fm-branch-visible-outcome" && entry.data.task === analysis.id);
if (visible.length !== 1 || !visible[0].data.summary.includes("Measured 42 from m1; no caveats.")) throw new Error("read-only result was not visibly delivered exactly once");
await fire("session_compact", { reason: "threshold", willRetry: false }, defaultSessionCtx);
let ack = await acknowledge.execute("ack-analysis", { through: visible[0].data.seq }, undefined, undefined, {});
if (ack.isError) throw new Error(`authenticated inline result lost its acknowledgement evidence across compaction: ${JSON.stringify(ack)}`);

const operations = { authority: "fixture", expiresAt: Date.now() + 60000, steps: [{ action: "sync", project: "/fixture" }] };
const operation = seed("b", "Sync completed with the owner-confirmed postcondition. Caveat: cleanup was not granted.", operations, true);
await service.notify(operation.id);
bus.emit("firstmate:outcomes-ready", {});
await settle(() => requests().length === 2, "direct operation ShortTask result");
request = requests().at(-1);
if (!request.message.content.includes("Sync completed with the owner-confirmed postcondition. Caveat: cleanup was not granted.")) throw new Error("MAIN did not receive the complete operation result body and caveat");
if (!request.message.content.includes('Verified operation receipts:') || !request.message.content.includes(`\"head\":\"${"a".repeat(40)}\"`)) throw new Error(`MAIN did not receive the exact operation receipt: ${request.message.content}`);
visible = mainEntries.filter((entry) => entry.customType === "fm-branch-visible-outcome" && entry.data.task === operation.id);
if (visible.length !== 1) throw new Error("operation result visible delivery duplicated");
ack = await acknowledge.execute("ack-operation", { through: visible[0].data.seq }, undefined, undefined, {});
if (ack.isError) throw new Error(`direct operation result was not preloaded for acknowledgement: ${JSON.stringify(ack)}`);

const asciiEdge = seed("d", "a".repeat(4096));
const unicodeEdge = seed("e", "😀".repeat(4096));
const unicodeOver = seed("f", "🧭".repeat(4097), operations, true);
const extremeMarker = "EXTREME_RESULT_BODY_MUST_STAY_OUT_OF_AUTOMATIC_DELIVERY";
const extremeSummary = `${extremeMarker}${"z".repeat(200000)}`;
const extreme = seed("1", extremeSummary);
for (const item of [asciiEdge, unicodeEdge, unicodeOver, extreme]) await service.notify(item.id);
// Simulate recovery after the notification receipt is lost. The outcome
// store's task key must keep the large completion single and body-free.
unlinkSync(join(unicodeOver.dir, "notified.json"));
await service.notify(unicodeOver.id);
bus.emit("firstmate:outcomes-ready", {});
await settle(() => requests().length === 3, "bounded ShortTask result notifications");
request = requests().at(-1);
if (!request.message.content.includes("a".repeat(4096)) || !request.message.content.includes("😀".repeat(4096))) throw new Error("the inclusive Unicode threshold stopped ordinary results from remaining inline");
if (!request.message.content.includes(`task=${unicodeOver.id}\nAuthenticated ShortTask result reference:`) ||
    !request.message.content.includes(`task=${extreme.id}\nAuthenticated ShortTask result reference:`)) throw new Error(`oversized results did not retain authenticated references: ${request.message.content}`);
if (request.message.content.includes(extremeMarker) || request.message.content.includes("🧭".repeat(32))) throw new Error("an oversized result body entered the hidden MAIN processing request");
if (!request.message.content.includes("call fm_short_task with action=result") || request.message.content.includes("call fm_branch_outcomes with exactly those sequences")) throw new Error("reference-only results did not select their single authenticated on-demand load");
const largeVisible = mainEntries.filter((entry) => entry.customType === "fm-branch-visible-outcome" && [unicodeOver.id, extreme.id].includes(entry.data.task));
if (largeVisible.length !== 2 || largeVisible.some((entry) => [...entry.data.summary].length > 1024)) throw new Error("oversized visible notices were missing or unbounded");
if (largeVisible.some((entry) => entry.data.summary.includes(extremeMarker) || entry.data.summary.includes("🧭".repeat(32)))) throw new Error("an arbitrary oversized body became its own visible summary");
if (!largeVisible.find((entry) => entry.data.task === unicodeOver.id)?.data.summary.includes("Verified operation receipts: 1")) throw new Error("the oversized operation notice lost its verified receipt distinction");
if (mainEntries.filter((entry) => entry.customType === "fm-branch-visible-outcome" && entry.data.task === unicodeOver.id).length !== 1) throw new Error("notification retry duplicated an oversized visible outcome");
const largeSeqs = largeVisible.map((entry) => entry.data.seq).sort((a, b) => a - b);
const refusedLargeAck = await acknowledge.execute("ack-reference-before-load", { through: Math.max(...largeSeqs) }, undefined, undefined, {});
if (!refusedLargeAck.isError || !refusedLargeAck.content[0].text.includes("using the retrieval method named in the active processing request") || refusedLargeAck.content[0].text.includes("with fm_branch_outcomes")) throw new Error("reference-only results bypassed the evidence-load acknowledgement gate or received impossible recovery guidance");
await fire("agent_settled", {}, defaultSessionCtx);
await settle(() => requests().length === 4, "reference-only ShortTask re-presentation");
const repeatedReference = requests().at(-1).message.content;
if (repeatedReference.includes(extremeMarker) || repeatedReference.includes("🧭".repeat(32)) || !repeatedReference.includes("Authenticated ShortTask result reference:")) throw new Error("reference-only re-presentation inserted a full result body or lost its authenticated reference");
await fire("session_shutdown", {}, defaultSessionCtx);
await fire("session_start", {}, defaultSessionCtx);
await settle(() => requests().length === 5, "reference-only ShortTask session recovery");
const recoveredReference = requests().at(-1).message.content;
if (recoveredReference.includes(extremeMarker) || recoveredReference.includes("🧭".repeat(32)) || !recoveredReference.includes("Authenticated ShortTask result reference:")) throw new Error("reference-only session recovery inserted a full result body or lost its authenticated reference");
if (mainEntries.filter((entry) => entry.customType === "fm-branch-visible-outcome" && entry.data.task === unicodeOver.id).length !== 1) throw new Error("session recovery duplicated an oversized visible outcome");
const loadedReferences = await outcomes.execute("load-large-references", { sequences: largeSeqs.join(",") }, undefined, undefined, {});
if (loadedReferences.isError || loadedReferences.content[0].text.includes(extremeMarker) || !loadedReferences.content[0].text.includes("Durable result relative to FM_HOME")) throw new Error(`authenticated reference load failed or exposed the full body: ${JSON.stringify(loadedReferences)}`);
pi.events.emit("firstmate:short-result-loaded", { id: extreme.id, summary: "spoofed result" });
const refusedNoticeOnlyAck = await acknowledge.execute("ack-reference-notice-only", { through: Math.max(...largeSeqs) }, undefined, undefined, {});
if (!refusedNoticeOnlyAck.isError || !refusedNoticeOnlyAck.content[0].text.includes("load exact durable outcome evidence first")) throw new Error("loading only the bounded notice satisfied a full-result acknowledgement");
for (const [item, expected] of [[unicodeOver, "🧭".repeat(4097)], [extreme, extremeSummary]]) {
  const loaded = JSON.parse(execFileSync(process.execPath, [join(realRoot, "bin/fm-short-agent.mjs"), "result", item.id], { env: { ...process.env, FM_HOME: home }, encoding: "utf8", maxBuffer: 1024 * 1024 }));
  if (loaded.summary !== expected) throw new Error(`explicit result retrieval changed ${item.id}`);
  pi.events.emit("firstmate:short-result-loaded", { id: item.id, summary: loaded.summary });
}
ack = await acknowledge.execute("ack-bounded-results", { through: Math.max(...largeSeqs) }, undefined, undefined, {});
if (ack.isError) throw new Error(`loaded result references could not be acknowledged: ${JSON.stringify(ack)}`);

const cancelled = seed("c", "authority revoked; active effects may be partial or uncertain", undefined, false, "cancelled");
await service.notify(cancelled.id);
bus.emit("firstmate:outcomes-ready", {});
await settle(() => requests().length === 6, "cancelled ShortTask recovery result");
request = requests().at(-1);
if (request.message.content.includes("Authenticated ShortTask result:")) throw new Error("a cancelled ShortTask was relabeled as direct success");
if (!request.message.content.includes("call fm_branch_outcomes with exactly those sequences")) throw new Error("an unavailable success body lost the durable recovery path");
visible = mainEntries.filter((entry) => entry.customType === "fm-branch-visible-outcome" && entry.data.task === cancelled.id);
const recovered = await outcomes.execute("recover-cancelled", { sequences: String(visible[0].data.seq) }, undefined, undefined, {});
if (recovered.isError || !recovered.content[0].text.includes("cancelled. Full result:")) throw new Error("durable recovery did not preserve the cancelled terminal state");
ack = await acknowledge.execute("ack-cancelled", { through: visible[0].data.seq }, undefined, undefined, {});
if (ack.isError) throw new Error(`recovered cancelled result could not be acknowledged: ${JSON.stringify(ack)}`);

bus.emit("firstmate:outcomes-ready", {});
await new Promise((resolve) => setTimeout(resolve, 100));
if (requests().length !== 6 || mainEntries.filter((entry) => entry.customType === "fm-branch-visible-outcome").length !== 7) throw new Error("reconciliation duplicated an acknowledged ShortTask notification");
console.log("short results stayed inline across compaction; Unicode-edge, oversized, repeated reference presentation, explicit retrieval, cancellation and durable exact-once delivery stayed intact");
EOF
  )
  status=$?
  set -e
  expect_code 0 "$status" "authenticated ShortTask public notification boundary: $out"
  pass "$out"
}

test_compact_progress_drives_branch_same_worker_continuation
test_outcomes_tool_uses_stock_execution_and_export_consumers
test_real_pi_picker_primitives_stay_bounded_and_searchable
test_branch_dispatch_two_stage_filter_and_prefix_contract
test_requested_healthy_outcome_and_unsolicited_routine_outcome_delivery
test_captain_outcome_is_exactly_once_across_crash_reload_and_unrelated_response
test_captain_outcome_processing_turn_is_sequence_keyed_and_re_presented
test_short_task_success_reaches_main_with_authenticated_body
test_branch_dispatch_classifies_main_only_rows_and_writes_the_eligible_snapshot
test_branch_dispatch_routes_only_identity_bound_ida_results
test_branch_cache_key_is_per_home_stable
test_branch_default_on_heartbeat_afk_and_fallback
test_branch_predrain_recheck_keeps_a_heartbeat_a_co_present_check_arrives_under
test_branch_report_refuses_a_task_the_wake_did_not_name
test_branch_predrain_recheck_excludes_new_main_owned_row_without_deferring_eligible_work
test_branch_predrain_needs_decision_keeps_routine_row_branch_eligible
test_settled_branch_prompt_releases_unacknowledged_grant
test_busy_branch_declines_an_unowned_ida_result
test_transient_reconcile_failure_recovers_without_reset_and_persistent_failures_back_off
test_post_construction_provider_error_falls_back_latches_and_recovers_on_cooldown
test_selection_change_does_not_corrupt_inflight_provider_state
test_main_owned_grant_result_falls_back_to_main
test_branch_admission_rechecks_retirement_and_endpoint_reuse
test_branch_predrain_recheck_noops_already_drained_wake
test_branch_mirror_filters_order_and_cursor
test_branch_mirror_reanchors_for_the_new_session_branch_conversation
test_branch_session_is_new_at_every_main_session_start
test_codex_branch_initializes_only_the_compat_package_before_prompting
test_non_codex_branch_does_not_depend_on_the_compat_package
test_codex_compat_package_failures_return_the_wake_to_main
test_supervision_reset_aborts_rotates_and_reanchors_without_touching_main_or_feishu
test_repeated_supervision_reset_before_the_next_wake_releases_the_absent_grant_vacuously
test_branch_model_pin_applies_and_absent_pin_keeps_the_default
test_unpinned_branch_follows_main_model_changes_live
test_supervision_model_command_persists_and_rebinds_the_live_branch
test_supervision_model_picker_is_bounded_searchable_and_branch_only
test_branch_model_picker_keeps_follow_main_first_under_ranking
test_branch_effort_pin_applies_and_absent_pin_follows_main
test_unpinned_branch_follows_main_effort_changes_live
test_extension_registered_provider_resolves_in_the_branch
test_supervision_model_command_picks_effort_after_the_model
test_unusable_model_pin_falls_back_to_main
test_replacement_activation_cleans_leases_and_retries_failure
test_cold_start_activates_after_lock_acquisition
test_queued_actions_recheck_lock_ownership
test_stale_generation_boundaries_are_side_effect_free
test_secondary_session_stays_inert
test_rebind_remirrors_undelivered_dialog_from_durable_cursor
test_delivery_keeps_the_event_loop_live_and_ordered
test_session_replacement_during_delivery_neither_loses_nor_duplicates
test_store_failure_during_delivery_neither_loses_nor_duplicates
test_mark_read_failure_keeps_routine_redelivery_and_captain_deduplication
test_expired_delegation_refuses_bound_branch_report
test_native_compact_continuation_with_installed_session_manager
