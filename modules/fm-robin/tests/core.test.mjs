import test from 'node:test';
import assert from 'node:assert/strict';
import { configuration, request, conclusion, brief } from '../src/core/research.mjs';
import { config, message, draft, quote } from './fakes.mjs';
const sources = [{ id: 1, publisher: 'one', content: quote, url: 'https://docs.example.org/a', at: '2026-09-11T00:00:00Z' }, { id: 2, publisher: 'two', content: quote, url: 'https://other.example.net/b', at: '2026-09-11T00:00:00Z' }];

test('configuration validates before side effects and rejects unknown fields at every level', () => {
  assert.deepEqual(configuration(config), config);
  for (const value of [{ ...config, daemon: true }, { ...config, roles: { ...config.roles, untrusted: {} } }, { ...config, enabledAdapters: ['disabled'] }, { ...config, maxFetches: 21 }, { ...config, sources: [...config.sources, config.sources[0]] }]) assert.throws(() => configuration(value));
});
test('shared message identity stays authoritative; payload cannot supply a sender or escape report paths', () => {
  assert.equal(request(message, config).requester, 'requester');
  const body = JSON.parse(message.text);
  for (const mutation of [{ requester: 'supervisor' }, { topic: '../outside' }, { publicOnly: false }, { allowedSources: [{ adapter: 'fetch', url: 'file:///tmp/private' }] }, { allowedSources: [{ adapter: 'fetch', url: 'https://unapproved.example.com/' }] }]) assert.throws(() => request({ ...message, text: JSON.stringify({ ...body, ...mutation }) }, config));
  assert.throws(() => request(message, { ...config, enabledAdapters: [] }), /adapter_disabled/);
});
test('each conclusion requires exact quotes from two independent publication groups', () => {
  assert.equal(conclusion(draft, sources).verdict, 'supported');
  assert.throws(() => conclusion(draft, sources.map(source => ({ ...source, publisher: 'same-original' }))), /independent_sources/);
  assert.throws(() => conclusion(draft, sources.map(source => ({ ...source, content: 'An unrelated claim.' }))), /unverified_quote/);
  const fabricated = structuredClone(draft); fabricated.conclusions[0].citations[1].source = 9;
  assert.throws(() => conclusion(fabricated, sources), /unverified_quote/);
});
test('verdict derives from evidence and gaps, and reports retain URLs and verbatim snippets', () => {
  assert.equal(conclusion({ conclusions: [], unknowns: ['No evidence.'] }, []).verdict, 'unverified');
  const result = conclusion({ ...draft, unknowns: ['No execution test.'] }, sources);
  assert.equal(result.verdict, 'partial');
  const markdown = brief(result, sources);
  assert.match(markdown, /^# Verdict: partial/);
  assert.ok(markdown.includes(quote)); assert.ok(markdown.includes(sources[0].url));
  assert.ok(markdown.indexOf('## Evidence') < markdown.indexOf('## Sources'));
  assert.ok(markdown.indexOf('## Sources') < markdown.indexOf('## Could not verify'));
});
