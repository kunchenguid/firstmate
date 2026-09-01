// ToolResolver — locate external binaries across platforms.
// Replaces `command -v` with `where.exe` on Windows, and handles the .cmd
// shims npm global packages install. Fail-closed: a tool that cannot be
// resolved is reported missing, never guessed.

import { spawn } from 'node:child_process';
import { promises as fs } from 'node:fs';
import { platformOf } from './path-util.js';

export interface ToolInfo {
  name: string;
  /** Absolute path to the executable, or null if not found. */
  path: string | null;
  /** True when the binary is a Windows .cmd/.bat shim (npm globals). */
  isCmdShim: boolean;
}

/** On Windows, `where` lists extensionless npm-shim names that are not real
 *  files; only entries whose file actually exists are usable by spawn. */
async function existingPath(candidate: string): Promise<string | null> {
  try {
    const st = await fs.stat(candidate);
    return st.isFile() ? candidate : null;
  } catch {
    return null;
  }
}

export async function resolveTool(name: string, env?: NodeJS.ProcessEnv): Promise<ToolInfo> {
  const win = platformOf(env) === 'win32';
  const probe = win ? 'where.exe' : 'command';
  const args = win ? [name] : ['-v', name];

  const result = await new Promise<string[] | null>((resolve) => {
    const p = spawn(probe, args, { stdio: ['ignore', 'pipe', 'ignore'] });
    let out = '';
    p.stdout.on('data', (d: Buffer) => (out += d.toString()));
    p.on('error', () => resolve(null));
    p.on('exit', (code) => resolve(code === 0 ? out.split(/\r?\n/).filter(Boolean) : null));
  });

  if (!result) return { name, path: null, isCmdShim: false };
  // Two passes: prefer candidates with a real Windows executable extension
  // (.cmd/.bat/.exe/.com). Extensionless files exist on PATH (POSIX shell
  // shims from npm) but node's spawn cannot execute them on Windows.
  const candidates = result.map((c) => c.trim()).filter(Boolean);
  const winExt = /\.(cmd|bat|exe|com)$/i;
  const ordered = win
    ? [...candidates.filter((c) => winExt.test(c)), ...candidates.filter((c) => !winExt.test(c))]
    : candidates;
  for (const candidate of ordered) {
    const real = await existingPath(candidate);
    if (!real) continue;
    const isCmdShim = /\.(cmd|bat)$/i.test(real);
    return { name, path: real, isCmdShim };
  }
  return { name, path: null, isCmdShim: false };
}

/** Resolve several tools at once, returning a map keyed by name. */
export async function resolveTools(
  names: string[],
  env?: NodeJS.ProcessEnv,
): Promise<Map<string, ToolInfo>> {
  const entries = await Promise.all(names.map((n) => resolveTool(n, env)));
  return new Map(entries.map((t) => [t.name, t]));
}

/** True when every named tool resolves. */
export async function toolsPresent(names: string[], env?: NodeJS.ProcessEnv): Promise<boolean> {
  const found = await resolveTools(names, env);
  return names.every((n) => found.get(n)?.path);
}
