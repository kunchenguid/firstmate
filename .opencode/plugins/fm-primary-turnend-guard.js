import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.js";

const COORDINATOR_KEY = "__firstmateOpenCodeWatchArm";
const CONTAINMENT_WARNING_PREFIX = "WARNING: process-event state is not private to this home:";

let skipNextIdle = false;
// The guard warns about process-event state no fm-procevent.sh command can
// service and still allows the turn, so that line only reaches an operator if
// this adapter surfaces it on the non-blocking path too. Latched by text so a
// standing repair is announced once per episode, not once per turn.
let reportedContainmentWarning = "";

function containmentWarning(stderr) {
  const line = String(stderr ?? "")
    .split("\n")
    .find((candidate) => candidate.startsWith(CONTAINMENT_WARNING_PREFIX));
  return line ? line.trim() : "";
}

// A toast is the only OpenCode surface that reports without consuming a turn.
// It is probed, never assumed: a client without it degrades to the guard's
// stderr rather than forcing a prompt this warning must never force.
async function reportContainment(client, warning) {
  if (!warning) {
    reportedContainmentWarning = "";
    return;
  }
  if (warning === reportedContainmentWarning) return;
  reportedContainmentWarning = warning;
  try {
    await client?.tui?.showToast?.({ body: { message: warning, variant: "warning" } });
  } catch {
    reportedContainmentWarning = "";
  }
}

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

async function letWatchArmRun(sessionID, client) {
  const coordinator = globalThis[COORDINATOR_KEY];
  if (!coordinator?.ensureArmed) return false;
  const status = await coordinator.ensureArmed(sessionID, client);
  return status === "armed" || status === "wake" || status === "failed";
}

export const FmPrimaryTurnendGuard = async ({ client, directory, worktree }) => {
  const root = worktree ? resolvePath(worktree) : await resolveRoot(directory);

  return {
    event: async ({ event }) => {
      if (event.type !== "session.idle") return;

      if (skipNextIdle) {
        skipNextIdle = false;
        return;
      }

      const sessionID = event.properties?.sessionID;
      if (!sessionID) return;

      if (await letWatchArmRun(sessionID, client)) return;

      const result = await runGuard(root);
      await reportContainment(client, containmentWarning(result.stderr));
      if (result.code !== 2) return;

      try {
        const text = await encodeFirstmateOperationalInput(
          root,
          "turn-end-guard",
          "TURN WOULD END BLIND - supervision is off. " +
            "The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n" +
            result.stderr,
        );
        await client.session.promptAsync({
          path: { id: sessionID },
          body: {
            parts: [{ type: "text", text }],
          },
        });
        skipNextIdle = true;
      } catch {
        skipNextIdle = false;
      }
    },
  };
};
