import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { configuration } from '../core/research.mjs';
import { scene } from '../core/scene.mjs';
import { fileStore, homeFiles, stats } from './files.mjs';
import { resourceMonitor, resources, resourceBudget } from './resources.mjs';
import { serve } from './service.mjs';
import { research } from '../usecases/research.mjs';
import { display, terminal, plain } from '../../../fm-tui-core/src/index.mjs';

const moduleRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
export const help = `Usage: fm-robin.sh <command> [options]
  start                 Run research manually in the foreground. Example: start --once
  status                Print runtime and its own sampled RSS/CPU. Example: status --json --home ./home
  stats                 Summarize the last 24 hours of telemetry. Example: stats --home ./home
  view                  View the calm scene without research. Example: view --clean
  demo                  Run synthetic research with fakes, never network. Example: demo --home ./empty-home
  --home DIR            Existing operational home (default: FM_HOME). Example: stats --home ./home
  --config FILE         JSON config (default: HOME/config/robin/config.json, then module defaults). Example: start --config ./robin.json
  --once                Process at most one request, then exit. Example: start --once
  --json                Explicit machine-readable status/stats. Example: status --json --home ./home
  --clean               Static scene; no animation. Example: view --clean
  --no-ui               Suppress animation. Example: start --no-ui
  --frames N            Export 1-64 deterministic scene frames. Example: view --frames 16 --out ./frames
  --out DIR             New directory for frame exports. Example: view --frames 16 --out ./frames
  -h, --help            Show every command and option without side effects. Example: start -h
NO_COLOR disables color; redirected view output is static. Example: NO_COLOR=1 fm-robin.sh view --clean
Start registers only its own foreground process as robin; it never auto-starts, schedules, or retires other services.
Live retrieval remains unready; enabled live adapters are refused before registration.
`;

export function loadConfig(home, override) {
  const io = homeFiles(home);
  const candidate = override ? path.resolve(override) : io.file('config/robin/config.json');
  const configFile = fs.existsSync(candidate) ? candidate : override ? candidate : path.join(moduleRoot, 'config.json');
  if (fs.lstatSync(configFile).isSymbolicLink() || fs.statSync(configFile).size > 65536) throw Error('invalid_config_file');
  return { config: configuration(JSON.parse(fs.readFileSync(configFile, 'utf8'))), base: path.dirname(configFile) };
}

async function main(args) {
  if (args.includes('-h') || args.includes('--help') || !args.length) { process.stdout.write(help); return; }
  const { values, positionals } = parseArgs({ args, allowPositionals: true, options: {
    home: { type: 'string' }, config: { type: 'string' }, once: { type: 'boolean' }, clean: { type: 'boolean' }, json: { type: 'boolean' },
    'no-ui': { type: 'boolean' }, frames: { type: 'string' }, out: { type: 'string' },
  } });
  if (positionals.length !== 1 || !['start', 'status', 'stats', 'view', 'demo'].includes(positionals[0])) throw Error('unknown_command');
  const verb = positionals[0];
  if ((values.frames || values.out) && verb !== 'view') throw Error('frames_require_view');
  if (values.once && verb !== 'start') throw Error('once_requires_start');
  if (values.json && !['status', 'stats'].includes(verb)) throw Error('json_requires_status_or_stats');
  if (verb === 'view') {
    if (values.frames || values.out) {
      const count = Number(values.frames);
      if (!Number.isInteger(count) || count < 1 || count > 64 || !values.out) throw Error('invalid_frame_export');
      fs.mkdirSync(values.out, { mode: 0o700 });
      for (let index = 0; index < count; index++) fs.writeFileSync(path.join(values.out, `${String(index).padStart(3, '0')}.txt`), plain(scene({}, index)), { flag: 'wx', mode: 0o600 });
      process.stdout.write(`Exported ${count} frames.\n`); return;
    }
    const view = display(terminal(), { clean: values.clean, noUi: values['no-ui'] });
    let tick = 0, monitor, blinking = false;
    const idleFrame = scene(), blinkFrame = scene({}, 15);
    view.draw(idleFrame);
    if (!view.animated) { view.close(); return; }
    try {
      const home = values.home ?? process.env.FM_HOME;
      monitor = home ? resourceMonitor(home, 'preview') : null;
      monitor?.sample();
      await new Promise((resolve, reject) => {
        const stop = error => {
          clearInterval(frames); clearInterval(samples);
          process.off('SIGINT', close); process.off('SIGTERM', close);
          error ? reject(error) : resolve();
        };
        const close = () => stop();
        const frames = setInterval(() => {
          try {
            const next = ++tick % 4 === 3;
            if (next !== blinking) { view.draw(next ? blinkFrame : idleFrame); blinking = next; }
          } catch (error) { stop(error); }
        }, 2000);
        const samples = monitor ? setInterval(() => {
          try { monitor.sample(); } catch (error) { stop(error); }
        }, resourceBudget.sampleMs) : undefined;
        process.on('SIGINT', close); process.on('SIGTERM', close);
      });
    } finally { view.close(); monitor?.close(); }
    return;
  }
  const home = values.home ?? process.env.FM_HOME;
  if (!home) throw Error('home_required');
  if (verb === 'status' || verb === 'stats') {
    const counts = stats(home);
    process.stdout.write(JSON.stringify(verb === 'stats' ? counts : { ...resources(home), liveResearchReady: false, requestLock: fs.existsSync(homeFiles(home).file('state/robin/run.lock')), ...counts }) + '\n'); return;
  }
  const loaded = loadConfig(home, values.config);
  if (verb === 'start') {
    // Shared admission is ready; the separate retrieval safety gate is not.
    if (loaded.config.enabledAdapters.length) throw Error('retrieval_unready');
    const controller = new AbortController(), stop = () => controller.abort();
    process.on('SIGINT', stop); process.on('SIGTERM', stop);
    try {
      const result = await serve({ home, root: path.resolve(moduleRoot, '../..'), config: loaded.config, retrieval: {}, reasoner: null,
        once: values.once, signal: controller.signal, ready: () => process.stdout.write('Robin ready; live retrieval remains disabled.\n') });
      if (result) process.stdout.write(JSON.stringify(result) + '\n');
    } finally { process.off('SIGINT', stop); process.off('SIGTERM', stop); }
    return;
  }
  if (!values.home) throw Error('demo_requires_explicit_home');
  const { fakes, config } = await import('../../tests/fakes.mjs');
  const ports = fakes(); ports.store = fileStore(home);
  if (fs.existsSync(ports.store.io.file('state/robin'))) throw Error('demo_requires_unused_robin_state');
  const unlock = ports.store.lock();
  try { process.stdout.write(JSON.stringify({ demo: true, ...await research(ports, config) }) + '\n'); }
  finally { unlock(); }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).catch(() => { process.stderr.write('Robin refused the operation; check configuration, admission, and documented limits.\n'); process.exitCode = 1; });
}
