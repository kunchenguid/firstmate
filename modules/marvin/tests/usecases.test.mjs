import test from 'node:test';
import assert from 'node:assert/strict';
import { observe, watch } from '../src/index.mjs';
import { fakes, provider } from './fakes.mjs';

test('fake ports preserve read, record, render, sleep continuity across refreshes', async () => {
  const ports = fakes([{ id: 'one', data: provider, credentialSource: '/private/credentials' }]);
  await watch(ports, { pools: [], refreshSeconds: 60 }, 2);
  assert.equal(ports.frames.length, 2);
  assert.deepEqual(ports.sleeps, [60000]);
  assert.equal(Date.parse(ports.frames[1].ts) - Date.parse(ports.frames[0].ts), 60000);
  assert.ok(ports.frames[1].pools[0].windows[0].delta > ports.frames[0].pools[0].windows[0].delta);
  assert.deepEqual(ports.events.map(e => Array.isArray(e) ? e[0] : e), [
    'source.enter', 'read', 'source.exit', 'sample', 'renderer.enter', 'render', 'renderer.exit', 'sleep',
    'source.enter', 'read', 'source.exit', 'sample', 'renderer.enter', 'render', 'renderer.exit',
  ]);
  assert.doesNotMatch(JSON.stringify(ports.events), /private@example|private\/credentials/);
});

test('unavailable reader still renders and records explicit errors', async () => {
  const ports = fakes([{ id: 'one', data: { provider: 'claude', windows: [] }, error: 'source unavailable' }]);
  const frame = await observe(ports, { pools: [] });
  assert.equal(frame.counts.unavailable, 1);
  assert.equal(ports.events.find(e => e[0] === 'source.exit')[1].outcome, 'error');
});
