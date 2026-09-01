// control — interrupt, exit, or relaunch a worker.
import type { CliCommand } from '../index.js';
import { createBackend } from '../../backend/factory.js';
import { LifecycleService, type ControlAction } from '../../control/lifecycle.js';

const ACTIONS: ControlAction[] = ['interrupt', 'exit', 'relaunch'];

export const controlCommand: CliCommand = {
  name: 'control',
  summary: 'Interrupt, exit, or relaunch a worker',
  async run({ env, argv }) {
    const taskId = argv[0];
    const action = argv[1] as ControlAction;
    if (!taskId || !ACTIONS.includes(action)) {
      console.error('usage: fm control <task-id> interrupt|exit|relaunch');
      return 2;
    }
    const backend = await createBackend({ env });
    const lifecycle = new LifecycleService(backend, env);
    try {
      await lifecycle.control(taskId, action);
      console.log(`${action} sent to ${taskId}`);
      return 0;
    } catch (err) {
      console.error(`fm: ${(err as Error).message}`);
      return 1;
    }
  },
};
