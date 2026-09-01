// HarnessLauncher — resolve and launch a coding-agent harness CLI.
// Mirrors the verified harness set from the bash fleet: claude, codex,
// opencode, pi, grok, kimi, cursor, muse — plus cmdc (Command Code).
// Each has a known launch form. On Windows, resolver output goes through
// resolveTool, which prefers real .cmd/.exe files over extensionless shims.

import { spawn, type ChildProcess } from 'node:child_process';
import { resolveTool } from '../platform/tools.js';

export type HarnessName =
  | 'claude'
  | 'codex'
  | 'opencode'
  | 'pi'
  | 'grok'
  | 'kimi'
  | 'cursor'
  | 'muse'
  | 'cmdc';

export interface HarnessResolver {
  (name: HarnessName, env: NodeJS.ProcessEnv): Promise<string>;
}

const LAUNCH_ARGS: Record<HarnessName, (promptFile: string) => string[]> = {
  // --verbose is required by claude whenever --print is combined with
  // --output-format stream-json (rejected otherwise: "requires --verbose").
  claude: (p) => ['--dangerously-skip-permissions', '--print', '--output-format', 'stream-json', '--verbose', `Execute the task in ${p}`],
  codex: (p) => ['exec', '--dangerously-bypass-approvals-and-sandbox', `Run the task described in ${p}`],
  opencode: (p) => ['--prompt', `Execute the task in ${p}`],
  pi: (p) => ['-e', p],
  grok: (p) => ['--always-approve', '-p', `Execute the task in ${p}`],
  kimi: (p) => ['--auto', p],
  cursor: (p) => ['--trust', 'run', `Execute the task in ${p}`],
  muse: (p) => ['--yolo', p],
  // Command Code headless: -p query, --yolo to allow edits/shell,
  // --output-format json for machine-readable results, --skip-onboarding for CI.
  cmdc: (p) => ['-p', `Execute the task in ${p}`, '--yolo', '--output-format', 'json', '--skip-onboarding'],
};

/** Build the launch args for a harness (shared by launcher and spawn). */
export function harnessLaunchArgs(name: HarnessName, promptFile: string): string[] {
  return LAUNCH_ARGS[name](promptFile);
}

export class HarnessLauncher {
  constructor(private readonly resolver: HarnessResolver = defaultResolver) {}

  async resolve(name: HarnessName, env: NodeJS.ProcessEnv): Promise<string> {
    return this.resolver(name, env);
  }

  launch(name: HarnessName, promptFile: string, cwd: string, env: NodeJS.ProcessEnv): ChildProcess {
    const args = harnessLaunchArgs(name, promptFile);
    const envExtra: NodeJS.ProcessEnv =
      name === 'claude' ? { CLAUDECODE: '1' }
      : name === 'pi' ? { PI_CODING_AGENT: 'true' }
      : name === 'grok' ? { GROK_AGENT: '1' }
      : name === 'muse' ? { MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL: 'on' }
      : {};
    return spawn(this.commandName(name), args, {
      cwd,
      env: { ...env, ...envExtra },
      stdio: ['ignore', 'pipe', 'pipe'],
      shell: false,
    });
  }

  private commandName(name: HarnessName): string {
    return name;
  }
}

/** Command Code installs as `cmdc`/`command-code`/`commandcode` (and `cmd`,
 *  but that collides with the Windows shell, so it is never auto-resolved).
 *  Prefer cmdc, then command-code, then commandcode. */
const CMDC_ALIASES = ['cmdc', 'command-code', 'commandcode'];

async function defaultResolver(name: HarnessName, env: NodeJS.ProcessEnv): Promise<string> {
  if (name === 'cmdc') {
    for (const alias of CMDC_ALIASES) {
      const tool = await resolveTool(alias, env);
      if (tool.path) return tool.path;
    }
    throw new Error(`harness 'cmdc' not found on PATH (tried ${CMDC_ALIASES.join(', ')})`);
  }
  const tool = await resolveTool(name, env);
  if (!tool.path) throw new Error(`harness '${name}' not found on PATH`);
  return tool.path;
}
