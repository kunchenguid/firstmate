import fs from 'node:fs';
import { execFileSync } from 'node:child_process';
const options = { encoding: 'utf8', timeout: 2000, stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, LC_ALL: 'C', TZ: 'UTC' } };
// Query only on startup/status, not in an idle sampling loop; birth identity rejects reused PIDs.
export function processStats(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return null;
  let text;
  try { text = execFileSync('ps', ['-p', String(pid), '-o', 'rss=', '-o', 'pcpu=', '-o', 'time=', '-o', 'stat=', '-o', 'lstart='], options); }
  catch (error) { if (error.status === 1) return null; throw Error('Process metrics unavailable; ps is required'); }
  const match = text.match(/^\s*(\d+)\s+(\d+(?:\.\d+)?)\s+((?:\d+-)?\d+(?::\d+)+(?:\.\d+)?)\s+(\S+)\s+(.+?)\s*$/);
  if (!match) throw Error('Unrecognized process metrics');
  const [, rss, cpu, time, state, birth] = match, parts = time.split('-');
  if (/^[ZX]/.test(state)) return null;
  let cpuSeconds = parts.at(-1).split(':').reduce((sum, value) => sum * 60 + Number(value), 0) + (parts.length === 2 ? Number(parts[0]) * 86400 : 0);
  let started = birth;
  if (process.platform === 'linux') {
    // Linux ps rounds CPU time to seconds; kernel ticks retain precision for idle budgets.
    let stat;
    try { stat = fs.readFileSync(`/proc/${pid}/stat`, 'utf8'); } catch (error) { if (error.code === 'ENOENT') return null; throw error; }
    const fields = stat.slice(stat.lastIndexOf(')') + 2).trim().split(/\s+/);
    const ticks = Number(execFileSync('getconf', ['CLK_TCK'], options));
    cpuSeconds = (Number(fields[11]) + Number(fields[12])) / ticks;
    started += `:${fields[19]}`;
    if (!(ticks > 0) || !Number.isFinite(cpuSeconds)) throw Error('Unrecognized kernel CPU accounting');
  }
  return { pid, rssBytes: Number(rss) * 1024, cpuPercent: Number(cpu), cpuSeconds, started, sampledAt: new Date().toISOString() };
}
