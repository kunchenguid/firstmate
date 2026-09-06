// TmuxBackend — POSIX terminal backend via the tmux server.
// Mirrors the bash tmux adapter's command vocabulary: new-window, send-keys,
// capture-pane, kill-window. Used on macOS/Linux; on Windows it refuses.

import { spawn } from 'node:child_process';
import type {
  AgentState,
  AttachableBackend,
  BackendCreateOptions,
} from './types.js';
import { platformOf } from '../platform/path-util.js';

export class TmuxBackend implements AttachableBackend {
  readonly name = 'tmux';
  private readonly session = 'firstmate';

  constructor() {
    if (platformOf() === 'win32') {
      throw new Error('tmux backend is POSIX-only; use `conpty` or `stdio` on Windows');
    }
  }

  private run(args: string[]): Promise<string> {
    return new Promise((resolve, reject) => {
      const p = spawn('tmux', args, { stdio: ['ignore', 'pipe', 'pipe'] });
      let out = '';
      let err = '';
      p.stdout.on('data', (d: Buffer) => (out += d.toString()));
      p.stderr.on('data', (d: Buffer) => (err += d.toString()));
      p.on('error', reject);
      p.on('exit', (code) => {
        if (code === 0) resolve(out.trim());
        else reject(new Error(`tmux ${args[0]} failed (${code}): ${err.trim()}`));
      });
    });
  }

  private async ensureSession(): Promise<void> {
    try {
      await this.run(['has-session', '-t', this.session]);
    } catch {
      await this.run(['new-session', '-d', '-s', this.session]);
    }
  }

  private windowTarget(taskId: string): string {
    return `=${this.session}:=${taskId}`;
  }

  async create(opts: BackendCreateOptions): Promise<string> {
    await this.ensureSession();
    try {
      await this.run(['kill-window', '-t', this.windowTarget(opts.taskId)]);
    } catch {
      /* no existing window */
    }
    await this.run([
      'new-window',
      '-d',
      '-P',
      '-F',
      '#{window_id}',
      '-t',
      `${this.session}:`,
      '-n',
      opts.taskId,
      '-c',
      opts.cwd,
      `${opts.command} ${opts.args.map(quote).join(' ')}`,
    ]);
    return opts.taskId;
  }

  async exists(taskId: string): Promise<boolean> {
    try {
      await this.run(['display-message', '-p', '#{window_id}', '-t', this.windowTarget(taskId)]);
      return true;
    } catch {
      return false;
    }
  }

  async capture(taskId: string, lines = 50): Promise<string> {
    try {
      return await this.run(['capture-pane', '-p', '-t', this.windowTarget(taskId), '-S', `-${lines}`]);
    } catch {
      return '';
    }
  }

  async sendText(taskId: string, text: string): Promise<void> {
    await this.run(['send-keys', '-t', this.windowTarget(taskId), '-l', text]);
  }

  async sendTextSubmit(taskId: string, text: string): Promise<void> {
    await this.run(['send-keys', '-t', this.windowTarget(taskId), '-l', text, 'Enter']);
  }

  async sendKey(taskId: string, key: string): Promise<void> {
    await this.run(['send-keys', '-t', this.windowTarget(taskId), key]);
  }

  async cwd(taskId: string): Promise<string | null> {
    try {
      return await this.run(['display-message', '-p', '#{pane_current_path}', '-t', this.windowTarget(taskId)]);
    } catch {
      return null;
    }
  }

  async agentState(taskId: string): Promise<AgentState> {
    try {
      const cmd = await this.run(['display-message', '-p', '#{pane_current_command}', '-t', this.windowTarget(taskId)]);
      if (!cmd) return 'dead';
      return 'alive';
    } catch {
      return 'missing';
    }
  }

  async kill(taskId: string): Promise<void> {
    try {
      await this.run(['kill-window', '-t', this.windowTarget(taskId)]);
    } catch {
      /* already gone */
    }
  }

  async attach(taskId: string): Promise<number> {
    // Reattach by switching the captain's tmux client to the task window.
    try {
      await this.run(['select-window', '-t', this.windowTarget(taskId)]);
      return 0;
    } catch (err) {
      process.stderr.write(`fm: attach failed: ${String(err)}\n`);
      return 1;
    }
  }
}

function quote(a: string): string {
  return /[\s"]/.test(a) ? `'${a.replace(/'/g, `'\\''`)}'` : a;
}
