#!/usr/bin/env bash
# Opt-in live guard for the Pi supervision-branch extension against the REAL
# installed @earendil-works/pi-coding-agent SDK (no stubs): the branch session
# is created through the real DefaultResourceLoader/SessionManager/
# createAgentSession surface, the custom bash and fm_branch_report tool
# definitions must be accepted by the real tool registry, the session file and
# pointer must persist on disk, and - because the isolated agent dir carries no
# credentials and no models - the branch's first prompt must fail fast and
# prove the never-lose-a-wake fallback to main against the real SDK. It also
# resolves the supervision-branch model pin through the branch's REAL
# ModelRuntime, so a pin the vendor cannot resolve is proven to refuse the
# build rather than silently running the branch on main's model. A second
# probe pins the vendor contract that pin rests on: an explicit model must beat
# the model a reopened session recorded, proven against a local,
# never-contacted fake provider. A third probe does the same for the
# supervision-branch effort pin: Pi's own supported-level list is what the
# picker offers, Pi's own clamp is what lowers a level a model cannot run, and
# an explicit thinking level must beat the level a reopened session recorded.
#
# No provider call leaves the machine. The branch probe points
# PI_CODING_AGENT_DIR at an empty directory, so it reads no credentials and
# model resolution stays empty by construction. The precedence probe reads
# only a local placeholder key for its never-contacted fake provider. Run after
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
cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
mkdir -p "$repo/bin"
cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
chmod +x "$repo/bin/fm-operational-input.sh"
ln -s "$PI_PACKAGE_DIR" "$repo/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$repo/node_modules/@earendil-works/pi-tui"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-ai" "$repo/node_modules/@earendil-works/pi-ai"
ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$repo/node_modules/typebox"

# Stock macOS Bash 3.2 cannot reliably parse JavaScript template literals in a
# heredoc nested inside command substitution, so capture through a file.
PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
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
const bus = {
  on(channel, handler) {
    busHandlers.set(channel, [...(busHandlers.get(channel) ?? []), handler]);
    return () => {};
  },
  emit(channel, data) {
    for (const handler of busHandlers.get(channel) ?? []) handler(data);
  },
};
const mainUserMessages = [];
const piHandlers = new Map();
const pi = {
  events: bus,
  on(event, handler) {
    piHandlers.set(event, [...(piHandlers.get(event) ?? []), handler]);
  },
  registerTool() {},
  registerCommand() {},
  registerMessageRenderer() {},
  sendMessage() {},
  sendUserMessage(content, options) {
    mainUserMessages.push({ content, options: options ?? {} });
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
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
const sessionCtx = {
  sessionManager: { getSessionFile: () => `${home}/main.jsonl`, getEntries: () => [] },
  modelRegistry,
};
for (const handler of piHandlers.get("session_start") ?? []) await handler({}, sessionCtx);
if (existsSync(`${home}/state/.pi-branch-extension-loaded`)) {
  throw new Error("branch activated before the primary session acquired its lock");
}
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);

const offer = {
  message: "signal: live-sdk probe",
  projects: [approvedProject],
  heartbeat: false,
  eligible: true,
  accepted: false,
  accept() {
    offer.accepted = true;
  },
};
bus.emit("fm-branch-supervision:dispatch", offer);
if (!offer.accepted) throw new Error("branch did not accept the wake offer against the real SDK");
for (let i = 0; i < 600 && mainUserMessages.length === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 50));
}
// With an empty agent dir there is no model, so the branch's first prompt
// must fail fast and return the wake to main - proving both that the real
// createAgentSession accepted our loader, tools, and custom definitions
// (construction succeeds) and that the fallback keeps the wake.
if (mainUserMessages.length !== 1) throw new Error("wake was lost: no fallback reached main");
const fallback = mainUserMessages[0].content;
if (!fallback.includes("FIRSTMATE WATCHER WAKE: signal: live-sdk probe")) {
  throw new Error(`fallback lost the wake reason: ${fallback}`);
}
if (!fallback.includes("Supervision branch unavailable")) {
  throw new Error(`fallback did not name the branch failure: ${fallback}`);
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
// and return the wake to main naming the pin, rather than silently running the
// branch on whatever model main would have used.
writeFileSync(`${home}/config/supervision-branch-model`, "openai/no-such-live-model\n");
for (const handler of piHandlers.get("session_shutdown") ?? []) await handler({}, sessionCtx);
for (const handler of piHandlers.get("session_start") ?? []) await handler({}, sessionCtx);
writeFileSync(`${home}/state/.wake-queue`, "1\t2\tsignal\tlive-probe.status\tsignal: live pin probe\n");
const pinOffer = {
  message: "signal: live pin probe",
  projects: [approvedProject],
  heartbeat: false,
  eligible: true,
  accepted: false,
  accept() {
    pinOffer.accepted = true;
  },
};
bus.emit("fm-branch-supervision:dispatch", pinOffer);
if (!pinOffer.accepted) throw new Error("branch did not accept the pinned wake offer");
for (let i = 0; i < 600 && mainUserMessages.length === 1; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 50));
}
if (mainUserMessages.length !== 2) throw new Error("pinned wake was lost: no fallback reached main");
const pinFallback = mainUserMessages[1].content;
if (!pinFallback.includes("openai/no-such-live-model") || !pinFallback.includes("supervision model pin")) {
  throw new Error(`the real-SDK fallback did not name the unusable pin: ${pinFallback}`);
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

# Second probe: the vendor contract the supervision-branch model pin rests on.
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

# Third probe: the vendor contract the supervision-branch EFFORT pin rests on.
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
