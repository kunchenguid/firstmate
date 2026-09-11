import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { once } from 'node:events';
import { setTimeout as sleep } from 'node:timers/promises';
const cli = fileURLToPath(new URL('../../../bin/fm-marvin.sh', import.meta.url));

// Explicit opt-in contacts the installed, credentialed quota-axi and measures a real idle process.
test('real quota stack stays below 60 MB RSS and 1% idle CPU over 30 seconds', {
  skip: process.env.FM_MARVIN_LIVE !== '1' ? 'set FM_MARVIN_LIVE=1 for live quota-axi and 30-second idle measurement' : false,
  timeout: 60000,
}, async t => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'quota-live-'));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const child = spawn(cli, ['watch', '--refresh', '60', '--json'], {
    env: { ...process.env, FM_HOME: home }, stdio: ['ignore', 'pipe', 'pipe'],
  });
  t.after(() => child.kill('SIGKILL'));
  const exit = once(child, 'exit');
  let text = '';
  for await (const chunk of child.stdout) {
    text += chunk;
    if (text.includes('\n')) break;
  }
  const frame = JSON.parse(text.trim().split('\n')[0]);
  assert.ok(frame.pools.some(pool => pool.windows.some(row => row.delta !== null)), 'requires measured live windows, not unavailable-only success');
  assert.ok(frame.resources.rssBytes < 60_000_000);
  assert.ok(Number.isFinite(frame.resources.cpuPercent));
  const usage = () => {
    const [rss, cpu] = execFileSync('ps', ['-o', 'rss=', '-o', 'time=', '-p', String(child.pid)], { encoding: 'utf8' }).trim().split(/\s+/);
    const seconds = cpu.split(':').reduce((sum, part) => sum * 60 + Number(part), 0);
    return { rssBytes: Number(rss) * 1024, cpuSeconds: seconds };
  };
  const before = usage(), start = performance.now();
  await sleep(30000);
  const after = usage(), elapsed = (performance.now() - start) / 1000;
  const cpuPercent = (after.cpuSeconds - before.cpuSeconds) / elapsed * 100;
  assert.ok(cpuPercent < 1, `idle CPU ${cpuPercent}%`);
  assert.ok(after.rssBytes < 60_000_000, `RSS ${after.rssBytes}`);
  console.log(`RESOURCE_BUDGET rssBytes=${after.rssBytes} idleCpuPercent=${cpuPercent.toFixed(3)} elapsedSeconds=${elapsed.toFixed(2)}`);
  child.kill('SIGINT');
  await exit;
});
