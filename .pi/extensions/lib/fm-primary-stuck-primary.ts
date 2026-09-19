import { readdirSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export type StuckPrimaryIdleProbe = {
  isIdle(): boolean;
  hasPendingMessages(): boolean;
};

export type StuckPrimaryConfig = {
  stateDir: string;
  stuckAfterArmMs: number;
};

export type StuckPrimaryRecovery = "none" | "triggerTurn";

export type StuckPrimaryMonitor = {
  onAgentStart: (now?: number) => void;
  onAgentSettled: () => void;
  onProgress: (now?: number) => void;
  onWatcherArmSucceeded: (now?: number) => void;
  recoveryAction: (probe: StuckPrimaryIdleProbe, now?: number) => StuckPrimaryRecovery;
  markTriggerTurnPending: () => void;
  markRecoveryAttempted: () => void;
  consumeTriggerTurnPendingResume: () => boolean;
};

export function wakeQueueHasRecords(stateDir: string): boolean {
  try {
    const body = readFileSync(join(stateDir, ".wake-queue"), "utf8").trim();
    return body.length > 0;
  } catch {
    return false;
  }
}

export function hasInFlightFleetWork(stateDir: string): boolean {
  try {
    for (const name of readdirSync(stateDir)) {
      if (name.endsWith(".meta")) return true;
    }
  } catch {
    return false;
  }
  return false;
}

function hasBackpressure(stateDir: string, probe: StuckPrimaryIdleProbe): boolean {
  if (probe.hasPendingMessages()) return true;
  return wakeQueueHasRecords(stateDir);
}

export function parseStuckAfterArmMs(raw: string | undefined): number {
  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || parsed < 100) return 45_000;
  return Math.floor(parsed);
}

function stalled(armedAt: number, lastProgressAt: number, now: number, stuckAfterArmMs: number): boolean {
  return now - armedAt >= stuckAfterArmMs && now - lastProgressAt >= stuckAfterArmMs;
}

export function createStuckPrimaryMonitor(config: StuckPrimaryConfig): StuckPrimaryMonitor {
  let runActive = false;
  let armedAt: number | null = null;
  let lastProgressAt = 0;
  let triggerTurnPendingResume = false;
  let recoveryCoolingDown = false;

  function commonRecoveryGuards(probe: StuckPrimaryIdleProbe, now: number): boolean {
    if (recoveryCoolingDown) return false;
    if (!runActive) return false;
    if (!armedAt) return false;
    if (!hasInFlightFleetWork(config.stateDir)) return false;
    if (!hasBackpressure(config.stateDir, probe)) return false;
    if (!stalled(armedAt, lastProgressAt, now, config.stuckAfterArmMs)) return false;
    return true;
  }

  return {
    onAgentStart(now = Date.now()) {
      runActive = true;
      armedAt = null;
      lastProgressAt = now;
      triggerTurnPendingResume = false;
      recoveryCoolingDown = false;
    },
    onAgentSettled() {
      runActive = false;
      armedAt = null;
      recoveryCoolingDown = false;
    },
    onProgress(now = Date.now()) {
      lastProgressAt = now;
      recoveryCoolingDown = false;
    },
    onWatcherArmSucceeded(now = Date.now()) {
      armedAt = now;
      lastProgressAt = now;
    },
    recoveryAction(probe, now = Date.now()) {
      if (!commonRecoveryGuards(probe, now)) return "none";
      if (!probe.isIdle()) return "none";
      return "triggerTurn";
    },
    markTriggerTurnPending() {
      triggerTurnPendingResume = true;
    },
    markRecoveryAttempted() {
      recoveryCoolingDown = true;
    },
    consumeTriggerTurnPendingResume() {
      const pending = triggerTurnPendingResume;
      triggerTurnPendingResume = false;
      return pending;
    },
  };
}

const GLOBAL_MONITOR_KEY = "__fmPrimaryStuckPrimaryMonitor";

function resolveStateDir(): string {
  const root = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
  const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
  return process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
}

export function getSharedStuckPrimaryMonitor(): StuckPrimaryMonitor {
  const globalStore = globalThis as typeof globalThis & {
    [GLOBAL_MONITOR_KEY]?: StuckPrimaryMonitor;
    [GLOBAL_MONITOR_KEY + ":stateDir"]?: string;
    [GLOBAL_MONITOR_KEY + ":stuckAfterArmMs"]?: number;
  };
  const stateDir = resolveStateDir();
  const stuckAfterArmMs = parseStuckAfterArmMs(process.env.FM_PI_STUCK_AFTER_ARM_MS);
  const configMatches =
    globalStore[GLOBAL_MONITOR_KEY + ":stateDir"] === stateDir &&
    globalStore[GLOBAL_MONITOR_KEY + ":stuckAfterArmMs"] === stuckAfterArmMs;
  if (!globalStore[GLOBAL_MONITOR_KEY] || !configMatches) {
    globalStore[GLOBAL_MONITOR_KEY] = createStuckPrimaryMonitor({ stateDir, stuckAfterArmMs });
    globalStore[GLOBAL_MONITOR_KEY + ":stateDir"] = stateDir;
    globalStore[GLOBAL_MONITOR_KEY + ":stuckAfterArmMs"] = stuckAfterArmMs;
  }
  return globalStore[GLOBAL_MONITOR_KEY];
}
