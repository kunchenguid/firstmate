// StdioBackend — platform-agnostic fallback backend.
// Spawns the command as a detached child process writing to a per-task log
// file, so sessions survive the CLI process that created them (the same model
// as tmux/conpty, where the session lives in a server and the CLI is a client).
// `fm attach` replays the log and bridges stdio to the live child.

import { spawn, type ChildProcess } from 'node:child_process';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import type {
  AgentState,
  AttachableBackend,
  BackendCreateOptions,
} from './types.js';
import { isAlive, killTree, killPid } from '../platform/process-manager.js';

interface SessionRecord {
  pid: number;
  logPath: string;
  cwd: string;
  command: string;
  args: string[];
  created: string;
}

interface LiveSession {
  child: ChildProcess;
  record: SessionRecord;
}

export class StdioBackend implements AttachableBackend {
  readonly name = 'stdio';
  private live = new Map<string, LiveSession>();

  private recordsDir(): string {
    return path.join(process.env.FM_HOME ?? path.join(os.homedir(), '.firstmate'), 'state', 'stdio');
  }

  private recordPath(taskId: string): string {
    return path.join(this.recordsDir(), `${taskId}.json`);
  }

  private logPath(taskId: string): string {
    return path.join(this.recordsDir(), `${taskId}.log`);
  }

  async create(opts: BackendCreateOptions): Promise<string> {
    await this.kill(opts.taskId).catch(() => undefined);
    const dir = this.recordsDir();
    await fs.mkdir(dir, { recursive: true });
    const logPath = this.logPath(opts.taskId);
    const isWin = process.platform === 'win32';
    const isCmdShim = /\.(cmd|bat)$/i.test(opts.command);

    // Redirect stdout/stderr straight to a real file descriptor rather than
    // piping through this process: a piped Node stream is a live socket the
    // parent holds open, so it (a) keeps the event loop alive, blocking
    // `fm spawn` until the harness exits instead of returning immediately,
    // and (b) breaks (EPIPE) once this CLI process exits and closes its end,
    // which defeats the "session survives the CLI process" design. A real fd
    // has no such dependency on this process staying alive.
    const logHandle = await fs.open(logPath, 'a');
    const logFd = logHandle.fd;
    // Windows .cmd/.bat shims (npm globals, fake harnesses) are not directly
    // spawnable by node. `shell: true` mangles their args, so launch them via
    // cmd.exe /d /s /c with the full command line instead.
    const child = isWin && isCmdShim
      ? spawn('cmd.exe', ['/d', '/s', '/c', buildCmdLine(opts.command, opts.args)], {
          cwd: opts.cwd,
          env: { ...process.env, ...opts.env },
          stdio: ['pipe', logFd, logFd],
          detached: true,
          windowsVerbatimArguments: true,
        })
      : spawn(opts.command, opts.args, {
          cwd: opts.cwd,
          env: { ...process.env, ...opts.env },
          stdio: ['pipe', logFd, logFd],
          detached: true,
        });
    await logHandle.close();

    const record: SessionRecord = {
      pid: child.pid ?? -1,
      logPath,
      cwd: opts.cwd,
      command: opts.command,
      args: opts.args,
      created: new Date().toISOString(),
    };
    await fs.writeFile(this.recordPath(opts.taskId), JSON.stringify(record, null, 2), 'utf8');

    this.live.set(opts.taskId, { child, record });
    // Detach so the CLI process exits while the child keeps running. The
    // process handle and the stdin pipe socket are each their own libuv
    // handle and each independently keeps the event loop alive; unref both.
    child.unref();
    (child.stdin as unknown as { unref?: () => void } | null)?.unref?.();

    return opts.taskId;
  }

  private async readRecord(taskId: string): Promise<SessionRecord | null> {
    try {
      const raw = await fs.readFile(this.recordPath(taskId), 'utf8');
      return JSON.parse(raw) as SessionRecord;
    } catch {
      return null;
    }
  }

  async exists(taskId: string): Promise<boolean> {
    const live = this.live.get(taskId);
    if (live) return live.child.exitCode === null;
    const record = await this.readRecord(taskId);
    if (!record) return false;
    return isAlive(record.pid);
  }

  async capture(taskId: string, lines = 50): Promise<string> {
    const live = this.live.get(taskId);
    if (live) {
      // Live: read the log tail.
    }
    const record = (await this.readRecord(taskId)) ?? live?.record;
    if (!record) return '';
    try {
      const handle = await fs.open(record.logPath, 'r');
      try {
        const stat = await handle.stat();
        const size = Math.min(stat.size, 64 * 1024);
        const buf = Buffer.alloc(size);
        await handle.read(buf, 0, size, stat.size - size);
        const text = buf.toString('utf8').split('\n');
        return text.slice(-lines).join('\n');
      } finally {
        await handle.close();
      }
    } catch {
      return '';
    }
  }

  async sendText(taskId: string, text: string): Promise<void> {
    const live = this.live.get(taskId);
    if (!live || !live.child.stdin || live.child.stdin.destroyed) return;
    live.child.stdin.write(text);
  }

  async sendTextSubmit(taskId: string, text: string): Promise<void> {
    await this.sendText(taskId, text + '\n');
  }

  async sendKey(taskId: string, key: string): Promise<void> {
    const map: Record<string, string> = {
      'C-c': '\u0003',
      'C-d': '\u0004',
      Enter: '\r',
    };
    await this.sendText(taskId, map[key] ?? key);
  }

  async cwd(taskId: string): Promise<string | null> {
    const record = await this.readRecord(taskId);
    return record?.cwd ?? null;
  }

  async agentState(taskId: string): Promise<AgentState> {
    const live = this.live.get(taskId);
    if (live) return live.child.exitCode === null ? 'alive' : 'dead';
    const record = await this.readRecord(taskId);
    if (!record) return 'missing';
    return isAlive(record.pid) ? 'alive' : 'dead';
  }

  async kill(taskId: string): Promise<void> {
    const live = this.live.get(taskId);
    if (live) {
      await killTree(live.child);
      this.live.delete(taskId);
    } else {
      const record = await this.readRecord(taskId);
      if (record && isAlive(record.pid)) {
        await killPid(record.pid);
      }
    }
    try {
      await fs.unlink(this.recordPath(taskId));
    } catch {
      /* already gone */
    }
  }

  /** Replay the log then bridge stdio to the live child. */
  async attach(taskId: string): Promise<number> {
    const record = await this.readRecord(taskId);
    if (!record) {
      process.stderr.write(`fm: no session for ${taskId}\n`);
      return 1;
    }
    const out = await this.capture(taskId, 5000);
    process.stdout.write(out + (out ? '\n' : ''));
    const live = this.live.get(taskId);
    if (!live) return 0;

    live.child.stdout?.pipe(process.stdout);
    live.child.stderr?.pipe(process.stderr);
    if (live.child.stdin) {
      process.stdin.pipe(live.child.stdin);
    }
    await new Promise<void>((resolve) => {
      live.child.on('exit', () => resolve());
      process.stdin.on('end', () => {
        if (live.child.stdin) live.child.stdin.end();
        resolve();
      });
    });
    return 0;
  }
}

/** Quote each argument for the Windows command line (cmd.exe /c form). */
function buildCmdLine(command: string, args: string[]): string {
  const quote = (a: string): string =>
    /[\s"]/.test(a) ? `"${a.replace(/"/g, '\\"')}"` : a;
  return [command, ...args.map(quote)].join(' ');
}
