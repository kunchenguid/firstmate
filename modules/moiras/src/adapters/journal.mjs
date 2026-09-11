import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { createInterface } from 'node:readline';
import { processStats } from './resources.mjs';
const segmentBytes = 1048576;
export function json(file) {
  let fd;
  try {
    if (!fs.lstatSync(file).isFile()) throw Error('Moiras record is not a regular file');
    fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    if (fs.fstatSync(fd).size > 1048576) throw Error('Moiras record exceeds 1 MiB');
    try { return JSON.parse(fs.readFileSync(fd, 'utf8')); } catch { throw Error('Malformed Moiras record'); }
  } catch (e) { if (e.code === 'ENOENT') return null; throw e; }
  finally { if (fd !== undefined) fs.closeSync(fd); }
}
/** @returns {import('../ports/io').Journal} */
export function journal(home) {
  const root = fs.realpathSync(home), dir = path.join(root, 'state/moiras');
  for (const name of ['state', 'state/moiras', 'state/moiras/events', 'state/moiras/telemetry']) {
    const target = path.join(root, name);
    if (!fs.existsSync(target)) fs.mkdirSync(target, { mode: 0o700 });
    if (!fs.lstatSync(target).isDirectory() || fs.lstatSync(target).isSymbolicLink()) throw Error('Unsafe Moiras directory');
  }
  const file = key => {
    if (!/^(?:snapshot|quiet|episodes|replies)\.json$|^events\/[a-f0-9]{24}\.json(?:\.(?:sent|delivery))?$/.test(key)) throw Error('Invalid journal key');
    const target = path.join(dir, key);
    if (fs.realpathSync(path.dirname(target)) !== path.dirname(target)) throw Error('Unsafe journal directory');
    return target;
  };
  const set = (key, value) => {
    const target = file(key), tmp = `${target}.${randomUUID()}.tmp`, text = JSON.stringify(value) + '\n';
    if (Buffer.byteLength(text) > 1048576) throw Error('Moiras record exceeds 1 MiB');
    if (fs.existsSync(target) && fs.lstatSync(target).isSymbolicLink()) throw Error('Unsafe journal record');
    fs.writeFileSync(tmp, text, { mode: 0o600, flag: 'wx' });
    try { fs.renameSync(tmp, target); } finally { if (fs.existsSync(tmp)) fs.unlinkSync(tmp); }
  };
  let retainedDay;
  return { get: key => json(file(key)), set,
    resources() {
      const lock = path.join(dir, 'running');
      if (!fs.existsSync(lock)) return null;
      if (!fs.lstatSync(lock).isDirectory()) throw Error('Unsafe server lease');
      const owner = json(path.join(lock, 'owner.json'));
      if (!owner || typeof owner !== 'object') return null;
      const sample = processStats(owner.pid);
      return sample?.started === owner.started ? sample : null;
    },
    claim() {
      const sample = processStats(process.pid);
      if (!sample) throw Error('Cannot identify server process');
      const lock = path.join(dir, 'running'), owner = { id: randomUUID(), pid: sample.pid, started: sample.started };
      try { fs.mkdirSync(lock, { mode: 0o700 }); } catch { throw Error('Moiras lock exists or is unavailable; inspect before retrying'); }
      fs.writeFileSync(path.join(lock, 'owner.json'), JSON.stringify(owner), { mode: 0o600, flag: 'wx' });
      let released = false;
      return () => { if (released) return; if (fs.realpathSync(lock) !== lock || JSON.stringify(json(path.join(lock, 'owner.json'))) !== JSON.stringify(owner)) throw Error('Moiras lock changed; not removed'); fs.unlinkSync(path.join(lock, 'owner.json')); fs.rmdirSync(lock); released = true; };
    },
    append(record) {
      if (!/^\d{4}-\d\d-\d\dT/.test(record.ts) || !Number.isFinite(Date.parse(record.ts))) throw Error('Unsafe telemetry time');
      const day = record.ts.slice(0, 10), logs = path.join(dir, 'telemetry'), target = path.join(logs, `${day}.jsonl`);
      if (fs.realpathSync(logs) !== logs) throw Error('Unsafe telemetry path');
      const text = JSON.stringify(record) + '\n', bytes = Buffer.byteLength(text);
      if (bytes > segmentBytes) throw Error('Telemetry record exceeds 1 MiB');
      if (retainedDay !== day) {
        const cutoff = new Date(Date.parse(day) - 86400000).toISOString().slice(0, 10);
        for (const name of fs.readdirSync(logs)) if (/^\d{4}-\d\d-\d\d(?:\.1)?\.jsonl$/.test(name) && name.slice(0, 10) < cutoff) {
          const old = path.join(logs, name);
          if (!fs.lstatSync(old).isFile()) throw Error('Unsafe expired telemetry file');
          fs.unlinkSync(old);
        }
        retainedDay = day;
      }
      const open = () => fs.openSync(target, fs.constants.O_APPEND | fs.constants.O_CREAT | fs.constants.O_WRONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK, 0o600);
      let fd = open();
      try {
        const stat = fs.fstatSync(fd);
        if (!stat.isFile() || stat.size > segmentBytes) throw Error('Telemetry segment exceeds budget; archive it before retrying');
        // ponytail: rotation across CLI/server writers is best-effort; serialize if lossless telemetry is required.
        if (stat.size + bytes > segmentBytes) {
          fs.closeSync(fd); fd = undefined;
          const backup = path.join(logs, `${day}.1.jsonl`);
          if (fs.existsSync(backup) && !fs.lstatSync(backup).isFile()) throw Error('Unsafe telemetry backup');
          fs.renameSync(target, backup); fd = open();
        }
        fs.writeFileSync(fd, text);
      } finally { if (fd !== undefined) fs.closeSync(fd); }
    },
    async stats(now) {
      const days = [...new Set([now, now - 86400].map(t => new Date(t * 1000).toISOString().slice(0, 10)))];
      const result = { events: 0, requests: 0, errors: 0, tokens: null, cost: null, unknownCosts: 0, durationMs: 0, rotated: false }, requests = new Set();
      for (const day of days) for (const suffix of ['', '.1']) {
        const target = path.join(dir, 'telemetry', `${day}${suffix}.jsonl`);
        if (!fs.existsSync(target)) continue;
        if (fs.realpathSync(target) !== target || !fs.lstatSync(target).isFile()) throw Error('Unsafe telemetry file');
        if (fs.statSync(target).size > segmentBytes) throw Error('Telemetry segment exceeds budget; stats incomplete');
        if (suffix) result.rotated = true;
        const stream = fs.createReadStream(target, { flags: fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW });
        try { for await (const line of createInterface({ input: stream, crlfDelay: Infinity })) {
          let row; try { row = JSON.parse(line); } catch { throw Error('Malformed telemetry row; stats incomplete'); }
          const at = Date.parse(row.ts) / 1000;
          if (!Number.isFinite(at)) throw Error('Malformed telemetry time');
          if (at < now - 86400 || at > now) continue;
          result.events++; if (row.requestId) requests.add(row.requestId); if (row.outcome === 'error') result.errors++;
          result.durationMs += Object.values(row.stepsMs ?? {}).reduce((sum, ms) => sum + ms, 0);
          if (row.event === 'reason.exit') { if (row.cost === null) result.unknownCosts++; else result.cost = (result.cost ?? 0) + row.cost; if (row.tokens !== null) result.tokens = (result.tokens ?? 0) + row.tokens; }
        } } finally { stream.destroy(); }
      }
      result.requests = requests.size; return result;
    },
  };
}
