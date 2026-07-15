import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';

function pidAlive(pid) {
  if (!pid || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    // EPERM means the process exists but is owned by another user: still alive.
    return error.code === 'EPERM';
  }
}

function readOwner(lockDir) {
  try {
    return JSON.parse(fs.readFileSync(path.join(lockDir, 'owner.json'), 'utf8'));
  } catch {
    return null;
  }
}

function readOwnerForRelease(lockDir) {
  try {
    return { owner: JSON.parse(fs.readFileSync(path.join(lockDir, 'owner.json'), 'utf8')), error: null };
  } catch (error) {
    return { owner: null, error };
  }
}

function lockAgeMs(lockDir, owner) {
  if (owner?.ts) {
    const parsed = Date.parse(owner.ts);
    if (!Number.isNaN(parsed)) return Date.now() - parsed;
  }
  try {
    return Date.now() - fs.statSync(lockDir).mtimeMs;
  } catch {
    return 0;
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Atomically break a lock we have decided is abandoned. Rename is atomic, so if
// two contenders both try to steal, only one rename wins; the loser gets ENOENT
// and simply retries the acquire loop. This prevents a double-reclaim race.
function tryStealLock(lockDir) {
  const dead = `${lockDir}.stale-${process.pid}-${crypto.randomBytes(4).toString('hex')}`;
  try {
    fs.renameSync(lockDir, dead);
  } catch {
    return false;
  }
  try {
    fs.rmSync(dead, { recursive: true, force: true });
  } catch {
    // best effort; the renamed husk is harmless if removal fails
  }
  return true;
}

// Release only if we still own the lock. If our lock was reclaimed by a proven
// stale-reclaim while we ran, owner.json now carries a different token, so we
// must not delete the new owner's live lock.
function releaseLock(lockDir, token) {
  const { owner, error } = readOwnerForRelease(lockDir);
  if (!owner || !owner.token) {
    console.error(`mem: refusing to release registry lock without readable owner token: ${error?.message || 'missing owner token'}`);
    return;
  }
  if (owner.token !== token) return;
  try {
    fs.rmSync(lockDir, { recursive: true, force: true });
  } catch {
    // best effort
  }
}

export class LockBusyError extends Error {
  constructor(message, owner) {
    super(message);
    this.name = 'LockBusyError';
    this.owner = owner;
  }
}

// Ported from fleet-bridge lib/bug-ledger-lock.js mkdir-lock semantics, then
// hardened for genuine cross-process exclusion. The memory registry owns its
// copy to avoid any runtime dependency on Fleet Bridge checkouts.
//
// Correctness properties (see data/memory-pr1-qa-s1/report.md, "the lock is not
// an exclusive lock across processes"):
//   * mkdir is the atomic mutex; owner.json is written via a temp file + rename
//     so partial owner metadata is never observed.
//   * A freshly-created lock whose owner metadata is not yet visible is treated
//     as INITIALIZING/busy for a bounded grace period, never immediately stale.
//   * Stale reclaim requires sufficient age AND, where the owner is readable,
//     proof the owning process is absent on this host. A lock we cannot prove
//     abandoned is waited on, never removed.
//   * The ownership token is verified before release.
export async function withRegistryLock(lockDir, fn, options = {}) {
  const staleMs = Number(options.staleMs ?? process.env.MEM_LOCK_STALE_MS ?? 30000);
  const initGraceMs = Number(options.initGraceMs ?? process.env.MEM_LOCK_INIT_GRACE_MS ?? 3000);
  const waitMs = Number(options.waitMs ?? process.env.MEM_LOCK_WAIT_MS ?? 5000);
  const token = crypto.randomBytes(16).toString('hex');
  const start = Date.now();
  fs.mkdirSync(path.dirname(lockDir), { recursive: true, mode: 0o755 });

  for (;;) {
    try {
      fs.mkdirSync(lockDir, { mode: 0o700 });
      const owner = { token, pid: process.pid, host: os.hostname(), ts: new Date().toISOString() };
      const tmp = path.join(lockDir, `owner.json.tmp-${process.pid}-${token.slice(0, 8)}`);
      fs.writeFileSync(tmp, JSON.stringify(owner, null, 2), { mode: 0o600 });
      fs.renameSync(tmp, path.join(lockDir, 'owner.json'));
      break;
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      const owner = readOwner(lockDir);
      const age = lockAgeMs(lockDir, owner);
      const sameHost = !owner || !owner.host || owner.host === os.hostname();
      let reclaimable = false;
      if (!owner) {
        // Owner metadata not visible. Within the init grace it is a lock being
        // populated right now: busy, never stale. Only a lock that is both far
        // past the init grace and past the stale threshold counts as a writer
        // that crashed mid-initialization.
        reclaimable = age >= initGraceMs && age > staleMs;
      } else if (age > staleMs && sameHost && !pidAlive(owner.pid)) {
        // Readable owner, sufficiently old, and its process is provably gone.
        reclaimable = true;
      }
      if (reclaimable && tryStealLock(lockDir)) continue;
      if (Date.now() - start >= waitMs) {
        throw new LockBusyError(`registry lock is held by pid ${owner?.pid ?? 'unknown'}`, owner);
      }
      await sleep(25 + Math.floor((token.charCodeAt(0) || 0) % 25));
    }
  }

  try {
    return await fn({ token });
  } finally {
    releaseLock(lockDir, token);
  }
}
