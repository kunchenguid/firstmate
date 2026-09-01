// backlog — inspect the task queue.
import type { CliCommand } from '../index.js';
import { createBacklogClient } from '../../backlog/index.js';

export const backlogCommand: CliCommand = {
  name: 'backlog',
  summary: 'Inspect the task queue',
  async run({ env, argv }) {
    if (argv.includes('--help') || argv.includes('-h')) {
      console.log('usage: fm backlog [list]');
      return 0;
    }
    const client = await createBacklogClient(env);
    const items = await client.list();
    if (items.length === 0) {
      console.log('backlog is empty');
      return 0;
    }
    for (const item of items) {
      console.log(`${item.status.padEnd(9)} ${item.id.padEnd(10)} ${item.subject}`);
    }
    return 0;
  },
};
