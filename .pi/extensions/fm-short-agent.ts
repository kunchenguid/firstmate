// Explicit opt-in. No background resources are started during extension discovery.
import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { Type } from 'typebox';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { runCommandAsync } from './lib/fm-async-exec.ts';
import { ShortAgents } from '../../bin/fm-short-agent.mjs';

export default function (pi: ExtensionAPI) {
  if (process.env.FM_SHORT_AGENT_ENABLED !== '1' || !process.env.FM_HOME) return;
  const home = resolve(process.env.FM_HOME);
  const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
  let service: ShortAgents | undefined;
  let timer: ReturnType<typeof setInterval> | undefined;
  let busy = false;
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
  const reconcile = async () => {
    if (busy) return;
    busy = true;
    try {
      if (!(await owner())) return;
      await (await get()).reconcile(); lastError = ''; pi.events.emit('firstmate:outcomes-ready', {});
    }
    catch (error) {
      const message = `Short-agent notification recovery failed: ${String(error).slice(0, 512)}`;
      if (message !== lastError) pi.sendMessage({ customType: 'fm-short-agent-error', content: message, display: true });
      lastError = message;
    }
    finally { busy = false; }
  };
  pi.on('session_start', () => {
    if (timer) clearInterval(timer);
    timer = setInterval(() => { void reconcile(); }, 2000);
    timer.unref();
    void reconcile();
  });
  pi.on('session_shutdown', () => { if (timer) clearInterval(timer); timer = undefined; });
  pi.registerTool({
    name: 'fm_short_submit', label: 'Submit read-only short task',
    description: 'Explicitly offload a bounded read-only analysis to an independent headless Pi session. Returns durable ID immediately. Choose an authenticated provider/model from Pi discovery; files are canonical explicit text snapshots. Reuse key only for identical retries. No terminal/worktree or parent history.',
    parameters: Type.Object({ key: Type.String(), goal: Type.String(), acceptance: Type.String(), provider: Type.String(), model: Type.String(),
      materials: Type.Array(Type.String(), { maxItems: 4 }),
      budget: Type.Optional(Type.Object({ timeMs: Type.Optional(Type.Integer()), tools: Type.Optional(Type.Integer()), outputTokens: Type.Optional(Type.Integer()), requests: Type.Optional(Type.Integer()) })),
    }),
    async execute(_id, args) {
      const result = (await get()).submit(args);
      return { content: [{ type: 'text', text: JSON.stringify(result) }], details: result };
    },
  });
  pi.registerTool({
    name: 'fm_short_task', label: 'Inspect or cancel short task',
    description: 'Read bounded status/result or cancel a short-agent ID. Cancellation preserves the first terminal result. Detailed evidence stays local; ordinary notification acknowledgement uses fm_branch_processed.',
    parameters: Type.Object({ id: Type.String(), action: Type.Union([Type.Literal('status'), Type.Literal('result'), Type.Literal('cancel')]) }),
    async execute(_id, args) {
      const control = await get();
      const result = args.action === 'cancel' ? control.cancel(args.id) : control.status(args.id);
      void reconcile();
      return { content: [{ type: 'text', text: JSON.stringify(result) }], details: result };
    },
  });
}
