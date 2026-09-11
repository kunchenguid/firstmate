import { fakeMessages } from '../../fm-state-reader/tests/fake-messages.mjs';
import { telemetry } from '../src/adapters/telemetry.mjs';
export function fakes(reading, inbox = []) {
  const records = new Map(), captures = new Set(), logs = [], published = [];
  const journal = { get: key => structuredClone(records.get(key) ?? null), set: (key, value) => records.set(key, structuredClone(value)),
    append: row => logs.push(structuredClone(row)), stats: async () => ({}), claim: () => () => {}, resources: () => null };
  return { records, captures, logs, published, journal, messages: fakeMessages(inbox), audit: telemetry(journal, 'observation'),
    source: { read: now => ({ ...structuredClone(reading), now }), watch: () => () => {} },
    forge: { read: async () => [] },
    publisher: { captured: id => captures.has(id), publish: async id => { captures.add(id); published.push(id); } },
  };
}
