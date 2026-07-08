import { spawn } from "node:child_process";
import { existsSync, readdirSync } from "node:fs";

let child = null;
let skipNextIdle = false;

function runProcess(command, args, options = {}) {
  return new Promise((resolve) => {
    const proc = spawn(command, args, {
      stdio: ["ignore", "pipe", "pipe"],
      ...options,
    });
    let stdout = "";
    let stderr = "";
    proc.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    proc.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    proc.on("error", (error) => resolve({ code: 127, stdout, stderr: String(error?.message ?? error) }));
    proc.on("close", (code) => resolve({ code: code ?? 0, stdout, stderr }));
  });
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  return anchor;
}

async function isPrimaryRoot(root) {
  if (!root) return false;
  if (!existsSync(`${root}/AGENTS.md`) || !existsSync(`${root}/bin`) || !existsSync(`${root}/state`)) return false;
  if (existsSync(`${root}/.fm-secondmate-home`)) return false;
  const gitDir = await runProcess("git", ["-C", root, "rev-parse", "--git-dir"]);
  const commonDir = await runProcess("git", ["-C", root, "rev-parse", "--git-common-dir"]);
  if (gitDir.code !== 0 || commonDir.code !== 0) return false;
  return gitDir.stdout.trim() === commonDir.stdout.trim();
}

function shouldArm(root) {
  if (existsSync(`${root}/state/.afk`)) return false;
  if (existsSync(`${root}/config/x-mode.env`)) return true;
  try {
    return readdirSync(`${root}/state`).some((name) => name.endsWith(".meta"));
  } catch {
    return false;
  }
}

function firstWakeOrFailure(stdout, stderr, code) {
  const combined = `${stdout}\n${stderr}`;
  const reason = combined.split(/\r?\n/).find((line) => /^(signal:|stale:|check:|heartbeat($|:))/.test(line));
  if (reason) return reason;
  if (/^watcher: healthy/m.test(combined)) return "";
  const failed = combined.split(/\r?\n/).find((line) => /^watcher: FAILED/.test(line));
  if (failed) return failed;
  if (code && code !== 0) return `watcher: FAILED - fm-watch-arm.sh exited ${code}${combined.trim() ? `\n${combined.trim()}` : ""}`;
  return "";
}

function spawnArm(root, sessionID, client) {
  child = spawn("bash", ["-lc", "[ -f config/x-mode.env ] && . config/x-mode.env; exec bin/fm-watch-arm.sh"], {
    cwd: root,
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => {
    stdout += chunk.toString();
  });
  child.stderr.on("data", (chunk) => {
    stderr += chunk.toString();
  });
  child.on("close", async (code) => {
    child = null;
    const reason = firstWakeOrFailure(stdout, stderr, code);
    if (!reason) return;
    try {
      await client.session.promptAsync({
        path: { id: sessionID },
        body: {
          parts: [
            {
              type: "text",
              text: `WATCHER FIRED - drain queued wakes with bin/fm-wake-drain.sh, handle the reported wake, and continue normal supervision.\n\n${reason}`,
            },
          ],
        },
      });
      skipNextIdle = true;
    } catch {
      skipNextIdle = false;
    }
  });
}

export const FmPrimaryWatchArm = async ({ client, directory, worktree }) => {
  const root = await resolveRoot(worktree ?? directory);
  const primary = await isPrimaryRoot(root);

  return {
    event: async ({ event }) => {
      if (event.type !== "session.idle") return;
      if (!primary) return;
      if (skipNextIdle) {
        skipNextIdle = false;
        return;
      }
      if (child) return;
      const sessionID = event.properties?.sessionID;
      if (!sessionID) return;
      if (!shouldArm(root)) return;
      spawnArm(root, sessionID, client);
    },
  };
};
