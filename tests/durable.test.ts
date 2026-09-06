// Durable records tests — status log and wake queue.
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { StatusLog, WakeQueue } from '../src/records/durable.js';

let dir: string;

beforeEach(async () => {
  dir = await fs.mkdtemp(path.join(os.tmpdir(), 'fm-records-test-'));
});

afterEach(async () => {
  await fs.rm(dir, { recursive: true, force: true });
});

describe('StatusLog', () => {
  it('appends and tails events', async () => {
    const log = new StatusLog(path.join(dir, 't.status'));
    await log.append('running', 'started');
    await log.append('done', 'finished');
    const events = await log.tail();
    expect(events).toHaveLength(2);
    expect(events[0]).toMatchObject({ state: 'running', note: 'started' });
  });

  it('returns an empty list when the log is absent', async () => {
    const log = new StatusLog(path.join(dir, 'missing.status'));
    expect(await log.tail()).toEqual([]);
  });
});

describe('WakeQueue', () => {
  it('pushes, drains, and acknowledges through a seq', async () => {
    const q = new WakeQueue(path.join(dir, '.wake-queue'));
    const seq1 = await q.push({ kind: 'signal', key: 't1' });
    await q.push({ kind: 'check', key: 't2' });

    const all = await q.drain();
    expect(all).toHaveLength(2);

    await q.acknowledgeThrough(seq1);
    const remaining = await q.drain();
    expect(remaining).toHaveLength(1);
    expect(remaining[0]).toMatchObject({ kind: 'check', key: 't2' });
  });

  it('acknowledges everything and removes the file', async () => {
    const q = new WakeQueue(path.join(dir, '.wake-queue'));
    const seq = await q.push({ kind: 'note', key: 'inbox-1' });
    await q.acknowledgeThrough(seq);
    expect(await q.drain()).toEqual([]);
  });
});
