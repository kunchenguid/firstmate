import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.js";
import { createSessionScope } from "./lib/fm-session-scope.js";

// OpenCode 2 plugin (default export with id + setup; the V1 named-function
// shape no longer loads). OpenCode 2 never emits the V1 session.idle event
// (verified live on 2.0.26: it exists in the schema but nothing publishes
// it); the execution-terminal events below are its replacement, and a
// shutdown interrupt is the app closing, not a turn end. Delivery is the V2
// ctx.session.prompt, the form of the V1 client.session.promptAsync call.

const COORDINATOR_KEY = "__firstmateOpenCodeWatchArm";

// The V2 turn-end set: one entry per way an execution can stop.
const TURN_END_TYPES = new Set([
  "session.execution.succeeded",
  "session.execution.failed",
  "session.execution.interrupted",
]);

let skipNextIdle = false;

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

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  return resolvePath(anchor);
}

function resolvePath(anchor) {
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

function runGuard(root) {
  if (!root) return Promise.resolve({ code: 0, stderr: "" });
  return runProcess(`${root}/bin/fm-turnend-guard.sh`, [], '{"stop_hook_active":false}');
}

// The watch-arm plugin registers one coordinator per location on a shared
// Map (its module owns that registry); a location without one falls through
// to the guard.
async function letWatchArmRun(sessionID, ctx) {
  const registry = globalThis[COORDINATOR_KEY];
  const coordinator = registry instanceof Map ? registry.get(ctx.location.directory) : undefined;
  if (!coordinator?.ensureArmed) return false;
  const status = await coordinator.ensureArmed(sessionID, ctx);
  return status === "armed" || status === "wake" || status === "failed";
}

export default {
  id: "fm-primary-turnend-guard",
  async setup(ctx) {
    const root = await resolveRoot(ctx.location.directory);
    const scope = createSessionScope(ctx);
    const controller = new AbortController();
    void (async () => {
      for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
        try {
          if (!TURN_END_TYPES.has(event.type)) continue;
          if (event.type === "session.execution.interrupted" && event.data?.reason === "shutdown") continue;
          if (!(await scope.belongs(event))) continue;

          if (skipNextIdle) {
            skipNextIdle = false;
            continue;
          }

          const sessionID = event.data?.sessionID;
          if (!sessionID) continue;

          if (await letWatchArmRun(sessionID, ctx)) continue;

          const result = await runGuard(root);
          if (result.code !== 2) continue;

          const text = await encodeFirstmateOperationalInput(
            root,
            "turn-end-guard",
            "TURN WOULD END BLIND - supervision is off. " +
              "The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n" +
              result.stderr,
          );
          await ctx.session.prompt({ sessionID, text });
          skipNextIdle = true;
        } catch {
          skipNextIdle = false;
        }
      }
    })();
    return () => controller.abort();
  },
};
