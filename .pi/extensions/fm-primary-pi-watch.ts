// Firstmate primary watcher bridge for Pi.
// Actionable child output is receipt-bound to the home-local durable wake queue
// before successor restoration, then revalidated by fm-wake-actionable.sh at the
// last idle boundary before captain-visible delivery.
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
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

type PendingWake = {
  message: string;
  receipt?: string;
};

type ActionabilityResult = {
  receipt?: string;
  obsolete?: boolean;
  failure?: string;
};

type ValidationState = "current" | "obsolete" | "error";

type BatchActionabilityResult = {
  states?: ValidationState[];
  failure?: string;
};

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const armScript = `${fmRoot}/bin/fm-watch-arm.sh`;
const actionableScript = `${fmRoot}/bin/fm-wake-actionable.sh`;
const marker = `${state}/.pi-watch-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;
const retryBaseMs = positiveInteger("FM_WATCH_REARM_RETRY_BASE_MS", 250);
const retryMaxMs = positiveInteger("FM_WATCH_REARM_RETRY_MAX_MS", 4000);
const retryLimit = positiveInteger("FM_WATCH_REARM_RETRY_LIMIT", 5);
const armReadyTimeoutMs = positiveInteger("FM_PI_ARM_READY_TIMEOUT_MS", 12000);
const armRetireTimeoutMs = positiveInteger("FM_WATCH_ARM_RETIRE_TIMEOUT_MS", 1000);
const actionableTimeoutMs = positiveInteger("FM_WAKE_ACTIONABLE_TIMEOUT_MS", 3000);

let child: ChildProcess | null = null;
let retryTimer: ReturnType<typeof setTimeout> | null = null;
let retryFailures = 0;
let stopping = false;
let seq = 0;
let restoring = false;
let activeContext: ExtensionContext | null = null;
let deliveryStarting = false;
let flushingWakes = false;
const pendingWakes: PendingWake[] = [];
const armReadiness = new WeakMap<ChildProcess, Promise<boolean>>();
const armClose = new WeakMap<ChildProcess, Promise<void>>();

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
  function stopArm(): void {
    stopping = true;
    if (retryTimer) clearTimeout(retryTimer);
    retryTimer = null;
    if (child) child.kill("SIGTERM");
    child = null;
  }

  const cleanupOnProcessExit = () => {
    stopArm();
  };
  process.once("exit", cleanupOnProcessExit);

  function actionability(action: "capture" | "validate", value: string): ActionabilityResult {
    const result = spawnSync(actionableScript, [action, value], {
      encoding: "utf8",
      env: {
        ...process.env,
        FM_HOME: fmHome,
        FM_ROOT_OVERRIDE: fmRoot,
        FM_STATE_OVERRIDE: state,
      },
      timeout: actionableTimeoutMs,
      maxBuffer: 64 * 1024,
    });
    const receipt = result.stdout.trim();
    if (result.status === 0) {
      if (action === "capture" && receipt) return { receipt };
      if (action === "validate") return {};
    }
    if (result.status === 1) return { obsolete: true };
    const detail = result.error?.message || result.stderr.trim() || `validator exited ${String(result.status)}`;
    return {
      receipt: action === "capture" && receipt ? receipt : undefined,
      failure: `watcher: FAILED - Pi extension could not ${action} wake actionability within ${actionableTimeoutMs}ms\n${detail}`,
    };
  }

  function validateActionabilityBatch(receipts: string[]): BatchActionabilityResult {
    if (receipts.length === 0) return { states: [] };
    const result = spawnSync(actionableScript, ["validate-batch"], {
      encoding: "utf8",
      env: {
        ...process.env,
        FM_HOME: fmHome,
        FM_ROOT_OVERRIDE: fmRoot,
        FM_STATE_OVERRIDE: state,
      },
      input: `${receipts.join("\n")}\n`,
      timeout: actionableTimeoutMs,
      maxBuffer: 64 * 1024,
    });
    const states = result.stdout.trim().split(/\r?\n/).filter(Boolean);
    const complete = states.length === receipts.length
      && states.every((state): state is ValidationState => /^(?:current|obsolete|error)$/.test(state));
    if ((result.status === 0 || result.status === 2) && complete) {
      if (result.status === 0) return { states };
      return {
        states,
        failure: `watcher: FAILED - Pi extension could not validate all wake actionability within ${actionableTimeoutMs}ms\nvalidator reported indeterminate source state`,
      };
    }
    const detail = result.error?.message || result.stderr.trim() || `validator exited ${String(result.status)}`;
    return {
      failure: `watcher: FAILED - Pi extension could not validate wake actionability batch within ${actionableTimeoutMs}ms\n${detail}`,
    };
  }

  function flushPendingWakes(): void {
    if (stopping || flushingWakes || deliveryStarting || pendingWakes.length === 0) return;
    if (activeContext && typeof activeContext.isIdle === "function" && !activeContext.isIdle()) return;
    flushingWakes = true;
    const batch = pendingWakes.splice(0);
    const messages: string[] = [];
    const validation = validateActionabilityBatch(
      batch.flatMap((pending) => pending.receipt ? [pending.receipt] : []),
    );
    if (validation.failure) messages.push(validation.failure);
    let receiptIndex = 0;
    for (const pending of batch) {
      if (pending.receipt) {
        const state = validation.states?.[receiptIndex];
        receiptIndex += 1;
        if (state !== "current") continue;
      }
      if (!messages.includes(pending.message)) messages.push(pending.message);
    }
    flushingWakes = false;
    if (messages.length === 0) return;
    deliveryStarting = true;
    pi.sendUserMessage(
      `FIRSTMATE WATCHER WAKE: ${messages.join("\n\n---\n\n")}\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.`,
    );
    if (!activeContext || typeof activeContext.isIdle !== "function") deliveryStarting = false;
  }

  function enqueueWake(message: string, receipt?: string): void {
    if (pendingWakes.some((pending) => pending.message === message && pending.receipt === receipt)) return;
    pendingWakes.push({ message, receipt });
  }

  function queueWake(message: string, receipt?: string): void {
    enqueueWake(message, receipt);
    flushPendingWakes();
  }

  function surfaceFailure(message: string): void {
    queueWake(message);
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

  async function restoreAfterActionableClose(predecessorArmPid: string): Promise<string> {
    let failure = "";
    for (let attempt = 0; attempt <= retryLimit; attempt += 1) {
      if (stopping) return "";
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

  function scheduleRetry(message: string, predecessorArmPid: string): void {
    if (stopping || child || retryTimer) return;
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
      const result = startArm(predecessorArmPid);
      if (!result.ok) {
        surfaceFailure(`watcher: FAILED - Pi extension could not launch a continuity retry\n${result.message}`);
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
      if (stopping) return;
      const classification = classifyClose(stdout, stderr, code, signal);
      const predecessor = String(armChild.pid ?? "");
      if (classification.kind === "actionable") {
        retryFailures = 0;
        restoring = true;
        const captured = actionability("capture", classification.message);
        void (async () => {
          const failure = await restoreAfterActionableClose(predecessor);
          restoring = false;
          if (stopping) return;
          if (captured.failure) enqueueWake(captured.failure);
          if (failure) enqueueWake(failure);
          if (captured.receipt) enqueueWake(classification.message, captured.receipt);
          flushPendingWakes();
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
      settleReadiness(false);
      releaseChild();
      if (stopping) return;
      if (restoring) return;
      scheduleRetry(`watcher: FAILED - Pi extension arm child ${id} failed: ${error.message}`, String(armChild.pid ?? ""));
    });
    return { ok: true, message: `watcher: started Pi extension arm child ${id}` };
  }

  pi.on?.("session_start", (_event, ctx) => {
    activeContext = ctx;
    markLoaded();
  });
  pi.on?.("agent_start", (_event, ctx) => {
    activeContext = ctx;
    deliveryStarting = false;
  });
  pi.on?.("agent_settled", (_event, ctx) => {
    activeContext = ctx;
    deliveryStarting = false;
    flushPendingWakes();
  });
  pi.on?.("session_shutdown", () => {
    stopArm();
    activeContext = null;
    pendingWakes.length = 0;
    process.off("exit", cleanupOnProcessExit);
  });

  pi.registerCommand?.("fm-watch-arm-pi", {
    description: "Arm firstmate watcher supervision through the Pi extension instead of foreground bash.",
    handler: async (_args, ctx) => {
      activeContext = ctx;
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
    execute: async (_toolCallId, _params, _signal, _onUpdate, ctx) => {
      activeContext = ctx;
      const result = startArm();
      return {
        content: [{ type: "text", text: result.message }],
        details: result,
      };
    },
  });

  markLoaded();
}
