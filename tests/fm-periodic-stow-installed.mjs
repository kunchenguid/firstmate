// Installed-Pi lifecycle guard for the idle reminder coordinator.
//
// Loads the tracked extension through Pi's real resource loader and drives its
// hidden follow-up through AgentSession with an offline deterministic provider.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, readFileSync, utimesSync, writeFileSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const [root, home, piPackageDir] = process.argv.slice(2);
assert.ok(root && home && piPackageDir,
  "usage: node fm-periodic-stow-installed.mjs ROOT HOME PI_PACKAGE_DIR");
assert.equal(process.env.FM_HOME, home, "installed-Pi reminder guard requires an isolated FM_HOME");

const sdk = await import(pathToFileURL(path.join(piPackageDir, "dist/index.js")));
const piAi = await import(pathToFileURL(path.join(piPackageDir,
  "node_modules/@earendil-works/pi-ai/dist/index.js")));
const extensionPath = path.join(root, ".pi/extensions/fm-periodic-stow.ts");
const sessionDir = path.join(home, "state/main-session");
mkdirSync(sessionDir, { recursive: true });
mkdirSync(path.join(home, "config"), { recursive: true });
writeFileSync(path.join(home, "state/.lock"), `${process.pid}\n`);
const lock = spawnSync(path.join(root, "bin/fm-session-lock-status.sh"), [], {
  encoding: "utf8", env: { ...process.env, FM_HOME: home, FM_ROOT_OVERRIDE: root },
});
assert.equal(`${lock.status}:${lock.stdout.trim()}`, "0:owned", `fixture lock was not owned: ${lock.stderr}`);
const configFile = path.join(home, "config/idle-reminder.json");
writeFileSync(configFile, JSON.stringify({ version: 1, enabled: true, interval_seconds: 1800 }));
const old = new Date(Date.now() - 1_801_000);
utimesSync(configFile, old, old);

let providerCalls = 0;
let networkCalls = 0;
const observed = [];
const observer = {
  name: "idle-reminder-observer",
  factory(pi) {
    pi.events.on("firstmate:heartbeat-tick", () => observed.push({ tick: true }));
    pi.on("session_start", (_event, ctx) => {
      observed.push({ mode: ctx.mode, hasUI: ctx.hasUI, idle: ctx.isIdle(), pending: ctx.hasPendingMessages(),
        editor: ctx.ui.getEditorText(), leaf: ctx.sessionManager.getLeafId(), file: ctx.sessionManager.getSessionFile(),
        task: process.env.FM_TASK_ID, operation: process.env.FIRSTMATE_OP, actor: process.env.FM_SUPERVISION_ACTOR });
    });
  },
};
const providerConfig = {
  baseUrl: "http://127.0.0.1/unused",
  apiKey: "offline-test-only",
  api: "idle-reminder-local-api",
  models: [{
    id: "deterministic",
    name: "Deterministic idle reminder fixture",
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
      role: "assistant", content: [], api: model.api, provider: model.provider, model: model.id,
      usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
      stopReason: "stop", timestamp: Date.now(),
    };
    const text = "captain，尚有未完成事项，请按下一步继续。";
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
  cacheWarming: "off", packages: [], extensions: [], skills: [], prompts: [], themes: [],
});
const skillDiscovery = new sdk.DefaultResourceLoader({
  cwd: root, agentDir: home, settingsManager: settings, noExtensions: true,
  noPromptTemplates: true, noThemes: true, noContextFiles: true,
  additionalSkillPaths: [path.join(root, ".agents/skills")],
});
await skillDiscovery.reload();
assert.equal(skillDiscovery.getSkills().skills.some((skill) => skill.name === "stow"), false,
  "installed Pi must not expose the internal stow contract as a skill command");
const runtime = await sdk.ModelRuntime.create();
runtime.registerProvider("idle-reminder-local", providerConfig);
await runtime.refresh({ providers: ["idle-reminder-local"], allowNetwork: false });
const model = runtime.getModel("idle-reminder-local", "deterministic");
assert.ok(model, "deterministic provider must be available");

