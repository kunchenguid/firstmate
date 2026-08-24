// Firstmate primary watcher bridge for omp.
// One active session generation owns the arm child and every retry callback.
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { encodeFirstmateOperationalInput } from "../../.pi/extensions/lib/fm-operational-input.ts";

type ArmResult = {
  ok: boolean;
  message: string;
};

type LockOwnership = "owned" | "missing" | "other";

type SessionGeneration = {
  id: number;
  stopping: boolean;
  child: ChildProcess | null;
  retryTimer: ReturnType<typeof setTimeout> | null;
  retryFailures: number;
  restoring: boolean;
  sequence: number;
};

type RecoveryBinding = {
  generation: string;
  watcherPid: string;
};

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || fmHome + "/state";
const config = process.env.FM_CONFIG_OVERRIDE || fmHome + "/config";
const armScript = fmRoot + "/bin/fm-watch-arm.sh";
const marker = state + "/.omp-watch-extension-loaded";
const extensionVersion = "sha256:" + createHash("sha256").update(readFileSync(extensionFile)).digest("hex");
const retryBaseMs = positiveInteger("FM_OMP_WATCH_REARM_RETRY_BASE_MS", 250);
const retryMaxMs = positiveInteger("FM_OMP_WATCH_REARM_RETRY_MAX_MS", 4000);
const retryLimit = positiveInteger("FM_OMP_WATCH_REARM_RETRY_LIMIT", 5);
const armReadyTimeoutMs = positiveInteger("FM_OMP_ARM_READY_TIMEOUT_MS", 12000);
const armRetireTimeoutMs = positiveInteger("FM_WATCH_ARM_RETIRE_TIMEOUT_MS", 1000);
const repairOnlyHint = "call fm_watch_arm_omp again only after a later notification says the cycle is missing, failed, or unhealthy";

