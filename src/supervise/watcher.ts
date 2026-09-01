// Watcher — the supervision loop.
// Polls the fleet's tasks, classifies each session's agent state, appends
// status events, and surfaces wake records. Mirrors bin/fm-watch.sh's polling
// model (durable wake files + backend liveness probes) without POSIX signals.

import type { TerminalBackend } from '../backend/types.js';
import { TaskMetaStore } from '../records/task-meta.js';
import { WakeQueue } from '../records/durable.js';
import { ensureHomeDirs } from '../platform/home.js';

export interface WatcherOptions {
  pollMs?: number;
  /** Run a single pass and exit (for tests and `watch --once`). */
  once?: boolean;
}

export class Watcher {
  private stopped = false;

  constructor(
    private readonly backend: TerminalBackend,
    private readonly env: NodeJS.ProcessEnv,
  ) {}

  async run(opts: WatcherOptions = {}): Promise<void> {
    const pollMs = opts.pollMs ?? 2000;
    const paths = await ensureHomeDirs(this.env);
    const store = new TaskMetaStore(paths.state);
    const queue = new WakeQueue(`${paths.state}/.wake-queue`);

    do {
      await this.pass(store, queue);
      if (opts.once) return;
      await sleep(pollMs);
    } while (!this.stopped);
  }

  stop(): void {
    this.stopped = true;
  }

  private async pass(store: TaskMetaStore, queue: WakeQueue): Promise<void> {
    const metas = await store.list();
    for (const meta of metas) {
      const state = await this.backend.agentState(meta.id);
      const log = store.statusLog(meta.id);
      if (state === 'dead' || state === 'missing') {
        await log.append('exited', `worker ${state}`);
        await queue.push({ kind: 'signal', key: meta.id, payload: `worker ${state}` });
      }
    }
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}
