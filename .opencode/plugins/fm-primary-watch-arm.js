import { spawn } from "node:child_process";
import { existsSync, readFileSync, readdirSync, realpathSync } from "node:fs";
import { resolve } from "node:path";

const COORDINATOR_KEY = "__firstmateOpenCodeWatchArm";
const ARM_READY_TIMEOUT_MS = Number(process.env.FM_OPENCODE_ARM_READY_TIMEOUT_MS || 12000);

let child = null;
let armStatus = "idle";
let waiters = new Set();

function setArmStatus(status) {
  armStatus = status;
  for (const resolve of waiters) resolve(status);
  waiters.clear();
}

function readyStatus() {
  if (armStatus === "armed" || armStatus === "wake" || armStatus === "failed" || armStatus === "external") return armStatus;
  return "";
}

function waitForArmReady() {
  const ready = readyStatus();
  if (ready) return Promise.resolve(ready);
  return new Promise((resolve) => {
    let timer = null;
    const waiter = (status) => {
      if (timer) clearTimeout(timer);
      waiters.delete(waiter);
      resolve(status);
    };
    timer = setTimeout(() => {
      waiters.delete(waiter);
      resolve("timeout");
    }, ARM_READY_TIMEOUT_MS);
    waiters.add(waiter);
  });
}

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
  return resolvePath(anchor);
}

function resolvePath(anchor) {
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

function effectivePaths(root) {
  const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
  const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || fmRoot;
  const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
  const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
  return { root: fmRoot, home: fmHome, state, config };
}

async function isPrimaryRoot(root, home) {
  if (!root) return false;
  if (!existsSync(`${root}/AGENTS.md`) || !existsSync(`${root}/bin`)) return false;
  if (existsSync(`${root}/.fm-secondmate-home`)) return false;
  if (home && home !== root && existsSync(`${home}/.fm-secondmate-home`)) return false;
  const gitDir = await runProcess("git", ["-C", root, "rev-parse", "--git-dir"]);
  const commonDir = await runProcess("git", ["-C", root, "rev-parse", "--git-common-dir"]);
  if (gitDir.code !== 0 || commonDir.code !== 0) return false;
  return gitDir.stdout.trim() === commonDir.stdout.trim();
}

function shouldArm(paths) {
  if (existsSync(`${paths.state}/.afk`)) return false;
  if (existsSync(`${paths.config}/x-mode.env`)) return true;
  try {
    return readdirSync(paths.state).some((name) => name.endsWith(".meta"));
  } catch {
    return false;
  }
}

async function sessionOwnsLock(paths) {
  let lockPid = "";
  try {
    lockPid = readFileSync(`${paths.state}/.lock`, "utf8").trim();
  } catch {
    return false;
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return false;
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) return true;
    const result = await runProcess("ps", ["-o", "ppid=", "-p", pid]);
    if (result.code !== 0) return false;
    pid = result.stdout.trim();
    if (!pid || pid === "1") return false;
  }
  return false;
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

function observeArmOutput(stdout, stderr) {
  const combined = `${stdout}\n${stderr}`;
  if (combined.split(/\r?\n/).some((line) => /^watcher: started\b/.test(line))) {
    setArmStatus("armed");
    return;
  }
  if (combined.split(/\r?\n/).some((line) => /^watcher: healthy\b/.test(line))) {
    setArmStatus("external");
    return;
  }
  if (combined.split(/\r?\n/).some((line) => /^watcher: FAILED/.test(line))) {
    setArmStatus("failed");
  }
}

async function sendPrompt(client, sessionID, text) {
  await client.session.promptAsync({
    path: { id: sessionID },
    body: {
      parts: [
        {
          type: "text",
          text,
        },
      ],
    },
  });
}

function spawnArm(paths, sessionID, client) {
  setArmStatus("starting");
  const env = {
    ...process.env,
    FM_HOME: paths.home,
    FM_ROOT_OVERRIDE: paths.root,
  };
  child = spawn("bash", ["-lc", 'config_dir="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"; [ -f "$config_dir/x-mode.env" ] && . "$config_dir/x-mode.env"; exec "$FM_ROOT_OVERRIDE/bin/fm-watch-arm.sh" --restart'], {
    cwd: paths.root,
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => {
    stdout += chunk.toString();
    observeArmOutput(stdout, stderr);
  });
  child.stderr.on("data", (chunk) => {
    stderr += chunk.toString();
    observeArmOutput(stdout, stderr);
  });
  child.on("close", async (code) => {
    child = null;
    const reason = firstWakeOrFailure(stdout, stderr, code);
    if (reason) setArmStatus(reason.startsWith("watcher: FAILED") ? "failed" : "wake");
    else if (!readyStatus()) setArmStatus("idle");
    if (!reason) return;
    try {
      await sendPrompt(
        client,
        sessionID,
        `WATCHER FIRED - drain queued wakes with bin/fm-wake-drain.sh, handle the reported wake, and continue normal supervision.\n\n${reason}`,
      );
    } catch {
    }
  });
  child.on("error", async (error) => {
    child = null;
    setArmStatus("failed");
    try {
      await sendPrompt(
        client,
        sessionID,
        `WATCHER FIRED - drain queued wakes with bin/fm-wake-drain.sh, handle the reported wake, and continue normal supervision.\n\nwatcher: FAILED - OpenCode arm child failed: ${error.message}`,
      );
    } catch {
    }
  });
}

async function ensureArm(paths, sessionID, client) {
  if (!sessionID) return "skipped";
  if (!(await isPrimaryRoot(paths.root, paths.home))) return "not-primary";
  if (!(await sessionOwnsLock(paths))) return "read-only";
  if (child) return waitForArmReady();
  if (!shouldArm(paths)) return "not-needed";
  spawnArm(paths, sessionID, client);
  return waitForArmReady();
}

export const FmPrimaryWatchArm = async ({ client, directory, worktree }) => {
  const root = worktree ? resolvePath(worktree) : await resolveRoot(directory);
  const paths = effectivePaths(root);
  globalThis[COORDINATOR_KEY] = {
    ensureArmed: (sessionID, activeClient) => ensureArm(paths, sessionID, activeClient ?? client),
  };

  return {
    event: async ({ event }) => {
      if (event.type !== "session.idle") return;
      const sessionID = event.properties?.sessionID;
      if (!sessionID) return;
      void ensureArm(paths, sessionID, client);
    },
  };
};
