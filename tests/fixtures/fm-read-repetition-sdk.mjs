// Real Pi SDK/provider parsing with synthetic responses and fake Bash operations.
// Every fetch is intercepted. Never uses a credential or an inference endpoint.
import assert from "node:assert/strict";
import { cpSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const source = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const [sdkDir, lab] = process.argv.slice(2);
assert.ok(sdkDir && lab, "usage: node fm-read-repetition-sdk.mjs <Pi package directory> <private scratch directory>");
const sdk = await import(pathToFileURL(join(sdkDir, "dist/index.js")));
const version = JSON.parse(readFileSync(join(sdkDir, "package.json"))).version;
const originalFetch = globalThis.fetch;
const results = [];

try {
  for (const mode of ["alternating-85", "alternating-65", "ssh", "cut", "grouped", "multiline", "continued-group", "unknown-group", "mutating-group", "same-batch", "truncated", "truncated-compact", "changing", "failed", "foreign-owner", "default-off"]) {
    const repo = join(lab, mode, "repo"), agentDir = join(lab, mode, "agent");
    const extensions = join(repo, ".pi/extensions");
    mkdirSync(join(extensions, "lib"), { recursive: true });
    mkdirSync(join(repo, "state"), { recursive: true });
    mkdirSync(join(repo, "config"), { recursive: true });
    mkdirSync(agentDir, { recursive: true });
    for (const file of ["fm-primary-read-repetition.ts", "lib/fm-primary-read-repetition-policy.ts"])
      cpSync(join(source, ".pi/extensions", file), join(extensions, file));
    if (mode !== "default-off") writeFileSync(join(repo, "config/read-repetition.json"), '{"enabled":true}');
    writeFileSync(join(repo, "state/.lock"), `${process.pid}\n`);
    writeFileSync(join(repo, "state/.pi-turnend-extension-loaded"), `sha256:synthetic\n${process.pid}\n`);
    for (const key of ["FM_TASK_ID", "FM_TASK_INBOX", "FM_SUPERVISION_ACTOR"]) delete process.env[key];
    Object.assign(process.env, { FM_HOME: repo, FM_ROOT_OVERRIDE: repo, FM_CONFIG_OVERRIDE: join(repo, "config"), FM_STATE_OVERRIDE: join(repo, "state"), PI_CODING_AGENT_DIR: agentDir });
    if (mode === "foreign-owner") process.env.FM_TASK_ID = "synthetic-worker";

    const provider = "fm-read-replay";
    writeFileSync(join(agentDir, "models.json"), JSON.stringify({ providers: {
      [provider]: { baseUrl: "https://read-replay.invalid/v1", api: "openai-completions", apiKey: "synthetic-placeholder",
        models: [{ id: "scripted", name: "Synthetic replay", contextWindow: mode === "truncated" ? 1048576 : 32768, maxTokens: 4096 }] },
    } }));
    const ssh = `ssh -o BatchMode=yes -o ConnectTimeout=10 fixture-host 'cd /fixture && echo summary && git diff --stat abcdef0..HEAD | sed -n "1,20p"' 2>&1 | head -40`;
    const single = mode === "ssh" ? ssh : mode === "cut" ? "echo excerpt; sed -n '17,18p' fixture | cut -c1-500"
      : mode === "grouped" ? "(cd /fixture && echo excerpt; sed -n '17,18p' fixture | nl -ba)"
      : mode === "multiline" ? "(cd /fixture\necho counts\nsed -n '1,20p' fixture | wc -l\nsed -n '1,20p' fixture | head -c 500 | tail -c 80 | od -An -tx1c\n)"
      : mode === "continued-group" ? "(cd /fixture && \\\necho excerpt; sed -n '1,20p' fixture | \\\nnl -ba)"
      : mode === "unknown-group" ? "(cat fixture | unknown)"
      : mode === "mutating-group" ? "(cat fixture; touch changed)" : "cat fixture";
    const batches = mode.startsWith("alternating-")
      ? Array.from({ length: Number(mode.split("-")[1]) }, () => ["cat fixture-a", "cat fixture-b"])
      : Array.from({ length: 6 }, () => Array(mode === "same-batch" ? 4 : 1).fill(single));
    let requests = 0, executions = 0, resetting = false, resetRequests = 0;
    const trace = [];
    const chunk = (delta, finish = null) => `data: ${JSON.stringify({
      id: `replay-${requests}`, object: "chat.completion.chunk", created: 1, model: "scripted",
      choices: [{ index: 0, delta, finish_reason: finish }],
    })}\n\n`;
    globalThis.fetch = async (input) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
      assert.ok(url.startsWith("https://read-replay.invalid/"), "Unexpected outbound request refused");
      requests++; trace.push({ event: "fetch" });
      assert.ok(requests <= 10, "Replay exceeded its bounded request budget");
      const commands = resetting ? (++resetRequests === 1 ? [batches[0][0]] : undefined) : batches[requests - 1];
      const delta = commands ? { role: "assistant", tool_calls: commands.map((command, i) => ({
        index: i, id: `unique-${requests}-${i}`, type: "function", function: { name: "bash", arguments: JSON.stringify({ command }) },
      })) } : { role: "assistant", content: "Replay complete." };
      return new Response(chunk(delta) + chunk({}, commands ? "tool_calls" : "stop") + "data: [DONE]\n\n", {
        headers: { "content-type": "text/event-stream" },
      });
    };
    const settings = sdk.SettingsManager.create(repo, agentDir);
    const factory = (await import(pathToFileURL(join(extensions, "fm-primary-read-repetition.ts")))).default;
    const makeLoader = async () => {
      const loader = new sdk.DefaultResourceLoader({
        cwd: repo, agentDir, settingsManager: settings,
        noExtensions: true, noSkills: true, noContextFiles: true, noThemes: true, noPromptTemplates: true,
        extensionFactories: [{ name: "synthetic-read-guard", factory }],
      });
      await loader.reload();
      return loader;
    };
    const runtime = await sdk.ModelRuntime.create({ authPath: join(agentDir, "auth.json"), modelsPath: join(agentDir, "models.json") });
    const registry = new sdk.ModelRegistry(runtime);
    await registry.refresh();
    const encoded = `--${repo.replace(/^[/\\]/, "").replace(/[/\\:]/g, "-")}--`;
    const manager = sdk.SessionManager.create(repo, join(agentDir, "sessions", encoded));
    const bash = sdk.createBashToolDefinition(repo, { operations: { exec: async (_command, _cwd, options) => {
      executions++;
      options.onData(Buffer.from(mode.startsWith("truncated") ? "synthetic unchanged read\n".repeat(5000) : mode === "changing" ? `synthetic changed ${executions}\n` : "synthetic unchanged read\n"));
      return { exitCode: mode === "failed" ? 1 : 0 };
    } } });
    const create = async (sessionManager) => (await sdk.createAgentSession({
      cwd: repo, agentDir, sessionManager, settingsManager: settings, resourceLoader: await makeLoader(),
      modelRuntime: runtime, model: registry.find(provider, "scripted"), tools: ["bash"], customTools: [bash],
    })).session;
    const errors = [];
    const session = await create(manager);
    try {
      await session.bindExtensions({ onError: (event) => errors.push(`${event.event}: ${event.error}`) });
      session.subscribe((event) => trace.push({ event: event.type, customType: event.message?.customType }));
      await session.prompt("Run the synthetic read replay.");
      assert.deepEqual(errors, [], `${mode}: extension errors`);
      const entries = manager.getBranch();
      const notices = entries.filter((entry) => entry.type === "custom_message" && entry.customType === "fm-read-repetition-stopped");
      const allowed = ["changing", "failed", "foreign-owner", "default-off", "unknown-group", "mutating-group"].includes(mode);
      assert.equal(notices.length, allowed ? 0 : 1, `${mode}: durable notice count`);
      assert.equal(executions, mode.startsWith("alternating-") ? 6 : allowed ? 6 : 3, `${mode}: executed operations`);
      assert.equal(requests, allowed ? 7 : mode === "truncated-compact" ? 6 : 4, `${mode}: bounded provider turns`);
      const stoppedIndex = trace.findIndex((e) => e.customType === "fm-read-repetition-stopped");
      if (stoppedIndex >= 0) assert.equal(trace.slice(stoppedIndex).filter((e) => e.event === "fetch").length, 0, `${mode}: fetch after stop`);
      assert.equal(session.model.provider, provider);
      assert.equal(session.model.id, "scripted");
      if (["foreign-owner", "default-off"].includes(mode)) {
        assert.equal(entries.filter((e) => e.type === "custom" && e.customType?.startsWith("fm-read-repetition-")).length, 0);
      } else {
        assert.ok(entries.some((e) => e.customType === "fm-read-repetition-activation-v1"), "proven-owner activation receipt");
      }
      if (!allowed) {
        assert.equal(notices[0].display, true);
        assert.match(notices[0].content, /next call was blocked before execution/);
        assert.ok(trace.some((e) => e.event === "agent_end"));
      }
      results.push({ mode, requests, executions, notices: notices.length });
      if (mode === "ssh") {
        const stoppedRequests = requests;
        await session.prompt("\u2063FIRSTMATE_OP: v1 watcher: synthetic wake", { source: "rpc" });
        await session.sendCustomMessage({ customType: "synthetic-operational-trigger", content: "Test trigger", display: false }, { triggerTurn: true });
        assert.equal(requests, stoppedRequests, "operational input cannot restart inference");
        session.dispose();
        const restored = await create(sdk.SessionManager.open(manager.getSessionFile(), manager.getSessionDir()));
        try {
          await restored.bindExtensions({ onError: (event) => errors.push(`${event.event}: ${event.error}`) });
          await restored.prompt("Unmarked automatic injection", { source: "extension" });
          assert.equal(requests, stoppedRequests, "reload retains latch");
          resetting = true;
          await restored.prompt("Deliberately read once for a new user request.", { source: "rpc" });
          assert.equal(requests, stoppedRequests + 2);
          assert.equal(executions, 4);
          assert.deepEqual(errors, []);
          Object.assign(results.at(-1), { operationalAndResumeLatch: true, realUserReset: true });
        } finally { restored.dispose(); }
      }
    } finally { session.dispose(); }
  }
} finally { globalThis.fetch = originalFetch; }
console.log(JSON.stringify({ sdk: version, casesPassed: results.length, results }));
