import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { plain } from '../../fm-tui-core/src/index.mjs';
import { scene } from '../src/core/scene.mjs';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const cli = path.join(root, 'bin/fm-robin.sh');
function home(t) { const directory = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'robin-cli-'))); t.after(() => fs.rmSync(directory, { recursive: true, force: true })); return directory; }

test('all help forms list every verb, option and example without home or credentials', () => {
  for (const command of ['', 'start', 'status', 'stats', 'view', 'demo']) for (const flag of ['-h', '--help']) {
    const output = execFileSync(cli, [...(command ? [command] : []), flag], { encoding: 'utf8', env: { PATH: process.env.PATH } });
    for (const expected of ['start', 'status', 'stats', 'view', 'demo', '--home', '--config', '--once', '--json', '--clean', '--no-ui', '--frames', '--out', '--help']) assert.ok(output.includes(expected));
    assert.equal(output.split('\n').filter(line => line.includes('Example:')).length, 15);
  }
});
test('fake-backed CLI demo writes a sourced knowledge report, not live message state', t => {
  const directory = home(t);
  const result = JSON.parse(execFileSync(cli, ['demo', '--home', directory], { encoding: 'utf8' }));
  assert.equal(result.demo, true); assert.equal(result.verdict, 'supported');
  assert.match(fs.readFileSync(path.join(directory, result.report), 'utf8'), /independent/);
  assert.ok(!fs.existsSync(path.join(directory, 'state/.wake-queue')));
  assert.ok(!fs.existsSync(path.join(directory, 'state/supervisor.inbox')));
  assert.equal(spawnSync(cli, ['demo', '--home', directory]).status, 1);
});
test('invalid configuration and unready live adapters refuse before registration', t => {
  const directory = home(t), config = JSON.parse(fs.readFileSync(path.join(root, 'modules/fm-robin/config.json')));
  config.enabledAdapters = ['fetch'];
  fs.writeFileSync(path.join(directory, 'enabled.json'), JSON.stringify(config));
  assert.equal(spawnSync(cli, ['start', '--once', '--home', directory, '--config', path.join(directory, 'enabled.json')]).status, 1);
  assert.deepEqual(fs.readdirSync(directory), ['enabled.json']);
  fs.writeFileSync(path.join(directory, 'bad.json'), '{"unknown":true}');
  assert.equal(spawnSync(cli, ['start', '--home', directory, '--config', path.join(directory, 'bad.json')]).status, 1);
  assert.deepEqual(fs.readdirSync(directory).sort(), ['bad.json', 'enabled.json']);
});
test('frame exports are deterministic, bounded and do not overwrite; clean/NO_COLOR have no escapes', t => {
  const directory = home(t), frames = path.join(directory, 'frames');
  execFileSync(cli, ['view', '--frames', '16', '--out', frames]);
  assert.equal(fs.readdirSync(frames).length, 16);
  assert.equal(fs.readFileSync(path.join(frames, '000.txt'), 'utf8'), plain(scene()));
  assert.equal(fs.readFileSync(path.join(frames, '014.txt'), 'utf8'), plain(scene()));
  assert.notEqual(fs.readFileSync(path.join(frames, '015.txt'), 'utf8'), plain(scene()));
  assert.equal(spawnSync(cli, ['view', '--frames', '1', '--out', frames]).status, 1);
  assert.equal(spawnSync(cli, ['view', '--frames', '999', '--out', path.join(directory, 'bad')]).status, 1);
  assert.ok(!fs.existsSync(path.join(directory, 'bad')));
  const output = execFileSync(cli, ['view', '--clean'], { encoding: 'utf8', env: { ...process.env, NO_COLOR: '1' } });
  assert.ok(!output.includes('\x1b')); assert.ok(output.includes('ROBIN / RESEARCH'));
});
test('scene represents only supplied activity; idle frames never invent source work', () => {
  const idle = plain(scene()), busy = plain(scene({ phase: 'retrieving', fetches: 1, queue: 2 }));
  assert.ok(idle.includes('queue=?')); assert.ok(busy.includes('queue=2'));
  assert.notEqual(idle, busy);
  assert.ok(!plain(scene({ phase: '\x1b[31mexternal' })).includes('\x1b'));
});
