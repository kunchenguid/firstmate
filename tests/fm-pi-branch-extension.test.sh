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
// Most drivers exercise an explicitly granted project. Consent-gating cases
// opt out so they can prove that absence itself preserves old behavior.
if (!process.env.FM_TEST_SKIP_BRANCH_GRANT) {
  writeFileSync(`${home}/config/pi-supervision-branch`, `project=${approvedProject}\n`);
}
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
function makeOffer(message, projects = [approvedProject]) {
  const offer = {
    message,
    projects,
    accepted: false,
    accept() {
      offer.accepted = true;
    },
  };
  return offer;
}
function dispatch(message, projects) {
  const offer = makeOffer(message, projects);
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
const { fire, dispatch, settle, outcomeScript, sentToMain, mainUserMessages, mainTools, renderers, home, realRoot } = globalThis.__t;
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
if (typeof sentToMain[2].message.content !== "string" || !sentToMain[2].message.content.startsWith("⚓ ")) {
  throw new Error(`captain note missing anchor prefix: ${sentToMain[2].message.content}`);
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
assertRenderedNote(sentToMain[2].message.content, "⚓");
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

test_branch_gating_config_afk_and_fallback() {
  local repo broken home out status
  repo="$TMP_ROOT/gating-root"
  broken="$TMP_ROOT/gating-broken-root"
  home="$TMP_ROOT/gating-home"
  mkdir -p "$home/state" "$home/config" "$broken/bin"
  install_pi_branch_extension_fixture "$repo"
  cp "$ROOT/bin/fm-lease.sh" "$ROOT/bin/fm-lease-lib.sh" "$ROOT/bin/fm-wake-lib.sh" "$broken/bin/"
  cat > "$broken/bin/fm-branch-prompt.sh" <<'SH'
#!/usr/bin/env bash
echo "synthetic generator failure" >&2
exit 1
SH
  chmod +x "$broken/bin/fm-branch-prompt.sh"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TEST_SKIP_BRANCH_GRANT=1 DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { dispatch, fire, settle, home }; })()`);
const { dispatch, fire, settle, home } = globalThis.__t;
import { existsSync, rmSync, writeFileSync } from "node:fs";

// No autonomy grant: session activation and wake routing both preserve the
// old path, with no branch-owned runtime state merely because Pi loaded it.
fire("session_start", {});
if (dispatch("signal: while unconfigured").accepted) throw new Error("unconfigured branch accepted a wake");
if (existsSync(`${home}/state/.pi-branch-extension-loaded`)) throw new Error("unconfigured branch activated runtime state");

// Empty, explicit off, and malformed values also fail closed.
writeFileSync(`${home}/config/pi-supervision-branch`, "\n");
if (dispatch("signal: while empty").accepted) throw new Error("empty grant accepted a wake");
writeFileSync(`${home}/config/pi-supervision-branch`, "off\n");
if (dispatch("signal: while disabled").accepted) throw new Error("disabled branch accepted a wake");
writeFileSync(`${home}/config/pi-supervision-branch`, "yes\n");
if (dispatch("signal: while malformed").accepted) throw new Error("malformed grant accepted a wake");

// An exact project opt-in grants the role, but away mode still owns supervision.
writeFileSync(`${home}/config/pi-supervision-branch`, `project=${home}/projects/approved\n`);
writeFileSync(`${home}/state/.afk`, "");
if (dispatch("signal: while afk").accepted) throw new Error("branch accepted a wake during away mode");

// Same build, gates cleared: only wakes wholly inside the granted project are
// accepted. A mixed-project drain stays on main rather than extending standing
// authority to the other project.
rmSync(`${home}/state/.afk`);
if (dispatch("heartbeat", []).accepted) {
  throw new Error("branch accepted an unscoped fleet-wide wake");
}
if (dispatch("signal: other project", [`${home}/projects/other`]).accepted) {
  throw new Error("branch accepted an out-of-scope project wake");
}
if (dispatch("signal: mixed projects", [`${home}/projects/approved`, `${home}/projects/other`]).accepted) {
  throw new Error("branch accepted a mixed-project wake");
}
if (!dispatch("signal: gates cleared").accepted) throw new Error("branch refused a wake with gates cleared");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "branch wake prompt");
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "config and afk gating must bind: $out"

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
  pass "branch gating (config, afk) binds and a broken branch falls back to main"
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
const offer = {
  message: "signal: after rebind",
  projects: [`${home}/projects/approved`],
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

test_branch_dispatch_two_stage_filter_and_prefix_contract
test_branch_cache_key_is_per_home_stable
test_branch_gating_config_afk_and_fallback
test_branch_mirror_filters_order_and_cursor
test_branch_session_persists_across_process_restarts
test_replacement_activation_cleans_leases_and_retries_failure
test_cold_start_activates_after_lock_acquisition
test_queued_actions_recheck_lock_ownership
test_stale_generation_boundaries_are_side_effect_free
test_secondary_session_stays_inert
test_rebind_remirrors_undelivered_dialog_from_durable_cursor
