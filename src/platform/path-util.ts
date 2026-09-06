// PathUtil — cross-platform path handling.
// Windows is case-insensitive; macOS/Linux are case-sensitive. Normalizes home
// expansion, converts win32 <-> posix forms, and provides portable comparisons.

import path from 'node:path';
import os from 'node:os';

export type Platform = 'win32' | 'darwin' | 'linux';

export function platformOf(env?: NodeJS.ProcessEnv): Platform {
  return (env?.FIRSTMATE_PLATFORM as Platform) ?? (process.platform as Platform);
}

export function isWindows(env?: NodeJS.ProcessEnv): boolean {
  return platformOf(env) === 'win32';
}

/** Expand a leading ~ to the home dir, matching bash tilde expansion. */
export function expandHome(p: string): string {
  if (p === '~') return os.homedir();
  if (p.startsWith('~/') || p.startsWith('~\\')) return path.join(os.homedir(), p.slice(2));
  return p;
}

/** Compare paths case-insensitively on Windows, case-sensitively elsewhere. */
export function samePath(a: string, b: string, env?: NodeJS.ProcessEnv): boolean {
  const na = path.normalize(a);
  const nb = path.normalize(b);
  if (isWindows(env)) return na.toLowerCase() === nb.toLowerCase();
  return na === nb;
}

/**
 * Convert a path for the target platform.
 * On Windows: forward slashes -> backslashes, and strip any MSYS/Cygwin
 * `/c/...` or `/mnt/c/...` drive prefixes when converting to native form.
 */
export function toNative(p: string, env?: NodeJS.ProcessEnv): string {
  const win = isWindows(env);
  const sep = win ? '\\' : '/';
  let out = p;
  if (win) {
    out = out.replace(/\//g, sep);
    out = out.replace(/^([a-zA-Z]):[\\/]/, (_, drive) => `${drive.toUpperCase()}:${sep}`);
  }
  return out;
}

/** Convert a path to forward-slash form (canonical in firstmate records). */
export function toPosix(p: string): string {
  return p.replace(/\\/g, '/');
}

/** Whether a path is an absolute Windows or POSIX path. */
export function isAbsolute(p: string): boolean {
  return path.isAbsolute(p) || /^[a-zA-Z]:[\\/]/.test(p) || p.startsWith('\\\\') || p.startsWith('//');
}

/** Join segments, normalizing separators for the current platform. */
export function join(...parts: string[]): string {
  return path.join(...parts);
}
