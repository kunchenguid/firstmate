// capture — print a task session's recent output.
import type { CliCommand } from '../index.js';
import { createBackend } from '../../backend/factory.js';
import { LifecycleService } from '../../control/lifecycle.js';

export const captureCommand: CliCommand = {
  name: 'capture',
  summary: 'Print a task session recent output',
  async run({ env, argv }) {
    const taskId = argv[0];
    if (!taskId) {
      console.error('usage: fm capture <task-id> [lines]');
      return 2;
    }
    const lines = Number(argv[1]) || 50;
    const backend = await createBackend({ env });
    const lifecycle = new LifecycleService(backend, env);
    try {
      const out = await lifecycle.capture(taskId, lines);
      process.stdout.write(out + (out ? '\n' : ''));
      return 0;
    } catch (err) {
      console.error(`fm: ${(err as Error).message}`);
      return 1;
    }
  },
};
