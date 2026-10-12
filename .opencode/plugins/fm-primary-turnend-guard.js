import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.js";
import { contextDirectory, createTurnEndLatch, promptSession, setupEventSubscription } from "./lib/fm-opencode2.js";

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
  const latch = createTurnEndLatch();

  return {
    event: async ({ event }) => {
      if (event.type !== "session.idle") return;

      const sessionID = event.properties?.sessionID;
      if (!sessionID) return;

      if (latch.consume(sessionID)) return;

      if (await letWatchArmRun(sessionID, client)) return;

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
        await client.session.promptAsync({
          path: { id: sessionID },
          body: {
            parts: [{ type: "text", text }],
          },
        });
        latch.exempt(sessionID);
      } catch {
        // Delivery failed: no follow-up was queued, so leave the session
        // unexempted and let its next terminal event run the guard again.
      }
    },
  };
};

function installTurnendGuard(ctx) {
  const anchor = contextDirectory(ctx);
  let rootPromise = null;
  const getRoot = () => (rootPromise ??= resolveRoot(anchor));
  const latch = createTurnEndLatch();
  setupEventSubscription(ctx, async (event) => {
    const sessionID = latch(event);
    if (!sessionID) return;

    if (latch.consume(sessionID)) return;

    if (await letWatchArmRun(sessionID, null)) return;

    const root = await getRoot();
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
      await promptSession(ctx, null, sessionID, text);
      latch.exempt(sessionID);
    } catch {
      // Delivery failed: no follow-up was queued, so leave the session
      // unexempted and let its next terminal event run the guard again.
    }
  });
}

export default {
  id: "fm.primary.turnend-guard",
  server: FmPrimaryTurnendGuard,
  setup(ctx) {
    installTurnendGuard(ctx);
  },
};
