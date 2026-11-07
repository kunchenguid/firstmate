import { existsSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";
import assert from "node:assert/strict";

assert.equal(process.env.FM_GATE_REFUSE_BYPASS, undefined, "fixture bypass reached the SDK process");
assert.equal(process.env.AI_GATEWAY_API_KEY, undefined, "ambient credential reached the SDK process");

const sdk = await import(pathToFileURL(process.env.PI_PACKAGE_DIR + "/dist/index.js").href);
const { DefaultResourceLoader, ModelRegistry, ModelRuntime, SessionManager, SettingsManager, createAgentSession } = sdk;
const cwd = process.env.STREAM_CWD, agentDir = process.env.PI_CODING_AGENT_DIR;
const piVersion = process.env.PI_VERSION || "installed";
const state = process.env.STREAM_STATE, enabled = process.env.STREAM_ENABLED === "300";
const marker = state + "/stream.model-stream";
const progress = state + "/stream.model-progress";
const record = () => existsSync(marker) ? readFileSync(marker, "utf8") : "";
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const until = async (predicate, description) => {
  const deadline = Date.now() + 10000;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error("Pi " + piVersion + ": timeout waiting for " + description);
    await delay(10);
  }
};
let controller, calls = 0, providers = 0, toolEntered = false, releaseTool;
let nextController;
const toolHold = new Promise((resolve) => { releaseTool = resolve; });
const encoder = new TextEncoder();
const chunk = (delta, finish = null) => "data: " + JSON.stringify({
  id: "synthetic", object: "chat.completion.chunk", created: 1, model: "stream",
  choices: [{ index: 0, delta, finish_reason: finish }],
}) + "\n\n";
const send = (target, delta, finish) => target.enqueue(encoder.encode(chunk(delta, finish)));
const finish = (target, reason = "stop") => {
  send(target, {}, reason);
  target.enqueue(encoder.encode("data: [DONE]\n\n"));
  target.close();
};
globalThis.fetch = async (input) => {
  const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
  assert.ok(url.startsWith("https://fm-worker-stream.invalid/"), "unexpected network request: " + url);
  calls += 1;
  if (calls === 1) assert.match(readFileSync(state + "/stream.busy-state", "utf8"), /state=busy source=pi-ext/);
  return new Response(new ReadableStream({
    start(target) {
      if (!enabled || calls > 2) {
        assert.equal(record(), "", "disabled/background request opened foreground evidence");
        send(target, {role: "assistant", content: "OK"});
        finish(target);
      } else if (calls === 1) {
        controller = target;
        send(target, {role: "assistant", content: "hello"});
      } else {
        nextController = target;
        send(target, {role: "assistant", content: "OK"});
      }
    },
  }), {status: 200, headers: {"content-type": "text/event-stream"}});
};
const settings = SettingsManager.create(cwd, agentDir);
settings.setCacheWarmingMode("off");
const loader = new DefaultResourceLoader({
  cwd, agentDir, settingsManager: settings,
  additionalExtensionPaths: [process.env.STREAM_EXTENSION],
  extensionFactories: [(pi) => {
    pi.on("before_provider_request", () => { providers += 1; });
  }],
  noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
});
await loader.reload();
const runtime = await ModelRuntime.create({authPath: agentDir + "/auth.json", modelsPath: agentDir + "/models.json"});
const registry = new ModelRegistry(runtime);
await registry.refresh();
const model = registry.find("fm-worker-stream", "stream");
assert.ok(model, "real Pi registry failed to resolve synthetic model");
const { session } = await createAgentSession({
  cwd, settingsManager: settings, resourceLoader: loader, modelRuntime: runtime, model,
  sessionManager: SessionManager.inMemory(), noTools: "builtin",
  customTools: [{
    name: "stream_probe_tool", label: "stream probe", description: "Isolated harmless phase probe",
    parameters: {type: "object", properties: {}},
    execute: async () => {
      assert.equal(record(), "", "real tool execution retained stream marker");
      toolEntered = true;
      await toolHold;
      return {content: [{type: "text", text: "OK"}]};
    },
  }],
});
let prompt;
try {
  prompt = session.prompt("Exercise the synthetic local stream.");
  if (enabled) {
    if (process.env.STREAM_FAULT_DIR) {
      const pidsFile = process.env.STREAM_FAULT_DIR + "/pids";
      await until(() => controller && existsSync(pidsFile), "stalled writer injection");
      await delay(1100);
      send(controller, {content: " recovered"});
      await until(() => existsSync(progress), "progress after instrumentation deadline");
      const pids = readFileSync(pidsFile, "utf8").trim().split("\n").map(Number);
      assert.equal(pids.length, 2, "writer descendant injection missing");
      for (const pid of pids) {
        let alive = false;
        try {
          process.kill(pid, 0);
          const status = spawnSync("ps", ["-p", String(pid), "-o", "stat="], {encoding: "utf8", timeout: 1000});
          if (status.status === 0) alive = !status.stdout.trim().startsWith("Z");
          else { process.kill(pid, 0); alive = true; }
        } catch (error) {
          if (!["ESRCH", "ENOENT"].includes(error.code)) throw error;
        }
        assert.equal(alive, false, "instrumentation deadline left owned descendant alive: " + pid);
      }
      console.log("ok - real Pi " + piVersion + " instrumentation deadline terminated writer and output-holding descendant");
    }
    await until(() => controller && existsSync(progress), "foreground progress");
    const first = record();
    assert.ok(first, "accepted real stream has no marker");
    await delay(1100);
    send(controller, {content: ""});
    await delay(50);
    assert.equal(record(), first, "empty provider event refreshed model progress");
    send(controller, {content: " next"});
    await until(() => record() !== first, "substantive real delta");
    const current = record();
    await delay(1100);
    assert.equal(record(), current, "held stream fabricated timer progress");
    send(controller, {tool_calls: [{index: 0, id: "probe-call", type: "function",
      function: {name: "stream_probe_tool", arguments: "{}"}}]});
    finish(controller, "tool_calls");
    await until(() => toolEntered, "real tool phase");
    assert.equal(record(), "", "silent tool phase retained model evidence");
    releaseTool();
    await until(() => nextController && record(), "next real request");
    assert.notEqual(record().match(/request=([0-9]+)/)[1], current.match(/request=([0-9]+)/)[1],
      "next request reused its predecessor identity");
    finish(nextController);
  }
  await prompt;
  assert.equal(record(), "", "settled real session retained stream evidence");
  assert.match(readFileSync(state + "/stream.busy-state", "utf8"), /state=idle source=pi-ext/);
  assert.equal(existsSync(state + "/stream.progress"), false, "normal stream changed native progress");
  if (!enabled) assert.equal(existsSync(progress), false, "default-off session wrote model progress");
  assert.ok(providers > 0, "real provider callback was never exercised");
  const before = providers;
  // Exercise the real provider outside the foreground agent loop with the
  // same public extension callback used for background provider requests.
  await runtime.streamSimple(model, {
    systemPrompt: "", messages: [{role: "user", content: [{type: "text", text: "background"}], timestamp: Date.now()}],
  }, {
    onPayload: (payload) => session.extensionRunner.emitBeforeProviderRequest(payload),
  }).result();
  assert.ok(providers > before, "background provider callback did not execute");
  assert.equal(record(), "", "background provider callback reopened foreground evidence");
  console.log("ok - real Pi " + piVersion + " " + (enabled ? "stream, tool, completion, and background request phases" : "default-off worker"));
} finally {
  releaseTool();
  if (session.isStreaming) await session.abort();
  await prompt?.catch(() => {});
  session.dispose();
}
