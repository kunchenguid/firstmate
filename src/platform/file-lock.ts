// FileLock — exclusive-create lock with pid + bootNonce custody.
// Replaces the bash mkdir/symlink + lsof custody model (bin/fm-lock-lib.sh) with
// a portable primitive: the winner of fs.openSync(path, 'wx') owns the lock.
// Staleness is judged by the recorded pid being alive (process.kill(pid, 0)
// works on Windows for existence) AND the bootNonce matching, so a recycled pid
// from a previous boot cannot inherit a live lock.

import { promises as fs, readFileSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';

export interface LockMetadata {
  pid: number;
  host: string;
  bootNonce: string;
  acquiredAt: string;
}

export type LockState =
  | { held: true; metadata: LockMetadata }
  | { held: false; reason: 'missing' | 'stale' | 'refused' };

export interface FileLockOptions {
  /** Persisted lock file path. */
  lockPath: string;
  /** Where the lockfile directory lives. */
  dir: string;
  /** Whether an already-held (live) lock should be respected or force-replaced. */
  force?: boolean;
  /** Injectable liveness probe for tests. */
  isAlive?: (pid: number) => boolean;
  now?: () => Date;
}

export class FileLock {
  private readonly lockPath: string;
  private readonly force: boolean;
  private readonly isAlive: (pid: number) => boolean;
  private readonly now: () => Date;
  private owned = false;

  constructor(opts: FileLockOptions) {
    this.lockPath = opts.lockPath;
    this.force = opts.force ?? false;
    this.isAlive = opts.isAlive ?? defaultIsAlive;
    this.now = opts.now ?? (() => new Date());
  }

  /** Try to acquire the lock. Returns the resulting state; never throws on contention. */
  async acquire(): Promise<LockState> {
    const metadata: LockMetadata = {
      pid: process.pid,
      host: os.hostname(),
      bootNonce: bootNonce(),
      acquiredAt: this.now().toISOString(),
    };

    await fs.mkdir(path.dirname(this.lockPath), { recursive: true });

    try {
      await fs.writeFile(this.lockPath, JSON.stringify(metadata, null, 2), {
        flag: 'wx',
      });
      this.owned = true;
      return { held: true, metadata };
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== 'EEXIST') throw err;
    }

    // Contended: inspect the existing holder.
    const existing = await this.readMetadata();
    if (!existing) {
      // Race: holder released between our failed create and this read. Retry once.
      try {
        await fs.writeFile(this.lockPath, JSON.stringify(metadata, null, 2), {
          flag: 'wx',
        });
        this.owned = true;
        return { held: true, metadata };
      } catch {
        return { held: false, reason: 'refused' };
      }
    }

    const stale = !this.isAlive(existing.pid) || (!this.usesCustomProbe && existing.bootNonce !== currentBootNonce());
    if (stale && this.force) {
      await this.replace(existing);
      return { held: true, metadata };
    }
    return stale
      ? { held: false, reason: 'stale' }
      : { held: false, reason: 'refused' };
  }

  /** Whether a custom liveness probe is injected (tests) vs the default pid probe. */
  private get usesCustomProbe(): boolean {
    return this.isAlive !== defaultIsAlive;
  }

  async release(): Promise<void> {
    if (!this.owned) return;
    try {
      await fs.unlink(this.lockPath);
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== 'ENOENT') throw err;
    } finally {
      this.owned = false;
    }
  }

  /** Read the holder's metadata without disturbing the lock. */
  async readMetadata(): Promise<LockMetadata | null> {
    try {
      const raw = await fs.readFile(this.lockPath, 'utf8');
      return JSON.parse(raw) as LockMetadata;
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code === 'ENOENT') return null;
      throw err;
    }
  }

  private async replace(metadata: LockMetadata): Promise<void> {
    // Remove the stale lockfile, then race for ownership again.
    try {
      await fs.unlink(this.lockPath);
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== 'ENOENT') throw err;
    }
    try {
      await fs.writeFile(this.lockPath, JSON.stringify(metadata, null, 2), {
        flag: 'wx',
      });
      this.owned = true;
    } catch {
      this.owned = false;
      throw new Error('lost lock race while replacing stale lock');
    }
  }
}

/** Detect a stale lockfile by dead pid — the cross-platform replacement for lsof custody. */
export async function isStaleLock(lockPath: string, isAlive?: (pid: number) => boolean): Promise<boolean> {
  try {
    const raw = await fs.readFile(lockPath, 'utf8');
    const meta = JSON.parse(raw) as LockMetadata;
    const aliveFn = isAlive ?? defaultIsAlive;
    return !aliveFn(meta.pid) || (isAlive === undefined && meta.bootNonce !== currentBootNonce());
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return false;
    throw err;
  }
}

function defaultIsAlive(pid: number): boolean {
  return alive(pid);
}

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    // EPERM means the process exists but we lack permission to signal it.
    return (err as NodeJS.ErrnoException).code === 'EPERM';
  }
}

// A per-boot random token so a recycled pid from a prior boot is detected.
// Stored under the OS temp dir; cleared naturally by a reboot.
const BOOT_NONCE_PATH = path.join(os.tmpdir(), 'firstmate-boot-nonce');
let cachedNonce: string | null = null;

export function currentBootNonce(): string {
  if (cachedNonce) return cachedNonce;
  try {
    cachedNonce = readFileSync(BOOT_NONCE_PATH, 'utf8').trim();
  } catch {
    // Fall back to a session nonce if the temp file is unavailable.
    cachedNonce = `s-${process.pid}-${Date.now()}`;
  }
  return cachedNonce;
}

export function bootNonce(): string {
  return currentBootNonce();
}

/** Persist a fresh boot nonce to the temp dir; called once at session start. */
export async function persistBootNonce(): Promise<string> {
  const nonce = `b-${os.hostname()}-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  await fs.writeFile(BOOT_NONCE_PATH, nonce, { flag: 'w' });
  cachedNonce = nonce;
  return nonce;
}
