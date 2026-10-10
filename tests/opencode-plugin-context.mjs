import { setImmediate } from "node:timers/promises";

// In-memory implementation of V2's live, abortable event stream for portable
// behavioral tests. Native OpenCode loading and delivery have a separate guard.
export async function loadOpenCodePlugin(plugin, session, directory) {
  const subscribers = new Set();
  const context = {
    location: { directory, project: { directory } },
    session: { get: async () => ({ location: { directory } }), ...session.session },
    event: {
      async *subscribe({ signal }) {
        const queue = [];
        let resume;
        const subscriber = (event) => { queue.push(event); resume?.(); };
        const abort = () => resume?.();
        subscribers.add(subscriber);
        signal.addEventListener("abort", abort, { once: true });
        try {
          while (!signal.aborted) {
            if (!queue.length) await new Promise((resolve) => { resume = resolve; });
            resume = undefined;
            if (queue.length) yield queue.shift();
          }
        } finally {
          subscribers.delete(subscriber);
          signal.removeEventListener("abort", abort);
        }
      },
    },
  };
  const dispose = await plugin.setup(context);
  return {
    context,
    dispose,
    async emit(event) {
      for (const subscriber of subscribers) subscriber(event);
      await setImmediate();
    },
  };
}
