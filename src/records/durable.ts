// Durable fleet records — status events and the wake queue.
// Mirrors the bash state/<id>.status append and state/.wake-queue conventions
// with append-only JSONL files. A status line is a wake event, not current state.

import { promises as fs } from 'node:fs';
import path from 'node:path';

export interface StatusEvent {
  ts: string;
  state: string;
  note: string;
}

export interface WakeRecord {
  seq: number;
  kind: 'signal' | 'stale' | 'check' | 'heartbeat' | 'note';
  key: string;
  payload?: string;
}

export class StatusLog {
  constructor(private readonly file: string) {}

  async append(state: string, note: string): Promise<void> {
    const event: StatusEvent = { ts: new Date().toISOString(), state, note };
    await fs.mkdir(path.dirname(this.file), { recursive: true });
    await fs.appendFile(this.file, `${JSON.stringify(event)}\n`, 'utf8');
  }

  /** Read the last N events (tail). */
  async tail(n = 20): Promise<StatusEvent[]> {
    try {
      const raw = await fs.readFile(this.file, 'utf8');
      const lines = raw.split('\n').filter(Boolean).slice(-n);
      return lines.map((l) => JSON.parse(l) as StatusEvent);
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code === 'ENOENT') return [];
      throw err;
    }
  }
}

export class WakeQueue {
  constructor(private readonly file: string) {}

  /** Enqueue a wake record; returns the assigned seq. */
  async push(record: Omit<WakeRecord, 'seq'>): Promise<number> {
    await fs.mkdir(path.dirname(this.file), { recursive: true });
    const seq = Date.now();
    await fs.appendFile(this.file, `${JSON.stringify({ seq, ...record })}\n`, 'utf8');
    return seq;
  }

  /** Read all queued wakes. */
  async drain(): Promise<WakeRecord[]> {
    try {
      const raw = await fs.readFile(this.file, 'utf8');
      return raw.split('\n').filter(Boolean).map((l) => JSON.parse(l) as WakeRecord);
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code === 'ENOENT') return [];
      throw err;
    }
  }

  /** Remove wakes up to and including `throughSeq`. */
  async acknowledgeThrough(throughSeq: number): Promise<void> {
    const remaining = (await this.drain()).filter((w) => w.seq > throughSeq);
    if (remaining.length === 0) {
      try {
        await fs.unlink(this.file);
      } catch {
        /* already gone */
      }
      return;
    }
    await fs.writeFile(this.file, remaining.map((w) => JSON.stringify(w)).join('\n') + '\n', 'utf8');
  }
}
