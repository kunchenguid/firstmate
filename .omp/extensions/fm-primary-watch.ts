// Firstmate primary watcher bridge for OMP. The extension owns one attached arm
// child per live session generation, restores a successor before delivering an
// actionable wake, and ignores every callback from a replaced generation.
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

interface OmpContext {
  sessionManager?: { getSessionFile?: () => string | undefined };
  ui?: { notify?: (message: string, level: "info" | "warning") => void };
}

interface OmpApi {
  on?: (event: string, handler: (...args: unknown[]) => unknown) => void;
  sendUserMessage: (content: string, options: { deliverAs: "followUp" }) => Promise<void> | void;
  registerCommand?: (name: string, command: {
    description: string;
    handler: (_args: unknown, context: OmpContext) => Promise<void>;
  }) => void;
  registerTool?: (tool: {
    name: string;
    label: string;
    description: string;
    parameters: unknown;
    execute: (
      toolCallId?: string,
      params?: unknown,
      signal?: AbortSignal,
      onUpdate?: unknown,
      context?: OmpContext,
    ) => Promise<{ content: Array<{ type: "text"; text: string }>; details: ArmResult }>;
  }) => void;
  zod?: { object: (shape: Record<string, unknown>) => unknown };
}

type LockOwnership = "owned" | "missing" | "other";
type CloseClassification = { kind: "actionable" | "failure"; message: string };
type ArmResult = { ok: boolean; message: string };
type PendingActionable = { classification: CloseClassification; predecessorPid: string };
type Generation = {
  id: number;
  sessionFile: string | null;
  stopping: boolean;
  child: ChildProcess | null;
  children: Set<ChildProcess>;
  retryTimer: NodeJS.Timeout | null;
  retryFailures: number;
  restoring: boolean;
  pendingActionable: PendingActionable[];
  sequence: number;
  stopPromise: Promise<void> | null;
};
const allArmChildren = new Set<ChildProcess>();

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const armScript = `${fmRoot}/bin/fm-watch-arm.sh`;
const marker = `${state}/.omp-watch-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;
const retryBaseMs = positiveInteger("FM_WATCH_REARM_RETRY_BASE_MS", 250);
const retryMaxMs = positiveInteger("FM_WATCH_REARM_RETRY_MAX_MS", 4000);
const retryLimit = positiveInteger("FM_WATCH_REARM_RETRY_LIMIT", 5);
const armReadyTimeoutMs = positiveInteger("FM_OMP_ARM_READY_TIMEOUT_MS", 12000);
const armRetireTimeoutMs = positiveInteger("FM_WATCH_ARM_RETIRE_TIMEOUT_MS", 1000);
const armReadiness = new WeakMap<ChildProcess, Promise<boolean>>();
const armClosed = new WeakMap<ChildProcess, Promise<void>>();
const armRecovery = new WeakMap<ChildProcess, { generation: string; watcherPid: string }>();
const armProcessGroups = new WeakMap<ChildProcess, number>();
let nextGenerationId = 0;
let activeGeneration: Generation | null = null;

function positiveInteger(name: string, fallback: number): number {
  const value = Number(process.env[name]);
  return Number.isFinite(value) && value > 0 ? Math.floor(value) : fallback;
}

function parentPid(pid: string): string {
  const result = spawnSync("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" });
  return result.status === 0 ? result.stdout.trim() : "";
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
  writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
}

function encodeWake(message: string): string {
  const body = `FIRSTMATE WATCHER WAKE: ${message}\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.`;
  const result = spawnSync(`${fmRoot}/bin/fm-operational-input.sh`, ["encode", "watcher"], {
    input: body,
    encoding: "utf8",
  });
  return result.status === 0 && result.stdout.trim() ? result.stdout.trim() : body;
}

function createGeneration(sessionFile: string | null = null): Generation {
  return {
    id: ++nextGenerationId,
    sessionFile,
    stopping: false,
    child: null,
    children: new Set(),
    retryTimer: null,
    retryFailures: 0,
    restoring: false,
    pendingActionable: [],
    sequence: 0,
    stopPromise: null,
  };
}

function generationIsLive(generation: Generation): boolean {
  return activeGeneration === generation && !generation.stopping;
}

function signalArm(child: ChildProcess, signal: NodeJS.Signals): void {
  const processGroupId = armProcessGroups.get(child);
  if (process.platform !== "win32" && processGroupId) {
    try {
      process.kill(-processGroupId, signal);
      return;
    } catch {
    }
  }
  try {
    child.kill(signal);
  } catch {
  }
}

function armProcessGroupAlive(child: ChildProcess): boolean {
  const processGroupId = armProcessGroups.get(child);
  if (process.platform === "win32" || !processGroupId) return child.exitCode === null;
  try {
    process.kill(-processGroupId, 0);
    return true;
  } catch {
    return false;
  }
}

function waitForArmProcessGroupExit(child: ChildProcess, timeoutMs: number): Promise<boolean> {
  return new Promise((resolveWait) => {
    const startedAt = Date.now();
    const poll = (): void => {
      if (!armProcessGroupAlive(child)) {
        resolveWait(true);
        return;
      }
      if (Date.now() - startedAt >= timeoutMs) {
        resolveWait(false);
        return;
      }
      setTimeout(poll, 10);
    };
    poll();
  });
}
function waitForArmClose(child: ChildProcess, timeoutMs: number): Promise<boolean> {
  const closed = armClosed.get(child);
  if (!closed) return Promise.resolve(child.exitCode !== null);
  return new Promise((resolveWait) => {
    const timer = setTimeout(() => resolveWait(false), timeoutMs);
    void closed.then(() => {
      clearTimeout(timer);
      resolveWait(true);
    });
  });
}


function stopGeneration(generation: Generation): Promise<void> {
  if (generation.stopPromise) return generation.stopPromise;
  generation.stopping = true;
  clearTimeout(generation.retryTimer ?? undefined);
  generation.retryTimer = null;
  const children = [...generation.children];
  generation.child = null;
  generation.stopPromise = Promise.all(children.map((child) => retireArm(child))).then(() => undefined);
  return generation.stopPromise;
}

function signalAllArmChildren(signal: NodeJS.Signals): void {
  for (const child of allArmChildren) signalArm(child, signal);
}

function stopAllArmChildren(): Promise<void> {
  return Promise.all([...allArmChildren].map((child) => retireArm(child))).then(() => undefined);
}

function contextSessionFile(context: unknown): string | null {
  const manager = (context as OmpContext | undefined)?.sessionManager;
  if (!manager || typeof manager.getSessionFile !== "function") return null;
  try {
    const file = manager.getSessionFile();
    return typeof file === "string" && file.length > 0 ? file : "<memory>";
  } catch {
    return null;
  }
}

function contextOwnsGeneration(owner: Generation, context: unknown): boolean {
  const file = contextSessionFile(context);
  return lockOwnership() === "owned"
    && generationIsLive(owner)
    && file !== null
    && file === owner.sessionFile;
}

function classifyClose(stdout: string, stderr: string, code: number | null, signal: NodeJS.Signals | null): CloseClassification {
  const combined = `${stdout}\n${stderr}`.trim();
  const actionable = combined.split(/\r?\n/).find((line) => /^(signal:|stale:|check:|heartbeat($|:))/.test(line));
  if (actionable) return { kind: "actionable", message: actionable };
  const detail = combined.split(/\r?\n/).find((line) => /^watcher: FAILED/.test(line));
  if (detail) return { kind: "failure", message: detail };
  if (signal) return { kind: "failure", message: `watcher: FAILED - OMP extension arm child ended from ${signal}${combined ? `\n${combined}` : ""}` };
  if (code && code !== 0) return { kind: "failure", message: `watcher: FAILED - fm-watch-arm.sh exited ${code}${combined ? `\n${combined}` : ""}` };
  return { kind: "failure", message: "watcher: FAILED - OMP extension arm cycle ended without an actionable reason" };
}

function retryDelay(attempt: number): number {
  return Math.min(retryMaxMs, retryBaseMs * 2 ** Math.max(0, attempt - 1));
}

async function waitForReadiness(child: ChildProcess): Promise<boolean> {
  const readiness = armReadiness.get(child);
  if (!readiness) return false;
  const gate = Promise.withResolvers<boolean>();
  const timer = setTimeout(() => gate.resolve(false), armReadyTimeoutMs);
  timer.unref();
  void readiness.then((ready) => {
    clearTimeout(timer);
    gate.resolve(ready);
  });
  return gate.promise;
}

async function retireArm(child: ChildProcess | null): Promise<boolean> {
  if (!child) return true;
  signalArm(child, "SIGTERM");
  let exited = await waitForArmProcessGroupExit(child, armRetireTimeoutMs);
  if (!exited) {
    signalArm(child, "SIGKILL");
    exited = await waitForArmProcessGroupExit(child, armRetireTimeoutMs);
  }
  const closed = await waitForArmClose(child, armRetireTimeoutMs);
  return exited && closed;
}

function confirmHandlingDelivery(recovery: { generation: string; watcherPid: string }): boolean {
  const result = spawnSync(
    "bash",
    [armScript, "--handling-delivered", recovery.generation, "--watcher-pid", recovery.watcherPid],
    {
      cwd: fmRoot,
      encoding: "utf8",
      env: { ...process.env, FM_HOME: fmHome, FM_STATE_OVERRIDE: state, FM_ROOT_OVERRIDE: fmRoot },
    },
  );
  return result.status === 0;
}

export default function (omp: OmpApi) {
  let generation = createGeneration();
  activeGeneration = generation;

  async function deliverWake(owner: Generation, message: string): Promise<void> {
    if (!generationIsLive(owner)) return;
    try {
      await omp.sendUserMessage(encodeWake(message), { deliverAs: "followUp" });
    } catch (error) {
      console.error(`Firstmate OMP watcher could not deliver wake: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  function scheduleRetry(owner: Generation, message: string, predecessorPid: string): void {
    if (!generationIsLive(owner) || owner.child || owner.retryTimer) return;
    if (lockOwnership() !== "owned") {
      void deliverWake(owner, `watcher: FAILED - OMP extension no longer owns the session lock\n${message}`);
      return;
    }
    owner.retryFailures += 1;
    if (owner.retryFailures > retryLimit) {
      void deliverWake(owner, `watcher: FAILED - OMP extension could not restore continuity after ${retryLimit} retries\n${message}`);
      return;
    }
    const timer = setTimeout(() => {
      if (owner.retryTimer === timer) owner.retryTimer = null;
      if (!generationIsLive(owner)) return;
      const result = startArm(owner, predecessorPid);
      if (!result.ok) void deliverWake(owner, `${result.message}\n${message}`);
    }, retryDelay(owner.retryFailures));
    timer.unref();
    owner.retryTimer = timer;
  }

  function restoreAfterActionableClose(
    owner: Generation,
    classification: CloseClassification,
    predecessorPid: string,
  ): void {
    if (!generationIsLive(owner)) return;
    if (owner.restoring) {
      owner.pendingActionable.push({ classification, predecessorPid });
      return;
    }
    owner.restoring = true;
    void (async () => {
      try {
        let failure = "";
        let recovery: { generation: string; watcherPid: string } | undefined;
        for (let attempt = 0; attempt <= retryLimit; attempt += 1) {
          if (!generationIsLive(owner)) return;
          const replacement = startArm(owner, predecessorPid);
          const successor = owner.child;
          if (replacement.ok && successor && await waitForReadiness(successor)) {
            recovery = armRecovery.get(successor);
            break;
          }
          failure = replacement.message;
          if (successor && !(await retireArm(successor))) break;
          if (attempt < retryLimit) {
            const delay = Promise.withResolvers<void>();
            const timer = setTimeout(delay.resolve, retryDelay(attempt + 1));
            timer.unref();
            await delay.promise;
          }
        }
        if (!generationIsLive(owner)) return;
        if (!recovery) failure = `${failure}\nwatcher: FAILED - OMP extension could not restore watcher continuity`;
        if (recovery && !confirmHandlingDelivery(recovery)) {
          failure = "watcher: FAILED - handling delivery confirmation was rejected";
        }
        await deliverWake(owner, failure ? `${classification.message}\n\n${failure}` : classification.message);
      } finally {
        if (!generationIsLive(owner)) return;
        owner.restoring = false;
        const pending = owner.pendingActionable.shift();
        if (pending) restoreAfterActionableClose(owner, pending.classification, pending.predecessorPid);
      }
    })();
  }

  function startArm(owner: Generation, predecessorPid = ""): ArmResult {
    if (!generationIsLive(owner)) return { ok: false, message: "watcher: not armed - OMP session is shutting down" };
    const ownership = lockOwnership();
    if (ownership === "other") return { ok: false, message: "watcher: read-only - session lock is held by another firstmate session" };
    if (ownership === "missing") {
      return { ok: false, message: "watcher: not armed - no live session holds the lock; run bin/fm-session-start.sh, then call fm_watch_arm_omp" };
    }
    markLoaded();
    if (owner.child) return { ok: true, message: "watcher: unchanged - OMP extension already owns an arm child" };
    if (owner.retryTimer) return { ok: true, message: "watcher: unchanged - OMP extension already owns a continuity retry" };

    const child = spawn(
      "bash",
      ["-c", "config_dir=\"${FM_CONFIG_OVERRIDE:-$FM_HOME/config}\"; [ -f \"$config_dir/x-mode.env\" ] && . \"$config_dir/x-mode.env\"; exec \"$FM_WATCH_ARM_SCRIPT\" --restart"],
      {
        cwd: fmRoot,
        detached: process.platform !== "win32",
        env: {
          ...process.env,
          FM_HOME: fmHome,
          FM_ROOT_OVERRIDE: fmRoot,
          FM_CONFIG_OVERRIDE: config,
          FM_WATCH_ARM_SCRIPT: armScript,
          FM_WATCH_PREDECESSOR_ARM_PID: predecessorPid,
        },
        stdio: ["ignore", "pipe", "pipe"],
      },
    );
    if (child.pid && process.platform !== "win32") armProcessGroups.set(child, child.pid);
    owner.children.add(child);
    allArmChildren.add(child);
    owner.child = child;
    owner.sequence += 1;
    let stdout = "";
    let stderr = "";
    let settled = false;
    const readyGate = Promise.withResolvers<boolean>();
    const closeGate = Promise.withResolvers<void>();
    armReadiness.set(child, readyGate.promise);
    armClosed.set(child, closeGate.promise);

    const observeReadiness = (): void => {
      const combined = `${stdout}\n${stderr}`;
      const recovery = combined.match(/^watcher: started pid=([0-9]+).* recovery-generation=([A-Za-z0-9._-]+)$/m);
      if (recovery) armRecovery.set(child, { watcherPid: recovery[1], generation: recovery[2] });
      if (/^watcher: (?:started|attached)\b/m.test(combined)) readyGate.resolve(true);
    };
    child.stdout?.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
      observeReadiness();
    });
    child.stderr?.on("data", (chunk: Buffer) => {
      stderr += chunk.toString();
      observeReadiness();
    });
    child.on("close", (code, signal) => {
      if (settled) return;
      settled = true;
      closeGate.resolve();
      readyGate.resolve(false);
      owner.children.delete(child);
      allArmChildren.delete(child);
      if (owner.child === child) owner.child = null;
      if (!generationIsLive(owner)) return;
      const classification = classifyClose(stdout, stderr, code, signal);
      const predecessor = String(child.pid ?? "");
      if (classification.kind !== "actionable") {
        scheduleRetry(owner, classification.message, predecessor);
        return;
      }
      restoreAfterActionableClose(owner, classification, predecessor);
    });
    child.on("error", (error) => {
      if (settled) return;
      settled = true;
      closeGate.resolve();
      readyGate.resolve(false);
      owner.children.delete(child);
      allArmChildren.delete(child);
      if (owner.child === child) owner.child = null;
      scheduleRetry(owner, `watcher: FAILED - OMP extension arm child failed: ${error.message}`, String(child.pid ?? ""));
    });
    return { ok: true, message: `watcher: started OMP extension arm child ${owner.sequence}; future re-arms are automatic` };
  }

  async function replaceSessionGeneration(context: unknown): Promise<void> {
    const sessionFile = contextSessionFile(context);
    const previous = generation;
    const shouldRearm = Boolean(previous.child || previous.retryTimer || previous.restoring);
    const predecessorPid = String(previous.child?.pid ?? "");
    const replacement = createGeneration(sessionFile);
    generation = replacement;
    activeGeneration = replacement;
    await stopGeneration(previous);
    if (!generationIsLive(replacement)) return;
    markLoaded();
    if (shouldRearm && sessionFile !== null) startArm(replacement, predecessorPid);
  }

  omp.on?.("session_start", (_event: unknown, context: unknown) => replaceSessionGeneration(context));
  omp.on?.("session_switch", (_event: unknown, context: unknown) => replaceSessionGeneration(context));
  omp.on?.("session_shutdown", async () => {
    const retiring = generation;
    activeGeneration = null;
    await stopGeneration(retiring);
    await stopAllArmChildren();
  });

  omp.registerCommand?.("fm-watch-arm-omp", {
    description: "Arm firstmate watcher supervision through the OMP extension.",
    handler: async (_args, context) => {
      const result = contextOwnsGeneration(generation, context)
        ? startArm(generation)
        : { ok: false, message: "watcher: not armed - OMP command does not belong to the active session generation" };
      context.ui?.notify?.(result.message, result.ok ? "info" : "warning");
    },
  });

  const parameters = omp.zod?.object({}) ?? {};
  omp.registerTool?.({
    name: "fm_watch_arm_omp",
    label: "Arm firstmate watcher",
    description: "Start the first OMP watcher cycle, or repair a cycle explicitly reported missing, failed, or unhealthy. Ordinary re-arming is automatic.",
    parameters,
    execute: async (_toolCallId, _params, _signal, _onUpdate, context) => {
      const result = contextOwnsGeneration(generation, context)
        ? startArm(generation)
        : { ok: false, message: "watcher: not armed - OMP tool call does not belong to the active session generation" };
      return { content: [{ type: "text", text: result.message }], details: result };
    },
  });

  markLoaded();
  process.once("exit", () => signalAllArmChildren("SIGTERM"));
}
