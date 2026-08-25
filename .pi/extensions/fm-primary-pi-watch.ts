// Firstmate primary watcher bridge for Pi.
//
// Session-generation ownership (stated once here):
// Pi emits session_shutdown for ordinary same-process replacements (/new, /resume,
// /fork, reload) as well as terminal quit. This extension binds one generation per
// session activation. Only the active live generation may start, stop, rearm, or
// clear the arm child. Replacement session_start (or a fresh factory bind) activates
// a new live generation so monitoring can arm again without restarting Pi. Terminal
// quit leaves the final generation stopped so late callbacks cannot rearm. Stale
// callbacks from a prior generation are no-ops against the active replacement.
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, Theme, ToolDefinition } from "@earendil-works/pi-coding-agent";
import { Box, Container, Text, type Component } from "@earendil-works/pi-tui";
import { Type } from "typebox";
import {
  createBranchDispatchOffer,
  FM_BRANCH_DISPATCH_EVENT,
  scopeForUnreadWake,
} from "./lib/fm-branch-dispatch.ts";
import {
  type CalmPresentationState,
  calmTranscriptClassIsVisible,
  FIRSTMATE_CALM_PRESENTATION_EVENT,
} from "./lib/fm-calm-visibility.ts";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.ts";

type ArmResult = {
  ok: boolean;
  message: string;
};

type LockOwnership = "owned" | "missing" | "other";

type CloseClassification = {
  kind: "actionable" | "failure";
  message: string;
};

type WatchToolShellState = {
  shell?: Box;
  call?: Component;
  result?: Component;
};

type WatchToolRenderContext = {
  isError: boolean;
  isPartial: boolean;
};

type SessionGeneration = {
  id: number;
  stopping: boolean;
  child: ChildProcess | null;
  retryTimer: ReturnType<typeof setTimeout> | null;
  retryFailures: number;
  restoring: boolean;
  seq: number;
};

