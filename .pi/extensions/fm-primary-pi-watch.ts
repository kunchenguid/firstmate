// Firstmate primary watcher bridge for Pi.
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

type ArmResult = {
  ok: boolean;
  message: string;
};

type LockOwnership = "owned" | "missing" | "other";
type WakeKind = "actionable" | "failure";
type WatcherStatus = "offline" | "watching" | "handling wake" | "attention";
type StatusUi = { setStatus(key: string, text: string | undefined): void };

type WakeDetails = {
  generation: number;
  kind: WakeKind;
  reason: string;
  exitCode: number | null;
  signal: NodeJS.Signals | null;
  truncated: boolean;
  stdoutTruncated: boolean;
  stderrTruncated: boolean;
};

type WakeSender = (message: string, details: WakeDetails) => Promise<void>;

type StatusClient = WakeSender & {
  token: symbol;
  ui: StatusUi | null;
  active: boolean;
  sendWake: WakeSender;
  rearm: () => Promise<ArmResult>;
};

type PendingWake = {
  message: string;
  details: WakeDetails;
};

type ArmRecord = {
  child: ChildProcess;
  cadence: string;
  generation: number;
  intentionalStopReason: string;
  settled: boolean;
  stdout: string;
  stderr: string;
  stdoutPending: string;
  stderrPending: string;
  stdoutTruncated: boolean;
  stderrTruncated: boolean;
  actionable: string;
  failureHint: string;
};

type ArmCoordinator = {
  current: ArmRecord | null;
  generation: number;
  sequence: number;
  visibleStatus: WatcherStatus;
  startPromise: Promise<ArmResult> | null;
  startCancelled: boolean;
  shuttingDown: boolean;
  shutdownPromise: Promise<void> | null;
  shutdownToken: symbol | null;
  clients: Map<symbol, StatusClient>;
  pendingWake: PendingWake | null;
  exitListener?: () => void;
};

