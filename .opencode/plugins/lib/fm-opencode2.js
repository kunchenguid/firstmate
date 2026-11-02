// Shared OpenCode 2 server-plugin adapters for Firstmate primary plugins.
// OpenCode 2 calls setup(ctx), exposes event streams through ctx.event.subscribe,
// and exposes blocking tool hooks through ctx.tool.hook("execute.before", fn).
import { realpathSync } from "node:fs";
import { resolve } from "node:path";

// ctx.event.subscribe is the server's whole public stream, while each location
// on that server gets its own plugin instances. Every event consumer must
// therefore confirm an event's session belongs to its own location (see
// createSessionScope) before any guard run, watcher arm, prompt, or busy write.
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

function normalizeDirectory(directory) {
  if (typeof directory !== "string" || !directory) return "";
  try {
    return realpathSync(directory);
  } catch {
    return resolve(directory);
  }
}

// One location's identity: its directory, plus its workspace when it has one.
// A plugin's ctx.location names the directory itself, while 2.0.x exposed only
// ctx.location.project; a session's location carries the directory alone.
export function locationIdentity(location) {
  const directory = normalizeDirectory(location?.directory ?? location?.project?.directory);
  const workspaceID = typeof location?.workspaceID === "string" ? location.workspaceID : "";
  return { directory, workspaceID };
}

function sameLocation(own, other) {
  if (!own.directory || own.directory !== other.directory) return false;
  return !own.workspaceID || !other.workspaceID || own.workspaceID === other.workspaceID;
}

// The key under which a location's plugin instances find each other in the
// server-wide coordinator registry below.
export function locationKey(location) {
  const { directory, workspaceID } = locationIdentity(location);
  return directory ? `${directory}\n${workspaceID}` : "";
}

// Watcher coordinators, one per location, shared by that location's arm and
// turn-end guard plugins. A Map under its own global name, so a plugin build
// from before per-location keying, still writing its single global coordinator,
// can never replace another location's entry.
const WATCH_ARMS_KEY = "__firstmateOpenCodeWatchArms";

export function watchArmRegistry() {
  const existing = globalThis[WATCH_ARMS_KEY];
  if (existing instanceof Map) return existing;
  const registry = new Map();
  globalThis[WATCH_ARMS_KEY] = registry;
  return registry;
}

const MAX_SESSION_DEPTH = 16;

// Decide which location a session's turn belongs to. A session's parent id and
// location are learned from the session lifecycle events that carry them
// (session.created and later moves carry data.sessionID with data.location),
// and otherwise read once through ctx.session.get({ sessionID }). The lookup is
// load-bearing: a resumed session (opencode --session) was created before this
// plugin loaded, so its creation event never reaches the cache. The verdict
// follows parent ids to the root session and compares the root's location with
// this plugin instance's own:
//   own-root   a top-level session of this location: the only one a turn-end
//              consumer may act for
//   own-child  a subagent session under one of this location's sessions
//   foreign    a session of another location on the same server
//   unknown    the session or its location cannot be determined; never act
export function createSessionScope(ctx) {
  const own = locationIdentity(ctx?.location);
  const sessions = new Map();

  const observe = (event) => {
    const properties = eventProperties(event);
    const id = properties.sessionID ?? properties.sessionId ?? properties.info?.id ?? "";
    const location = properties.location ?? properties.info?.location;
    if (!id || typeof location?.directory !== "string") return;
    const parentID = properties.parentID ?? properties.parentId ?? properties.info?.parentID ?? "";
    sessions.set(id, { parentID: parentID || sessions.get(id)?.parentID || "", location });
  };

  const describe = async (sessionID) => {
    const known = sessions.get(sessionID);
    if (known) return known;
    if (typeof ctx?.session?.get !== "function") return null;
    try {
      const session = await ctx.session.get({ sessionID });
      if (typeof session?.location?.directory !== "string") return null;
      const entry = { parentID: session.parentID ?? session.parentId ?? "", location: session.location };
      sessions.set(sessionID, entry);
      return entry;
    } catch {
      return null;
    }
  };

  const classify = async (sessionID) => {
    if (!sessionID || !own.directory) return "unknown";
    let entry = await describe(sessionID);
    if (!entry) return "unknown";
    const child = Boolean(entry.parentID);
    for (let depth = 0; entry.parentID && depth < MAX_SESSION_DEPTH; depth += 1) {
      entry = await describe(entry.parentID);
      if (!entry) return "unknown";
    }
    if (entry.parentID) return "unknown";
    if (!sameLocation(own, locationIdentity(entry.location))) return "foreign";
    return child ? "own-child" : "own-root";
  };

  return { observe, classify };
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
