import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { resourceBudget } from '../src/adapters/resources.mjs';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');

test('real foreground preview and message service each meet the 30-second idle CPU/RSS budget', { timeout: 120000 }, t => {
  for (const command of ['view', 'start']) {
  const home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'robin-resource-')));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const result = JSON.parse(execFileSync('python3', ['-c', String.raw`
import json, os, pathlib, pty, select, signal, subprocess, sys, time
cli, home, command = sys.argv[1:]
env = {'PATH': os.environ['PATH'], 'TERM': 'xterm-256color', 'NO_COLOR': '1'}
master, slave = pty.openpty()
proc = subprocess.Popen([cli, command, '--home', home], stdin=slave, stdout=slave, stderr=slave, env=env)
os.close(slave)
def status():
    return json.loads(subprocess.check_output([cli, 'status', '--json', '--home', home], env=env))
def drain(seconds=1):
    readable, _, _ = select.select([master], [], [], seconds)
    if readable:
        os.read(master, 65536)
        time.sleep(seconds)
def native():
    rss, clock = subprocess.check_output(['ps', '-o', 'rss=', '-o', 'time=', '-p', str(proc.pid)], text=True).split()
    elapsed = 0.0
    for component in clock.split(':'):
        elapsed = elapsed * 60 + float(component)
    return int(rss) * 1024, elapsed
try:
    deadline = time.monotonic() + 10
    while not pathlib.Path(home, 'state/robin/resources.json').exists():
        assert proc.poll() is None, 'preview exited before publishing its own usage'
        assert time.monotonic() < deadline, 'resource publication missing'
        drain()
    first = status()['resources']
    assert first['pid'] == proc.pid, 'status reported its own PID instead of the foreground process'
    initial_rss, initial_cpu = native()
    wall_start = time.monotonic()
    deadline = wall_start + 42
    peak_rss = max(first['rssBytes'], initial_rss)
    while True:
        assert proc.poll() is None, 'foreground process exited during the idle sample'
        assert time.monotonic() < deadline, 'no 30-second self-measurement'
        drain()
        record = json.loads(pathlib.Path(home, 'state/robin/resources.json').read_text())
        peak_rss = max(peak_rss, record['rssBytes'])
        if record['elapsedMs'] - first['elapsedMs'] >= 30000:
            break
    last = status()
    assert last['state'] == ('preview' if command == 'view' else 'research')
    last = last['resources']
    rss, native_cpu = native()
    window_ms = last['elapsedMs'] - first['elapsedMs']
    percent = (last['cpuMicros'] - first['cpuMicros']) / (window_ms * 10)
    os_percent = (native_cpu - initial_cpu) / (time.monotonic() - wall_start) * 100
    print(json.dumps({'pid': proc.pid, 'windowMs': window_ms, 'cpuPercent': percent, 'osCpuPercent': os_percent,
      'rssBytes': max(peak_rss, rss), 'reportedCpuPercent': last['cpuPercent'], 'sampleMs': last['sampleMs']}))
finally:
    if proc.poll() is None:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
    os.close(master)
assert proc.returncode == 0, 'preview did not exit cleanly on SIGTERM'
assert status()['resources'] is None, 'stopped process still advertised as live'
`, path.join(root, 'bin/fm-robin.sh'), home, command], { encoding: 'utf8', timeout: 55000 }));
  assert.ok(result.windowMs >= 30000);
  assert.ok(result.cpuPercent < resourceBudget.idleCpuPercent, JSON.stringify(result));
  assert.ok(result.osCpuPercent < resourceBudget.idleCpuPercent, JSON.stringify(result));
  assert.ok(result.reportedCpuPercent < resourceBudget.idleCpuPercent, JSON.stringify(result));
  assert.ok(result.rssBytes < resourceBudget.rssBytes, JSON.stringify(result));
  assert.ok(result.sampleMs >= 1000, 'no sub-second resource timer');
  console.log(`ROBIN_IDLE_BUDGET ${JSON.stringify({ command, node: process.version, platform: `${process.platform}/${process.arch}`, ...result })}`);
  }
});
