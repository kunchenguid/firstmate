import { spawn } from "node:child_process";
import { pluginRoot } from "./lib/fm-v2-plugin.js";

// PreToolUse seatbelt for OpenCode: block a stray persistent top-level `cd` in
// the primary firstmate checkout before the agent's bash tool relocates the
// shell out of the home (see bin/fm-cd-pretool-check.sh and docs/cd-guard.md).
// This mirrors fm-primary-pretool-check.js, calling the cd-guard owner instead
// of the watcher-arm one. The owner script is itself inert outside the
// real primary checkout, so a crewmate/scout worktree is never affected.

function runProcess(command, args) {
  return new Promise((resolvePromise) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolvePromise({ code: 0, stdout: "", stderr: "" }));
    child.on("close", (code) => resolvePromise({ code: code ?? 0, stdout, stderr }));
  });
}

export async function createCdCheckHandler(ctx) {
  const root = pluginRoot(ctx);

  return async (event) => {
    if (!root || event.tool !== "shell") return;
    const command = event.input?.command;
    if (!command || typeof command !== "string") return;

    const result = await runProcess(`${root}/bin/fm-cd-pretool-check.sh`, ["--command", command]);
    if (result.code !== 2) return;

    const reason = result.stderr.trim() || "denied by the cd-guard PreToolUse seatbelt";
    throw new Error(reason);
  };
}

export default {
  id: "firstmate.primary-cd-check",
  async setup(ctx) {
    await ctx.tool.hook("execute.before", await createCdCheckHandler(ctx));
  },
};
