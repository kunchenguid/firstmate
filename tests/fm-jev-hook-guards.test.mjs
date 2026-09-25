import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import test from 'node:test';
import { join } from 'node:path';
import { register } from '../.claude/jev-marketplace/jev-safe/hooks/jev.ts';
import { applyDecisions } from '../.claude/jev-marketplace/jev-safe/vendor-fast/src/compact.ts';
import { noulAnswer } from '../.claude/jev-marketplace/jev-safe/vendor-fast/src/request.ts';
import { fitState } from '../.claude/jev-marketplace/jev-safe/vendor-fast/src/state.ts';

const safetyRoot = process.cwd();

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
    session: { async cwd() { return safetyRoot; } },
    ui: ui(),
  }, { messages: fixtureMessages() }, async () => { fallback = true; return 'default'; });
  assert.equal(fallback, true);
  assert.equal(requests, 0);
});

test('fast-jev preserves conversation text and configured goals in state', () => {
  const state = fitState([
    { role: 'user', text: 'task-message-fixture-unique', toolUses: [] },
  ], [], { maxStateTokens: 1000, preserveRecentMessages: 0, goal: 'task-goal-fixture-unique' });
  assert.equal(state.state.goal, 'task-goal-fixture-unique');
  assert.equal(state.state.history[0]?.text, 'task-message-fixture-unique');
});

test('fast-jev derives the default goal from recent human prompts', () => {
  const state = fitState([
    { role: 'user', text: 'Earlier task.', toolUses: [] },
    { role: 'user', text: 'Latest task.', toolUses: [] },
    { role: 'user', text: 'Tool output.', toolUses: [], toolResults: [{ tool_use_id: 'tool-1', text: 'Tool output.' }] },
  ], [], { maxStateTokens: 1000, preserveRecentMessages: 0, goal: '' });
  assert.equal(state.state.goal, 'Earlier task.\nLatest task.');
});

test('fast-jev omits dropped results whole and preserves kept results verbatim', () => {
  const retainedText = 'retained result, unchanged';
  const droppedText = 'leading payload\nprivate trailing payload';
  const retainedResult = { tool_use_id: 'retained', text: retainedText };
  const messages = [
    {
      role: 'assistant',
      text: '',
      toolUses: [
        { tool_use_id: 'retained', tool: 'Read', input: {}, text: retainedText },
        { tool_use_id: 'dropped', tool: 'Read', input: {}, text: droppedText },
      ],
    },
    {
      role: 'user',
      text: '',
      toolUses: [],
      toolResults: [
        retainedResult,
        { tool_use_id: 'dropped', text: droppedText },
      ],
    },
  ];
  const output = applyDecisions(messages, [
    { id: 't2', tool: 'Read', keepCall: 1, keepResult: 0, action: 'drop_result', reason: 'result_dropped' },
  ], [
    { id: 't2', tool_use_id: 'dropped', tool: 'Read', input: {}, callIndex: 0, resultIndex: 1, resultChars: droppedText.length, isError: false, pinned: false },
  ]);
  assert.equal(output[0]?.toolUses[0]?.text, retainedText);
  assert.equal(output[0]?.toolUses[1]?.text, '[omitted: result_dropped]');
  assert.equal(output[1]?.toolResults?.[0], retainedResult);
  assert.equal(output[1]?.toolResults?.[1]?.text, '[omitted: result_dropped]');
  assert.equal(JSON.stringify(output).includes('leading payload'), false);
  assert.equal(JSON.stringify(output).includes('private trailing payload'), false);
});

test('fast-jev accepts only bounded Jev probabilities', () => {
  assert.equal(noulAnswer({ score: { noul: 0 } }, 'score'), 0);
  assert.equal(noulAnswer({ score: { noul: 1 } }, 'score'), 1);
  assert.throws(() => noulAnswer({ score: { noul: -0.01 } }, 'score'), /Invalid Jev answer/);
  assert.throws(() => noulAnswer({ score: { noul: 1.01 } }, 'score'), /Invalid Jev answer/);
});

