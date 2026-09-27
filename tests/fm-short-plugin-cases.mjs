import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { pluginFixture } from './fm-short-plugin-fixture.mjs';
const [root, tmp] = process.argv.slice(2);
const { shortPluginLoader } = await import(pathToFileURL(path.join(root, 'bin/fm-short-plugin.mjs')));
const pkg = path.join(tmp, 'plugin-sdk');
fs.mkdirSync(pkg);
const source = pluginFixture(pkg);
const sdkFile = path.join(pkg, 'fixture.mjs');
fs.writeFileSync(sdkFile, source);
const sdk = await import(pathToFileURL(sdkFile));
const manifest = path.join(sdk.getAgentDir(), 'npm/node_modules/pi-openai-codex-compat/package.json');
const original = fs.readFileSync(manifest, 'utf8');
const child = path.join(tmp, 'plugin-child'); fs.mkdirSync(child);
for (const change of [{ name: 'another-plugin' }, { version: '0.0.17' }, { pi: { extensions: ['../escape.ts'] } }]) {
  fs.writeFileSync(manifest, JSON.stringify({ ...JSON.parse(original), ...change }));
  await assert.rejects(() => shortPluginLoader(sdk, child, {}, 'task'), /identity\/version\/entrypoint mismatch/);
}
fs.unlinkSync(manifest);
await assert.rejects(() => shortPluginLoader(sdk, child, {}, 'task'), /requires installed/);
fs.writeFileSync(manifest, original);
const loader = await shortPluginLoader(sdk, child, {}, 'task');
assert.equal(loader.getExtensions().extensions.length, 1);
assert.equal(loader.getExtensions().extensions[0].tools.size, 0, 'shell registration removed before session construction');
assert.equal(loader.getExtensions().extensions[0].commands.size, 0);
assert.equal(loader.getSystemPrompt(), 'task');
assert.deepEqual(loader.getAgentsFiles(), { agentsFiles: [] });
for (const kind of ['error', 'other-extension', 'unauthorized-tool']) {
  const badSdk = { ...sdk, DefaultResourceLoader: class extends sdk.DefaultResourceLoader {
    constructor(options) {
      const override = options.extensionsOverride;
      super({ ...options, extensionsOverride: result => {
        if (kind === 'error') result.errors.push({ error: 'failed' });
        if (kind === 'other-extension') result.extensions.push({});
        if (kind === 'unauthorized-tool') result.extensions[0].tools.set('unrestricted_bash', {});
        return override(result);
      } });
    }
  } };
  await assert.rejects(() => shortPluginLoader(badSdk, child, {}, 'task'), /plugin load failed|unexpected tool/);
}
console.log('plugin identity, load, discovery and tool registration boundaries passed');
