// Lifecycle — send, control, teardown, attach.
// Wires the terminal backend, task meta store, and steering inbox together.

import { ensureHomeDirs } from '../platform/home.js';
import type { TerminalBackend } from '../backend/types.js';
import { TaskMetaStore } from '../records/task-meta.js';
import { SteeringInbox } from '../records/steering-inbox.js';
import { WorktreeProvider } from '../spawn/worktree.js';

export type ControlAction = 'interrupt' | 'exit' | 'relaunch';

export class LifecycleService {
  constructor(
    private readonly backend: TerminalBackend,
    private readonly env: NodeJS.ProcessEnv,
  ) {}

  private async taskMeta(id: string): Promise<{ store: TaskMetaStore; meta: NonNullable<Awaited<ReturnType<TaskMetaStore['read']>>> }> {
    const paths = await ensureHomeDirs(this.env);
    const store = new TaskMetaStore(paths.state);
    const meta = await store.read(id);
    if (!meta) throw new Error(`no task ${id}`);
    return { store, meta };
  }

  /** Steer a worker through its durable inbox + doorbell. */
  async send(taskId: string, message: string, resolveKey?: string): Promise<number> {
    const { store } = await this.taskMeta(taskId);
    const inbox = new SteeringInbox(`${store.stateDir}/${taskId}.inbox`);
    const record = await inbox.push({
      kind: resolveKey ? 'resolve-key' : 'steer',
      message,
      ...(resolveKey ? { resolveKey } : {}),
    });
    // Doorbell: write a constant line to the session so the worker notices.
    await this.backend.sendTextSubmit(taskId, `\u001b[2m[firstmate:steer]\u001b[0m`);
    return record.seq;
  }

  /** Control the worker's lifecycle. */
  async control(taskId: string, action: ControlAction): Promise<void> {
    const { store } = await this.taskMeta(taskId);
    if (action === 'interrupt') {
      await this.backend.sendKey(taskId, 'C-c');
    } else if (action === 'exit') {
      await this.backend.sendTextSubmit(taskId, 'exit');
      await store.statusLog(taskId).append('exiting', 'captain requested exit');
    } else if (action === 'relaunch') {
      await this.backend.sendTextSubmit(taskId, 'exit');
      await store.statusLog(taskId).append('relaunching', 'captain requested relaunch');
    }
  }

  /** Tear down a finished task: kill session, remove worktree, mark done. */
  async teardown(taskId: string): Promise<void> {
    const { store, meta } = await this.taskMeta(taskId);
    // Refuse to tear down if there are unacknowledged steers (unlanded work signal).
    const inbox = new SteeringInbox(`${store.stateDir}/${taskId}.inbox`);
    const pending = await inbox.pending();
    if (pending.length > 0) {
      throw new Error(`task ${taskId} has ${pending.length} unacknowledged steer(s); refusing teardown`);
    }
    await this.backend.kill(taskId);
    const worktrees = new WorktreeProvider();
    await worktrees.remove(meta.project, meta.worktree);
    await store.statusLog(taskId).append('done', 'torn down');
    await store.remove(taskId);
  }

  /** Attach the captain's terminal to the task session. */
  async attach(taskId: string): Promise<number> {
    const { meta } = await this.taskMeta(taskId);
    const attachable = this.backend as TerminalBackend & { attach?: (id: string) => Promise<number> };
    if (typeof attachable.attach === 'function') {
      return attachable.attach(taskId);
    }
    process.stderr.write(`fm: backend ${meta.backend} does not support attach; use 'fm capture'\n`);
    return 1;
  }

  /** Capture the session's recent output. */
  async capture(taskId: string, lines = 50): Promise<string> {
    await this.taskMeta(taskId);
    return this.backend.capture(taskId, lines);
  }
}
