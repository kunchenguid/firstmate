// Installed SDK/plugin test: initialization and handler behavior without model I/O.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
const [root, tmp] = process.argv.slice(2);
const { sdkEntry, initializeNetwork } = await import(pathToFileURL(path.join(root, 'bin/fm-short-agent.mjs')));
const { shortPluginLoader } = await import(pathToFileURL(path.join(root, 'bin/fm-short-plugin.mjs')));
await initializeNetwork();
const sdk = await import(pathToFileURL(sdkEntry()));
const runtime = await sdk.ModelRuntime.create();
const model = (await runtime.getAvailable()).find(m => m.provider === 'openai-codex' && m.id === 'gpt-5.6-luna');
assert.ok(model);
const dir = fs.mkdtempSync(path.join(tmp, 'sdk-plugin-'));
for (const relative of ['extensions', '.pi/extensions']) {
  fs.mkdirSync(path.join(dir, relative), { recursive: true });
  fs.writeFileSync(path.join(dir, relative, 'excluded.ts'), 'export default function(){ throw Error("UNAUTHORIZED_EXTENSION"); }');
}
for (const relative of ['AGENTS.md', 'APPEND_SYSTEM.md', '.pi/APPEND_SYSTEM.md']) fs.writeFileSync(path.join(dir, relative), 'PARENT_SENTINEL');
const settingsManager = sdk.SettingsManager.inMemory({ compaction: { enabled: false }, cacheWarming: 'off', transport: 'sse', retry: { enabled: false, provider: { maxRetries: 0 } } });
const fetch = globalThis.fetch;
let networkCalls = 0, session;
globalThis.fetch = async () => { networkCalls++; throw Error('unexpected network during isolated initialization'); };
try {
  const loadedPlugin = await shortPluginLoader(sdk, dir, settingsManager, 'Only this task.');
  const loader = loadedPlugin.loader;
  assert.equal(loader.getExtensions().errors.length, 0);
  assert.equal(loader.getExtensions().extensions.length, 1);
  assert.equal(loader.getExtensions().extensions[0].tools.size, 0);
  assert.equal(loader.getSkills().skills.length, 0);
  assert.equal(loader.getPrompts().prompts.length, 0);
  assert.equal(loader.getAgentsFiles().agentsFiles.length, 0);
  assert.deepEqual(loader.getAppendSystemPrompt(), []);
  const before = runtime.getProvider('openai-codex'), errors = [];
  ({ session } = await sdk.createAgentSession({ cwd: dir, agentDir: dir, modelRuntime: runtime, model,
    tools: [], sessionManager: sdk.SessionManager.inMemory(dir), resourceLoader: loader, settingsManager }));
  await session.bindExtensions({ mode: 'print', onError: e => errors.push(e.event) });
  assert.deepEqual(errors, []);
  assert.notEqual(runtime.getProvider('openai-codex'), before);
  assert.deepEqual(session.getActiveToolNames(), []);
  assert.equal(session.messages.length, 0);
  assert.ok(!session.systemPrompt.includes('PARENT_SENTINEL'));
  const payload = await session.extensionRunner.emitBeforeProviderRequest({ model: model.id, input: [],
    tools: [{ type: 'web_search' }], text: { verbosity: 'high' }, reasoning: { summary: 'detailed', mode: 'pro' } });
  assert.equal(payload.text.verbosity, 'low');
  assert.deepEqual(payload.tools, []);
  assert.ok(!('summary' in payload.reasoning)); assert.ok(!('mode' in payload.reasoning));
  assert.equal(networkCalls, 0);
  assert.equal(settingsManager.getCompactionSettings().enabled, false);
  assert.equal(settingsManager.getCacheWarmingMode(), 'off');
  fs.writeFileSync(path.join(tmp, 'plugin-sdk-evidence.json'), JSON.stringify({ plugin: loadedPlugin.plugin,
    extensions: loader.getExtensions().extensions.length, registeredExtensionTools: 0, activeTools: [],
    messages: 0, initializationNetworkCalls: networkCalls, errors, payload: { text: payload.text, reasoning: payload.reasoning, tools: payload.tools },
    compaction: 'disabled', cacheWarming: 'off', unselectedExtensionsExcluded: true }));
  console.log('installed plugin initialization, handler behavior and resource exclusion passed');
} finally {
  if (session) { await session.extensionRunner.emit({ type: 'session_shutdown', reason: 'quit' }); session.dispose(); }
  globalThis.fetch = fetch;
}
