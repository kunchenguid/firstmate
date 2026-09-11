import { createHash } from 'node:crypto';
import { fakeMessages } from '../../fm-state-reader/tests/fake-messages.mjs';
export const now = Date.parse('2026-09-11T00:00:00Z');
export const config = {
  maxSeconds: 120, maxFetches: 6, maxBytes: 65536,
  enabledAdapters: ['fetch', 'gh', 'scrapling', 'alphaxiv'],
  sources: [{ origin: 'https://docs.example.org', publisher: 'example' }, { origin: 'https://other.example.net', publisher: 'other' }],
  roles: { researcher: { harness: 'pi', model: 'default', effort: 'low', persona: 'personas/researcher.md' } },
};
export const payload = {
  question: 'What do these public documents agree on?', scope: 'Only the supplied documentation.', topic: 'documentation', publicOnly: true,
  deadline: '2026-09-11T00:02:00Z',
  allowedSources: [{ adapter: 'fetch', url: 'https://docs.example.org/a' }, { adapter: 'scrapling', url: 'https://other.example.net/b' }],
};
export const message = {
  schema: 'fm-message.v1', id: `msg-${'1'.repeat(32)}`, thread: 'research-example',
  at: '2026-09-11T00:00:00Z', from: 'requester', to: ['robin'], kind: 'request', ref: null, text: JSON.stringify(payload),
};
export const quote = 'The API returns one result for each request.';
export const draft = { conclusions: [{ kind: 'observed', statement: 'Both supplied documents describe one result per request.', citations: [{ source: 1, quote }, { source: 2, quote }] }], unknowns: [] };
export function fakeRetrieval(content = quote) {
  const calls = [];
  return { calls, async fetch(url, options) { calls.push({ url, options }); return content; } };
}
export function fakeReasoner(output = draft) {
  const calls = [];
  return { calls, async reason(input, options) { calls.push({ input, options }); return structuredClone(output); } };
}
export function fakeStore() {
  const records = new Map(), reports = new Map(), telemetry = [], calls = [];
  return {
    records, reports, telemetry, calls,
    async load(id) { return structuredClone(records.get(id) ?? null); },
    async save(id, record) { calls.push('save'); records.set(id, structuredClone(record)); },
    async finish(id, topic, markdown, result) {
      calls.push('finish');
      const record = { ...result, report: `data/knowledge/${topic}/${id}.md`, eventId: createHash('sha256').update(id).digest('hex').slice(0, 24) };
      reports.set(record.report, markdown); records.set(id, structuredClone(record)); return record;
    },
    async log(row) { telemetry.push(structuredClone(row)); },
  };
}
export function fakes(entries = [{ name: '001.msg', message }]) {
  let time = now;
  const published = [];
  return {
    messages: fakeMessages(entries), store: fakeStore(),
    retrieval: Object.fromEntries(['fetch', 'gh', 'scrapling', 'alphaxiv'].map(name => [name, fakeRetrieval()])),
    reasoner: fakeReasoner(), events: { published, async publish(id) { published.push(id); } },
    clock: { now: () => time, advance: ms => { time += ms; } },
  };
}
