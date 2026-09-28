#!/usr/bin/env bash
# Opt-in live guard for the Pi supervision-branch extension against the REAL
# installed @earendil-works/pi-coding-agent SDK (no stubs): the branch session
# is created through the real DefaultResourceLoader/SessionManager/
# createAgentSession surface, the custom bash and fm_branch_report tool
# definitions must be accepted by the real tool registry, the session file and
# pointer must persist on disk, and - because the isolated agent dir carries no
# credentials and no models - the branch's first prompt must reject its offer
# settlement so the watcher retains ownership and delivers the wake to main
# against the real SDK. It also resolves the supervision-branch model pin
# through the branch's REAL ModelRuntime, so a pin the vendor cannot resolve is
# proven to refuse the build rather than silently running the branch on main's
# model. A second branch probe intercepts the incident's post-construction 429
# in-process and proves that Pi's normally settled error turn returns ownership
# to the watcher. The model-precedence probe pins the vendor contract that the
# model pin rests on:
# an explicit model must beat the model a reopened session recorded, proven
# against a local, never-contacted fake provider. The effort-precedence probe
# does the same for the supervision-branch effort pin: Pi's own supported-level
# list is what the picker offers, Pi's own clamp is what lowers a level a model
# cannot run, and an explicit thinking level must beat the level a reopened
# session recorded. Finally, an isolated copy of the installed
# pi-openai-codex-compat package is driven through the branch dispatch boundary.
# The real Pi CLI uses intercepted SSE responses to prove lazy creation after
# legacy outcome reconciliation, startup before prompting, and persistence of
# the native remote-compaction checkpoint after the exact verified-pair check.
# A final real-SDK probe uses synthetic accepted Feishu records and the native
# encoder with Pi's actual custom-message queue to verify trusted captain
# mirroring before persistence, on idle/streaming paths and cold branch creation.
#
# No provider call leaves the machine. The first branch probe points
# PI_CODING_AGENT_DIR at an empty directory, so it reads no credentials and
# model resolution stays empty by construction. The 429 probe intercepts its
# only request before transport, and the precedence probes read only a local
# placeholder key for their never-contacted fake provider. The compatibility
# probe reads only a synthetic OAuth record from its isolated agent directory
# and intercepts every request in-process. Run after every Pi or compatibility
# package upgrade and before trusting refreshed per-harness evidence
# (docs/verification/runtime-backends.md).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_PI_BRANCH_LIVE_E2E npm jq node pi python3
export NODE_NO_WARNINGS=1

PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
  fail "Pi package absent: the live branch guard needs @earendil-works/pi-coding-agent installed (FM_PI_PACKAGE_DIR to override)"
fi
PI_VERSION=$(jq -r '.version' "$PI_PACKAGE_DIR/package.json" 2>/dev/null || printf 'unknown')

TMP_ROOT=$(fm_test_tmproot fm-pi-branch-live)
repo="$TMP_ROOT/repo"
home="$TMP_ROOT/home"
agentdir="$TMP_ROOT/agent-dir"
mkdir -p "$repo/.pi/extensions/lib" "$repo/node_modules/@earendil-works" \
  "$home/state" "$home/config" "$agentdir"
cp "$ROOT/.pi/extensions/fm-branch-supervision.ts" "$repo/.pi/extensions/fm-branch-supervision.ts"
cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
cp "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$repo/.pi/extensions/lib/fm-native-contract.ts"
cp "$ROOT/.pi/extensions/lib/fm-task-continuation.ts" "$repo/.pi/extensions/lib/fm-task-continuation.ts"
cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$repo/.pi/extensions/lib/fm-async-exec.ts"
cp "$ROOT/.pi/extensions/lib/fm-branch-model-picker.ts" "$repo/.pi/extensions/lib/fm-branch-model-picker.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
cp "$ROOT/.pi/extensions/lib/fm-feishu-native-channel.ts" "$repo/.pi/extensions/lib/fm-feishu-native-channel.ts"
mkdir -p "$repo/bin"
cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
cp "$ROOT/bin/fm-feishu-state.mjs" "$repo/bin/fm-feishu-state.mjs"
cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed generation=%s watcher=%s\n' "$2" "$4" >> "${FM_LIVE_WATCH_LOG:?}"
  exit 0
fi
printf 'arm pid=%s\n' "$$" >> "${FM_LIVE_WATCH_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=live-sdk-generation\n' "$$"
trap 'exit 0' TERM INT
while :; do
  if [ -e "$FM_LIVE_WATCH_TRIGGER" ]; then
    reason=$(cat "$FM_LIVE_WATCH_TRIGGER")
    rm -f "$FM_LIVE_WATCH_TRIGGER"
    printf '%s\n' "$reason"
    exit 0
  fi
  sleep 0.02
done
SH
chmod +x "$repo/bin/fm-operational-input.sh" "$repo/bin/fm-watch-arm.sh"
ln -s "$PI_PACKAGE_DIR" "$repo/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$repo/node_modules/@earendil-works/pi-tui"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-ai" "$repo/node_modules/@earendil-works/pi-ai"
ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$repo/node_modules/typebox"

# Stock macOS Bash 3.2 cannot reliably parse JavaScript template literals in a
# heredoc nested inside command substitution, so capture through a file.
BRANCH_PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" \
  WATCH_PLUGIN="$repo/.pi/extensions/fm-primary-pi-watch.ts" \
  FM_HOME="$home" FM_REAL_ROOT="$ROOT" FM_WATCH_ROOT="$repo" \
  FM_LIVE_WATCH_LOG="$TMP_ROOT/live-watch.log" FM_LIVE_WATCH_TRIGGER="$TMP_ROOT/live-watch.trigger" \
  PI_CODING_AGENT_DIR="$agentdir" PI_PACKAGE_DIR="$PI_PACKAGE_DIR" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const home = resolve(process.env.FM_HOME);
// Supervision is default-on: the live guard exercises the branch with no
// captain grant file present at all.
const approvedProject = `${home}/projects/live-probe`;
mkdirSync(approvedProject, { recursive: true });
writeFileSync(`${home}/state/live-probe.meta`, `project=${approvedProject}\nwindow=fm-live-probe\n`);
writeFileSync(`${home}/state/.wake-queue`, "1\t1\tsignal\tlive-probe.status\tsignal: live-sdk probe\n");
const busHandlers = new Map();
const offers = [];
const bus = {
  on(channel, handler) {
    busHandlers.set(channel, [...(busHandlers.get(channel) ?? []), handler]);
    return () => {};
  },
  emit(channel, data) {
    for (const handler of busHandlers.get(channel) ?? []) handler(data);
    if (channel === "fm-branch-supervision:dispatch") offers.push(data);
  },
};
const mainUserMessages = [];
const piHandlers = new Map();
let watcherTool = null;
let sessionCtx = {};
const pi = {
  events: bus,
  on(event, handler) {
    piHandlers.set(event, [...(piHandlers.get(event) ?? []), handler]);
  },
  registerTool(tool) {
    if (tool.name === "fm_watch_arm_pi") watcherTool = tool;
  },
  registerCommand() {},
  registerMessageRenderer() {},
  sendMessage() {},
  // Main is idle throughout this probe, so a send starts a run: Pi raises
  // before_agent_start with the exact text and then the user message_start.
  // A send while main streams raises neither at queue time; the sixth probe
  // below proves that against the real AgentSession.
  async sendUserMessage(content, options) {
    mainUserMessages.push({ content, options: options ?? {} });
    for (const handler of piHandlers.get("before_agent_start") ?? []) {
      await handler({ prompt: content }, sessionCtx);
    }
    for (const handler of piHandlers.get("message_start") ?? []) {
      await handler({ message: { role: "user", content: [{ type: "text", text: content }] } }, sessionCtx);
    }
  },
};
process.env.FM_ROOT_OVERRIDE = process.env.FM_REAL_ROOT;
const branchMod = await import(pathToFileURL(process.env.BRANCH_PLUGIN).href);
branchMod.default(pi);
process.env.FM_ROOT_OVERRIDE = process.env.FM_WATCH_ROOT;
const watchMod = await import(pathToFileURL(process.env.WATCH_PLUGIN).href);
watchMod.default(pi);
// The real model surface, built from the same empty agent dir: no
// credentials are read and no catalog is fetched, so every model lookup is
// genuinely empty by construction.
const { ModelRegistry, ModelRuntime } = await import(
  pathToFileURL(`${process.env.PI_PACKAGE_DIR}/dist/index.js`).href
);
const modelRegistry = new ModelRegistry(
  await ModelRuntime.create({
    authPath: `${process.env.PI_CODING_AGENT_DIR}/auth.json`,
    modelsPath: `${process.env.PI_CODING_AGENT_DIR}/models.json`,
  }),
);
if (typeof modelRegistry.getAvailable !== "function" || typeof modelRegistry.hasConfiguredAuth !== "function") {
  throw new Error("the real ModelRegistry no longer exposes the model surface the supervision picker reads");
}
sessionCtx = {
  sessionManager: { getSessionFile: () => `${home}/main.jsonl`, getEntries: () => [] },
  modelRegistry,
};
const waitFor = async (predicate, label) => {
  for (let i = 0; i < 600; i += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`timeout waiting for ${label}`);
};
const armCount = () => existsSync(process.env.FM_LIVE_WATCH_LOG)
  ? readFileSync(process.env.FM_LIVE_WATCH_LOG, "utf8").split(/\n/).filter((line) => line.startsWith("arm ")).length
  : 0;
