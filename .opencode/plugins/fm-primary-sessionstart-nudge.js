import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";

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

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

export default {
  id: "fm-primary-sessionstart-nudge",
  async setup(ctx) {
    const root = await resolveRoot(ctx.location?.directory);
    const controller = new AbortController();

    void (async () => {
      try {
        for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
          if (event.type !== "session.created") continue;
          const sessionID = event.data?.sessionID;
          if (!sessionID || handledSessions.has(sessionID) || !root) continue;
          handledSessions.add(sessionID);

          const result = await runProcess(`${root}/bin/fm-sessionstart-nudge.sh`, []);
          const nudge = result.code === 0 ? result.stdout.trim() : "";
          if (!nudge) continue;

          try {
            await ctx.session.prompt({ sessionID, text: nudge, delivery: "queue" });
          } catch {
            // Best-effort nudge; a delivery failure never blocks the session.
          }
        }
      } catch {
        // The event stream ends when the abort signal fires at teardown.
      }
    })();

    return () => controller.abort();
  },
};
