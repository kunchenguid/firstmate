// TaskMeta — durable per-task metadata, mirroring state/<id>.meta.
// Holds the task's recorded endpoint, backend, project, and delivery posture.
// Written atomically so a crash cannot leave a partial record.

import { promises as fs } from 'node:fs';
import path from 'node:path';
import { StatusLog } from './durable.js';

export interface TaskMeta {
  id: string;
  /** Backend endpoint that owns this task's terminal (tmux target, pty id...). */
  endpoint: string;
  /** Backend name: 'stdio' | 'conpty' | 'tmux' | ... */
  backend: string;
  /** Isolated worktree path. */
  worktree: string;
  /** Project repo path. */
  project: string;
  /** Delivery mode: 'no-mistakes' | 'direct-PR' | 'local-only'. */
  deliveryMode: string;
  /** Merge posture: 'yolo' on/off. */
  yolo: boolean;
  /** Created timestamp. */
  createdAt: string;
}

export class TaskMetaStore {
  constructor(readonly stateDir: string) {}

  private file(id: string): string {
    return path.join(this.stateDir, `${id}.meta`);
  }

  async write(meta: TaskMeta): Promise<void> {
    await fs.mkdir(this.stateDir, { recursive: true });
    const tmp = `${this.file(meta.id)}.tmp`;
    await fs.writeFile(tmp, JSON.stringify(meta, null, 2), 'utf8');
    await fs.rename(tmp, this.file(meta.id));
  }

  async read(id: string): Promise<TaskMeta | null> {
    try {
      const raw = await fs.readFile(this.file(id), 'utf8');
      return JSON.parse(raw) as TaskMeta;
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code === 'ENOENT') return null;
      throw err;
    }
  }

  async remove(id: string): Promise<void> {
    try {
      await fs.unlink(this.file(id));
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== 'ENOENT') throw err;
    }
  }

  async list(): Promise<TaskMeta[]> {
    let files: string[];
    try {
      files = await fs.readdir(this.stateDir);
    } catch {
      return [];
    }
    const metas = await Promise.all(
      files.filter((f) => f.endsWith('.meta')).map((f) => this.read(f.replace(/\.meta$/, ''))),
    );
    return metas.filter((m): m is TaskMeta => m !== null);
  }

  /** The status log for a task (state/<id>.status). */
  statusLog(id: string): StatusLog {
    return new StatusLog(path.join(this.stateDir, `${id}.status`));
  }
}
