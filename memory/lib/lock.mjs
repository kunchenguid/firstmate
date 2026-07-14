import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

function pidAlive(pid) {
  if (!pid || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function readOwner(lockDir) {
  try {
    return JSON.parse(fs.readFileSync(path.join(lockDir, 'owner.json'), 'utf8'));
  } catch {
    return null;
  }
}

function writeOwner(lockDir) {
  const owner = { pid: process.pid, host: os.hostname(), ts: new Date().toISOString() };
  fs.writeFileSync(path.join(lockDir, 'owner.json'), JSON.stringify(owner, null, 2));
  return owner;
}

export class LockBusyError extends Error {
  constructor(message, owner) {
    super(message);
    this.name = 'LockBusyError';
    this.owner = owner;
  }
}

// Ported from fleet-bridge lib/bug-ledger-lock.js mkdir-lock semantics.
// The memory registry owns its copy to avoid any runtime dependency on Fleet Bridge checkouts.
export async function withRegistryLock(lockDir, fn, options = {}) {
  const staleMs = Number(options.staleMs ?? process.env.MEM_LOCK_STALE_MS ?? 30000);
  const waitMs = Number(options.waitMs ?? 5000);
  const start = Date.now();
  fs.mkdirSync(path.dirname(lockDir), { recursive: true, mode: 0o755 });

  for (;;) {
    try {
      fs.mkdirSync(lockDir, { mode: 0o700 });
      writeOwner(lockDir);
      break;
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      const owner = readOwner(lockDir);
      const age = owner?.ts ? Date.now() - Date.parse(owner.ts) : staleMs + 1;
      const sameHost = !owner?.host || owner.host === os.hostname();
      if (age > staleMs && (!sameHost || !pidAlive(owner?.pid))) {
        fs.rmSync(lockDir, { recursive: true, force: true });
        continue;
      }
      if (Date.now() - start >= waitMs) {
        throw new LockBusyError(`registry lock is held by pid ${owner?.pid || 'unknown'}`, owner);
      }
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
  }

  try {
    return await fn();
  } finally {
    fs.rmSync(lockDir, { recursive: true, force: true });
  }
}
