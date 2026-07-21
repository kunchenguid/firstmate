// Firstmate primary watcher bridge for Pi.
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

type ArmResult = {
  ok: boolean;
  message: string;
};

type LockOwnership = "owned" | "missing" | "other";

type CloseClassification = {
  kind: "actionable" | "failure";
  message: string;
};

type SessionReplacementReason = "reload" | "new" | "resume" | "fork";

type ActiveRestoration = {
  generation: number;
  token: number;
};

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const armScript = `${fmRoot}/bin/fm-watch-arm.sh`;
const marker = `${state}/.pi-watch-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;
const retryBaseMs = positiveInteger("FM_WATCH_REARM_RETRY_BASE_MS", 250);
const retryMaxMs = positiveInteger("FM_WATCH_REARM_RETRY_MAX_MS", 4000);
const retryLimit = positiveInteger("FM_WATCH_REARM_RETRY_LIMIT", 5);
const armReadyTimeoutMs = positiveInteger("FM_PI_ARM_READY_TIMEOUT_MS", 12000);
const armRetireTimeoutMs = positiveInteger("FM_WATCH_ARM_RETIRE_TIMEOUT_MS", 1000);

let child: ChildProcess | null = null;
let retryTimer: ReturnType<typeof setTimeout> | null = null;
let retryFailures = 0;
let stopping = false;
let seq = 0;
let sessionGeneration = 0;
let pendingSessionStart: SessionReplacementReason | null = null;
let restorationSequence = 0;
let activeRestoration: ActiveRestoration | null = null;
const armReadiness = new WeakMap<ChildProcess, Promise<boolean>>();
const armClose = new WeakMap<ChildProcess, Promise<void>>();

function positiveInteger(name: string, fallback: number): number {
  const value = Number(process.env[name]);
  if (!Number.isFinite(value) || value <= 0) return fallback;
  return Math.floor(value);
}

function sessionReplacementReason(reason: unknown): SessionReplacementReason | null {
  if (reason === "reload" || reason === "new" || reason === "resume" || reason === "fork") return reason;
  return null;
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

function classifyClose(stdout: string, stderr: string, code: number | null, signal: NodeJS.Signals | null): CloseClassification {
  const combined = `${stdout}\n${stderr}`.trim();
  const reason = actionableLine(combined);
  if (reason) return { kind: "actionable", message: reason };
  const healthy = combined.split(/\r?\n/).find((line) => /^watcher: healthy\b/.test(line));
  if (healthy) {
    return {
      kind: "failure",
      message: `watcher: FAILED - Pi extension arm child found an external healthy watcher instead of owning wake delivery\n${healthy}`,
    };
  }
  const failed = combined.split(/\r?\n/).find((line) => /^watcher: FAILED/.test(line));
  if (failed) return { kind: "failure", message: failed };
  if (signal) {
    return {
      kind: "failure",
      message: `watcher: FAILED - Pi extension arm child ended from ${signal}${combined ? `\n${combined}` : ""}`,
    };
  }
  if (code && code !== 0) {
    return {
      kind: "failure",
      message: `watcher: FAILED - fm-watch-arm.sh exited ${code}${combined ? `\n${combined}` : ""}`,
    };
  }
  return {
    kind: "failure",
    message: "watcher: FAILED - Pi extension arm cycle ended without an actionable reason",
  };
}

export default function (pi: ExtensionAPI) {
  function sessionIsActive(generation: number): boolean {
    return !stopping && generation === sessionGeneration;
  }

  function stopArm(): void {
    if (!stopping) sessionGeneration += 1;
    stopping = true;
    activeRestoration = null;
    if (retryTimer) clearTimeout(retryTimer);
    retryTimer = null;
    if (child) child.kill("SIGTERM");
    child = null;
  }

  let processExitCleanupRegistered = false;
  const cleanupOnProcessExit = () => {
    pendingSessionStart = null;
    stopArm();
  };
  const installProcessExitCleanup = (): void => {
    if (processExitCleanupRegistered) return;
    process.once("exit", cleanupOnProcessExit);
    processExitCleanupRegistered = true;
  };
  const removeProcessExitCleanup = (): void => {
    if (!processExitCleanupRegistered) return;
    process.off("exit", cleanupOnProcessExit);
    processExitCleanupRegistered = false;
  };
  installProcessExitCleanup();

  async function sendWake(message: string, generation: number): Promise<void> {
    if (!sessionIsActive(generation)) return;
    await pi.sendUserMessage(
      `FIRSTMATE WATCHER WAKE: ${message}\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.`,
      { deliverAs: "followUp" },
    );
  }

  function surfaceFailure(message: string, generation: number): void {
    void sendWake(message, generation).catch(() => {
      // Pi owns delivery errors; continuity restoration never waits on prompting.
    });
  }

  function retryDelay(attempt: number): number {
    return Math.min(retryMaxMs, retryBaseMs * 2 ** Math.max(0, attempt - 1));
  }

  function waitForRetry(attempt: number): Promise<void> {
    return new Promise((resolveRetry) => {
      const timer = setTimeout(resolveRetry, retryDelay(attempt));
      timer.unref();
    });
  }

  function waitForReadiness(armChild: ChildProcess): Promise<boolean> {
    const readiness = armReadiness.get(armChild);
    if (!readiness) return Promise.resolve(false);
    return new Promise((resolveReady) => {
      const timer = setTimeout(() => resolveReady(false), armReadyTimeoutMs);
      timer.unref();
      void readiness.then((ready) => {
        clearTimeout(timer);
        resolveReady(ready);
      });
    });
  }

  async function retireArm(armChild: ChildProcess | null): Promise<boolean> {
    if (!armChild) return true;
    armChild.kill("SIGTERM");
    const closed = armClose.get(armChild);
    if (!closed) return false;
    return new Promise((resolveRetired) => {
      const timer = setTimeout(() => resolveRetired(false), armRetireTimeoutMs);
      timer.unref();
      void closed.then(() => {
        clearTimeout(timer);
        resolveRetired(true);
      });
    });
  }

  async function restoreAfterActionableClose(predecessorArmPid: string, generation: number): Promise<string> {
    let failure = "";
    for (let attempt = 0; attempt <= retryLimit; attempt += 1) {
      if (!sessionIsActive(generation)) return "";
      const replacement = startArm(predecessorArmPid);
      const successorChild = child;
      if (replacement.ok && successorChild && await waitForReadiness(successorChild)) return "";
      if (replacement.ok) {
        failure = "watcher: FAILED - Pi extension could not verify a ready successor watcher";
        if (!(await retireArm(successorChild))) {
          return `${failure}\nwatcher: FAILED - Pi extension could not restore watcher continuity because the unready successor arm did not exit within ${armRetireTimeoutMs}ms`;
        }
      } else {
        failure = /(?:read-only|no live session)/.test(replacement.message)
          ? `watcher: FAILED - Pi extension cannot restore continuity because this session no longer owns the lock\n${replacement.message}`
          : `watcher: FAILED - Pi extension could not start the successor watcher cycle\n${replacement.message}`;
        if (/(?:read-only|no live session)/.test(replacement.message)) break;
      }
      if (attempt === retryLimit) break;
      await waitForRetry(attempt + 1);
    }
    return `${failure}\nwatcher: FAILED - Pi extension could not restore watcher continuity after ${retryLimit} retries`;
  }

  function scheduleRetry(message: string, predecessorArmPid: string, generation: number): void {
    if (!sessionIsActive(generation) || child || retryTimer) return;
    const ownership = lockOwnership();
    if (ownership !== "owned") {
      surfaceFailure(`watcher: FAILED - Pi extension cannot restore continuity because this session no longer owns the lock\n${message}`, generation);
      return;
    }
    retryFailures += 1;
    if (retryFailures > retryLimit) {
      surfaceFailure(`watcher: FAILED - Pi extension could not restore watcher continuity after ${retryLimit} retries\n${message}`, generation);
      return;
    }
    const timer = setTimeout(() => {
      if (retryTimer === timer) retryTimer = null;
      if (!sessionIsActive(generation)) return;
      const result = startArm(predecessorArmPid);
      if (!result.ok) {
        surfaceFailure(`watcher: FAILED - Pi extension could not launch a continuity retry\n${result.message}`, generation);
      }
    }, retryDelay(retryFailures));
    timer.unref();
    retryTimer = timer;
  }

  function startArm(predecessorArmPid = ""): ArmResult {
    if (stopping) return { ok: false, message: "watcher: not armed - Pi session is shutting down" };
    const ownership = lockOwnership();
    if (ownership === "other") return { ok: false, message: "watcher: read-only - session lock is held by another firstmate session" };
    if (ownership === "missing") {
      return {
        ok: false,
        message: "watcher: not armed - no live session holds the lock; run bin/fm-session-start.sh to reclaim it, then call fm_watch_arm_pi to re-arm",
      };
    }
    markLoaded();
    if (child) return { ok: true, message: "watcher: healthy - Pi extension already has an arm child" };
    if (retryTimer) return { ok: true, message: "watcher: continuity retry already scheduled by the Pi extension" };
    const id = ++seq;
    const generation = sessionGeneration;
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
    let readinessSettled = false;
    let resolveReadiness: (ready: boolean) => void = () => {};
    let resolveClosed: () => void = () => {};
    const readiness = new Promise<boolean>((resolveReady) => {
      resolveReadiness = resolveReady;
    });
    armReadiness.set(armChild, readiness);
    const closed = new Promise<void>((resolveClosedChild) => {
      resolveClosed = resolveClosedChild;
    });
    armClose.set(armChild, closed);
    const settleReadiness = (ready: boolean): void => {
      if (readinessSettled) return;
      readinessSettled = true;
      resolveReadiness(ready);
    };
    const observeEstablishedArm = (): void => {
      if (/^watcher: (?:started|attached)\b/m.test(`${stdout}\n${stderr}`)) {
        settleReadiness(true);
      }
    };
    const releaseChild = (): void => {
      if (child === armChild) child = null;
    };
    armChild.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
      observeEstablishedArm();
    });
    armChild.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString();
      observeEstablishedArm();
    });
    armChild.on("close", (code: number | null, signal: NodeJS.Signals | null) => {
      if (settled) return;
      settled = true;
      resolveClosed();
      settleReadiness(false);
      releaseChild();
      if (!sessionIsActive(generation)) return;
      const classification = classifyClose(stdout, stderr, code, signal);
      const predecessor = String(armChild.pid ?? "");
      if (classification.kind === "actionable") {
        retryFailures = 0;
        const restoration: ActiveRestoration = { generation, token: ++restorationSequence };
        activeRestoration = restoration;
        void (async () => {
          try {
            const failure = await restoreAfterActionableClose(predecessor, generation);
            if (!sessionIsActive(generation)) return;
            const message = failure ? `${classification.message}\n\n${failure}` : classification.message;
            await sendWake(message, generation);
          } finally {
            if (activeRestoration?.token === restoration.token) activeRestoration = null;
          }
        })().catch(() => {
        });
        return;
      }
      if (activeRestoration?.generation === generation) return;
      scheduleRetry(classification.message, predecessor, generation);
    });
    armChild.on("error", (error: Error) => {
      if (settled) return;
      settled = true;
      resolveClosed();
      settleReadiness(false);
      releaseChild();
      if (!sessionIsActive(generation)) return;
      if (activeRestoration?.generation === generation) return;
      scheduleRetry(`watcher: FAILED - Pi extension arm child ${id} failed: ${error.message}`, String(armChild.pid ?? ""), generation);
    });
    return { ok: true, message: `watcher: started Pi extension arm child ${id}` };
  }

  pi.on?.("session_start", (event) => {
    const reason = sessionReplacementReason(event.reason);
    if (reason && pendingSessionStart === reason) {
      pendingSessionStart = null;
      stopping = false;
      retryFailures = 0;
      activeRestoration = null;
      installProcessExitCleanup();
    }
    markLoaded();
  });
  pi.on?.("session_shutdown", (event) => {
    pendingSessionStart = sessionReplacementReason(event.reason);
    stopArm();
    removeProcessExitCleanup();
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
