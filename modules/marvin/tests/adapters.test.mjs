import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawn } from 'node:child_process';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';
import { validateConfig } from '../src/adapters/config.mjs';
import { quotaSource, validateSnapshot } from '../src/adapters/source.mjs';
import { telemetry } from '../src/adapters/telemetry.mjs';
import { renderFrame, terminalRenderer } from '../src/adapters/terminal.mjs';
import { classify } from '../src/index.mjs';
import { provider } from './fakes.mjs';
const cli = fileURLToPath(new URL('../../../bin/fm-marvin.sh', import.meta.url));
function fixture(t) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'quota-test-'));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const data = { ...provider, windows: provider.windows.map(w => ({ ...w, resetsAt: new Date(Date.now() + 86400000).toISOString() })) };
  fs.writeFileSync(path.join(home, 'snapshot.json'), JSON.stringify({ schemaVersion: 5, providers: [data] }));
  fs.writeFileSync(path.join(home, 'quota-axi'), `#!${process.execPath}\nconst fs = require('node:fs');\nfs.appendFileSync(process.env.FM_HOME + '/calls', JSON.stringify({args:process.argv.slice(2), codex:process.env.CODEX_HOME})+'\\n');\nprocess.stdout.write(fs.readFileSync(process.env.FM_HOME + '/snapshot.json'));\n`, { mode: 0o700 });
  return { home, env: { ...process.env, FM_HOME: home, PATH: `${home}:${process.env.PATH}`, NO_COLOR: '1' },
    run(args, env = {}) { return execFileSync(cli, args, { encoding: 'utf8', env: { ...this.env, ...env } }); } };
}