function refreshWatchToolShell(
  state: WatchToolShellState,
  theme: Theme,
  context: WatchToolRenderContext,
): Box {
  const background = context.isPartial
    ? (text: string) => theme.bg("toolPendingBg", text)
    : context.isError
      ? (text: string) => theme.bg("toolErrorBg", text)
      : (text: string) => theme.bg("toolSuccessBg", text);
  const shell = state.shell ?? new Box(1, 1, background);
  state.shell = shell;
  shell.setBgFn(background);
  shell.clear();
  if (state.call) shell.addChild(state.call);
  if (state.result) shell.addChild(state.result);
  return shell;
}

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const armScript = `${fmRoot}/bin/fm-watch-arm.sh`;
const wakeContextScript = `${fmRoot}/bin/fm-wake-context.sh`;
const marker = `${state}/.pi-watch-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;
const retryBaseMs = positiveInteger("FM_WATCH_REARM_RETRY_BASE_MS", 250);
const retryMaxMs = positiveInteger("FM_WATCH_REARM_RETRY_MAX_MS", 4000);
const retryLimit = positiveInteger("FM_WATCH_REARM_RETRY_LIMIT", 5);
// 35s on Windows so the budget stays above arm's MSYS confirm default (30s in
// bin/fm-watch-arm.sh): a slow but successful Git Bash cold start must not be
// SIGTERMed mid-confirmation. Conditioned on win32 so other platforms keep 12s.
const armReadyTimeoutMs = positiveInteger(
  "FM_PI_ARM_READY_TIMEOUT_MS",
  process.platform === "win32" ? 35000 : 12000,
);
const armRetireTimeoutMs = positiveInteger("FM_WATCH_ARM_RETIRE_TIMEOUT_MS", 1000);
const repairOnlyHint = "call fm_watch_arm_pi again only after a later notification says the cycle is missing, failed, or unhealthy";
const shuttingDownMessage = "watcher: not armed - Pi session is shutting down";

let nextGenerationId = 0;
let activeGeneration: SessionGeneration | null = null;
const armReadiness = new WeakMap<ChildProcess, Promise<boolean>>();
const armClose = new WeakMap<ChildProcess, Promise<void>>();
const armRecovery = new WeakMap<ChildProcess, { generation: string; watcherPid: string }>();

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

function wakeContextPresentation(): string {
  const fallback = "WAKE_CONTEXT_FALLBACK: run bin/fm-wake-drain.sh once.";
  const result = spawnSync("bash", [wakeContextScript, "--present"], {
    cwd: fmRoot,
    env: { ...process.env, FM_HOME: fmHome, FM_STATE_OVERRIDE: state, FM_ROOT_OVERRIDE: fmRoot },
    encoding: "utf8",
  });
  const output = `${result.stdout || ""}\n${result.stderr || ""}`.trim();
  return output || fallback;
}

function createGeneration(): SessionGeneration {
  return {
    id: ++nextGenerationId,
    stopping: false,
    child: null,
    retryTimer: null,
    retryFailures: 0,
    restoring: false,
    seq: 0,
  };
}

function activateGeneration(generation: SessionGeneration): void {
  activeGeneration = generation;
}

function generationIsLive(generation: SessionGeneration): boolean {
  return activeGeneration === generation && !generation.stopping;
}

function stopGeneration(generation: SessionGeneration): void {
  generation.stopping = true;
  if (generation.retryTimer) clearTimeout(generation.retryTimer);
  generation.retryTimer = null;
  if (generation.child) generation.child.kill("SIGTERM");
  generation.child = null;
}

const cleanupOnProcessExit = () => {
  if (activeGeneration) stopGeneration(activeGeneration);
};
process.once("exit", cleanupOnProcessExit);

type Recovery = { generation: string; watcherPid: string };
type Confirmation = { ok: boolean; detail: string };
type Restoration = { failure: string; recovery?: Recovery };
type RestorationStep = Restoration & { retry: boolean; terminal?: boolean };
type WatchToolDefinition = ToolDefinition;
type PiWatchRuntime = { pi: ExtensionAPI; generation: SessionGeneration; calm: CalmPresentationState };
type ArmCycle = {
  stdout: string; stderr: string; settled: boolean; readinessSettled: boolean;
  resolveReadiness: (ready: boolean) => void; resolveClosed: () => void;
};

function createRuntime(pi: ExtensionAPI): PiWatchRuntime {
  const generation = createGeneration();
  activateGeneration(generation);
  return { pi, generation, calm: { active: false, stockExportRendering: false } };
}

function registerCalmPresentation(runtime: PiWatchRuntime): void {
  runtime.pi.events?.on?.(FIRSTMATE_CALM_PRESENTATION_EVENT, (data) => {
    const next = data as Partial<CalmPresentationState>;
    runtime.calm = { active: next.active === true, stockExportRendering: next.stockExportRendering === true };
  });
}

function calmHides(runtime: PiWatchRuntime, itemClass: Parameters<typeof calmTranscriptClassIsVisible>[0]): boolean {
  return runtime.calm.active && !runtime.calm.stockExportRendering && !calmTranscriptClassIsVisible(itemClass);
}

async function sendWake(runtime: PiWatchRuntime, owner: SessionGeneration, message: string): Promise<void> {
  if (!generationIsLive(owner)) return;
  const content = encodeFirstmateOperationalInput(
    "watcher",
    `FIRSTMATE WATCHER WAKE: ${message}\n\n${wakeContextPresentation()}\n\nHandle the attached wake-context packet or fallback instruction without rebuilding fleet context. Watcher continuity is extension-owned.`,
  );
  await runtime.pi.sendUserMessage(content, { deliverAs: "followUp" });
}

function rejectedConfirmation(result: ReturnType<typeof spawnSync>, recovery: Recovery): Confirmation {
  const stderr = String(result.stderr || "").trim();
  return {
    ok: false,
    detail: `watcher: FAILED - handling delivery confirmation was rejected (status=${result.status ?? "none"} generation=${recovery.generation} watcherPid=${recovery.watcherPid})${stderr ? `\n${stderr}` : ""}`,
  };
}

function failedConfirmation(error: unknown, recovery: Recovery): Confirmation {
  const message = error instanceof Error ? error.message : String(error);
  return {
    ok: false,
    detail: `watcher: FAILED - handling delivery confirmation could not be executed (generation=${recovery.generation} watcherPid=${recovery.watcherPid})\n${message}`,
  };
}

function confirmHandlingDelivery(recovery: Recovery): Confirmation {
  try {
    const result = spawnSync("bash", [armScript, "--handling-delivered", recovery.generation, "--watcher-pid", recovery.watcherPid], {
      cwd: fmRoot,
      encoding: "utf8",
      env: { ...process.env, FM_HOME: fmHome, FM_STATE_OVERRIDE: state, FM_ROOT_OVERRIDE: fmRoot },
    });
    return result.status === 0 ? { ok: true, detail: "" } : rejectedConfirmation(result, recovery);
  } catch (error) {
    return failedConfirmation(error, recovery);
  }
}

function confirmHandlingDeliveryWithRetry(owner: SessionGeneration, recovery: Recovery): Confirmation {
  const snapshot = (): Recovery => {
    const current = owner.child ? armRecovery.get(owner.child) : undefined;
    return current ?? recovery;
  };
  const first = confirmHandlingDelivery(snapshot());
  return first.ok ? first : confirmHandlingDelivery(snapshot());
}

function offerWakeToBranch(runtime: PiWatchRuntime, message: string): boolean {
  const heartbeat = /^heartbeat($|:)/.test(message);
  const isCheckTrigger = /^check:/.test(message);
  const scope = scopeForUnreadWake(state, heartbeat);
  const offer = createBranchDispatchOffer(message, scope.projects, heartbeat, !isCheckTrigger && scope.eligible);
  runtime.pi.events?.emit?.(FM_BRANCH_DISPATCH_EVENT, offer);
  return offer.accepted;
}

async function deliverActionableWake(runtime: PiWatchRuntime, owner: SessionGeneration, message: string, repairFailed: boolean, recovery?: Recovery): Promise<void> {
  if (!generationIsLive(owner)) return;
  if (recovery) {
    const confirmed = confirmHandlingDeliveryWithRetry(owner, recovery);
    if (!confirmed.ok) {
      if (!pidAlive(recovery.watcherPid)) await retireArm(owner.child);
      await sendWake(runtime, owner, `${message}\n\n${confirmed.detail}`);
      return;
    }
  }
  if (!repairFailed && offerWakeToBranch(runtime, message)) return;
  await sendWake(runtime, owner, message);
}

function surfaceFailure(runtime: PiWatchRuntime, owner: SessionGeneration, message: string): void {
  void sendWake(runtime, owner, message).catch(() => {
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

async function restorationStep(runtime: PiWatchRuntime, owner: SessionGeneration, predecessor: string): Promise<RestorationStep> {
  const replacement = startArm(runtime, owner, predecessor);
  const successor = owner.child;
  if (replacement.ok && successor && await waitForReadiness(successor)) {
    return { failure: "", recovery: armRecovery.get(successor), retry: false };
  }
  if (replacement.ok) {
    const failure = "watcher: FAILED - Pi extension could not verify a ready successor watcher";
    if (await retireArm(successor)) return { failure, retry: true };
    return { failure: `${failure}\nwatcher: FAILED - Pi extension could not restore watcher continuity because the unready successor arm did not exit within ${armRetireTimeoutMs}ms`, retry: false, terminal: true };
  }
  const lostOwnership = /(?:read-only|no live session)/.test(replacement.message);
  const failure = lostOwnership
    ? `watcher: FAILED - Pi extension cannot restore continuity because this session no longer owns the lock\n${replacement.message}`
    : `watcher: FAILED - Pi extension could not start the successor watcher cycle\n${replacement.message}`;
  return { failure, retry: !lostOwnership };
}

async function restoreAfterActionableClose(runtime: PiWatchRuntime, owner: SessionGeneration, predecessor: string): Promise<Restoration> {
  let failure = "";
  for (let attempt = 0; attempt <= retryLimit; attempt += 1) {
    if (!generationIsLive(owner)) return { failure: "" };
    const step = await restorationStep(runtime, owner, predecessor);
    failure = step.failure;
    if (!step.failure || step.terminal) return { failure, recovery: step.recovery };
    if (!step.retry) break;
    if (attempt === retryLimit) break;
    await waitForRetry(attempt + 1);
  }
  return { failure: `${failure}\nwatcher: FAILED - Pi extension could not restore watcher continuity after ${retryLimit} retries` };
}

function runScheduledRetry(runtime: PiWatchRuntime, owner: SessionGeneration, predecessor: string, timer: ReturnType<typeof setTimeout>): void {
  if (owner.retryTimer === timer) owner.retryTimer = null;
  if (!generationIsLive(owner)) return;
  const result = startArm(runtime, owner, predecessor);
  if (!result.ok) surfaceFailure(runtime, owner, `watcher: FAILED - Pi extension could not launch a continuity retry\n${result.message}`);
}

function scheduleRetry(runtime: PiWatchRuntime, owner: SessionGeneration, message: string, predecessor: string): void {
  if (!generationIsLive(owner) || owner.child || owner.retryTimer) return;
  if (lockOwnership() !== "owned") {
    surfaceFailure(runtime, owner, `watcher: FAILED - Pi extension cannot restore continuity because this session no longer owns the lock\n${message}`);
    return;
  }
  owner.retryFailures += 1;
  if (owner.retryFailures > retryLimit) {
    surfaceFailure(runtime, owner, `watcher: FAILED - Pi extension could not restore watcher continuity after ${retryLimit} retries\n${message}`);
    return;
  }
  const timer = setTimeout(() => {
    runScheduledRetry(runtime, owner, predecessor, timer);
  }, retryDelay(owner.retryFailures));
  timer.unref();
  owner.retryTimer = timer;
}

function armOwnershipRefusal(owner: SessionGeneration): ArmResult | null {
  if (!generationIsLive(owner)) return { ok: false, message: shuttingDownMessage };
  const ownership = lockOwnership();
  if (ownership === "other") return { ok: false, message: "watcher: read-only - session lock is held by another firstmate session" };
  if (ownership === "missing") {
    return { ok: false, message: "watcher: not armed - no live session holds the lock; run bin/fm-session-start.sh to reclaim it, then call fm_watch_arm_pi to re-arm" };
  }
  return null;
}

function existingArmResult(owner: SessionGeneration): ArmResult | null {
  if (owner.child) return { ok: true, message: `watcher: unchanged - Pi extension already owns an arm child; no manual re-arm needed; ${repairOnlyHint}` };
  if (owner.retryTimer) return { ok: true, message: `watcher: unchanged - Pi extension already owns a scheduled continuity retry; no manual re-arm needed; ${repairOnlyHint}` };
  return null;
}

function armEnvironment(predecessor: string): NodeJS.ProcessEnv {
  return {
    ...process.env,
    FM_HOME: fmHome,
    FM_ROOT_OVERRIDE: fmRoot,
    FM_CONFIG_OVERRIDE: config,
    FM_WATCH_ARM_SCRIPT: armScript,
    FM_WATCH_PREDECESSOR_ARM_PID: predecessor,
  };
}

function spawnArm(predecessor: string): ChildProcess {
  return spawn("bash", ["-lc", "config_dir=\"${FM_CONFIG_OVERRIDE:-$FM_HOME/config}\"; [ -f \"$config_dir/x-mode.env\" ] && . \"$config_dir/x-mode.env\"; exec \"$FM_WATCH_ARM_SCRIPT\" --restart"], {
    cwd: fmRoot,
    env: armEnvironment(predecessor),
    stdio: ["ignore", "pipe", "pipe"],
  });
}

function createArmCycle(armChild: ChildProcess): ArmCycle {
  let resolveReadiness: (ready: boolean) => void = () => {};
  let resolveClosed: () => void = () => {};
  const readiness = new Promise<boolean>((resolveReady) => { resolveReadiness = resolveReady; });
  const closed = new Promise<void>((resolveClosedChild) => { resolveClosed = resolveClosedChild; });
  armReadiness.set(armChild, readiness);
  armClose.set(armChild, closed);
  return { stdout: "", stderr: "", settled: false, readinessSettled: false, resolveReadiness, resolveClosed };
}

function settleReadiness(cycle: ArmCycle, ready: boolean): void {
  if (cycle.readinessSettled) return;
  cycle.readinessSettled = true;
  cycle.resolveReadiness(ready);
}

function observeEstablishedArm(armChild: ChildProcess, cycle: ArmCycle): void {
  const combined = `${cycle.stdout}\n${cycle.stderr}`;
  const recovery = combined.match(/^watcher: started pid=([0-9]+).* recovery-generation=([A-Za-z0-9._-]+)$/m);
  if (recovery) armRecovery.set(armChild, { watcherPid: recovery[1], generation: recovery[2] });
  if (/^watcher: (?:started|attached)\b/m.test(combined)) settleReadiness(cycle, true);
}

function appendArmOutput(armChild: ChildProcess, cycle: ArmCycle, stream: "stdout" | "stderr", chunk: Buffer): void {
  cycle[stream] += chunk.toString();
  observeEstablishedArm(armChild, cycle);
}

function settleClosedArm(owner: SessionGeneration, armChild: ChildProcess, cycle: ArmCycle): boolean {
  if (cycle.settled) return false;
  cycle.settled = true;
  cycle.resolveClosed();
  settleReadiness(cycle, false);
  if (owner.child === armChild) owner.child = null;
  return true;
}

async function restoreAndDeliver(runtime: PiWatchRuntime, owner: SessionGeneration, predecessor: string, classification: CloseClassification): Promise<void> {
  try {
    const restoration = await restoreAfterActionableClose(runtime, owner, predecessor);
    if (!generationIsLive(owner)) return;
    const message = restoration.failure ? `${classification.message}\n\n${restoration.failure}` : classification.message;
    await deliverActionableWake(runtime, owner, message, Boolean(restoration.failure), restoration.recovery);
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    surfaceFailure(runtime, owner, `watcher: FAILED - Pi extension could not deliver an actionable wake\n${detail}`);
  } finally {
    if (generationIsLive(owner)) owner.restoring = false;
  }
}

function beginActionableClose(runtime: PiWatchRuntime, owner: SessionGeneration, predecessor: string, classification: CloseClassification): void {
  if (owner.restoring) return;
  owner.retryFailures = 0;
  owner.restoring = true;
  void restoreAndDeliver(runtime, owner, predecessor, classification);
}

function handleArmClose(runtime: PiWatchRuntime, owner: SessionGeneration, armChild: ChildProcess, cycle: ArmCycle, code: number | null, signal: NodeJS.Signals | null): void {
  if (!settleClosedArm(owner, armChild, cycle) || !generationIsLive(owner)) return;
  const classification = classifyClose(cycle.stdout, cycle.stderr, code, signal);
  const predecessor = String(armChild.pid ?? "");
  if (classification.kind === "actionable") {
    beginActionableClose(runtime, owner, predecessor, classification);
    return;
  }
  if (!owner.restoring) scheduleRetry(runtime, owner, classification.message, predecessor);
}

function handleArmError(runtime: PiWatchRuntime, owner: SessionGeneration, armChild: ChildProcess, cycle: ArmCycle, id: number, error: Error): void {
  if (!settleClosedArm(owner, armChild, cycle) || !generationIsLive(owner) || owner.restoring) return;
  scheduleRetry(runtime, owner, `watcher: FAILED - Pi extension arm child ${id} failed: ${error.message}`, String(armChild.pid ?? ""));
}

function wireArmChild(runtime: PiWatchRuntime, owner: SessionGeneration, armChild: ChildProcess, cycle: ArmCycle, id: number): void {
  armChild.stdout.on("data", (chunk: Buffer) => appendArmOutput(armChild, cycle, "stdout", chunk));
  armChild.stderr.on("data", (chunk: Buffer) => appendArmOutput(armChild, cycle, "stderr", chunk));
  armChild.on("close", (code, signal) => handleArmClose(runtime, owner, armChild, cycle, code, signal));
  armChild.on("error", (error) => handleArmError(runtime, owner, armChild, cycle, id, error));
}

function startArm(runtime: PiWatchRuntime, owner: SessionGeneration, predecessor = ""): ArmResult {
  const refusal = armOwnershipRefusal(owner);
  if (refusal) return refusal;
  markLoaded();
  const existing = existingArmResult(owner);
  if (existing) return existing;
  const id = ++owner.seq;
  const armChild = spawnArm(predecessor);
  owner.child = armChild;
  wireArmChild(runtime, owner, armChild, createArmCycle(armChild), id);
  return { ok: true, message: `watcher: started Pi extension arm child ${id}; future ordinary re-arms are automatic; ${repairOnlyHint}` };
}

function registerLifecycle(runtime: PiWatchRuntime): void {
  runtime.pi.on?.("session_start", () => {
    if (runtime.generation.stopping) runtime.generation = createGeneration();
    activateGeneration(runtime.generation);
    markLoaded();
  });
  runtime.pi.on?.("session_shutdown", () => stopGeneration(runtime.generation));
}

function registerWatchCommand(runtime: PiWatchRuntime): void {
  runtime.pi.registerCommand?.("fm-watch-arm-pi", {
    description: "Arm firstmate watcher supervision through the Pi extension instead of foreground bash.",
    handler: async (_args, ctx) => {
      const result = startArm(runtime, runtime.generation);
      ctx.ui.notify(result.message, result.ok ? "info" : "warning");
    },
  });
}

function renderWatchCall(runtime: PiWatchRuntime, theme: Theme, context: { state: unknown } & WatchToolRenderContext): Component {
  if (calmHides(runtime, "assistant-tool-call")) return new Container();
  if (runtime.calm.stockExportRendering) return new Text(theme.fg("toolTitle", theme.bold("fm_watch_arm_pi")), 0, 0);
  const shellState = context.state as WatchToolShellState;
  shellState.call = new Text(theme.fg("toolTitle", theme.bold("fm_watch_arm_pi")), 0, 0);
  return refreshWatchToolShell(shellState, theme, context);
}

function renderWatchResult(runtime: PiWatchRuntime, result: { content: Array<{ type: string; text?: string }> }, theme: Theme, context: { state: unknown } & WatchToolRenderContext): Component {
  if (calmHides(runtime, "tool-result")) return new Container();
  const output = result.content.filter((item) => item.type === "text").map((item) => item.text).join("\n");
  if (runtime.calm.stockExportRendering) return new Text(theme.fg("toolOutput", output), 0, 0);
  const shellState = context.state as WatchToolShellState;
  shellState.result = output ? new Text(theme.fg("toolOutput", output), 0, 0) : new Container();
  refreshWatchToolShell(shellState, theme, context);
  return new Container();
}

async function executeWatchTool(runtime: PiWatchRuntime) {
  const result = startArm(runtime, runtime.generation);
  return { content: [{ type: "text" as const, text: result.message }], details: result };
}

function watchToolDefinition(runtime: PiWatchRuntime): WatchToolDefinition {
  return {
    name: "fm_watch_arm_pi", label: "Arm firstmate watcher",
    description: "Start the first required Pi watcher cycle, or repair one only after a notification says the cycle is missing, failed, or unhealthy. Do not call after ordinary work or ordinary notifications; the Pi extension re-arms automatically. Never run bin/fm-watch-arm.sh through bash.",
    promptSnippet: "Start the first required Pi watcher cycle or repair a cycle reported missing, failed, or unhealthy; ordinary re-arming is automatic.",
    promptGuidelines: ["Call fm_watch_arm_pi only for the first required cycle or after a notification says the cycle is missing, failed, or unhealthy. Do not call it after ordinary work, turn completion, or ordinary signal, stale, check, or heartbeat handling because the Pi extension owns re-arming. Never run bin/fm-watch-arm.sh through bash."],
    parameters: Type.Object({}), renderShell: "self",
    renderCall: (_args, theme, context) => renderWatchCall(runtime, theme, context),
    renderResult: (result, _options, theme, context) => renderWatchResult(runtime, result, theme, context),
    execute: async () => executeWatchTool(runtime),
  };
}

export default function (pi: ExtensionAPI) {
  const runtime = createRuntime(pi);
  registerCalmPresentation(runtime);
  registerLifecycle(runtime);
  registerWatchCommand(runtime);
  runtime.pi.registerTool?.(watchToolDefinition(runtime));
  markLoaded();
}
