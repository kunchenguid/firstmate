// ProcessManager — spawn, tree-kill, and liveness.
// Replaces ps -t / /proc / kill -0 usage with portable Node primitives.
// On Windows, tree-kill falls back to taskkill /T /F when job objects are
// unavailable; liveness uses process.kill(pid, 0) which works for existence.

import { spawn, type ChildProcess } from 'node:child_process';
import { platformOf } from './path-util.js';

export interface SpawnOptions {
  cwd?: string;
  env?: NodeJS.ProcessEnv;
  shell?: boolean;
}

export interface SpawnedProcess {
  pid: number | undefined;
  child: ChildProcess;
  killTree(): Promise<void>;
  exitCode(): Promise<number | null>;
}

export function isAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return (err as NodeJS.ErrnoException).code === 'EPERM';
  }
}

export async function spawnProcess(
  command: string,
  args: string[],
  opts: SpawnOptions = {},
): Promise<SpawnedProcess> {
  const child = spawn(command, args, {
    cwd: opts.cwd,
    env: opts.env ?? process.env,
    shell: opts.shell ?? false,
    stdio: ['pipe', 'pipe', 'pipe'],
  });

  return {
    pid: child.pid,
    child,
    killTree: () => killTree(child),
    exitCode: () =>
      new Promise((resolve) => {
        if (child.exitCode !== null) return resolve(child.exitCode);
        child.once('exit', (code) => resolve(code ?? 0));
      }),
  };
}

export async function killTree(child: ChildProcess): Promise<void> {
  if (child.exitCode !== null) return;
  if (child.pid === undefined) return;
  await killPid(child.pid);
}

/** Kill a process by pid, tree-style on Windows (taskkill /T /F). */
export async function killPid(pid: number): Promise<void> {
  if (platformOf() === 'win32') {
    await new Promise<void>((resolve) => {
      const killer = spawn('taskkill', ['/PID', String(pid), '/T', '/F'], {
        stdio: 'ignore',
      });
      killer.on('exit', () => resolve());
      killer.on('error', () => {
        try {
          process.kill(pid, 'SIGKILL');
        } catch {
          /* already gone */
        }
        resolve();
      });
    });
  } else {
    // Negative pid signals the whole process group on posix.
    try {
      process.kill(-pid, 'SIGKILL');
    } catch {
      try {
        process.kill(pid, 'SIGKILL');
      } catch {
        /* already gone */
      }
    }
  }
}

export async function commandExists(command: string, env?: NodeJS.ProcessEnv): Promise<boolean> {
  return new Promise((resolve) => {
    const probe = platformOf(env) === 'win32' ? 'where.exe' : 'command';
    const args = platformOf(env) === 'win32' ? [command] : ['-v', command];
    const p = spawn(probe, args, { stdio: 'ignore' });
    p.on('exit', (code) => resolve(code === 0));
    p.on('error', () => resolve(false));
  });
}
