import fs from 'node:fs';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';

const requestId = id => {
  if (!/^msg-[a-f0-9]{32}$/.test(id)) throw Error('invalid_request_id');
  return id;
};
export function homeFiles(home) {
  home = fs.realpathSync(home);
  if (home === path.parse(home).root) throw Error('unsafe_home');
  const file = relative => {
    const target = path.resolve(home, relative);
    if (!target.startsWith(`${home}${path.sep}`)) throw Error('unsafe_path');
    let current = home;
    for (const part of path.relative(home, target).split(path.sep)) {
      current = path.join(current, part);
      try { if (fs.lstatSync(current).isSymbolicLink()) throw Error('symlink_refused'); }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
    }
    return target;
  };
  const read = (relative, limit = 1048576) => {
    const target = file(relative);
    try {
      const fd = fs.openSync(target, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
      try {
        const stat = fs.fstatSync(fd);
        if (!stat.isFile() || stat.size > limit) throw Error('oversized_or_nonfile');
        return fs.readFileSync(fd, 'utf8');
      } finally { fs.closeSync(fd); }
    } catch (error) { if (error.code === 'ENOENT') return null; throw error; }
  };
  const write = (relative, content, immutable = false) => {
    const target = file(relative);
    fs.mkdirSync(path.dirname(target), { recursive: true, mode: 0o700 });
    file(relative);
    if (immutable) {
      const existing = read(relative);
      if (existing !== null) { if (existing !== content) throw Error('immutable_conflict'); return; }
    }
    const temporary = `${target}.${randomUUID()}.tmp`;
    const fd = fs.openSync(temporary, 'wx', 0o600);
    try { fs.writeFileSync(fd, content); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
    try {
      if (immutable) { fs.linkSync(temporary, target); fs.unlinkSync(temporary); }
      else fs.renameSync(temporary, target);
      const directory = fs.openSync(path.dirname(target), 'r');
      try { fs.fsyncSync(directory); } finally { fs.closeSync(directory); }
    } finally { if (fs.existsSync(temporary)) fs.unlinkSync(temporary); }
  };
  return { home, file, read, write };
}

export const telemetryLimits = { days: 7, fileBytes: 512 * 1024, recordBytes: 16 * 1024 };
export function fileStore(home) {
  const io = homeFiles(home);
  let prunedDay;
  const recordPath = id => `state/robin/requests/${requestId(id)}.json`;
  const materialize = (id, record) => {
    if (!/^data\/knowledge\/[a-z][a-z0-9-]{0,63}\/msg-[a-f0-9]{32}\.md$/.test(record.report) || !record.report.endsWith(`/${id}.md`) || typeof record.markdown !== 'string' || Buffer.byteLength(record.markdown) > 262144 || !/^[a-f0-9]{24}$/.test(record.eventId)) throw Error('invalid_record');
    io.write(record.report, record.markdown, true);
    io.write(`state/robin/events/${record.eventId}.json`, JSON.stringify({ id: record.eventId, type: 'robin.brief', requestId: id, requester: record.requester, report: record.report, verdict: record.verdict }) + '\n', true);
    return record;
  };
  return {
    io,
    async load(id) {
      const raw = io.read(recordPath(id));
      return raw === null ? null : materialize(id, JSON.parse(raw));
    },
    async save(id, record) { io.write(recordPath(id), JSON.stringify(record) + '\n'); },
    async finish(id, topic, markdown, result) {
      requestId(id);
      if (!/^[a-z][a-z0-9-]{0,63}$/.test(topic) || Buffer.byteLength(markdown) > 262144) throw Error('invalid_report');
      const record = { ...result, report: `data/knowledge/${topic}/${id}.md`, markdown, eventId: createHash('sha256').update(id).digest('hex').slice(0, 24) };
      // Journal before materializing: load repairs a crash between these writes.
      io.write(recordPath(id), JSON.stringify(record) + '\n', true);
      return materialize(id, record);
    },
    async log(row) {
      if (!/^\d{4}-\d{2}-\d{2}T/.test(row.ts) || !Number.isFinite(Date.parse(row.ts))) throw Error('invalid_telemetry_date');
      const day = row.ts.slice(0, 10), content = JSON.stringify(row) + '\n';
      if (Buffer.byteLength(content) > telemetryLimits.recordBytes) throw Error('telemetry_record_too_large');
      const relative = `state/robin/telemetry/${day}.jsonl`;
      const target = io.file(relative), directory = path.dirname(target);
      fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
      if (prunedDay !== day) {
        const cutoff = new Date(Date.parse(`${day}T00:00:00Z`) - (telemetryLimits.days - 1) * 86400000).toISOString().slice(0, 10);
        for (const name of fs.readdirSync(directory)) {
          if (/^\d{4}-\d{2}-\d{2}\.jsonl$/.test(name) && name.slice(0, 10) < cutoff) {
            const old = io.file(`state/robin/telemetry/${name}`);
            if (fs.lstatSync(old).isFile()) fs.unlinkSync(old);
          }
        }
        prunedDay = day;
      }
      const fd = fs.openSync(io.file(relative), fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_APPEND | fs.constants.O_NOFOLLOW, 0o600);
      try {
        if (fs.fstatSync(fd).size + Buffer.byteLength(content) > telemetryLimits.fileBytes) {
          fs.ftruncateSync(fd, 0);
          fs.writeFileSync(fd, JSON.stringify({ ...row, event: 'telemetry.truncated', reasons: ['daily_byte_cap'], counters: {} }) + '\n');
        }
        fs.writeFileSync(fd, content); fs.fsyncSync(fd);
      } finally { fs.closeSync(fd); }
    },
    lock() {
      const directory = io.file('state/robin/run.lock');
      fs.mkdirSync(path.dirname(directory), { recursive: true, mode: 0o700 });
      try { fs.mkdirSync(directory, { mode: 0o700 }); } catch (error) { if (error.code === 'EEXIST') throw Error('already_running_or_stale_lock'); throw error; }
      const inode = fs.statSync(directory).ino;
      fs.writeFileSync(path.join(directory, 'pid'), `${process.pid}\n`, { flag: 'wx', mode: 0o600 });
      return () => {
        if (fs.statSync(io.file('state/robin/run.lock')).ino !== inode) throw Error('lock_replaced');
        fs.unlinkSync(path.join(directory, 'pid')); fs.rmdirSync(directory);
      };
    },
  };
}

export function stats(home, now = Date.now()) {
  const io = homeFiles(home), counts = { requests: 0, supported: 0, unverified: 0, errors: 0, fetches: 0, malformed: 0, truncated: false, tokens: null, cost: null };
  for (const time of [now - 86400000, now]) {
    const date = new Date(time).toISOString().slice(0, 10);
    for (const line of (io.read(`state/robin/telemetry/${date}.jsonl`, 4194304) ?? '').split('\n').filter(Boolean)) {
      let row; try { row = JSON.parse(line); } catch { counts.malformed++; continue; }
      const at = Date.parse(row.ts);
      if (!Number.isFinite(at)) { counts.malformed++; continue; }
      if (at < now - 86400000 || at > now) continue;
      if (row.event === 'telemetry.truncated') { counts.truncated = true; continue; }
      if (row.outcome === 'error') counts.errors++;
      if (row.event === 'retrieval.enter') counts.fetches++;
      if (row.event === 'request.exit') { counts.requests++; if (row.outcome === 'accepted') counts.supported++; else counts.unverified++; }
    }
  }
  return counts;
}
