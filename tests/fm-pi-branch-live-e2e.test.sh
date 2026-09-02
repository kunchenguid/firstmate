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
# session recorded.
#
# No provider call leaves the machine. The first branch probe points
# PI_CODING_AGENT_DIR at an empty directory, so it reads no credentials and
# model resolution stays empty by construction. The 429 probe intercepts its
# only request before transport, and the precedence probes read only a local
# placeholder key for their never-contacted fake provider. Run after
# every Pi upgrade and before trusting refreshed per-harness evidence
# (docs/verification/runtime-backends.md).
set -u

if [ "${FM_PI_BRANCH_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PI_BRANCH_LIVE_E2E=1 to run the real-SDK Pi branch regression"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
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
cp "$ROOT/.pi/extensions/lib/fm-branch-model-picker.ts" "$repo/.pi/extensions/lib/fm-branch-model-picker.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
mkdir -p "$repo/bin"
cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
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
