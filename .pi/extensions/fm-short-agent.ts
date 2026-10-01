// Explicit opt-in. No background resources are started during extension discovery.
import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { Type } from 'typebox';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { runCommandAsync } from './lib/fm-async-exec.ts';
import { ShortAgents } from '../../bin/fm-short-agent.mjs';
import { SHORT_RESULT_LOADED_EVENT } from '../../bin/fm-short-notification.mjs';

export default function (pi: ExtensionAPI) {
  if (process.env.FM_SHORT_AGENT_ENABLED !== '1' || !process.env.FM_HOME) return;
  const home = resolve(process.env.FM_HOME);
  const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
  let service: ShortAgents | undefined;
  let timer: ReturnType<typeof setInterval> | undefined;
  let busy = false;
  let active = false;
  let lastError = '';
  const owner = async () => {
    try {
      const lock = resolve(home, 'state/.lock');
      const expected = readFileSync(lock, 'utf8').trim();
      if (!/^[0-9]+$/.test(expected) || expected === '1') return false;
      let pid = String(process.pid);
      for (let depth = 0; depth < 8 && pid !== '1'; depth++) {
        if (pid === expected) return readFileSync(lock, 'utf8').trim() === expected;
        const result = await runCommandAsync('ps', ['-o', 'ppid=', '-p', pid], { maxBuffer: 1024 });
        pid = result.stdout.trim();
        if (!/^[0-9]+$/.test(pid)) return false;
      }
      return false;
    } catch { return false; }
  };
  const get = async () => {
    if (!(await owner())) throw Error('short-agent control requires the owning primary Pi session lock');
    return service ??= new ShortAgents(home, root);
  };
  // The primary outlives home updates. Its cached ShortAgents module cannot
  // read receipts introduced by a newer owner, even after files are updated.
  // Read/reconcile through the current public owner; its evidence and process
  // guards remain authoritative and no cleanup effect is replayed here.
  const currentOwner = async (action: 'status' | 'reconcile', id?: string) => {
    if (!(await owner())) throw Error('short-agent control requires the owning primary Pi session lock');
    const result = await runCommandAsync(process.execPath,
      [resolve(root, 'bin/fm-short-agent.mjs'), action, ...(id ? [id] : [])], {
        env: { ...process.env, FM_HOME: home, FM_ROOT_OVERRIDE: root,
          FM_STATE_OVERRIDE: resolve(home, 'state'), FM_DATA_OVERRIDE: resolve(home, 'data'),
          FM_CONFIG_OVERRIDE: resolve(home, 'config') },
        maxBuffer: Number.POSITIVE_INFINITY,
      });
    if (result.status !== 0) throw Error(result.stderr.trim() || `short-agent ${action} failed`);
    return JSON.parse(result.stdout);
  };
  const reconcile = async () => {
    if (busy) return;
    busy = true;
    try {
      if (!(await owner())) return;
      await currentOwner('reconcile');
      if (!active) return;
      lastError = '';
    }
    catch (error) {
      const message = `Short-agent notification recovery failed: ${String(error).slice(0, 512)}`;
      if (active && message !== lastError) pi.sendMessage({ customType: 'fm-short-agent-error', content: message, display: true });
      lastError = message;
    }
    finally { busy = false; if (active) pi.events.emit('firstmate:outcomes-ready', {}); }
  };
  pi.on('session_start', () => {
    active = true;
    if (timer) clearInterval(timer);
    timer = setInterval(() => { void reconcile(); }, 2000);
    timer.unref();
    void reconcile();
  });
  pi.on('session_shutdown', () => { active = false; if (timer) clearInterval(timer); timer = undefined; });
  pi.registerTool({
    name: 'fm_short_submit', label: 'Submit short task',
    description: 'Offload an analysis or explicitly authorized finite operation chain to an independent headless Pi session. Returns durable ID immediately. Defaults to openai-codex/gpt-5.6-luna; explicit authenticated overrides are preserved. Firstmate applies no task input, output, request, tool-call, or wall-clock budget; provider and model context limits still apply. Operations require concrete existing authority, exact targets and expiry; files are canonical explicit text snapshots. Reuse key only for identical retries. No terminal/worktree or parent history.',
    parameters: Type.Object({ key: Type.String(), goal: Type.String(), acceptance: Type.String(), provider: Type.Optional(Type.String()), model: Type.Optional(Type.String()),
      operations: Type.Optional(Type.Object({ expiresAt: Type.Integer(), authority: Type.String(), steps: Type.Array(Type.Union([
        Type.Object({ action: Type.Literal('sync'), project: Type.String() }),
        Type.Object({ action: Type.Literal('recover-sync'), project: Type.String() }),
        Type.Object({ action: Type.Literal('install-shellcheck'), destination: Type.String() }),
        Type.Object({ action: Type.Literal('merge'), task: Type.String(), url: Type.String() }),
        Type.Object({ action: Type.Literal('cleanup'), task: Type.String() }),
      ]), { minItems: 1, maxItems: 4 }) })),
      materials: Type.Array(Type.String()),
    }),
    async execute(_id, args) {
      const result = (await get()).submit(args);
      return { content: [{ type: 'text', text: JSON.stringify(result) }], details: result };
    },
  });
  pi.registerTool({
    name: 'fm_short_task', label: 'Inspect or cancel short task',
    description: 'Read status/result or cancel a short-agent ID. Use result to retrieve the complete unchanged body when a completion notification carries only a durable reference. Cancellation preserves the first terminal result. Detailed evidence stays local; ordinary notification acknowledgement uses fm_branch_processed.',
    parameters: Type.Object({ id: Type.String(), action: Type.Union([Type.Literal('status'), Type.Literal('result'), Type.Literal('cancel')]) }),
    async execute(_id, args) {
      const result = args.action === 'cancel' ? (await get()).cancel(args.id) : await currentOwner('status', args.id);
      if (args.action !== 'cancel' && result.state === 'completed') {
        pi.events.emit(SHORT_RESULT_LOADED_EVENT, { id: args.id, summary: result.summary });
      }
      void reconcile();
      return { content: [{ type: 'text', text: JSON.stringify(result) }], details: result };
    },
  });
}
