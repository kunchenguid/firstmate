// Minimal OpenCode 2 plugin host for behavior tests.
//
// OpenCode 2 loads a plugin's default export and calls setup(ctx); the
// context is a server client plus the plugin extension API. This host mirrors
// exactly the contract the tracked plugins are written against - the
// default-export definition, ctx.event.subscribe() as an async iterable,
// ctx.tool.hook("execute.before"|"execute.after", ...), ctx.session.prompt,
// and ctx.session.get for location scoping - so a test drives the plugin's
// real registration and delivery paths rather than its source text.
//
// Usage from an inline node driver:
//   import { loadV2Plugin } from "<repo>/tests/assets/opencode-v2-host.mjs";
//   const host = await loadV2Plugin(process.env.PLUGIN, { directory: process.env.WORKTREE });
//   await host.emit({ type: "session.created", data: { sessionID: "s1" } });
//   host.prompts          // every ctx.session.prompt input, in order
//   await host.runToolHook("execute.before", { tool: "shell", input: { command: "cd x" } });
//
// emit() resolves only after the plugin's subscription loop has finished
// handling that event (the loop requests the next value when it is done), so
// assertions after an await see the delivered effect.
//
// Sessions are not registered by default; ctx.session.get answers unknown
// ids as sessions at the host's own location, which is the common test case.
// Register a foreign session with addSession(id, { directory }) to exercise
// location scoping.
import { pathToFileURL } from "node:url";

export async function loadV2Plugin(pluginPath, { directory, projectDirectory } = {}) {
  const module = await import(pathToFileURL(pluginPath).href);
  const definition = module.default;
  if (!definition || typeof definition.id !== "string" || typeof definition.setup !== "function") {
    throw new Error(`${pluginPath} does not default-export an OpenCode 2 plugin definition with id and setup`);
  }

  const locationDirectory = directory ?? process.cwd();
  const queue = [];
  let wake = null;
  const controller = new AbortController();

  async function* events() {
    while (!controller.signal.aborted) {
      if (queue.length === 0) {
        await new Promise((resolve) => {
          wake = resolve;
        });
        continue;
      }
      const item = queue.shift();
      yield item.event;
      // The loop asked for the next event, so the previous event's handling
      // finished; that is the emit() completion signal.
      item.handled();
    }
  }

  const prompts = [];
  const sessions = new Map();
  const toolHooks = new Map();
  const sessionHooks = new Map();
  let promptGate = null;

  const ctx = {
    app: { version: "2.0.26-test" },
    location: {
      directory: locationDirectory,
      project: {
        id: "test",
        directory: projectDirectory ?? locationDirectory,
        canonical: projectDirectory ?? locationDirectory,
      },
    },
    options: {},
    event: {
      subscribe: () => events(),
    },
    session: {
      prompt: async (input) => {
        prompts.push(input);
        if (promptGate) await promptGate;
        return input;
      },
      get: async ({ sessionID }) => {
        const session = sessions.get(sessionID);
        if (session) return session;
        return { id: sessionID, location: { directory: locationDirectory } };
      },
      hook: async (name, callback) => {
        const callbacks = sessionHooks.get(name) ?? [];
        callbacks.push(callback);
        sessionHooks.set(name, callbacks);
        return { dispose: async () => {} };
      },
    },
    tool: {
      hook: async (name, callback) => {
        const callbacks = toolHooks.get(name) ?? [];
        callbacks.push(callback);
        toolHooks.set(name, callbacks);
        return { dispose: async () => {} };
      },
      list: async () => [],
    },
  };

  const cleanup = await definition.setup(ctx);

  return {
    id: definition.id,
    ctx,
    prompts,
    addSession(sessionID, { directory: sessionDirectory } = {}) {
      sessions.set(sessionID, { id: sessionID, location: { directory: sessionDirectory ?? locationDirectory } });
    },
    // Block ctx.session.prompt deliveries behind a gate when a test needs to
    // observe state while a delivery is in flight.
    setPromptGate(gate) {
      promptGate = gate;
    },
    async emit(event) {
      await new Promise((resolve) => {
        queue.push({ event, handled: resolve });
        if (wake) {
          const resume = wake;
          wake = null;
          resume();
        }
      });
    },
    async runToolHook(name, event) {
      for (const callback of toolHooks.get(name) ?? []) await callback(event);
    },
    async close() {
      controller.abort();
      if (wake) {
        const resume = wake;
        wake = null;
        resume();
      }
      if (typeof cleanup === "function") await cleanup();
    },
  };
}
