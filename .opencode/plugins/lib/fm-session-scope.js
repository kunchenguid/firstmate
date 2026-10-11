// Location scoping for OpenCode 2 plugin event subscriptions.
//
// OpenCode 2 loads a plugin instance per location, but every instance's
// ctx.event.subscribe() carries the whole server event stream, including
// sessions created at other locations, while tool hooks stay scoped to the
// instance's own location (all verified live on 2.0.26: a plugin loaded for
// one directory received another directory's session events, and a guard
// registered for one directory refused a command only there). Firstmate's
// plugins must act only on sessions that belong to the location they loaded
// for, which is what the V1 per-process runtime gave them.
//
// This module owns that decision for the tracked primary plugins.
// The fm-busy-state plugin fm-spawn generates into a worker worktree carries
// an inlined copy of the same rule because it must stay self-contained where
// no lib directory exists; keep the two in step when either changes.
// bin/fm-primary-scope-lib.sh owns the equivalent scope for shell entrypoints.
import { realpathSync } from "node:fs";
import { resolve } from "node:path";

function resolvePath(anchor) {
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

// createSessionScope(ctx) -> { locationDirectory, belongs(event) }
// belongs(event) resolves the event's session against the plugin instance's
// own location and caches the verdict per session id. A session.created event
// answers from its own location data; every other event resolves through the
// server so a session that existed before the plugin loaded is still scoped
// correctly. A session whose location cannot be resolved counts as foreign,
// so a failed lookup can never widen the plugin's scope.
export function createSessionScope(ctx) {
  const locationDirectory = resolvePath(ctx.location.directory);
  const verdicts = new Map();
  const pending = new Map();

  async function resolveBelongs(sessionID, event) {
    let directory;
    if (event.type === "session.created") {
      directory = event.data?.location?.directory;
    }
    if (typeof directory !== "string" || !directory) {
      try {
        directory = (await ctx.session.get({ sessionID }))?.location?.directory;
      } catch {
        return false;
      }
    }
    return typeof directory === "string" && directory.length > 0 && resolvePath(directory) === locationDirectory;
  }

  return {
    locationDirectory,
    async belongs(event) {
      const sessionID = event?.data?.sessionID;
      if (typeof sessionID !== "string" || !sessionID) return false;
      const known = verdicts.get(sessionID);
      if (known !== undefined) return known;
      let inFlight = pending.get(sessionID);
      if (!inFlight) {
        inFlight = resolveBelongs(sessionID, event).then((belongs) => {
          verdicts.set(sessionID, belongs);
          pending.delete(sessionID);
          return belongs;
        });
        pending.set(sessionID, inFlight);
      }
      return inFlight;
    },
  };
}
