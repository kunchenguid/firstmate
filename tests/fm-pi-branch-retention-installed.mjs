// Installed-Pi regression for active/cold supervision outcome retention.
//
// The tracked extension is loaded through the real DefaultResourceLoader and
// bound to a real AgentSession. A deterministic in-process provider handles
// the branch turn, so no network request can leave this fixture.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const [root, home, piPackageDir] = process.argv.slice(2);
assert.ok(root && home && piPackageDir,
  "usage: node fm-pi-branch-retention-installed.mjs ROOT HOME PI_PACKAGE_DIR");
assert.equal(process.env.FM_HOME, home, "the installed-Pi fixture requires an explicit isolated FM_HOME");

const sdk = await import(pathToFileURL(path.join(piPackageDir, "dist/index.js")));
const piAi = await import(pathToFileURL(path.join(piPackageDir, "node_modules/@earendil-works/pi-ai/dist/index.js")));
const extensionPath = path.join(root, ".pi/extensions/fm-branch-supervision.ts");
const periodicExtensionPath = path.join(root, ".pi/extensions/fm-periodic-stow.ts");
const outcomeScript = path.join(root, "bin/fm-branch-outcome.sh");
const probePath = path.join(home, "retention-probe.ts");
const state = path.join(home, "state");

mkdirSync(state, { recursive: true });
mkdirSync(path.join(home, "config"), { recursive: true });
mkdirSync(path.join(home, "projects/approved"), { recursive: true });
writeFileSync(path.join(state, ".lock"), `${process.pid}\n`);

const writeTask = (task, taskState) => {
  mkdirSync(path.join(home, "data", task), { recursive: true });
  writeFileSync(path.join(state, `${task}.meta`),
    `spawn_gen=g-${task}\nproject=${path.join(home, "projects/approved")}\nwindow=fm-${task}\n`);
  writeFileSync(path.join(state, `${task}.status`), "working: isolated fixture\n");
  writeFileSync(path.join(home, "data", task, "task.json"), `${JSON.stringify({
    schema: "fm-task.v1", id: task, title: task, body: "fixture", state: taskState, kind: "ship",
    repo: "", priority: "", created: "2026-10-04", closed: null, completion: null, hold: null,
    deferred_until: null, blocked_by: [], links: {}, history: [], updated_at: "2026-10-04T00:00:00Z",
    progress: { acceptance: "fixture", current_state: "fixture", remaining_gap: "fixture", next_step: "fixture" },
  })}\n`);
};
writeTask("decision-before", "done");
writeTask("decision-after", "done");

