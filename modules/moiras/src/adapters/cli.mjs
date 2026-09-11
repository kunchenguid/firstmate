#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { parseArgs } from 'node:util';
import { display, terminal, plain } from '../../../fm-tui-core/src/index.mjs';
import { thread, measure, serviceId } from '../core/findings.mjs';
import { frame, plainStatus } from '../core/frame.mjs';
import { config, defaultConfig, toolRoot } from './config.mjs';
import { state } from './state.mjs';
import { forge } from './forge.mjs';
import { journal } from './journal.mjs';
import { telemetry } from './telemetry.mjs';
import { observe } from './service.mjs';
import { reasoner } from './reason.mjs';
import { explain } from '../usecases/explain.mjs';
import { run } from './command.mjs';
const flags = {
  help: ['boolean', 'Show every verb and flag without starting or needing credentials', '-h'],
  json: ['boolean', 'Status as JSON, including the running server PID, RSS and CPU (null when unavailable)', 'status --json'],
  config: ['string', 'Configuration JSON file (default: modules/moiras/config.json)', '--config settings.json'],
  'no-ui': ['boolean', 'Run the observer with plain event lines, without animation', 'start --no-ui'],
  clean: ['boolean', 'Print every task once in ASCII, with no animation or escapes (also when NO_COLOR is set)', 'start --clean'],
  'no-llm': ['boolean', 'Forbid reasoning; start/status never invoke models regardless', 'start --no-llm'],
  demo: ['boolean', 'Preview the approved scene with synthetic data and no observer', 'start --demo'],
  frames: ['string', 'Export 1-600 numbered frames without starting a service', '--demo --frames 24 --out frames'],
  out: ['string', 'New frame output directory; existing frame files are not overwritten', '--frames 24 --out frames'],
  width: ['string', 'Preview width in cells (20-300, default terminal width or 100)', '--demo --frames 24 --out frames --width 80'],
  height: ['string', 'Preview height in rows (8-120, default terminal height or 30)', '--demo --frames 24 --out frames --height 24'],
  'at-ms': ['string', 'Frame-export scene start in milliseconds (default 4000, near eye transfer)', '--demo --frames 24 --out frames --at-ms 0'],
};
const options = Object.fromEntries(Object.entries(flags).map(([name, [type]]) => [name, { type, ...(name === 'help' ? { short: 'h' } : {}) }]));
const { values: opt, positionals } = parseArgs({ options, allowPositionals: true });
const clean = opt.clean || process.env.NO_COLOR !== undefined;
const help = () => ['Moiras - manual, advisory terminal observer', ...[
  ['start', 'Start the foreground observer; Ctrl+C stops it', 'start --no-llm'],
  ['status', 'Print a fresh all-task snapshot once', 'status'],
  ['stats', 'Summarize retained local telemetry from the last 24 hours', 'stats'],
  ['reason ROLE TASK', 'Explicitly spend one bounded model call; print an advisory, never act or publish it', 'reason clotho example-task'],
].map(([verb, text, example]) => `${verb}: ${text}\n  Example: fm-moiras ${example}`),
...Object.entries(flags).map(([name, [, text, example]]) => `${name === 'help' ? '-h / ' : ''}--${name}: ${text}\n  Example: fm-moiras ${example}`)].join('\n') + '\n';
const integer = (v, fallback, min, max) => { const n = Number(v ?? fallback); if (!Number.isInteger(n) || n < min || n > max) throw Error(`Expected integer ${min}..${max}`); return n; };
const dimensions = () => [integer(opt.width, Math.max(20, Math.min(300, process.stdout.columns ?? 100)), 20, 300), integer(opt.height, Math.max(8, Math.min(120, process.stdout.rows ?? 30)), 8, 120)];
const demo = { demo: true, now: 0, prs: [], beaconAge: 12, used: 2, capacity: 8, workers: [
  { id: 'render-thread', harness: 'pi', model: 'small', effort: 'low', busy: 'busy', age: 1080, last: 'working: tests are running', lines: [] },
  { id: 'check-seam', harness: 'codex', model: 'default', effort: 'medium', busy: 'idle', age: 3120, last: 'blocked: repeated test failure', lines: Array(3).fill('FAIL adapter contract') },
], facts: ['DEMONSTRATION | pool 2/8 | load 1.4 | beacon 12s'] };
async function main() {
  if (opt.help) { process.stdout.write(help()); return; }
  const verb = positionals[0] ?? 'start';
  if (!['start', 'status', 'stats', 'reason'].includes(verb) || (verb === 'reason' ? positionals.length !== 3 : positionals.length > 1)) throw Error('Use start, status, stats or reason ROLE TASK; -h lists all options');
  if (verb === 'reason' && (opt['no-llm'] || opt.demo || opt.frames !== undefined)) throw Error('reason requires real evidence and explicit model permission; remove --no-llm, --demo and --frames');
  if (opt.json && (verb !== 'status' || opt.demo || opt.frames !== undefined)) throw Error('--json is only supported by real status');
  dimensions();
  const home = opt.demo ? toolRoot : fs.realpathSync(process.env.FM_HOME ?? toolRoot), configFile = path.resolve(opt.config ?? defaultConfig), c = config(configFile);
  if (opt.demo) demo.findings = measure(demo, c);
  const store = opt.demo ? null : journal(home), audit = store && telemetry(store, randomUUID());
  const emit = text => audit ? audit.step('terminal.write', () => process.stdout.write(text), [], Buffer.byteLength(text)) : process.stdout.write(text);
  const snapshot = async signal => {
    if (opt.demo) return demo;
    let prs = [], failure = c.repositories.length ? '' : 'PRs: unconfigured';
    try { prs = await audit.step('forge.read', () => forge.read(c.repositories, signal), c.repositories); } catch { failure = 'Forge unavailable; PR findings withheld'; }
    const data = thread(await audit.step('state.read', () => state(home, c.poolFiles).read(Date.now() / 1000)), prs, failure);
    return { ...data, findings: measure(data, c) };
  };
  if (verb === 'stats') { if (!store) throw Error('stats needs a real home, not --demo'); emit(JSON.stringify(await audit.step('telemetry.stats', () => store.stats(Date.now() / 1000)), null, 2) + '\n'); return; }
  if (opt.frames !== undefined) {
    if (!opt.out) throw Error('--frames requires --out');
    const count = integer(opt.frames, 24, 1, 600), at = integer(opt['at-ms'], 4000, 0, 86400000), data = await snapshot();
    fs.mkdirSync(opt.out, { recursive: true }); if (fs.lstatSync(opt.out).isSymbolicLink()) throw Error('Symlinked frame output directory');
    for (let i = 0; i < count; i++) fs.writeFileSync(path.join(opt.out, `${String(i).padStart(3, '0')}.txt`), clean ? plainStatus(data) : plain(frame(data, at + i * 250, ...dimensions())), { flag: 'wx' });
    return;
  }
  if (verb === 'status') {
    const data = await snapshot();
    emit(opt.json ? JSON.stringify({ ...data, server: await audit.step('process.read', () => store.resources()) }) + '\n' : plainStatus(data)); return;
  }
  if (verb === 'reason') {
    const controller = new AbortController(), cancel = () => controller.abort();
    process.once('SIGINT', cancel); process.once('SIGTERM', cancel);
    try {
      if (Object.hasOwn(c.roles, positionals[1])) await audit.step('harness.validate',
        () => run(path.join(toolRoot, 'bin/fm-harness.sh'), ['validate', c.roles[positionals[1]].harness],
          { env: { ...process.env, FM_HOME: home }, signal: controller.signal, timeout: 10000 }), [c.roles[positionals[1]].harness]);
      const result = await explain({ reasoner: reasoner(configFile, { signal: controller.signal }), audit }, c.roles, positionals[1], positionals[2], await snapshot(controller.signal));
      emit(result.text + '\n');
    } finally { process.removeListener('SIGINT', cancel); process.removeListener('SIGTERM', cancel); }
    return;
  }
  let observer, timer, view, closing = false, lastSize = '', staticPrinted = false;
  const native = terminal(), port = { ...native, write: text => closing ? native.write(text) : emit(text), tty: native.tty && process.env.TERM !== 'dumb', color: native.color && process.env.TERM !== 'dumb' };
  const controller = new AbortController();
  const restore = () => { clearInterval(timer); view?.close(); };
  const stop = async () => { if (closing) return; closing = true; controller.abort(); try { await observer?.stop(); } finally { restore(); } };
  process.once('SIGINT', stop); process.once('SIGTERM', stop); process.once('exit', () => { closing = true; restore(); });
  try {
    if (!opt.demo) emit(`Moiras reads ${home}/state; writes state/moiras and registered events. No task actions. Startup registers the shared ${serviceId} channel.\n`);
    observer = opt.demo ? { data: () => demo, stop: async () => {} } : await observe({ home, root: toolRoot, configFile, signal: controller.signal, notify: text => { if (!view?.animated && !closing) emit(text + '\n'); } });
    if (closing) { await observer.stop(); return; }
    const started = performance.now(), idleSeed = randomUUID();
    const draw = () => {
      const size = dimensions(), key = size.join('x'), data = observer.data();
      if (key !== lastSize) { view?.close(); view = display(port, { clean, noUi: opt['no-ui'] || size[0] < 76 }); lastSize = key; staticPrinted = false; }
      if (view.animated) view.draw(frame({ ...data, idleSeed, renderNow: data.demo ? data.now : Date.now() / 1000 }, performance.now() - started, ...size));
      else if (!staticPrinted) { emit(plainStatus(data)); staticPrinted = true; }
    };
    draw(); if (view.animated) timer = setInterval(() => { try { draw(); } catch { void stop(); process.exitCode = 1; } }, 1000);
  } catch (error) { await stop(); throw error; }
}
main().catch(error => { console.error(`Moiras: ${error.message}`); process.exitCode = 1; });
