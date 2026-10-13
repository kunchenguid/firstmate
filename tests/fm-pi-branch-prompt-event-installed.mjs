// Installed-Pi regression for the supervision branch's prompt-event boundary.
//
// This loads the tracked extension through a real DefaultResourceLoader and
// drives AgentSession.sendCustomMessage plus AgentSession.prompt against a
// deterministic in-process provider. No provider request leaves the process.
import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const [root, home, piPackageDir] = process.argv.slice(2);
assert.ok(root && home && piPackageDir,
  "usage: node fm-pi-branch-prompt-event-installed.mjs ROOT HOME PI_PACKAGE_DIR");
assert.equal(process.env.FM_HOME, home, "the installed-Pi fixture requires an explicit isolated FM_HOME");

const sdk = await import(pathToFileURL(path.join(piPackageDir, "dist/index.js")));
const piAi = await import(pathToFileURL(path.join(piPackageDir, "node_modules/@earendil-works/pi-ai/dist/index.js")));
const extensionPath = path.join(root, ".pi/extensions/fm-branch-supervision.ts");

mkdirSync(path.join(home, "state/main-session"), { recursive: true });
mkdirSync(path.join(home, "config"), { recursive: true });
writeFileSync(path.join(home, "state/.lock"), `${process.pid}\n`);

const observed = [];
const observer = {
  name: "prompt-event-observer",
  factory(pi) {
    pi.on("before_agent_start", (event) => {
      observed.push({
        messageType: event.messageType,
        prompt: event.messageType === "user" ? event.prompt : undefined,
        customType: event.messageType === "custom" ? event.message.customType : undefined,
      });
    });
  },
};

let providerCalls = 0;
const providerConfig = {
  baseUrl: "http://127.0.0.1/unused",
  apiKey: "offline-test-only",
  api: "prompt-event-local-api",
  models: [{
    id: "deterministic",
    name: "Deterministic prompt-event fixture",
    reasoning: false,
    input: ["text"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 32768,
    maxTokens: 256,
  }],
  streamSimple(model) {
    providerCalls += 1;
    const stream = piAi.createAssistantMessageEventStream();
    const output = {
      role: "assistant",
      content: [],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: {
        input: 0,
        output: 0,
        cacheRead: 0,
        cacheWrite: 0,
        totalTokens: 0,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
      },
      stopReason: "stop",
      timestamp: Date.now(),
    };
    const text = `ISOLATED_PROMPT_EVENT_${providerCalls}`;
    queueMicrotask(() => {
      stream.push({ type: "start", partial: output });
      output.content.push({ type: "text", text });
      stream.push({ type: "text_start", contentIndex: 0, partial: output });
      stream.push({ type: "text_delta", contentIndex: 0, delta: text, partial: output });
      stream.push({ type: "text_end", contentIndex: 0, content: text, partial: output });
      stream.push({ type: "done", reason: "stop", message: output });
      stream.end();
    });
    return stream;
  },
};

const settings = sdk.SettingsManager.inMemory({
  compaction: { enabled: false },
  retry: { enabled: false, provider: { maxRetries: 0 } },
  cacheWarming: "off",
  packages: [],
  extensions: [],
  skills: [],
  prompts: [],
  themes: [],
});
const runtime = await sdk.ModelRuntime.create();
runtime.registerProvider("prompt-event-local", providerConfig);
await runtime.refresh({ providers: ["prompt-event-local"], allowNetwork: false });
const model = runtime.getModel("prompt-event-local", "deterministic");
assert.ok(model, "isolated deterministic provider must be available");
const loader = new sdk.DefaultResourceLoader({
  cwd: root,
  agentDir: home,
  settingsManager: settings,
  noExtensions: true,
  noSkills: true,
  noPromptTemplates: true,
  noThemes: true,
  noContextFiles: true,
  additionalExtensionPaths: [extensionPath],
  extensionFactories: [observer],
  systemPromptOverride: () => "Installed-Pi prompt-event regression.",
  appendSystemPromptOverride: () => [],
  agentsFilesOverride: () => ({ agentsFiles: [] }),
});
await loader.reload();
assert.deepEqual(loader.getExtensions().errors, [], "real loader must load the tracked extension without errors");

const sessionManager = sdk.SessionManager.create(root, path.join(home, "state/main-session"));
const { session } = await sdk.createAgentSession({
  cwd: root,
  agentDir: home,
  modelRuntime: runtime,
  model,
  thinkingLevel: "off",
  resourceLoader: loader,
  settingsManager: settings,
  sessionManager,
});
const extensionErrors = [];
const originalFetch = globalThis.fetch;
let networkCalls = 0;
globalThis.fetch = async () => {
  networkCalls += 1;
  throw new Error("unexpected network from installed-Pi prompt-event regression");
};

try {
  await session.bindExtensions({ mode: "print", onError: (error) => extensionErrors.push(error) });
  await session.sendCustomMessage({
    customType: "fm-branch-process",
    content: "automatic result notification",
    display: true,
  }, { triggerTurn: true });
  await session.prompt("ordinary user prompt");

  assert.deepEqual(observed, [
    { messageType: "custom", prompt: undefined, customType: "fm-branch-process" },
    { messageType: "user", prompt: "ordinary user prompt", customType: undefined },
  ], "installed Pi must emit distinct custom and user before_agent_start payloads");
  const promptErrors = extensionErrors.filter((error) => error.event === "before_agent_start");
  assert.deepEqual(promptErrors, [], JSON.stringify(promptErrors));
  const userEntries = sessionManager.getEntries().filter((entry) =>
    entry.type === "message" && entry.message.role === "user" &&
    entry.message.content?.some?.((item) => item.type === "text" && item.text === "ordinary user prompt"));
  assert.equal(userEntries.length, 1, "ordinary user prompt must persist exactly once");
  assert.equal(providerCalls, 2, "custom and user inputs must each complete one real AgentSession run");
  assert.equal(networkCalls, 0, "the deterministic provider made no external request");
  console.log(JSON.stringify({
    piVersion: JSON.parse(readFileSync(path.join(piPackageDir, "package.json"), "utf8")).version,
    observed,
    providerCalls,
    networkCalls,
    runtime: "installed AgentSession + DefaultResourceLoader",
  }));
} finally {
  await session.extensionRunner.emit({ type: "session_shutdown", reason: "quit" });
  session.dispose();
  globalThis.fetch = originalFetch;
}
