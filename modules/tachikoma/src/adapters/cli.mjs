#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { buffer, put, clean, display, terminal } from '../../../fm-tui-core/src/index.mjs';
import { routeTask, learn } from '../usecases/routing.mjs';
import { summarize } from '../core/stats.mjs';
import { latestPoolRecovery, recoveryCounters } from '../core/recovery.mjs';
import { evidence, token } from './evidence.mjs';
import { journal, readJSON } from './storage.mjs';
import { observed, serviceTelemetry } from './telemetry.mjs';

const help = `Tachikoma - subscription routing and outcome learning (manual commands only)
Usage: bin/fm-tachikoma.sh <verb> [flags]

Verbs:
  route    Choose and record an eligible model. Example: route --task fix-1 --class bounded-implementation-proven-root-fix --repo example --brief brief.md --if-enabled
  learn    Rebuild model cards from sealed real outcomes. Example: learn
  status   Print one static frame (the default). Example: status --clean
  stats    Summarize the current UTC day's request telemetry. Example: stats --day 2026-09-11

Route flags:
  --task ID             Opaque task identifier. Example: --task fix-1
  --class CLASS         Explicit task classification. Example: --class bounded-implementation-proven-root-fix
  --repo NAME           Exact compiled project name. Example: --repo example
  --brief FILE          Hash the brief without logging its content. Example: --brief data/fix-1/brief.md
  --snapshot FILE       Use recorded quota-axi TOON without network access. Example: --snapshot quota.toon
  --seed UINT32         Replay a recorded random draw. Example: --seed 123
  --request-id ID       Idempotent request identity. Example: --request-id request-123
  --thread-id ID        Correlation identity for service telemetry. Example: --thread-id thread-123
  --if-enabled          Return disabled/fallback=profiles when off. Example: route --if-enabled --task fix-1 --class bounded --repo example --brief brief.md
  --require-enabled     Refuse while activation is off (spawn uses this). Example: route --require-enabled --task fix-1 --class bounded --repo example --brief brief.md

Read-only flags:
  --json                Machine-readable status. Example: status --json
  --clean               Static output, no animation or redraw. Example: status --clean
  --no-ui               Static output, no animation or redraw. Example: status --no-ui
  --day YYYY-MM-DD      UTC day to summarize. Example: stats --day 2026-09-11
  -h, --help            Show every implemented verb and flag. Example: route -h

Configuration: FM_HOME/config/tachikoma/policy.json is a reviewed compilation
bound by SHA256 to model-catalog.json and crew-dispatch.json. Missing compilation
is not approval to guess policy. See modules/tachikoma/README.md for every key.
FM_HOME selects the operational home; FM_DATA_OVERRIDE overrides durable data.
Never auto-starts a service or model. Unknown tokens/cost remain null. NO_COLOR
is honored. Foreground animation and the optional specialist are later slices.
`;

