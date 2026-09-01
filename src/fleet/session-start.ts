// SessionStart — the one-shot startup digest.
// Acquires the per-home lock, drains the wake queue, and prints the fleet
// state. Mirrors bin/fm-session-start.sh's lock-first contract: a lock-refused
// session stays read-only and reports the exact refusal.

import path from 'node:path';
import { ensureHomeDirs } from '../platform/home.js';
import { FileLock, persistBootNonce } from '../platform/file-lock.js';
import { WakeQueue } from '../records/durable.js';
import { TaskMetaStore } from '../records/task-meta.js';
import type { TerminalBackend } from '../backend/types.js';

export interface SessionStartResult {
  lockHeld: boolean;
  lockReason: string;
  wakes: number;
  fleet: Array<{ id: string; agent: string }>;
}

export class SessionStartService {
  constructor(
    private readonly backend: TerminalBackend,
    private readonly env: NodeJS.ProcessEnv,
  ) {}

  async run(): Promise<SessionStartResult> {
    const paths = await ensureHomeDirs(this.env);
    await persistBootNonce();

    // 1. Lock.
    const lock = new FileLock({
      lockPath: path.join(paths.state, 'session.lock'),
      dir: paths.state,
    });
    const lockState = await lock.acquire();
    const lockHeld = lockState.held;
    const lockReason = lockState.held ? 'acquired' : lockState.reason;

    // 2. Wake queue (readable even when lock-refused; drain only when held).
    const queue = new WakeQueue(`${paths.state}/.wake-queue`);
    const wakes = await queue.drain();
    const wakeCount = wakes.length;

    // 3. Fleet state.
    const store = new TaskMetaStore(paths.state);
    const metas = await store.list();
    const fleet: Array<{ id: string; agent: string }> = [];
    for (const meta of metas) {
      const agent = await this.backend.agentState(meta.id).catch(() => 'unreadable' as const);
      fleet.push({ id: meta.id, agent });
    }

    return { lockHeld, lockReason, wakes: wakeCount, fleet };
  }
}
