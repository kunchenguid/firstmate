/**
 * Default-off Pi Context Atlas prototype. Explicit load only, never auto-install.
 * From the selected Git repository root:
 *   pi -e /path/to/firstmate/bin/context-atlas.ts
 *   pi -e /path/to/firstmate/bin/context-atlas.ts --atlas-read --atlas-defer
 * For a command-line prompt, put -- after the flags and before the quoted prompt.
 * Optional --atlas-root /absolute/repo and --atlas-exclude prefix,prefix narrow scope.
 * --atlas-read authorizes this extension's local, bounded text adapter, NOT a
 * proxy for Pi read. Do not enable it where a read-tool-specific policy must
 * mediate reads: that policy must independently authorize atlas too.
 * --atlas-defer temporarily hides only originally active, original Pi built-in
 * read/grep/find/ls tools. All other tools and their owners remain unchanged.
 * /atlas-help prints this contract; /atlas-restore restores unchanged deferred
 * definitions without removing any other active tools. Shutdown also restores.
 *
 * atlas({op:"resolve",q:"f:README.md"}) -> generation and identity-backed ref.
 * atlas({op:"read",ref:"<returned ref>",gen:"<returned generation>",at:1,count:20})
 * atlas({op:"resolve",q:"t:read"}) then op:"activate" -> original tool next call.
 * Other ops: catalog (q optional; at is 1-based pagination), inspect, refresh.
 * q is a literal identity substring, optionally f: or t:, never a shell command.
 * ref operations require gen. Refresh invalidates every earlier generation.
 * No positional aliases, arbitrary execution, writes, symbols, diffs or network.
 * Bounds: 8 catalog candidates, 100 read lines, 256 KiB file, 8 KiB JSON result,
 * 20,000 Git inventory paths / 2 MiB inventory output / 5 seconds per Git call.
 * Hidden/private/dependency/build/credential paths, ignored files (even tracked),
 * symlinks and hardlinks are excluded; --atlas-exclude adds relative prefixes.
 * The catalog reads metadata only, never contents. File reads need --atlas-read.
 * This is not a sandbox or a secret scanner: do not authorize reads in a tree
 * containing secrets disguised as ordinary source files or adversarial writers.
 */
import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { Type } from 'typebox';
import { StringEnum } from '@earendil-works/pi-ai';
import { createAtlas, activatable, toolStamp } from './context-atlas/catalog.mjs';

const HELP = `Context Atlas: explicit-load experiment; no arbitrary tool execution.
Load: pi -e /path/to/firstmate/bin/context-atlas.ts [--atlas-read] [--atlas-defer]
For a command-line prompt, add -- before the quoted prompt, after all flags.
Scope: --atlas-root /absolute/git-root; --atlas-exclude relative/prefix,another
atlas ops: catalog, resolve, inspect, read, activate, refresh.
Resolve q is a literal identity substring (optional f: or t: prefix).
Use the returned ref and generation as ref/gen for inspect/read/activate.
at/count select 1-based catalog pages or read lines. Refresh invalidates old gen.
Limits: 8 candidates, 100 lines, 256 KiB files, 8 KiB JSON results.
Read needs --atlas-read and uses a separate local text adapter, not the read tool.
Existing read-specific policies do not automatically govern atlas; authorize it separately.
Only originally active built-in read/grep/find/ls can be deferred and reactivated.
Activation preserves the original name/schema/hooks for the model's next call.
/atlas-restore restores unchanged deferred tools, preserving other active tools.
Default exclusions cover ignored, hidden, private, credential, dependency and build paths.
No writes, shell execution, network, diffs or symbol parser. Not a sandbox or secret scanner.
See bin/context-atlas.ts header for the complete invocation contract.`;

export default function (pi: ExtensionAPI) {
  pi.registerFlag('atlas-root', { type: 'string', description: 'Selected Git root; defaults to cwd' });
  pi.registerFlag('atlas-exclude', { type: 'string', description: 'Additional excluded repository-relative prefixes, comma-separated' });
  pi.registerFlag('atlas-read', { type: 'boolean', default: false, description: 'Authorize Atlas local text reads separately from original tool policies' });
  pi.registerFlag('atlas-defer', { type: 'boolean', default: false, description: 'Defer originally active built-in read/grep/find/ls until Atlas activation' });
  let dispatch: ReturnType<typeof createAtlas> | undefined;
  const deferred = new Map<string, string>();
  function restore() {
    const names = pi.getAllTools().filter(t => deferred.get(t.name) === toolStamp(t)).map(t => t.name);
    pi.setActiveTools([...new Set([...pi.getActiveTools(), ...names])]);
    deferred.clear();
  }
  pi.on('session_start', (_event, ctx) => {
    dispatch = undefined;
    const root = pi.getFlag('atlas-root');
    const excludes = pi.getFlag('atlas-exclude');
    dispatch = createAtlas({
      root: typeof root === 'string' ? root : ctx.cwd,
      read: pi.getFlag('atlas-read') === true,
      exclusions: typeof excludes === 'string' ? excludes.split(',') : [],
      tools: () => pi.getAllTools(), active: () => pi.getActiveTools(),
      activate: (t) => {
        if (deferred.get(t.name) !== toolStamp(t)) return false;
        pi.setActiveTools([...new Set([...pi.getActiveTools(), t.name])]);
        return pi.getActiveTools().includes(t.name);
      },
    });
    if (pi.getFlag('atlas-defer') === true && pi.getActiveTools().includes('atlas')) {
      const active = new Set(pi.getActiveTools());
      for (const t of pi.getAllTools()) if (active.has(t.name) && activatable(t)) deferred.set(t.name, toolStamp(t));
      pi.setActiveTools([...active].filter(n => !deferred.has(n)));
    }
  });
  pi.on('session_shutdown', () => { restore(); dispatch = undefined; });
  pi.registerCommand('atlas-help', { description: 'Context Atlas invocation and safety contract', handler: async () => {
    pi.sendMessage({ customType: 'atlas-help', content: HELP, display: true });
  } });
  pi.registerCommand('atlas-restore', { description: 'Restore unchanged Atlas-deferred tools', handler: async (_args, ctx) => {
    if (!ctx.isIdle()) { ctx.ui.notify('Wait for the current turn before restoring tools.', 'warning'); return; }
    restore();
    ctx.ui.notify('Unchanged Atlas-deferred tools restored.', 'info');
  } });
  pi.registerTool({
    name: 'atlas', label: 'Context Atlas',
    description: 'Index files/tools: catalog/resolve q (literal, optional f:/t:). inspect/read/activate require returned ref and generation as gen. Read at/count lines; activate original read-only tool for next call. refresh invalidates gen. Max 8 candidates, 100 lines, 8 KiB JSON. No writes or shell.',
    parameters: Type.Object({
      op: StringEnum(['catalog', 'resolve', 'inspect', 'read', 'activate', 'refresh']),
      q: Type.Optional(Type.String({ maxLength: 400 })),
      ref: Type.Optional(Type.String({ maxLength: 400 })),
      gen: Type.Optional(Type.String({ maxLength: 400 })),
      at: Type.Optional(Type.Integer({ minimum: 1 })),
      count: Type.Optional(Type.Integer({ minimum: 1, maximum: 100 })),
    }, { additionalProperties: false }),
    async execute(_id, params, signal) {
      if (!dispatch) throw new Error('Atlas unavailable: selected root must be a readable Git root; see /atlas-help.');
      const result = dispatch(params, signal);
      return { content: [{ type: 'text', text: JSON.stringify(result) }], details: result };
    },
  });
}
