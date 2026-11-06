// Shared OpenCode 2 server-plugin adapters for Firstmate primary plugins.
// OpenCode 2 calls setup(ctx), exposes event streams through ctx.event.subscribe,
// and exposes blocking tool hooks through ctx.tool.hook("execute.before", fn).

export function setupEventSubscription(ctx, handler) {
  if (!ctx?.event?.subscribe) return false;
  const controller = new AbortController();
  void (async () => {
    try {
      const stream = await ctx.event.subscribe({
        signal: controller.signal,
        onActivity() {},
      });
      for await (const event of stream) {
        await handler(event);
      }
    } catch {
    }
  })();
  return true;
}

export function setupToolExecuteBefore(ctx, handler) {
  if (!ctx?.tool?.hook) return false;
  ctx.tool.hook("execute.before", async (event) => {
    await handler(event);
  });
  return true;
}

export function contextDirectory(ctx) {
  // OpenCode 2.0.x exposes the plugin's project as ctx.location.project.
  const directory = ctx?.location?.project?.directory;
  return typeof directory === "string" ? directory : "";
}

export function eventType(event) {
  return event?.type ?? event?.name ?? "";
}

export function eventProperties(event) {
  return event?.properties ?? event?.data ?? event ?? {};
}

export function eventSessionID(event) {
  const properties = eventProperties(event);
  return properties.sessionID ??
    properties.sessionId ??
    properties.session?.id ??
    properties.info?.id ??
    properties.id ??
    "";
}

function sessionIdentity(properties) {
  const source = properties.info ?? properties.session ?? properties;
  const id = source.id ?? properties.sessionID ?? properties.sessionId ?? "";
  const parentID = source.parentID ?? source.parentId ?? properties.parentID ?? properties.parentId ?? "";
  return { id, parentID };
}

// Every terminal execution event ends a turn: an interrupted or failed turn
// must keep supervision exactly like a succeeded one. A server shutdown is not
// a turn end the session can act on.
const EXECUTION_ENDED = new Set([
  "session.execution.succeeded",
  "session.execution.failed",
  "session.execution.interrupted",
]);

export function executionEnded(event) {
  if (!EXECUTION_ENDED.has(eventType(event))) return false;
  return eventProperties(event).reason !== "shutdown";
}

// Fire the turn-end signal on every ROOT (top-level) session's turn end and
// skip only true child sessions. OpenCode 2's session.execution.* events fire
// per session, so a turn that spawns a subagent also emits the child session's
// terminal event. Child sessions are identified by the parent id OpenCode
// carries on session lifecycle events (session.created/updated info.parentID),
// learned here as they arrive; a session with a known or inline parent is a
// child and never arms supervision or runs the blind-turn guard. Concurrent
// top-level sessions each settle independently, so no root turn end is dropped.
export function createTurnEndLatch() {
  const childSessions = new Set();
  const exemptSessions = new Set();
  const latch = (event) => {
    const { id, parentID } = sessionIdentity(eventProperties(event));
    if (id && parentID) childSessions.add(id);
    if (!executionEnded(event)) return "";
    if (!id || parentID || childSessions.has(id)) return "";
    return id;
  };
  // Turn-end exemption, keyed by session id. A blind-turn follow-up queued for
  // one session re-prompts it, which emits another terminal event; exempt only
  // that session's next terminal event so a concurrent session never consumes
  // another session's exemption and always runs its own supervision check.
  latch.exempt = (sessionID) => {
    if (sessionID) exemptSessions.add(sessionID);
  };
  latch.consume = (sessionID) => {
    if (!sessionID || !exemptSessions.has(sessionID)) return false;
    exemptSessions.delete(sessionID);
    return true;
  };
  return latch;
}

// OpenCode 2's execute.before event carries the model-visible tool name and
// its decoded input; only the shell tool runs a command line.
export function shellCommand(event) {
  if (event?.tool !== "shell") return "";
  const command = event.input?.command;
  return typeof command === "string" ? command : "";
}

export async function promptSession(ctx, client, sessionID, text) {
  if (ctx?.session?.prompt) {
    // The OpenCode 2.0.x plugin context takes a flat { sessionID, text }.
    await ctx.session.prompt({ sessionID, text });
    return;
  }
  if (client?.session?.promptAsync) {
    // The OpenCode 1 SDK client keys the prompt off path.id.
    await client.session.promptAsync({ path: { id: sessionID }, body: { parts: [{ type: "text", text }] } });
    return;
  }
  throw new Error("no OpenCode session prompt API is available");
}
