// SteeringInbox — durable per-task steering records.
// Mirrors state/<id>.inbox: sequenced instruction records the worker
// acknowledges by moving them into handled/. fm-send writes here; the watcher
// rings the worker's doorbell; the worker consumes and acknowledges.

import { promises as fs } from 'node:fs';
import path from 'node:path';

export interface SteerRecord {
  seq: number;
  kind: 'steer' | 'resolve-key';
  message: string;
  /** Optional decision key this steer resolves. */
  resolveKey?: string;
  created: string;
}

export class SteeringInbox {
  constructor(private readonly dir: string) {}

  async push(record: Omit<SteerRecord, 'seq' | 'created'>): Promise<SteerRecord> {
    await fs.mkdir(this.dir, { recursive: true });
    const seq = Date.now();
    const full: SteerRecord = { ...record, seq, created: new Date().toISOString() };
    await fs.writeFile(path.join(this.dir, `${seq}.json`), JSON.stringify(full, null, 2), 'utf8');
    return full;
  }

  /** List pending (unhandled) records, oldest first. */
  async pending(): Promise<SteerRecord[]> {
    let files: string[];
    try {
      files = await fs.readdir(this.dir);
    } catch {
      return [];
    }
    const pending = files.filter((f) => f.endsWith('.json'));
    pending.sort();
    const records = await Promise.all(
      pending.map((f) => fs.readFile(path.join(this.dir, f), 'utf8').then((r) => JSON.parse(r) as SteerRecord)),
    );
    return records;
  }

  /** Acknowledge a record by moving it into handled/. */
  async acknowledge(seq: number): Promise<void> {
    const handled = path.join(this.dir, 'handled');
    await fs.mkdir(handled, { recursive: true });
    const src = path.join(this.dir, `${seq}.json`);
    try {
      await fs.rename(src, path.join(handled, `${seq}.json`));
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== 'ENOENT') throw err;
    }
  }
}