let telemetry;
try {
  const [verb = 'status', ...argv] = process.argv.slice(2);
  if (['-h', '--help'].includes(verb) || argv.some(value => ['-h', '--help'].includes(value))) {
    process.stdout.write(help);
  } else {
    const options = verb === 'route' ? Object.fromEntries(['task','class','repo','brief','snapshot','seed','request-id','thread-id'].map(key => [key, { type: 'string' }]).concat([['if-enabled', { type: 'boolean' }], ['require-enabled', { type: 'boolean' }]])) : verb === 'status' ? { json: { type: 'boolean' }, clean: { type: 'boolean' }, 'no-ui': { type: 'boolean' } } : verb === 'stats' ? { day: { type: 'string' } } : {};
    if (!['route','learn','status','stats'].includes(verb)) throw new Error('expected route, learn, status, or stats');
    const { values } = parseArgs({ args: argv, options, allowPositionals: false, strict: true });
    const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../..');
    const home = fs.realpathSync(process.env.FM_HOME || root);
    const data = path.resolve(process.env.FM_DATA_OVERRIDE || path.join(home, 'data'));
    const state = path.join(home, 'state');
    const request = { ...values, requestId: values['request-id'] || crypto.randomUUID(), threadId: values['thread-id'], requireEnabled: values['require-enabled'] === true };
    if (!token(request.requestId) || (request.threadId && !token(request.threadId))) throw new Error('invalid correlation identifier');
    if (values.seed !== undefined) {
      request.seed = Number(values.seed);
      if (!/^\d+$/.test(values.seed) || !Number.isInteger(request.seed) || request.seed > 0xffffffff) throw new Error('seed must be uint32');
    }
    if (values['if-enabled'] && values['require-enabled']) throw new Error('conflicting activation flags');
    const reader = evidence({ root, home, data });
    const storage = journal({ root, home, data, state });
    if (verb === 'route' && values['if-enabled'] && !reader.activation()) {
      process.stdout.write('{"status":"disabled","fallback":"profiles"}\n');
    } else if (verb === 'status') {
      const decisions = await storage.readDecisions();
      const sync = readJSON(path.join(data, 'tachikoma/sync.json'));
      const result = { enabled: reader.activation(), decisions: decisions.length, last: decisions.at(-1) ?? null, sync, pools: recoveryCounters(latestPoolRecovery(decisions), Date.now()) };
      if (values.json) process.stdout.write(`${JSON.stringify(result)}\n`);
      else {
        const width = Math.max(20, Math.min(160, process.stdout.columns || 80));
        const lines = [`TACHIKOMA | routing ${result.enabled ? 'enabled' : 'off'} | manual commands`, `Decisions: ${decisions.length} | Sealed attempts: ${sync?.sealedAttempts ?? 'not synced'}`, `Pick: ${result.last?.model ?? 'none'}`, ...(result.last?.reasons || ['No routing decisions']), ...result.pools.flatMap(pool => [`Pool ${pool.pool}: ${pool.models.join(', ')}`, ...pool.quota.map(q => `  ${q.scope}: remaining ${q.headroom ?? 'unknown'}% | pacing ${q.spendPriority ?? 'unknown'}`), `  Reset ${pool.quotaResetAt ?? 'unknown'} | recheck ${pool.secondsUntilRecheck === null ? 'unmeasured/not scheduled' : `${pool.secondsUntilRecheck}s (fresh evidence required)`}`])].flatMap(line => clean(line).match(new RegExp(`.{1,${width - 1}}`, 'g')) || ['']);
        const grid = buffer(width, lines.length); lines.forEach((line, row) => put(grid, 0, row, line));
        const view = display(terminal(), { clean: true });
        try { view.draw(grid); } finally { view.close(); }
      }
    } else if (verb === 'stats') {
      const day = values.day || new Date().toISOString().slice(0, 10);
      const summary = summarize(serviceTelemetry(state, request).readDay(day), day);
      summary.pools = recoveryCounters(latestPoolRecovery(await storage.readDecisions()), Date.now());
      process.stdout.write(`${JSON.stringify(summary)}\n`);
    } else {
      telemetry = serviceTelemetry(state, request);
      telemetry.emit({ event: 'request.received', inputs: { ids: [request.task, request.class, request.repo].filter(Boolean), bytes: null }, counters: {} });
      const ports = { journal: observed('journal', storage, telemetry), telemetry, evidence: observed('evidence', { read: reader.read }, telemetry), modelTelemetry: observed('model-telemetry', { readAttempts: reader.readAttempts }, telemetry) };
      const result = verb === 'route' ? await routeTask(request, ports) : await learn(ports, new Date().toISOString());
      const outcome = verb === 'route' && !result.model ? 'rejected' : 'accepted';
      telemetry.emit({ event: 'request.completed', decision: result, model: result.model ?? null, harness: result.harness ?? null, effort: result.effort ?? null, reasons: result.reasons ?? ['outcome-sync'], outcome, counters: verb === 'route' ? { candidates: result.alternatives.length, refusals: result.alternatives.filter(row => row.eligibility === 'blocked').length } : { attempts: result.sealedAttempts, models: result.models.length }, evidencePath: `data/tachikoma/${verb === 'route' ? 'decisions.jsonl' : 'sync.json'}` });
      process.stdout.write(`${JSON.stringify(result)}\n`);
      if (outcome === 'rejected') process.exitCode = 3;
    }
  }
} catch (error) {
  const reason = error.code || error.message;
  try { telemetry?.emit({ event: 'request.completed', outcome: 'error', reasons: [reason] }); } catch { /* The original refusal remains authoritative when its log is unavailable. */ }
  process.stderr.write(`Tachikoma refused: ${reason}\n`);
  process.exitCode = 2;
}
