import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { setTimeout as sleep } from 'node:timers/promises';
import { loadConfig } from './config.mjs';
import { quotaSource } from './source.mjs';
import { telemetry } from './telemetry.mjs';
import { terminalRenderer, renderHistory, renderFrame } from './terminal.mjs';
import { terminal } from '../../../fm-tui-core/src/index.mjs';
import { observe, watch } from '../index.mjs';

const help = `Usage: fm-marvin.sh [status|watch|history|stats] [options]
  status       Print one frame (default). Example: fm-marvin.sh status --clean
  watch        Refresh in foreground; Ctrl+C exits. Example: fm-marvin.sh watch --refresh 60
  history      Per-pool samples from the last 7 days. Example: fm-marvin.sh history --json
  stats        Summarize telemetry from the last day. Example: fm-marvin.sh stats
Options (accepted by every verb):
  -h, --help       Show this help without credentials. Example: fm-marvin.sh watch -h
  --clean          Static aligned ASCII grid. Example: fm-marvin.sh --clean
  --json           JSON instead of terminal output. Example: fm-marvin.sh --json
  --config FILE    Pool/window settings. Example: fm-marvin.sh --config marvin.json
  --refresh N      Seconds between completed frames (1..86400; default 60). Example: fm-marvin.sh watch --refresh 30
  --frames N       Stop after N frames (watch only). Example: fm-marvin.sh watch --frames 2
  --out DIR        Export numbered frames (watch only, requires --frames). Example: fm-marvin.sh watch --frames 3 --out state/marvin/frames
                   Text --frames 3 writes 80 Unicode, 120 Unicode, and 80 ASCII review frames from one sample.
NO_COLOR disables color. FM_HOME selects the home (default repository root).
Config defaults to FM_HOME/config/marvin.json if present, otherwise module config.json.
Telemetry is written under FM_HOME/state/marvin/telemetry; no daemon or credential scraping.
`;

async function main() {
  if (process.argv.slice(2).some(arg => arg === '-h' || arg === '--help')) { process.stdout.write(help); return; }
  const { values, positionals } = parseArgs({ allowPositionals: true, options: {
    clean: { type: 'boolean' }, json: { type: 'boolean' }, config: { type: 'string' },
    refresh: { type: 'string' }, frames: { type: 'string' }, out: { type: 'string' },
  } });
  const verb = positionals[0] || 'status';
  if (positionals.length > 1 || !['status', 'watch', 'history', 'stats'].includes(verb)) throw Error('Unknown command; use -h');
  const integer = (value, max) => /^\d+$/.test(value) && Number(value) >= 1 && Number(value) <= max;
  if (values.refresh && !integer(values.refresh, 86400)) throw Error('--refresh must be an integer from 1 to 86400');
  if (values.frames && !integer(values.frames, 100000)) throw Error('--frames must be an integer from 1 to 100000');
  if ((values.frames || values.out) && verb !== 'watch') throw Error('--frames and --out require watch');
  if (values.out && !values.frames) throw Error('--out requires --frames');
  const home = process.env.FM_HOME || fileURLToPath(new URL('../../../../', import.meta.url));
  const localConfig = path.join(home, 'config/marvin.json');
  const config = loadConfig(values.config || (fs.existsSync(localConfig) ? localConfig : fileURLToPath(new URL('../../config.json', import.meta.url))));
  if (values.refresh) config.refreshSeconds = Number(values.refresh);
  const clock = { now: () => Date.now(), sleep };
  const journal = telemetry(home, clock);
  if (verb === 'history' || verb === 'stats') {
    const records = journal.read(clock.now() - (verb === 'history' ? 7 : 1) * 86400000, verb === 'history' ? 'sample' : 'all');
    const stats = { records: records.length, samples: records.filter(r => r.event === 'sample').length,
      errors: records.filter(r => r.outcome === 'error').length, cost: null, tokens: null };
    process.stdout.write(values.json ? JSON.stringify(verb === 'history' ? records.filter(r => r.event === 'sample') : stats) + '\n' :
      verb === 'history' ? renderHistory(records) : `Last 24h: ${stats.samples} samples, ${stats.errors} errors, ${stats.records} events; cost/tokens unavailable\n`);
    return;
  }
  const output = terminal();
  let index = 0;
  const review = verb === 'watch' && values.out && values.frames === '3' && !values.json;
  const renderer = terminalRenderer(output, { watch: verb === 'watch', clean: values.clean, json: values.json,
    refreshSeconds: config.refreshSeconds,
    width: () => Math.floor(Math.max(20, Math.min(299, process.stdout.columns || Number(process.env.COLUMNS) || 100))) });
  const ports = { source: quotaSource(), clock, telemetry: journal, renderer: { render(frame) {
    const cpu = process.cpuUsage();
    frame.resources = { rssBytes: process.memoryUsage.rss(), cpuPercent: (cpu.user + cpu.system) / (process.uptime() * 10000) };
    const text = renderer.render(frame);
    if (values.out) {
      fs.mkdirSync(values.out, { recursive: true, mode: 0o700 });
      if (review) {
        const variants = [[80, false], [120, false], [80, true]];
        for (const [width, ascii] of variants) {
          fs.writeFileSync(path.join(values.out, `${String(++index).padStart(4, '0')}.txt`),
            renderFrame(frame, { width, clean: ascii, refreshSeconds: config.refreshSeconds }), { mode: 0o600, flag: 'wx' });
        }
      } else {
        fs.writeFileSync(path.join(values.out, `${String(++index).padStart(4, '0')}.${values.json ? 'json' : 'txt'}`), text, { mode: 0o600, flag: 'wx' });
      }
    }
  } } };
  // No raw mode or hidden cursor: default SIGINT terminates both polling and child reads.
  if (verb === 'watch') await watch(ports, config, review ? 1 : values.frames ? Number(values.frames) : Infinity);
  else await observe(ports, config);
}
main().catch(error => { process.stderr.write(`marvin: ${error.message}\n`); process.exitCode = 1; });
