// A minimal OpenCode 2 host for driving firstmate's tracked OpenCode plugins
// from a behavior test.
//
// OpenCode 2 default-exports a plugin definition whose setup(ctx) registers
// hooks and opens a subscription to the connected server's whole public event
// stream. A test therefore cannot call a returned hooks object the way OpenCode 1
// plugins were driven, and it must model the subscription so an event can be
// delivered at a chosen moment and awaited to completion.
//
// `fire` keeps the semantics the v1 suites relied on: it delivers one event and
// resolves once that event's handler has run to completion, so a test can hold
// the promise open while it mutates the world (for example stealing the session
// lock) before the handler observes it.

import { pathToFileURL } from "node:url";

export async function loadPlugin(pluginPath, options = {}) {
  const { directory, canonical, onPrompt } = options;
  if (!directory) throw new Error("loadPlugin requires the instance directory");

  // Events queue until the plugin's subscription asks for one, so ordering the
  // test controls is preserved exactly.
  const pending = [];
  let wake = null;
  const take = () =>
    new Promise((resolve) => {
      if (pending.length > 0) {
        resolve(pending.shift());
        return;
      }
      wake = () => {
        wake = null;
        resolve(pending.shift());
      };
    });

  const mod = await import(pathToFileURL(pluginPath).href);
  const definition = mod.default;
  if (!definition || typeof definition.id !== "string" || typeof definition.setup !== "function") {
    throw new Error(`not an OpenCode 2 plugin definition: ${pluginPath}`);
  }

  const cleanup = await definition.setup({
    location: {
      directory,
      project: { id: "test-project", directory, canonical: canonical ?? directory },
    },
    options: {},
    event: {
      subscribe: () => ({
        async *[Symbol.asyncIterator]() {
          for (;;) {
            const item = await take();
            yield item.event;
            item.settled();
          }
        },
      }),
    },
    session: {
      prompt: async (input) => {
        if (onPrompt) await onPrompt(input);
        return { id: "msg_test", sessionID: input.sessionID, delivery: "steer" };
      },
    },
  });

  const fire = async (event) => {
    const settled = new Promise((resolve) => pending.push({ event, settled: resolve }));
    if (wake) wake();
    await settled;
  };

  // The turn end an OpenCode 2 plugin observes: the last step of a turn. A
  // "tool-calls" step is the agent loop continuing, not the end.
  const turnEnd = (sessionID = "session-test", finish = "stop") =>
    fire({
      type: "session.step.ended",
      data: { sessionID, finish },
      location: { directory },
    });

  return {
    id: definition.id,
    fire,
    turnEnd,
    cleanup: typeof cleanup === "function" ? cleanup : async () => {},
  };
}