for (const handler of piHandlers.get("session_start") ?? []) {
  await handler({ type: "session_start", reason: "startup" }, sessionCtx);
}
if (existsSync(`${home}/state/.pi-branch-extension-loaded`)) {
  throw new Error("branch activated before the primary session acquired its lock");
}
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
if (!watcherTool) throw new Error("watcher tool was not registered");
const armed = await watcherTool.execute("live-sdk-arm", {}, undefined, undefined, {});
if (!armed.details?.ok) throw new Error(`watcher did not arm: ${JSON.stringify(armed.details)}`);
await waitFor(() => armCount() === 1, "initial watcher arm");
writeFileSync(process.env.FM_LIVE_WATCH_TRIGGER, "signal: live-sdk probe\n");
await waitFor(() => mainUserMessages.length === 1, "watcher-owned main delivery");
if (offers.length !== 1 || !offers[0].accepted) {
  throw new Error(`branch did not accept the watcher offer against the real SDK: ${JSON.stringify(offers)}`);
}
const offerFailure = await offers[0].settlement.then(() => null, (error) => error);
if (!(offerFailure instanceof Error)) {
  throw new Error("an unpromptable branch did not reject its offer settlement to the watcher");
}
// With an empty agent dir there is no model, so the branch's first prompt
// must fail fast. The rejected settlement proves ownership returned to the
// watcher, and this consumed main delivery proves the watcher kept the wake.
const fallback = mainUserMessages[0].content;
if (!fallback.includes("FIRSTMATE WATCHER WAKE: signal: live-sdk probe")) {
  throw new Error(`watcher-owned fallback lost the wake reason: ${fallback}`);
}
if (!existsSync(`${home}/state/.branch-session`)) {
  throw new Error("real SessionManager did not persist the branch session pointer");
}
// The real SessionManager writes the session file lazily (on its first
// persisted entry), so assert the pointer's placement rather than the file:
// the recorded path must live under this home branch-session store.
const pointer = readFileSync(`${home}/state/.branch-session`, "utf8").trim();
if (!pointer.startsWith(`${home}/state/branch-session/`) || !pointer.endsWith(".jsonl")) {
  throw new Error(`recorded branch session pointer is misplaced: ${pointer}`);
}
if (!existsSync(`${home}/state/branch-session`)) {
  throw new Error("branch session store directory was not created");
}

// A model pin the branch's REAL runtime cannot resolve must refuse the build
// and reject the offer back to watcher-owned main delivery rather than
// silently running the branch on whatever model main would have used.
writeFileSync(`${home}/config/supervision-branch-model`, "openai/no-such-live-model\n");
for (const handler of piHandlers.get("session_shutdown") ?? []) {
  await handler({ type: "session_shutdown", reason: "new" }, sessionCtx);
}
for (const handler of piHandlers.get("session_start") ?? []) {
  await handler({ type: "session_start", reason: "new" }, sessionCtx);
}
await waitFor(() => armCount() >= 3, "replacement watcher arm");
writeFileSync(`${home}/state/.wake-queue`, "1\t2\tsignal\tlive-probe.status\tsignal: live pin probe\n");
writeFileSync(process.env.FM_LIVE_WATCH_TRIGGER, "signal: live pin probe\n");
await waitFor(() => mainUserMessages.length === 2, "pinned watcher-owned main delivery");
if (offers.length !== 2 || !offers[1].accepted) {
  throw new Error(`branch did not accept the pinned watcher offer: ${JSON.stringify(offers)}`);
}
const pinFailure = await offers[1].settlement.then(() => null, (error) => error);
if (!(pinFailure instanceof Error) ||
    !pinFailure.message.includes("openai/no-such-live-model") ||
    !pinFailure.message.includes("supervision model pin")) {
  throw new Error(`the rejected real-SDK settlement did not name the unusable pin: ${String(pinFailure)}`);
}
const pinFallback = mainUserMessages[1].content;
if (!pinFallback.includes("FIRSTMATE WATCHER WAKE: signal: live pin probe")) {
  throw new Error(`pinned watcher-owned fallback lost the wake reason: ${pinFallback}`);
}
const confirmations = readFileSync(process.env.FM_LIVE_WATCH_LOG, "utf8")
  .split(/\n/)
  .filter((line) => line.startsWith("confirmed "));
if (confirmations.length !== 2) {
  throw new Error(`watcher did not confirm both successor deliveries: ${confirmations.join(" | ")}`);
}
console.log("LIVE_OK");
process.exit(0);
EOF
status=$?
out=$(cat "$TMP_ROOT/node-output")
if [ "$status" -ne 0 ] || [ "$out" != "LIVE_OK" ]; then
  fail "real-SDK Pi branch guard failed against pi-coding-agent $PI_VERSION: $out"
fi
pass "real Pi SDK $PI_VERSION accepts the branch session construction and preserves an unpromptable wake"

# Real-SDK Mode 2 guard: a constructed AgentSession receives the c1 429 shape
# from Pi's real OpenAI-compatible adapter. Fetch is intercepted in-process,
# so no provider request leaves the machine, but Pi still persists the error
# assistant message and resolves session.prompt() through its production loop.
errorhome="$TMP_ROOT/error-home"
erroragentdir="$TMP_ROOT/error-agent-dir"
mkdir -p "$errorhome/state" "$errorhome/config" "$erroragentdir"
cat > "$erroragentdir/models.json" <<'JSON'
{
  "providers": {
    "fm-live-error": {
      "baseUrl": "https://fm-provider-error.invalid/v1",
      "api": "openai-completions",
      "apiKey": "fm-live-placeholder",
      "models": [
        { "id": "fm-live-error-model", "name": "fm live error", "contextWindow": 8192, "maxTokens": 512 }
      ]
    }
  }
}
JSON
BRANCH_PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" \
  WATCH_PLUGIN="$repo/.pi/extensions/fm-primary-pi-watch.ts" \
  FM_HOME="$errorhome" FM_REAL_ROOT="$ROOT" FM_WATCH_ROOT="$repo" \
  FM_LIVE_WATCH_LOG="$TMP_ROOT/error-watch.log" FM_LIVE_WATCH_TRIGGER="$TMP_ROOT/error-watch.trigger" \
  PI_CODING_AGENT_DIR="$erroragentdir" PI_PACKAGE_DIR="$PI_PACKAGE_DIR" \
  node --input-type=module > "$TMP_ROOT/error-output" 2>&1 <<'EOF'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const home = resolve(process.env.FM_HOME);
const approvedProject = `${home}/projects/live-error-probe`;
mkdirSync(approvedProject, { recursive: true });
writeFileSync(`${home}/state/live-error-probe.meta`, `project=${approvedProject}\nwindow=fm-live-error-probe\n`);
writeFileSync(`${home}/state/.wake-queue`, "1\t1\tsignal\tlive-error-probe.status\tsignal: c1 429 probe\n");
let providerRequests = 0;
globalThis.fetch = async (input) => {
  const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
  if (!url.startsWith("https://fm-provider-error.invalid/")) {
    throw new Error(`unexpected network request in provider-free guard: ${url}`);
  }
  providerRequests += 1;
  return new Response(
    JSON.stringify({ error: { message: "Monthly usage limit reached", type: "insufficient_quota" } }),
    { status: 429, headers: { "content-type": "application/json" } },
  );
};

const busHandlers = new Map();
const offers = [];
const bus = {
  on(channel, handler) {
    busHandlers.set(channel, [...(busHandlers.get(channel) ?? []), handler]);
    return () => {};
  },
  emit(channel, data) {
    for (const handler of busHandlers.get(channel) ?? []) handler(data);
    if (channel === "fm-branch-supervision:dispatch") offers.push(data);
  },
};
const piHandlers = new Map();
const mainUserMessages = [];
let watcherTool = null;
let sessionCtx = {};
const pi = {
  events: bus,
  on(event, handler) {
    piHandlers.set(event, [...(piHandlers.get(event) ?? []), handler]);
  },
  registerTool(tool) {
    if (tool.name === "fm_watch_arm_pi") watcherTool = tool;
  },
  registerCommand() {},
  registerMessageRenderer() {},
  sendMessage() {},
  // Idle main, as in the first probe: a send starts a run and Pi raises
  // before_agent_start, then the user message_start.
  async sendUserMessage(content, options) {
    mainUserMessages.push({ content, options: options ?? {} });
    for (const handler of piHandlers.get("before_agent_start") ?? []) {
      await handler({ prompt: content }, sessionCtx);
    }
    for (const handler of piHandlers.get("message_start") ?? []) {
      await handler({ message: { role: "user", content: [{ type: "text", text: content }] } }, sessionCtx);
    }
  },
  getThinkingLevel() {
    return "off";
  },
};
process.env.FM_ROOT_OVERRIDE = process.env.FM_REAL_ROOT;
const branchMod = await import(pathToFileURL(process.env.BRANCH_PLUGIN).href);
branchMod.default(pi);
process.env.FM_ROOT_OVERRIDE = process.env.FM_WATCH_ROOT;
const watchMod = await import(pathToFileURL(process.env.WATCH_PLUGIN).href);
watchMod.default(pi);
sessionCtx = {
  model: { provider: "fm-live-error", id: "fm-live-error-model" },
  sessionManager: { getSessionFile: () => `${home}/main.jsonl`, getEntries: () => [] },
};
const waitFor = async (predicate, label) => {
  for (let i = 0; i < 600; i += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`timeout waiting for ${label}`);
};
for (const handler of piHandlers.get("session_start") ?? []) {
  await handler({ type: "session_start", reason: "startup" }, sessionCtx);
}
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
if (!watcherTool) throw new Error("watcher tool was not registered for the provider-error probe");
const armed = await watcherTool.execute("provider-error-arm", {}, undefined, undefined, {});
if (!armed.details?.ok) throw new Error(`provider-error watcher did not arm: ${JSON.stringify(armed.details)}`);
await waitFor(() => existsSync(process.env.FM_LIVE_WATCH_LOG), "provider-error watcher arm");
writeFileSync(process.env.FM_LIVE_WATCH_TRIGGER, "signal: c1 429 probe\n");
await waitFor(() => mainUserMessages.length === 1, "provider-error watcher-owned main delivery");
if (offers.length !== 1 || !offers[0].accepted) {
  throw new Error(`real-SDK provider-error watcher offer was not accepted: ${JSON.stringify(offers)}`);
}
const offerFailure = await offers[0].settlement.then(() => null, (error) => error);
if (!(offerFailure instanceof Error) ||
    !offerFailure.message.includes("provider failed after construction") ||
    !offerFailure.message.includes("Monthly usage limit reached")) {
  throw new Error(`real-SDK provider-error settlement lost the normally settled 429 turn: ${String(offerFailure)}`);
}
const fallback = mainUserMessages[0].content;
if (!fallback.includes("FIRSTMATE WATCHER WAKE: signal: c1 429 probe")) {
  throw new Error(`real-SDK watcher-owned fallback lost the 429 wake: ${fallback}`);
}
if (mainUserMessages[0].options.deliverAs !== "followUp") {
  throw new Error("real-SDK provider-error watcher delivery was not a follow-up");
}
if (providerRequests !== 1) throw new Error(`non-retryable 429 made ${providerRequests} provider attempts instead of one`);
if (existsSync(`${home}/state/.branch-eligible-rows`)) {
  throw new Error("real-SDK provider-error fallback left the claimed row grant active");
}
if (existsSync(`${home}/state/branch-outcomes.jsonl`)) {
  throw new Error("real-SDK provider error fabricated a durable branch outcome");
}
const queue = readFileSync(`${home}/state/.wake-queue`, "utf8");
if (!queue.includes("\tsignal\tlive-error-probe.status\t")) {
  throw new Error(`real-SDK provider-error fallback lost the durable wake row: ${queue}`);
}
const pointer = readFileSync(`${home}/state/.branch-session`, "utf8").trim();
const { SessionManager } = await import(pathToFileURL(`${process.env.PI_PACKAGE_DIR}/dist/index.js`).href);
const persistedContext = SessionManager.open(pointer, `${home}/state/branch-session`).buildSessionContext();
const persistedError = persistedContext.messages
  .filter((message) => message.role === "assistant")
  .at(-1);
