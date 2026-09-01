// Command registry — maps subcommand names to implementations.
import type { CliCommand, CommandRegistry } from '../index.js';

export async function buildRegistry(): Promise<CommandRegistry> {
  const { sessionStartCommand } = await import('./session-start.js');
  const { sendCommand } = await import('./send.js');
  const { controlCommand } = await import('./control.js');
  const { teardownCommand } = await import('./teardown.js');
  const { watchCommand } = await import('./watch.js');
  const { crewStateCommand } = await import('./crew-state.js');
  const { backlogCommand } = await import('./backlog.js');
  const { statusCommand } = await import('./status.js');
  const { spawnCommand } = await import('./spawn.js');
  const { setupCommand } = await import('./setup.js');
  const { attachCommand } = await import('./attach.js');
  const { captureCommand } = await import('./capture.js');
  const { helpCommand } = await import('./help.js');

  const commands: CliCommand[] = [
    sessionStartCommand,
    sendCommand,
    controlCommand,
    teardownCommand,
    watchCommand,
    crewStateCommand,
    backlogCommand,
    statusCommand,
    spawnCommand,
    setupCommand,
    attachCommand,
    captureCommand,
    helpCommand,
  ];

  const registry: CommandRegistry = new Map();
  for (const cmd of commands) registry.set(cmd.name, cmd);
  return registry;
}
