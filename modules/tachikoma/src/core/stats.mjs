// Pure projection of the module's minimized daily event records.
const count = value => Number.isFinite(value) && value >= 0;

export function summarize(events, day) {
  const requests = new Set();
  const terminals = new Map();
  const result = { day, requests: 0, pending: 0, outcomes: { accepted: 0, rejected: 0, error: 0 }, ports: {}, counters: {}, usage: { observations: 0, inputTokens: null, outputTokens: null, costByCurrency: {} } };
  for (const event of events) {
    if (event.schemaVersion !== 1 || event.module !== 'tachikoma' || event.ts?.slice(0, 10) !== day || !event.requestId) continue;
    requests.add(event.requestId);
    if (event.event === 'request.completed' && Object.hasOwn(result.outcomes, event.outcome)) terminals.set(event.requestId, event);
    if (event.event === 'port.exit' && typeof event.inputs?.port === 'string') {
      const name = event.inputs.port;
      if (!/^[a-z][a-z0-9-]*$/.test(name) || ['constructor', 'prototype'].includes(name)) continue;
      const port = result.ports[name] ||= { calls: 0, errors: 0, durationMs: 0 };
      port.calls++;
      port.errors += Number(event.outcome === 'error');
      if (count(event.stepsMs?.[name])) port.durationMs += event.stepsMs[name];
    }
  }
  result.requests = requests.size;
  result.pending = requests.size - terminals.size;
  for (const event of terminals.values()) {
    result.outcomes[event.outcome]++;
    for (const [key, value] of Object.entries(event.counters || {})) {
      if (/^[a-z][a-zA-Z0-9]*$/.test(key) && !['constructor', 'prototype'].includes(key) && count(value)) result.counters[key] = (Object.hasOwn(result.counters, key) ? result.counters[key] : 0) + value;
    }
    if (count(event.tokens?.inputTokens) && count(event.tokens?.outputTokens)) {
      result.usage.observations++;
      result.usage.inputTokens = (result.usage.inputTokens ?? 0) + event.tokens.inputTokens;
      result.usage.outputTokens = (result.usage.outputTokens ?? 0) + event.tokens.outputTokens;
    }
    if (count(event.cost?.amount) && /^[A-Z]{3}$/.test(event.cost.currency)) result.usage.costByCurrency[event.cost.currency] = (result.usage.costByCurrency[event.cost.currency] || 0) + event.cost.amount;
  }
  return result;
}
