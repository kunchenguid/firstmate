// A minimal in-process stand-in for one OpenCode 2 server hosting several
// locations, for portable plugin regressions that need no OpenCode binary.
// Like the real server (verified against OpenCode 2.2.4 by
// tests/opencode-v2-scope-live-fixture.mjs), every plugin subscription sees
// the whole server's event stream, session.execution.* events carry only a
// sessionID, and ctx.session.get({ sessionID }) resolves a session's location
// and parent. emit() resolves once every subscriber has finished handling the
// event, because each plugin awaits its handler before pulling the next one.

export function createFakeServer() {
  const subscribers = [];
  const sessions = new Map();
  const prompts = [];

  const subscribe = () => {
    const sub = { pending: [], waiters: [], inFlight: false, drained: null };
    subscribers.push(sub);
    const next = () => {
      if (sub.inFlight) {
        sub.inFlight = false;
        const drained = sub.drained;
        sub.drained = null;
        if (drained) drained();
      }
      if (sub.pending.length) {
        sub.inFlight = true;
        return Promise.resolve({ value: sub.pending.shift(), done: false });
      }
      return new Promise((resolve) => {
        sub.waiters.push((value) => {
          sub.inFlight = true;
          resolve(value);
        });
      });
    };
    return { [Symbol.asyncIterator]: () => ({ next }) };
  };

  const emit = (event) =>
    Promise.all(subscribers.map((sub) => new Promise((done) => {
      sub.drained = done;
      const waiter = sub.waiters.shift();
      if (waiter) waiter({ value: event, done: false });
      else sub.pending.push(event);
    })));

  // Register a session the server knows; parentID marks a subagent session.
  const addSession = (id, directory, parentID = "") => {
    sessions.set(id, { id, location: { directory }, ...(parentID ? { parentID } : {}) });
  };

  const ctxFor = (directory) => ({
    location: { directory, project: { id: "global", directory } },
    event: { subscribe: async () => subscribe() },
    session: {
      get: async ({ sessionID }) => {
        const session = sessions.get(sessionID);
        if (!session) throw new Error(`NotFound: ${sessionID}`);
        return session;
      },
      prompt: async ({ sessionID, text }) => {
        prompts.push({ from: directory, sessionID, text });
      },
    },
  });

  const terminal = (sessionID, outcome = "succeeded") => ({ type: `session.execution.${outcome}`, data: { sessionID } });
  const started = (sessionID) => ({ type: "session.execution.started", data: { sessionID } });
  const created = (sessionID, directory, parentID = "") => ({
    type: "session.created",
    location: { directory },
    data: { sessionID, location: { directory }, ...(parentID ? { parentID } : {}) },
  });

  return { addSession, ctxFor, emit, prompts, terminal, started, created };
}
