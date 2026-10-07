import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";

// The ONE owner of how firstmate's OpenCode plugins read the host's plugin
// contract. Every plugin in this directory imports these helpers instead of
// restating them, because three of the facts here are safety-relevant and a
// second copy of any of them would drift into a silently disabled guard.
//
// Every claim below was verified against OpenCode 2.0.20 and
// @opencode/plugin 2.0.20 by running real sessions, not read off the v1 API:
// a plugin's own location, the scope of the event stream, and the turn-end
// signal all changed shape, and the tool the seatbelts police was renamed.

// The shell tool's effective name. OpenCode 1 called it "bash"; OpenCode 2
// registers it as "shell" (verified against ctx.tool.list() and against a live
// execute.before event). A seatbelt that still tested for "bash" would match no
// call at all and read as installed while guarding nothing.
export const SHELL_TOOL = "shell";

// `options.input` is written to the child's stdin, which some firstmate guard
// scripts require: bin/fm-turnend-guard.sh reads its whole turn-end hook
// payload from stdin and exits 0 immediately when stdin is empty, so a caller
// that stops sending the payload turns that guard into a permanent no-op
// instead of an error. Any other key is passed through to spawn.
export function runProcess(command, args, options = {}) {
  const { input, ...spawnOptions } = typeof options === "string" ? { input: options } : options;
  return new Promise((resolvePromise) => {
    const child = spawn(command, args, {
      stdio: [input === undefined ? "ignore" : "pipe", "pipe", "pipe"],
      ...spawnOptions,
    });
    let stdout = "";
    let stderr = "";
    // A caller that asks for "ignore" on a stream makes the matching property
    // null rather than an empty stream, so attaching to it unconditionally
    // throws inside the promise executor and rejects the call. A caller that
    // only inspects the result never sees that, which is how a nudge or a guard
    // can go silently dead; the streams are therefore optional here.
    child.stdout?.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr?.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", (error) => resolvePromise({ code: 127, stdout, stderr: String(error?.message ?? error) }));
    child.on("close", (code) => resolvePromise({ code: code ?? 0, stdout, stderr }));
    if (input !== undefined) child.stdin.end(input);
  });
}

export function resolvePath(anchor) {
  if (!anchor) return "";
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

export async function resolveRepositoryRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  return resolvePath(anchor);
}

// The firstmate root this plugin instance belongs to.
//
// OpenCode 1 handed a plugin `{ directory, worktree }` and every plugin here
// resolved its root from `worktree` when the session ran inside a worktree and
// from `directory` otherwise. OpenCode 2 replaced that pair: `ctx.location` now
// carries this instance's own `directory` (which IS the worktree when there is
// one) alongside `project.canonical` (always the canonical project root, so in
// a worktree it names the primary checkout and is NOT what these plugins want).
// The same two branches are therefore reproduced from those two fields.
export async function resolvePluginRoot(ctx) {
  const directory = ctx?.location?.directory;
  const canonical = ctx?.location?.project?.canonical;
  const worktree = canonical && directory && directory !== canonical ? directory : undefined;
  if (worktree) return resolvePath(worktree);
  return resolveRepositoryRoot(canonical || directory);
}

// Whether an event belongs to this plugin instance's own location.
//
// OpenCode 2's ctx.event.subscribe() is the connected server's entire public
// event stream, not this instance's: one server serves every location, and a
// plugin in one worktree observes sessions, tool calls and turns in all the
// others. Each event carries the location it belongs to, so every handler here
// filters on it. An event that publishes no location (session.execution.* does
// not) belongs to no location and is ignored rather than attributed by guess.
export function isOwnEvent(ctx, event) {
  const own = ctx?.location?.directory;
  const directory = event?.location?.directory;
  return Boolean(own) && Boolean(directory) && directory === own;
}

// The session whose turn just ended, or null when this event is not that
// boundary.
//
// OpenCode 2 no longer delivers OpenCode 1's `session.idle` to a plugin
// subscription: it is absent from the stream across repeated real sessions,
// even though it remains in the published event schema. A turn ends when its
// last step ends, which is a `session.step.ended` whose `finish` is not
// "tool-calls" - a "tool-calls" step is the agent loop continuing into a
// further step, not the end of the turn. `ctx.session.wait()` resolves at the
// same instant and is the documented wait primitive, but it is a long poll per
// session rather than the event these plugins are built around.
//
// Known limit, stated rather than papered over: a turn that dies in a hard
// provider failure reports `session.step.failed`, whose data carries no
// sessionID, so it cannot be attributed to a session here and is not treated as
// a turn end. Continuity in that case rests on the watcher's bounded retry
// rather than on a turn-end trigger.
export function turnEndedSessionID(event) {
  if (event?.type !== "session.step.ended") return null;
  if (event.data?.finish === "tool-calls") return null;
  return event.data?.sessionID ?? null;
}

// Subscribe to this instance's own events and return a cleanup that ends the
// subscription. A handler that throws is contained here: one bad event must not
// end a long-lived subscription, because a dead subscription is exactly the
// blind supervision this directory exists to prevent.
export function subscribeOwnEvents(ctx, handler) {
  const controller = new AbortController();
  void (async () => {
    for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
      if (!isOwnEvent(ctx, event)) continue;
      try {
        await handler(event);
      } catch {
        // Contained on purpose; see above.
      }
    }
  })();
  return () => controller.abort();
}
