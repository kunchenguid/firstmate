import { spawn } from "node:child_process";
import { pluginRoot } from "./lib/fm-v2-plugin.js";

// PreToolUse seatbelt for OpenCode: the arm mechanism itself lives entirely in
// fm-primary-watch-arm.js (a plugin-owned child process, never a model tool
// call), so the residual risk here is the AGENT shelling `bin/fm-watch-arm.sh`
// wrong through its own bash tool - the anti-pattern bin/fm-arm-pretool-check.sh
// guards against (see that script's header and docs/arm-pretool-check.md).

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

export async function createPretoolCheckHandler(ctx) {
  const root = pluginRoot(ctx);

  return async (event) => {
    if (!root || !["shell", "bash"].includes(event.tool)) return;
    const command = event.input?.command;
    if (!command || typeof command !== "string") return;

    const result = await runProcess(`${root}/bin/fm-arm-pretool-check.sh`, ["--command", command]);
    if (result.code !== 2) return;

    const reason = result.stderr.trim() || "denied by the watcher-arm PreToolUse seatbelt";
    throw new Error(reason);
  };
}

export default {
  id: "firstmate.primary-pretool-check",
  async setup(ctx) {
    await ctx.tool.hook("execute.before", await createPretoolCheckHandler(ctx));
  },
};
