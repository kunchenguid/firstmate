import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { createSessionScope } from "./lib/fm-session-scope.js";

// OpenCode 2 plugin (default export with id + setup; the V1 named-function
// shape no longer loads). session.created still exists on the V2 wire with
// its session id under event.data, and ctx.session.prompt is the V2 form of
// the V1 client.session.promptAsync delivery (both verified live on 2.0.26).
// The V2 event stream is server-wide, so the scope check keeps the nudge on
// this location's own sessions (lib/fm-session-scope.js owns that rule).
//
// The subscription starts before any slow work: on a shared server the
// session can be created while setup's git probe still runs, and a
// subscription registered after that would miss the one session.created this
// plugin exists for. The root therefore resolves lazily inside the handler.

const handledSessions = new Set();

function runProcess(command, args) {
  return new Promise((resolveResult) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "ignore"] });
    let stdout = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.on("error", () => resolveResult({ code: 0, stdout: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stdout }));
  });
}

function resolvePath(anchor) {
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  return resolvePath(anchor);
}

export default {
  id: "fm-primary-sessionstart-nudge",
  async setup(ctx) {
    const scope = createSessionScope(ctx);
    let rootPromise = null;
    const root = () => (rootPromise ??= resolveRoot(ctx.location.directory));
    const controller = new AbortController();
    void (async () => {
      for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
        try {
          if (event.type !== "session.created") continue;
          const sessionID = event.data?.sessionID;
          if (!sessionID || handledSessions.has(sessionID)) continue;
          if (!(await scope.belongs(event))) continue;
          handledSessions.add(sessionID);

          const rootDir = await root();
          if (!rootDir) continue;
          const result = await runProcess(`${rootDir}/bin/fm-sessionstart-nudge.sh`, []);
          const nudge = result.code === 0 ? result.stdout.trim() : "";
          if (!nudge) continue;

          await ctx.session.prompt({ sessionID, text: nudge });
        } catch {
          // One event must never end the subscription: the nudge must keep
          // working for later sessions.
        }
      }
    })();
    return () => controller.abort();
  },
};
