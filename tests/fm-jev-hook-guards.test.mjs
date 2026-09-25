import assert from 'node:assert/strict';
import test from 'node:test';
import { register } from '../.claude/jev-marketplace/jev-safe/hooks/jev.ts';

function fixtureMessages() {
  return [
    { role: 'user', text: 'Compact this synthetic fixture history.', toolUses: [] },
    {
      role: 'assistant',
      text: '',
      toolUses: [{ tool_use_id: 'fixture-read', tool: 'Read', input: { file_path: 'synthetic-fixture.txt' } }],
    },
    {
      role: 'user',
      text: '',
      toolUses: [],
      toolResults: [{ tool_use_id: 'fixture-read', text: 'Synthetic fixture output.\n'.repeat(100) }],
    },
  ];
}

function hooks() {
  const registered = [];
  register((...args) => registered.push(args), { preserveRecentMessages: 0, minReductionRatio: 0 });
  return registered;
}

function ui() {
  return { log() {}, toast() {} };
}

test('fast-jev falls back without a key and sends no request', async () => {
  const entry = hooks().find(([event]) => event === 'session.compact');
  const handler = entry.at(-1);
  let fallback = false;
  let requests = 0;
  await handler({
    http: { async fetch() { requests += 1; throw new Error('unexpected request'); } },
    env: { async get() { return undefined; } },
    settings: { async read() { return {}; } },
    ui: ui(),
  }, { messages: fixtureMessages() }, async () => { fallback = true; return 'default'; });
  assert.equal(fallback, true);
  assert.equal(requests, 0);
});

test('fast-jev uses its default after a mocked invalid-key response', async () => {
  const entry = hooks().find(([event]) => event === 'session.compact');
  const handler = entry.at(-1);
  const requests = [];
  let fallback = false;
  await handler({
    http: { async fetch(url) {
      requests.push(url);
      return url.endsWith('/check')
        ? { status: 200, ok: true, text: '{"allowed":true,"reason":"clean"}' }
        : { status: 401, ok: false, text: 'unauthorized' };
    } },
    env: { async get() { return 'invalid-test-key'; } },
    settings: { async read() { return {}; } },
    ui: ui(),
  }, { messages: fixtureMessages() }, async () => { fallback = true; return 'default'; });
  assert.equal(fallback, true);
  assert.equal(requests.length, 2);
  assert.match(requests[0], /127\.0\.0\.1:48752\/check$/);
});

test('winnow preserves the original result when the safety gate blocks its path', async () => {
  const entry = hooks().find(([event, filter]) => event === 'tool.call' && filter?.tool === 'Read');
  const handler = entry.at(-1);
  const answer = { result: { content: 'synthetic result.\n'.repeat(200) } };
  const requests = [];
  const event = { tool: 'Read', tool_use_id: 'fixture', file_path: 'data/captain.md' };
  const returned = await handler({
    http: { async fetch(url) {
      requests.push(url);
      return { status: 200, ok: true, text: '{"allowed":false,"reason":"sensitive_path"}' };
    } },
    session: {
      async messages() { return []; },
      async id() { return 'synthetic'; },
      async cwd() { return '/synthetic'; },
    },
    ui: ui(),
  }, event, async () => answer);
  assert.equal(returned, answer);
  assert.equal(requests.length, 1);
  assert.match(requests[0], /127\.0\.0\.1:48752\/check$/);
});
