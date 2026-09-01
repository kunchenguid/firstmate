import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { effectiveHomePaths, sendEncodedWakePrompt } from "./lib/fm-wake-delivery.js";

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

export const FmPrimarySessionstartNudge = async ({ client, directory, worktree }) => {
  const root = worktree ? resolvePath(worktree) : await resolveRoot(directory);

  return {
    event: async ({ event }) => {
      if (event.type !== "session.created") return;
      const sessionID = event.properties?.info?.id ?? event.properties?.sessionID;
      if (!sessionID || handledSessions.has(sessionID) || !root) return;
      handledSessions.add(sessionID);

      const result = await runProcess(`${root}/bin/fm-sessionstart-nudge.sh`, []);
      const nudge = result.code === 0 ? result.stdout.trim() : "";
      if (!nudge) return;

      // The nudge wrapper already emitted operational-encoded text, so deliver
      // it as-is. That delivery doubles as the session-start self-check of the
      // running build's wake-injection path: a stale OpenCode TUI that cannot
      // accept prompts is recorded and alarmed here instead of being discovered
      // through missed watcher wakes, and the next bootstrap surfaces it as the
      // WAKE_DELIVERY diagnostic.
      await sendEncodedWakePrompt(
        effectiveHomePaths(root),
        client,
        sessionID,
        "session-start",
        nudge,
        "session-start nudge",
      );
    },
  };
};
