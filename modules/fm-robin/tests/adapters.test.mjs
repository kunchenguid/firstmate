import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { events } from '../src/adapters/events.mjs';
import { fileStore, stats, telemetryLimits } from '../src/adapters/files.mjs';
import { research } from '../src/usecases/research.mjs';
import { config, message, fakes, now } from './fakes.mjs';

function fixture(t) {
  const home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'robin-files-')));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  return home;
}
test('real filesystem composes with the request use case; reports, events and telemetry are durable', async t => {
  const home = fixture(t), ports = fakes(); ports.store = fileStore(home);
  const unlock = ports.store.lock();
  const result = await research(ports, config);
  assert.match(fs.readFileSync(path.join(home, result.report), 'utf8'), /^# Verdict: supported/);
  const saved = await fileStore(home).load(message.id);
  assert.equal(saved.notified, true);
  assert.equal(JSON.parse(fs.readFileSync(path.join(home, 'state/robin/events', `${saved.eventId}.json`))).requester, 'requester');
  assert.equal(stats(home, now).requests, 1);
  assert.equal(stats(home, now).fetches, 2);
  assert.equal(stats(home, now).cost, null);
  unlock(); assert.ok(!fs.existsSync(path.join(home, 'state/robin/run.lock')));
});
test('one process lock; symlink paths and escaping IDs are refused', async t => {
  const home = fixture(t), store = fileStore(home), unlock = store.lock();
  assert.throws(() => fileStore(home).lock(), /already_running/); unlock();
  await assert.rejects(store.load('../outside'), /invalid_request/);
  fs.mkdirSync(path.join(home, 'data')); fs.symlinkSync(os.tmpdir(), path.join(home, 'data/knowledge'));
  await assert.rejects(store.finish(message.id, 'topic', 'report', { verdict: 'unverified', requester: 'requester' }), /symlink/);
});
test('load repairs missing report/event files from the committed journal and refuses changed reports', async t => {
  const home = fixture(t), store = fileStore(home);
  const record = await store.finish(message.id, 'topic', 'original report', { verdict: 'supported', requester: 'requester' });
  fs.unlinkSync(path.join(home, record.report)); fs.unlinkSync(path.join(home, 'state/robin/events', `${record.eventId}.json`));
  await fileStore(home).load(message.id);
  assert.equal(fs.readFileSync(path.join(home, record.report), 'utf8'), 'original report');
  fs.writeFileSync(path.join(home, record.report), 'modified');
  await assert.rejects(store.load(message.id), /immutable_conflict/);
  assert.equal(fs.readFileSync(path.join(home, record.report), 'utf8'), 'modified');
});
test('status and stats never create runtime files', t => {
  const home = fixture(t);
  assert.equal(stats(home, now).requests, 0);
  assert.deepEqual(fs.readdirSync(home), []);
});
test('telemetry retains seven days, caps daily bytes, and exposes truncated statistics', async t => {
  const home = fixture(t), store = fileStore(home), directory = path.join(home, 'state/robin/telemetry');
  for (let day = 1; day <= 10; day++) await store.log({ ts: `2026-09-${String(day).padStart(2, '0')}T12:00:00Z`, event: 'request.exit', outcome: 'accepted' });
  assert.equal(fs.readdirSync(directory).length, telemetryLimits.days);
  assert.ok(!fs.existsSync(path.join(directory, '2026-09-03.jsonl')));
  for (let index = 0; index < 80; index++) await store.log({ ts: '2026-09-10T12:00:00Z', event: 'request.exit', outcome: 'accepted', reasons: ['synthetic'.repeat(1000)] });
  assert.ok(fs.statSync(path.join(directory, '2026-09-10.jsonl')).size <= telemetryLimits.fileBytes);
  assert.equal(stats(home, Date.parse('2026-09-10T12:00:01Z')).truncated, true);
  const size = fs.statSync(path.join(directory, '2026-09-10.jsonl')).size;
  await assert.rejects(store.log({ ts: '2026-09-10T12:00:00Z', content: 'x'.repeat(telemetryLimits.recordBytes) }), /record_too_large/);
  assert.equal(fs.statSync(path.join(directory, '2026-09-10.jsonl')).size, size);
});
test('research composes with real immutable event capture and a durable wake before acknowledgement', async t => {
  const home = fixture(t), ports = fakes();
  const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
  const previous = process.env.FM_PROCEVENT_CLAIM_ROOT;
  process.env.FM_PROCEVENT_CLAIM_ROOT = path.join(home, 'claims');
  t.after(() => { if (previous === undefined) delete process.env.FM_PROCEVENT_CLAIM_ROOT; else process.env.FM_PROCEVENT_CLAIM_ROOT = previous; });
  ports.store = fileStore(home); ports.events = events({ home, root });
  const acknowledge = ports.messages.acknowledge.bind(ports.messages);
  ports.messages.acknowledge = async name => {
    const record = await ports.store.load(message.id);
    const source = `robin-${record.eventId}`;
    const result = JSON.parse(fs.readFileSync(path.join(home, `state/procevent-inbox/${source}.1.result`), 'utf8'));
    assert.equal(result.report, record.report); assert.equal(result.requester, 'requester');
    assert.match(fs.readFileSync(path.join(home, 'state/.wake-queue'), 'utf8'), /procevent fm-state-reader robin-/);
    assert.ok(fs.existsSync(path.join(home, result.report)));
    await acknowledge(name);
  };
  const unlock = ports.store.lock();
  try { assert.equal((await research(ports, config)).state, 'answered'); } finally { unlock(); }
});
