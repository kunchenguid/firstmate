// Firstmate primary watcher bridge for Pi.
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

type ArmResult = {
  ok: boolean;
  message: string;
};

type LockOwnership = "owned" | "missing" | "dead" | "other" | "malformed" | "unknown";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const armScript = `${fmRoot}/bin/fm-watch-arm.sh`;
const lockScript = `${fmRoot}/bin/fm-lock.sh`;
const scopeScript = `${fmRoot}/bin/fm-primary-scope.sh`;
const awayFlag = `${state}/.afk`;
const marker = `${state}/.pi-watch-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;

let child: any = null;
let armReady = false;
let armReadiness: Promise<ArmResult> | null = null;
let seq = 0;

function lockEnvironment() {
  return {
    ...process.env,
    FM_HOME: fmHome,
    FM_ROOT_OVERRIDE: fmRoot,
    FM_STATE_OVERRIDE: state,
  };
}

function lockOwnership(): LockOwnership {
  const result = spawnSync(lockScript, ["ownership"], { encoding: "utf8", env: lockEnvironment() });
  const ownership = String(result.stdout || "").trim();
  if (result.status !== 0) return "unknown";
  if (["owned", "missing", "dead", "other", "malformed", "unknown"].includes(ownership)) {
    return ownership as LockOwnership;
  }
  return "unknown";
}

function isPrimaryHome(): boolean {
  const result = spawnSync(scopeScript, [], {
    encoding: "utf8",
    env: {
      ...lockEnvironment(),
      FM_ROOT_OVERRIDE: root,
    },
  });
  return result.status === 0;
}

function markLoadedForPrimary(): void {
  const ownership = lockOwnership();
  if (ownership === "other" || ownership === "malformed" || ownership === "unknown") return;
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
  if (healthy) return `watcher: FAILED - Pi extension arm child found an external healthy watcher instead of owning wake delivery\n${healthy}`;
  const failed = combined.split(/\r?\n/).find((line) => /^watcher: FAILED/.test(line));
  if (failed) return failed;
  if (code && code !== 0) return `watcher: FAILED - fm-watch-arm.sh exited ${code}${combined ? `\n${combined}` : ""}`;
  return "";
}

export default function (pi: ExtensionAPI) {
  const primaryHome = isPrimaryHome();
  let awayMonitor: ReturnType<typeof setInterval> | null = null;
  let awayMonitorError = "";
  let awayMonitorRetry: ReturnType<typeof setTimeout> | null = null;
  let awayMonitorRetryDelayMs = 250;
  let awayObserved = existsSync(awayFlag);
  let sessionActive = false;
  let shuttingDown = false;
  const intentionalStops = new WeakSet<object>();

  function stopArm(): void {
    if (child) {
      intentionalStops.add(child);
      child.kill("SIGTERM");
    }
    child = null;
    armReady = false;
    armReadiness = null;
  }

  function readAwayFlag(): boolean {
    try {
      statSync(awayFlag);
      return true;
    } catch (error) {
      if (error && typeof error === "object" && "code" in error && error.code === "ENOENT") return false;
      throw error;
    }
  }

  async function reconcileAwayOwnership(): Promise<void> {
    const awayActive = readAwayFlag();
    if (awayActive) {
      awayObserved = true;
      stopArm();
      return;
    }
    if (!awayObserved) return;
    awayObserved = false;
    if (!sessionActive || shuttingDown || !awayMonitor) return;
    const result = await startArm();
    if (!result.ok) await sendWakeSafely(result.message);
  }

  const awayMonitorListener = () => {
    void reconcileAwayOwnership().catch((error) => {
      handleAwayMonitorFailure(error);
    });
  };

  function handleAwayMonitorFailure(error: unknown): void {
    awayMonitorError = error instanceof Error ? error.message : String(error);
    if (awayMonitor) {
      clearInterval(awayMonitor);
      awayMonitor = null;
    }
    stopArm();
    scheduleAwayMonitorRetry();
  }

  function scheduleAwayMonitorRetry(): void {
    if (awayMonitorRetry || shuttingDown) return;
    const delay = awayMonitorRetryDelayMs;
    awayMonitorRetryDelayMs = Math.min(awayMonitorRetryDelayMs * 2, 30000);
    awayMonitorRetry = setTimeout(() => {
      awayMonitorRetry = null;
      startAwayMonitor();
    }, delay);
    awayMonitorRetry.unref();
  }

  function startAwayMonitor(): boolean {
    if (awayMonitor) return true;
    if (!primaryHome) return false;
    let awayActive: boolean;
    try {
      awayActive = readAwayFlag();
      awayMonitor = setInterval(awayMonitorListener, 50);
      awayMonitor.unref();
    } catch (error) {
      handleAwayMonitorFailure(error);
      return false;
    }
    awayMonitorError = "";
    awayMonitorRetryDelayMs = 250;
    if (awayMonitorRetry) {
      clearTimeout(awayMonitorRetry);
      awayMonitorRetry = null;
    }
    awayObserved = awayActive;
    if (awayObserved) stopArm();
    markLoadedForPrimary();
    if (sessionActive && !awayObserved && !child) {
      void recoverArmAfterMonitor();
    }
    return true;
  }

  function stopAwayMonitor(): void {
    if (awayMonitor) clearInterval(awayMonitor);
    awayMonitor = null;
    if (awayMonitorRetry) {
      clearTimeout(awayMonitorRetry);
      awayMonitorRetry = null;
    }
    awayMonitorRetryDelayMs = 250;
  }

  const cleanupOnProcessExit = () => {
    shuttingDown = true;
    sessionActive = false;
    stopAwayMonitor();
    stopArm();
  };
  process.once("exit", cleanupOnProcessExit);

  async function sendWake(message: string) {
    if (!awayMonitor || existsSync(awayFlag)) return;
    await pi.sendUserMessage(
      `FIRSTMATE WATCHER WAKE: ${message}\n\nRun bin/fm-wake-drain.sh first, handle the queued wake, then resume Pi supervision.`,
      { deliverAs: "followUp" },
    );
  }

  async function sendWakeSafely(message: string): Promise<void> {
    try {
      await sendWake(message);
    } catch {
      return;
    }
  }

  async function recoverArmAfterMonitor(): Promise<void> {
    try {
      const result = await startArm();
      if (!result.ok) await sendWakeSafely(result.message);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      await sendWakeSafely(`watcher: FAILED - Pi arm recovery after monitor restart failed: ${message}`);
    }
  }

  async function startArm(): Promise<ArmResult> {
    if (!primaryHome) {
      return { ok: false, message: "watcher: inactive - current checkout is not a primary firstmate home" };
    }
    if (!awayMonitor) {
      const detail = awayMonitorError ? ` (${awayMonitorError})` : "";
      return { ok: false, message: `watcher: inactive - away-mode state monitor unavailable${detail}` };
    }
    let ownership = lockOwnership();
    let acquisitionError = "";
    let attemptedAcquisition = false;
    if (ownership === "missing" || ownership === "dead") {
      attemptedAcquisition = true;
      const acquisition = spawnSync(lockScript, [], { encoding: "utf8", env: lockEnvironment() });
      acquisitionError = String(acquisition.stderr || "").trim().split(/\r?\n/)[0] || "";
      ownership = lockOwnership();
    }
    if (ownership === "other") {
      const message = attemptedAcquisition
        ? "watcher: lock ownership changed during resume - a verified live firstmate session now owns this home"
        : "watcher: read-only - a verified live firstmate session owns this home";
      return { ok: false, message };
    }
    if (ownership !== "owned") {
      const detail = acquisitionError ? ` (${acquisitionError})` : "";
      return { ok: false, message: `watcher: lock acquisition failed - session lock is ${ownership}${detail}` };
    }
    markLoadedForPrimary();
    if (existsSync(awayFlag)) {
      return { ok: true, message: "watcher: away mode - sub-supervisor owns supervision" };
    }
    if (child) {
      if (armReady) return { ok: true, message: "watcher: healthy - Pi extension already has an arm child" };
      if (armReadiness) return armReadiness;
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
    });
    child = armChild;
    armReady = false;
    let stdout = "";
    let stderr = "";
    const readiness = new Promise<ArmResult>((resolveReadiness) => {
      let settled = false;
      const settle = (result: ArmResult) => {
        if (settled) return;
        settled = true;
        armReady = result.ok;
        resolveReadiness(result);
      };
      armChild.stdout.on("data", (chunk: Buffer) => {
        stdout += chunk.toString();
        if (stdout.split(/\r?\n/).some((line) => /^watcher: started\b/.test(line))) {
          settle({ ok: true, message: `watcher: started Pi extension arm child ${id}` });
        }
      });
      armChild.stderr.on("data", (chunk: Buffer) => {
        stderr += chunk.toString();
      });
      armChild.on("close", async (code: number | null) => {
        const intentionallyStopped = intentionalStops.has(armChild);
        if (child === armChild) {
          child = null;
          armReady = false;
          armReadiness = null;
        }
        const reason = actionableLine(`${stdout}\n${stderr}`);
        const failure = reason ? "" : failureLine(stdout, stderr, code);
        settle({
          ok: false,
          message: failure || `watcher: FAILED - Pi extension arm child ${id} exited before confirming watcher readiness`,
        });
        if (intentionallyStopped || (!reason && !failure)) return;
        await sendWakeSafely(reason || failure);
      });
      armChild.on("error", async (error: Error) => {
        if (child === armChild) {
          child = null;
          armReady = false;
          armReadiness = null;
        }
        const failure = `watcher: FAILED - Pi extension arm child ${id} failed: ${error.message}`;
        settle({ ok: false, message: failure });
        await sendWakeSafely(failure);
      });
    });
    armReadiness = readiness;
    return readiness;
  }

  pi.on?.("session_start", async (_event, ctx) => {
    if (!primaryHome) return;
    shuttingDown = false;
    sessionActive = true;
    startAwayMonitor();
    const result = await startArm();
    if (!result.ok) ctx?.ui?.notify?.(result.message, "warning");
  });
  pi.on?.("session_shutdown", () => {
    shuttingDown = true;
    sessionActive = false;
    stopAwayMonitor();
    stopArm();
    process.off("exit", cleanupOnProcessExit);
  });

  pi.registerCommand?.("fm-watch-arm-pi", {
    description: "Arm firstmate watcher supervision through the Pi extension instead of foreground bash.",
    handler: async (_args, ctx) => {
      const result = await startArm();
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
      const result = await startArm();
      return {
        content: [{ type: "text", text: result.message }],
        details: result,
      };
    },
  });

  startAwayMonitor();
}