if (persistedError?.stopReason !== "error" || !persistedError.errorMessage?.includes("Monthly usage limit reached")) {
  throw new Error(`real SessionManager did not restore the settled provider error: ${JSON.stringify(persistedError)}`);
}
const confirmations = readFileSync(process.env.FM_LIVE_WATCH_LOG, "utf8")
  .split(/\n/)
  .filter((line) => line.startsWith("confirmed "));
if (confirmations.length !== 1) {
  throw new Error(`provider-error watcher did not confirm its successor delivery: ${confirmations.join(" | ")}`);
}
console.log("ERROR_FALLBACK_OK");
process.exit(0);
EOF
status=$?
out=$(cat "$TMP_ROOT/error-output")
if [ "$status" -ne 0 ] || [ "$out" != "ERROR_FALLBACK_OK" ]; then
  fail "real-SDK Pi settled-provider-error guard failed against pi-coding-agent $PI_VERSION: $out"
fi
pass "real Pi SDK $PI_VERSION rejects a post-construction 429 to watcher-owned main delivery without losing its durable row"

# Third probe: the vendor contract the supervision-branch model pin rests on.
# An explicit model must beat the model a reopened session recorded, or a pin
# would silently stop applying the first time the branch reopens. Proven with
# a local, never-contacted fake provider with a placeholder key, so no request
# leaves the machine and no user credential is read.
modeldir="$TMP_ROOT/model-agent-dir"
mkdir -p "$modeldir" "$TMP_ROOT/model-sessions"
cat > "$modeldir/models.json" <<'JSON'
{
  "providers": {
    "fm-live-fake": {
      "baseUrl": "http://127.0.0.1:9/v1",
      "api": "openai-completions",
      "apiKey": "fm-live-placeholder",
      "models": [
        { "id": "fm-live-a", "name": "fm live a", "contextWindow": 8192, "maxTokens": 512 },
        { "id": "fm-live-b", "name": "fm live b", "contextWindow": 8192, "maxTokens": 512 }
      ]
    }
  }
}
JSON
PI_PACKAGE_DIR="$PI_PACKAGE_DIR" PI_CODING_AGENT_DIR="$modeldir" FM_LIVE_SESSIONS="$TMP_ROOT/model-sessions" \
  node --input-type=module > "$TMP_ROOT/model-output" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const pkg = pathToFileURL(`${process.env.PI_PACKAGE_DIR}/dist/index.js`).href;
const { ModelRegistry, ModelRuntime, SessionManager, createAgentSession } = await import(pkg);
const runtime = await ModelRuntime.create({
  authPath: `${process.env.PI_CODING_AGENT_DIR}/auth.json`,
  modelsPath: `${process.env.PI_CODING_AGENT_DIR}/models.json`,
});
const registry = new ModelRegistry(runtime);
await registry.refresh();

// The candidates resolve through the same registry calls the picker makes.
const first = registry.find("fm-live-fake", "fm-live-a");
const second = registry.find("fm-live-fake", "fm-live-b");
if (!first || !second) throw new Error("the real registry did not resolve the locally declared models");
if (!registry.hasConfiguredAuth(first)) throw new Error("hasConfiguredAuth rejected a locally declared model with a key");
if (!registry.getAvailable().some((model) => model.id === "fm-live-a")) {
  throw new Error("getAvailable no longer lists a model with configured credentials, so the picker would be empty");
}

const cwd = process.cwd();
const sessions = process.env.FM_LIVE_SESSIONS;
const creating = SessionManager.create(cwd, sessions);
const created = await createAgentSession({ cwd, sessionManager: creating, modelRuntime: runtime, model: first, tools: [] });
if (created.session.model?.id !== "fm-live-a") {
  throw new Error(`a pinned model was not applied on create: ${created.session.model?.id}`);
}
const sessionFile = creating.getSessionFile();

// Reopen the SAME session with a different pin: the explicit model must win
// over the one the session recorded.
const repinned = await createAgentSession({
  cwd,
  sessionManager: SessionManager.open(sessionFile, sessions),
  modelRuntime: runtime,
  model: second,
  tools: [],
});
if (repinned.session.model?.id !== "fm-live-b") {
  throw new Error(`a reopened session ignored the pin and kept its recorded model: ${repinned.session.model?.id}`);
}

// With no pin the reopened session restores its own recorded model, which is
// the untouched behavior an absent pin must keep.
const unpinned = await createAgentSession({
  cwd,
  sessionManager: SessionManager.open(sessionFile, sessions),
  modelRuntime: runtime,
  tools: [],
});
if (unpinned.session.model?.id !== "fm-live-a") {
  throw new Error(`an unpinned reopen did not restore the session's own model: ${unpinned.session.model?.id}`);
}
console.log("MODEL_OK");
process.exit(0);
EOF
status=$?
out=$(cat "$TMP_ROOT/model-output")
if [ "$status" -ne 0 ] || [ "$out" != "MODEL_OK" ]; then
  fail "real-SDK model-pin precedence guard failed against pi-coding-agent $PI_VERSION: $out"
fi
pass "real Pi SDK $PI_VERSION applies an explicit branch model on create and over a reopened session's recorded model"

# Fourth probe: the vendor contract the supervision-branch EFFORT pin rests on.
# Same never-contacted local provider, now declaring models with different
# reasoning ceilings so Pi's own supported-level list and clamp are exercised
# for real. The recorded-level case needs a session file on disk, and Pi
# flushes one only once an assistant message exists, so the probe appends both
# entries through the real SessionManager rather than hand-writing the format.
effortdir="$TMP_ROOT/effort-agent-dir"
mkdir -p "$effortdir" "$TMP_ROOT/effort-sessions"
cat > "$effortdir/models.json" <<'JSON'
{
  "providers": {
    "fm-live-fake": {
      "baseUrl": "http://127.0.0.1:9/v1",
      "api": "openai-completions",
      "apiKey": "fm-live-placeholder",
      "models": [
        {
          "id": "fm-live-deep",
          "name": "fm live deep",
          "contextWindow": 8192,
          "maxTokens": 512,
          "reasoning": true,
          "thinkingLevelMap": {
            "minimal": "minimal",
            "low": "low",
            "medium": "medium",
            "high": "high",
            "xhigh": "xhigh",
            "max": "max"
          }
        },
        { "id": "fm-live-shallow", "name": "fm live shallow", "contextWindow": 8192, "maxTokens": 512, "reasoning": true },
        { "id": "fm-live-plain", "name": "fm live plain", "contextWindow": 8192, "maxTokens": 512 }
      ]
    }
  }
}
JSON
PI_PACKAGE_DIR="$PI_PACKAGE_DIR" PI_CODING_AGENT_DIR="$effortdir" FM_LIVE_SESSIONS="$TMP_ROOT/effort-sessions" \
  node --input-type=module > "$TMP_ROOT/effort-output" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const packageRoot = process.env.PI_PACKAGE_DIR;
const pkg = pathToFileURL(`${packageRoot}/dist/index.js`).href;
const { ModelRegistry, ModelRuntime, SessionManager, createAgentSession } = await import(pkg);
// The same specifier the extension imports; Pi's extension loader aliases it
// to this package's own bundled copy.
const { clampThinkingLevel, getSupportedThinkingLevels } = await import(
  pathToFileURL(`${packageRoot}/node_modules/@earendil-works/pi-ai/dist/compat.js`).href
);
const runtime = await ModelRuntime.create({
  authPath: `${process.env.PI_CODING_AGENT_DIR}/auth.json`,
  modelsPath: `${process.env.PI_CODING_AGENT_DIR}/models.json`,
});
const registry = new ModelRegistry(runtime);
await registry.refresh();

const deep = registry.find("fm-live-fake", "fm-live-deep");
const shallow = registry.find("fm-live-fake", "fm-live-shallow");
const plain = registry.find("fm-live-fake", "fm-live-plain");
if (!deep || !shallow || !plain) throw new Error("the real registry did not resolve the locally declared effort models");

// Pi's own vocabulary, and the same list the extension declares for rejecting
// an unrecognized hand-edited pin. The tracked strict typecheck enforces this
// from the type side; this is the runtime half, checked after a Pi upgrade.
const vocabulary = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];
const deepLevels = getSupportedThinkingLevels(deep);
if (JSON.stringify(deepLevels) !== JSON.stringify(vocabulary)) {
  throw new Error(`Pi's own effort vocabulary changed: ${JSON.stringify(deepLevels)}`);
}
// A reasoning model that maps no extended levels stops below them, and a
// non-reasoning model offers only "off" - so the picker's menu really does
// narrow with the model the captain just chose.
const shallowLevels = getSupportedThinkingLevels(shallow);
if (shallowLevels.includes("xhigh") || shallowLevels.includes("max") || !shallowLevels.includes("high")) {
  throw new Error(`Pi no longer narrows the level list for an unmapped model: ${JSON.stringify(shallowLevels)}`);
}
if (JSON.stringify(getSupportedThinkingLevels(plain)) !== JSON.stringify(["off"])) {
  throw new Error("Pi no longer reports a non-reasoning model as effort-off only");
}
if (clampThinkingLevel(shallow, "max") !== "high") {
  throw new Error(`Pi's own clamp no longer lowers an unsupported level: ${clampThinkingLevel(shallow, "max")}`);
}
// An unrecognized token collapses to the model's lowest level, which is why
// the extension rejects one as "no pin" before it can reach this clamp.
if (clampThinkingLevel(shallow, "fm-not-a-level") !== "off") {
  throw new Error("Pi's clamp no longer collapses an unrecognized token, so the extension's guard needs review");
}

