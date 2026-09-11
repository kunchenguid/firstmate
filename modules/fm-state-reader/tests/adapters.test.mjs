import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { files, snapshot, publishEvent } from '../src/index.mjs';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const home = () => { const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fm-modules-')); fs.mkdirSync(path.join(dir, 'state')); return fs.realpathSync(dir); };
test('real filesystem adapter composes with snapshot, watches events and rejects private paths', async () => {
  const dir = home(); let close;
  try {
    fs.writeFileSync(path.join(dir, 'state/a.meta'), 'harness=pi\nmodel=small');
    const source = files(dir), now = Date.now() / 1000; assert.equal(snapshot(source, now).workers[0].harness, 'pi');
    assert.throws(() => source.read('state/a.meta/../../.pi/auth.json'), /allow-list/);
    fs.symlinkSync(path.join(dir, 'state/a.meta'), path.join(dir, 'state/b.meta')); assert.equal(source.read('state/b.meta'), null); assert.equal(snapshot(source, now).workers.length, 1);
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(Error('watch event missing')), 5000);
      close = source.watch(error => { clearTimeout(timer); error ? reject(error) : resolve(); });
      fs.writeFileSync(path.join(dir, 'state/a.status'), 'working: changed');
    });
    assert.equal(snapshot(source, now).workers[0].last, 'working: changed');
    fs.writeFileSync(path.join(dir, 'state/a.status'), '0123456789'); assert.equal(files(dir, { maxBytes: 5 }).read('state/a.status').text, '56789');
  } finally { close?.(); fs.rmSync(dir, { recursive: true, force: true }); }
});
test('real module event uses registered capture and wake, never changes the original task', async () => {
  const dir = home(), id = '0123456789abcdef01234567', previous = process.env.FM_PROCEVENT_CLAIM_ROOT;
  process.env.FM_PROCEVENT_CLAIM_ROOT = path.join(dir, 'claims');
  try {
    const taskFile = path.join(dir, 'state/a.status'); fs.writeFileSync(taskFile, 'working: untouched\n');
    fs.mkdirSync(path.join(dir, 'state/example/events'), { recursive: true });
    fs.writeFileSync(path.join(dir, `state/example/events/${id}.json`), JSON.stringify({ id, rule: 'example', evidence: ['test only'] }) + '\n');
    const { source } = await publishEvent({ home: dir, root, module: 'example', id });
    const result = fs.readFileSync(path.join(dir, `state/procevent-inbox/${source}.1.result`), 'utf8');
    assert.match(result, /test only/); assert.match(fs.readFileSync(path.join(dir, 'state/.wake-queue'), 'utf8'), /procevent fm-state-reader example-/);
    assert.equal(fs.readFileSync(taskFile, 'utf8'), 'working: untouched\n');
    await assert.rejects(publishEvent({ home: dir, root, module: '../escape', id }), /Invalid/);
    await assert.rejects(publishEvent({ home: dir, root: dir, module: 'example', id }), /register failed: ENOENT/);
  } finally { if (previous === undefined) delete process.env.FM_PROCEVENT_CLAIM_ROOT; else process.env.FM_PROCEVENT_CLAIM_ROOT = previous; fs.rmSync(dir, { recursive: true, force: true }); }
});
