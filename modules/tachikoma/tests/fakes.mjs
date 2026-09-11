export function fakeJournal() {
  let tail = Promise.resolve();
  const port = {
    decisions: [], cards: [], receipt: null, trace: [],
    exclusive(work) { const run = tail.then(work); tail = run.catch(() => {}); return run; },
    async readDecisions() { port.trace.push('read-decisions'); return structuredClone(port.decisions); },
    async readCards() { port.trace.push('read-cards'); return structuredClone(port.cards); },
    async appendDecision(value) { port.trace.push('append-decision'); port.decisions.push(structuredClone(value)); },
    async replaceCards(cards, receipt) { port.trace.push('replace-cards'); port.cards = structuredClone(cards); port.receipt = structuredClone(receipt); },
  };
  return port;
}
export const fakeEvidence = context => ({ read: async () => structuredClone(context) });
export const fakeModelTelemetry = attempts => ({ readAttempts: async () => structuredClone(attempts) });
export function fakeTelemetry() {
  const events = [];
  return { events, emit: event => events.push(structuredClone(event)), readDay: () => structuredClone(events) };
}
