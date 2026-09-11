import { safe } from '../../../fm-state-reader/src/index.mjs';
export function telemetry(journal, requestId, actor = 'moiras', threadId = null) {
  const counters = { adapterCalls: 0, errors: 0, decisions: 0 };
  const record = (event, extra = {}) => journal.append({ ts: new Date().toISOString(), module: 'moiras', event, requestId, threadId, actor,
    inputs: { ids: [], bytes: 0 }, decision: null, reasons: [], stepsMs: {}, model: null, harness: null, effort: null, tokens: null, cost: null,
    outcome: null, evidencePath: null, ...extra, counters: { ...counters } });
  return {
    forRequest: (id, thread) => telemetry(journal, id, actor, thread),
    decision(event, decision, reasons = [], evidencePath = null) {
      counters.decisions++; record(event, { decision, reasons: reasons.map(r => safe(r).slice(0, 200)), evidencePath, outcome: decision === 'refused' ? 'rejected' : 'accepted' });
    },
    step(name, call, ids = [], bytes = Buffer.byteLength(JSON.stringify(ids))) {
      counters.adapterCalls++; record(`${name}.enter`, { inputs: { ids: ids.map(id => safe(id).slice(0, 160)), bytes } });
      const start = performance.now();
      const ok = result => { record(`${name}.exit`, { outcome: 'accepted', stepsMs: { [name]: performance.now() - start } }); return result; };
      const fail = error => { counters.errors++; record(`${name}.exit`, { outcome: 'error', reasons: [safe(error.killed ? 'timeout' : error.code ?? error.message).slice(0, 200)], stepsMs: { [name]: performance.now() - start } }); throw error; };
      try { const result = call(); return typeof result?.then === 'function' ? result.then(ok, fail) : ok(result); }
      catch (error) { return fail(error); }
    },
  };
}
