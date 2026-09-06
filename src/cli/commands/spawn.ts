// spawn — create a task: worktree + brief + harness session.
import type { CliCommand } from '../index.js';
import { createBackend } from '../../backend/factory.js';
import { SpawnService } from '../../spawn/index.js';
import type { HarnessName } from '../../spawn/harness.js';

const HARNESSES: HarnessName[] = ['claude', 'codex', 'opencode', 'pi', 'grok', 'kimi', 'cursor', 'muse', 'cmdc'];

export const spawnCommand: CliCommand = {
  name: 'spawn',
  summary: 'Create a task (worktree + brief + harness session)',
  async run({ env, argv }) {
    const harness = argv[0] as HarnessName;
    const project = argv[1];
    const subject = argv.slice(2).join(' ');
    if (!HARNESSES.includes(harness) || !project || !subject) {
      console.error('usage: fm spawn <harness> <project-path> <subject>');
      console.error(`harnesses: ${HARNESSES.join(', ')}`);
      return 2;
    }
    const backend = await createBackend({ env });
    const service = new SpawnService(backend, env);
    try {
      const result = await service.spawn({
        project,
        subject,
        harness,
        deliveryMode: (env.FM_DELIVERY as 'no-mistakes' | 'direct-PR' | 'local-only') ?? 'no-mistakes',
        yolo: env.FM_YOLO === '1',
      });
      console.log(`spawned ${result.taskId}`);
      console.log(`  worktree: ${result.worktree}`);
      console.log(`  branch:   ${result.branch}`);
      console.log(`  backend:  ${result.backend} (${result.endpoint})`);
      return 0;
    } catch (err) {
      console.error(`fm: ${(err as Error).message}`);
      return 1;
    }
  },
};
