// Firstmate primary watcher bridge for omp (Oh My Pi).
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.ts";

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
const marker = `${state}/.omp-watch-extension-loaded`;
const deliveryFailureMarker = `${state}/.omp-watch-delivery-failed`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;
const retryLimit = positiveInteger("FM_WATCH_REARM_RETRY_LIMIT", 5);
const stableCycleMs = positiveInteger("FM_OMP_WATCH_STABLE_MS", 30000);

let child: ChildProcess | null = null;
let seq = 0;
let stopping = false;
let deliverySeq = 0;

function positiveInteger(name: string, fallback: number): number {
  const value = Number(process.env[name]);
  if (!Number.isFinite(value) || value <= 0) return fallback;
  return Math.floor(value);
}

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

function markLoaded(): void {
  if (lockOwnership() === "other") return;
  mkdirSync(state, { recursive: true });
  writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
}

function actionableLine(output: string): string {
  const lines = output.split(/\r?\n/);
  return lines.find((line) => /^(signal:|stale:|check:|heartbeat($|:))/.test(line)) || "";
}

function failureLine(stdout: string, stderr: string, code: number | null): string {
  const combined = `${stdout}\n${stderr}`.trim();
  const healthy = combined.split(/\r?\n/).find((line) => /^watcher: healthy\b/.test(line));
  if (healthy) return `watcher: FAILED - omp extension arm child found an external healthy watcher instead of owning wake delivery\n${healthy}`;
  const failed = combined.split(/\r?\n/).find((line) => /^watcher: FAILED/.test(line));
  if (failed) return failed;
  if (code && code !== 0) return `watcher: FAILED - fm-watch-arm.sh exited ${code}${combined ? `\n${combined}` : ""}`;
  return "";
}

export default function (pi: ExtensionAPI) {
  function stopArm(): void {
    stopping = true;
    child?.kill("SIGTERM");
    child = null;
  }

  const cleanupOnProcessExit = () => {
    stopArm();
  };
  process.once("exit", cleanupOnProcessExit);

  async function sendWake(message: string): Promise<void> {
    const deliveryId = ++deliverySeq;
    const content = encodeFirstmateOperationalInput(
      "watcher",
      `FIRSTMATE WATCHER WAKE: ${message}\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.`,
    );
    try {
      await pi.sendUserMessage(content, { deliverAs: "followUp" });
      if (deliveryId === deliverySeq) rmSync(deliveryFailureMarker, { force: true });
    } catch (error) {
      if (deliveryId === deliverySeq) {
        mkdirSync(state, { recursive: true });
        const detail = error instanceof Error ? error.message : String(error);
        writeFileSync(deliveryFailureMarker, `${message}\n\nwatcher: FAILED - omp wake delivery rejected: ${detail}\n`);
      }
      throw error;
    }
  }

  function startFailureSuccessor(message: string, predecessorArmPid: string, failureAttempt: number): string {
    if (failureAttempt >= retryLimit) {
      return `${message}\n\nwatcher: FAILED - omp extension could not restore watcher continuity after ${retryLimit} retries`;
    }
    const successor = startArm(predecessorArmPid, failureAttempt + 1);
    if (successor.ok) return message;
    return `${message}\n\nwatcher: FAILED - omp extension could not start a bounded successor watcher cycle\n${successor.message}`;
  }

  function startArm(predecessorArmPid = "", failureAttempt = 0): ArmResult {
    if (stopping) return { ok: false, message: "watcher: not armed - omp session is shutting down" };
    const ownership = lockOwnership();
    if (ownership === "other") return { ok: false, message: "watcher: read-only - session lock is held by another firstmate session" };
    if (ownership === "missing") {
      return {
        ok: false,
        message: "watcher: not armed - no live session holds the lock; run bin/fm-session-start.sh to reclaim it, then call fm_watch_arm_omp to re-arm",
      };
    }
    markLoaded();
    if (child) return { ok: true, message: "watcher: healthy - omp extension already has an arm child" };
    const id = ++seq;
    const env = {
      ...process.env,
      FM_HOME: fmHome,
      FM_ROOT_OVERRIDE: fmRoot,
      FM_CONFIG_OVERRIDE: config,
      FM_WATCH_ARM_SCRIPT: armScript,
      FM_WATCH_PREDECESSOR_ARM_PID: predecessorArmPid,
    };
    const armChild = spawn("bash", ["-lc", "config_dir=\"${FM_CONFIG_OVERRIDE:-$FM_HOME/config}\"; [ -f \"$config_dir/x-mode.env\" ] && . \"$config_dir/x-mode.env\"; exec \"$FM_WATCH_ARM_SCRIPT\" --restart"], {
      cwd: fmRoot,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    child = armChild;
    let stdout = "";
    let stderr = "";
    let settled = false;
    let readinessAt: bigint | null = null;
    const observeEstablishedArm = (): void => {
      if (readinessAt === null && /^watcher: (?:started|attached)\b/m.test(`${stdout}\n${stderr}`)) {
        readinessAt = process.hrtime.bigint();
      }
    };
    armChild.stdout?.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
      observeEstablishedArm();
    });
    armChild.stderr?.on("data", (chunk: Buffer) => {
      stderr += chunk.toString();
      observeEstablishedArm();
    });
    armChild.on("close", (code: number | null) => {
      if (settled) return;
      settled = true;
      if (child === armChild) child = null;
      if (stopping) return;
      const reason = actionableLine(`${stdout}\n${stderr}`);
      const failure = reason ? "" : failureLine(stdout, stderr, code);
      if (!reason && !failure) return;
      let message = reason || failure;
      if (reason) {
        const successor = startArm(String(armChild.pid ?? ""), 0);
        if (!successor.ok) {
          message += `\n\nwatcher: FAILED - omp extension could not start a successor watcher cycle\n${successor.message}`;
        }
      } else {
        const stable =
          readinessAt !== null && process.hrtime.bigint() - readinessAt >= BigInt(stableCycleMs) * 1_000_000n;
        message = startFailureSuccessor(message, String(armChild.pid ?? ""), stable ? 0 : failureAttempt);
      }
      void sendWake(message).catch(() => {});
    });
    armChild.on("error", (error: Error) => {
      if (settled) return;
      settled = true;
      if (child === armChild) child = null;
      if (stopping) return;
      const message = startFailureSuccessor(
        `watcher: FAILED - omp extension arm child ${id} failed: ${error.message}`,
        String(armChild.pid ?? ""),
        failureAttempt,
      );
      void sendWake(message).catch(() => {});
    });
    return { ok: true, message: `watcher: started omp extension arm child ${id}` };
  }

  pi.on?.("session_start", () => {
    markLoaded();
  });
  pi.on?.("session_shutdown", () => {
    stopArm();
    process.off("exit", cleanupOnProcessExit);
  });

  pi.registerCommand?.("fm-watch-arm-omp", {
    description: "Arm firstmate watcher supervision through the omp extension instead of foreground bash.",
    handler: async (_args, ctx) => {
      const result = startArm();
      ctx.ui.notify(result.message, result.ok ? "info" : "warning");
    },
  });

  pi.registerTool?.({
    name: "fm_watch_arm_omp",
    label: "Arm firstmate watcher",
    description: "Arm omp watcher supervision. Always use this tool instead of running bin/fm-watch-arm.sh through bash.",
    parameters: pi.zod.object({}),
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