const cwd = process.cwd();
const sessions = process.env.FM_LIVE_SESSIONS;
const creating = SessionManager.create(cwd, sessions);
const created = await createAgentSession({
  cwd,
  sessionManager: creating,
  modelRuntime: runtime,
  model: deep,
  thinkingLevel: "xhigh",
  tools: [],
});
if (created.session.thinkingLevel !== "xhigh") {
  throw new Error(`a pinned effort was not applied on create: ${created.session.thinkingLevel}`);
}

// Record a level in a session file Pi will actually restore from.
const recording = SessionManager.create(cwd, sessions);
recording.appendThinkingLevelChange("xhigh");
recording.appendMessage({
  role: "assistant",
  content: [{ type: "text", text: "recorded" }],
  api: "openai-completions",
  provider: "fm-live-fake",
  model: "fm-live-deep",
  usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
  stopReason: "stop",
});
const recorded = recording.getSessionFile();

// With no override the reopened session restores its own recorded level -
// which is exactly why an unpinned branch must apply main's effort
// explicitly instead of merely omitting it.
const restored = await createAgentSession({
  cwd,
  sessionManager: SessionManager.open(recorded, sessions),
  modelRuntime: runtime,
  model: deep,
  tools: [],
});
if (restored.session.thinkingLevel !== "xhigh") {
  throw new Error(`a reopened session no longer restores its recorded effort: ${restored.session.thinkingLevel}`);
}
// An explicit level must beat that recorded one, or the pin would silently
// stop applying the first time the branch reopens.
const overridden = await createAgentSession({
  cwd,
  sessionManager: SessionManager.open(recorded, sessions),
  modelRuntime: runtime,
  model: deep,
  thinkingLevel: "low",
  tools: [],
});
if (overridden.session.thinkingLevel !== "low") {
  throw new Error(`a reopened session ignored the effort override and kept its recorded level: ${overridden.session.thinkingLevel}`);
}
// Pi clamps at build time, so a pin above the branch model's ceiling lowers
// the branch rather than refusing it.
const clamped = await createAgentSession({
  cwd,
  sessionManager: SessionManager.open(recorded, sessions),
  modelRuntime: runtime,
  model: shallow,
  thinkingLevel: "max",
  tools: [],
});
if (clamped.session.thinkingLevel !== "high") {
  throw new Error(`an over-ceiling effort override was not clamped on build: ${clamped.session.thinkingLevel}`);
}
console.log("EFFORT_OK");
process.exit(0);
EOF
status=$?
out=$(cat "$TMP_ROOT/effort-output")
if [ "$status" -ne 0 ] || [ "$out" != "EFFORT_OK" ]; then
  fail "real-SDK effort-pin guard failed against pi-coding-agent $PI_VERSION: $out"
fi
pass "real Pi SDK $PI_VERSION reports its own supported effort levels and applies an explicit branch effort over a reopened session's recorded level"

# Fifth probe: the real SDK contract deterministic captain delivery rests on.
# ExtensionAPI.appendEntry must synchronously insert the registered custom entry
# into an active InteractiveMode transcript, persist it across SessionManager
# reopen, and keep it out of model context. No model is selected or prompted.
PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" DELIVERY_DIR="$TMP_ROOT/delivery-sessions" \
  DELIVERY_AGENT_DIR="$TMP_ROOT/delivery-agent-dir" PI_PACKAGE_DIR="$PI_PACKAGE_DIR" \
  node --input-type=module > "$TMP_ROOT/delivery-output" 2>&1 <<'EOF'
import { mkdirSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const pkg = resolve(process.env.PI_PACKAGE_DIR);
const {
  DefaultResourceLoader,
  InteractiveMode,
  SessionManager,
  SettingsManager,
  createAgentSession,
  initTheme,
} = await import(
  pathToFileURL(`${pkg}/dist/index.js`).href
);
initTheme("dark");
const sessions = resolve(process.env.DELIVERY_DIR);
const agentDir = resolve(process.env.DELIVERY_AGENT_DIR);
mkdirSync(sessions, { recursive: true });
mkdirSync(agentDir, { recursive: true });
const manager = SessionManager.create(process.cwd(), sessions);
manager.appendMessage({
  role: "assistant",
  content: [{ type: "text", text: "The retry safe-stopped; diagnosis is underway." }],
  api: "openai-completions",
  provider: "local-none",
  model: "no-provider-call",
  usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
  stopReason: "stop",
});
const settings = SettingsManager.create(process.cwd(), agentDir);
let capturedApi;
const loader = new DefaultResourceLoader({
  cwd: process.cwd(),
  agentDir,
  settingsManager: settings,
  additionalExtensionPaths: [process.env.PLUGIN],
  extensionFactories: [{ name: "append-entry-probe", factory: (pi) => { capturedApi = pi; } }],
  noSkills: true,
  noPromptTemplates: true,
  noThemes: true,
  noContextFiles: true,
});
await loader.reload();
const created = await createAgentSession({
  cwd: process.cwd(),
  sessionManager: manager,
  settingsManager: settings,
  resourceLoader: loader,
  tools: [],
});
const runtimeHost = {
  session: created.session,
  setBeforeSessionInvalidate() {},
  setRebindSession() {},
};
const interactive = new InteractiveMode(runtimeHost, { tuiMode: "alt-screen" });
interactive.isInitialized = true;
interactive.subscribeToAgent();
const record = {
  version: 1,
  seq: 234,
  task: "email-intake-canary-next-page-diagnosis-v1",
  verdict: "captain",
  summary: "Completed diagnosis proves the prior assistant response was unrelated.",
  silent: false,
};
capturedApi.appendEntry("fm-branch-visible-outcome", record);

const rendered = interactive.chatContainer.render(240).join("\n");
if (!rendered.includes("⚓") || !rendered.includes(`[seq ${record.seq}]`) || !rendered.includes(record.task) || !rendered.includes(record.summary)) {
  throw new Error(`active Pi transcript did not immediately render the exact outcome: ${rendered}`);
}
if (rendered.split(record.summary).length !== 2) {
  throw new Error(`active Pi transcript rendered the outcome more than once: ${rendered}`);
}

const reopened = SessionManager.open(manager.getSessionFile(), sessions);
const entries = reopened.getEntries();
const entry = entries.find((candidate) => candidate.type === "custom" && candidate.customType === "fm-branch-visible-outcome");
if (!entry || JSON.stringify(entry.data) !== JSON.stringify(record)) {
  throw new Error(`appendEntry did not persist the exact record across reopen: ${JSON.stringify(entry)}`);
}
if (reopened.buildSessionContext().messages.some((message) => JSON.stringify(message).includes(record.summary))) {
  throw new Error("a custom session entry entered model context");
}
interactive.unsubscribe();
await created.session.dispose();
console.log("DELIVERY_OK");
process.exit(0);
EOF
status=$?
out=$(cat "$TMP_ROOT/delivery-output")
if [ "$status" -ne 0 ] || [ "$out" != "DELIVERY_OK" ]; then
  fail "real-SDK visible outcome delivery guard failed against pi-coding-agent $PI_VERSION: $out"
fi
pass "real Pi SDK $PI_VERSION immediately renders appendEntry in the active transcript, persists it across reopen, and excludes it from model context"

# Sixth probe: the vendor event contract watcher continuity rests on, against
# the real AgentSession and ExtensionRunner with the tracked watcher extension
# loaded through Pi's own resource loader. A wake the extension delivers while
# main is streaming must join the running run without ever raising
# before_agent_start, the extension must still start the successor and deliver
# the next close, and Pi must surface consumption of both the streaming-time
# and the idle follow-up through the events the extension reads (the user
# message_start, and before_agent_start for the idle one). The provider is a
# local fake whose only fetch is intercepted in-process and held open until
# the follow-up is queued, so no request leaves the machine and no credential
# is read.
streamdir="$TMP_ROOT/stream-agent-dir"
streamhome="$TMP_ROOT/stream-home"
mkdir -p "$streamdir" "$streamhome/state" "$streamhome/config" "$TMP_ROOT/stream-sessions"
cat > "$streamdir/models.json" <<'JSON'
{
  "providers": {
    "fm-live-stream": {
      "baseUrl": "https://fm-live-stream.invalid/v1",
      "api": "openai-completions",
      "apiKey": "fm-live-placeholder",
      "models": [
        { "id": "fm-live-stream-model", "name": "fm live stream", "contextWindow": 8192, "maxTokens": 512 }
      ]
    }
  }
}
JSON
WATCH_PLUGIN="$repo/.pi/extensions/fm-primary-pi-watch.ts" \
  FM_HOME="$streamhome" FM_ROOT_OVERRIDE="$repo" \
  FM_LIVE_WATCH_LOG="$TMP_ROOT/stream-watch.log" FM_LIVE_WATCH_TRIGGER="$TMP_ROOT/stream-watch.trigger" \
  FM_LIVE_SESSIONS="$TMP_ROOT/stream-sessions" \
  PI_CODING_AGENT_DIR="$streamdir" PI_PACKAGE_DIR="$PI_PACKAGE_DIR" \
  node --input-type=module > "$TMP_ROOT/stream-output" 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const home = resolve(process.env.FM_HOME);
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const pkg = resolve(process.env.PI_PACKAGE_DIR);
const { DefaultResourceLoader, ModelRegistry, ModelRuntime, SessionManager, SettingsManager, createAgentSession } =
  await import(pathToFileURL(`${pkg}/dist/index.js`).href);

// The local fake provider: the first completion streams one token and then
// holds its stream open until the probe releases it; later ones finish at once.
let completions = 0;
let releaseStream = () => {};
const streamHeld = new Promise((release) => {
  releaseStream = release;
});
const chunk = (delta, finish) => `data: ${JSON.stringify({
  id: "fm-live-stream",
  object: "chat.completion.chunk",
  created: 1,
  model: "fm-live-stream-model",
  choices: [{ index: 0, delta, finish_reason: finish }],
  ...(finish ? { usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } } : {}),
})}\n\n`;
globalThis.fetch = async (input) => {
  const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
  if (!url.startsWith("https://fm-live-stream.invalid/")) {
    throw new Error(`unexpected network request in provider-free guard: ${url}`);
  }
  completions += 1;
  const hold = completions === 1 ? streamHeld : Promise.resolve();
  const encoder = new TextEncoder();
  const body = new ReadableStream({
    async start(controller) {
      controller.enqueue(encoder.encode(chunk({ role: "assistant", content: "OK" }, null)));
      await hold;
      controller.enqueue(encoder.encode(chunk({}, "stop")));
      controller.enqueue(encoder.encode("data: [DONE]\n\n"));
      controller.close();
    },
  });
  return new Response(body, { status: 200, headers: { "content-type": "text/event-stream" } });
};

const events = [];
const userText = (content) => typeof content === "string"
  ? content
  : content.filter((part) => part.type === "text").map((part) => part.text).join("\n");
const agentDir = resolve(process.env.PI_CODING_AGENT_DIR);
const settings = SettingsManager.create(process.cwd(), agentDir);
const loader = new DefaultResourceLoader({
  cwd: process.cwd(),
  agentDir,
  settingsManager: settings,
  additionalExtensionPaths: [process.env.WATCH_PLUGIN],
  extensionFactories: [{
    name: "fm-event-contract-probe",
    factory: (pi) => {
      pi.on("before_agent_start", (event) => {
        events.push({ type: "before_agent_start", text: event.prompt });
      });
      pi.on("message_start", (event) => {
        if (event.message.role !== "user") return;
        events.push({ type: "user_message_start", text: userText(event.message.content) });
      });
      pi.on("input", (event) => {
        events.push({ type: "input", text: event.text, source: event.source, streamingBehavior: event.streamingBehavior });
      });
      pi.on("agent_settled", () => {
        events.push({ type: "agent_settled" });
      });
    },
  }],
  noSkills: true,
  noPromptTemplates: true,
  noThemes: true,
  noContextFiles: true,
});
await loader.reload();
const runtime = await ModelRuntime.create({
  authPath: `${agentDir}/auth.json`,
  modelsPath: `${agentDir}/models.json`,
});
const registry = new ModelRegistry(runtime);
await registry.refresh();
const model = registry.find("fm-live-stream", "fm-live-stream-model");
if (!model) throw new Error("the real registry did not resolve the local streaming model");
const { session } = await createAgentSession({
  cwd: process.cwd(),
  sessionManager: SessionManager.create(process.cwd(), resolve(process.env.FM_LIVE_SESSIONS)),
  settingsManager: settings,
  resourceLoader: loader,
  modelRuntime: runtime,
  model,
  noTools: "builtin",
});

const armLog = process.env.FM_LIVE_WATCH_LOG;
const armRows = (prefix) => existsSync(armLog)
  ? readFileSync(armLog, "utf8").split(/\n/).filter((line) => line.startsWith(prefix)).length
  : 0;
const has = (type, text) => events.some((event) => event.type === type && (text === undefined || event.text.includes(text)));
const settledRuns = () => events.filter((event) => event.type === "agent_settled").length;
const waitFor = async (predicate, label) => {
  for (let i = 0; i < 600; i += 1) {
    const failure = events.find((event) => event.type === "prompt_error");
    if (failure) throw new Error(`the real session rejected its prompt: ${failure.text}`);
    if (predicate()) return;
    await new Promise((tick) => setTimeout(tick, 50));
  }
  throw new Error(`timeout waiting for ${label}; events=${JSON.stringify(events)}`);
};

const armTool = session.getToolDefinition("fm_watch_arm_pi");
if (!armTool) throw new Error("the real tool registry did not expose fm_watch_arm_pi");
const armed = await armTool.execute("live-stream-arm", {}, undefined, undefined, {});
if (!armed.details?.ok) throw new Error(`watcher did not arm: ${JSON.stringify(armed.details)}`);
await waitFor(() => armRows("arm ") === 1, "initial watcher arm");

// Turn 1: main streams against the held provider stream; the watcher closes
// mid-turn and the extension delivers its wake while main is busy.
session.prompt("Reply with exactly the word OK.").catch((error) => {
  events.push({ type: "prompt_error", text: error instanceof Error ? error.message : String(error) });
});
await waitFor(() => completions === 1 && session.isStreaming, "main streaming on the held completion");
writeFileSync(process.env.FM_LIVE_WATCH_TRIGGER, "signal: live streaming probe\n");
await waitFor(
  () => events.some((event) => event.type === "input" && event.source === "extension" && event.streamingBehavior === "followUp" && event.text.includes("signal: live streaming probe")),
  "the watcher follow-up queued while main streams",
);
await waitFor(() => armRows("arm ") === 2, "successor started while main streams");
if (has("before_agent_start", "signal: live streaming probe")) {
  throw new Error("Pi raised before_agent_start for a follow-up queued while streaming; the extension must never wait for that");
}
releaseStream();
await waitFor(() => settledRuns() === 1, "the first run to settle");
if (!has("user_message_start", "signal: live streaming probe")) {
  throw new Error(`the queued follow-up never joined the run as a user message: ${JSON.stringify(events)}`);
}
if (has("before_agent_start", "signal: live streaming probe")) {
  throw new Error("Pi raised before_agent_start for a queued follow-up when the run reached it");
}
if (completions !== 2) throw new Error(`the queued follow-up did not open its own model turn: ${completions} completions`);

// Idle: the successor closes while main is idle, so the next wake starts a run
// and Pi raises before_agent_start with the exact text, then the user message.
writeFileSync(process.env.FM_LIVE_WATCH_TRIGGER, "signal: live idle probe\n");
await waitFor(() => has("before_agent_start", "signal: live idle probe"), "the idle follow-up to raise before_agent_start");
await waitFor(() => armRows("arm ") === 3, "successor after the idle delivery");
await waitFor(() => settledRuns() === 2, "the idle run to settle");
if (!has("user_message_start", "signal: live idle probe")) {
  throw new Error(`the idle follow-up never reached the run as a user message: ${JSON.stringify(events)}`);
}
if (armRows("confirmed ") !== 2) {
  throw new Error(`the watcher did not confirm both successor deliveries: ${readFileSync(armLog, "utf8")}`);
}
session.dispose();
console.log("STREAM_OK");
process.exit(0);
EOF
status=$?
out=$(cat "$TMP_ROOT/stream-output")
if [ "$status" -ne 0 ] || [ "$out" != "STREAM_OK" ]; then
  fail "real-SDK streaming-time watcher delivery guard failed against pi-coding-agent $PI_VERSION: $out"
fi
pass "real Pi SDK $PI_VERSION queues a streaming-time watcher wake without before_agent_start, keeps the successor chain, and surfaces consumption of both follow-ups"

# Sixth probe: run the executable supervision extension with the REAL installed
# pi-openai-codex-compat package copied into an otherwise isolated Pi home. The
# provider transport is inherited from its isolated global settings and intercepted
# before the network, so the real provider override, tool-call loop, threshold
# compaction hook, and persisted native checkpoint all execute without using a
# captain credential or contacting OpenAI.
PI_AGENT_DIR=$(PI_PACKAGE_DIR="$PI_PACKAGE_DIR" node --input-type=module <<'EOF'
import { pathToFileURL } from "node:url";
const { getAgentDir } = await import(pathToFileURL(`${process.env.PI_PACKAGE_DIR}/dist/index.js`).href);
process.stdout.write(getAgentDir());
EOF
)
compat_source_root=${FM_PI_CODEX_COMPAT_NODE_MODULES:-"$PI_AGENT_DIR/npm/node_modules"}
compat_package_dir="$compat_source_root/pi-openai-codex-compat"
for package_path in \
  "$compat_package_dir/package.json" \
  "$compat_package_dir/extensions/index.ts"; do
  if [ ! -f "$package_path" ]; then
    fail "installed Pi compatibility resource absent: $package_path"
  fi
done
compat_version=$(jq -r '.version' "$compat_package_dir/package.json" 2>/dev/null || printf 'unknown')
compathome="$TMP_ROOT/compat-home"
compatroot="$TMP_ROOT/compat-root"
compatagentdir="$TMP_ROOT/compat-agent-dir"
compatmodules="$compatagentdir/npm/node_modules"
mkdir -p "$compathome/state/branch-session" "$compathome/config" "$compatmodules"
mkdir -p "$compatroot/.pi"
ln -s "$ROOT/bin" "$compatroot/bin"
ln -s "$ROOT/.agents" "$compatroot/.agents"
# Copy the installed package's declared dependency closure, including locally
# built native binaries. Different supported releases own different parsers;
# the live guard must neither install packages nor assume the 0.0.9 WASM tree.
if ! COMPAT_PACKAGE_DIR="$compat_package_dir" COMPAT_MODULES="$compatmodules" node --input-type=module <<'EOF'
import { cpSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
function copyPackage(source, destination, ancestors = new Map()) {
  mkdirSync(dirname(destination), { recursive: true });
  cpSync(source, destination, { recursive: true });
  const manifest = JSON.parse(readFileSync(join(source, "package.json"), "utf8"));
  const require = createRequire(join(source, "package.json"));
  const chain = new Map(ancestors).set(manifest.name, source);
  for (const name of Object.keys(manifest.dependencies ?? {})) {
    const dependency = require.resolve.paths(name).map((path) => join(path, name))
      .find((path) => existsSync(join(path, "package.json")));
    if (!dependency) throw new Error(`installed compatibility dependency absent: ${name}`);
    if (chain.get(name) === dependency) continue;
    copyPackage(dependency, join(destination, "node_modules", name), chain);
  }
}
copyPackage(process.env.COMPAT_PACKAGE_DIR, join(process.env.COMPAT_MODULES, "pi-openai-codex-compat"));
EOF
then
  fail "could not isolate the installed compatibility dependency tree"
fi

# Match the installed npm provenance without installing or discovering anything
# in main. Both extensions below are explicit, loaded by the real CLI.
printf '{"packages":["npm:pi-openai-codex-compat@%s"]}\n' "$compat_version" > "$compatagentdir/settings.json"
cat > "$repo/compat-probe.ts" <<'EOF'
import { AgentSession, DefaultPackageManager, ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { zstdDecompressSync } from "node:zlib";

export default async function compatProbe(pi) {
  const home = resolve(process.env.FM_HOME);
  const agentDir = resolve(process.env.PI_CODING_AGENT_DIR);
  const approvedProject = `${home}/projects/compat-live`;
  mkdirSync(approvedProject, { recursive: true });
  writeFileSync(`${home}/state/compat-live.meta`, `project=${approvedProject}\nwindow=fm-compat-live\n`);
  writeFileSync(`${home}/state/.wake-queue`, "1\t1\tsignal\tcompat-live.status\tsignal: compat package probe\n");
  writeFileSync(`${home}/config/supervision-branch-model`, "openai-codex/gpt-5.6-luna\n");
  writeFileSync(`${home}/config/supervision-branch-effort`, "minimal\n");

  const encode = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
  const access = `${encode({ alg: "none", typ: "JWT" })}.${encode({
    "https://api.openai.com/auth": { chatgpt_account_id: "fm-live-account" },
  })}.signature`;
  writeFileSync(`${agentDir}/auth.json`, `${JSON.stringify({
    "openai-codex": { type: "oauth", access, refresh: "unused", expires: Date.now() + 3_600_000 },
  })}\n`);

  const probeRuntime = await ModelRuntime.create();
  const probeModel = probeRuntime.getModel("openai-codex", "gpt-5.6-luna");
  if (!probeModel || probeModel.api !== "openai-codex-responses") {
    throw new Error("the installed Pi catalog no longer exposes openai-codex/gpt-5.6-luna on the Codex Responses API");
  }
  if (probeModel.contextWindow <= 5000) throw new Error("the Codex probe model cannot support its test threshold");

  // These are files consumed by the actual branch constructor, not injected
  // settings or transport overrides. Project defaults deliberately conflict.
  const root = resolve(process.env.FM_ROOT_OVERRIDE);
  const sentinel = `${agentDir}/unwanted`;
  mkdirSync(sentinel, { recursive: true });
  writeFileSync(`${sentinel}/package.json`, JSON.stringify({ name: "unwanted", pi: { extensions: ["index.ts"] } }));
  writeFileSync(`${sentinel}/index.ts`, 'export default function () { throw new Error("unwanted extension loaded"); }');
  writeFileSync(`${sentinel}/SKILL.md`, "---\nname: unwanted\ndescription: unwanted\n---\nUNWANTED_CONTEXT\n");
  writeFileSync(`${sentinel}/prompt.md`, "UNWANTED_CONTEXT\n");
  writeFileSync(`${agentDir}/AGENTS.md`, "UNWANTED_CONTEXT\n");
  writeFileSync(`${root}/AGENTS.md`, "UNWANTED_CONTEXT\n");
  const resourceSettings = {
    packages: [sentinel], extensions: [`${sentinel}/index.ts`],
    skills: [sentinel], prompts: [`${sentinel}/prompt.md`], themes: [sentinel],
  };
  const globalSettingsBytes = JSON.stringify({
    ...resourceSettings,
    defaultProvider: "openai-codex", defaultModel: "gpt-5.6-sol", defaultThinkingLevel: "high",
    transport: "sse",
    websocketConnectTimeoutMs: 7000,
    httpIdleTimeoutMs: 23000,
    httpProxy: "http://127.0.0.1:9",
    compaction: {
      enabled: true,
      reserveTokens: probeModel.contextWindow - 5000,
      keepRecentTokens: 50,
    },
    retry: { enabled: false, provider: { maxRetries: 0, maxRetryDelayMs: 1234 } },
  }, null, 2);
  const projectSettingsBytes = JSON.stringify({ ...resourceSettings, transport: "websocket", websocketConnectTimeoutMs: 1 });
  writeFileSync(`${agentDir}/settings.json`, globalSettingsBytes);
  writeFileSync(`${root}/.pi/settings.json`, projectSettingsBytes);
  const proxyEnvironment = Object.fromEntries(["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"].map((key) => [key, process.env[key]]));

  const originalResolve = DefaultPackageManager.prototype.resolve;
  let branchPackageResolutions = 0;
  DefaultPackageManager.prototype.resolve = function (...args) {
    if (this.cwd === root) {
      branchPackageResolutions += 1;
      assert.deepEqual(this.listConfiguredPackages(), [], "branch must not resolve configured packages before discovery filtering");
    }
    return originalResolve.apply(this, args);
  };
  let branchSession;
  const originalPrompt = AgentSession.prototype.prompt;
  AgentSession.prototype.prompt = function (...args) {
    if (!this.sessionManager.getSessionFile()?.startsWith(sessionsDir)) return originalPrompt.apply(this, args);
    branchSession = this;
    assert.equal(this.settingsManager.isProjectTrusted(), false);
    assert.deepEqual(this.settingsManager.getProjectSettings(), {});
    assert.deepEqual(this.resourceLoader.getSkills().skills, []);
    assert.deepEqual(this.resourceLoader.getPrompts().prompts, []);
    assert.deepEqual(this.resourceLoader.getThemes().themes, []);
    assert.deepEqual(this.resourceLoader.getAgentsFiles().agentsFiles, []);
    assert.equal(this.model.id, "gpt-5.6-luna");
    assert.equal(this.thinkingLevel, "minimal");
    return originalPrompt.apply(this, args);
  };
  let providerCalls = 0;
  const originalStream = ModelRuntime.prototype.streamSimple;
  ModelRuntime.prototype.streamSimple = function (model, context, options) {
    providerCalls += 1;
    assert.equal(options.transport, "sse", "global SSE must reach the real branch provider consumer");
    assert.equal(branchSession.settingsManager.getGlobalSettings().httpProxy, "http://127.0.0.1:9");
    assert.equal(options.websocketConnectTimeoutMs, 7000);
    assert.equal(options.timeoutMs, 23000);
    assert.equal(options.maxRetries, 0);
    assert.equal(options.maxRetryDelayMs, 1234);
    assert(!JSON.stringify(context.messages).includes("UNWANTED_CONTEXT"));
    return originalStream.call(this, model, context, options);
  };
  let websocketAttempts = 0;
  globalThis.WebSocket = class { constructor() { websocketAttempts += 1; throw new Error("unexpected WebSocket attempt"); } };

  // Legacy endpoint labels are valid outcome history but cannot name task caches.
  // Ownership at session_start reproduces the primary startup reconciliation path.
  const legacy = {
    seq: 1, epoch: 1, task: "default:w90:p2", wake: "signal: historical endpoint",
    verdict: "routine", summary: "legacy outcome",
  };
  writeFileSync(`${home}/state/branch-outcomes.jsonl`, `${JSON.stringify(legacy)}\n`);
  writeFileSync(`${home}/state/.branch-outcomes-cursor`, "1\n");
  writeFileSync(`${home}/state/.branch-outcomes-processed`, "1\n");
  writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
  const sessionsDir = `${home}/state/branch-session`;
  const requestRecords = [];
  const sse = (events) => `${events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("")}data: [DONE]\n\n`;
  async function requestBody(init) {
    const headers = new Headers(init?.headers);
    const raw = init?.body;
    let bytes;
    if (typeof raw === "string") bytes = Buffer.from(raw);
    else if (raw instanceof Uint8Array) bytes = Buffer.from(raw);
    else if (raw instanceof ArrayBuffer) bytes = Buffer.from(raw);
    else if (raw) bytes = Buffer.from(await new Response(raw).arrayBuffer());
    else bytes = Buffer.alloc(0);
    if (headers.get("content-encoding") === "zstd") bytes = zstdDecompressSync(bytes);
    return { body: JSON.parse(bytes.toString("utf8")), headers };
  }
  globalThis.fetch = async (input, init) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    if (!url.startsWith("https://chatgpt.com/backend-api/")) {
      throw new Error(`unexpected external request in compatibility probe: ${url}`);
    }
    const { body, headers } = await requestBody(init);
    const metadataRaw = body.client_metadata?.["x-codex-turn-metadata"];
    if (typeof metadataRaw !== "string") {
      throw new Error(`compatibility provider metadata absent before request: ${JSON.stringify(body.client_metadata)}`);
    }
    const metadata = JSON.parse(metadataRaw);
    requestRecords.push({ body, headers: Object.fromEntries(headers), metadata, url });

    if (metadata.request_kind === "compaction") {
      return new Response(sse([
        { type: "response.output_item.done", output_index: 0, item: { type: "compaction", encrypted_content: "fm-native-checkpoint" } },
        { type: "response.completed", response: { id: "resp_compact", status: "completed", usage: { input_tokens: 100, output_tokens: 10, total_tokens: 110 } } },
      ]), { status: 200, headers: { "content-type": "text/event-stream" } });
    }

    const turnNumber = requestRecords.filter((record) => record.metadata.request_kind === "turn").length;
    if (turnNumber === 1) {
      const args = JSON.stringify({
        task: "compat-live",
        verdict: "routine",
        summary: "installed Codex compatibility provider handled the branch",
        wake: "signal: compat package probe",
      });
      return new Response(sse([
        { type: "response.output_item.done", output_index: 0, item: { type: "function_call", id: "fc_report", call_id: "call_report", name: "fm_branch_report", arguments: args } },
        { type: "response.completed", response: { id: "resp_report", status: "completed", end_turn: true, usage: { input_tokens: 50, output_tokens: 10, total_tokens: 60 } } },
      ]), { status: 200, headers: { "content-type": "text/event-stream" } });
    }
    if (turnNumber === 2) {
      return new Response(sse([
        { type: "response.output_item.done", output_index: 0, item: { type: "message", id: "msg_done", role: "assistant", status: "completed", phase: "final_answer", content: [{ type: "output_text", text: "reported", annotations: [] }] } },
        { type: "response.completed", response: { id: "resp_done", status: "completed", end_turn: true, usage: { input_tokens: 5900, output_tokens: 100, total_tokens: 6000 } } },
      ]), { status: 200, headers: { "content-type": "text/event-stream" } });
    }
    throw new Error(`unexpected extra Codex turn request: ${turnNumber}`);
  };

  pi.registerCommand("branch-probe", { handler: async (_args, ctx) => {
    if (existsSync(`${home}/state/.branch-session`)) throw new Error("pointer existed before eligible wake");
    if (requestRecords.length !== 0) throw new Error("request before eligible wake");
    let settlementState = "not-accepted";
    let settlement;
    const offer = {
      message: "signal: compat package probe", projects: [approvedProject],
      heartbeat: false, eligible: true, accepted: false,
      accept(promise) {
        this.accepted = true;
        settlement = promise;
        settlementState = "pending";
        promise.then(
          () => { settlementState = "resolved"; },
          (error) => { settlementState = `rejected: ${error.message}`; },
        );
      },
      reportAlreadyOwned() {},
    };
    pi.events.emit("fm-branch-supervision:dispatch", offer);
    console.log(`PROBE_ADMISSION ${offer.accepted}`);
    if (!offer.accepted) {
      console.log(`PROBE_LOADED ${existsSync(`${home}/state/.pi-branch-extension-loaded`)} PROBE_POINTER ${existsSync(`${home}/state/.branch-session`)} REQUESTS ${requestRecords.length}`);
      throw new Error("eligible offer was not accepted");
    }
    let entries = [];
    for (let index = 0; index < 600; index += 1) {
      try {
        const pointer = readFileSync(`${home}/state/.branch-session`, "utf8").trim();
        entries = SessionManager.open(pointer, sessionsDir).getEntries();
      } catch {}
      const routinePublished = readFileSync(`${home}/state/branch-outcomes.jsonl`, "utf8").includes("installed Codex compatibility provider handled the branch");
      if (settlementState.startsWith("rejected: ") || (entries.some((entry) => entry.type === "compaction") && routinePublished)) break;
      await new Promise((resolveWait) => setTimeout(resolveWait, 50));
    }

    console.log(`PROBE_SETTLEMENT ${settlementState}`);
    console.log(`PROBE_POINTER ${existsSync(`${home}/state/.branch-session`)}`);
    if (settlementState.startsWith("rejected:")) throw new Error(settlementState);
    const turns = requestRecords.filter((record) => record.metadata.request_kind === "turn");
    const compactions = requestRecords.filter((record) => record.metadata.request_kind === "compaction");
    if (turns.length !== 2 || compactions.length !== 1 || requestRecords.length !== 3) {
      throw new Error(`unexpected compatibility request sequence: ${requestRecords.map((record) => record.metadata.request_kind).join(",")}`);
    }
    const expectedTools = ["read", "bash", "fm_branch_report"];
    for (const [index, turn] of turns.entries()) {
      const toolNames = Array.isArray(turn.body.tools) ? turn.body.tools.map((tool) => tool.name) : [];
      if (JSON.stringify(toolNames) !== JSON.stringify(expectedTools)) {
        throw new Error(`Codex turn ${index + 1} changed the branch tool payload: ${JSON.stringify(toolNames)}`);
      }
      const beta = turn.headers["x-codex-beta-features"] ?? "";
      if (!beta.split(",").map((item) => item.trim()).includes("remote_compaction_v2")) {
        throw new Error(`Codex turn ${index + 1} lacks the compatibility startup hook: ${beta}`);
      }
    }
    if (!turns[1].body.input.some((item) => item.type === "function_call_output" && item.call_id === "call_report")) {
      throw new Error("the installed compatibility provider did not continue after the branch report tool");
    }
    const compactRequest = compactions[0];
    if (compactRequest.body.input.at(-1)?.type !== "compaction_trigger") {
      throw new Error(`native compaction request lacks its trigger: ${JSON.stringify(compactRequest.body.input.at(-1))}`);
    }
    if (!String(compactRequest.headers["x-codex-beta-features"] ?? "").split(",").map((item) => item.trim()).includes("remote_compaction_v2")) {
      throw new Error("native compaction request lacks the remote_compaction_v2 feature header");
    }
    if (compactRequest.metadata.compaction?.implementation !== "responses_compaction_v2" ||
        compactRequest.metadata.compaction?.phase !== "pre_turn") {
      throw new Error(`native compaction metadata is wrong: ${JSON.stringify(compactRequest.metadata)}`);
    }
    const checkpoint = entries.find((entry) => entry.type === "compaction");
    if (!checkpoint || checkpoint.fromHook !== true || checkpoint.details?.kind !== "openai-codex-compat-remote-compaction") {
      throw new Error(`the real branch did not persist a compatibility checkpoint: ${JSON.stringify(checkpoint)}`);
    }
    const nativeItems = checkpoint.details.history?.filter((item) => item.type === "compaction") ?? [];
    if (nativeItems.length !== 1 || nativeItems[0].encrypted_content !== "fm-native-checkpoint") {
      throw new Error(`the persisted compatibility checkpoint lost native history: ${JSON.stringify(checkpoint.details)}`);
    }
    if (!readFileSync(`${home}/state/branch-outcomes.jsonl`, "utf8").includes("installed Codex compatibility provider handled the branch")) {
      throw new Error("the executable branch boundary did not persist its report");
    }
    await settlement;
    assert(branchPackageResolutions > 0, "real branch package resolver was not exercised");
    assert(providerCalls >= 2, "real branch provider consumer was not exercised");
    assert.equal(websocketAttempts, 0);
    // Exercise persistence-capable SDK/plugin setters on the branch-owned
    // manager, flush their async queue, and prove neither file was rewritten.
    branchSession.settingsManager.setDefaultModelAndProvider("test", "branch-only");
    branchSession.settingsManager.setDefaultThinkingLevel("low");
    branchSession.settingsManager.setTransport("websocket");
    branchSession.setAutoCompactionEnabled(false);
    await branchSession.settingsManager.flush();
    await branchSession.settingsManager.reload();
    assert.equal(branchSession.settingsManager.getTransport(), "websocket");
    assert.equal(readFileSync(`${agentDir}/settings.json`, "utf8"), globalSettingsBytes);
    assert.equal(readFileSync(`${root}/.pi/settings.json`, "utf8"), projectSettingsBytes);
    for (const [key, value] of Object.entries(proxyEnvironment)) assert.equal(process.env[key], value);
    const visible = ctx.sessionManager.getEntries().filter((entry) => entry.type === "custom_message" &&
      entry.customType === "fm-branch-merge" &&
      JSON.stringify(entry.content).includes("installed Codex compatibility provider handled the branch"));
    if (visible.length !== 1) throw new Error(`expected one routine outcome in real main, got ${visible.length}`);
    const rows = readFileSync(`${home}/state/branch-outcomes.jsonl`, "utf8").trim().split("\n").map(JSON.parse);
    if (rows.length !== 2 || rows[0].task !== "default:w90:p2" || rows[1].task !== "compat-live") {
      throw new Error("legacy history or new outcome was lost");
    }
    console.log("CODEX_COMPAT_OK");
    ctx.shutdown();
  }});
}
EOF
pi_cli_entry=$(jq -er '.bin.pi' "$PI_PACKAGE_DIR/package.json") || fail "installed Pi CLI entry is absent"
FM_HOME="$compathome" FM_ROOT_OVERRIDE="$compatroot" PI_CODING_AGENT_DIR="$compatagentdir" PI_OFFLINE=1 \
  node "$PI_PACKAGE_DIR/$pi_cli_entry" --offline --no-context-files --no-skills \
  --no-prompt-templates --no-themes --no-extensions \
  -e "$repo/.pi/extensions/fm-branch-supervision.ts" -e "$repo/compat-probe.ts" \
  --provider openai-codex --model gpt-5.6-luna --thinking minimal \
  --session-dir "$compathome/main" -p /branch-probe > "$TMP_ROOT/compat-output" 2>&1
status=$?
out=$(cat "$TMP_ROOT/compat-output")
if [ "$status" -ne 0 ] || ! printf '%s\n' "$out" | grep -qx 'CODEX_COMPAT_OK'; then
  fail "real installed pi-openai-codex-compat $compat_version branch guard failed against pi-coding-agent $PI_VERSION: $out"
fi
pass "real Pi CLI $PI_VERSION with pi-openai-codex-compat $compat_version inherits global SSE and connection settings without project resources or writes, preserving Luna/minimal, guarded tools, legacy outcomes and native compaction"

# Real Pi custom-message ingress: publish only synthetic accepted Feishu events
# through the state owner and native encoder, then deliver them with the SDK's
# actual sendCustomMessage path. No Feishu transport, credentials, or sends.
mirrorhome="$TMP_ROOT/mirror-home"
mirroragentdir="$TMP_ROOT/mirror-agent-dir"
mkdir -p "$mirrorhome/state" "$mirrorhome/config" "$mirroragentdir"
FM_HOME="$mirrorhome" FM_ROOT_OVERRIDE="$ROOT" PI_CODING_AGENT_DIR="$mirroragentdir" \
  BRANCH_PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" PI_PACKAGE_DIR="$PI_PACKAGE_DIR" \
  node --input-type=module > "$TMP_ROOT/mirror-output" 2>&1 <<'EOF'
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
const root = resolve(process.env.FM_ROOT_OVERRIDE);
const home = resolve(process.env.FM_HOME);
const agentDir = resolve(process.env.PI_CODING_AGENT_DIR);
const sdk = await import(pathToFileURL(`${process.env.PI_PACKAGE_DIR}/dist/index.js`).href);
const state = await import(pathToFileURL(`${root}/bin/fm-feishu-state.mjs`).href);
const native = await import(pathToFileURL(`${root}/.pi/extensions/lib/fm-feishu-native-channel.ts`).href);
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
mkdirSync(`${home}/projects/probe`, { recursive: true });
writeFileSync(`${home}/state/probe.meta`, `project=${home}/projects/probe\nwindow=mirror-probe\n`);
writeFileSync(`${home}/state/.wake-queue`, "1\t1\tsignal\tprobe.status\tsignal: mirror probe\n");
const globalSettings = { transport: "sse", compaction: { enabled: false }, retry: { enabled: false } };
writeFileSync(`${agentDir}/settings.json`, JSON.stringify(globalSettings));
writeFileSync(`${agentDir}/models.json`, JSON.stringify({ providers: {
  "fm-mirror": { baseUrl: "https://fm-mirror.invalid/v1", api: "openai-completions", apiKey: "synthetic-key",
    models: [{ id: "mirror-model", contextWindow: 65536, maxTokens: 512 }] },
} }));
const runtime = await sdk.ModelRuntime.create();
const model = runtime.getModel("fm-mirror", "mirror-model");
assert(model);
let api;
let session;
let mainReplies = 0;
let releaseMain;
let holdMain = false;
let mainHeld = false;
let branchTurn = 0;
const snapshots = [];
const stagedRefs = new Set();
const beforePersistence = [];
const mirrorEntries = (manager) => manager.getEntries().filter((e) => e.type === "custom_message" && e.customType === "fm-main-mirror").map((e) => e.content);
const originalPrompt = sdk.AgentSession.prototype.prompt;
sdk.AgentSession.prototype.prompt = function (...args) {
  if (this.sessionManager.getSessionFile()?.startsWith(`${home}/state/branch-session/`)) {
    snapshots.push(mirrorEntries(this.sessionManager));
  }
  return originalPrompt.apply(this, args);
};
const waitFor = async (predicate, label) => {
  for (let i = 0; i < 600; i += 1) {
    if (predicate()) return;
    await new Promise((r) => setTimeout(r, 20));
  }
  throw new Error(`timeout: ${label}`);
};
const dispatch = async () => {
  let settlement;
  const offer = { message: "signal: mirror probe", eligible: true, heartbeat: false,
    projects: [`${home}/projects/probe`], accepted: false,
    accept(promise) { this.accepted = true; settlement = promise; }, reportAlreadyOwned() {} };
  api.events.emit("fm-branch-supervision:dispatch", offer);
  assert(offer.accepted, "mirror probe wake was not accepted");
  await settlement;
};
globalThis.fetch = async (input, init) => {
  assert(String(input).startsWith("https://fm-mirror.invalid/"), "unexpected network request");
  const body = JSON.parse(init.body);
  const branch = body.tools?.some((t) => t.function?.name === "fm_branch_report");
  let delta;
  let finish;
  if (branch) {
    branchTurn += 1;
    if (branchTurn % 2 === 1) {
      delta = { role: "assistant", tool_calls: [{ index: 0, id: `report_${branchTurn}`, type: "function", function: {
        name: "fm_branch_report", arguments: JSON.stringify({ task: "probe", verdict: "routine", summary: "mirror checked" }),
      } }] };
      finish = "tool_calls";
    } else { delta = { role: "assistant", content: "branch done" }; finish = "stop"; }
  } else {
    if (holdMain) {
      mainHeld = true;
      await new Promise((r) => { releaseMain = r; });
      holdMain = false;
    }
    delta = { role: "assistant", content: `MAIN_REPLY_${++mainReplies}` };
    finish = "stop";
  }
  const chunk = (value, reason = null) => ({ id: "chat_mirror", object: "chat.completion.chunk", created: 1, model: "mirror-model", choices: [{ index: 0, delta: value, finish_reason: reason }] });
  return new Response(`data: ${JSON.stringify(chunk(delta))}\n\ndata: ${JSON.stringify(chunk({}, finish))}\n\ndata: [DONE]\n\n`, { headers: { "content-type": "text/event-stream" } });
};
async function openMain(manager) {
  const settingsManager = sdk.SettingsManager.inMemory(globalSettings, { projectTrusted: false });
  const loader = new sdk.DefaultResourceLoader({ cwd: root, agentDir, settingsManager,
    noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
    additionalExtensionPaths: [process.env.BRANCH_PLUGIN], systemPrompt: "Isolated mirror test",
    extensionFactories: [{ name: "mirror-probe", factory: (pi) => {
      api = pi;
      pi.on("message_start", async (event, ctx) => {
        const ref = event.message.details?.deliveryRef;
        if (!stagedRefs.has(ref)) return;
        stagedRefs.delete(ref);
        assert(!ctx.sessionManager.getEntries().some((e) => e.type === "custom_message" && e.details?.deliveryRef === ref), "fixture must reach the pre-persistence boundary");
        await dispatch();
        beforePersistence.push(snapshots.at(-1));
      });
    } }],
  });
  await loader.reload();
  assert.deepEqual(loader.getExtensions().errors, []);
  const created = await sdk.createAgentSession({ cwd: root, agentDir, model, modelRuntime: runtime,
    settingsManager, resourceLoader: loader, sessionManager: manager, tools: [], thinkingLevel: "off" });
  const errors = [];
  await created.session.bindExtensions({ mode: "print", onError: (e) => errors.push(e) });
  return { session: created.session, errors };
}
const manager = sdk.SessionManager.create(root, `${home}/main`);
({ session } = await openMain(manager));
await session.prompt("TUI_INITIAL");
state.createPairing(home, { appIdFingerprint: `sha256:${"1".repeat(64)}`, allowedUser: "ou_testcaptain", allowedChat: "oc_testchat" });
state.bindSession(home, { sessionId: manager.getSessionId(), sessionFile: manager.getSessionFile(),
  sessionCwd: root, headerId: manager.getSessionId(), headerCwd: root });
function ingress(label) {
  const published = state.publishFeishuInbound(home, { event_id: `evt_${label}`, message_id: `om_${label}`,
    sender_id: "ou_testcaptain", sender_type: "user", chat_id: "oc_testchat", chat_type: "p2p", message_type: "text", content: label, create_time: "1" });
  assert.equal(published.status, "published");
  const event = state.findInboundByDeliveryRef(home, published.deliveryRef);
  const message = native.encodeFeishuIngress(event);
  // Native string-content evidence format; the production classifier still
  // verifies this immutable ledger record, binding generation, and exact body.
  const digest = createHash("sha256").update(`s;${Buffer.byteLength(message.content)}:${message.content}`).digest("hex");
  state.recordInboundContentDigest(home, published.deliveryRef, `sha256:${digest}`);
  assert(native.classifyFeishuMessage({ role: "custom", ...message }));
  return message;
}
const idle = ingress("FEISHU_IDLE");
// Continuation may add operational turns after an unanswered input; bind the
// response to this ingress rather than assuming a global provider-call count.
const idleReply = mainReplies + 1;
stagedRefs.add(idle.details.deliveryRef);
await session.sendCustomMessage(idle, { triggerTurn: true, deliverAs: "steer" });
assert(beforePersistence[0]?.includes("[captain] FEISHU_IDLE"), "trusted idle Feishu input missing before dependent branch prompt");
await dispatch();
let mirrored = snapshots.at(-1);
assert.equal(mirrored.filter((s) => s === "[captain] FEISHU_IDLE").length, 1, "persisted idle ingress duplicated staged input");
assert(mirrored.indexOf("[captain] TUI_INITIAL") < mirrored.indexOf("[main] MAIN_REPLY_1"));
assert(mirrored.indexOf("[captain] FEISHU_IDLE") < mirrored.indexOf(`[main] MAIN_REPLY_${idleReply}`));

const streamed = ingress("FEISHU_STREAM");
const streamReply = mainReplies + 1;
holdMain = true;
const streaming = session.prompt("TUI_STREAM");
await waitFor(() => mainHeld, "main streaming");
stagedRefs.add(streamed.details.deliveryRef);
await session.sendCustomMessage(streamed, { triggerTurn: true, deliverAs: "steer" });
assert(stagedRefs.has(streamed.details.deliveryRef), "queued input was consumed before streaming was released");
releaseMain();
await streaming;
assert(beforePersistence[1]?.includes("[captain] FEISHU_STREAM"), "trusted streaming Feishu input missing before dependent branch prompt");
await dispatch();
mirrored = snapshots.at(-1);
assert.equal(mirrored.filter((s) => s === "[captain] FEISHU_STREAM").length, 1);
assert(mirrored.indexOf("[captain] TUI_STREAM") < mirrored.indexOf(`[main] MAIN_REPLY_${streamReply}`));
assert(mirrored.indexOf(`[main] MAIN_REPLY_${streamReply}`) < mirrored.indexOf("[captain] FEISHU_STREAM"));
assert(mirrored.indexOf("[captain] FEISHU_STREAM") < mirrored.indexOf(`[main] MAIN_REPLY_${streamReply + 1}`));

for (const message of [
  { ...idle, content: "FORGED_BODY" },
  { ...idle, details: { ...idle.details, bindingGeneration: idle.details.bindingGeneration + 1 } },
  { ...idle, details: { ...idle.details, deliveryRef: `in_${"0".repeat(24)}` } },
  { customType: "internal-notification", content: "INTERNAL_CUSTOM", display: false },
  { customType: "fm-branch-merge", content: "BRANCH_RESULT", display: false },
]) await session.sendCustomMessage(message, { triggerTurn: false });
manager.appendMessage({ role: "user", content: "\u2063FIRSTMATE_OP: v1 watcher: INTERNAL_WAKE", timestamp: Date.now() });
manager.appendMessage({ role: "toolResult", toolCallId: "test", toolName: "read", content: [{ type: "text", text: "TOOL_RESULT" }], isError: false, timestamp: Date.now() });
await dispatch();
assert(!snapshots.at(-1).some((s) => /FORGED_|INTERNAL_|BRANCH_RESULT|TOOL_RESULT/.test(s)), "untrusted or internal traffic entered captain context");
assert.equal(snapshots.at(-1).filter((s) => s === "[captain] FEISHU_IDLE").length, 1, "unverified binding generation or delivery ref was accepted");
const oldBranchFile = readFileSync(`${home}/state/.branch-session`, "utf8");
await session.dispose();
({ session } = await openMain(sdk.SessionManager.open(manager.getSessionFile())));
await dispatch();
assert.notEqual(readFileSync(`${home}/state/.branch-session`, "utf8"), oldBranchFile);
mirrored = snapshots.at(-1);
for (const label of ["TUI_INITIAL", "FEISHU_IDLE", "TUI_STREAM", "FEISHU_STREAM"]) {
  assert.equal(mirrored.filter((s) => s === `[captain] ${label}`).length, 1, `cold branch history lost or duplicated ${label}`);
}
assert(mirrored.indexOf("[captain] FEISHU_IDLE") < mirrored.indexOf(`[main] MAIN_REPLY_${idleReply}`));
assert(mirrored.indexOf("[captain] FEISHU_STREAM") < mirrored.indexOf(`[main] MAIN_REPLY_${streamReply + 1}`));
assert(!mirrored.some((s) => /FORGED_|INTERNAL_|BRANCH_RESULT|TOOL_RESULT/.test(s)));
await session.dispose();
console.log("FEISHU_MIRROR_OK");
EOF
status=$?
out=$(cat "$TMP_ROOT/mirror-output")
if [ "$status" -ne 0 ] || ! printf '%s\n' "$out" | grep -qx 'FEISHU_MIRROR_OK'; then
  fail "real Pi $PI_VERSION trusted Feishu mirror guard failed: $out"
fi
pass "real Pi SDK $PI_VERSION mirrors only provenance-verified Feishu text before idle/streaming branch turns, once and in order across persistence and cold creation"

# The actual Pi host and extension runtime also exercise delegated continuation
# while an independent MAIN question arrives before the branch settles.
FM_REAL_ROOT="$ROOT" FM_DELEGATION_HOST_DIR="$TMP_ROOT/delegation-host" \
  python3 "$ROOT/tests/delegation-host.py" > "$TMP_ROOT/delegation-host-output" 2>&1 || {
    cat "$TMP_ROOT/delegation-host-output"
    fail "real Pi delegated continuation host failed"
  }
cat "$TMP_ROOT/delegation-host-output"
pass "real Pi delegated continuation preserves open goals and handles MAIN input concurrently"
