export const QUIESCENT = "QUIESCENT";

const EXECUTION_STARTED = "session.execution.started";
const QUIESCENT_EVENTS = new Set([
  "session.idle",
  "session.execution.succeeded",
  "session.execution.failed",
  "session.execution.interrupted",
]);
const TERMINAL_EVENTS = new Set([
  "session.execution.succeeded",
  "session.execution.failed",
  "session.execution.interrupted",
]);
const RECENT_TERMINAL_LIMIT = 256;

export class OpenCodeLifecycleAdapter {
  #activeExecutions = new Map();
  #recentTerminals = new Set();
  #terminalOrder = [];

  normalize(event) {
    const type = event?.type;
    const sessionID = event?.data?.sessionID ?? event?.properties?.sessionID;
    if (!sessionID) return null;

    if (type === EXECUTION_STARTED) {
      this.#activeExecutions.set(sessionID, event.id ?? event.durable?.seq ?? "");
      return null;
    }
    if (!QUIESCENT_EVENTS.has(type)) return null;

    const terminal = TERMINAL_EVENTS.has(type);
    const identity = terminal ? terminalIdentity(event, sessionID) : event.id;
    if (identity && this.#recentTerminals.has(identity)) return null;
    if (terminal && identity) this.#rememberTerminal(identity);

    const executionRef = terminal
      ? this.#activeExecutions.get(sessionID) || event.data?.executionID || event.id
      : undefined;
    if (terminal) this.#activeExecutions.delete(sessionID);

    return { type: QUIESCENT, sessionID, executionRef };
  }

  #rememberTerminal(identity) {
    this.#recentTerminals.add(identity);
    this.#terminalOrder.push(identity);
    if (this.#terminalOrder.length > RECENT_TERMINAL_LIMIT) {
      this.#recentTerminals.delete(this.#terminalOrder.shift());
    }
  }
}

function terminalIdentity(event, sessionID) {
  if (event.id) return event.id;
  const aggregateID = event.durable?.aggregateID ?? sessionID;
  const sequence = event.durable?.seq;
  return sequence === undefined ? "" : `${aggregateID}:${sequence}`;
}
