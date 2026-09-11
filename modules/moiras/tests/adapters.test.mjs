import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { journal } from '../src/adapters/journal.mjs';
import { state } from '../src/adapters/state.mjs';
import { forge } from '../src/adapters/forge.mjs';
test('real journal and shared reader compose without changing task records', async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'moiras-module-'));
  try {
    const store = journal(home), release = store.claim(); assert.throws(() => store.claim(), /lock/);
    fs.writeFileSync(path.join(home, 'state/sample.meta'), 'harness=pi\n');
    assert.equal(state(home).read(1000).workers[0].harness, 'pi');
    store.set('snapshot.json', { known: true }); assert.deepEqual(store.get('snapshot.json'), { known: true });
    assert.throws(() => store.set('../sample.meta', {}), /key/);
    fs.symlinkSync(path.join(home, 'state/sample.meta'), path.join(home, 'state/moiras/quiet.json'));
    assert.throws(() => store.set('quiet.json', {}), /Unsafe/);
    const row = { ts: new Date(1000 * 1000).toISOString(), requestId: 'request', event: 'state.exit', outcome: 'accepted', stepsMs: { state: 4 } };
    store.append(row); store.append({ ...row, event: 'publish.exit', outcome: 'error' });
    const stats = await store.stats(1001); assert.equal(stats.requests, 1); assert.equal(stats.events, 2); assert.equal(stats.errors, 1); assert.equal(stats.cost, null);
    assert.equal(fs.readFileSync(path.join(home, 'state/sample.meta'), 'utf8'), 'harness=pi\n'); release(); release();
  } finally { fs.rmSync(home, { recursive: true, force: true }); }
});
test('forge adapter validates its real executable output and closes stdin', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'moiras-forge-')), previous = process.env.PATH;
  const pr = { url: 'https://github.com/example/repo/pull/1', head: 'fm/sample', state: 'open', created: '2026-09-11', merged: null, proof: true };
  try {
    fs.writeFileSync(path.join(dir, 'gh-axi'), `#!${process.execPath}\nprocess.stdin.resume(); process.stdin.on('end', () => console.log(${JSON.stringify('p1: ' + JSON.stringify(JSON.stringify(pr)))}));\n`, { mode: 0o700 });
    process.env.PATH = `${dir}${path.delimiter}${previous}`;
    assert.deepEqual(await forge.read(['example/repo']), [pr]);
    await assert.rejects(forge.read(['../escape']), /Invalid repository/);
    fs.writeFileSync(path.join(dir, 'gh-axi'), `#!${process.execPath}\nconsole.log('truncated');\n`);
    await assert.rejects(forge.read(['example/repo']), /Unexpected or truncated/);
  } finally { process.env.PATH = previous; fs.rmSync(dir, { recursive: true, force: true }); }
});