// The fixture driver crosses the same shared extension event bus as the real
// watcher. Production code still owns append, reconciliation, compaction,
// branch admission, reporting, and settlement.
writeFileSync(probePath, `
import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI): void {
  pi.registerTool({
    name: "append_retention_decision",
    label: "Append retention decision",
    description: "Append one exact post-compaction outcome.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
    execute: async () => {
      const seq = execFileSync(process.env.FM_RETENTION_OUTCOME_SCRIPT!, [
        "append", "--task", "decision-after", "--verdict", "captain",
        "--summary", "post-compaction exact decision", "--material-key", "post-compaction-v1",
      ], { env: process.env, encoding: "utf8" }).trim();
      pi.events.emit("firstmate:outcomes-ready", {});
      return { content: [{ type: "text", text: seq }] };
    },
  });
  pi.registerTool({
    name: "dispatch_retention_fixture",
    label: "Dispatch retention fixture",
    description: "Dispatch one isolated supervision wake.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
    execute: async () => {
      writeFileSync(process.env.FM_HOME + "/state/.wake-queue",
        "1\\t1\\tsignal\\tbranch-driver.status\\tsignal: ordinary eligible admission after cold retention\\n");
      const offer = {
        token: "installed-pi-retention", message: "signal: ordinary eligible admission after cold retention",
        projects: [], heartbeat: false, eligible: true, idaResultRows: [],
        eligibleSeqs: ["1"], eligibleTasks: ["branch-driver"], taskBySeq: { "1": "branch-driver" },
        declineReason: "no-listener", accepted: false, settlement: Promise.resolve(),
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

const rows = [];
for (let seq = 1; seq <= 1065; seq += 1) {
  rows.push({
    seq, epoch: seq, task: `padding-${seq}`, wake: "fixture", verdict: "routine",
    summary: `padding-${seq}-${"x".repeat(1400)}`, silent: false,
  });
}
rows[999] = {
  seq: 1000, epoch: 1000, task: "decision-before", wake: "fixture", verdict: "captain",
  summary: "pre-compaction exact decision outside the recent window", silent: false,
};
const initialStore = rows.map((row) => JSON.stringify(row)).join("\n") + "\n";
const initialBytes = Buffer.byteLength(initialStore);
assert.ok(initialBytes > 1024 * 1024, "fixture must exceed the historical 1 MiB stdout guard");
writeFileSync(path.join(state, "branch-outcomes.jsonl"), initialStore);
writeFileSync(path.join(state, ".branch-outcomes-cursor"), "999\n");
writeFileSync(path.join(state, ".branch-outcomes-processed"), "999\n");
// A healthy running owner already has a current bounded index. This prevents
// startup migration from legitimately taking the explicit cold recovery path.
writeFileSync(path.join(state, ".branch-outcome-index-ready"), "1065\n");

let providerCalls = 0;
const originalFetch = globalThis.fetch;
let networkCalls = 0;
globalThis.fetch = async () => {
  networkCalls += 1;
  throw new Error("unexpected network from installed-Pi retention regression");
};
const providerConfig = {
  baseUrl: "http://127.0.0.1/unused", apiKey: "offline-test-only", api: "retention-local-api",
  models: [{
    id: "deterministic", name: "Deterministic retention fixture", reasoning: false,
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
    const alreadyReported = context.messages.some((message) =>
      message.role === "toolResult" && message.toolName === "fm_branch_report");
    queueMicrotask(() => {
      stream.push({ type: "start", partial: output });
      if (all.includes("FIRSTMATE SUPERVISION WAKE:") && !alreadyReported) {
        output.stopReason = "toolUse";
        const toolCall = { type: "toolCall", id: `report-${providerCalls}`, name: "fm_branch_report",
          arguments: { task: "branch-driver", verdict: "routine", summary: "ordinary admission survived cold retention" } };
        output.content.push(toolCall);
        stream.push({ type: "toolcall_start", contentIndex: 0, partial: output });
        stream.push({ type: "toolcall_delta", contentIndex: 0, delta: JSON.stringify(toolCall.arguments), partial: output });
        stream.push({ type: "toolcall_end", contentIndex: 0, toolCall, partial: output });
        stream.push({ type: "done", reason: "toolUse", message: output });
      } else {
        const text = "ISOLATED_RETENTION_FIXTURE_SETTLED";
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
runtime.registerProvider("retention-local", providerConfig);
await runtime.refresh({ providers: ["retention-local"], allowNetwork: false });
const model = runtime.getModel("retention-local", "deterministic");
assert.ok(model, "isolated deterministic provider must be available");
const loader = new sdk.DefaultResourceLoader({
  cwd: root, agentDir: home, settingsManager: settings,
  noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
  additionalExtensionPaths: [periodicExtensionPath, extensionPath, probePath],
  systemPromptOverride: () => "Installed-Pi outcome-retention regression.",
  appendSystemPromptOverride: () => [], agentsFilesOverride: () => ({ agentsFiles: [] }),
});
await loader.reload();
assert.deepEqual(loader.getExtensions().errors, [], "real loader must load the tracked extension without errors");

const mainSessionDir = path.join(state, "main-session");
mkdirSync(mainSessionDir, { recursive: true });
const sessionManager = sdk.SessionManager.create(root, mainSessionDir);
const { session } = await sdk.createAgentSession({
  cwd: root, agentDir: home, modelRuntime: runtime, model, thinkingLevel: "off",
  resourceLoader: loader, settingsManager: settings, sessionManager,
});
const extensionErrors = [];
const waitFor = async (predicate, label) => {
  for (let attempt = 0; attempt < 600; attempt += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timed out waiting for ${label}`);
};
const visibleSeqs = () => sessionManager.getEntries()
  .filter((entry) => entry.type === "custom" && entry.customType === "fm-branch-visible-outcome")
  .map((entry) => entry.data?.seq);
const processRequests = () => session.messages
  .filter((message) => message.role === "custom" && message.customType === "fm-branch-process");
const runOutcome = (args, maxBuffer = 8 * 1024 * 1024) => execFileSync(outcomeScript, args, {
  env: { ...process.env, FM_HOME: home }, encoding: "utf8", maxBuffer,
});

