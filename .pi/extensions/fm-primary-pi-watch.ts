// Firstmate primary watcher bridge for Pi.
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
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
type SessionLockPolicy = "defer" | "recover" | "owned-only";

type CloseClassification = {
  kind: "actionable" | "failure";
  message: string;
};

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
let restoring = false;
const armReadiness = new WeakMap<ChildProcess, Promise<boolean>>();
const armStartResults = new WeakMap<ChildProcess, Promise<ArmResult>>();
const armClose = new WeakMap<ChildProcess, Promise<void>>();

function positiveInteger(name: string, fallback: number): number {
  const value = Number(process.env[name]);
  if (!Number.isFinite(value) || value <= 0) return fallback;
  return Math.floor(value);
}

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

function lockPolicyForSessionStart(reason: unknown): SessionLockPolicy | null {
  switch (String(reason ?? "")) {
    case "startup":
    case "new":
      return "defer";
    case "resume":
      return "recover";
    case "fork":
    case "reload":
      return "owned-only";
    default:
      return null;
  }
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
  const primaryHome = isPrimaryHome();
  let awayMonitor: ReturnType<typeof setInterval> | null = null;
  let awayMonitorError = "";
  let awayMonitorRetry: ReturnType<typeof setTimeout> | null = null;
  let awayMonitorRetryDelayMs = 250;
  let awayObserved = existsSync(awayFlag);
  let sessionActive = false;
  let activeSessionLockPolicy: SessionLockPolicy = "owned-only";
  let shuttingDown = false;
  const intentionalStops = new WeakSet<object>();

  function stopArm(): void {
    if (retryTimer) clearTimeout(retryTimer);
    retryTimer = null;
    if (child) {
      intentionalStops.add(child);
      child.kill("SIGTERM");
    }
    child = null;
    retryFailures = 0;
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
    const result = await startArm(activeSessionLockPolicy);
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
    stopping = true;
    shuttingDown = true;
    sessionActive = false;
    stopAwayMonitor();
    stopArm();
  };
  process.once("exit", cleanupOnProcessExit);

  async function sendWake(message: string): Promise<void> {
    if (!awayMonitor || existsSync(awayFlag)) return;
    await pi.sendUserMessage(
      `FIRSTMATE WATCHER WAKE: ${message}\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.`,
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
      const result = await startArm(activeSessionLockPolicy);
      if (!result.ok) await sendWakeSafely(result.message);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      await sendWakeSafely(`watcher: FAILED - Pi arm recovery after monitor restart failed: ${message}`);
    }
  }

  function surfaceFailure(message: string): void {
    void sendWakeSafely(message);
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

  function waitForStartResult(armChild: ChildProcess): Promise<ArmResult> {
    const startResult = armStartResults.get(armChild);
    if (!startResult) {
      return Promise.resolve({ ok: false, message: "watcher: FAILED - Pi extension arm child has no readiness result" });
    }
    return new Promise((resolveResult) => {
      const timer = setTimeout(() => {
        resolveResult({ ok: false, message: "watcher: FAILED - Pi extension arm child timed out before confirming watcher readiness" });
      }, armReadyTimeoutMs);
      timer.unref();
      void startResult.then((result) => {
        clearTimeout(timer);
        resolveResult(result);
      });
    });
  }

  async function retireArm(armChild: ChildProcess | null, intentional = false): Promise<boolean> {
    if (!armChild) return true;
    if (intentional) intentionalStops.add(armChild);
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

  function terminalOwnershipFailure(message: string): boolean {
    return /(?:read-only|lock ownership changed|lock acquisition failed|lock ownership unavailable)/.test(message);
  }

  async function restoreAfterActionableClose(predecessorArmPid: string): Promise<string> {
    let failure = "";
    for (let attempt = 0; attempt <= retryLimit; attempt += 1) {
      if (stopping || shuttingDown || existsSync(awayFlag)) return "";
      const replacement = launchArm(activeSessionLockPolicy, predecessorArmPid);
      const successorChild = child;
      if (replacement.ok && successorChild && await waitForReadiness(successorChild)) return "";
      if (replacement.ok) {
        failure = "watcher: FAILED - Pi extension could not verify a ready successor watcher";
        if (!(await retireArm(successorChild))) {
          return `${failure}\nwatcher: FAILED - Pi extension could not restore watcher continuity because the unready successor arm did not exit within ${armRetireTimeoutMs}ms`;
        }
      } else {
        failure = terminalOwnershipFailure(replacement.message)
          ? `watcher: FAILED - Pi extension cannot restore continuity because this session no longer owns the lock\n${replacement.message}`
          : `watcher: FAILED - Pi extension could not start the successor watcher cycle\n${replacement.message}`;
        if (terminalOwnershipFailure(replacement.message)) break;
      }
      if (attempt === retryLimit) break;
      await waitForRetry(attempt + 1);
    }
    return `${failure}\nwatcher: FAILED - Pi extension could not restore watcher continuity after ${retryLimit} retries`;
  }

  function scheduleRetry(message: string, predecessorArmPid: string): void {
    if (stopping || shuttingDown || child || retryTimer || !awayMonitor || existsSync(awayFlag)) return;
    const ownership = lockOwnership();
    if (ownership !== "owned") {
      surfaceFailure(`watcher: FAILED - Pi extension cannot restore continuity because this session no longer owns the lock\n${message}`);
      return;
    }
    retryFailures += 1;
    if (retryFailures > retryLimit) {
      surfaceFailure(`watcher: FAILED - Pi extension could not restore watcher continuity after ${retryLimit} retries\n${message}`);
      return;
    }
    const timer = setTimeout(() => {
      if (retryTimer === timer) retryTimer = null;
      const result = launchArm(activeSessionLockPolicy, predecessorArmPid);
      if (!result.ok) {
        surfaceFailure(`watcher: FAILED - Pi extension could not launch a continuity retry\n${result.message}`);
      }
    }, retryDelay(retryFailures));
    timer.unref();
    retryTimer = timer;
  }

  function launchArm(lockPolicy: SessionLockPolicy, predecessorArmPid = ""): ArmResult {
    if (!primaryHome) {
      return { ok: false, message: "watcher: inactive - current checkout is not a primary firstmate home" };
    }
    if (stopping || shuttingDown) {
      return { ok: false, message: "watcher: not armed - Pi session is shutting down" };
    }
    if (!awayMonitor) {
      const detail = awayMonitorError ? ` (${awayMonitorError})` : "";
      return { ok: false, message: `watcher: inactive - away-mode state monitor unavailable${detail}` };
    }
    let ownership = lockOwnership();
    let acquisitionError = "";
    let attemptedAcquisition = false;
    if (ownership === "missing" || ownership === "dead") {
      if (lockPolicy === "defer") {
        return { ok: true, message: "watcher: pending - session start must acquire the lock before arming" };
      }
      if (lockPolicy === "owned-only") {
        return { ok: false, message: `watcher: read-only - existing session-lock ownership required (state: ${ownership})` };
      }
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
      const failure = lockPolicy === "recover" ? "lock acquisition failed" : "lock ownership unavailable";
      return { ok: false, message: `watcher: ${failure} - session lock is ${ownership}${detail}` };
    }
    markLoadedForPrimary();
    if (existsSync(awayFlag)) {
      return { ok: true, message: "watcher: away mode - sub-supervisor owns supervision" };
    }
    if (child) {
      return { ok: true, message: "watcher: healthy - Pi extension already has an arm child" };
    }
    if (retryTimer) return { ok: false, message: "watcher: not armed - continuity retry already scheduled by the Pi extension" };
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
    let readinessSettled = false;
    let startResultSettled = false;
    let resolveReadiness: (ready: boolean) => void = () => {};
    let resolveStartResult: (result: ArmResult) => void = () => {};
    let resolveClosed: () => void = () => {};
    const readiness = new Promise<boolean>((resolveReady) => {
      resolveReadiness = resolveReady;
    });
    armReadiness.set(armChild, readiness);
    const startResult = new Promise<ArmResult>((resolveResult) => {
      resolveStartResult = resolveResult;
    });
    armStartResults.set(armChild, startResult);
    const closed = new Promise<void>((resolveClosedChild) => {
      resolveClosed = resolveClosedChild;
    });
    armClose.set(armChild, closed);
    const settleReadiness = (ready: boolean): void => {
      if (readinessSettled) return;
      readinessSettled = true;
      resolveReadiness(ready);
    };
    const settleStartResult = (result: ArmResult): void => {
      if (startResultSettled) return;
      startResultSettled = true;
      resolveStartResult(result);
    };
    const observeEstablishedArm = (): void => {
      if (/^watcher: (?:started|attached)\b/m.test(`${stdout}\n${stderr}`)) {
        settleReadiness(true);
        settleStartResult({ ok: true, message: `watcher: started Pi extension arm child ${id}` });
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
      const classification = classifyClose(stdout, stderr, code, signal);
      settleReadiness(false);
      settleStartResult({ ok: false, message: classification.message });
      releaseChild();
      if (stopping || shuttingDown || intentionalStops.has(armChild) || existsSync(awayFlag)) return;
      const predecessor = String(armChild.pid ?? "");
      if (classification.kind === "actionable") {
        retryFailures = 0;
        restoring = true;
        void (async () => {
          const failure = await restoreAfterActionableClose(predecessor);
          restoring = false;
          if (stopping || shuttingDown || existsSync(awayFlag)) return;
          const message = failure ? `${classification.message}\n\n${failure}` : classification.message;
          await sendWakeSafely(message);
        })().catch(() => {
        });
        return;
      }
      if (restoring) return;
      scheduleRetry(classification.message, predecessor);
    });
    armChild.on("error", (error: Error) => {
      if (settled) return;
      settled = true;
      resolveClosed();
      const failure = `watcher: FAILED - Pi extension arm child ${id} failed: ${error.message}`;
      settleReadiness(false);
      settleStartResult({ ok: false, message: failure });
      releaseChild();
      if (stopping || shuttingDown || intentionalStops.has(armChild) || existsSync(awayFlag)) return;
      if (restoring) return;
      scheduleRetry(failure, String(armChild.pid ?? ""));
    });
    return { ok: true, message: `watcher: started Pi extension arm child ${id}` };
  }

  async function startArm(lockPolicy: SessionLockPolicy, predecessorArmPid = ""): Promise<ArmResult> {
    const result = launchArm(lockPolicy, predecessorArmPid);
    if (!result.ok) return result;
    const armChild = child;
    if (!armChild) return result;
    const verified = await waitForStartResult(armChild);
    if (verified.ok) return result;
    if (child === armChild) await retireArm(armChild, true);
    return verified;
  }

  pi.on?.("session_start", async (event, ctx) => {
    if (!primaryHome) return;
    const reason = String((event as { reason?: unknown }).reason ?? "");
    const lockPolicy = lockPolicyForSessionStart(reason);
    if (!lockPolicy) {
      sessionActive = false;
      activeSessionLockPolicy = "owned-only";
      stopArm();
      ctx?.ui?.notify?.(`watcher: inactive - unsupported Pi session_start reason: ${reason || "<missing>"}`, "warning");
      return;
    }
    stopping = false;
    shuttingDown = false;
    sessionActive = true;
    activeSessionLockPolicy = lockPolicy;
    startAwayMonitor();
    const result = await startArm(activeSessionLockPolicy);
    if (!result.ok) ctx?.ui?.notify?.(result.message, "warning");
  });
  pi.on?.("session_shutdown", () => {
    stopping = true;
    shuttingDown = true;
    sessionActive = false;
    activeSessionLockPolicy = "owned-only";
    stopAwayMonitor();
    stopArm();
    process.off("exit", cleanupOnProcessExit);
  });

  pi.registerCommand?.("fm-watch-arm-pi", {
    description: "Arm firstmate watcher supervision through the Pi extension instead of foreground bash.",
    handler: async (_args, ctx) => {
      const result = await startArm(activeSessionLockPolicy);
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
      const result = await startArm(activeSessionLockPolicy);
      return {
        content: [{ type: "text", text: result.message }],
        details: result,
      };
    },
  });

  startAwayMonitor();
}
