// Spawn — orchestrate a task: resolve project, create worktree, write brief,
// launch the harness into a backend session, record durable task meta.

import { promises as fs } from 'node:fs';
import path from 'node:path';
import { ensureHomeDirs } from '../platform/home.js';
import type { TerminalBackend } from '../backend/types.js';
import { HarnessLauncher, harnessLaunchArgs, type HarnessName } from './harness.js';
import { WorktreeProvider } from './worktree.js';
import { TaskMetaStore, type TaskMeta } from '../records/task-meta.js';
import { createBacklogClient } from '../backlog/index.js';

export interface SpawnOptions {
  /** Project repo path. */
  project: string;
  /** Task subject. */
  subject: string;
  /** Harness to run the task. */
  harness: HarnessName;
  /** Delivery mode. */
  deliveryMode?: 'no-mistakes' | 'direct-PR' | 'local-only';
  /** Merge posture. */
  yolo?: boolean;
  /** Explicit backend override. */
  backend?: 'stdio' | 'conpty' | 'tmux';
  /** Optional direct command/args override (tests, custom harnesses). */
  harnessOverride?: HarnessCommand;
}

export interface SpawnResult {
  taskId: string;
  worktree: string;
  branch: string;
  endpoint: string;
  backend: string;
  meta: TaskMeta;
}

export interface HarnessCommand {
  command: string;
  args: string[];
}

export class SpawnService {
  constructor(
    private readonly backend: TerminalBackend,
    private readonly env: NodeJS.ProcessEnv,
    private readonly worktrees = new WorktreeProvider(),
    private readonly launcher = new HarnessLauncher(),
  ) {}

  async spawn(opts: SpawnOptions): Promise<SpawnResult> {
    const paths = await ensureHomeDirs(this.env);
    const taskId = `t-${Date.now().toString(36)}`;

    // 1. Backlog: record the item as in-flight.
    const backlog = await createBacklogClient(this.env);
    await backlog.add(opts.subject, { note: `task ${taskId}` });
    await backlog.transition((await backlog.list()).find((i) => i.note?.includes(taskId))?.id ?? taskId, 'in-flight');

    // 2. Worktree.
    const wt = await this.worktrees.create(opts.project, taskId);

    // 3. Brief.
    const brief = `# ${opts.subject}

Task: ${taskId}
Project: ${opts.project}
Worktree: ${wt.path}
Delivery mode: ${opts.deliveryMode ?? 'no-mistakes'}
Merge posture: ${opts.yolo ? 'yolo on' : 'yolo off'}

## Instructions
Complete the task described in the subject within this isolated worktree.
Follow the project's delivery contract for the selected mode.
Do not work outside this worktree.
`;
    const briefPath = path.join(wt.path, 'TASK.md');
    await fs.writeFile(briefPath, brief, 'utf8');

    // 4. Launch harness into the backend.
    const harnessPath = opts.harnessOverride
      ? opts.harnessOverride.command
      : await this.launcher.resolve(opts.harness, this.env);
    const harnessArgs = opts.harnessOverride
      ? opts.harnessOverride.args
      : harnessLaunchArgs(opts.harness, briefPath);
    const endpoint = await this.backend.create({
      taskId,
      cwd: wt.path,
      command: harnessPath,
      args: harnessArgs,
      env: {},
    });
    // 5. Durable task meta.
    const meta: TaskMeta = {
      id: taskId,
      endpoint,
      backend: this.backend.name,
      worktree: wt.path,
      project: opts.project,
      deliveryMode: opts.deliveryMode ?? 'no-mistakes',
      yolo: opts.yolo ?? false,
      createdAt: new Date().toISOString(),
    };
    const store = new TaskMetaStore(paths.state);
    await store.write(meta);
    await store.statusLog(taskId).append('running', `spawned on ${this.backend.name}`);

    return { taskId, worktree: wt.path, branch: wt.branch, endpoint, backend: this.backend.name, meta };
  }
}
