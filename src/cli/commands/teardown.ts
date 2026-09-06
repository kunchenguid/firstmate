// teardown — clean up a finished task (kill session, remove worktree).
import type { CliCommand } from '../index.js';
import { createBackend } from '../../backend/factory.js';
import { LifecycleService } from '../../control/lifecycle.js';

export const teardownCommand: CliCommand = {
  name: 'teardown',
  summary: 'Clean up a finished task',
  async run({ env, argv }) {
    const taskId = argv[0];
    if (!taskId) {
      console.error('usage: fm teardown <task-id>');
      return 2;
    }
    const backend = await createBackend({ env });
    const lifecycle = new LifecycleService(backend, env);
    try {
      await lifecycle.teardown(taskId);
      console.log(`torn down ${taskId}`);
      return 0;
    } catch (err) {
      console.error(`fm: ${(err as Error).message}`);
      return 1;
    }
  },
};
