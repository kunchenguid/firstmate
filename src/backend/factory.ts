// Backend factory — auto-detect and construct the terminal backend.
// Mirrors the bash fm_backend_detect precedence:
//   explicit FM_BACKEND -> platform default -> stdio fallback.
// On Windows the default is `conpty` (falls back to stdio when node-pty is
// missing). On POSIX the default is `tmux` when tmux exists, else stdio.

import type { TerminalBackend } from './types.js';
import { StdioBackend } from './stdio.js';
import { ConptyBackend } from './conpty.js';
import { TmuxBackend } from './tmux.js';
import { platformOf } from '../platform/path-util.js';
import { resolveTool } from '../platform/tools.js';

export type BackendName = 'stdio' | 'conpty' | 'tmux';

export interface BackendFactoryOptions {
  env?: NodeJS.ProcessEnv;
  /** Force a specific backend (from FM_BACKEND or --backend). */
  force?: BackendName;
}

export async function createBackend(opts: BackendFactoryOptions = {}): Promise<TerminalBackend> {
  const env = opts.env ?? process.env;
  const name = await resolveBackendName(opts.force, env);
  return constructBackend(name);
}

export async function resolveBackendName(force: BackendName | undefined, env: NodeJS.ProcessEnv): Promise<BackendName> {
  if (force) return force;
  const explicit = env.FM_BACKEND as BackendName | undefined;
  if (explicit && ['stdio', 'conpty', 'tmux'].includes(explicit)) return explicit;

  const platform = platformOf(env);
  if (platform === 'win32') {
    // Prefer conpty; fall back to stdio if node-pty is unavailable.
    try {
      await import('node-pty');
      return 'conpty';
    } catch {
      return 'stdio';
    }
  }
  // POSIX: tmux when available, else stdio.
  const tmux = await resolveTool('tmux', env);
  return tmux.path ? 'tmux' : 'stdio';
}

export function constructBackend(name: BackendName): TerminalBackend {
  switch (name) {
    case 'conpty':
      try {
        return new ConptyBackend();
      } catch {
        return new StdioBackend();
      }
    case 'tmux':
      try {
        return new TmuxBackend();
      } catch {
        return new StdioBackend();
      }
    default:
      return new StdioBackend();
  }
}
