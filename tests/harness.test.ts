// Harness launcher tests — launch-arg shapes and cmdc alias resolution.
import { describe, it, expect } from 'vitest';
import { harnessLaunchArgs, HarnessLauncher } from '../src/spawn/harness.js';

describe('harnessLaunchArgs', () => {
  it('builds the claude headless form', () => {
    const args = harnessLaunchArgs('claude', '/tmp/brief.md');
    expect(args).toContain('--dangerously-skip-permissions');
    expect(args).toContain('--print');
    expect(args.some((a) => a.includes('/tmp/brief.md'))).toBe(true);
  });

  it('builds the cmdc headless form', () => {
    const args = harnessLaunchArgs('cmdc', '/tmp/brief.md');
    expect(args).toEqual([
      '-p',
      'Execute the task in /tmp/brief.md',
      '--yolo',
      '--output-format',
      'json',
      '--skip-onboarding',
    ]);
  });

  it('cmdc launch args always include yolo + json output', () => {
    const args = harnessLaunchArgs('cmdc', 'brief.md');
    expect(args).toContain('--yolo');
    expect(args).toContain('json');
    expect(args).toContain('--skip-onboarding');
  });
});

describe('HarnessLauncher resolver', () => {
  it('resolves cmdc through the injected resolver', async () => {
    const launcher = new HarnessLauncher(async () => '/opt/bin/cmdc');
    await expect(launcher.resolve('cmdc', {})).resolves.toBe('/opt/bin/cmdc');
  });

  it('rejects an unknown harness', async () => {
    const launcher = new HarnessLauncher(async () => {
      throw new Error('not found');
    });
    await expect(launcher.resolve('cmdc', {})).rejects.toThrow('not found');
  });
});
