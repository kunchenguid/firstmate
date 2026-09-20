import { spawn } from "node:child_process";
import { pluginRoot, subscribeToEvents } from "./lib/fm-v2-plugin.js";

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

export async function createSessionstartNudgeHandler(ctx) {
  const root = pluginRoot(ctx);

  return async (event) => {
    if (event.type !== "session.created") return;
    const sessionID = event.data.sessionID;
    if (!sessionID || handledSessions.has(sessionID) || !root) return;
    handledSessions.add(sessionID);

    const result = await runProcess(`${root}/bin/fm-sessionstart-nudge.sh`, []);
    const nudge = result.code === 0 ? result.stdout.trim() : "";
    if (!nudge) return;

    try {
      await ctx.session.prompt({ sessionID, text: nudge });
    } catch {
    }
  };
}

export default {
  id: "firstmate.primary-sessionstart-nudge",
  async setup(ctx) {
    return subscribeToEvents(ctx, await createSessionstartNudgeHandler(ctx));
  },
};
