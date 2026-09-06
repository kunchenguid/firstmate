// WorktreeProvider — isolated task worktrees via native `git worktree`.
// The bash fleet uses treehouse; the native core uses plain git worktree,
// which works on all platforms. Lease support is a no-op here (documented
// degrade) until treehouse is verified on Windows.

import { spawn } from 'node:child_process';
import { promises as fs } from 'node:fs';
import path from 'node:path';

export interface WorktreeInfo {
  /** Absolute path to the worktree. */
  path: string;
  /** Branch name the worktree is on. */
  branch: string;
}

export class WorktreeProvider {
  async create(projectPath: string, taskId: string): Promise<WorktreeInfo> {
    const branch = `fm-${taskId}`;
    const worktreePath = path.join(projectPath, '..', `.fm-${taskId}`);
    await this.git(projectPath, ['worktree', 'add', '-b', branch, worktreePath, 'HEAD']);
    return { path: worktreePath, branch };
  }

  async remove(projectPath: string, worktreePath: string): Promise<void> {
    try {
      await this.git(projectPath, ['worktree', 'remove', '--force', worktreePath]);
    } catch {
      // Fall back to manual cleanup when git worktree removal fails.
      await fs.rm(worktreePath, { recursive: true, force: true });
    }
  }

  private git(cwd: string, args: string[]): Promise<string> {
    return new Promise((resolve, reject) => {
      const p = spawn('git', args, { cwd, stdio: ['ignore', 'pipe', 'pipe'] });
      let out = '';
      let err = '';
      p.stdout.on('data', (d: Buffer) => (out += d.toString()));
      p.stderr.on('data', (d: Buffer) => (err += d.toString()));
      p.on('error', reject);
      p.on('exit', (code) => {
        if (code === 0) resolve(out.trim());
        else reject(new Error(`git worktree failed (${code}): ${err.trim() || out.trim()}`));
      });
    });
  }
}
