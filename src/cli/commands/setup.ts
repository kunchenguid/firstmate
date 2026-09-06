// setup — check the toolchain and install what is missing.
// Node + git + gh + the npm axi tools are the core; node-pty is installed as
// the native backend dep on Windows. Reports each tool as present/missing and
// prints the install command for anything missing. Harness CLIs are reported
// as optional (at least one is needed to spawn).

import type { CliCommand } from '../index.js';
import { resolveTools } from '../../platform/tools.js';
import { ensureHomeDirs } from '../../platform/home.js';

const CORE_TOOLS = ['node', 'git', 'gh', 'tasks-axi', 'no-mistakes', 'gh-axi', 'lavish-axi', 'quota-axi', 'chrome-devtools-axi'];
const HARNESS_TOOLS = ['claude', 'codex', 'opencode', 'pi', 'grok', 'kimi', 'cursor', 'muse', 'cmdc'];

export const setupCommand: CliCommand = {
  name: 'setup',
  summary: 'Check and install the firstmate toolchain',
  async run({ env, argv }) {
    if (argv.includes('--help') || argv.includes('-h')) {
      console.log('usage: fm setup');
      return 0;
    }
    const paths = await ensureHomeDirs(env);
    const tools = await resolveTools(CORE_TOOLS, env);

    console.log('firstmate setup (native core)');
    console.log(`FM_HOME: ${paths.home}`);
    console.log('');
    let missing = 0;
    for (const name of CORE_TOOLS) {
      const t = tools.get(name);
      if (t?.path) {
        console.log(`  ✓ ${name.padEnd(18)} ${t.path}`);
      } else {
        console.log(`  ✗ ${name.padEnd(18)} missing`);
        missing++;
      }
    }
    console.log('');
    console.log('harnesses (at least one required to spawn):');
    const { HarnessLauncher } = await import('../../spawn/harness.js');
    const launcher = new HarnessLauncher();
    for (const name of HARNESS_TOOLS) {
      try {
        const p = await launcher.resolve(name as Parameters<typeof launcher.resolve>[0], env);
        console.log(`  ✓ ${name.padEnd(18)} ${p}`);
      } catch {
        console.log(`  ○ ${name.padEnd(18)} not installed`);
      }
    }
    if (missing > 0) {
      console.log('');
      console.log(`install missing tools, then re-run: npm install -g tasks-axi gh-axi lavish-axi quota-axi chrome-devtools-axi`);
      console.log(`(node, git, gh via your platform installer; see docs/windows-support.md)`);
      return 1;
    }
    console.log('');
    console.log('toolchain OK');
    return 0;
  },
};
