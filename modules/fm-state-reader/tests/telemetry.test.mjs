import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const day = ms => new Date(ms).toISOString().slice(0, 10);
const row = (ms, outcome = 'accepted') => JSON.stringify({ schema: 'fm-message-telemetry.v1', ts: new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z'), event: 'finished', outcome, counters: { delivered: 1 } }) + '\n';
function fixture(t) {
  const home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'fm-telemetry-')));
  const directory = path.join(home, 'state/fm-message/telemetry');
  fs.mkdirSync(directory, { recursive: true });
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const run = (...args) => execFileSync(path.join(root, 'bin/fm-message.sh'), args, { env: { ...process.env, FM_HOME: home, FM_STATE_OVERRIDE: path.join(home, 'state') }, encoding: 'utf8', timeout: 30000, stdio: 'pipe' });
  return { home, directory, run, file: ms => path.join(directory, `${day(ms)}.jsonl`), stats: () => JSON.parse(run('stats')) };
}

test('transport appends prune only expired owned daily files and preserve other evidence', t => {
  const f = fixture(t), now = Date.now();
  const old = f.file(now - 8 * 86400000), retained = f.file(now - 5 * 86400000);
  const linked = f.file(now - 9 * 86400000), victim = path.join(f.home, 'untouched');
  fs.writeFileSync(old, 'expired'); fs.writeFileSync(retained, 'retained');
  for (const age of [6, 7]) fs.writeFileSync(f.file(now - age * 86400000), 'retention boundary');
  fs.writeFileSync(victim, 'outside telemetry'); fs.symlinkSync(victim, linked);
  fs.writeFileSync(path.join(f.directory, 'notes.jsonl'), 'unowned name');
  const existing = row(now - 1000); fs.writeFileSync(f.file(now), existing);
  f.run('service', 'register', 'telemetry-test', String(process.pid));
  try {
    assert.equal(fs.existsSync(old), false);
    assert.equal(fs.readFileSync(retained, 'utf8'), 'retained');
    const latest = fs.readdirSync(f.directory).filter(name => /^\d{4}-\d{2}-\d{2}\.jsonl$/.test(name)).sort().at(-1);
    const finished = JSON.parse(fs.readFileSync(path.join(f.directory, latest), 'utf8').trim().split('\n').at(-1));
    const cutoff = day(Date.parse(finished.ts) - 6 * 86400000);
    for (const age of [6, 7]) assert.equal(fs.existsSync(f.file(now - age * 86400000)), day(now - age * 86400000) >= cutoff);
    assert.equal(fs.readFileSync(victim, 'utf8'), 'outside telemetry');
    assert.equal(fs.lstatSync(linked).isSymbolicLink(), true);
    assert.equal(fs.readFileSync(path.join(f.directory, 'notes.jsonl'), 'utf8'), 'unowned name');
    assert(fs.readFileSync(f.file(now), 'utf8').startsWith(existing));
    assert(f.stats().accepted >= 2);
  } finally { f.run('service', 'deregister', 'telemetry-test', String(process.pid)); }
});

test('transport stats read only a bounded recent window and disclose incomplete counts', t => {
  const f = fixture(t), now = Date.now(), yesterday = now - 86400000;
  const empty = f.stats();
  assert.equal(empty.events, 0); assert.equal(empty.bytesRead, 0); assert.equal(empty.complete, true);
  fs.writeFileSync(f.file(now), row(now) + row(now + 86400000));
  fs.writeFileSync(f.file(yesterday), row(now - 3600000, 'rejected') + row(now - 86410000));
  fs.writeFileSync(f.file(now - 7 * 86400000), 'malformed expired archive\n');
  fs.writeFileSync(f.file(now + 86400000), 'malformed future archive\n');
  fs.writeFileSync(path.join(f.directory, 'other.jsonl'), 'not a daily log\n');
  const complete = f.stats();
  assert.equal(complete.events, 2); assert.equal(complete.requests, 2);
  assert.equal(complete.accepted, 1); assert.equal(complete.rejected, 1);
  assert.equal(complete.complete, true);
  fs.appendFileSync(f.file(now), '{"incomplete":');
  const partial = f.stats();
  assert.equal(partial.complete, false); assert.equal(partial.events, 2);
  assert(partial.bytesRead < 1048576);
  const line = row(now);
  fs.writeFileSync(f.file(now), 'invalid prefix\n' + line.repeat(Math.ceil(1048576 / line.length)));
  fs.writeFileSync(f.file(yesterday), 'invalid prefix\n' + row(now - 3600000, 'rejected').repeat(Math.ceil(1048576 / line.length)));
  const bounded = f.stats();
  assert.equal(bounded.complete, false);
  assert(bounded.events > 0 && bounded.events < Math.ceil(1048576 / line.length));
  assert(bounded.accepted > 0 && bounded.rejected > 0);
  assert.equal(bounded.bytesRead, 1048576);
  fs.writeFileSync(f.file(now), line + 'invalid complete record\n');
  assert.throws(f.stats);
  fs.writeFileSync(f.file(now), '{"schema":"unknown"}\n');
  assert.throws(f.stats);
  fs.unlinkSync(f.file(now));
  fs.symlinkSync(f.file(yesterday), f.file(now));
  assert.throws(f.stats);
  fs.unlinkSync(f.file(now)); fs.mkdirSync(f.file(now));
  assert.throws(f.stats, /not a regular file/);
  fs.rmdirSync(f.file(now)); execFileSync('mkfifo', [f.file(now)]);
  assert.throws(f.stats, /not a regular file/);
});
