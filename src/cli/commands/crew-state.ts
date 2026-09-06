// crew-state — show a task's current reconciled state.
import type { CliCommand } from '../index.js';
import { createBackend } from '../../backend/factory.js';
import { CrewStateService } from '../../supervise/crew-state.js';

export const crewStateCommand: CliCommand = {
  name: 'crew-state',
  summary: 'Show a task current reconciled state',
  async run({ env, argv }) {
    const taskId = argv[0];
    if (!taskId) {
      console.error('usage: fm crew-state <task-id>');
      return 2;
    }
    const backend = await createBackend({ env });
    const service = new CrewStateService(backend, env);
    try {
      const state = await service.state(taskId);
      console.log(`task:     ${state.taskId}`);
      console.log(`backend:  ${state.backend} (${state.endpoint})`);
      console.log(`agent:    ${state.agent}`);
      console.log(`steers:   ${state.pendingSteers} pending`);
      console.log(`events:`);
      for (const e of state.lastEvents) console.log(`  ${e}`);
      return 0;
    } catch (err) {
      console.error(`fm: ${(err as Error).message}`);
      return 1;
    }
  },
};
