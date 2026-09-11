import fs from 'node:fs';
import path from 'node:path';
const allowed = /^(?:state\/(?:[\w.-]+\.(?:meta|status|busy-state|busy-gen)|\.last-watcher-beat|\.wake-queue)|data\/(?:routing-outcomes|review-outcomes)\.jsonl)$/;
/** @returns {import('../ports/files').StateFiles} */
export function files(home, { poolFiles = [], maxBytes = 65536 } = {}) {
  if (!Number.isInteger(maxBytes) || maxBytes < 1 || maxBytes > 1048576) throw Error('Invalid read limit');
  const root = fs.realpathSync(home), pools = poolFiles.map((_, i) => `pool:${i}`);
  const targets = new Map(pools.map((key, i) => [key, path.resolve(root, poolFiles[i])]));
  const ordinary = key => {
    if (!allowed.test(key)) throw Error('Read outside the public state allow-list');
    const target = path.join(root, key);
    if (fs.existsSync(path.dirname(target)) && fs.lstatSync(path.dirname(target)).isSymbolicLink()) throw Error('Symlinked state directory');
    return target;
  };
  return {
    pools,
    taskIds() {
      ordinary('state/probe.meta');
      try { return fs.readdirSync(path.join(root, 'state'), { withFileTypes: true }).filter(entry => entry.isFile() && /^[\w.-]+\.meta$/.test(entry.name)).map(entry => entry.name.slice(0, -5)).sort(); }
      catch (e) { if (e.code === 'ENOENT') return []; throw e; }
    },
    watch(changed) {
      const filters = new Map([[path.join(root, 'state'), name => allowed.test(`state/${name}`)], [path.join(root, 'data'), name => allowed.test(`data/${name}`)]]);
      for (const target of targets.values()) {
        const dir = path.dirname(target), prior = filters.get(dir);
        filters.set(dir, name => name === path.basename(target) || !!prior?.(name));
      }
      const watchers = [];
      try {
        for (const [dir, accepts] of filters) {
          if (!fs.existsSync(dir)) continue;
          if (fs.lstatSync(dir).isSymbolicLink()) throw Error('Symlinked watch directory');
          watchers.push(fs.watch(dir, (_, name) => { if (!name || accepts(String(name))) changed(); }).on('error', changed));
        }
      } catch (e) { watchers.forEach(w => w.close()); throw e; }
      return () => watchers.forEach(w => w.close());
    },
    read(key) {
      const target = targets.get(key) ?? ordinary(key);
      let fd;
      try {
        if (!fs.lstatSync(target).isFile()) return null;
        fd = fs.openSync(target, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
        const stat = fs.fstatSync(fd), bytes = Buffer.alloc(Math.min(stat.size, maxBytes));
        const count = fs.readSync(fd, bytes, 0, bytes.length, Math.max(0, stat.size - maxBytes));
        return { text: bytes.subarray(0, count).toString(), at: stat.mtimeMs / 1000, truncated: stat.size > maxBytes };
      } catch (e) { if (['ENOENT', 'ELOOP'].includes(e.code)) return null; throw e; }
      finally { if (fd !== undefined) fs.closeSync(fd); }
    },
  };
}
