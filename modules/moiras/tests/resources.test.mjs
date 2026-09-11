import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { journal } from '../src/adapters/journal.mjs';
import { toolRoot } from '../src/adapters/config.mjs';
import { run } from '../src/adapters/command.mjs';
test('resource status identifies its lease owner, never the status command or a reused process', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'moiras-resource-')), store = journal(home);
  let release;
  try {
    assert.equal(store.resources(), null);
    release = store.claim(); const reported = store.resources();
    assert.equal(reported.pid, process.pid); assert.ok(reported.rssBytes > 0); assert.ok(reported.cpuPercent >= 0);
    const ownerFile = path.join(home, 'state/moiras/running/owner.json'), owner = fs.readFileSync(ownerFile, 'utf8');
    fs.writeFileSync(ownerFile, JSON.stringify({ ...JSON.parse(owner), started: 'not this process birth' }));
    assert.equal(store.resources(), null); fs.writeFileSync(ownerFile, owner);
    release(); assert.equal(store.resources(), null);
  } finally { release?.(); fs.rmSync(home, { recursive: true, force: true }); }
});
test('telemetry rotates bounded segments, expires old days and never follows a symlink', async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'moiras-retention-')), store = journal(home);
  const dir = path.join(home, 'state/moiras/telemetry'), ts = '2026-09-11T00:00:01.000Z';
  try {
    fs.writeFileSync(path.join(dir, '2026-09-08.jsonl'), '{}\n');
    fs.writeFileSync(path.join(dir, '2026-09-10.jsonl'), JSON.stringify({ ts: '2026-09-10T23:59:50.000Z', event: 'previous-day' }) + '\n');
    fs.writeFileSync(path.join(dir, 'unrelated.txt'), 'keep');
    for (let i = 0; i < 8; i++) store.append({ ts, event: 'probe', outcome: 'accepted', padding: 'x'.repeat(350000) });
    assert.ok(!fs.existsSync(path.join(dir, '2026-09-08.jsonl')));
    const logs = fs.readdirSync(dir).filter(name => name.endsWith('.jsonl'));
    assert.equal(logs.length, 3); assert.ok(logs.includes('2026-09-10.jsonl'));
    for (const name of logs) {
      assert.ok(fs.statSync(path.join(dir, name)).size <= 1048576);
      for (const line of fs.readFileSync(path.join(dir, name), 'utf8').trim().split('\n')) JSON.parse(line);
    }
    const stats = await store.stats(Date.parse(ts) / 1000 + 1);
    assert.equal(stats.events, 5); assert.equal(stats.rotated, true);
    const target = path.join(dir, 'unrelated.txt');
    fs.unlinkSync(path.join(dir, '2026-09-11.jsonl')); fs.symlinkSync(target, path.join(dir, '2026-09-11.jsonl'));
    assert.throws(() => store.append({ ts, event: 'probe' }));
    assert.equal(fs.readFileSync(target, 'utf8'), 'keep');
  } finally { fs.rmSync(home, { recursive: true, force: true }); }
});
test('real animated terminal stays below 60 MB RSS and 1% idle CPU over 30 seconds', { timeout: 75000 }, async () => {
  const { stdout } = await run('python3', [fileURLToPath(new URL('./resources.py', import.meta.url)), toolRoot], { timeout: 70000 });
  const result = JSON.parse(stdout); assert.ok(result.windowSeconds >= 30);
  assert.ok(result.maxRssBytes < 60000000, `RSS ${result.maxRssBytes}`);
  assert.ok(result.idleCpuPercent >= 0 && result.idleCpuPercent < 1, `CPU ${result.idleCpuPercent}%`);
  assert.ok(result.animated); assert.equal(result.exit, 0); assert.equal(result.stoppedServer, null);
  console.log(JSON.stringify(result));
});
