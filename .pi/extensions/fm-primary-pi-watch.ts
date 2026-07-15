// Firstmate primary watcher bridge for Pi.
// Every arm call reuses bin/fm-wake-lib.sh's identity+beacon health predicate.
// The extension owns each detached arm process group until all inherited pipes
// close, so stale cycles and clean Pi exit terminate exact descendants without
// a cross-home process-name kill.
import { spawn, spawnSync, type ChildProcessByStdio } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { Readable } from "node:stream";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

type ArmResult = {
  ok: boolean;
  message: string;
};

type LockOwnership = "owned" | "missing" | "other";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const armScript = `${fmRoot}/bin/fm-watch-arm.sh`;
const watchScript = (() => {
  const path = `${fmRoot}/bin/fm-watch.sh`;
  try {
    return realpathSync(path);
  } catch {
    return path;
  }
})();
const wakeLib = `${fmRoot}/bin/fm-wake-lib.sh`;
const marker = `${state}/.pi-watch-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;

type ArmChild = ChildProcessByStdio<null, Readable, Readable>;

let child: ArmChild | null = null;
const ownedGroups = new Set<number>();
const closingChildren = new Map<number, ArmChild>();
const intentionalStops = new WeakSet<ArmChild>();
let seq = 0;

function parentPid(pid: string): string {
  const result = spawnSync("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" });
  if (result.status !== 0) return "";
  return result.stdout.trim();
}

function pidAlive(pid: string): boolean {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

function lockOwnership(): LockOwnership {
  let lockPid = "";
  try {
    lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
  } catch {
    return "missing";
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "other";
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) return "owned";
    pid = parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return pidAlive(lockPid) ? "other" : "missing";
}

function sessionOwnsLock(): boolean {
  return lockOwnership() === "owned";
}

function healthyWatcherPid(): string {
  const grace = process.env.FM_GUARD_GRACE || "300";
  const result = spawnSync(
    "bash",
    ["-c", '. "$1"; fm_watcher_healthy "$2" "$3" "$4" "$5" && printf "%s" "$FM_WATCHER_HEALTHY_PID"', "_", wakeLib, state, watchScript, grace, fmHome],
    { encoding: "utf8", env: process.env, timeout: 2000 },
  );
  return result.status === 0 ? result.stdout.trim() : "";
}

function childOwnsWatcher(arm: ArmChild, watcherPid: string): boolean {
  let pid = watcherPid;
  for (let i = 0; i < 16 && pid; i += 1) {
    if (pid === String(arm.pid)) return true;
    pid = parentPid(pid);
  }
  return false;
}

function markLoaded(): void {
  if (lockOwnership() === "other") return;
  mkdirSync(state, { recursive: true });
  writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
}

function actionableLine(output: string): string {
  const lines = output.split(/\r?\n/);
  return lines.find((line) => /^(signal:|stale:|check:|heartbeat($|:))/.test(line)) || "";
}

function reportedFailureLine(output: string): string {
  const lines = output.split(/\r?\n/);
  const healthy = lines.find((line) => /^watcher: healthy\b/.test(line));
  if (healthy) return `watcher: FAILED - Pi extension arm child found an external healthy watcher instead of owning wake delivery\n${healthy}`;
  return lines.find((line) => /^watcher: FAILED/.test(line)) || "";
}

function failureLine(stdout: string, stderr: string, code: number | null): string {
  const combined = `${stdout}\n${stderr}`.trim();
  const reported = reportedFailureLine(combined);
  if (reported) return reported;
  if (code && code !== 0) return `watcher: FAILED - fm-watch-arm.sh exited ${code}${combined ? `\n${combined}` : ""}`;
  return "";
}

export default function (pi: ExtensionAPI) {
  function stopOwnedGroups(): void {
    for (const pid of ownedGroups) {
      const closingChild = closingChildren.get(pid);
      if (closingChild) intentionalStops.add(closingChild);
      spawnSync(
        "bash",
        ["-c", 'kill -TERM -- "-$1" 2>/dev/null || true; sleep 0.2; kill -KILL -- "-$1" 2>/dev/null || true', "_", String(pid)],
        { timeout: 1000 },
      );
    }
    ownedGroups.clear();
  }

  function stopArm(): void {
    if (child) intentionalStops.add(child);
    stopOwnedGroups();
    child = null;
  }

  const cleanupOnProcessExit = () => {
    stopArm();
  };
  process.once("exit", cleanupOnProcessExit);

  async function sendWake(message: string) {
    await pi.sendUserMessage(
      `FIRSTMATE WATCHER WAKE: ${message}\n\nRun bin/fm-wake-drain.sh first, handle the queued wake, then resume Pi supervision.`,
      { deliverAs: "followUp" },
    );
  }

  function startArm(): ArmResult {
    if (!sessionOwnsLock()) return { ok: false, message: "watcher: read-only - session lock is held by another firstmate session" };
    markLoaded();
    if (child) {
      const watcherPid = healthyWatcherPid();
      if (watcherPid && childOwnsWatcher(child, watcherPid)) {
        return { ok: true, message: `watcher: healthy - Pi extension owns watcher pid ${watcherPid}` };
      }
      stopArm();
    } else if (ownedGroups.size > 0) {
      // An arm shell exited while descendants retained its pipes. Reap the
      // exact extension-owned group before starting another home-scoped cycle.
      stopOwnedGroups();
    }
    const id = ++seq;
    const env = {
      ...process.env,
      FM_HOME: fmHome,
      FM_ROOT_OVERRIDE: fmRoot,
      FM_CONFIG_OVERRIDE: config,
      FM_WATCH_ARM_SCRIPT: armScript,
    };
    const armChild = spawn("bash", ["-lc", "config_dir=\"${FM_CONFIG_OVERRIDE:-$FM_HOME/config}\"; [ -f \"$config_dir/x-mode.env\" ] && . \"$config_dir/x-mode.env\"; exec \"$FM_WATCH_ARM_SCRIPT\" --restart"], {
      cwd: fmRoot,
      env,
      stdio: ["ignore", "pipe", "pipe"],
      detached: true,
    });
    child = armChild;
    if (armChild.pid) {
      ownedGroups.add(armChild.pid);
      closingChildren.set(armChild.pid, armChild);
    }
    let stdout = "";
    let stderr = "";
    armChild.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
    });
    armChild.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString();
    });
    armChild.on("exit", () => {
      if (child === armChild) child = null;
    });
    armChild.on("close", async (code: number | null) => {
      if (armChild.pid) {
        ownedGroups.delete(armChild.pid);
        closingChildren.delete(armChild.pid);
      }
      const combined = `${stdout}\n${stderr}`.trim();
      const reason = actionableLine(combined);
      const reportedFailure = reportedFailureLine(combined);
      const stoppedByExtension = intentionalStops.has(armChild);
      intentionalStops.delete(armChild);
      if (stoppedByExtension && !reason && !reportedFailure) return;
      const failure = reason ? "" : reportedFailure || failureLine(stdout, stderr, code);
      if (!reason && !failure) return;
      try {
        await sendWake(reason || failure);
      } catch {
        // Pi owns delivery errors; fail open so the extension never wedges the session.
      }
    });
    armChild.on("error", async (error: Error) => {
      if (child === armChild) child = null;
      if (armChild.pid) {
        ownedGroups.delete(armChild.pid);
        closingChildren.delete(armChild.pid);
      }
      const stoppedByExtension = intentionalStops.has(armChild);
      intentionalStops.delete(armChild);
      if (stoppedByExtension) return;
      try {
        await sendWake(`watcher: FAILED - Pi extension arm child ${id} failed: ${error.message}`);
      } catch {
        // Fail open.
      }
    });
    return { ok: true, message: `watcher: started Pi extension arm child ${id}` };
  }

  pi.on?.("session_start", () => {
    markLoaded();
  });
  pi.on?.("session_shutdown", () => {
    stopArm();
    process.off("exit", cleanupOnProcessExit);
  });

  pi.registerCommand?.("fm-watch-arm-pi", {
    description: "Arm firstmate watcher supervision through the Pi extension instead of foreground bash.",
    handler: async (_args, ctx) => {
      const result = startArm();
      ctx.ui.notify(result.message, result.ok ? "info" : "warning");
    },
  });

  pi.registerTool?.({
    name: "fm_watch_arm_pi",
    label: "Arm firstmate watcher",
    description: "Arm Pi watcher supervision. Always use this tool instead of running bin/fm-watch-arm.sh through bash.",
    promptSnippet: "Arm firstmate watcher supervision through Pi without a foreground bash arm.",
    promptGuidelines: [
      "For Pi watcher supervision, call fm_watch_arm_pi instead of running bin/fm-watch-arm.sh through bash.",
    ],
    parameters: Type.Object({}),
    execute: async () => {
      const result = startArm();
      return {
        content: [{ type: "text", text: result.message }],
        details: result,
      };
    },
  });

  markLoaded();
}