async function loader() {
  const value = new sdk.DefaultResourceLoader({
    cwd: root, agentDir: home, settingsManager: settings, noExtensions: true, noSkills: true,
    noPromptTemplates: true, noThemes: true, noContextFiles: true,
    additionalExtensionPaths: [extensionPath],
    extensionFactories: [observer],
    systemPromptOverride: () => "Installed-Pi idle reminder regression.",
    appendSystemPromptOverride: () => [], agentsFilesOverride: () => ({ agentsFiles: [] }),
  });
  await value.reload();
  assert.deepEqual(value.getExtensions().errors, [], "real loader must load the reminder extension");
  return value;
}

async function waitFor(predicate, label) {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.fail(`timed out waiting for ${label}`);
}

const originalFetch = globalThis.fetch;
globalThis.fetch = async () => {
  networkCalls += 1;
  throw new Error("unexpected network from installed-Pi idle reminder regression");
};
const uiContext = new Proxy({
  getEditorText: () => "",
  notify: (message, kind) => observed.push({ notify: message, kind }),
}, {
  get(target, property) {
    if (property in target) return target[property];
    return () => undefined;
  },
});

let manager = sdk.SessionManager.create(root, sessionDir);
manager.appendCustomEntry("installed-pi-reminder-seed", { version: 1 });
let created = await sdk.createAgentSession({
  cwd: root, agentDir: home, modelRuntime: runtime, model, thinkingLevel: "off",
  resourceLoader: await loader(), settingsManager: settings, sessionManager: manager,
});
try {
  await created.session.bindExtensions({ mode: "tui", uiContext,
    onError: (error) => { throw error.error || error; } });
  assert.deepEqual({ mode: observed[0]?.mode, hasUI: observed[0]?.hasUI, idle: observed[0]?.idle,
    pending: observed[0]?.pending, editor: observed[0]?.editor },
  { mode: "tui", hasUI: true, idle: true, pending: false, editor: "" },
  "installed Pi must expose the structural idle TUI boundary used by the reminder");
  await created.session.prompt("Prime one real Pi lifecycle boundary before the idle reminder.");
  try {
    await waitFor(() => manager.getEntries().some((entry) =>
      entry.type === "custom" && entry.customType === "fm-idle-reminder-delivered"), "delivery receipt");
  } catch (error) {
    throw new Error(`${error.message}; calls=${providerCalls}; observed=${JSON.stringify(observed)}; entries=${JSON.stringify(manager.getEntries())}`);
  }
  assert.equal(providerCalls, 2, "one priming turn and one due reminder must each complete one AgentSession run");
  assert.equal(networkCalls, 0, "deterministic provider must remain offline");
  await created.session.extensionRunner.emit({ type: "session_shutdown", reason: "reload" });
  created.session.dispose();

  const sessionFile = manager.getSessionFile();
  manager = sdk.SessionManager.open(sessionFile, sessionDir, root);
  created = await sdk.createAgentSession({
    cwd: root, agentDir: home, modelRuntime: runtime, model, thinkingLevel: "off",
    resourceLoader: await loader(), settingsManager: settings, sessionManager: manager,
  });
  await created.session.bindExtensions({ mode: "tui", uiContext,
    onError: (error) => { throw error.error || error; } });
  await new Promise((resolve) => setTimeout(resolve, 200));
  assert.equal(providerCalls, 2, "reload must restore the successful cadence without duplicate delivery");
  console.log(JSON.stringify({
    piVersion: JSON.parse(readFileSync(path.join(piPackageDir, "package.json"), "utf8")).version,
    providerCalls, networkCalls, runtime: "installed AgentSession + DefaultResourceLoader",
  }));
} finally {
  await created.session.extensionRunner.emit({ type: "session_shutdown", reason: "quit" });
  created.session.dispose();
  globalThis.fetch = originalFetch;
}
