// watch — run the supervision watcher loop.
import type { CliCommand } from '../index.js';
import { createBackend } from '../../backend/factory.js';
import { Watcher } from '../../supervise/watcher.js';

export const watchCommand: CliCommand = {
  name: 'watch',
  summary: 'Run the supervision watcher loop',
  async run({ env, argv }) {
    if (argv.includes('--help') || argv.includes('-h')) {
      console.log('usage: fm watch [--once]');
      return 0;
    }
    const backend = await createBackend({ env });
    const watcher = new Watcher(backend, env);
    const once = argv.includes('--once');
    try {
      await watcher.run({ once });
      return 0;
    } catch (err) {
      console.error(`fm: ${(err as Error).message}`);
      return 1;
    }
  },
};
