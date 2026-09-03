import { execFile, spawnSync, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const marker = `${state}/.omp-turnend-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;
const sessionStartLimit = 512 * 1024;
const sessionStartFallback =
  "Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.";
const sessionStartRetireTimeoutMs = 1000;

type LockOwnership = "owned" | "missing" | "other";
type SessionStartGeneration = {
  id: number;
  sessionFile: string;
  stopping: boolean;
  delivered: boolean;
  child: ChildProcess | null;
  processGroupId: number | null;
  childClosed: boolean;
  childClose: Promise<void> | null;
  stopPromise: Promise<void> | null;
  result: Promise<string>;
};
interface OmpContext {
  sessionManager?: { getSessionFile?: () => string | undefined };
}
interface OmpApi {
  on?: (event: string, handler: (...args: unknown[]) => unknown) => void;
}

let nextSessionStartId = 0;
let activeSessionStart: SessionStartGeneration | null = null;
let pendingSessionStartRetirement: Promise<void> = Promise.resolve();
const runningChildren = new Set<ChildProcess>();

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

function contextOwnsGeneration(generation: SessionStartGeneration | null, context: unknown): boolean {
  const sessionFile = contextSessionFile(context);
  return lockOwnership() === "owned"
    && generation !== null
    && sessionFile !== null
    && sessionFile === generation.sessionFile;
}

function trackChild(child: ChildProcess): void {
  runningChildren.add(child);
  child.once("close", () => runningChildren.delete(child));
  child.once("error", () => runningChildren.delete(child));
}

function stopRunningChildren(signal: NodeJS.Signals = "SIGTERM"): void {
  for (const child of runningChildren) {
    try {
      child.kill(signal);
    } catch {
    }
  }
}

function signalSessionStartGroup(generation: SessionStartGeneration, signal: NodeJS.Signals): void {
  if (process.platform !== "win32" && generation.processGroupId) {
    try {
      process.kill(-generation.processGroupId, signal);
      return;
    } catch {
    }
  }
  const child = generation.child;
  if (!child) return;
  try {
    child.kill(signal);
  } catch {
  }
}
function sessionStartGroupAlive(generation: SessionStartGeneration): boolean {
  if (process.platform === "win32" || !generation.processGroupId) {
    return Boolean(generation.child && !generation.childClosed);
  }
  try {
    process.kill(-generation.processGroupId, 0);
    return true;
  } catch {
    return false;
  }
}

function waitForSessionStartGroupExit(
  generation: SessionStartGeneration,
  timeoutMs: number,
): Promise<boolean> {
  return new Promise((resolveWait) => {
    const startedAt = Date.now();
    const poll = (): void => {
      if (!sessionStartGroupAlive(generation)) {
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

function waitForSessionStartClose(
  generation: SessionStartGeneration,
  timeoutMs: number,
): Promise<boolean> {
  if (generation.childClosed || !generation.childClose) return Promise.resolve(true);
  return new Promise((resolveWait) => {
    const timer = setTimeout(() => resolveWait(false), timeoutMs);
    void generation.childClose?.then(() => {
      clearTimeout(timer);
      resolveWait(true);
    });
  });
}

function stopSessionStartGeneration(generation: SessionStartGeneration): Promise<void> {
  if (generation.stopPromise) return generation.stopPromise;
  generation.stopping = true;
  generation.stopPromise = (async () => {
    if (!generation.child && !generation.processGroupId) {
      await generation.result;
      return;
    }
    signalSessionStartGroup(generation, "SIGTERM");
    if (!(await waitForSessionStartGroupExit(generation, sessionStartRetireTimeoutMs))) {
      signalSessionStartGroup(generation, "SIGKILL");
      await waitForSessionStartGroupExit(generation, sessionStartRetireTimeoutMs);
    }
    await waitForSessionStartClose(generation, sessionStartRetireTimeoutMs);
  })();
  return generation.stopPromise;
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

function encodeOperational(kind: "session-start" | "turn-end-guard", body: string): string {
  const result = spawnSync(`${root}/bin/fm-operational-input.sh`, ["encode", kind], {
    input: body,
    encoding: "utf8",
  });
  return result.status === 0 && result.stdout.trim() ? result.stdout.trim() : body;
}

function sessionSwitchSource(event: unknown): string {
  const reason = String((event as { reason?: unknown } | undefined)?.reason ?? "");
  if (reason === "new") return "clear";
  if (reason === "resume" || reason === "fork") return reason;
  return "startup";
}

function runSessionStart(generation: SessionStartGeneration, source: string): Promise<string> {
  const gate = Promise.withResolvers<string>();
  const child = execFile(
    `${root}/bin/fm-sessionstart-run.sh`,
    ["--source", source],
    {
      detached: process.platform !== "win32",
      maxBuffer: sessionStartLimit,
    },
    (error, stdout) => {
      if (generation.stopping) {
        gate.resolve("");
        return;
      }
      if (error) {
        console.error(`Firstmate OMP session-start extension failed: ${error.message}`);
        gate.resolve(sessionStartFallback);
        return;
      }
      gate.resolve(String(stdout || "").trim());
    },
  );
  generation.child = child;
  generation.processGroupId = process.platform === "win32" ? null : child.pid ?? null;
  generation.childClose = new Promise<void>((resolveClose) => {
    const markClosed = (): void => {
      if (generation.childClosed) return;
      generation.childClosed = true;
      if (generation.child === child) generation.child = null;
      resolveClose();
    };
    child.once("close", markClosed);
    child.once("error", markClosed);
  });
  trackChild(child);
  return gate.promise;
}

function runGuard(stopHookActive: boolean): Promise<{ code: number; stderr: string }> {
  const gate = Promise.withResolvers<{ code: number; stderr: string }>();
  const child = execFile(`${root}/bin/fm-turnend-guard.sh`, (error, _stdout, stderr) => {
    if (error && typeof error.code !== "number") {
      console.error(`Firstmate OMP turn-end guard failed closed: ${error.message}`);
      gate.resolve({ code: 2, stderr: "Firstmate OMP turn-end guard could not be executed." });
      return;
    }
    gate.resolve({ code: error && typeof error.code === "number" ? error.code : 0, stderr: String(stderr || "") });
  });
  trackChild(child);
  child.stdin?.end(JSON.stringify({ stop_hook_active: stopHookActive }));
  return gate.promise;
}

function runChecker(script: string, command: string): Promise<{ code: number; stderr: string }> {
  const gate = Promise.withResolvers<{ code: number; stderr: string }>();
  const child = execFile(`${root}/bin/${script}`, ["--command", command], (error, _stdout, stderr) => {
    if (error && typeof error.code !== "number") {
      console.error(`Firstmate OMP ${script} failed closed: ${error.message}`);
      gate.resolve({ code: 2, stderr: `Firstmate OMP ${script} could not be executed.` });
      return;
    }
    gate.resolve({ code: error && typeof error.code === "number" ? error.code : 0, stderr: String(stderr || "") });
  });
  trackChild(child);
  return gate.promise;
}

function bashToolCommand(event: unknown): string {
  if (!event || typeof event !== "object" || !(("type") in event) || event.type !== "tool_call") return "";
  if (!(("toolName") in event) || event.toolName !== "bash" || !(("input") in event)) return "";
  const input = event.input;
  if (!input || typeof input !== "object" || !(("command") in input)) return "";
  return typeof input.command === "string" ? input.command : "";
}

export default function (omp: OmpApi) {
  function beginSessionStart(source: string, context: unknown): void {
    markLoaded();
    const sessionFile = contextSessionFile(context);
    const previous = activeSessionStart;
    if (sessionFile === null) {
      activeSessionStart = null;
      if (previous) pendingSessionStartRetirement = stopSessionStartGeneration(previous);
      return;
    }
    const generation: SessionStartGeneration = {
      id: ++nextSessionStartId,
      sessionFile,
      stopping: false,
      delivered: false,
      child: null,
      processGroupId: null,
      childClosed: false,
      childClose: null,
      stopPromise: null,
      result: Promise.resolve(""),
    };
    activeSessionStart = generation;
    const predecessorRetired = previous
      ? stopSessionStartGeneration(previous)
      : pendingSessionStartRetirement;
    pendingSessionStartRetirement = predecessorRetired;
    generation.result = (async () => {
      await predecessorRetired;
      if (activeSessionStart !== generation || generation.stopping) return "";
      return runSessionStart(generation, source);
    })();
  }
  omp.on?.("session_start", (_event: unknown, context: unknown) => beginSessionStart("startup", context));
  omp.on?.("session_switch", (event: unknown, context: unknown) => beginSessionStart(sessionSwitchSource(event), context));
  omp.on?.("session_compact", (_event: unknown, context: unknown) => beginSessionStart("compact", context));

  omp.on?.("before_agent_start", async (_event: unknown, context: unknown) => {
    const generation = activeSessionStart;
    if (!generation || generation.delivered || !contextOwnsGeneration(generation, context)) return;
    const raw = await generation.result;
    if (activeSessionStart !== generation || generation.delivered || !raw || !contextOwnsGeneration(generation, context)) return;
    generation.delivered = true;
    return {
      message: {
        customType: "firstmate-sessionstart-nudge",
        content: encodeOperational("session-start", raw),
        display: false,
        details: { kind: "session-start", generation: generation.id },
      },
    };
  });

  omp.on?.("tool_call", async (event: unknown, context: unknown) => {
    if (!contextOwnsGeneration(activeSessionStart, context)) {
      return { block: true, reason: "Firstmate OMP guard rejected a tool event outside the active session generation." };
    }
    const command = bashToolCommand(event);
    if (!command) return {};
    const cdResult = await runChecker("fm-cd-pretool-check.sh", command);
    if (cdResult.code === 2) {
      return { block: true, reason: cdResult.stderr.trim() || "denied by the cd-guard PreToolUse seatbelt" };
    }
    const armResult = await runChecker("fm-arm-pretool-check.sh", command);
    if (armResult.code === 2) {
      return { block: true, reason: armResult.stderr.trim() || "denied by the watcher-arm PreToolUse seatbelt" };
    }
    return {};
  });

  omp.on?.("session_stop", async (event: unknown, context: unknown) => {
    if (!contextOwnsGeneration(activeSessionStart, context)) {
      return {
        decision: "block",
        reason: encodeOperational("turn-end-guard", "TURN WOULD END BLIND - the OMP stop event does not belong to the active session generation."),
      };
    }
    const stopHookActive = (event as { stop_hook_active?: unknown } | undefined)?.stop_hook_active === true;
    const result = await runGuard(stopHookActive);
    if (result.code !== 2) return;
    const reason = encodeOperational(
      "turn-end-guard",
      "TURN WOULD END BLIND - supervision is off. The watcher cycle is missing, failed, or unhealthy. " +
        "Follow the harness recovery instruction below before ending the turn.\n\n" + result.stderr,
    );
    return { decision: "block", reason };
  });

  omp.on?.("session_shutdown", async () => {
    const generation = activeSessionStart;
    activeSessionStart = null;
    const retired = generation
      ? stopSessionStartGeneration(generation)
      : pendingSessionStartRetirement;
    pendingSessionStartRetirement = retired;
    await retired;
    stopRunningChildren();
  });
  process.once("exit", () => {
    const generation = activeSessionStart;
    if (generation) signalSessionStartGroup(generation, "SIGTERM");
    stopRunningChildren();
  });

  markLoaded();
}
