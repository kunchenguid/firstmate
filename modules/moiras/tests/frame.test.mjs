import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { frame, plainStatus } from '../src/core/frame.mjs';
import { plain, diff } from '../../fm-tui-core/src/index.mjs';
import { toolRoot } from '../src/adapters/config.mjs';
import { run } from '../src/adapters/command.mjs';
test('one eye, long idle holds and continuous diff redraw at both review sizes', () => {
  for (const [width, height] of [[100, 30], [80, 24]]) {
    let before, still = 0, positions = new Set();
    for (let ms = 0; ms < 24000; ms += 250) {
      const grid = frame({}, ms, width, height), text = plain(grid), delta = diff(before, grid, false);
      assert.equal([...text.matchAll(/◉/g)].length, 1); positions.add(text.indexOf('◉'));
      assert.ok(!delta.includes('\x1b[2J')); assert.ok(!/\x1b\[[0-9;]*m/.test(delta));
      if (!delta) still++; before = grid;
    }
    assert.ok(still > 60, `only ${still} quiet frames`); assert.ok(positions.size >= 15);
  }
});
test('reviewed arc stays among the hoods, and a seeded idle beat moves only one prop', () => {
  const choices = new Set();
  for (const width of [100, 80]) {
    for (let ms = 6000; ms <= 8000; ms += 250) {
      const row = plain(frame({}, ms, width, 30)).split('\n').findIndex(line => line.includes('◉'));
      assert.ok(row >= 4 && row <= 6, `eye entered row ${row}`);
    }
    for (let idleSeed = 0; idleSeed < 20; idleSeed++) {
      const crop = (ms, n) => plain(frame({ idleSeed }, ms, width, 30)).split('\n').slice(7, 13).map(row => row.slice(Math.floor(width * n / 3), Math.floor(width * (n + 1) / 3))).join('\n');
      const moved = [0, 1, 2].filter(n => crop(1000, n) !== crop(3500, n));
      assert.equal(moved.length, 1); choices.add(moved[0]);
      assert.deepEqual([0, 1, 2].filter(n => crop(1000, n) !== crop(3000, n)), moved, 'idle beat must survive one-second sampling');
      for (const n of [0, 1, 2]) assert.equal(crop(1000, n), crop(4000, n));
    }
  }
  assert.equal(choices.size, 3);
  const finding = { id: '123456789012345678901234', rule: 'repeat-failure', task: 'sample', default: 'inspect' };
  assert.match(plain(frame({ findings: [finding] })), /\? 12345678  repeat-failure/);
  assert.ok(!plain(frame({ findings: [finding] })).includes(finding.id));
  assert.ok(plainStatus({ findings: [finding] }).includes(finding.id));
  assert.match(plain(frame({ workers: [{ id: 'sample', harness: 'pi', model: 'x', effort: 'medium', busy: 'busy', age: 3600, last: 'working: wait' }], findings: [{ ...finding, rule: 'busy-but-silent' }] })), /⚠️/);
});
test('CLI reasoning honors the home harness policy before invoking a model', async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'moiras-policy-')), sentinel = path.join(home, 'invoked');
  for (const dir of ['config', 'state', 'bin']) fs.mkdirSync(path.join(home, dir));
  fs.writeFileSync(path.join(home, 'config/disabled-adapters'), 'pi\n');
  fs.writeFileSync(path.join(home, 'state/sample.meta'), 'harness=pi\nmodel=example\n');
  fs.writeFileSync(path.join(home, 'state/sample.status'), 'working: checks\n');
  fs.writeFileSync(path.join(home, 'bin/pi'), '#!/bin/sh\nprintf x > "$MOIRAS_SENTINEL"\nexit 9\n', { mode: 0o700 });
  try {
    await assert.rejects(run(path.join(toolRoot, 'bin/fm-moiras.sh'), ['reason', 'clotho', 'sample'], {
      env: { ...process.env, FM_HOME: home, FM_CONFIG_OVERRIDE: path.join(home, 'config'), MOIRAS_SENTINEL: sentinel, PATH: `${home}/bin:${process.env.PATH}` }, timeout: 10000,
    }), /disabled/);
    assert.ok(!fs.existsSync(sentinel), 'disabled harness was invoked');
    fs.writeFileSync(path.join(home, 'config/disabled-adapters'), '');
    const response = JSON.stringify({ type: 'message_end', message: { role: 'assistant', stopReason: 'stop', content: [{ type: 'text', text: 'MOIRAS|observe|sample is busy' }] } });
    fs.writeFileSync(path.join(home, 'bin/pi'), `#!/bin/sh\nprintf x > "$MOIRAS_SENTINEL"\nprintf '%s\\n' '${response}'\n`, { mode: 0o700 });
    const enabled = await run(path.join(toolRoot, 'bin/fm-moiras.sh'), ['reason', 'clotho', 'sample'], {
      env: { ...process.env, FM_HOME: home, FM_CONFIG_OVERRIDE: path.join(home, 'config'), MOIRAS_SENTINEL: sentinel, PATH: `${home}/bin:${process.env.PATH}` }, timeout: 10000,
    });
    assert.equal(enabled.stdout, 'MOIRAS|observe|sample is busy\n'); assert.ok(fs.existsSync(sentinel));
  } finally { fs.rmSync(home, { recursive: true, force: true }); }
});
test('CLI help works on every verb without a home; clean preview is ASCII and complete', async () => {
  const cli = path.join(toolRoot, 'bin/fm-moiras.sh');
  for (const verb of ['start', 'status', 'stats', 'reason']) {
    const { stdout } = await run(cli, [verb, '-h'], { env: { ...process.env, FM_HOME: '/nonexistent-moiras-home' } });
    assert.equal((stdout.match(/Example: fm-moiras/g) ?? []).length, 16); assert.match(stdout, /--at-ms/); assert.match(stdout, /-h \/ --help/);
  }
  await assert.rejects(run(cli, ['reason', 'clotho', 'sample', '--no-llm'], { env: { ...process.env, FM_HOME: '/nonexistent-moiras-home' } }), /explicit model permission/);
  const { stdout } = await run(cli, ['--demo', '--clean'], { env: { ...process.env, NO_COLOR: '' } });
  assert.equal((await run(cli, ['--demo'], { env: { ...process.env, NO_COLOR: '' } })).stdout, stdout);
  assert.match(stdout, /DEMONSTRATION/); assert.match(stdout, /render-thread/); assert.match(stdout, /check-seam/); assert.match(stdout, /^[\x20-\x7e\n]*$/);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'moiras-frames-'));
  try {
    const env = { ...process.env }; delete env.NO_COLOR;
    await run(cli, ['--demo', '--frames', '24', '--out', dir], { env });
    assert.equal(fs.readdirSync(dir).length, 24);
    const id = stdout.match(/([a-f0-9]{24}) repeat-failure:/)?.[1];
    assert.ok(id && id !== 'a'.repeat(24));
    assert.ok(fs.readFileSync(path.join(dir, '000.txt'), 'utf8').includes(`? ${id.slice(0, 8)}  repeat-failure`));
    await assert.rejects(run(cli, ['--demo', '--frames', '24', '--out', dir]));
    const target = path.join(dir, 'target'), link = path.join(dir, 'link');
    fs.mkdirSync(target); fs.symlinkSync(target, link);
    await assert.rejects(run(cli, ['--demo', '--frames', '24', '--out', link])); assert.deepEqual(fs.readdirSync(target), []);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
  assert.ok(!plainStatus({ workers: [{ id: '\x1b', model: 'token=hidden', last: 'x' }] }).includes('hidden'));
});
