// HomePaths — resolve the firstmate operational home and its subdirectories.
// Mirrors the bash fleet: FM_HOME selects an instance's private data/,
// state/, config/, and projects/; scripts come from the tracked code root.

import { promises as fs } from 'node:fs';
import path from 'node:path';
import os from 'node:os';

export interface HomePaths {
  /** Root of the firstmate operational home. */
  home: string;
  state: string;
  data: string;
  config: string;
  projects: string;
  /** The tracked repo root containing bin/, src/, etc. */
  codeRoot: string;
}

/** Resolve the tracked code root (the repo containing this package). */
export function resolveCodeRoot(): string {
  // When run from dist/, the source root is two levels up from this file's
  // compiled location (dist/src/platform) — but under vitest it's src/.
  const here = import.meta.url;
  const distMarker = here.includes('/dist/');
  const srcDir = distMarker
    ? new URL('../../', import.meta.url).pathname
    : new URL('../../../', import.meta.url).pathname;
  return decodeURIComponent(srcDir.replace(/^\/[A-Za-z]:/, (m) => m.toLowerCase()));
}

/** Resolve FM_HOME, defaulting to ~/.firstmate. */
export function resolveHome(env: NodeJS.ProcessEnv): string {
  return env.FM_HOME ?? path.join(os.homedir(), '.firstmate');
}

export function homePaths(env: NodeJS.ProcessEnv): HomePaths {
  const home = resolveHome(env);
  return {
    home,
    state: path.join(home, 'state'),
    data: path.join(home, 'data'),
    config: path.join(home, 'config'),
    projects: path.join(home, 'projects'),
    codeRoot: resolveCodeRoot(),
  };
}

export async function ensureHomeDirs(env: NodeJS.ProcessEnv): Promise<HomePaths> {
  const p = homePaths(env);
  await Promise.all(
    [p.state, p.data, p.config, p.projects].map((d) => fs.mkdir(d, { recursive: true })),
  );
  return p;
}
