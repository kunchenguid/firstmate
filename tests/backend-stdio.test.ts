// Stdio backend tests — create, capture, send, kill.
import { describe, it, expect } from 'vitest';
import { StdioBackend } from '../src/backend/stdio.js';
import { createBackend } from '../src/backend/factory.js';

describe('StdioBackend', () => {
  it('creates a session and captures output', async () => {
    const backend = new StdioBackend();
    const node = process.execPath;
    await backend.create({
      taskId: 't1',
      cwd: process.cwd(),
      command: node,
      args: ['-e', 'console.log("hello from stdio"); setTimeout(() => {}, 60000);'],
    });
    expect(await backend.exists('t1')).toBe(true);
    // Poll until the output lands (bounded; stretches under load).
    let out = '';
    for (let i = 0; i < 50; i++) {
      out = await backend.capture('t1');
      if (out.includes('hello from stdio')) break;
      await new Promise((r) => setTimeout(r, 100));
    }
    expect(out).toContain('hello from stdio');
    await backend.kill('t1');
  });

  it('detects a dead session', async () => {
    const backend = new StdioBackend();
    await backend.create({
      taskId: 't2',
      cwd: process.cwd(),
      command: process.execPath,
      args: ['-e', 'process.exit(0);'],
    });
    // Poll until the process exits (bounded; stretches under load).
    let dead = false;
    for (let i = 0; i < 50; i++) {
      if (!(await backend.exists('t2'))) {
        dead = true;
        break;
      }
      await new Promise((r) => setTimeout(r, 100));
    }
    expect(dead).toBe(true);
    expect(await backend.agentState('t2')).toBe('dead');
  });

  it('factory returns stdio when FM_BACKEND=stdio', async () => {
    const backend = await createBackend({ env: { FM_BACKEND: 'stdio' } as NodeJS.ProcessEnv });
    expect(backend.name).toBe('stdio');
  });
});
