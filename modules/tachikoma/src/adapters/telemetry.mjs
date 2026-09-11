import path from 'node:path';
import { performance } from 'node:perf_hooks';
import { readLines, writeJSON } from './storage.mjs';

export function serviceTelemetry(state, request, now = () => new Date().toISOString()) {
  return {
    emit(value) {
      const ts = now();
      const record = { schemaVersion: 1, ts, module: 'tachikoma', event: value.event, requestId: request.requestId ?? null, threadId: request.threadId ?? null, actor: 'tachikoma', inputs: { ids: [], bytes: null }, decision: null, reasons: [], stepsMs: {}, model: null, harness: null, effort: null, tokens: null, cost: null, outcome: null, evidencePath: null, counters: {}, ...value };
      writeJSON(path.join(state, 'tachikoma', 'telemetry', `${ts.slice(0, 10)}.jsonl`), record, true);
    },
    readDay(day) {
      if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) throw new Error('day must be YYYY-MM-DD');
      return readLines(path.join(state, 'tachikoma', 'telemetry', `${day}.jsonl`));
    },
  };
}

// Cross-cutting observation of real I/O only. Never log arguments or results:
// ports can contain prompt text, account descriptions, or raw provider errors.
export function observed(name, port, telemetry) {
  return Object.fromEntries(Object.entries(port).map(([method, operation]) => [method, async (...args) => {
    const started = performance.now();
    const inputs = { ids: [], bytes: null, port: name, operation: method };
    telemetry.emit({ event: 'port.enter', inputs });
    try {
      const result = await operation.apply(port, args);
      telemetry.emit({ event: 'port.exit', inputs, stepsMs: { [name]: performance.now() - started }, outcome: 'accepted' });
      return result;
    } catch (error) {
      telemetry.emit({ event: 'port.exit', inputs, stepsMs: { [name]: performance.now() - started }, outcome: 'error', reasons: [error.code || 'port-refused'] });
      throw error;
    }
  }]));
}
