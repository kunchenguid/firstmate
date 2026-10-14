// Drive a Firstmate OpenCode 2 plugin in a plain Node host.
//
// OpenCode 2 loads a local plugin only from a default export carrying an `id`
// plus `setup(ctx)`, and reaches the plugin through `ctx` domains rather than
// the V1 returned-hooks object. This host builds a minimal context, runs the
// plugin's own setup(), and lets a driver push server events through
// ctx.event.subscribe() and inspect the hooks it registered. OpenCode 2 runs
// one server for every location, so an event may carry another location; an
// event without one resolves through ctx.session.get, which answers with the
// plugin's own location unless a driver overrides it.
//
// Usage from a driver:
//   const plugin = await startPlugin(process.env.PLUGIN, {
//     directory: process.env.WORKTREE,
//     session: { prompt: async (input) => { prompts.push(input.text); } },
//   });
//   await plugin.emit({ type: "session.idle", data: { sessionID: "s" } });
//   await plugin.emit({ type: "session.idle", location: { directory: "/other" }, data: { sessionID: "s" } });
import { pathToFileURL } from "node:url";

export async function startPlugin(pluginPath, options = {}) {
  const definition = (await import(pathToFileURL(pluginPath).href)).default;
  if (!definition || typeof definition.id !== "string" || typeof definition.setup !== "function") {
    throw new Error(`not an OpenCode 2 plugin definition: ${pluginPath}`);
  }

  const pending = [];
  const waiters = [];
  const toolHooks = {};
  let started = 0;
  let finished = 0;

  const take = () =>
    pending.length > 0
      ? Promise.resolve(pending.shift())
      : new Promise((resolve) => waiters.push(resolve));

  const ctx = {
    location: { directory: options.directory },
    session: {
      prompt: async () => {},
      get: async () => ({ location: { directory: options.directory } }),
      ...(options.session ?? {}),
    },
    tool: {
      hook: async (name, callback) => {
        (toolHooks[name] ??= []).push(callback);
        return { dispose: async () => {} };
      },
    },
    event: {
      subscribe: async function* () {
        for (;;) {
          const event = await take();
          try {
            yield event;
          } finally {
            finished += 1;
          }
        }
      },
    },
  };

  const cleanup = await definition.setup(ctx);

  return {
    id: definition.id,
    ctx,
    toolHooks,
    // Push one server event and wait until the plugin's subscription loop has
    // finished handling it, so a driver can assert immediately afterwards.
    async emit(event) {
      started += 1;
      const waiter = waiters.shift();
      if (waiter) waiter(event);
      else pending.push(event);
      const deadline = Date.now() + 10000;
      while (finished < started && Date.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, 1));
      }
    },
    // Run every callback the plugin registered for a tool hook.
    async runTool(name, event) {
      for (const hook of toolHooks[name] ?? []) await hook(event);
    },
    async stop() {
      if (typeof cleanup === "function") await cleanup();
    },
  };
}
