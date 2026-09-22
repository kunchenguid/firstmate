import { spawn } from "node:child_process";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.js";
import { pluginRoot, subscribeToEvents } from "./lib/fm-v2-plugin.js";

const COORDINATOR_KEY = "__firstmateOpenCodeWatchArm";

function runProcess(command, args, input = "") {
  return new Promise((resolve) => {
    const child = spawn(command, args, {
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolve({ code: 0, stdout: "", stderr: "" }));
    child.on("close", (code) => resolve({ code: code ?? 0, stdout, stderr }));
    child.stdin.end(input);
  });
}

function runGuard(root) {
  if (!root) return Promise.resolve({ code: 0, stderr: "" });
  return runProcess(`${root}/bin/fm-turnend-guard.sh`, [], '{"stop_hook_active":false}');
}

async function letWatchArmRun(sessionID, ctx) {
  const coordinator = globalThis[COORDINATOR_KEY];
  if (!coordinator?.ensureArmed) return false;
  const status = await coordinator.ensureArmed(sessionID, ctx);
  return status === "armed" || status === "wake" || status === "failed";
}

export async function createTurnendGuardHandler(ctx) {
  const root = pluginRoot(ctx);
  const skippedSessionIDs = new Set();

  return async (event) => {
    if (event.type !== "session.execution.succeeded" && event.type !== "session.execution.failed") return;
    const sessionID = event.data.sessionID;
    if (!sessionID) return;

    if (skippedSessionIDs.delete(sessionID)) {
      return;
    }

    if (await letWatchArmRun(sessionID, ctx)) return;

    const result = await runGuard(root);
    if (result.code !== 2) return;

    try {
      const text = await encodeFirstmateOperationalInput(
        root,
        "turn-end-guard",
        "TURN WOULD END BLIND - supervision is off. " +
          "The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n" +
          result.stderr,
      );
      await ctx.session.prompt({ sessionID, text });
      skippedSessionIDs.add(sessionID);
    } catch {
      skippedSessionIDs.delete(sessionID);
    }
  };
}

export default {
  id: "firstmate.primary-turnend-guard",
  async setup(ctx) {
    return subscribeToEvents(ctx, await createTurnendGuardHandler(ctx));
  },
};