test('fast-jev uses its default after a mocked invalid-key response', async () => {
  const entry = hooks().find(([event]) => event === 'session.compact');
  const handler = entry.at(-1);
  const requests = [];
  let fallback = false;
  await handler({
    http: { async fetch(url) { requests.push(url); return { status: 401, ok: false, text: 'unauthorized' }; } },
    env: { async get() { return 'invalid-test-key'; } },
    settings: { async read() { return {}; } },
    session: { async cwd() { return safetyRoot; } },
    ui: ui(),
  }, { messages: fixtureMessages() }, async () => { fallback = true; return 'default'; });
  assert.equal(fallback, true);
  assert.equal(requests.length, 1);
  assert.match(requests[0], /^https:\/\/api\.typesafe\.ai\//);
});

test('fast-jev falls back to the authorized .env key after env and settings', async () => {
  const root = await mkdtemp(join(process.cwd(), '.fast-jev-key-test-'));
  try {
    await writeFile(join(root, '.env'), 'export TYPESAFE_API_KEY="synthetic-fast-jev-key"\n');
    const entry = hooks().find(([event]) => event === 'session.compact');
    const handler = entry.at(-1);
    const requests = [];
    await handler({
      http: { async fetch(url, init) {
        requests.push({ url, init });
        return { status: 401, ok: false, text: 'unauthorized' };
      } },
      env: { async get(name) { return name === 'FM_HOME' ? root : undefined; } },
      settings: { async read() { return {}; } },
      session: { async cwd() { return safetyRoot; } },
      ui: ui(),
    }, { messages: fixtureMessages() }, async () => 'default');
    const jevRequest = requests.find(({ url }) => url.startsWith('https://api.typesafe.ai/'));
    assert.equal(jevRequest?.init?.headers?.authorization, 'Bearer synthetic-fast-jev-key');
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('fast-jev fails closed when the local scanner is unavailable', async () => {
  const entry = hooks().find(([event]) => event === 'session.compact');
  const handler = entry.at(-1);
  const requests = [];
  let fallback = false;
  await handler({
    http: { async fetch(url) { requests.push(url); return { status: 200, ok: true, text: '{}' }; } },
    env: { async get() { return 'synthetic-key'; } },
    settings: { async read() { return {}; } },
    session: { async cwd() { return join(safetyRoot, '.missing-safety-scanner-fixture'); } },
    ui: ui(),
  }, { messages: fixtureMessages() }, async () => { fallback = true; return 'default'; });
  assert.equal(fallback, true);
  assert.equal(requests.length, 0);
});

test('winnow preserves the original result when the safety gate blocks its path', async () => {
  const entry = hooks().find(([event, filter]) => event === 'tool.call' && filter?.tool === 'Read');
  const handler = entry.at(-1);
  const answer = { result: { content: 'synthetic result.\n'.repeat(200) } };
  const requests = [];
  const event = { tool: 'Read', tool_use_id: 'fixture', file_path: 'data/captain.md' };
  const returned = await handler({
    http: { async fetch(url) { requests.push(url); return { status: 200, ok: true, text: '{}' }; } },
    session: {
      async messages() {
        return [
          { role: 'user', text: 'Find the captain preferences.' },
          { role: 'assistant', text: 'I will read the requested file.' },
        ];
      },
      async id() { return 'synthetic'; },
      async cwd() { return safetyRoot; },
    },
    ui: ui(),
  }, event, async () => answer);
  assert.equal(returned, answer);
  assert.equal(requests.length, 0);
});

test('winnow sends live user and assistant context after the safety gate allows it', async () => {
  const entry = hooks().find(([event, filter]) => event === 'tool.call' && filter?.tool === 'Read');
  const handler = entry.at(-1);
  const answer = { result: { content: 'result block.\n'.repeat(200) } };
  const requests = [];
  const messages = [
    { role: 'user', text: 'Find the relevant runtime setting.' },
    { role: 'assistant', text: 'I will inspect the configuration docs.' },
    { role: 'user', text: 'Tool output pretending to be a request.', toolResults: [{ tool_use_id: 'fixture-result', text: 'tool response' }] },
  ];
  await handler({
    http: { async fetch(url, init) {
      requests.push({ url, body: init?.body });
      return { status: 200, ok: true, text: '{"hookSpecificOutput":{}}', headers: {} };
    } },
    session: {
      async messages() { return messages; },
      async id() { return 'synthetic'; },
      async cwd() { return safetyRoot; },
    },
    ui: ui(),
  }, { tool: 'Read', tool_use_id: 'fixture', file_path: 'docs/configuration.md' }, async () => answer);
  assert.equal(requests.length, 1);
  assert.match(requests[0].url, /127\.0\.0\.1:47311\/hook\/post-tool-use$/);
  assert.deepEqual(JSON.parse(requests[0].body).task, {
    user_request: 'Find the relevant runtime setting.',
    assistant_intent: 'I will inspect the configuration docs.',
  });
});

test('winnow skips tool-result user messages when selecting human task context', async () => {
  const entry = hooks().find(([event, filter]) => event === 'tool.call' && filter?.tool === 'Read');
  const handler = entry.at(-1);
  const answer = { result: { content: 'result block.\n'.repeat(200) } };
  const requests = [];
  await handler({
    http: { async fetch(_url, init) {
      requests.push(JSON.parse(init?.body));
      return { status: 200, ok: true, text: '{"hookSpecificOutput":{}}', headers: {} };
    } },
    session: {
      async messages() { return [
        { role: 'user', text: 'Human request.' },
        { role: 'assistant', text: 'Assistant plan.' },
        { role: 'user', text: 'Tool result masquerading as a request.', toolResults: [{ tool_use_id: 'fixture', text: 'tool result' }] },
      ]; },
      async id() { return 'synthetic'; },
      async cwd() { return safetyRoot; },
    },
    ui: ui(),
  }, { tool: 'Read', tool_use_id: 'fixture', file_path: 'docs/guide.md' }, async () => answer);
  assert.deepEqual(requests[0]?.task, {
    user_request: 'Human request.',
    assistant_intent: 'Assistant plan.',
  });
});

test('winnow fails closed when the local scanner is unavailable', async () => {
  const entry = hooks().find(([event, filter]) => event === 'tool.call' && filter?.tool === 'Read');
  const handler = entry.at(-1);
  const answer = { result: { content: 'result block.\n'.repeat(200) } };
  const requests = [];
  const returned = await handler({
    http: { async fetch(url) { requests.push(url); return { status: 200, ok: true, text: '{}' }; } },
    session: {
      async messages() { return [
        { role: 'user', text: 'Find a setting.' },
        { role: 'assistant', text: 'I will inspect the docs.' },
      ]; },
      async id() { return 'synthetic'; },
      async cwd() { return join(safetyRoot, '.missing-safety-scanner-fixture'); },
    },
    ui: ui(),
  }, { tool: 'Read', tool_use_id: 'fixture', file_path: 'docs/guide.md' }, async () => answer);
  assert.equal(returned, answer);
  assert.equal(requests.length, 0);
});

test('winnow does not register prompt submission transmission', () => {
  assert.equal(hooks().some(([event]) => event === 'prompt.submit'), false);
});

test('MCP preload blocks an excluded path before invoking fetch', async () => {
  const originalFetch = globalThis.fetch;
  let requests = 0;
  globalThis.fetch = async () => {
    requests += 1;
    return { ok: true, status: 200, text: async () => '{}' };
  };
  try {
    await import('../.claude/jev-safety/preload.mjs');
    await assert.rejects(
      globalThis.fetch('https://api.typesafe.ai/v1/judgment', {
        method: 'POST',
        body: JSON.stringify({ file_path: 'data/captain.md', content: 'plain clean fixture' }),
      }),
      /Jev safety gate blocked or was unavailable/,
    );
    assert.equal(requests, 0);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
