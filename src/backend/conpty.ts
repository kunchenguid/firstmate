// ConptyBackend — Windows-native terminal backend via node-pty + ConPTY.
// Each task gets its own pseudo-console with a scrollback ring buffer; the
// captain attaches through `fm attach` (bridges local stdio to the pty).
// On non-Windows platforms this backend refuses loudly rather than pretending.

import { EventEmitter } from 'node:events';
import type {
  AgentState,
  AttachableBackend,
  BackendCreateOptions,
} from './types.js';
import { platformOf } from '../platform/path-util.js';

interface PtySession {
  pty: import('node-pty').IPty;
  buffer: string[];
  max: number;
  emitter: EventEmitter;
  cwd: string | null;
  exited: boolean;
}

let ptyModule: typeof import('node-pty') | null = null;
try {
  // node-pty is an optional native module; only loaded on Windows.
  ptyModule = await import('node-pty');
} catch {
  ptyModule = null;
}

export class ConptyBackend implements AttachableBackend {
  readonly name = 'conpty';
  private sessions = new Map<string, PtySession>();

  constructor() {
    if (platformOf() !== 'win32') {
      throw new Error('conpty backend is Windows-only');
    }
    if (!ptyModule) {
      throw new Error('node-pty is not installed; run `fm setup` to install native deps');
    }
  }

  async create(opts: BackendCreateOptions): Promise<string> {
    this.kill(opts.taskId).catch(() => undefined);
    if (!ptyModule) throw new Error('node-pty unavailable');

    const max = opts.scrollback ?? 200;
    const emitter = new EventEmitter();
    const pty = ptyModule.spawn(opts.command, opts.args, {
      name: 'xterm-256color',
      cols: 120,
      rows: 40,
      cwd: opts.cwd,
      env: { ...process.env, ...opts.env } as Record<string, string>,
      useConpty: true,
    });

    const session: PtySession = { pty, buffer: [], max, emitter, cwd: opts.cwd, exited: false };
    this.sessions.set(opts.taskId, session);

    pty.onData((data: string) => {
      for (const line of data.split('\n')) session.buffer.push(line);
      if (session.buffer.length > max) session.buffer.splice(0, session.buffer.length - max);
      emitter.emit('output', data);
    });
    pty.onExit(({ exitCode }: { exitCode: number }) => {
      session.exited = true;
      emitter.emit('exit', exitCode);
    });

    return opts.taskId;
  }

  async exists(taskId: string): Promise<boolean> {
    const s = this.sessions.get(taskId);
    if (!s) return false;
    return !s.exited;
  }

  async capture(taskId: string, lines = 50): Promise<string> {
    const s = this.sessions.get(taskId);
    if (!s) return '';
    return s.buffer.slice(-lines).join('\n');
  }

  async sendText(taskId: string, text: string): Promise<void> {
    const s = this.sessions.get(taskId);
    if (!s) return;
    s.pty.write(text);
  }

  async sendTextSubmit(taskId: string, text: string): Promise<void> {
    await this.sendText(taskId, text + '\r');
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
    return this.sessions.get(taskId)?.cwd ?? null;
  }

  async agentState(taskId: string): Promise<AgentState> {
    const s = this.sessions.get(taskId);
    if (!s) return 'missing';
    if (s.exited) return 'dead';
    return 'alive';
  }

  async kill(taskId: string): Promise<void> {
    const s = this.sessions.get(taskId);
    if (!s) return;
    try {
      s.pty.kill();
    } catch {
      /* already exited */
    }
    this.sessions.delete(taskId);
  }

  /** Bridge local stdio to the pty (Windows Terminal tab attach). */
  async attach(taskId: string): Promise<number> {
    const s = this.sessions.get(taskId);
    if (!s) {
      process.stderr.write(`fm: no live session for ${taskId}\n`);
      return 1;
    }
    process.stdout.write(s.buffer.join('\n') + (s.buffer.length ? '\n' : ''));
    if (s.exited) return 0;

    const unsub = (data: string) => process.stdout.write(data);
    s.emitter.on('output', unsub);
    process.stdin.setRawMode?.(true);
    process.stdin.on('data', (d: Buffer) => s.pty.write(d.toString()));

    await new Promise<void>((resolve) => {
      s.emitter.on('exit', () => resolve());
      process.stdin.on('end', () => resolve());
    });
    s.emitter.off('output', unsub);
    process.stdin.setRawMode?.(false);
    return 0;
  }
}

