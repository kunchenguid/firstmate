// session-start — run the one-shot startup digest (lock, wake queue, fleet).
import type { CliCommand } from '../index.js';
import { createBackend } from '../../backend/factory.js';
import { SessionStartService } from '../../fleet/session-start.js';

export const sessionStartCommand: CliCommand = {
  name: 'session-start',
  summary: 'Run the one-shot session-start digest',
  async run({ env }) {
    const backend = await createBackend({ env });
    const service = new SessionStartService(backend, env);
    const result = await service.run();

    console.log('firstmate session-start (native core)');
    console.log(`lock: ${result.lockHeld ? 'held' : `refused (${result.lockReason})`}`);
    console.log(`wake queue: ${result.wakes} record(s)`);
    console.log(`fleet: ${result.fleet.length} task(s)`);
    for (const t of result.fleet) {
      console.log(`  ${t.id}: ${t.agent}`);
    }
    if (!result.lockHeld) {
      console.error(`fm: session lock refused (${result.lockReason}); remaining read-only`);
      return 1;
    }
    return 0;
  },
};
