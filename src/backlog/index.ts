// Backlog — the durable task queue.
// Prefers the tasks-axi CLI (the repo's configured backend) and falls back to
// a built-in JSONL store when tasks-axi is not installed, so the native core
// works standalone. The fallback mirrors the same add/list/transition contract.

import { promises as fs } from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { resolveTool } from '../platform/tools.js';
import { resolveHome } from '../platform/home.js';

export type BacklogStatus = 'backlog' | 'in-flight' | 'done' | 'blocked';

export interface BacklogItem {
  id: string;
  subject: string;
  status: BacklogStatus;
  createdAt: string;
  note?: string;
}

export interface BacklogClient {
  add(subject: string, opts?: { note?: string }): Promise<BacklogItem>;
  list(): Promise<BacklogItem[]>;
  transition(id: string, status: BacklogStatus): Promise<void>;
}

export async function createBacklogClient(env: NodeJS.ProcessEnv): Promise<BacklogClient> {
  const tool = await resolveTool('tasks-axi', env);
  if (tool.path) {
    return new TasksAxiBacklog(tool.path, env);
  }
  return new JsonlBacklog(env);
}

/** tasks-axi adapter — shells out to the npm CLI (cross-platform). */
class TasksAxiBacklog implements BacklogClient {
  constructor(
    private readonly bin: string,
    private readonly env: NodeJS.ProcessEnv,
  ) {}

  async add(subject: string, opts?: { note?: string }): Promise<BacklogItem> {
    const out = await this.run(['add', subject, ...(opts?.note ? ['--note', opts.note] : [])]);
    // tasks-axi prints the new item's id (often a number).
    const id = out.trim().split(/\s+/).pop() ?? String(Date.now());
    const item: BacklogItem = { id, subject, status: 'backlog', createdAt: new Date().toISOString() };
    if (opts?.note) item.note = opts.note;
    return item;
  }

  async list(): Promise<BacklogItem[]> {
    const out = await this.run(['list', '--json']);
    try {
      const parsed = JSON.parse(out);
      return Array.isArray(parsed) ? (parsed as BacklogItem[]) : [];
    } catch {
      return [];
    }
  }

  async transition(id: string, status: BacklogStatus): Promise<void> {
    const verb = status === 'in-flight' ? 'start' : status === 'done' ? 'done' : status === 'blocked' ? 'block' : 'add';
    await this.run([verb, id]);
  }

  private run(args: string[]): Promise<string> {
    return new Promise((resolve, reject) => {
      const p = spawn(this.bin, args, {
        env: this.env,
        stdio: ['ignore', 'pipe', 'pipe'],
        shell: /\.(cmd|bat)$/i.test(this.bin),
      });
      let out = '';
      let err = '';
      p.stdout.on('data', (d: Buffer) => (out += d.toString()));
      p.stderr.on('data', (d: Buffer) => (err += d.toString()));
      p.on('error', reject);
      p.on('exit', (code) => {
        if (code === 0) resolve(out);
        else reject(new Error(`tasks-axi failed (${code}): ${err.trim() || out.trim()}`));
      });
    });
  }
}

/** Built-in JSONL backlog — works without tasks-axi. */
export class JsonlBacklog implements BacklogClient {
  private readonly file: string;

  constructor(env: NodeJS.ProcessEnv) {
    this.file = path.join(resolveHome(env), 'data', 'backlog.jsonl');
  }

  async add(subject: string, opts?: { note?: string }): Promise<BacklogItem> {
    await fs.mkdir(path.dirname(this.file), { recursive: true });
    const item: BacklogItem = {
      id: `t-${Date.now().toString(36)}`,
      subject,
      status: 'backlog',
      createdAt: new Date().toISOString(),
    };
    if (opts?.note) item.note = opts.note;
    await fs.appendFile(this.file, `${JSON.stringify(item)}\n`, 'utf8');
    return item;
  }

  async list(): Promise<BacklogItem[]> {
    try {
      const raw = await fs.readFile(this.file, 'utf8');
      return raw.split('\n').filter(Boolean).map((l) => JSON.parse(l) as BacklogItem);
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code === 'ENOENT') return [];
      throw err;
    }
  }

  async transition(id: string, status: BacklogStatus): Promise<void> {
    const items = await this.list();
    const next = items.map((i) => (i.id === id ? { ...i, status } : i));
    await fs.writeFile(this.file, next.map((i) => JSON.stringify(i)).join('\n') + '\n', 'utf8');
  }
}
