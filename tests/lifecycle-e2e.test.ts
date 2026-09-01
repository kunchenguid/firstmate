// End-to-end lifecycle test: spawn -> send -> control -> teardown.
// Uses the stdio backend and a fake harness script so no real agent runs.
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import os from 'node:os';
import path from 'node:path';
import { promises as fs } from 'node:fs';
import { spawn } from 'node:child_process';
import { StdioBackend } from '../src/backend/stdio.js';
import { SpawnService } from '../src/spawn/index.js';
import { LifecycleService } from '../src/control/lifecycle.js';
import { TaskMetaStore } from '../src/records/task-meta.js';
import { JsonlBacklog } from '../src/backlog/index.js';

let tmp: string;
let projectDir: string;
let env: NodeJS.ProcessEnv;

async function git(args: string[], cwd: string): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const p = spawn('git', args, { cwd, stdio: 'ignore' });
    p.on('exit', (code) => (code === 0 ? resolve() : reject(new Error(`git ${args[0]} failed: ${code}`))));
    p.on('error', reject);
  });
}

beforeEach(async () => {
  tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'fm-e2e-test-'));
  projectDir = path.join(tmp, 'proj');
  await fs.mkdir(projectDir);
  await git(['init'], projectDir);
  await fs.writeFile(path.join(projectDir, 'README.md'), '# test project\n', 'utf8');
  await git(['add', '.'], projectDir);
  await git(['-c', 'user.email=test@test', '-c', 'user.name=test', 'commit', '-m', 'init'], projectDir);

  env = { ...process.env, FM_HOME: path.join(tmp, 'home') };
});

afterEach(async () => {
  await fs.rm(tmp, { recursive: true, force: true });
});

// A fake harness: echoes a line, reads stdin until "exit", then exits.
async function writeFakeHarness(): Promise<string> {
  const script = path.join(tmp, 'fake-harness.cjs');
  const body = `
    const readline = require('node:readline');
    const rl = readline.createInterface({ input: process.stdin });
    console.log('FAKE_HARNESS_READY');
    rl.on('line', (line) => {
      if (line.includes('exit')) process.exit(0);
    });
  `;
  await fs.writeFile(script, body, 'utf8');
  return script;
}

describe('spawn -> lifecycle e2e', () => {
  it('spawns a task, sends a steer, controls, and tears down', async () => {
    const backend = new StdioBackend();
    const fakeHarness = await writeFakeHarness();
    const service = new SpawnService(backend, env);

    const result = await service.spawn({
      project: projectDir,
      subject: 'test task',
      harness: 'claude',
      deliveryMode: 'local-only',
      // Run node executing the fake harness script, so no real agent CLI is needed.
      harnessOverride: { command: process.execPath, args: [fakeHarness] },
    });

    expect(result.taskId).toBeTruthy();
    expect(result.backend).toBe('stdio');
    // The worktree was created inside the project's parent.
    expect(result.worktree).toContain('.fm-');

    // The fake harness launched (node runs it), so the backend session exists.
    const exists = await backend.exists(result.taskId);
    expect(exists).toBe(true);

    // Send a steer.
    const lifecycle = new LifecycleService(backend, env);
    const seq = await lifecycle.send(result.taskId, 'please continue');
    expect(seq).toBeGreaterThan(0);

    // Teardown refuses while steers are pending.
    await expect(lifecycle.teardown(result.taskId)).rejects.toThrow(/unacknowledged/);

    // Acknowledge the steer, then teardown succeeds.
    const store = new TaskMetaStore(path.join(env.FM_HOME!, 'state'));
    const inbox = new (await import('../src/records/steering-inbox.js')).SteeringInbox(`${store.stateDir}/${result.taskId}.inbox`);
    await inbox.acknowledge(seq);
    await lifecycle.teardown(result.taskId);

    // Task meta is gone after teardown.
    expect(await store.read(result.taskId)).toBeNull();
  });

  it('records the task in the backlog', async () => {
    const backend = new StdioBackend();
    const fakeHarness = await writeFakeHarness();
    const service = new SpawnService(backend, env);
    const result = await service.spawn({
      project: projectDir,
      subject: 'backlog task',
      harness: 'claude',
      harnessOverride: { command: process.execPath, args: [fakeHarness] },
    });
    const backlog = new JsonlBacklog(env);
    const items = await backlog.list();
    expect(items.some((i) => i.subject === 'backlog task')).toBe(true);
    // Kill the session so the worktree dir is not locked on Windows.
    await backend.kill(result.taskId);
  });
});
