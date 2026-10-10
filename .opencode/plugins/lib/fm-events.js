import { resolve } from "node:path";

export const TURN_END_EVENTS = [
  "session.execution.succeeded",
  "session.execution.failed",
  "session.execution.interrupted",
];

export function watchArmCoordinatorKey(ctx) {
  return JSON.stringify([resolve(ctx.location.directory), ctx.location.workspaceID ?? ""]);
}

// V2 subscriptions see the server stream, not only this plugin's location.
// Buffer handler work so prompt admission cannot stall its own event delivery.
export function subscribeFirstmateEvents(ctx, types, handler) {
  const controller = new AbortController();
  const directory = resolve(ctx.location.directory);
  let pending = Promise.resolve();
  const subscription = (async () => {
    for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
      if (!types.includes(event.type)) continue;
      pending = pending.then(async () => {
        if (controller.signal.aborted) return;
        // Durable execution events have no top-level location in V2.
        const location = event.location ?? event.data?.location
          ?? (await ctx.session.get({ sessionID: event.data.sessionID })).location;
        if (!location?.directory || resolve(location.directory) !== directory) return;
        if ((location.workspaceID ?? "") !== (ctx.location.workspaceID ?? "")) return;
        if (!controller.signal.aborted) return handler(event);
      }).catch((error) => {
        if (!controller.signal.aborted) console.error("Firstmate OpenCode event handler:", error);
      });
    }
  })().catch((error) => {
    if (!controller.signal.aborted) console.error("Firstmate OpenCode event subscription:", error);
  });
  return async () => {
    controller.abort();
    await subscription;
    await pending;
  };
}
