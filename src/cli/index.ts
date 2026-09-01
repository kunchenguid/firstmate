// CLI entry — parses argv, resolves subcommands and legacy aliases, runs.

export interface CliContext {
  cwd: string;
  env: NodeJS.ProcessEnv;
  argv: string[];
}

export interface CliCommand {
  name: string;
  summary: string;
  run(ctx: CliContext): Promise<number>;
}

export type CommandRegistry = Map<string, CliCommand>;

export function createContext(argv: string[]): CliContext {
  return { cwd: process.cwd(), env: process.env, argv };
}

export async function runCli(argv: string[]): Promise<number> {
  const ctx = createContext(argv);
  const [rawName, ...rest] = argv;

  if (!rawName || rawName === '--help' || rawName === '-h' || rawName === 'help') {
    printUsage();
    return 0;
  }

  const registry = await loadRegistry();
  const resolved = resolveAlias(rawName, registry);
  if (!resolved) {
    console.error(`fm: unknown command '${rawName}'`);
    printUsage();
    return 2;
  }

  return resolved.run({ ...ctx, argv: rest });
}

// Lazy import avoids pulling the whole command surface into every invocation.
async function loadRegistry(): Promise<CommandRegistry> {
  const { buildRegistry } = await import('./commands/index.js');
  return buildRegistry();
}

const LEGACY_ALIASES: Record<string, string> = {
  'fm-session-start': 'session-start',
  'fm-bootstrap': 'setup',
  'fm-send': 'send',
  'fm-control': 'control',
  'fm-teardown': 'teardown',
  'fm-watch': 'watch',
  'fm-watch-arm': 'watch',
  'fm-crew-state': 'crew-state',
  'fm-backlog': 'backlog',
  'fm-status': 'status',
  'fm-help': 'help',
};

function resolveAlias(name: string, registry: CommandRegistry): CliCommand | undefined {
  if (registry.has(name)) return registry.get(name);
  const canonical = LEGACY_ALIASES[name];
  if (canonical) return registry.get(canonical);
  return undefined;
}

export function printUsage(): void {
  console.log(`firstmate — native core

Usage: fm <command> [args]

Commands:
  setup           Check and install the toolchain
  session-start   Run the one-shot session-start digest (lock, wake queue, fleet)
  spawn           Create a task (worktree + brief + harness session)
  send            Steer a worker through its durable inbox
  control         Interrupt, exit, or relaunch a worker
  teardown        Clean up a finished task
  attach          Attach the captain's terminal to a task session
  capture         Print a task session's recent output
  watch           Run the supervision watcher loop
  crew-state      Show a task's current reconciled state
  backlog         Inspect the task queue
  status          Show fleet status
  help            Show this help

Legacy names (fm-send, fm-control, ...) are accepted as aliases.
Run 'fm <command> --help' for command-specific help.
`);
}
