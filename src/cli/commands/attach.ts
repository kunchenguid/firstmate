// attach — attach the captain's terminal to a task session.
import type { CliCommand } from '../index.js';
import { createBackend } from '../../backend/factory.js';
import { LifecycleService } from '../../control/lifecycle.js';

export const attachCommand: CliCommand = {
  name: 'attach',
  summary: 'Attach the captain terminal to a task session',
  async run({ env, argv }) {
    const taskId = argv[0];
    if (!taskId) {
      console.error('usage: fm attach <task-id>');
      return 2;
    }
    const backend = await createBackend({ env });
    const lifecycle = new LifecycleService(backend, env);
    try {
      return await lifecycle.attach(taskId);
    } catch (err) {
      console.error(`fm: ${(err as Error).message}`);
      return 1;
    }
  },
};
