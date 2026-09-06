// status — show fleet status (tasks + agent states).
import type { CliCommand } from '../index.js';
import { createBackend } from '../../backend/factory.js';
import { TaskMetaStore } from '../../records/task-meta.js';
import { ensureHomeDirs } from '../../platform/home.js';

export const statusCommand: CliCommand = {
  name: 'status',
  summary: 'Show fleet status',
  async run({ env, argv }) {
    if (argv.includes('--help') || argv.includes('-h')) {
      console.log('usage: fm status');
      return 0;
    }
    const backend = await createBackend({ env });
    const paths = await ensureHomeDirs(env);
    const store = new TaskMetaStore(paths.state);
    const metas = await store.list();
    console.log(`firstmate status (native core)`);
    console.log(`FM_HOME: ${paths.home}`);
    console.log(`backend: ${backend.name}`);
    console.log(`tasks:   ${metas.length}`);
    for (const meta of metas) {
      const agent = await backend.agentState(meta.id).catch(() => 'unreadable' as const);
      console.log(`  ${meta.id}: ${agent} (${meta.backend})`);
    }
    return 0;
  },
};
