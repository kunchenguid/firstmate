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
  ctx.tool.hook("execute.before", async (input, output) => {
    await handler(input, output);
  });
  return true;
}

export function contextDirectory(ctx) {
  const location = ctx?.location;
  if (typeof ctx?.worktree === "string") return ctx.worktree;
  if (typeof ctx?.directory === "string") return ctx.directory;
  if (typeof location?.directory === "string") return location.directory;
  if (typeof location?.path === "string") return location.path;
  if (typeof location?.cwd === "string") return location.cwd;
  if (typeof location?.root === "string") return location.root;
  return "";
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
    properties.session?.parentID ??
    properties.session?.parentId ??
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
    if (eventType(event) !== "session.execution.succeeded") return "";
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

export function toolName(input) {
  return input?.tool ?? input?.toolID ?? input?.toolId ?? input?.name ?? input?.tool?.id ?? "";
}

function findCommand(value, depth = 0) {
  if (!value || depth > 4) return "";
  if (typeof value === "string") return "";
  if (typeof value !== "object") return "";
  for (const key of ["command", "cmd", "script"]) {
    if (typeof value[key] === "string") return value[key];
  }
  for (const key of ["args", "arguments", "input", "parameters", "toolCall", "tool", "payload"]) {
    const found = findCommand(value[key], depth + 1);
    if (found) return found;
  }
  return "";
}

export function toolCommand(input, output) {
  return findCommand(output) || findCommand(input);
}

export async function promptSession(ctx, client, sessionID, text) {
  const body = { parts: [{ type: "text", text }] };
  const attempts = [];
  if (ctx?.session?.prompt) {
    attempts.push(() => ctx.session.prompt({ sessionID, prompt: { text }, delivery: "queue" }));
    attempts.push(() => ctx.session.prompt({ sessionID, prompt: { text } }));
    attempts.push(() => ctx.session.prompt({ path: { sessionID }, body: { prompt: { text } } }));
  }
  if (client?.session?.promptAsync) {
    // The proven pre-port OpenCode 1 shape keys the prompt off path.id, so try
    // it first: a generated SDK client returns {data,error} without throwing on
    // a bad path, so a path.id-less attempt would otherwise resolve and short-
    // circuit, silently dropping the prompt to session undefined. The
    // path.sessionID variant stays as a defensive fallback.
    attempts.push(() => client.session.promptAsync({ path: { id: sessionID }, body }));
    attempts.push(() => client.session.promptAsync({ path: { sessionID }, body }));
  }
  let firstError = null;
  for (const attempt of attempts) {
    try {
      await attempt();
      return;
    } catch (error) {
      firstError ??= error;
    }
  }
  if (firstError) throw firstError;
  throw new Error("no OpenCode session prompt API is available");
}