test('CLI composes executable source, pace, render, JSONL and seven-day history', t => {
  const f = fixture(t);
  const frame = JSON.parse(f.run(['status', '--json']));
  assert.equal(frame.pools[0].tags[0], 'HOT');
  assert.ok(frame.resources.rssBytes > 0);
  assert.ok(Number.isFinite(frame.resources.cpuPercent));
  const calls = fs.readFileSync(path.join(f.home, 'calls'), 'utf8');
  assert.match(calls, /--json.*--full.*--no-credential-refresh/);
  const cleanFrame = f.run(['--clean']);
  assert.match(cleanFrame, /7D ALL\s+##------\s+36%\s+-14%/);
  assert.match(cleanFrame, /1 pools \| 1 over pace \| 0 unavailable \| 0 identity mismatch/);
  assert.match(cleanFrame, /private@example.test/);
  assert.match(cleanFrame, /\[RESET (?:23h59m|1d0h)\]/);
  assert.doesNotMatch(f.run(['--clean']), /\x1b|▓|░/);
  const history = JSON.parse(f.run(['history', '--json']));
  assert.equal(history.length, 3);
  assert.equal(history[0].pools[0].windows[0].remaining, 36);
  assert.doesNotMatch(JSON.stringify(history), /private@example/);
  assert.match(f.run(['stats']), /3 samples, 0 errors, 15 events/);
  assert.equal(fs.readFileSync(path.join(f.home, 'calls'), 'utf8').trim().split('\n').length, 3);
});

test('every help path is credential-free and invalid flags/config have no side effects', t => {
  const f = fixture(t);
  for (const verb of ['', 'status', 'watch', 'history', 'stats']) for (const flag of ['-h', '--help']) {
    assert.match(f.run([...(verb ? [verb] : []), flag]), /Usage: fm-marvin.sh/);
  }
  for (const args of [['watch', '--refresh', '0'], ['watch', '--refresh', 'nan'], ['watch', '--frames', '-1'], ['watch', '--out', 'x'], ['oops']]) {
    assert.throws(() => f.run(args), /Command failed/);
  }
  assert.equal(fs.existsSync(path.join(f.home, 'calls')), false);
  assert.equal(fs.existsSync(path.join(f.home, 'state')), false);
  assert.throws(() => validateConfig({ pools: [], refreshSeconds: 60, mystery: true }));
  assert.throws(() => validateConfig({ pools: [{ id: 'a', provider: 'codex', env: { PATH: '/evil' } }], refreshSeconds: 60 }));
  assert.throws(() => validateConfig({ pools: [{ id: 'a', provider: 'codex' }, { id: 'a', provider: 'codex' }], refreshSeconds: 60 }));
});

test('multi-account source uses configured homes and labels without credential parsing', async t => {
  const f = fixture(t);
  const records = await quotaSource(f.env).read([{ id: 'one', provider: 'claude', env: { CODEX_HOME: '/account-one' } }, { id: 'two', provider: 'claude' }]);
  assert.deepEqual(records.map(row => row.id), ['one', 'two']);
  const calls = fs.readFileSync(path.join(f.home, 'calls'), 'utf8').trim().split('\n').map(JSON.parse);
  assert.equal(calls[0].codex, '/account-one');
  assert.deepEqual(calls[0].args.slice(-2), ['--provider', 'claude']);
});

test('malformed source becomes unavailable rather than a plausible empty report', async t => {
  const f = fixture(t);
  assert.throws(() => validateSnapshot({ schemaVersion: 4, providers: [] }));
  assert.throws(() => validateSnapshot({ schemaVersion: 5, providers: [{ ...provider, account: { email: 42 } }] }));
  assert.throws(() => validateSnapshot({ schemaVersion: 5, providers: [{ ...provider, label: {} }] }));
  assert.throws(() => validateSnapshot({ schemaVersion: 5, providers: [{ ...provider, quotaSemantics: { effectiveAvailability: [null] } }] }));
  fs.writeFileSync(path.join(f.home, 'snapshot.json'), '{broken');
  const rows = await quotaSource(f.env).read([]);
  assert.equal(classify(rows, Date.now()).counts.unavailable, 1);
  fs.writeFileSync(path.join(f.home, 'snapshot.json'), JSON.stringify({ schemaVersion: 5, providers: [] }));
  assert.match((await quotaSource(f.env).read([]))[0].error, /invalid/);
});

test('six pools use three fixed columns at 100 and two at 80 with aligned metrics', () => {
  const now = Date.parse('2026-09-11T00:00:00Z');
  const inputs = Array.from({ length: 6 }, (_, i) => ({ id: `p${i}`, label: `POOL ${i}`, data: {
    ...provider, account: { email: `user${i}@example.test` }, windows: Array.from({ length: [3, 1, 1, 2, 2, 2][i] }, (_, j) => ({ ...provider.windows[0], id: `w${j}` })),
  } }));
  const frame = classify(inputs, now);
  for (const [width, height, headingRows] of [[100, 30, 2], [80, 24, 3]]) {
    const text = renderFrame(frame, { width });
    assert.ok(text.trimEnd().split('\n').length <= height, text);
    assert.ok(text.split('\n').every(line => line.length <= width), text);
    assert.equal(text.split('\n').filter(line => line.includes('POOL')).length, headingRows);
    for (let i = 0; i < 6; i++) assert.match(text, new RegExp(`POOL ${i}`));
    assert.match(text, /▓|░/);
    const lines = text.trimEnd().split('\n');
    const firstLimit = lines[3];
    assert.equal(firstLimit.indexOf('▓'), 12);
    assert.equal(firstLimit.indexOf('▓', 20), 46);
    assert.equal(firstLimit.indexOf('36%'), 22);
    assert.equal(firstLimit.indexOf('-14%'), 27);
    assert.equal(lines[0].indexOf('POOL 1'), 34);
    assert.equal(lines[1].indexOf('36%'), 14);
    assert.match(lines.at(-2), /^6 pools \| 6 over pace \| 0 unavailable \| 0 identity mismatch \| 0 duplicate$/);
    assert.match(lines.at(-1), /MARVIN.*LEFT.*PACE.*2026-09-11T00:00:00.000Z/);
    const ascii = renderFrame(frame, { width, clean: true, color: true });
    assert.equal(ascii.split('\n').length, text.split('\n').length);
    assert.equal(ascii.split('\n')[0].indexOf('POOL 1'), 34);
    assert.match(ascii, /##------\s+36%\s+-14%/);
    assert.doesNotMatch(ascii, /[^\x20-\x7e\n]/);
  }
  frame.pools[0].email = '\x1b[2J\nforged';
  assert.doesNotMatch(renderFrame(frame), /\x1b/);
  assert.match(renderFrame(frame, { color: true }), /\x1b\[38;5;222m\[HOT\]/);
});

test('dense menus grow vertically without hiding limits, identities or warnings', () => {
  const names = ['claude', 'codex', 'codex', 'cursor', 'kimi', 'grok'];
  const inputs = names.map((name, i) => ({ id: `p${i}`, label: `POOL ${i}`, expectedEmail: `expected${i}@example.test`, data: {
    ...provider, provider: name, account: { email: name === 'codex' ? 'shared@example.test' : `expected${i}@example.test` },
    windows: Array.from({ length: i === 3 ? 4 : 3 }, (_, j) => ({ ...provider.windows[0], id: `w${j}` })),
  } }));
  const frame = classify(inputs, Date.parse('2026-09-11T00:00:00Z'));
  assert.equal(frame.counts.mismatch, 2);
  assert.equal(frame.counts.duplicate, 2);
  const text = renderFrame(frame, { width: 80 });
  assert.ok(text.split('\n').every(line => line.length <= 80), text);
  assert.equal((text.match(/7D ALL/g) || []).length, 19);
  assert.equal((text.match(/shared@example.test/g) || []).length, 2);
  assert.equal((text.match(/\[RESET 1d0h\]/g) || []).length, 6);
  assert.match(text, /DUPLICATE ACCOUNT/);
  assert.match(text, /IDENTITY MISMATCH/);
});

test('grid retains unknown states and sanitizes long external fields at every width', () => {
  const frame = classify([{ id: 'offline', data: { provider: 'offline', windows: [] } },
    { id: 'unknown', data: { ...provider, windows: [{ id: 'api', label: 'API QUOTA', percentRemaining: 0 }] } }], Date.now());
  frame.pools[0].label = 'LONG\x1b[2J\nNAME'.repeat(8);
  frame.pools[0].email = '界\taccount@example.test'.repeat(8);
  frame.pools[0].plan = '\x1b[32m' + 'plan'.repeat(20);
  for (const width of [20, 32, 67, 80, 100, 299]) for (const ascii of [false, true]) {
    const text = renderFrame(frame, { width, clean: ascii });
    assert.ok(text.split('\n').every(line => line.length <= width), text);
    assert.doesNotMatch(text, /\x1b|\t|界/);
    assert.match(text, /\[UNAVAILABLE\]/);
    assert.match(text, /\[PACE UNKNOWN\]/);
    assert.match(text, /\?{12}/);
    assert.match(text, /\[RESET \?\]/);
    if (width >= 32) assert.match(text, /API\s+[-░]{8}\s+0%\s+\?/);
  }
  const empty = renderFrame(classify([], Date.now()));
  assert.match(empty, /No quota pools configured or discovered/);
  assert.match(empty, /0 pools \| 0 over pace/);
});

test('static and TTY styling agree while clean and NO_COLOR retain a readable grid', () => {
  const now = Date.parse('2026-09-11T00:00:00Z');
  const frame = classify([{ id: 'hot', data: provider }, { id: 'under', data: {
    ...provider, account: { email: 'other@example.test' }, windows: [{ ...provider.windows[0], percentRemaining: 70 }],
  } }], now);
  const colored = renderFrame(frame, { color: true });
  assert.match(colored, /\x1b\[38;5;222m\[HOT\]/);
  assert.match(colored, /\x1b\[38;5;141m\[UNDER\]/);
  assert.match(colored, /\x1b\[38;5;245mprivate@example.test/);
  assert.equal(colored.replace(/\x1b\[[0-9;]*m/g, '').trimEnd(), renderFrame(frame).trimEnd());
  const writes = [];
  const renderer = terminalRenderer({ tty: true, color: true, write: text => writes.push(text) }, { watch: true, width: () => 100 });
  assert.equal(renderer.render(frame), renderFrame(frame));
  assert.match(writes.join(''), /\x1b\[38;5;141m\[UNDER\]/);
  assert.match(writes.join(''), /\x1b\[38;5;222m\[HOT\]/);
  writes.length = 0;
  terminalRenderer({ tty: true, color: true, write: text => writes.push(text) }, { clean: true, width: () => 100 }).render(frame);
  assert.equal(writes.join(''), renderFrame(frame, { clean: true }));
  assert.doesNotMatch(writes.join(''), /[^\x20-\x7e\n]/);
  writes.length = 0;
  terminalRenderer({ tty: false, color: false, write: text => writes.push(text) }, { width: () => 100 }).render(frame);
  assert.equal(writes.join(''), renderFrame(frame));
});

test('TTY watch emits only changed cells and stays silent for unchanged quota evidence', () => {
  const writes = [];
  let width = 100;
  const renderer = terminalRenderer({ tty: true, color: false, write: text => writes.push(text) }, { watch: true, width: () => width });
  const frame = classify([{ id: 'one', data: provider }], Date.parse('2026-09-11T00:00:00Z'));
  renderer.render(frame);
  assert.match(writes.join(''), /\x1b\[2J/);
  writes.length = 0;
  renderer.render({ ...frame, ts: '2026-09-11T00:01:00Z', resources: { rssBytes: 123 } });
  assert.deepEqual(writes, []);
  frame.pools[0].remaining = 20;
  renderer.render(frame);
  assert.ok(writes.length > 0);
  assert.doesNotMatch(writes.join(''), /\x1b\[2J|\x1b\[38;/);
  writes.length = 0; width = 80;
  renderer.render(frame);
  assert.match(writes.join(''), /\x1b\[2J/);
});

test('history excludes expired/future records and tolerates only an incomplete tail', t => {
  const f = fixture(t), now = Date.parse('2026-09-11T00:00:00Z');
  let instant = now - 8 * 86400000;
  const journal = telemetry(f.home, { now: () => instant });
  journal.append('sample'); instant = now; journal.append('sample');
  instant = now + 86400000; journal.append('sample'); instant = now;
  const file = path.join(f.home, 'state/marvin/telemetry/2026-09-11.jsonl');
  fs.appendFileSync(file, '{partial');
  assert.equal(journal.read(now - 7 * 86400000).length, 1);
  fs.appendFileSync(file, '\n');
  assert.throws(() => journal.read(now - 7 * 86400000), /Malformed telemetry/);
});

test('telemetry caps daily growth and prunes dates outside the history horizon', t => {
  const f = fixture(t);
  let now = Date.parse('2026-09-01T00:00:00Z');
  const journal = telemetry(f.home, { now: () => now });
  journal.append('sample');
  now += 10 * 86400000;
  for (let i = 0; i < 800; i++) journal.append('sample', { padding: 'x'.repeat(1024) });
  const directory = path.join(f.home, 'state/marvin/telemetry');
  assert.deepEqual(fs.readdirSync(directory), ['2026-09-11.jsonl']);
  const file = path.join(directory, '2026-09-11.jsonl');
  assert.ok(fs.statSync(file).size <= 512 * 1024);
  assert.ok(journal.read(now - 86400000).length > 0);
});

test('bounded watch exports two distinct frames; SIGINT interrupts a sleeping watch', async t => {
  const f = fixture(t);
  const directory = path.join(f.home, 'frames');
  f.run(['watch', '--refresh', '1', '--frames', '2', '--out', directory, '--json']);
  const first = JSON.parse(fs.readFileSync(path.join(directory, '0001.json')));
  const second = JSON.parse(fs.readFileSync(path.join(directory, '0002.json')));
  assert.ok(Date.parse(second.ts) > Date.parse(first.ts));
  const child = spawn(cli, ['watch', '--refresh', '60', '--json'], { env: f.env, stdio: ['ignore', 'pipe', 'pipe'] });
  t.after(() => child.kill('SIGKILL'));
  const exit = once(child, 'exit');
  await once(child.stdout, 'data');
  child.kill('SIGINT');
  const [, signal] = await exit;
  assert.equal(signal, 'SIGINT');
});
