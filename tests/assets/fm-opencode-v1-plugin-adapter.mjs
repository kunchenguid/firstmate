// Test-only compatibility adapter: drives an OpenCode v2 plugin's
// { id, setup(ctx) } default export through the old V1 calling convention
// (`await mod.FmPrimaryX({ client, directory, worktree })` returning
// `{ event: async ({ event }) => ... } }`) that this suite's fixtures were
// written against. It exists so the extensive continuity fixtures in
// tests/fm-pi-watch-extension.test.sh, which exercise the OpenCode watch-arm
// and turn-end-guard plugins for cross-harness parity with the Pi extension,
// did not need a line-by-line rewrite when those plugins moved to OpenCode
// v2's default-export shape. It is not a production shim: no tracked plugin
// file uses it.
//
// Every real OpenCode v2 fact this adapter relies on was verified 2026-09-27
// against the installed OpenCode 2.0.18: ctx.location.directory,
// ctx.event.subscribe returning an async iterable of { type, data }, and
// ctx.session.prompt({ sessionID, text, delivery }). OpenCode v2 also
// deprecated session.idle/session.status in favor of the session.execution.*
// lifecycle, so this adapter maps every fixture's legacy "session.idle" onto
// "session.execution.succeeded" - an ordinary completed turn, the only case
// these fixtures ever meant by "idle" - while passing any other event type
// through unchanged.
export async function invokeV1Plugin(defaultExport, { client, directory, worktree }) {
  const queue = [];
  const waiters = [];
  function pushEvent(event) {
    if (waiters.length) waiters.shift()(event);
    else queue.push(event);
  }
  const bus = {
    [Symbol.asyncIterator]() {
      return {
        next() {
          return new Promise((resolve) => {
            if (queue.length) {
              resolve({ done: false, value: queue.shift() });
              return;
            }
            waiters.push((event) => resolve({ done: false, value: event }));
          });
        },
      };
    },
  };
  const ctx = {
    location: { directory: worktree || directory },
    event: { subscribe: () => bus },
    tool: { hook: async () => {} },
    session: {
      prompt: async ({ sessionID, text }) => {
        await client.session.promptAsync({ path: { id: sessionID }, body: { parts: [{ type: "text", text }] } });
      },
    },
  };
  await defaultExport.setup(ctx);
  return {
    event: async ({ event }) => {
      const sessionID = event?.properties?.sessionID ?? event?.properties?.info?.id ?? event?.data?.sessionID;
      const data = { sessionID };
      if (event?.properties?.info) data.info = event.properties.info;
      const type = event.type === "session.idle" ? "session.execution.succeeded" : event.type;
      pushEvent({ type, data });
      // The v2 loop drains the bus in the background; every caller of this
      // adapter already polls for its own side effects, so handing control
      // back to the microtask queue once is enough to let the loop dequeue.
      await new Promise((resolve) => setImmediate(resolve));
    },
  };
}