let nextGenerationId = 0;
let activeGeneration: SessionGeneration | null = null;
const armReadiness = new WeakMap<ChildProcess, Promise<boolean>>();
const armClose = new WeakMap<ChildProcess, Promise<void>>();
const armRecovery = new WeakMap<ChildProcess, RecoveryBinding>();

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
    lockPid = readFileSync(state + "/.lock", "utf8").trim();
  } catch {
    return "missing";
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "other";
  let pid = String(process.pid);
  for (let i = 0; i < 16; i += 1) {
    if (pid === lockPid) return "owned";
    pid = parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return pidAlive(lockPid) ? "other" : "missing";
}

function markLoaded(): void {
  if (lockOwnership() === "other") return;
  mkdirSync(state, { recursive: true });
  writeFileSync(marker, extensionVersion + "\n" + process.pid + "\n");
}

function generationIsLive(generation: SessionGeneration): boolean {
  return activeGeneration === generation && !generation.stopping;
}

function createGeneration(): SessionGeneration {
  return {
    id: ++nextGenerationId,
    stopping: false,
    child: null,
    retryTimer: null,
    retryFailures: 0,
    restoring: false,
    sequence: 0,
  };
}

function stopGeneration(generation: SessionGeneration): void {
  generation.stopping = true;
  if (generation.retryTimer) clearTimeout(generation.retryTimer);
  generation.retryTimer = null;
  if (generation.child) generation.child.kill("SIGTERM");
  generation.child = null;
}

function actionableLine(output: string): string {
  return output
    .split(/\r?\n/)
    .find((line) => /^(signal:|stale:|check:|heartbeat($|:))/.test(line)) || "";
}

function classifyClose(
  stdout: string,
  stderr: string,
  code: number | null,
  signal: NodeJS.Signals | null,
): string {
  const combined = (stdout + "\n" + stderr).trim();
  const reason = actionableLine(combined);
  if (reason) return reason;
  const healthy = combined.split(/\r?\n/).find((line) => /^watcher: healthy\b/.test(line));
  if (healthy) {
    return "watcher: FAILED - omp extension arm child found an external healthy watcher instead of owning wake delivery\n" + healthy;
  }
  const failed = combined.split(/\r?\n/).find((line) => /^watcher: FAILED/.test(line));
  if (failed) return failed;
  if (signal) return "watcher: FAILED - omp extension arm child ended from " + signal + (combined ? "\n" + combined : "");
  if (code && code !== 0) return "watcher: FAILED - fm-watch-arm.sh exited " + code + (combined ? "\n" + combined : "");
  return "watcher: FAILED - omp extension arm cycle ended without an actionable reason";
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

function confirmHandlingDelivery(binding: RecoveryBinding): { ok: boolean; detail: string } {
  try {
    const result = spawnSync(
      "bash",
      [armScript, "--handling-delivered", binding.generation, "--watcher-pid", binding.watcherPid],
      {
        cwd: fmRoot,
        encoding: "utf8",
        env: { ...process.env, FM_HOME: fmHome, FM_STATE_OVERRIDE: state, FM_ROOT_OVERRIDE: fmRoot },
      },
    );
    if (result.status === 0) return { ok: true, detail: "" };
    const stderr = (result.stderr || "").trim();
    return {
      ok: false,
      detail: "watcher: FAILED - handling delivery confirmation was rejected (status=" +
        (result.status ?? "none") + ")" + (stderr ? "\n" + stderr : ""),
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return {
      ok: false,
      detail: "watcher: FAILED - handling delivery confirmation could not be executed\n" + message,
    };
  }
}

async function sendWake(api: ExtensionAPI, generation: SessionGeneration, message: string): Promise<void> {
  if (!generationIsLive(generation)) return;
  const content = encodeFirstmateOperationalInput(
    "watcher",
    "FIRSTMATE WATCHER WAKE: " + message +
      "\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.",
  );
  try {
    api.sendUserMessage(content, { deliverAs: "followUp" });
  } catch {
  }
}

function surfaceFailure(api: ExtensionAPI, generation: SessionGeneration, message: string): void {
  void sendWake(api, generation, message);
}

function startArm(api: ExtensionAPI, owner: SessionGeneration, predecessorArmPid = ""): ArmResult {
  if (!generationIsLive(owner)) return { ok: false, message: "watcher: not armed - omp session is shutting down" };
  const ownership = lockOwnership();
  if (ownership === "other") return { ok: false, message: "watcher: read-only - session lock is held by another firstmate session" };
  if (ownership === "missing") {
    return {
      ok: false,
      message: "watcher: not armed - no live session holds the lock; run bin/fm-session-start.sh to reclaim it, then call fm_watch_arm_omp to re-arm",
    };
  }
  markLoaded();
  if (owner.child) {
    return {
      ok: true,
      message: "watcher: unchanged - omp extension already owns an arm child; no manual re-arm needed; " + repairOnlyHint,
    };
  }
  if (owner.retryTimer) {
    return {
      ok: true,
      message: "watcher: unchanged - omp extension already owns a scheduled continuity retry; no manual re-arm needed; " + repairOnlyHint,
    };
  }
  const id = ++owner.sequence;
  const env = {
    ...process.env,
    FM_HOME: fmHome,
    FM_ROOT_OVERRIDE: fmRoot,
    FM_CONFIG_OVERRIDE: config,
    FM_WATCH_ARM_SCRIPT: armScript,
    FM_WATCH_PREDECESSOR_ARM_PID: predecessorArmPid,
  };
  const armChild = spawn(
    "bash",
    [
      "-lc",
      "config_dir=\"${FM_CONFIG_OVERRIDE:-$FM_HOME/config}\"; [ -f \"$config_dir/x-mode.env\" ] && . \"$config_dir/x-mode.env\"; exec \"$FM_WATCH_ARM_SCRIPT\" --restart",
    ],
    {
      cwd: fmRoot,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  owner.child = armChild;
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
    const combined = stdout + "\n" + stderr;
    const recovery = combined.match(/^watcher: started pid=([0-9]+).* recovery-generation=([A-Za-z0-9._-]+)$/m);
    if (recovery) armRecovery.set(armChild, { watcherPid: recovery[1], generation: recovery[2] });
    if (/^watcher: (?:started|attached)\b/m.test(combined)) settleReadiness(true);
  };
  const releaseChild = (): void => {
    if (owner.child === armChild) owner.child = null;
  };
  armChild.stdout?.on("data", (chunk: Buffer) => {
    stdout += chunk.toString();
    observeEstablishedArm();
  });
  armChild.stderr?.on("data", (chunk: Buffer) => {
    stderr += chunk.toString();
    observeEstablishedArm();
  });
  armChild.on("close", (code: number | null, signal: NodeJS.Signals | null) => {
    if (settled) return;
    settled = true;
    resolveClosed();
    settleReadiness(false);
    releaseChild();
    if (!generationIsLive(owner)) return;
    const message = classifyClose(stdout, stderr, code, signal);
    const predecessor = String(armChild.pid ?? "");
    if (actionableLine((stdout + "\n" + stderr).trim())) {
      if (owner.restoring) return;
      owner.retryFailures = 0;
      owner.restoring = true;
      void (async () => {
        try {
          let failure = "";
          let recovery: RecoveryBinding | undefined;
          for (let attempt = 0; attempt <= retryLimit; attempt += 1) {
            if (!generationIsLive(owner)) return;
            const replacement = startArm(api, owner, predecessor);
            const successor = owner.child;
            if (replacement.ok && successor && await waitForReadiness(successor)) {
              recovery = armRecovery.get(successor);
              failure = "";
              break;
            }
            failure = replacement.ok
              ? "watcher: FAILED - omp extension could not verify a ready successor watcher"
              : replacement.message;
            if (successor && !(await retireArm(successor))) {
              failure += "\nwatcher: FAILED - the unready successor arm did not exit within " + armRetireTimeoutMs + "ms";
              break;
            }
            if (attempt === retryLimit) break;
            await waitForRetry(attempt + 1);
          }
          if (!recovery && !failure) failure = "watcher: FAILED - omp extension could not restore watcher continuity after retries";
          if (recovery) {
            const confirmed = confirmHandlingDelivery(recovery);
            if (!confirmed.ok) failure = confirmed.detail;
          }
          await sendWake(api, owner, message + (failure ? "\n\n" + failure : ""));
        } catch (error) {
          const detail = error instanceof Error ? error.message : String(error);
          surfaceFailure(api, owner, "watcher: FAILED - omp extension could not deliver an actionable wake\n" + detail);
        } finally {
          if (generationIsLive(owner)) owner.restoring = false;
        }
      })();
      return;
    }
    if (owner.restoring) return;
    scheduleRetry(api, owner, message, predecessor);
  });
  armChild.on("error", (error: Error) => {
    if (settled) return;
    settled = true;
    resolveClosed();
    settleReadiness(false);
    releaseChild();
    if (!generationIsLive(owner) || owner.restoring) return;
    scheduleRetry(api, owner, "watcher: FAILED - omp extension arm child " + id + " failed: " + error.message, String(armChild.pid ?? ""));
  });
  return {
    ok: true,
    message: "watcher: started omp extension arm child " + id + "; future ordinary re-arms are automatic; " + repairOnlyHint,
  };
}

function scheduleRetry(api: ExtensionAPI, owner: SessionGeneration, message: string, predecessorArmPid: string): void {
  if (!generationIsLive(owner) || owner.child || owner.retryTimer) return;
  if (lockOwnership() !== "owned") {
    surfaceFailure(api, owner, "watcher: FAILED - omp extension cannot restore continuity because this session no longer owns the lock\n" + message);
    return;
  }
  owner.retryFailures += 1;
  if (owner.retryFailures > retryLimit) {
    surfaceFailure(api, owner, "watcher: FAILED - omp extension could not restore watcher continuity after " + retryLimit + " retries\n" + message);
    return;
  }
  const timer = setTimeout(() => {
    if (owner.retryTimer === timer) owner.retryTimer = null;
    if (!generationIsLive(owner)) return;
    const result = startArm(api, owner, predecessorArmPid);
    if (!result.ok) surfaceFailure(api, owner, "watcher: FAILED - omp extension could not launch a continuity retry\n" + result.message);
  }, retryDelay(owner.retryFailures));
  timer.unref();
  owner.retryTimer = timer;
}

function activateFreshGeneration(generation: SessionGeneration): SessionGeneration {
  if (!generation.stopping) stopGeneration(generation);
  const replacement = createGeneration();
  activeGeneration = replacement;
  return replacement;
}

export default function (api: ExtensionAPI) {
  let generation = createGeneration();
  activeGeneration = generation;

  api.on("session_start", () => {
    if (generation.stopping) generation = createGeneration();
    activeGeneration = generation;
    markLoaded();
  });
  api.on("session_switch", () => {
    generation = activateFreshGeneration(generation);
    markLoaded();
  });
  api.on("session_shutdown", () => {
    stopGeneration(generation);
  });

  api.registerTool({
    name: "fm_watch_arm_omp",
    label: "Arm firstmate watcher",
    description: "Start the first required omp watcher cycle or repair one only after a notification says the cycle is missing, failed, or unhealthy. Do not call after ordinary work or ordinary notifications; the omp extension re-arms automatically. Never run bin/fm-watch-arm.sh through bash.",
    promptSnippet: "Start the first required omp watcher cycle or repair a cycle reported missing, failed, or unhealthy; ordinary re-arming is automatic.",
    promptGuidelines: [
      "Call fm_watch_arm_omp only for the first required cycle or after a notification says the cycle is missing, failed, or unhealthy. Do not call it after ordinary work, turn completion, or ordinary signal, stale, check, or heartbeat handling because the omp extension owns re-arming. Never run bin/fm-watch-arm.sh through bash.",
    ],
    parameters: api.typebox.Type.Object({}),
    execute: async () => {
      const result = startArm(api, generation);
      return {
        content: [{ type: "text", text: result.message }],
        details: result,
      };
    },
  });

  process.once("exit", () => {
    stopGeneration(generation);
  });
  markLoaded();
}