type CoordinatorHost = typeof globalThis & {
  __firstmatePiWatchCoordinators?: Map<string, ArmCoordinator>;
};

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = realpathSync(resolve(extensionDir, "../.."));
const fmHome = resolve(process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root);
const fmRoot = resolve(process.env.FM_ROOT_OVERRIDE || root);
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const armScript = `${fmRoot}/bin/fm-watch-arm.sh`;
const lockScript = `${fmRoot}/bin/fm-lock.sh`;
const marker = `${state}/.pi-watch-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;
const MAX_CAPTURE_BYTES = 16 * 1024;
const MAX_PENDING_LINE_BYTES = 4 * 1024;
const FIRSTMATE_PI_WATCHER_STATUS_KEY = "firstmate-pi-watcher" as const;
const WATCHER_STATUS_TEXT: Record<WatcherStatus, WatcherStatus> = {
  offline: "offline",
  watching: "watching",
  "handling wake": "handling wake",
  attention: "attention",
};
const requestedStopGrace = Number(process.env.FM_PI_WATCH_STOP_GRACE_MS ?? "1000");
const STOP_GRACE_MS = Number.isFinite(requestedStopGrace) && requestedStopGrace >= 0 ? requestedStopGrace : 1000;
const STOP_KILL_GRACE_MS = 500;
const AWAY_SUSPENSION_LINE = "watcher: suspended - away mode owns supervision";
const coordinatorHost = globalThis as CoordinatorHost;
const coordinators = coordinatorHost.__firstmatePiWatchCoordinators ??= new Map<string, ArmCoordinator>();

function supervisingHome(): boolean {
  if (existsSync(`${root}/.fm-secondmate-home`)) return true;
  if (!existsSync(`${root}/AGENTS.md`) || !existsSync(`${root}/bin`)) return false;
  if (process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE) {
    try {
      if (realpathSync(fmHome) === root) return true;
    } catch {}
  }
  const gitDir = spawnSync("git", ["-C", root, "rev-parse", "--git-dir"], { encoding: "utf8" });
  const commonDir = spawnSync("git", ["-C", root, "rev-parse", "--git-common-dir"], { encoding: "utf8" });
  if (gitDir.status !== 0 || commonDir.status !== 0) return false;
  return gitDir.stdout.trim() === commonDir.stdout.trim();
}

function coordinatorForHome(): ArmCoordinator {
  const existing = coordinators.get(fmHome);
  if (existing) {
    existing.visibleStatus ??= "offline";
    if (existing.clients.size === 0) existing.visibleStatus = "offline";
    existing.shutdownPromise ??= null;
    existing.shutdownToken ??= null;
    if (!existing.shutdownPromise) {
      existing.shuttingDown = false;
      existing.startCancelled = false;
    }
    return existing;
  }
  const coordinator: ArmCoordinator = {
    current: null,
    generation: 0,
    sequence: 0,
    visibleStatus: "offline",
    startPromise: null,
    startCancelled: false,
    shuttingDown: false,
    shutdownPromise: null,
    shutdownToken: null,
    clients: new Map<symbol, StatusClient>(),
    pendingWake: null,
  };
  coordinators.set(fmHome, coordinator);
  return coordinator;
}

function writeClientStatus(client: StatusClient, status: WatcherStatus | undefined): void {
  if (!client.active || !client.ui) return;
  client.ui.setStatus(
    FIRSTMATE_PI_WATCHER_STATUS_KEY,
    status === undefined ? undefined : WATCHER_STATUS_TEXT[status],
  );
}

function publishStatus(coordinator: ArmCoordinator, status: WatcherStatus): void {
  if (coordinator.shuttingDown) return;
  coordinator.visibleStatus = status;
  for (const client of coordinator.clients.values()) writeClientStatus(client, status);
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

function claimSessionLock(): Promise<void> {
  return new Promise((resolvePromise) => {
    const child = spawn(lockScript, [], {
      cwd: fmRoot,
      env: {
        ...process.env,
        FM_HOME: fmHome,
        FM_ROOT_OVERRIDE: fmRoot,
        FM_STATE_OVERRIDE: state,
      },
      stdio: "ignore",
    });
    let settled = false;
    const settle = () => {
      if (settled) return;
      settled = true;
      resolvePromise();
    };
    child.on("error", settle);
    child.on("close", settle);
  });
}

function canonicalLockIsStale(): boolean {
  const result = spawnSync(lockScript, ["status"], {
    cwd: fmRoot,
    env: {
      ...process.env,
      FM_HOME: fmHome,
      FM_ROOT_OVERRIDE: fmRoot,
      FM_STATE_OVERRIDE: state,
    },
    encoding: "utf8",
  });
  return result.status === 0 && /^lock: stale\b/.test(result.stdout.trim());
}

function markLoaded(): void {
  if (lockOwnership() === "other" && !canonicalLockIsStale()) return;
  mkdirSync(state, { recursive: true });
  writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
}

function cadenceFingerprint(): string {
  let interval = process.env.FM_CHECK_INTERVAL || "300";
  try {
    const contents = readFileSync(`${config}/x-mode.env`, "utf8");
    for (const line of contents.split(/\r?\n/)) {
      const match = line.match(/^\s*(?:export\s+)?FM_CHECK_INTERVAL\s*=\s*(?:"([0-9]+)"|'([0-9]+)'|([0-9]+))\s*(?:#.*)?$/);
      if (match) interval = match[1] || match[2] || match[3];
    }
  } catch {}
  return `FM_CHECK_INTERVAL=${interval}`;
}

function actionableLine(line: string): string {
  return /^(signal:|stale:|check:|heartbeat($|:))/.test(line) ? line : "";
}

function appendBoundedTail(current: string, text: string): { value: string; truncated: boolean } {
  const combined = Buffer.from(current + text);
  if (combined.byteLength <= MAX_CAPTURE_BYTES) return { value: combined.toString(), truncated: false };
  return {
    value: combined.subarray(combined.byteLength - MAX_CAPTURE_BYTES).toString(),
    truncated: true,
  };
}

function inspectOutputLine(record: ArmRecord, line: string): void {
  const lineBuffer = Buffer.from(line);
  const boundedLine = lineBuffer.byteLength > MAX_PENDING_LINE_BYTES
    ? lineBuffer.subarray(0, MAX_PENDING_LINE_BYTES).toString()
    : line;
  if (!record.actionable) record.actionable = actionableLine(boundedLine);
  if (!record.failureHint && (/^watcher: healthy\b/.test(boundedLine) || /^watcher: FAILED/.test(boundedLine))) {
    record.failureHint = boundedLine;
  }
  if (boundedLine === AWAY_SUSPENSION_LINE && !record.intentionalStopReason) {
    record.intentionalStopReason = "away-mode";
  }
}

function clientOwnsGeneration(
  coordinator: ArmCoordinator,
  client: StatusClient,
  generation: number,
): boolean {
  return coordinator.generation === generation
    && !coordinator.shuttingDown
    && client.active
    && coordinator.clients.get(client.token) === client;
}

function captureOutput(record: ArmRecord, stream: "stdout" | "stderr", chunk: Buffer): void {
  const text = chunk.toString();
  const tail = appendBoundedTail(record[stream], text);
  record[stream] = tail.value;
  const truncatedKey = stream === "stdout" ? "stdoutTruncated" : "stderrTruncated";
  record[truncatedKey] ||= tail.truncated;

  const pendingKey = stream === "stdout" ? "stdoutPending" : "stderrPending";
  const lines = `${record[pendingKey]}${text}`.split(/\r?\n/);
  record[pendingKey] = lines.pop() ?? "";
  for (const line of lines) inspectOutputLine(record, line);
  if (Buffer.byteLength(record[pendingKey]) > MAX_PENDING_LINE_BYTES) {
    inspectOutputLine(record, record[pendingKey]);
    record[pendingKey] = Buffer.from(record[pendingKey]).subarray(0, MAX_PENDING_LINE_BYTES).toString();
    record[truncatedKey] = true;
  }
}

function failureLine(record: ArmRecord, code: number | null, signal: NodeJS.Signals | null): string {
  const combined = `${record.stdout}\n${record.stderr}`.trim();
  if (/^watcher: healthy\b/.test(record.failureHint)) {
    return `watcher: FAILED - Pi extension arm child found an external healthy watcher instead of owning wake delivery\n${record.failureHint}`;
  }
  if (/^watcher: FAILED/.test(record.failureHint)) return record.failureHint;
  if (signal) return `watcher: FAILED - fm-watch-arm.sh terminated by ${signal}${combined ? `\n${combined}` : ""}`;
  if (code !== null && code !== 0) return `watcher: FAILED - fm-watch-arm.sh exited ${code}${combined ? `\n${combined}` : ""}`;
  return `watcher: FAILED - fm-watch-arm.sh exited unexpectedly with code ${code ?? "unknown"}${combined ? `\n${combined}` : ""}`;
}

function settleArm(
  coordinator: ArmCoordinator,
  record: ArmRecord,
  code: number | null,
  signal: NodeJS.Signals | null,
  error?: Error,
): void {
  if (record.settled) return;
  record.settled = true;
  inspectOutputLine(record, record.stdoutPending);
  inspectOutputLine(record, record.stderrPending);
  const ownsGeneration = coordinator.current === record && coordinator.generation === record.generation;
  if (ownsGeneration) {
    coordinator.current = null;
  }
  const message = error
    ? `watcher: FAILED - Pi extension arm child ${record.generation} failed: ${error.message}`
    : record.actionable || failureLine(record, code, signal);
  const kind: WakeKind = record.actionable && !error ? "actionable" : "failure";
  const details: WakeDetails = {
    generation: record.generation,
    kind,
    reason: message,
    exitCode: code,
    signal,
    truncated: record.stdoutTruncated || record.stderrTruncated,
    stdoutTruncated: record.stdoutTruncated,
    stderrTruncated: record.stderrTruncated,
  };
  const awayModeActive = existsSync(`${state}/.afk`);
  const shouldDefer = kind === "actionable"
    ? awayModeActive || Boolean(record.intentionalStopReason)
    : awayModeActive && !record.intentionalStopReason;
  if (shouldDefer) {
    coordinator.pendingWake = { message, details };
    return;
  }
  if (ownsGeneration && record.intentionalStopReason === "away-mode") {
    publishStatus(coordinator, "offline");
  }
  if (!ownsGeneration || coordinator.shuttingDown || record.intentionalStopReason) return;
  if (kind === "failure") publishStatus(coordinator, "attention");
  const activeClient = [...coordinator.clients.values()].reverse().find((candidate) => candidate.active);
  if (!activeClient) return;
  void (async () => {
    try {
      await activeClient.sendWake(message, details);
    } catch {
      if (!clientOwnsGeneration(coordinator, activeClient, record.generation)) return;
      coordinator.pendingWake = { message, details };
      publishStatus(coordinator, "attention");
      if (kind === "actionable") {
        void activeClient.rearm().catch(() => undefined);
      }
      return;
    }
    if (kind !== "actionable" || !clientOwnsGeneration(coordinator, activeClient, record.generation)) return;
    publishStatus(coordinator, "handling wake");
    void activeClient.rearm().catch(() => {
      if (clientOwnsGeneration(coordinator, activeClient, record.generation)) {
        publishStatus(coordinator, "attention");
      }
    });
  })();
}

function signalArm(record: ArmRecord, signal: NodeJS.Signals): void {
  const pid = record.child.pid;
  if (pid) {
    try {
      process.kill(-pid, signal);
      return;
    } catch {
      // Fall back to the direct child only when group signaling is unavailable.
    }
  }
  try {
    record.child.kill(signal);
  } catch {
    // The process may already be gone; settlement remains event-driven or bounded below.
  }
}

function processGroupAlive(record: ArmRecord): boolean {
  const pid = record.child.pid;
  if (!pid) return false;
  try {
    process.kill(-pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code !== "ESRCH";
  }
}

function stopsWithin(record: ArmRecord, milliseconds: number): Promise<boolean> {
  return new Promise<boolean>((resolvePromise) => {
    const deadline = Date.now() + milliseconds;
    const check = () => {
      if (record.settled && !processGroupAlive(record)) {
        resolvePromise(true);
        return;
      }
      const remaining = deadline - Date.now();
      if (remaining <= 0) {
        resolvePromise(false);
        return;
      }
      setTimeout(check, Math.min(10, remaining));
    };
    check();
  });
}

async function stopArmRecord(
  coordinator: ArmCoordinator,
  record: ArmRecord,
  reason: string,
): Promise<void> {
  try {
    if (!record.intentionalStopReason) record.intentionalStopReason = reason;
    signalArm(record, "SIGTERM");
    if (!(await stopsWithin(record, STOP_GRACE_MS))) {
      signalArm(record, "SIGKILL");
      if (!(await stopsWithin(record, STOP_KILL_GRACE_MS))) {
        if (!record.settled) settleArm(coordinator, record, null, "SIGKILL");
        if (processGroupAlive(record)) {
          throw new Error(`watcher: FAILED - process group ${record.child.pid} survived SIGKILL`);
        }
      }
    }
  } finally {
    if (coordinator.current === record) {
      coordinator.current = null;
    }
  }
}

function stopArmOnProcessExit(coordinator: ArmCoordinator): void {
  const record = coordinator.current;
  if (!record) return;
  if (!record.intentionalStopReason) record.intentionalStopReason = "process-exit";
  signalArm(record, "SIGTERM");
  signalArm(record, "SIGKILL");
}

function runChecker(script: string, command: string): Promise<{ code: number; stderr: string }> {
  return new Promise((resolveResult) => {
    const child = spawn(`${fmRoot}/bin/${script}`, ["--command", command], {
      stdio: ["ignore", "ignore", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolveResult({ code: 0, stderr: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stderr }));
  });
}

function runPretoolCheck(command: string): Promise<{ code: number; stderr: string }> {
  return runChecker("fm-arm-pretool-check.sh", command);
}

function runCdCheck(command: string): Promise<{ code: number; stderr: string }> {
  return runChecker("fm-cd-pretool-check.sh", command);
}

export default function (pi: ExtensionAPI) {
  if (!supervisingHome()) return;
  const coordinator = coordinatorForHome();

  async function sendWake(message: string, details: WakeDetails): Promise<void> {
    pi.sendMessage(
      {
        customType: "firstmate-watcher-wake",
        content: `FIRSTMATE WATCHER WAKE: ${message}\n\nRun bin/fm-wake-drain.sh first, handle the queued wake, then resume Pi supervision.`,
        display: true,
        details,
      },
      { deliverAs: "followUp", triggerTurn: true },
    );
  }

  const client: StatusClient = Object.assign(sendWake, {
    token: Symbol("pi-watch-extension-client"),
    ui: null as StatusUi | null,
    active: true,
    sendWake,
    rearm: startArm,
  });
  coordinator.clients.set(client.token, client);

  const cleanupOnProcessExit = () => {
    for (const activeClient of coordinator.clients.values()) {
      writeClientStatus(activeClient, undefined);
      activeClient.active = false;
    }
    coordinator.clients.clear();
    coordinator.shuttingDown = true;
    coordinator.startCancelled = true;
    coordinator.generation += 1;
    stopArmOnProcessExit(coordinator);
  };
  if (!coordinator.exitListener) {
    coordinator.exitListener = cleanupOnProcessExit;
    process.once("exit", cleanupOnProcessExit);
  }

  async function suspendForAwayMode(): Promise<ArmResult | null> {
    if (!existsSync(`${state}/.afk`)) return null;
    const record = coordinator.current;
    if (record) await stopArmRecord(coordinator, record, "away-mode");
    if (!existsSync(`${state}/.afk`)) return null;
    publishStatus(coordinator, "offline");
    return { ok: true, message: "watcher: suspended - away mode owns supervision" };
  }

  async function startArmOnce(): Promise<ArmResult> {
    const initialSuspension = await suspendForAwayMode();
    if (initialSuspension) return initialSuspension;
    if (lockOwnership() !== "owned") await claimSessionLock();
    if (coordinator.startCancelled || coordinator.shuttingDown || coordinator.clients.size === 0) {
      return { ok: false, message: "watcher: not started - Pi extension session shut down" };
    }
    if (lockOwnership() !== "owned") {
      publishStatus(coordinator, "attention");
      return { ok: false, message: "watcher: read-only - session lock is held by another firstmate session" };
    }
    const lockedSuspension = await suspendForAwayMode();
    if (lockedSuspension) return lockedSuspension;
    markLoaded();
    const cadence = cadenceFingerprint();
    if (coordinator.current?.cadence === cadence && !coordinator.current.settled) {
      return { ok: true, message: "watcher: healthy - Pi extension already has an arm child" };
    }
    if (coordinator.current) await stopArmRecord(coordinator, coordinator.current, "cadence-change");
    if (coordinator.startCancelled || coordinator.shuttingDown || coordinator.clients.size === 0) {
      return { ok: false, message: "watcher: not started - Pi extension session shut down" };
    }
    const postCleanupSuspension = await suspendForAwayMode();
    if (postCleanupSuspension) return postCleanupSuspension;
    const pendingWake = coordinator.pendingWake;
    if (pendingWake) {
      const activeClient = [...coordinator.clients.values()].reverse().find((candidate) => candidate.active);
      if (activeClient) {
        try {
          await activeClient.sendWake(pendingWake.message, pendingWake.details);
        } catch (error) {
          publishStatus(coordinator, "attention");
          return {
            ok: false,
            message: error instanceof Error
              ? `watcher: FAILED - pending wake delivery failed: ${error.message}`
              : "watcher: FAILED - pending wake delivery failed",
          };
        }
        if (coordinator.pendingWake === pendingWake) coordinator.pendingWake = null;
        publishStatus(coordinator, "handling wake");
      }
    }
    if (coordinator.startCancelled || coordinator.shuttingDown || coordinator.clients.size === 0) {
      return { ok: false, message: "watcher: not started - Pi extension session shut down" };
    }
    const preSpawnSuspension = await suspendForAwayMode();
    if (preSpawnSuspension) return preSpawnSuspension;

    const id = ++coordinator.sequence;
    const generation = ++coordinator.generation;
    const env = {
      ...process.env,
      FM_HOME: fmHome,
      FM_ROOT_OVERRIDE: fmRoot,
      FM_STATE_OVERRIDE: state,
      FM_CONFIG_OVERRIDE: config,
      FM_WATCH_ARM_SCRIPT: armScript,
    };
    const launchCommand = "state_dir=\"${FM_STATE_OVERRIDE:-$FM_HOME/state}\"; if [ -f \"$state_dir/.afk\" ]; then printf '%s\\n' '"
      + AWAY_SUSPENSION_LINE
      + "'; exit 0; fi; config_dir=\"${FM_CONFIG_OVERRIDE:-$FM_HOME/config}\"; [ -f \"$config_dir/x-mode.env\" ] && . \"$config_dir/x-mode.env\"; exec \"$FM_WATCH_ARM_SCRIPT\" --restart";
    const child = spawn("bash", ["-lc", launchCommand], {
      cwd: fmRoot,
      env,
      detached: true,
      stdio: ["ignore", "pipe", "pipe"],
    });
    const record: ArmRecord = {
      child,
      cadence,
      generation,
      intentionalStopReason: "",
      settled: false,
      stdout: "",
      stderr: "",
      stdoutPending: "",
      stderrPending: "",
      stdoutTruncated: false,
      stderrTruncated: false,
      actionable: "",
      failureHint: "",
    };
    coordinator.current = record;
    publishStatus(coordinator, "watching");
    child.stdout?.on("data", (chunk: Buffer) => {
      captureOutput(record, "stdout", chunk);
    });
    child.stderr?.on("data", (chunk: Buffer) => {
      captureOutput(record, "stderr", chunk);
    });
    child.on("close", (code: number | null, signal: NodeJS.Signals | null) => {
      settleArm(coordinator, record, code, signal);
    });
    child.on("error", (error: Error) => {
      settleArm(coordinator, record, null, null, error);
    });
    return { ok: true, message: `watcher: started Pi extension arm child ${id}` };
  }

  async function startArm(): Promise<ArmResult> {
    const pendingShutdown = coordinator.shutdownPromise;
    if (pendingShutdown) {
      try {
        await pendingShutdown;
      } catch (error) {
        if (client.active && coordinator.clients.get(client.token) === client) {
          publishStatus(coordinator, "attention");
        }
        return {
          ok: false,
          message: error instanceof Error
            ? error.message
            : "watcher: FAILED - Pi extension reload cleanup failed",
        };
      }
    }
    if (!client.active || coordinator.clients.get(client.token) !== client) {
      return { ok: false, message: "watcher: not started - Pi extension session shut down" };
    }
    if (coordinator.startPromise) return coordinator.startPromise;
    if (coordinator.shuttingDown || coordinator.clients.size === 0) {
      return Promise.resolve({ ok: false, message: "watcher: not started - Pi extension session shut down" });
    }
    coordinator.startCancelled = false;
    let startPromise: Promise<ArmResult>;
    startPromise = startArmOnce().finally(() => {
      if (coordinator.startPromise !== startPromise) return;
      coordinator.startPromise = null;
    });
    coordinator.startPromise = startPromise;
    return startPromise;
  }

  pi.on?.("session_start", async (_event, ctx) => {
    client.ui = ctx.ui;
    writeClientStatus(client, coordinator.visibleStatus);
    markLoaded();
    await startArm();
  });

  async function shutdownClient(reason: string): Promise<void> {
    if (!client.active) return;
    writeClientStatus(client, undefined);
    client.active = false;
    coordinator.clients.delete(client.token);
    if (coordinator.clients.size > 0) return;
    if (coordinator.shutdownPromise) {
      await coordinator.shutdownPromise;
      return;
    }

    coordinator.shuttingDown = true;
    coordinator.startCancelled = true;
    const record = coordinator.current;
    if (record && !record.intentionalStopReason) record.intentionalStopReason = reason;
    coordinator.generation += 1;

    const pendingStart = coordinator.startPromise;
    const exitListener = coordinator.exitListener;
    const shutdownToken = Symbol("pi-watch-extension-shutdown");
    coordinator.shutdownToken = shutdownToken;
    const shutdownPromise = Promise.resolve().then(async () => {
      try {
        if (pendingStart) await pendingStart.catch(() => undefined);
        if (coordinator.shutdownToken !== shutdownToken) return;
        const currentRecord = coordinator.current;
        if (currentRecord) await stopArmRecord(coordinator, currentRecord, reason);
        if (coordinator.shutdownToken !== shutdownToken) return;
      } finally {
        if (coordinator.shutdownToken === shutdownToken) {
          if (coordinator.clients.size === 0) {
            if (exitListener && coordinator.exitListener === exitListener) {
              process.off("exit", exitListener);
              coordinator.exitListener = undefined;
            }
          } else {
            coordinator.shuttingDown = false;
            coordinator.startCancelled = false;
          }
          coordinator.shutdownToken = null;
          coordinator.shutdownPromise = null;
        }
      }
    });
    coordinator.shutdownPromise = shutdownPromise;
    await shutdownPromise;
  }

  pi.on?.("session_shutdown", async (event) => {
    await shutdownClient(event.reason || "session-shutdown");
  });

  pi.on("tool_call", async (event) => {
    if (event.type !== "tool_call" || event.toolName !== "bash") return {};
    const command = String((event.input as { command?: unknown })?.command ?? "");
    if (!command) return {};
    const cdResult = await runCdCheck(command);
    if (cdResult.code === 2) {
      return { block: true, reason: cdResult.stderr.trim() || "denied by the cd-guard PreToolUse seatbelt" };
    }
    const result = await runPretoolCheck(command);
    if (result.code !== 2) return {};
    return { block: true, reason: result.stderr.trim() || "denied by the watcher-arm PreToolUse seatbelt" };
  });

  pi.on("tool_execution_end", async () => {
    await startArm();
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

  markLoaded();
}
