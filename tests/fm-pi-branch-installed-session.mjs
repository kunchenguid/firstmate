// Installed-Pi regression for the supervision outcome history window.
//
// This intentionally does not use fm-pi-branch-extension.test.sh's mocked Pi
// API. It loads the tracked extension through the installed DefaultResourceLoader,
// binds it to a real AgentSession, and uses an in-process deterministic provider
// for the branch turn so no request can leave the test process.
import assert from "node:assert/strict";
import { writeFileSync, mkdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const [root, home, piPackageDir] = process.argv.slice(2);
assert.ok(root && home && piPackageDir, "usage: node fm-pi-branch-installed-session.mjs ROOT HOME PI_PACKAGE_DIR");
assert.equal(process.env.FM_HOME, home, "the installed-Pi fixture requires an explicit isolated FM_HOME");

const sdk = await import(pathToFileURL(path.join(piPackageDir, "dist/index.js")));
const piAi = await import(pathToFileURL(path.join(piPackageDir, "node_modules/@earendil-works/pi-ai/dist/index.js")));
const extensionPath = path.join(root, ".pi/extensions/fm-branch-supervision.ts");
const periodicExtensionPath = path.join(root, ".pi/extensions/fm-periodic-stow.ts");
const probePath = path.join(home, "dispatch-probe.ts");

mkdirSync(path.join(home, "state"), { recursive: true });
mkdirSync(path.join(home, "config"), { recursive: true });
writeFileSync(path.join(home, "state/.lock"), `${process.pid}\n`);

// The probe crosses the same shared extension event bus as the real watcher.
// It is only a fixture driver: the production extension owns admission,
// reconciliation, branch creation, reporting, and settlement.
writeFileSync(probePath, `
import { writeFileSync } from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI): void {
  pi.registerTool({
    name: "dispatch_bounded_history_fixture",
    label: "Dispatch bounded history fixture",
    description: "Dispatch one isolated supervision wake.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
    execute: async () => {
      writeFileSync(process.env.FM_HOME + "/state/.wake-queue", "1\\t1\\tsignal\\tbranch-driver.status\\tsignal: ordinary eligible admission after bounded outcome recovery\\n");
      const offer = {
        token: "installed-pi-bounded-history",
        message: "signal: ordinary eligible admission after bounded outcome recovery",
        projects: [], heartbeat: false, eligible: true, idaResultRows: [],
        eligibleSeqs: ["1"], eligibleTasks: ["branch-driver"],
        taskBySeq: { "1": "branch-driver" }, declineReason: "no-listener",
        accepted: false, settlement: Promise.resolve(),
        accept(settlement = Promise.resolve()) { this.accepted = true; this.declineReason = ""; this.settlement = settlement; },
        decline(reason: string) { if (!this.accepted) this.declineReason = reason; },
      };
      pi.events.emit("fm-branch-supervision:dispatch", offer);
      if (!offer.accepted) throw new Error("real supervision extension declined fixture: " + offer.declineReason);
      await offer.settlement;
      return { content: [{ type: "text", text: JSON.stringify({ accepted: true, settled: true }) }] };
    },
  });
}
`);

const identity = (n) => n.toString(16).padStart(64, "0");
const rows = [];
for (let seq = 1; seq <= 1000; seq += 1) {
  rows.push({
    seq, epoch: seq, task: `padding-${seq}`, wake: "fixture", verdict: "routine",
    summary: `padding-${seq}-${"x".repeat(1200)}`, silent: false,
  });
}
const replace = (seq, row) => {
  rows[seq - 1] = {
    seq, epoch: seq, wake: "fixture", silent: false, ...row,
    ...(row.taskGeneration ? { statusEndpoint: seq, statusIdent: `fixture-${seq}` } : {}),
  };
};
replace(100, { task: "old-decision", verdict: "captain", summary: "older unprocessed decision remains actionable" });
replace(500, { task: "outside-first", verdict: "routine", summary: "outside-window first material", taskGeneration: "g-outside-first", evidenceKey: identity(1), taskDisposition: "in_flight" });
replace(700, { task: "outside-terminal", verdict: "routine", summary: "outside-window terminal", taskGeneration: "g-outside-terminal", evidenceKey: identity(2), taskDisposition: "archived" });
replace(850, { task: "inside-old", verdict: "routine", summary: "inside-window obsolete material", taskGeneration: "g-inside-old", evidenceKey: identity(3), taskDisposition: "in_flight" });
replace(900, { task: "outside-first", verdict: "routine", summary: "inside-window terminal", taskGeneration: "g-outside-first", evidenceKey: identity(4), taskDisposition: "archived" });
replace(901, { task: "inside-old", verdict: "routine", summary: "inside-window terminal", taskGeneration: "g-inside-old", evidenceKey: identity(5), taskDisposition: "done" });
replace(950, { task: "outside-terminal", verdict: "routine", summary: "inside-window new material", taskGeneration: "g-outside-terminal", evidenceKey: identity(6), taskDisposition: "in_flight" });
replace(997, { task: "outside-first", verdict: "routine", summary: "outside-window first material", taskGeneration: "g-outside-first", evidenceKey: identity(1), taskDisposition: "archived" });
replace(998, { task: "outside-terminal", verdict: "routine", summary: "inside-window new material", taskGeneration: "g-outside-terminal", evidenceKey: identity(6), taskDisposition: "in_flight" });
replace(999, { task: "inside-old", verdict: "routine", summary: "inside-window obsolete material", taskGeneration: "g-inside-old", evidenceKey: identity(3), taskDisposition: "done" });
replace(1000, { task: "new-decision", verdict: "captain", summary: "new exact decision remains visible" });
const store = rows.map((row) => JSON.stringify(row)).join("\n") + "\n";
assert.ok(Buffer.byteLength(store) > 1024 * 1024, "fixture must exceed the historical 1 MiB stdout guard");
writeFileSync(path.join(home, "state/branch-outcomes.jsonl"), store);
writeFileSync(path.join(home, "state/.branch-outcomes-cursor"), "996\n");
writeFileSync(path.join(home, "state/.branch-outcomes-processed"), "99\n");

for (const task of ["old-decision", "new-decision"]) {
  mkdirSync(path.join(home, "data", task), { recursive: true });
  mkdirSync(path.join(home, "projects", "approved"), { recursive: true });
  writeFileSync(path.join(home, "state", `${task}.meta`),
    `spawn_gen=g-${task}\nproject=${path.join(home, "projects", "approved")}\nwindow=fm-${task}\n`);
  writeFileSync(path.join(home, "state", `${task}.status`), "working: fixture\n");
  writeFileSync(path.join(home, "data", task, "task.json"), `${JSON.stringify({
    schema: "fm-task.v1", id: task, title: task, body: "fixture", state: "done", kind: "ship",
    repo: "", priority: "", created: "2026-10-04", closed: null, completion: null, hold: null,
    deferred_until: null, blocked_by: [], links: {}, history: [], updated_at: "2026-10-04T00:00:00Z",
    progress: { acceptance: "fixture", current_state: "fixture", remaining_gap: "fixture", next_step: "fixture" },
  })}\n`);
}

let providerCalls = 0;
const originalFetch = globalThis.fetch;
let networkCalls = 0;
globalThis.fetch = async () => { networkCalls += 1; throw new Error("unexpected network from installed-Pi regression"); };
const providerConfig = {
  baseUrl: "http://127.0.0.1/unused",
  apiKey: "offline-test-only",
  api: "bounded-history-local-api",
  models: [{
    id: "deterministic", name: "Deterministic bounded-history fixture", reasoning: false,
    input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 32768, maxTokens: 256,
  }],
  streamSimple(model, context) {
    providerCalls += 1;
    const stream = piAi.createAssistantMessageEventStream();
    const output = {
      role: "assistant", content: [], api: model.api, provider: model.provider, model: model.id,
      usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
      stopReason: "stop", timestamp: Date.now(),
    };
    const all = context.messages.map((message) => typeof message.content === "string"
      ? message.content
      : Array.isArray(message.content)
        ? message.content.filter((item) => item.type === "text").map((item) => item.text).join("\n")
        : "").join("\n");
    const alreadyReported = context.messages.some((message) => message.role === "toolResult" && message.toolName === "fm_branch_report");
    queueMicrotask(() => {
      stream.push({ type: "start", partial: output });
      if (all.includes("FIRSTMATE SUPERVISION WAKE:") && !alreadyReported) {
        output.stopReason = "toolUse";
        const toolCall = { type: "toolCall", id: `report-${providerCalls}`, name: "fm_branch_report",
          arguments: { task: "branch-driver", verdict: "routine", summary: "ordinary eligible admission recovered" } };
        output.content.push(toolCall);
        stream.push({ type: "toolcall_start", contentIndex: 0, partial: output });
        stream.push({ type: "toolcall_delta", contentIndex: 0, delta: JSON.stringify(toolCall.arguments), partial: output });
        stream.push({ type: "toolcall_end", contentIndex: 0, toolCall, partial: output });
        stream.push({ type: "done", reason: "toolUse", message: output });
      } else {
        const text = "ISOLATED_PI_FIXTURE_SETTLED";
        output.content.push({ type: "text", text });
        stream.push({ type: "text_start", contentIndex: 0, partial: output });
        stream.push({ type: "text_delta", contentIndex: 0, delta: text, partial: output });
        stream.push({ type: "text_end", contentIndex: 0, content: text, partial: output });
        stream.push({ type: "done", reason: "stop", message: output });
      }
      stream.end();
    });
    return stream;
  },
};

const settings = sdk.SettingsManager.inMemory({
  compaction: { enabled: false }, retry: { enabled: false, provider: { maxRetries: 0 } },
  cacheWarming: "off", packages: [], extensions: [], skills: [], prompts: [], themes: [],
});
const runtime = await sdk.ModelRuntime.create();
runtime.registerProvider("bounded-history-local", providerConfig);
await runtime.refresh({ providers: ["bounded-history-local"], allowNetwork: false });
const model = runtime.getModel("bounded-history-local", "deterministic");
assert.ok(model, "isolated deterministic provider must be available");
const loader = new sdk.DefaultResourceLoader({
  cwd: root, agentDir: home, settingsManager: settings,
  noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
  additionalExtensionPaths: [periodicExtensionPath, extensionPath, probePath],
  systemPromptOverride: () => "Installed-Pi bounded-history regression.",
  appendSystemPromptOverride: () => [], agentsFilesOverride: () => ({ agentsFiles: [] }),
});
await loader.reload();
assert.deepEqual(loader.getExtensions().errors, [], "real loader must load the tracked extension without errors");

const mainSessionDir = path.join(home, "state/main-session");
mkdirSync(mainSessionDir, { recursive: true });
const sessionManager = sdk.SessionManager.create(root, mainSessionDir);
const { session } = await sdk.createAgentSession({
  cwd: root, agentDir: home, modelRuntime: runtime, model, thinkingLevel: "off",
  resourceLoader: loader, settingsManager: settings, sessionManager,
});
const extensionErrors = [];

const waitFor = async (predicate, label) => {
  for (let attempt = 0; attempt < 500; attempt += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timed out waiting for ${label}`);
};

try {
  await session.bindExtensions({ mode: "print", onError: (error) => extensionErrors.push(error) });
  await waitFor(() => sessionManager.getEntries().some((entry) =>
    entry.type === "custom" && entry.customType === "fm-branch-visible-outcome" && entry.data?.seq === 1000),
  "new sequence-keyed visible outcome");
  await waitFor(() => session.messages.some((message) =>
    message.role === "custom" && message.customType === "fm-branch-process"),
  "ordered outcome processing request");

  const routine = session.messages.filter((message) => message.role === "custom" && message.customType === "fm-branch-merge");
  assert.deepEqual(routine.map((message) => message.content), [
    "⛵ outside-first: outside-window first material",
    "⛵ outside-terminal: inside-window new material",
  ], "window-external evidence stays unknown while wholly proven obsolete material is suppressed");
  const processing = session.messages.filter((message) => message.role === "custom" && message.customType === "fm-branch-process").at(-1);
  assert.ok(processing?.content.includes('sequences="100,1000"'), "old unprocessed and new outcomes keep exact sequence identity");
  assert.ok(processing.content.indexOf("[seq 100] task=old-decision") < processing.content.indexOf("[seq 1000] task=new-decision"),
    "substantive decisions remain ordered");

  const outcomes = session.getToolDefinition("fm_branch_outcomes");
  const processed = session.getToolDefinition("fm_branch_processed");
  assert.ok(outcomes && processed, "real AgentSession exposes production outcome tools");
  const loaded = await outcomes.execute("installed-load", { sequences: "100,1000" });
  assert.equal(loaded.isError, undefined, JSON.stringify(loaded));
  assert.match(loaded.content[0].text, /"seq":100/);
  assert.match(loaded.content[0].text, /"seq":1000/);
  const acknowledged = await processed.execute("installed-ack", { sequences: "100,1000" });
  assert.equal(acknowledged.isError, undefined, JSON.stringify(acknowledged));
  assert.equal(readFileSync(path.join(home, "state/.branch-outcomes-processed"), "utf8").trim(), "1000");

  const task = "branch-driver";
  mkdirSync(path.join(home, "data", task), { recursive: true });
  mkdirSync(path.join(home, "projects", "approved"), { recursive: true });
  writeFileSync(path.join(home, "state", `${task}.meta`),
    `spawn_gen=g-${task}\nproject=${path.join(home, "projects", "approved")}\nwindow=fm-${task}\n`);
  writeFileSync(path.join(home, "state", `${task}.status`), "working: fixture\n");
  writeFileSync(path.join(home, "data", task, "task.json"), `${JSON.stringify({
    schema: "fm-task.v1", id: task, title: task, body: "fixture", state: "in_flight", kind: "ship",
    repo: "", priority: "", created: "2026-10-04", closed: null, completion: null, hold: null,
    deferred_until: null, blocked_by: [], links: {}, history: [], updated_at: "2026-10-04T00:00:00Z",
    progress: { acceptance: "fixture", current_state: "fixture", remaining_gap: "fixture", next_step: "fixture" },
  })}\n`);
  const dispatch = session.getToolDefinition("dispatch_bounded_history_fixture");
  assert.ok(dispatch, "probe tool must be registered through the real extension runtime");
  const admitted = await dispatch.execute("installed-dispatch", {});
  assert.equal(admitted.isError, undefined, JSON.stringify(admitted));
  assert.deepEqual(JSON.parse(admitted.content[0].text), { accepted: true, settled: true });
  const appended = readFileSync(path.join(home, "state/branch-outcomes.jsonl"), "utf8").trim().split("\n").map(JSON.parse).at(-1);
  assert.equal(appended.seq, 1001);
  assert.equal(appended.task, "branch-driver");
  assert.equal(appended.summary, "ordinary eligible admission recovered");
  assert.ok(providerCalls >= 2, "real branch AgentSession completed a tool call and settled");
  assert.equal(networkCalls, 0, "the deterministic provider made no external request");
  assert.deepEqual(extensionErrors, [], JSON.stringify(extensionErrors));
  console.log(JSON.stringify({
    piVersion: JSON.parse(readFileSync(path.join(piPackageDir, "package.json"), "utf8")).version,
    storeBytes: Buffer.byteLength(store), historyRows: rows.length, recentWindow: 200,
    processedSequences: [100, 1000], visibleSequence: 1000, admittedSequence: 1001,
    providerCalls, networkCalls, runtime: "installed AgentSession + DefaultResourceLoader",
  }));
} finally {
  await session.extensionRunner.emit({ type: "session_shutdown", reason: "quit" });
  session.dispose();
  globalThis.fetch = originalFetch;
}
