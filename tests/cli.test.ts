// CLI tests — dispatch, aliases, and unknown-command handling.
import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest';
import os from 'node:os';
import path from 'node:path';
import { promises as fs } from 'node:fs';

// Import fresh so each test can stub process.exitCode cleanly.
const cli = await import('../src/cli/index.js');

let tmpHome: string;

beforeEach(async () => {
  tmpHome = await fs.mkdtemp(path.join(os.tmpdir(), 'fm-cli-test-'));
  process.env.FM_HOME = tmpHome;
});

afterEach(async () => {
  vi.restoreAllMocks();
  await fs.rm(tmpHome, { recursive: true, force: true });
  delete process.env.FM_HOME;
});

describe('CLI dispatch', () => {
  it('returns 0 for --help', async () => {
    const code = await cli.runCli(['--help']);
    expect(code).toBe(0);
  });

  it('returns 0 for the help command', async () => {
    const code = await cli.runCli(['help']);
    expect(code).toBe(0);
  });

  it('returns 2 for an unknown command', async () => {
    const code = await cli.runCli(['no-such-command']);
    expect(code).toBe(2);
  });

  it('resolves a legacy alias to its canonical command', async () => {
    const code = await cli.runCli(['fm-session-start']);
    expect(code).toBe(0);
  });

  it('runs session-start with a temp FM_HOME', async () => {
    const out: string[] = [];
    const spy = vi.spyOn(console, 'log').mockImplementation((...a) => out.push(String(a[0])));
    const code = await cli.runCli(['session-start']);
    expect(code).toBe(0);
    expect(out.some((l) => l.includes('firstmate session-start (native core)'))).toBe(true);
    spy.mockRestore();
  });

  it('send requires a task id and message', async () => {
    const err: string[] = [];
    const spy = vi.spyOn(console, 'error').mockImplementation((...a) => err.push(String(a[0])));
    expect(await cli.runCli(['send'])).toBe(2);
    expect(await cli.runCli(['send', 'task-1'])).toBe(2);
    expect(err.length).toBeGreaterThan(0);
    spy.mockRestore();
  });

  it('control validates its action', async () => {
    expect(await cli.runCli(['control', 'task-1', 'explode'])).toBe(2);
    // No such task -> returns 1 (not 0).
    expect(await cli.runCli(['control', 'task-1', 'interrupt'])).toBe(1);
  });
});
