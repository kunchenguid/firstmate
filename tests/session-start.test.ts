// Session-start digest test: lock, wake queue, fleet summary.
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import os from 'node:os';
import path from 'node:path';
import { promises as fs } from 'node:fs';
import { SessionStartService } from '../src/fleet/session-start.js';
import { StdioBackend } from '../src/backend/stdio.js';
import { WakeQueue } from '../src/records/durable.js';

let tmp: string;
let env: NodeJS.ProcessEnv;

beforeEach(async () => {
  tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'fm-ss-test-'));
  env = { ...process.env, FM_HOME: path.join(tmp, 'home'), FM_BACKEND: 'stdio' };
});

afterEach(async () => {
  await fs.rm(tmp, { recursive: true, force: true });
});

describe('SessionStartService', () => {
  it('acquires the lock and reports an empty fleet', async () => {
    const service = new SessionStartService(new StdioBackend(), env);
    const result = await service.run();
    expect(result.lockHeld).toBe(true);
    expect(result.wakes).toBe(0);
    expect(result.fleet).toEqual([]);
  });

  it('reports queued wakes', async () => {
    const paths = { state: path.join(env.FM_HOME!, 'state') };
    const queue = new WakeQueue(`${paths.state}/.wake-queue`);
    await queue.push({ kind: 'signal', key: 't1' });

    const service = new SessionStartService(new StdioBackend(), env);
    const result = await service.run();
    expect(result.wakes).toBe(1);
  });

  it('refuses the lock when another holder owns it', async () => {
    const first = new SessionStartService(new StdioBackend(), env);
    await first.run();
    // Second session-start in the same home must be refused.
    const second = new SessionStartService(new StdioBackend(), env);
    const result = await second.run();
    expect(result.lockHeld).toBe(false);
  });
});
