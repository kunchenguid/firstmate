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
    "$repo/node_modules/@earendil-works/pi-tui" \
    "$repo/node_modules/typebox"
  cp "$EXT" "$repo/.pi/extensions/fm-branch-supervision.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
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

export class UserMessageComponent {}

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
}

export function createBashToolDefinition(cwd, options) {
  return {
    name: "bash",
    label: "stub bash",
    description: "stub bash",
    parameters: { type: "object" },
    __cwd: cwd,
    __options: options,
    execute: async () => ({ content: [], details: undefined }),
  };
}

export async function createAgentSession(options) {
  if (globalThis.__fmCreateSessionError) throw new Error(globalThis.__fmCreateSessionError);
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
  (globalThis.__fmSessions ??= []).push(session);
  return { session, extensionsResult: {} };
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
DRIVER_PRELUDE=$(cat <<'JS'
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
  registerCommand() {},
  registerMessageRenderer(customType, renderer) {
    renderers.set(customType, renderer);
  },
  sendMessage(message, options) {
    sentToMain.push({ message, options: options ?? {} });
  },
  sendUserMessage(content, options) {
    mainUserMessages.push({ content, options: options ?? {} });
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
)

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

test_branch_predrain_recheck_defers_new_main_owned_row() {
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
const offer = dispatch("heartbeat", [], true, true);
if (!offer.accepted) throw new Error("eligible heartbeat offer was not accepted");
appendFileSync(`${home}/state/.wake-queue`, "2\t2\tcheck\tx-inbox\tcheck: pending x mention\n");
for (let i = 0; i < 250 && mainUserMessages.length === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if ((globalThis.__fmPrompts ?? []).length !== 0) {
  throw new Error("branch prompted after a main-owned row arrived before drain");
}
if (mainUserMessages.length !== 1 || !String(mainUserMessages[0].content).includes("FIRSTMATE WATCHER WAKE: heartbeat")) {
  throw new Error(`mixed queue did not fall back to main: ${JSON.stringify(mainUserMessages)}`);
}
const queue = readFileSync(`${home}/state/.wake-queue`, "utf8");
if (!queue.includes("\theartbeat\t") || !queue.includes("\tcheck\t")) {
  throw new Error(`pre-drain fallback mutated the queued set: ${queue}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "pre-drain eligibility re-check must defer the whole mixed queue to main: $out"
  pass "pre-drain eligibility re-check defers a newly main-owned row"
}

# The non-heartbeat half of the same recheck: a check-kind row that arrives
# after a signal/stale offer is accepted must stay main-owned WITHOUT bouncing
# the branch's own eligible row back to main - the reproduction from the task
# (docs/watcher-continuity.md "Per-actor acknowledgement"). Heartbeat keeps
# its own, unchanged, all-or-nothing rule (proven above); this is the case
# scopeForUnreadWake changed.
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
  { type: "message", message: { role: "user", content: "never merge task-7 without my word" } },
  { type: "message", message: { role: "assistant", content: [{ type: "text", text: "aye, holding task-7" }, { type: "toolCall", id: "t1" }] } },
  { type: "message", message: { role: "user", content: "⁣FIRSTMATE_OP: v1 watcher: operational injection" } },
  { type: "message", message: { role: "toolResult", content: "tool output stays in main" } },
  { type: "custom", message: { role: "custom", customType: "fm-branch-merge", content: "merged note" } },
  { type: "compaction", summary: "compacted" },
  { type: "message", message: { role: "user", content: `pad ${"x".repeat(5000)}` } },
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
if (mirrored[0].content !== "[captain] never merge task-7 without my word") throw new Error(`bad captain mirror: ${mirrored[0].content}`);
if (mirrored[1].content !== "[main] aye, holding task-7") throw new Error(`bad main mirror: ${mirrored[1].content}`);
if (!mirrored[2].content.includes("[mirror truncated at 4000 characters]")) throw new Error("long dialog was not capped");
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

// heartbeat keeps its own unchanged all-or-nothing rule: the same main-only
// row that is merely excluded for a non-heartbeat scan still vetoes a
// heartbeat review outright.
const heartbeatMixed = scopeForUnreadWake(state, true);
if (heartbeatMixed.eligible || !heartbeatMixed.corrupted) {
  throw new Error(`a main-only row must still veto a heartbeat review: ${JSON.stringify(heartbeatMixed)}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "main-only classification and eligible-row snapshot contract must hold: $out"
  pass "scopeForUnreadWake excludes every main-only class without vetoing eligible task-local rows, and writes the eligible snapshot"
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
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$fixture/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$fixture/.pi/extensions/lib/fm-operational-input.ts"
  ln -s "$package_dir" "$fixture/node_modules/@earendil-works/pi-coding-agent"
  ln -s "$package_dir/node_modules/@earendil-works/pi-tui" "$fixture/node_modules/@earendil-works/pi-tui"
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
  content: [{ type: "text", text: "\x1b[31mOUTCOME_ONE\x1b[0m\r\nOUT\u0000COME_TWO\uFFF9" }],
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
if (JSON.stringify(actualRow.render(100)) !== JSON.stringify(stockRow.render(100))) {
  throw new Error("Calm-off ToolExecutionComponent rendering differs from Pi stock");
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
test_branch_dispatch_two_stage_filter_and_prefix_contract
test_branch_dispatch_classifies_main_only_rows_and_writes_the_eligible_snapshot
test_branch_cache_key_is_per_home_stable
test_branch_default_on_heartbeat_afk_and_fallback
test_branch_predrain_recheck_defers_new_main_owned_row
test_branch_predrain_recheck_excludes_new_main_owned_row_without_deferring_eligible_work
test_settled_branch_prompt_releases_unacknowledged_grant
test_main_owned_grant_result_falls_back_to_main
test_branch_predrain_recheck_noops_already_drained_wake
test_branch_mirror_filters_order_and_cursor
test_branch_session_persists_across_process_restarts
test_replacement_activation_cleans_leases_and_retries_failure
test_cold_start_activates_after_lock_acquisition
test_queued_actions_recheck_lock_ownership
test_stale_generation_boundaries_are_side_effect_free
test_secondary_session_stays_inert
test_rebind_remirrors_undelivered_dialog_from_durable_cursor
