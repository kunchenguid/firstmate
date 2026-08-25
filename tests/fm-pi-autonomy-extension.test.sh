#!/usr/bin/env bash
# Active-mode executable regression for the Pi multi-brain extension.
# The Pi SDK and model are deterministic in-process fixtures, while Firstmate's
# config, prompt, journal, ownership, and routing code are real. No provider,
# Linear, forge, project mutation, or worker process is contacted.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-autonomy-extension)
repo="$TMP_ROOT/repo"
home="$TMP_ROOT/home"
mkdir -p \
  "$repo/.pi/extensions/lib" \
  "$repo/node_modules/@earendil-works/pi-coding-agent" \
  "$repo/node_modules/@earendil-works/pi-ai" \
  "$repo/node_modules/@earendil-works/pi-tui" \
  "$repo/node_modules/typebox" \
  "$home/state" "$home/config" "$home/data" "$home/projects/app"
cp "$ROOT/.pi/extensions/fm-branch-supervision.ts" "$repo/.pi/extensions/fm-branch-supervision.ts"
cp "$ROOT/.pi/extensions/lib/fm-autonomy.ts" "$repo/.pi/extensions/lib/fm-autonomy.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
git -C "$home/projects/app" init -q
git -C "$home/projects/app" remote add origin https://github.com/acme/app.git

cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
import { mkdirSync, writeFileSync } from "node:fs";

export function getAgentDir() { return "/fixture-agent"; }
export function getMarkdownTheme() { return {}; }
export class UserMessageComponent {
  constructor(content, theme) { this.content = content; this.theme = theme; }
}
export class ModelRuntime {
  static async create() { globalThis.__modelRuntimeCreates = (globalThis.__modelRuntimeCreates ?? 0) + 1; return new ModelRuntime(); }
  async getAvailable(provider) {
    return provider === "fixture-provider"
      ? [{ provider, id: "fixture-cheap", contextWindow: 32000, maxTokens: 4096, cost: { input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite: 0.1 } }]
      : [];
  }
  getModel(provider, id) {
    if (provider !== "fixture-provider") return undefined;
    if (id === "fixture-cheap") return { provider, id, contextWindow: 32000, maxTokens: 4096, cost: { input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite: 0.1 } };
    if (id === "fixture-expensive") return { provider, id, contextWindow: 32000, maxTokens: 4096, cost: { input: 2, output: 8, cacheRead: 0.2, cacheWrite: 2 } };
    return undefined;
  }
  async getAuth() { return { auth: { apiKey: globalThis.__fixtureModelAuth ?? "fixture-model-credential" }, source: "fixture" }; }
}
export class DefaultResourceLoader {
  constructor(options) { this.options = options; (globalThis.__loaders ??= []).push(this); }
  async reload() {}
}
export class SessionManager {
  constructor(file) { this.file = file; }
  static create(_cwd, dir) {
    mkdirSync(dir, { recursive: true });
    const file = `${dir}/fixture.jsonl`;
    writeFileSync(file, "");
    return new SessionManager(file);
  }
  static open(file) { return new SessionManager(file); }
  getSessionFile() { return this.file; }
  getSessionId() { return this.file; }
}
export function createBashToolDefinition() {
  globalThis.__bashToolCreated = true;
  return { name: "bash", parameters: { type: "object" }, async execute() { return { content: [] }; } };
}
export async function createAgentSession(options) {
  const listeners = [];
  const ordinal = (globalThis.__sessions?.length ?? 0) + 1;
  const session = {
    options,
    ordinal,
    customMessages: [],
    prompts: [],
    ops: [],
    subscribe(listener) { listeners.push(listener); return () => {}; },
    getContextUsage() { return { tokens: globalThis.__overflowSession === ordinal ? 20000 : 1000, contextWindow: 32000, percent: 0 }; },
    async sendCustomMessage(message) { session.customMessages.push(message); session.ops.push({ kind: "custom", message }); },
    async prompt(text) {
      session.prompts.push(text);
      session.ops.push({ kind: "prompt", text });
      for (const listener of listeners) listener({ type: "turn_start", turnIndex: 0, timestamp: Date.now() });
      const marker = text.lastIndexOf("\n\n{");
      const envelope = JSON.parse(text.slice(marker + 2));
      const tool = options.customTools.find((candidate) => candidate.name === "fm_supervision_decide");
      await tool.execute("fixture-call", {
        batchId: envelope.batchId,
        action: "wake",
        eventIds: envelope.events.map((event) => event.id),
        summary: "A Firstmate notification needs main-session handling.",
        reasonCodes: ["firstmate-notification"],
        workClaims: [],
      });
      const usage = {
        input: 100,
        output: 10,
        cacheRead: 900,
        cacheWrite: 100,
        cost: { input: 0.001, output: 0.001, cacheRead: 0.001, cacheWrite: 0.001, total: 0.004 },
      };
      for (const listener of listeners) listener({
        type: "message_end",
        message: { role: "assistant", provider: "fixture-provider", model: "fixture-cheap", timestamp: Date.now(), usage },
      });
    },
    async abort() {},
    dispose() {},
  };
  (globalThis.__sessions ??= []).push(session);
  return { session };
}
JS
cat > "$repo/node_modules/@earendil-works/pi-ai/package.json" <<'JSON'
{"name":"@earendil-works/pi-ai","type":"module","exports":"./index.js"}
JSON
cat > "$repo/node_modules/@earendil-works/pi-ai/index.js" <<'JS'
export function StringEnum(values) { return { type: "string", enum: values }; }
JS
cat > "$repo/node_modules/@earendil-works/pi-tui/package.json" <<'JSON'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
JSON
cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Text { constructor(text, paddingX, paddingY) { this.text = text; this.paddingX = paddingX; this.paddingY = paddingY; } }
export class Box { constructor(...children) { this.children = children; } }
export class Container { constructor(...children) { this.children = children; } }
JS
cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties, options) { return { type: "object", properties, ...(options ?? {}) }; },
  String(options) { return { type: "string", ...(options ?? {}) }; },
  Number(options) { return { type: "number", ...(options ?? {}) }; },
  Boolean(options) { return { type: "boolean", ...(options ?? {}) }; },
  Array(items, options) { return { type: "array", items, ...(options ?? {}) }; },
  Optional(schema) { return { ...schema, optional: true }; },
  Literal(value) { return { const: value }; },
  Union(anyOf, options) { return { anyOf, ...(options ?? {}) }; },
};
JS