try {
  await session.bindExtensions({ mode: "print", onError: (error) => extensionErrors.push(error) });
  await waitFor(() => visibleSeqs().includes(1000), "pre-compaction visible outcome");
  await waitFor(() => processRequests().at(-1)?.content.includes('sequences="1000"'),
    "pre-compaction exact processing request");

  const outcomes = session.getToolDefinition("fm_branch_outcomes");
  const processed = session.getToolDefinition("fm_branch_processed");
  assert.ok(outcomes && processed, "real AgentSession exposes production outcome tools");
  const beforeLoad = await outcomes.execute("retention-load-before", { sequences: "1000" });
  assert.equal(beforeLoad.isError, undefined, JSON.stringify(beforeLoad));
  assert.match(beforeLoad.content[0].text, /pre-compaction exact decision/);
  const beforeAck = await processed.execute("retention-ack-before", { sequences: "1000" });
  assert.equal(beforeAck.isError, undefined, JSON.stringify(beforeAck));

  const firstCold = readFileSync(path.join(state, "branch-outcomes-cold.jsonl"), "utf8");
  const firstActive = readFileSync(path.join(state, "branch-outcomes.jsonl"), "utf8")
    .trim().split("\n").map(JSON.parse);
  assert.ok(Buffer.byteLength(firstCold) > 1024 * 1024,
    "the archived processed prefix must itself exceed the historical stdout guard");
  assert.equal(firstActive[0].seq, 937, "frontier-inclusive retention must keep seq 937 through 1000");
  assert.equal(firstActive.at(-1).seq, 1065, "unread tail must remain active after compaction");
  assert.equal(runOutcome(["list", "--seq", "1"]).trim().split("\n").map(JSON.parse)[0].seq, 1,
    "explicit cold lookup must preserve the original stable sequence");

  const appendDecision = session.getToolDefinition("append_retention_decision");
  assert.ok(appendDecision, "fixture append tool must be registered through the real extension runtime");
  const appendedDecision = await appendDecision.execute("retention-append-after", {});
  assert.equal(appendedDecision.isError, undefined, JSON.stringify(appendedDecision));
  assert.equal(appendedDecision.content[0].text, "1066");
  await waitFor(() => visibleSeqs().includes(1066), "post-compaction visible outcome");
  await waitFor(() => processRequests().at(-1)?.content.includes('sequences="1066"'),
    "post-compaction exact processing request");
  const afterLoad = await outcomes.execute("retention-load-after", { sequences: "1066" });
  assert.equal(afterLoad.isError, undefined, JSON.stringify(afterLoad));
  assert.match(afterLoad.content[0].text, /post-compaction exact decision/);
  const afterAck = await processed.execute("retention-ack-after", { sequences: "1066" });
  assert.equal(afterAck.isError, undefined, JSON.stringify(afterAck));

  const retainedActive = readFileSync(path.join(state, "branch-outcomes.jsonl"), "utf8")
    .trim().split("\n").map(JSON.parse);
  assert.equal(retainedActive.length, 64, "active store must retain exactly 64 processed rows at the frontier");
  assert.equal(retainedActive[0].seq, 1003);
  assert.equal(retainedActive.at(-1).seq, 1066);
  assert.equal(readFileSync(path.join(state, ".branch-outcomes-base"), "utf8").trim(),
    "fm-branch-outcomes-base-v1\t1003");
  assert.equal(readFileSync(path.join(state, ".branch-outcomes-processed"), "utf8").trim(), "1066");

  // A malformed >1 MiB cold store cannot affect the ordinary read, append,
  // delivery, or branch-admission path. Explicit history readers still fail
  // closed (covered by the owner-level shell tests).
  const validCold = readFileSync(path.join(state, "branch-outcomes-cold.jsonl"), "utf8");
  writeFileSync(path.join(state, "branch-outcomes-cold.jsonl"), `not-json\n${validCold}`);
  writeTask("branch-driver", "in_flight");
  const dispatch = session.getToolDefinition("dispatch_retention_fixture");
  assert.ok(dispatch, "fixture dispatch tool must be registered through the real extension runtime");
  const admitted = await dispatch.execute("retention-dispatch", {});
  assert.equal(admitted.isError, undefined, JSON.stringify(admitted));
  assert.deepEqual(JSON.parse(admitted.content[0].text), { accepted: true, settled: true });
  writeFileSync(path.join(state, "branch-outcomes-cold.jsonl"), validCold);

  const finalActive = readFileSync(path.join(state, "branch-outcomes.jsonl"), "utf8")
    .trim().split("\n").map(JSON.parse);
  const delivered = finalActive.at(-1);
  assert.equal(delivered.seq, 1067);
  assert.equal(delivered.task, "branch-driver");
  assert.equal(delivered.summary, "ordinary admission survived cold retention");
  assert.equal(finalActive.length, 65, "new pending work is retained in addition to the processed 64-row window");
  assert.ok(providerCalls >= 2, "real branch AgentSession completed a tool call and settled");
  assert.equal(networkCalls, 0, "the deterministic provider made no external request");
  assert.deepEqual(extensionErrors, [], JSON.stringify(extensionErrors));
  console.log(JSON.stringify({
    piVersion: JSON.parse(readFileSync(path.join(piPackageDir, "package.json"), "utf8")).version,
    initialBytes, coldBytes: Buffer.byteLength(validCold), activeRows: finalActive.length,
    retainedProcessedRows: 64, acknowledgedSequences: [1000, 1066], admittedSequence: 1067,
    providerCalls, networkCalls, runtime: "installed AgentSession + DefaultResourceLoader",
  }));
} finally {
  await session.extensionRunner.emit({ type: "session_shutdown", reason: "quit" });
  session.dispose();
  globalThis.fetch = originalFetch;
}
