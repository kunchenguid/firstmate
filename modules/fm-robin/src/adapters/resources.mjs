import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { homeFiles } from './files.mjs';

export const resourceBudget = { rssBytes: 60_000_000, idleCpuPercent: 1, sampleMs: 5000 };
const recordPath = 'state/robin/resources.json';
const ownerPath = 'state/robin/resources.owner';

// The foreground process reports itself; status never substitutes its own usage.
// The application owns sampling timers and signal cleanup.
export function resourceMonitor(home, mode) {
  if (!['preview', 'research'].includes(mode)) throw Error('invalid_resource_mode');
  const io = homeFiles(home), generation = randomUUID();
  const owner = io.file(ownerPath);
  fs.mkdirSync(path.dirname(owner), { recursive: true, mode: 0o700 });
  fs.writeFileSync(owner, generation, { flag: 'wx', mode: 0o600 });
  const started = process.hrtime.bigint();
  let lastTime = started, lastCpu = process.cpuUsage(), first = true;
  return {
    sample() {
      const at = process.hrtime.bigint(), cpu = process.cpuUsage();
      const elapsedMs = Number(at - lastTime) / 1e6;
      const cpuMicros = cpu.user + cpu.system;
      const cpuPercent = first ? null : (cpuMicros - lastCpu.user - lastCpu.system) / (elapsedMs * 10);
      const record = { pid: process.pid, generation, mode, sampledAt: new Date().toISOString(), elapsedMs: Number(at - started) / 1e6,
        sampleMs: first ? null : elapsedMs, cpuMicros, rssBytes: process.memoryUsage.rss(), cpuPercent, budget: resourceBudget };
      io.write(recordPath, JSON.stringify(record) + '\n');
      lastTime = at; lastCpu = cpu; first = false;
      return record;
    },
    close() {
      if (io.read(ownerPath, 100) !== generation) throw Error('resource_owner_changed');
      const record = io.read(recordPath, 4096);
      if (record !== null) {
        if (JSON.parse(record).generation !== generation) throw Error('resource_record_changed');
        fs.unlinkSync(io.file(recordPath));
      }
      fs.unlinkSync(io.file(ownerPath));
    },
  };
}

export function resources(home) {
  const io = homeFiles(home), raw = io.read(recordPath, 4096);
  if (raw === null) return { state: 'stopped', resources: null, budget: resourceBudget };
  const record = JSON.parse(raw);
  if (!record || typeof record !== 'object' || Object.keys(record).some(key => !['pid', 'generation', 'mode', 'sampledAt', 'elapsedMs', 'sampleMs', 'cpuMicros', 'rssBytes', 'cpuPercent', 'budget'].includes(key)) ||
    !Number.isInteger(record.pid) || record.pid < 2 || !['preview', 'research'].includes(record.mode) ||
    !Number.isFinite(record.rssBytes) || record.rssBytes <= 0 || !Number.isFinite(record.cpuMicros) ||
    (record.cpuPercent !== null && (!Number.isFinite(record.cpuPercent) || record.cpuPercent < 0)) ||
    !Number.isFinite(Date.parse(record.sampledAt)) || io.read(ownerPath, 100) !== record.generation) throw Error('invalid_resource_record');
  record.budget = resourceBudget;
  let live = false;
  try { process.kill(record.pid, 0); live = true; } catch (error) { if (error.code !== 'ESRCH') throw error; }
  if (!live || Date.now() - Date.parse(record.sampledAt) > resourceBudget.sampleMs * 3) return { state: 'stale', resources: null, budget: resourceBudget };
  return { state: record.mode, resources: record, budget: resourceBudget };
}
