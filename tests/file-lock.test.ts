// FileLock behavior tests — contention, staleness, force-replace, release.
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { FileLock, isStaleLock, currentBootNonce, type LockMetadata } from '../src/platform/file-lock.js';

let dir: string;

beforeEach(async () => {
  dir = await fs.mkdtemp(path.join(os.tmpdir(), 'fm-lock-test-'));
});

afterEach(async () => {
  await fs.rm(dir, { recursive: true, force: true });
});

function lockPath(name = 'session.lock') {
  return path.join(dir, name);
}

describe('FileLock', () => {
  it('acquires an uncontended lock', async () => {
    const lock = new FileLock({ lockPath: lockPath(), dir });
    const state = await lock.acquire();
    expect(state.held).toBe(true);
    await lock.release();
  });

  it('refuses when another live holder owns the lock', async () => {
    const first = new FileLock({ lockPath: lockPath(), dir });
    await first.acquire();
    const second = new FileLock({ lockPath: lockPath(), dir });
    const state = await second.acquire();
    expect(state).toEqual({ held: false, reason: 'refused' });
    await first.release();
  });

  it('treats a lock owned by a dead pid as stale', async () => {
    const metadata: LockMetadata = {
      pid: 999999999, // almost certainly not alive
      host: 'test',
      bootNonce: 'test-nonce',
      acquiredAt: new Date().toISOString(),
    };
    await fs.writeFile(lockPath(), JSON.stringify(metadata), 'utf8');
    expect(await isStaleLock(lockPath())).toBe(true);
  });

  it('treats a lock owned by a live pid as live', async () => {
    const metadata: LockMetadata = {
      pid: process.pid,
      host: 'test',
      bootNonce: currentBootNonce(),
      acquiredAt: new Date().toISOString(),
    };
    await fs.writeFile(lockPath(), JSON.stringify(metadata), 'utf8');
    expect(await isStaleLock(lockPath())).toBe(false);
  });

  it('force-replaces a stale lock but refuses a live one', async () => {
    const stale: LockMetadata = {
      pid: 999999999,
      host: 'test',
      bootNonce: 'stale-nonce',
      acquiredAt: new Date().toISOString(),
    };
    await fs.writeFile(lockPath(), JSON.stringify(stale), 'utf8');

    const forced = new FileLock({ lockPath: lockPath(), dir, force: true });
    const state = await forced.acquire();
    expect(state.held).toBe(true);
    await forced.release();

    // A live holder must not be force-replaced.
    const live = new FileLock({ lockPath: lockPath(), dir });
    await live.acquire();
    const noForce = new FileLock({ lockPath: lockPath(), dir, force: true });
    const refused = await noForce.acquire();
    expect(refused).toEqual({ held: false, reason: 'refused' });
    await live.release();
  });

  it('uses an injectable liveness probe', async () => {
    const metadata: LockMetadata = {
      pid: 42,
      host: 'test',
      bootNonce: 'probe-nonce',
      acquiredAt: new Date().toISOString(),
    };
    await fs.writeFile(lockPath(), JSON.stringify(metadata), 'utf8');

    // Probe says pid 42 is alive -> lock is live -> refused.
    const aliveProbe = new FileLock({ lockPath: lockPath(), dir, isAlive: () => true });
    expect(await aliveProbe.acquire()).toEqual({ held: false, reason: 'refused' });

    // Probe says pid 42 is dead -> stale -> force replaces.
    const deadProbe = new FileLock({ lockPath: lockPath(), dir, force: true, isAlive: () => false });
    const state = await deadProbe.acquire();
    expect(state.held).toBe(true);
    await deadProbe.release();
  });

  it('releases idempotently', async () => {
    const lock = new FileLock({ lockPath: lockPath(), dir });
    await lock.acquire();
    await lock.release();
    await lock.release(); // no throw
    expect(await isStaleLock(lockPath())).toBe(false);
  });
});
