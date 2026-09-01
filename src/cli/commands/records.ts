// Reusable record helpers shared by CLI commands.
import { promises as fs } from 'node:fs';
import path from 'node:path';
import os from 'node:os';

export interface HomePaths {
  /** Root of the firstmate operational home (data/, state/, config/, projects/). */
  home: string;
  state: string;
  data: string;
  config: string;
}

/** Resolve FM_HOME, mirroring the bash fleet's home selection. */
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
  };
}

export async function ensureHomeDirs(env: NodeJS.ProcessEnv): Promise<HomePaths> {
  const p = homePaths(env);
  await Promise.all([p.state, p.data, p.config].map((d) => fs.mkdir(d, { recursive: true })));
  return p;
}
