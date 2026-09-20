import { realpathSync } from "node:fs";
import { resolve } from "node:path";

export function subscribeToEvents(ctx, handleEvent) {
  const controller = new AbortController();

  void (async () => {
    try {
      for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
        await handleEvent(event);
      }
    } catch (error) {
      if (!controller.signal.aborted) console.error(error);
    }
  })();

  return () => controller.abort();
}

export function pluginRoot(ctx) {
  const directory = ctx.location.project.directory;
  try {
    return realpathSync(directory);
  } catch {
    return resolve(directory);
  }
}
