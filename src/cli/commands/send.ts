// send — steer a worker through its durable inbox + doorbell.
import type { CliCommand } from '../index.js';
import { createBackend } from '../../backend/factory.js';
import { LifecycleService } from '../../control/lifecycle.js';

export const sendCommand: CliCommand = {
  name: 'send',
  summary: 'Steer a worker through its durable inbox',
  async run({ env, argv }) {
    const taskId = argv[0];
    const message = argv.slice(1).join(' ');
    if (!taskId || !message) {
      console.error('usage: fm send <task-id> <message>');
      return 2;
    }
    const backend = await createBackend({ env });
    const lifecycle = new LifecycleService(backend, env);
    try {
      const seq = await lifecycle.send(taskId, message);
      console.log(`queued steer for ${taskId} (seq ${seq})`);
      return 0;
    } catch (err) {
      console.error(`fm: ${(err as Error).message}`);
      return 1;
    }
  },
};
