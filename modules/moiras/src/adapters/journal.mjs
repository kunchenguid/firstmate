import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { createInterface } from 'node:readline';
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
    if (!/^(?:snapshot|quiet|episodes|replies)\.json$|^events\/[a-f0-9]{24}\.json(?:\.sent)?$/.test(key)) throw Error('Invalid journal key');
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
  return { get: key => json(file(key)), set,
    claim() {
      const lock = path.join(dir, 'running'), owner = randomUUID();
      try { fs.mkdirSync(lock, { mode: 0o700 }); } catch { throw Error('Moiras lock exists or is unavailable; inspect before retrying'); }
      fs.writeFileSync(path.join(lock, 'owner.json'), JSON.stringify(owner), { mode: 0o600, flag: 'wx' });
      let released = false;
      return () => { if (released) return; if (fs.realpathSync(lock) !== lock || json(path.join(lock, 'owner.json')) !== owner) throw Error('Moiras lock changed; not removed'); fs.unlinkSync(path.join(lock, 'owner.json')); fs.rmdirSync(lock); released = true; };
    },
    append(record) {
      const target = path.join(dir, 'telemetry', `${record.ts.slice(0, 10)}.jsonl`);
      if (!/^\d{4}-\d\d-\d\dT/.test(record.ts) || fs.realpathSync(path.dirname(target)) !== path.dirname(target)) throw Error('Unsafe telemetry path');
      const fd = fs.openSync(target, fs.constants.O_APPEND | fs.constants.O_CREAT | fs.constants.O_WRONLY | fs.constants.O_NOFOLLOW, 0o600);
      try { fs.writeFileSync(fd, JSON.stringify(record) + '\n'); } finally { fs.closeSync(fd); }
    },
    async stats(now) {
      const days = [...new Set([now, now - 86400].map(t => new Date(t * 1000).toISOString().slice(0, 10)))];
      const result = { events: 0, requests: 0, errors: 0, tokens: null, cost: null, unknownCosts: 0, durationMs: 0 }, requests = new Set();
      for (const day of days) {
        const target = path.join(dir, 'telemetry', `${day}.jsonl`);
        if (!fs.existsSync(target)) continue;
        if (fs.realpathSync(target) !== target || !fs.lstatSync(target).isFile()) throw Error('Unsafe telemetry file');
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
