import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.js";

const COORDINATOR_KEY = "__firstmateOpenCodeWatchArm";
// OpenCode v2 deprecated session.idle/session.status; the turn boundary is the
// session.execution.* lifecycle (verified 2026-09-27 against OpenCode 2.0.18).
const TURN_END_EVENT_TYPES = new Set([
  "session.execution.succeeded",
  "session.execution.failed",
  "session.execution.interrupted",
]);

let skipNextTurnEnd = false;

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

// The watch-arm plugin owns one coordinator per server process (module scope
// is shared across plugin instances in OpenCode v2 exactly as it was in V1,
// since every project plugin still loads into the same server process).
// ensureArmed only needs a session id: it calls the watch-arm plugin's own
// captured ctx.session.prompt, so no client/ctx handoff is needed here.
async function letWatchArmRun(sessionID) {
  const coordinator = globalThis[COORDINATOR_KEY];
  if (!coordinator?.ensureArmed) return false;
  const status = await coordinator.ensureArmed(sessionID);
  return status === "armed" || status === "wake" || status === "failed";
}

// An unexpected failure while handling one turn end must stay visible: the
// server's stderr is the only channel this plugin owns, and swallowing the
// error as if it were teardown is what lets later turns go unguarded with no
// trace. The subscription itself is kept alive by the caller.
function surfaceGuardError(error) {
  const detail = error?.stack || String(error?.message ?? error);
  process.stderr.write(
    `fm-primary-turnend-guard: unexpected error while processing a turn end; later turns are still guarded\n${detail}\n`,
  );
}

export default {
  id: "fm-primary-turnend-guard",
  async setup(ctx) {
    const root = await resolveRoot(ctx.location?.directory);
    const controller = new AbortController();

    async function handleTurnEnd(event) {
      if (!TURN_END_EVENT_TYPES.has(event.type)) return;

      if (skipNextTurnEnd) {
        skipNextTurnEnd = false;
        return;
      }

      const sessionID = event.data?.sessionID;
      if (!sessionID) return;

      if (await letWatchArmRun(sessionID)) return;

      const result = await runGuard(root);
      if (result.code !== 2) return;

      // Cleared before the awaits so a failed encode or prompt leaves the next
      // turn end guarded again instead of skipped.
      skipNextTurnEnd = false;
      const text = await encodeFirstmateOperationalInput(
        root,
        "turn-end-guard",
        "TURN WOULD END BLIND - supervision is off. " +
          "The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n" +
          result.stderr,
      );
      await ctx.session.prompt({ sessionID, text, delivery: "queue" });
      skipNextTurnEnd = true;
    }

    void (async () => {
      try {
        for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
          try {
            await handleTurnEnd(event);
          } catch (error) {
            // One turn's failure never ends the subscription: later turns still
            // need their guard check.
            if (!controller.signal.aborted) surfaceGuardError(error);
          }
        }
      } catch (error) {
        // The event stream ends when the abort signal fires at teardown; any
        // other stream failure is unexpected and must stay visible.
        if (!controller.signal.aborted) surfaceGuardError(error);
      }
    })();

    return () => controller.abort();
  },
};