cat > "$home/config/pi-autonomy.json" <<'JSON'
{
  "version": 1,
  "enabled": true,
  "ownerId": "fixture-owner",
  "pollSeconds": 3600,
  "linear": {
    "workspaceId": "workspace-1",
    "credential": { "env": "FM_TEST_LINEAR_KEY", "kind": "api-key" },
    "scopes": [{
      "teamId": "team-1",
      "projectId": "project-1",
      "statuses": {
        "intake": ["status-todo"],
        "claimed": "status-claimed",
        "inProgress": "status-progress",
        "completed": "status-complete"
      },
      "labels": { "required": ["label-auto"], "blocked": ["label-blocked"] }
    }]
  },
  "repositories": [{ "linearProjectId": "project-1", "firstmateProject": "app", "checkout": "app" }],
  "supervision": {
    "model": { "provider": "fixture-provider", "id": "fixture-cheap", "thinkingLevel": "low" },
    "limits": {
      "maxBatchEvents": 10,
      "maxBatchIssues": 10,
      "maxPromptInputTokens": 10000,
      "maxOutputTokens": 1000,
      "maxTurnMilliseconds": 5000,
      "maxIterationsPerBatch": 1,
      "maxCostUsdPerWindow": 1,
      "costWindowSeconds": 3600,
      "maxLinearPages": 4,
      "maxLinearRetries": 1,
      "maxLinearRetryMilliseconds": 1000
    }
  },
  "capacity": { "maxActiveIssues": 4, "maxParallelWorkers": 2, "maxHeavyValidations": 1 }
}
JSON
cat > "$home/data/projects.md" <<'EOF'
# Projects
- app [no-mistakes +yolo] - fixture (added 2026-08-25)
EOF

PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" \
FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_LINEAR_KEY="fixture-secret-never-logged" \
node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const home = process.env.FM_HOME;
writeFileSync(`${home}/state/task.meta`, `project=${home}/projects/app\nwindow=fm-task\n`);
const handlers = new Map();
const busHandlers = new Map();
const mainMessages = [];
const mainTools = [];
const commands = new Map();
const notifications = [];
const mainEntries = [];
const mainSessionManager = {
  getSessionFile: () => `${home}/main.jsonl`,
  getSessionId: () => "main-session",
  getEntries: () => mainEntries,
};
const events = {
  on(name, handler) { busHandlers.set(name, [...(busHandlers.get(name) ?? []), handler]); },
  emit(name, data) { for (const handler of busHandlers.get(name) ?? []) handler(data); },
};
const pi = {
  events,
  on(name, handler) { handlers.set(name, [...(handlers.get(name) ?? []), handler]); },
  registerTool(tool) { mainTools.push(tool); },
  registerCommand(name, value) { commands.set(name, value); },
  registerMessageRenderer() {},
  sendMessage(message, options) { mainMessages.push({ message, options: options ?? {} }); },
  sendUserMessage() { throw new Error("active autonomy path unexpectedly fell back to a user-message wake"); },
};
const expensiveMainModel = {
  provider: "fixture-provider",
  id: "fixture-expensive",
  cost: { input: 2, output: 8, cacheRead: 0.2, cacheWrite: 2 },
};
const fire = async (name, event = {}, ctx = { sessionManager: mainSessionManager, model: expensiveMainModel, ui: { notify: (...args) => notifications.push(args) } }) => {
  for (const handler of handlers.get(name) ?? []) await handler(event, ctx);
};
const waitFor = async (predicate, label) => {
  for (let i = 0; i < 300; i += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timed out waiting for ${label}`);
};
const dispatch = (seq, message) => {
  writeFileSync(`${home}/state/.wake-queue`, `1\t${seq}\tsignal\ttask.status\t${message}\n`);
  const offer = {
    message,
    projects: [`${home}/projects/app`],
    heartbeat: false,
    eligible: true,
    accepted: false,
    accept() { offer.accepted = true; },
  };
  events.emit("fm-branch-supervision:dispatch", offer);
  assert.equal(offer.accepted, true);
};

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await fire("session_start");
assert.equal(globalThis.__modelRuntimeCreates ?? 0, 0, "lock-refused startup resolved model authentication");
assert.equal(notifications.length, 0, `valid config produced a warning: ${JSON.stringify(notifications)}`);
assert.equal(process.env.FM_TEST_LINEAR_KEY, undefined, "active Pi process retained the Linear credential in provider/worker ambient env");
assert(mainTools.some((tool) => tool.name === "fm_autonomy"));
assert(commands.has("fm-autonomy"));
const autonomyTool = mainTools.find((tool) => tool.name === "fm_autonomy");
const waitingStatus = JSON.parse((await autonomyTool.execute("waiting-status", { action: "status" })).content[0].text);
assert.equal(waitingStatus.active, false);
assert(waitingStatus.diagnostics.some((value) => value.includes("waiting for this Pi session to own")));
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
await fire("agent_settled");
await waitFor(() => (globalThis.__modelRuntimeCreates ?? 0) >= 1, "deferred lock-owned activation");
await new Promise((resolve) => setTimeout(resolve, 100));
const activatedStatus = JSON.parse((await autonomyTool.execute("active-status", { action: "status" })).content[0].text);
assert.equal(activatedStatus.active, true, JSON.stringify(activatedStatus));

// Dialog committed before lazy branch creation must still append before the
// first event prompt rather than being skipped by the persistent cursor.
mainEntries.push({ type: "message", id: "pre-u", timestamp: "2026-08-24T23:59:00.000Z", message: { role: "user", content: "Pre-branch captain context", timestamp: 1 } });
await fire("turn_end", {}, { sessionManager: mainSessionManager, ui: { notify() {} } });

dispatch(1, "signal: fixture event one");
await waitFor(() => mainMessages.length === 1, "idle wake delivery");
let branch = globalThis.__sessions[0];
assert.deepEqual(branch.options.tools, ["fm_supervision_decide"]);
assert.deepEqual(branch.options.customTools.map((tool) => tool.name), ["fm_supervision_decide"]);
assert.equal(globalThis.__bashToolCreated, undefined, "read-only autonomy branch created a bash tool");
assert.equal(branch.options.model.provider, "fixture-provider");
assert.equal(branch.options.model.id, "fixture-cheap");
assert.equal(branch.options.model.maxTokens, 1000);
assert.equal(branch.options.thinkingLevel, "low");
assert(branch.options.resourceLoader.options.systemPrompt.startsWith("You are the read-only SUPERVISION BRAIN"));
assert.equal(branch.ops[0].kind, "custom", "pre-branch transcript did not append before the first event prompt");
assert(branch.ops[0].message.content.includes("Pre-branch captain context"));
assert.equal(branch.ops[1].kind, "prompt");
assert.equal(branch.options.resourceLoader.options.systemPrompt.includes(home), false, "stable prompt absorbed home state");
assert.equal(mainMessages[0].options.deliverAs, "followUp");
assert.equal(mainMessages[0].options.triggerTurn, true);
assert.equal(mainMessages[0].message.display, false);
assert.equal(mainMessages[0].message.details.action, "wake");

// A working main receives the next urgent decision as steering at the safe
// boundary, not a duplicate idle wake.
mainEntries.push({
  type: "custom_message",
  customType: "fm-autonomy-decision",
  details: { decisionId: mainMessages[0].message.details.decisionId },
});
await fire("turn_end", {}, { sessionManager: mainSessionManager, ui: { notify() {} } });
writeFileSync(`${home}/state/.wake-queue`, "");
await fire("agent_start");
globalThis.__overflowSession = branch.ordinal;
dispatch(2, "signal: fixture event two");
await waitFor(() => mainMessages.length === 2, "working steer delivery");
assert.equal(globalThis.__sessions.length, 2, "over-cap persistent context did not rotate to one fresh bounded session");
branch = globalThis.__sessions.at(-1);
assert(branch.customMessages.some((message) => message.content.includes("Pre-branch captain context")), "bounded session rotation did not replay recent visible transcript context");
delete globalThis.__overflowSession;
assert.equal(mainMessages[1].options.deliverAs, "steer");
assert.equal(mainMessages[1].options.triggerTurn, undefined);

// Finalized visible user and assistant text mirrors append silently without a
// model turn; tool results, thinking blocks, and operational input stay out.
const promptsBeforeMirror = branch.prompts.length;
mainEntries.push(
  { type: "message", id: "u1", timestamp: "2026-08-25T00:00:00.000Z", message: { role: "user", content: "Captain-visible text fixture-secret-never-logged", timestamp: 1 } },
  { type: "message", id: "t1", timestamp: "2026-08-25T00:00:01.000Z", message: { role: "toolResult", content: [{ type: "text", text: "secret tool output" }] } },
  { type: "message", id: "a1", timestamp: "2026-08-25T00:00:02.000Z", message: { role: "assistant", content: [
    { type: "thinking", thinking: "hidden chain" },
    { type: "text", text: "Visible assistant answer" },
    { type: "toolCall", name: "bash", arguments: { command: "secret" } }
  ], timestamp: 2 } },
  { type: "message", id: "op1", timestamp: "2026-08-25T00:00:03.000Z", message: { role: "user", content: "FIRSTMATE WATCHER internal", timestamp: 3 } },
);
await fire("turn_end", {}, { sessionManager: mainSessionManager, ui: { notify() {} } });
await waitFor(() => branch.customMessages.length >= 3, "silent transcript mirror");
assert.equal(branch.prompts.length, promptsBeforeMirror, "transcript mirroring triggered a model turn");
const mirrorText = branch.customMessages.map((message) => message.content).join("\n");
assert(mirrorText.includes("Captain-visible text [redacted runtime credential]"));
assert(mirrorText.includes("Visible assistant answer"));
assert.equal(mirrorText.includes("secret tool output"), false);
assert.equal(mirrorText.includes("hidden chain"), false);
assert.equal(mirrorText.includes("secret\""), false);
assert.equal(mirrorText.includes("FIRSTMATE WATCHER internal"), false);

const journal = readFileSync(`${home}/state/autonomy/journal.jsonl`, "utf8").trim().split("\n").map(JSON.parse);
const transcriptRows = journal.filter((row) => row.kind === "transcript");
assert.equal(transcriptRows.length, 3);
assert.deepEqual(transcriptRows.map((row) => row.data.role), ["user", "user", "assistant"]);
assert(journal.some((row) => row.kind === "usage" && row.data.cacheRead === 900));
assert.equal(readFileSync(`${home}/state/autonomy/journal.jsonl`, "utf8").includes("fixture-secret-never-logged"), false);
assert(readFileSync(`${home}/state/.autonomy-session`, "utf8").includes("/state/autonomy-session/"));
assert(readFileSync(`${home}/state/.autonomy-session-binding`, "utf8").startsWith("autonomy-session-"));
assert(readFileSync(`${home}/state/.autonomy-mirror-cursor`, "utf8").includes(`${home}/main.jsonl`));

// Reconfiguration refuses to reuse the main model as the supposedly cheaper
// supervision brain, even when that model is otherwise authenticated.
const selectedAsMain = { provider: "fixture-provider", id: "fixture-cheap", cost: { input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite: 0.1 } };
await fire("model_select", { model: selectedAsMain }, { sessionManager: mainSessionManager, model: selectedAsMain, ui: { notify() {} } });
const inactive = JSON.parse((await autonomyTool.execute("status-call", { action: "status" })).content[0].text);
assert.equal(inactive.active, false);
assert(inactive.diagnostics.some((value) => value.includes("distinct from the main Pi model")));

globalThis.__fixtureModelAuth = "fixture-secret-never-logged";
await fire("model_select", { model: expensiveMainModel }, { sessionManager: mainSessionManager, model: expensiveMainModel, ui: { notify() {} } });
const collision = JSON.parse((await autonomyTool.execute("collision-status", { action: "status" })).content[0].text);
assert.equal(collision.active, false);
assert(collision.diagnostics.some((value) => value.includes("credential collides")));
assert.equal(JSON.stringify(collision).includes("fixture-secret-never-logged"), false);
assert.equal(process.env.FM_TEST_LINEAR_KEY, undefined, "main-provider credential collision restored the Linear token to ambient model env");
delete globalThis.__fixtureModelAuth;

const configPath = `${home}/config/pi-autonomy.json`;
writeFileSync(configPath, readFileSync(configPath, "utf8").replace("FM_TEST_LINEAR_KEY", "FM_TEST_LINEAR_KEY_B"));
process.env.FM_TEST_LINEAR_KEY_B = "fixture-second-secret-never-logged";
await fire("model_select", { model: expensiveMainModel }, { sessionManager: mainSessionManager, model: expensiveMainModel, ui: { notify() {} } });
const reconfigured = JSON.parse((await autonomyTool.execute("reconfigured-status", { action: "status" })).content[0].text);
assert.equal(reconfigured.active, true, JSON.stringify(reconfigured));
assert.equal(process.env.FM_TEST_LINEAR_KEY, undefined, "prior Linear credential returned to ambient env after reconfiguration");
assert.equal(process.env.FM_TEST_LINEAR_KEY_B, undefined, "current Linear credential remained in ambient env after reconfiguration");

const invalidConfig = JSON.parse(readFileSync(configPath, "utf8"));
invalidConfig.linear.credential.env = "FM_TEST_LINEAR_KEY_C";
invalidConfig.capacity.maxActiveIssues = 0;
process.env.FM_TEST_LINEAR_KEY_C = "fixture-third-secret-never-logged";
writeFileSync(configPath, JSON.stringify(invalidConfig));
await fire("model_select", { model: expensiveMainModel }, { sessionManager: mainSessionManager, model: expensiveMainModel, ui: { notify() {} } });
const invalidReconfiguration = JSON.parse((await autonomyTool.execute("invalid-reconfigured-status", { action: "status" })).content[0].text);
assert.equal(invalidReconfiguration.active, false);
assert.equal(process.env.FM_TEST_LINEAR_KEY, undefined, "invalid reconfiguration restored a prior Linear credential");
assert.equal(process.env.FM_TEST_LINEAR_KEY_B, undefined, "invalid reconfiguration restored the current Linear credential");
assert.equal(process.env.FM_TEST_LINEAR_KEY_C, undefined, "invalid reconfiguration left a newly observed Linear credential ambient");

await fire("session_shutdown");
assert.equal(process.env.FM_TEST_LINEAR_KEY, "fixture-secret-never-logged", "session shutdown did not restore the parent Pi process environment for replacement activation");
assert.equal(process.env.FM_TEST_LINEAR_KEY_B, "fixture-second-secret-never-logged", "session shutdown did not restore the reconfigured Linear credential");
assert.equal(process.env.FM_TEST_LINEAR_KEY_C, "fixture-third-secret-never-logged", "session shutdown did not restore the invalidly reconfigured Linear credential");
console.log("ok - active Pi autonomy uses one read-only cheaper-model brain, safe delivery, and silent visible transcript commits");
JS

pass "active Pi autonomy extension behavior holds"
