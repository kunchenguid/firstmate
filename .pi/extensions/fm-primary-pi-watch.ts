// Firstmate primary watcher bridge for Pi.
//
// Session-generation ownership (stated once here):
// Pi emits session_shutdown for ordinary same-process replacements (/new, /resume,
// /fork, reload) as well as terminal quit. This extension binds one generation per
// session activation. Only the active live generation may start, stop, rearm, or
// clear the arm child. An owning replacement session_start (or fresh factory bind)
// arms its new generation without a model turn. A replacement handoff carries
// actionable closes that were still pending delivery; its durable state lives at
// state/extensions/pi-primary-watch/session-replacement-actionable.json.
// Terminal quit leaves the final generation stopped so late callbacks cannot rearm.
// Stale callbacks from a prior generation are no-ops against the active replacement.
//
// Delivery versus consumption (stated once here):
// A main follow-up is delivered once Pi accepts it (sendUserMessage resolves).
// The successor pipeline never waits for the model to read it: a follow-up
// queued while main is streaming joins the running run without ever raising
// before_agent_start, so waiting on that event stalls every later close.
// Consumption is tracked only so a replacement can replay a follow-up Pi had
// not consumed. An idle main consumes at before_agent_start; a streaming main
// consumes at the user message_start carrying the exact wake text; either
// event finishes the pending record, and a still-unconsumed record rides the
// replacement handoff.
//
// Ordinary wake presentation coalescing (stated once here):
// The watcher enqueues every actionable event durably before it exits, so this
// extension only decides whether Pi's fixed follow-up dock gains another row.
// While one ordinary work-waiting row is pending, later ordinary wakes add no
// row; the pending row already directs the model to drain the durable queue.
// The latch lives on the session generation and clears on both agent_start and
// agent_settled. A replacement session activates a fresh generation with a
// clear latch, so no stale latch leaks across generations and a genuinely
// later burst creates one new row.
// The latch is set BEFORE calling pi.sendUserMessage because in Pi 0.84.4 that
// ExtensionAPI method returns void (dist/core/extensions/types.d.ts declares it
// void; dist/core/extensions/loader.js discards the runtime promise), so the
// await resumes on the very next microtask while the run it triggers starts
// from the runtime's own asynchronous chain and emits agent_start later.
// Setting the latch before the call is therefore the only ordering with no
// race; setting it after the await would race the consumption edge and could
// strand the latch true behind a row that was already consumed.
// Both clearing edges are needed because Pi 0.84.4 consumes a docked row
// without a second agent_start. An idle send makes the runtime start a run that
// emits agent_start; a row docked on a busy agent is drained inline by the run
// already in flight, which emits turn_start only.
// agent_start therefore stays the idle-path edge, re-arming presentation the
// moment that row is consumed rather than at the end of the run it started,
// while agent_settled is the settle boundary that implies no docked row
// remains: Pi emits it once a run has fully settled with no automatic retry,
// compaction, or queued continuation left, including when the run aborts and
// its queue is discarded.
// The worst case is therefore bounded: a wake arriving after an inline drain
// but before settle is suppressed for the remainder of that one run, never
// indefinitely for the generation, and the durable queue still holds it.
// Urgent supervision failures bypass the latch and always surface as their own
// row: call sites mark the paths they own, and any message carrying the
// `watcher: FAILED` marker is urgent regardless of which branch delivered it,
// so a typed failure riding the ordinary branch is never coalesced away. Every
// failure text in this extension must keep that marker; a false-urgent costs
// one extra row, a false-ordinary could sit on a real supervision failure.
// Pi exposes no per-row consumption signal, so a captain prompt that starts a
// run while a row is still docked clears the latch early and a close during
// that run can dock a second row. That transient is bounded at two rows, both
// consumed in order, and is the accepted cost of using run boundaries as the
// only consumption evidence Pi offers.
// Second residual, a limitation of the current Pi extension API surface rather
// than a chosen design: the extension cannot observe a failed send at all.
// ExtensionAPI.sendUserMessage returns void and the runtime binding routes
// every rejection to runner.emitError, so a delivery that fails leaves the
// latch set with no row docked and no run started. It clears at the next run's
// agent_start or agent_settled, in practice the next captain turn, and the
// durable queue still holds the event meanwhile. The delivery path still rolls
// the latch back inside the catch that drops the unconsumed-wake record, so a
// surface that does report a rejection releases presentation immediately.
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, Theme } from "@earendil-works/pi-coding-agent";
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

type PendingActionableClose = {
  version: 1;
  token: string;
  message: string;
  predecessorArmPid: string;
  delivered?: true;
};

type ReplacementActionableHandoff = {
  version: 2;
  pending: PendingActionableClose[];
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

type UnconsumedWake = {
  content: string;
  pending: PendingActionableClose;
};

type WakePresentation = "ordinary" | "urgent";

type SessionGeneration = {
  id: number;
  stopping: boolean;
  replacement: boolean;
  child: ChildProcess | null;
  retryTimer: ReturnType<typeof setTimeout> | null;
  cleanupTimer: ReturnType<typeof setTimeout> | null;
  retryFailures: number;
  restoring: boolean;
  seq: number;
  pendingActionables: PendingActionableClose[];
  cleanupFailure: string;
  // Main follow-ups Pi has accepted but not yet consumed, by pending token.
  // Never cleared at shutdown: a delivery continuation that runs after the
  // replacement began reads it to tell a main-queued wake (replayed) from a
  // branch-handled one (finished).
  unconsumedWakes: Map<string, UnconsumedWake>;
  // A verified successor's failure close that arrived while the pipeline was
  // still delivering the wake it was started for; its bounded retry runs once
  // that delivery settles instead of being skipped by the single-flight guard.
  deferredClose: { message: string; predecessorArmPid: string } | null;
  pendingOrdinaryWakeRow: boolean;
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
const marker = `${state}/.pi-watch-extension-loaded`;
const handoffDir = `${state}/extensions/pi-primary-watch`;
const actionableHandoff = `${handoffDir}/session-replacement-actionable.json`;
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
let nextHandoffId = 0;
let activeGeneration: SessionGeneration | null = null;
let replacementHandoff: PendingActionableClose[] | null = null;
type ReplacementActionableReceiver = (pending: PendingActionableClose) => void;
type ActionableDeliveryClaim = {
  owner: SessionGeneration;
  settlement: Promise<"delivered" | "failed">;
};
type ReplacementCoordinator = {
  receiver: ReplacementActionableReceiver | null;
  pending: PendingActionableClose[];
  nextTokenId: number;
  deliveries: Map<string, ActionableDeliveryClaim>;
};
type ReplacementCoordinatorGlobal = typeof globalThis & {
  __firstmatePiWatchReplacements?: Map<string, ReplacementCoordinator>;
};
const replacementCoordinatorGlobal = globalThis as ReplacementCoordinatorGlobal;
const replacementCoordinators = replacementCoordinatorGlobal.__firstmatePiWatchReplacements ??= new Map<string, ReplacementCoordinator>();
function replacementCoordinatorFor(handoff: string): ReplacementCoordinator {
  const existing = replacementCoordinators.get(handoff);
  if (existing) return existing;
  const created: ReplacementCoordinator = {
    receiver: null,
    pending: [],
    nextTokenId: 0,
    deliveries: new Map(),
  };
  replacementCoordinators.set(handoff, created);
  return created;
}
const replacementCoordinator = replacementCoordinatorFor(actionableHandoff);
const armReadiness = new WeakMap<ChildProcess, Promise<boolean>>();
const armClose = new WeakMap<ChildProcess, Promise<void>>();
// Children the extension itself asked to exit; their close is not a failure
// of the successor and never earns a deferred retry.
const armRetired = new WeakSet<ChildProcess>();
const armRecovery = new WeakMap<ChildProcess, { generation: string; watcherPid: string }>();
const armPendingActionable = new WeakMap<ChildProcess, PendingActionableClose>();

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

function completedActionableLine(output: string): string {
  const newline = output.lastIndexOf("\n");
  return newline < 0 ? "" : actionableLine(output.slice(0, newline + 1));
}

// The text Pi carries in a user message_start: sendUserMessage wraps a string
// as one text part, so the joined text parts equal the sent content.
function userMessageText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  const parts: string[] = [];
  for (const part of content) {
    if (
      typeof part === "object" && part !== null &&
      (part as { type?: unknown }).type === "text" &&
      typeof (part as { text?: unknown }).text === "string"
    ) {
      parts.push((part as { text: string }).text);
    }
  }
  return parts.join("\n");
}

function nodeErrorCode(error: unknown): string {
  return typeof error === "object" && error !== null && "code" in error
    ? String((error as { code?: unknown }).code ?? "")
    : "";
}

function createPendingActionable(message: string, predecessorArmPid: string): PendingActionableClose {
  return {
    version: 1,
    token: `${process.pid}-${Date.now()}-${++replacementCoordinator.nextTokenId}`,
    message,
    predecessorArmPid,
  };
}

function validatePendingActionable(value: unknown): PendingActionableClose {
  if (
    typeof value !== "object" || value === null ||
    (value as { version?: unknown }).version !== 1 ||
    typeof (value as { token?: unknown }).token !== "string" ||
    !/^[0-9]+-[0-9]+-[0-9]+$/.test((value as { token: string }).token) ||
    typeof (value as { message?: unknown }).message !== "string" ||
    !actionableLine((value as { message: string }).message) ||
    typeof (value as { predecessorArmPid?: unknown }).predecessorArmPid !== "string" ||
    !/^[0-9]*$/.test((value as { predecessorArmPid: string }).predecessorArmPid) ||
    ((value as { delivered?: unknown }).delivered !== undefined &&
      (value as { delivered?: unknown }).delivered !== true)
  ) {
    throw new Error(`invalid Pi replacement actionable handoff at ${actionableHandoff}`);
  }
  return value as PendingActionableClose;
}

function validateReplacementHandoff(value: unknown): PendingActionableClose[] {
  if (
    typeof value !== "object" || value === null ||
    (value as { version?: unknown }).version !== 2 ||
    !Array.isArray((value as { pending?: unknown }).pending) ||
    (value as { pending: unknown[] }).pending.length === 0
  ) {
    throw new Error(`invalid Pi replacement actionable handoff at ${actionableHandoff}`);
  }
  const pending = (value as { pending: unknown[] }).pending.map(validatePendingActionable);
  if (new Set(pending.map((item) => item.token)).size !== pending.length) {
    throw new Error(`invalid Pi replacement actionable handoff at ${actionableHandoff}`);
  }
  return pending;
}

function writeReplacementHandoff(pending: PendingActionableClose[]): void {
  replacementHandoff = [...pending];
  mkdirSync(handoffDir, { recursive: true });
  const temporary = `${actionableHandoff}.tmp-${process.pid}-${++nextHandoffId}`;
  const handoff: ReplacementActionableHandoff = { version: 2, pending };
  try {
    writeFileSync(temporary, `${JSON.stringify(handoff)}\n`, { mode: 0o600 });
    renameSync(temporary, actionableHandoff);
  } catch (error) {
    try {
      unlinkSync(temporary);
    } catch {
      // Preserve the original handoff publication error.
    }
    throw error;
  }
}

function persistReplacementHandoff(pending: PendingActionableClose[]): void {
  if (pending.length === 0) return;
  writeReplacementHandoff(pending);
}

function loadReplacementHandoff(): PendingActionableClose[] {
  try {
    const pending = validateReplacementHandoff(JSON.parse(readFileSync(actionableHandoff, "utf8")));
    replacementHandoff = pending;
    return [...pending];
  } catch (error) {
    if (nodeErrorCode(error) === "ENOENT") {
      replacementHandoff = null;
      return [];
    }
    throw error;
  }
}

function mergeReplacementHandoff(pending: PendingActionableClose): void {
  let stored: PendingActionableClose[] = [];
  try {
    stored = validateReplacementHandoff(JSON.parse(readFileSync(actionableHandoff, "utf8")));
  } catch (error) {
    if (nodeErrorCode(error) !== "ENOENT") throw error;
  }
  if (!stored.some((item) => item.token === pending.token)) stored.push(pending);
  writeReplacementHandoff(stored);
}

function clearReplacementHandoff(pending: PendingActionableClose): void {
  try {
    const stored = validateReplacementHandoff(JSON.parse(readFileSync(actionableHandoff, "utf8")));
    const remaining = stored.filter((item) => item.token !== pending.token);
    if (remaining.length === stored.length) return;
    if (remaining.length > 0) {
      writeReplacementHandoff(remaining);
    } else {
      replacementHandoff = null;
      unlinkSync(actionableHandoff);
    }
  } catch (error) {
    if (nodeErrorCode(error) !== "ENOENT") throw error;
  }
}

// The marker every failure text in this extension embeds (header contract).
function isUrgentSupervisionFailure(message: string): boolean {
  return message.includes("watcher: FAILED");
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

function createGeneration(): SessionGeneration {
  return {
    id: ++nextGenerationId,
    stopping: false,
    replacement: false,
    child: null,
    retryTimer: null,
    cleanupTimer: null,
    retryFailures: 0,
    restoring: false,
    seq: 0,
    pendingActionables: [],
    cleanupFailure: "",
    unconsumedWakes: new Map(),
    deferredClose: null,
    pendingOrdinaryWakeRow: false,
  };
}

function activateGeneration(generation: SessionGeneration): void {
  activeGeneration = generation;
}

function generationIsLive(generation: SessionGeneration): boolean {
  return activeGeneration === generation && !generation.stopping;
}

function stopGeneration(generation: SessionGeneration): ChildProcess | null {
  generation.stopping = true;
  if (generation.retryTimer) clearTimeout(generation.retryTimer);
  if (generation.cleanupTimer) clearTimeout(generation.cleanupTimer);
  generation.retryTimer = null;
  generation.cleanupTimer = null;
  const child = generation.child;
  if (child) child.kill("SIGTERM");
  generation.child = null;
  return child;
}

async function waitForGenerationChildClose(armChild: ChildProcess | null): Promise<void> {
  if (!armChild) return;
  const closed = armClose.get(armChild);
  if (!closed) return;
  await new Promise<void>((resolveWait) => {
    const timer = setTimeout(resolveWait, armRetireTimeoutMs);
    void closed.then(() => {
      clearTimeout(timer);
      resolveWait();
    });
  });
}

async function stopSessionGeneration(generation: SessionGeneration, replacement: boolean): Promise<void> {
  generation.replacement = replacement;
  let persistedTokens = "";
  try {
    if (replacement && generation.pendingActionables.length > 0) {
      persistReplacementHandoff(generation.pendingActionables);
      persistedTokens = generation.pendingActionables.map((pending) => pending.token).join("\n");
    }
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    for (const pending of generation.pendingActionables) {
      if (replacementCoordinator.pending.some((item) => item.token === pending.token)) continue;
      replacementCoordinator.pending.push({
        ...pending,
        message: `${pending.message}\n\nwatcher: FAILED - Pi extension could not persist a replacement-session actionable wake\n${detail}`,
      });
    }
    throw error;
  } finally {
    const child = stopGeneration(generation);
    await waitForGenerationChildClose(child);
  }
  const currentTokens = generation.pendingActionables.map((pending) => pending.token).join("\n");
  if (replacement && currentTokens && currentTokens !== persistedTokens) {
    persistReplacementHandoff(generation.pendingActionables);
  }
}

const cleanupOnProcessExit = () => {
  if (activeGeneration) stopGeneration(activeGeneration);
};
process.once("exit", cleanupOnProcessExit);

export default function (pi: ExtensionAPI) {
  let generation = createGeneration();
  activateGeneration(generation);

  let calmPresentation: CalmPresentationState = {
    active: false,
    stockExportRendering: false,
  };
  pi.events?.on?.(FIRSTMATE_CALM_PRESENTATION_EVENT, (data) => {
    const next = data as Partial<CalmPresentationState>;
    calmPresentation = {
      active: next.active === true,
      stockExportRendering: next.stockExportRendering === true,
    };
  });
  const calmHides = (itemClass: Parameters<typeof calmTranscriptClassIsVisible>[0]): boolean =>
    calmPresentation.active &&
    !calmPresentation.stockExportRendering &&
    !calmTranscriptClassIsVisible(itemClass);

  async function sendWake(
    owner: SessionGeneration,
    message: string,
    presentation: WakePresentation,
    pending?: PendingActionableClose,
  ): Promise<boolean> {
    if (!generationIsLive(owner)) return false;
    const urgent = presentation === "urgent" || isUrgentSupervisionFailure(message);
    // The already-pending row directs the model to drain the durable queue, so
    // this event is presented by that row; its durable record is untouched.
    if (!urgent && owner.pendingOrdinaryWakeRow) return true;
    const content = encodeFirstmateOperationalInput(
      "watcher",
      `FIRSTMATE WATCHER WAKE: ${message}\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.`,
    );
    if (pending) owner.unconsumedWakes.set(pending.token, { content, pending });
    if (!urgent) owner.pendingOrdinaryWakeRow = true;
    try {
      await pi.sendUserMessage(content, { deliverAs: "followUp" });
    } catch (error) {
      if (pending) owner.unconsumedWakes.delete(pending.token);
      // Delivery rejected before a row existed, so release the latch rather
      // than suppressing every later ordinary wake behind a row that is not
      // there, then let the caller handle the failure as it already does.
      if (!urgent) owner.pendingOrdinaryWakeRow = false;
      throw error;
    }
    // Accepted by Pi. A generation replaced while Pi was accepting it may
    // have lost the follow-up with the old session, so report it undelivered
    // and let the replacement replay the still-pending record.
    return generationIsLive(owner);
  }

  // Pi consumed a main follow-up: an idle main at before_agent_start, a
  // streaming main at the user message_start that joins the running run.
  function consumeWake(owner: SessionGeneration, text: string): void {
    for (const [token, wake] of owner.unconsumedWakes) {
      if (wake.content !== text) continue;
      owner.unconsumedWakes.delete(token);
      wake.pending.delivered = true;
      try {
        finishPendingActionable(owner, wake.pending);
      } catch (error) {
        surfaceCleanupFailure(owner, error);
        schedulePendingCleanup(owner);
      }
      return;
    }
  }

  function confirmHandlingDelivery(recovery: { generation: string; watcherPid: string }): {
    ok: boolean;
    detail: string;
  } {
    try {
      const result = spawnSync(
        "bash",
        [armScript, "--handling-delivered", recovery.generation, "--watcher-pid", recovery.watcherPid],
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
        detail: `watcher: FAILED - handling delivery confirmation was rejected (status=${result.status ?? "none"} generation=${recovery.generation} watcherPid=${recovery.watcherPid})${stderr ? `\n${stderr}` : ""}`,
      };
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return {
        ok: false,
        detail: `watcher: FAILED - handling delivery confirmation could not be executed (generation=${recovery.generation} watcherPid=${recovery.watcherPid})\n${message}`,
      };
    }
  }

  function confirmHandlingDeliveryWithRetry(
    owner: SessionGeneration,
    recovery: { generation: string; watcherPid: string },
  ): { ok: boolean; detail: string } {
    const snapshot = (): { generation: string; watcherPid: string } => {
      const current = owner.child ? armRecovery.get(owner.child) : undefined;
      return current ?? recovery;
    };
    const first = confirmHandlingDelivery(snapshot());
    if (first.ok) return first;
    return confirmHandlingDelivery(snapshot());
  }

  function offerWakeToBranch(message: string): Promise<void> | null {
    const heartbeat = /^heartbeat($|:)/.test(message);
    // A check-kind close (merge-confirmation polls, Relay mentions,
    // credential/auth failures, and every other legitimately main-only
    // class - docs/pi-supervision-branch.md) is never routed to the branch
    // even when other currently-unread rows are individually eligible: this
    // watcher cycle's own triggering event stays on main, exactly as before
    // scopeForUnreadWake stopped letting a co-present check row veto the
    // whole scan. That relaxation is what lets an UNRELATED eligible
    // signal/stale row still reach the branch on this cycle; it must never
    // also let a check-kind trigger itself slip past main's delivery.
    const isCheckTrigger = /^check:/.test(message);
    const scope = scopeForUnreadWake(state, heartbeat);
    const eligible = !isCheckTrigger && scope.eligible;
    const offer = createBranchDispatchOffer(message, scope.projects, heartbeat, eligible);
    pi.events?.emit?.(FM_BRANCH_DISPATCH_EVENT, offer);
    return offer.accepted ? offer.settlement : null;
  }

  async function deliverActionableWake(
    owner: SessionGeneration,
    message: string,
    repairFailed: boolean,
    pending: PendingActionableClose,
    recovery?: { generation: string; watcherPid: string },
  ): Promise<boolean> {
    if (!generationIsLive(owner)) return false;
    if (recovery) {
      const confirmed = confirmHandlingDeliveryWithRetry(owner, recovery);
      if (!confirmed.ok) {
        const watcherPid = recovery.watcherPid;
        if (!pidAlive(watcherPid)) {
          await retireArm(owner.child);
        }
        return await sendWake(owner, `${message}\n\n${confirmed.detail}`, "urgent", pending);
      }
    }
    if (!repairFailed) {
      const branchDelivery = offerWakeToBranch(message);
      if (branchDelivery) {
        try {
          await branchDelivery;
          return true;
        } catch {}
      }
    }
    return await sendWake(owner, message, "ordinary", pending);
  }

  function surfaceFailure(owner: SessionGeneration, message: string): void {
    void sendWake(owner, message, "urgent").catch(() => {
      // Pi owns delivery errors; continuity restoration never waits on prompting.
    });
  }

  function enqueuePendingActionable(
    owner: SessionGeneration,
    pending: PendingActionableClose,
  ): void {
    if (owner.pendingActionables.some((item) => item.token === pending.token)) return;
    owner.pendingActionables.push(pending);
    if (owner.stopping && owner.replacement) {
      let replacementPending = pending;
      try {
        mergeReplacementHandoff(pending);
      } catch (error) {
        const detail = error instanceof Error ? error.message : String(error);
        replacementPending = {
          ...pending,
          message: `${pending.message}\n\nwatcher: FAILED - Pi extension could not persist a late replacement-session actionable wake\n${detail}`,
        };
      }
      if (replacementCoordinator.receiver) {
        replacementCoordinator.receiver(replacementPending);
      } else if (replacementPending !== pending) {
        replacementCoordinator.pending.push(replacementPending);
      }
    }
  }

  function finishPendingActionable(owner: SessionGeneration, pending: PendingActionableClose): void {
    clearReplacementHandoff(pending);
    const index = owner.pendingActionables.findIndex((item) => item.token === pending.token);
    if (index >= 0) owner.pendingActionables.splice(index, 1);
    owner.cleanupFailure = "";
  }

  function surfaceCleanupFailure(
    owner: SessionGeneration,
    error: unknown,
  ): void {
    const detail = error instanceof Error ? error.message : String(error);
    if (owner.cleanupFailure === detail) return;
    owner.cleanupFailure = detail;
    surfaceFailure(owner, `watcher: FAILED - Pi extension could not clear a delivered replacement-session actionable wake\n${detail}`);
  }

  function schedulePendingCleanup(owner: SessionGeneration): void {
    if (!generationIsLive(owner) || owner.cleanupTimer) return;
    const timer = setTimeout(() => {
      if (owner.cleanupTimer === timer) owner.cleanupTimer = null;
      void processPendingActionables(owner);
    }, retryDelay(1));
    timer.unref();
    owner.cleanupTimer = timer;
  }

  async function processPendingActionables(owner: SessionGeneration): Promise<void> {
    if (!generationIsLive(owner) || owner.restoring || owner.pendingActionables.length === 0) return;
    owner.restoring = true;
    const attemptedCleanup = new Set<string>();
    try {
      while (generationIsLive(owner) && owner.pendingActionables.length > 0) {
        for (const delivered of owner.pendingActionables.filter((item) => item.delivered && !attemptedCleanup.has(item.token))) {
          attemptedCleanup.add(delivered.token);
          try {
            finishPendingActionable(owner, delivered);
          } catch (error) {
            surfaceCleanupFailure(owner, error);
          }
        }
        // A record Pi has accepted but not consumed is neither redelivered
        // nor finished here: consumption finishes it, replacement replays it.
        const pending = owner.pendingActionables.find(
          (item) => !item.delivered && !owner.unconsumedWakes.has(item.token),
        );
        if (!pending) break;
        const existingClaim = replacementCoordinator.deliveries.get(pending.token);
        if (existingClaim && existingClaim.owner !== owner) {
          const settlement = await existingClaim.settlement;
          if (!generationIsLive(owner)) return;
          if (settlement === "delivered") {
            pending.delivered = true;
            continue;
          }
          if (replacementCoordinator.deliveries.get(pending.token) === existingClaim) {
            replacementCoordinator.deliveries.delete(pending.token);
          }
        }
        let settleClaim: (settlement: "delivered" | "failed") => void = () => {};
        const settlement = new Promise<"delivered" | "failed">((resolveSettlement) => {
          settleClaim = resolveSettlement;
        });
        const deliveryClaim = { owner, settlement };
        replacementCoordinator.deliveries.set(pending.token, deliveryClaim);
        const releaseClaim = (): void => {
          if (replacementCoordinator.deliveries.get(pending.token) === deliveryClaim) {
            replacementCoordinator.deliveries.delete(pending.token);
          }
        };
        try {
          // A new restoration supersedes whatever became of the previous
          // successor; only a failure during this delivery is retried after it.
          owner.deferredClose = null;
          const restoration = await restoreAfterActionableClose(owner, pending.predecessorArmPid);
          if (!generationIsLive(owner)) {
            settleClaim("failed");
            releaseClaim();
            return;
          }
          const message = restoration.failure ? `${pending.message}\n\n${restoration.failure}` : pending.message;
          const delivered = await deliverActionableWake(owner, message, Boolean(restoration.failure), pending, restoration.recovery);
          if (!delivered) {
            settleClaim("failed");
            releaseClaim();
            return;
          }
          const awaitingConsumption = owner.unconsumedWakes.has(pending.token);
          if (awaitingConsumption && !generationIsLive(owner)) {
            // Pi accepted the follow-up, then the session was replaced before
            // this continuation ran: the shutdown persisted the still-pending
            // record, so a replacement waiting on this claim must replay it.
            settleClaim("failed");
            releaseClaim();
            return;
          }
          settleClaim("delivered");
          if (!awaitingConsumption) {
            // The branch handled it, or Pi consumed it before this ran.
            pending.delivered = true;
            try {
              finishPendingActionable(owner, pending);
            } catch (error) {
              surfaceCleanupFailure(owner, error);
            }
          }
          releaseClaim();
        } catch (error) {
          settleClaim("failed");
          releaseClaim();
          throw error;
        }
      }
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      surfaceFailure(owner, `watcher: FAILED - Pi extension could not deliver an actionable wake\n${detail}`);
    } finally {
      if (generationIsLive(owner)) {
        owner.restoring = false;
        if (owner.pendingActionables.some((pending) => pending.delivered)) schedulePendingCleanup(owner);
        // No bare arm is launched here. A generation without a child at this
        // point has either delivered a typed restoration failure after its
        // bounded retries, which hands repair to main through fm_watch_arm_pi
        // (one more silent launch past the bound could hold a hung child that
        // the repair call would then report as "unchanged"), or lost a
        // verified successor during the delivery, which takes the ordinary
        // bounded, lock-checked retry it would have taken had the pipeline
        // been idle.
        const deferred = owner.deferredClose;
        owner.deferredClose = null;
        if (deferred && !owner.child && !owner.retryTimer) {
          scheduleRetry(owner, deferred.message, deferred.predecessorArmPid);
        }
      }
    }
  }

  const receiveReplacementActionable: ReplacementActionableReceiver = (pending) => {
    if (!generationIsLive(generation)) return;
    enqueuePendingActionable(generation, pending);
    void processPendingActionables(generation);
  };

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
    armRetired.add(armChild);
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

  async function restoreAfterActionableClose(owner: SessionGeneration, predecessorArmPid: string): Promise<{
    failure: string;
    recovery?: { generation: string; watcherPid: string };
  }> {
    let failure = "";
    for (let attempt = 0; attempt <= retryLimit; attempt += 1) {
      if (!generationIsLive(owner)) return { failure: "" };
      const replacement = startArm(owner, predecessorArmPid);
      const successorChild = owner.child;
      if (replacement.ok && successorChild && await waitForReadiness(successorChild)) {
        return { failure: "", recovery: armRecovery.get(successorChild) };
      }
      if (replacement.ok) {
        failure = "watcher: FAILED - Pi extension could not verify a ready successor watcher";
        if (!(await retireArm(successorChild))) {
          return {
            failure: `${failure}\nwatcher: FAILED - Pi extension could not restore watcher continuity because the unready successor arm did not exit within ${armRetireTimeoutMs}ms`,
          };
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
    return { failure: `${failure}\nwatcher: FAILED - Pi extension could not restore watcher continuity after ${retryLimit} retries` };
  }

  function scheduleRetry(owner: SessionGeneration, message: string, predecessorArmPid: string): void {
    if (!generationIsLive(owner) || owner.child || owner.retryTimer) return;
    const ownership = lockOwnership();
    if (ownership !== "owned") {
      surfaceFailure(owner, `watcher: FAILED - Pi extension cannot restore continuity because this session no longer owns the lock\n${message}`);
      return;
    }
    owner.retryFailures += 1;
    if (owner.retryFailures > retryLimit) {
      surfaceFailure(owner, `watcher: FAILED - Pi extension could not restore watcher continuity after ${retryLimit} retries\n${message}`);
      return;
    }
    const timer = setTimeout(() => {
      if (owner.retryTimer === timer) owner.retryTimer = null;
      if (!generationIsLive(owner)) return;
      const result = startArm(owner, predecessorArmPid);
      if (!result.ok) {
        surfaceFailure(owner, `watcher: FAILED - Pi extension could not launch a continuity retry\n${result.message}`);
      }
    }, retryDelay(owner.retryFailures));
    timer.unref();
    owner.retryTimer = timer;
  }

  function startArm(owner: SessionGeneration, predecessorArmPid = ""): ArmResult {
    if (!generationIsLive(owner)) return { ok: false, message: shuttingDownMessage };
    const ownership = lockOwnership();
    if (ownership === "other") return { ok: false, message: "watcher: read-only - session lock is held by another firstmate session" };
    if (ownership === "missing") {
      return {
        ok: false,
        message: "watcher: not armed - no live session holds the lock; run bin/fm-session-start.sh to reclaim it, then call fm_watch_arm_pi to re-arm",
      };
    }
    markLoaded();
    if (owner.child) {
      return {
        ok: true,
        message: `watcher: unchanged - Pi extension already owns an arm child; no manual re-arm needed; ${repairOnlyHint}`,
      };
    }
    if (owner.retryTimer) {
      return {
        ok: true,
        message: `watcher: unchanged - Pi extension already owns a scheduled continuity retry; no manual re-arm needed; ${repairOnlyHint}`,
      };
    }
    const id = ++owner.seq;
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
    owner.child = armChild;
    let stdout = "";
    let stderr = "";
    let settled = false;
    let readinessSettled = false;
    let verified = false;
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
      verified = ready;
      resolveReadiness(ready);
    };
    const observeEstablishedArm = (): void => {
      const combined = `${stdout}\n${stderr}`;
      const recovery = combined.match(/^watcher: started pid=([0-9]+).* recovery-generation=([A-Za-z0-9._-]+)$/m);
      if (recovery) armRecovery.set(armChild, { watcherPid: recovery[1], generation: recovery[2] });
      if (/^watcher: (?:started|attached)\b/m.test(combined)) {
        settleReadiness(true);
      }
      const reason = completedActionableLine(stdout) || completedActionableLine(stderr);
      if (reason && !armPendingActionable.has(armChild)) {
        const pending = createPendingActionable(reason, String(armChild.pid ?? ""));
        armPendingActionable.set(armChild, pending);
        enqueuePendingActionable(owner, pending);
      }
    };
    const releaseChild = (): void => {
      if (owner.child === armChild) owner.child = null;
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
      const classification = classifyClose(stdout, stderr, code, signal);
      const predecessor = String(armChild.pid ?? "");
      if (classification.kind === "actionable") {
        const pending = armPendingActionable.get(armChild) ?? createPendingActionable(classification.message, predecessor);
        enqueuePendingActionable(owner, pending);
        if (!generationIsLive(owner)) return;
        owner.retryFailures = 0;
        void processPendingActionables(owner);
        return;
      }
      if (!generationIsLive(owner)) return;
      if (owner.restoring) {
        // The pipeline is still delivering the wake this successor was
        // started for. A verified successor that failed on its own keeps its
        // bounded retry for the end of that delivery; an unready child closing
        // here was retired by the restoration itself.
        if (verified && !armRetired.has(armChild)) {
          owner.deferredClose = { message: classification.message, predecessorArmPid: predecessor };
        }
        return;
      }
      scheduleRetry(owner, classification.message, predecessor);
    });
    armChild.on("error", (error: Error) => {
      if (settled) return;
      settled = true;
      resolveClosed();
      settleReadiness(false);
      releaseChild();
      if (!generationIsLive(owner)) return;
      if (owner.restoring) return;
      scheduleRetry(owner, `watcher: FAILED - Pi extension arm child ${id} failed: ${error.message}`, String(armChild.pid ?? ""));
    });
    return {
      ok: true,
      message: `watcher: started Pi extension arm child ${id}; future ordinary re-arms are automatic; ${repairOnlyHint}`,
    };
  }

  function activateOwnedWatch(owner: SessionGeneration): ArmResult {
    if (!generationIsLive(owner)) return { ok: false, message: shuttingDownMessage };
    if (lockOwnership() !== "owned") return startArm(owner);
    replacementCoordinator.receiver = receiveReplacementActionable;
    let pending: PendingActionableClose[] = [];
    let loadFailure = "";
    try {
      pending = loadReplacementHandoff();
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      loadFailure = `watcher: FAILED - Pi extension could not load a replacement-session actionable wake\n${detail}`;
    }
    const inProcessPending = replacementCoordinator.pending.splice(0);
    for (const actionable of [...pending, ...inProcessPending]) {
      enqueuePendingActionable(owner, actionable);
    }
    if (owner.pendingActionables.length > 0) {
      if (loadFailure) surfaceFailure(owner, loadFailure);
      const armResult = startArm(owner, owner.pendingActionables[0].predecessorArmPid);
      if (!armResult.ok) {
        surfaceFailure(owner, `watcher: FAILED - Pi extension could not arm before replacement wake delivery\n${armResult.message}`);
      }
      void processPendingActionables(owner);
      return armResult;
    }
    const result = startArm(owner);
    if (loadFailure) surfaceFailure(owner, `${loadFailure}\n${result.message}`);
    return result;
  }

  pi.on?.("before_agent_start", (event) => {
    consumeWake(generation, event.prompt);
  });
  pi.on?.("message_start", (event) => {
    if (event.message.role !== "user") return;
    consumeWake(generation, userMessageText(event.message.content));
  });

  pi.on?.("session_start", async () => {
    if (generation.stopping) generation = createGeneration();
    activateGeneration(generation);
    markLoaded();
    if (lockOwnership() !== "owned") return;
    activateOwnedWatch(generation);
  });
  pi.on?.("session_shutdown", async (event) => {
    const replacement = event.reason === "reload" || event.reason === "new" || event.reason === "resume" || event.reason === "fork";
    if (replacementCoordinator.receiver === receiveReplacementActionable) replacementCoordinator.receiver = null;
    await stopSessionGeneration(generation, replacement);
  });
  // The idle-path consumption edge: a run that takes a pending row begins by
  // emitting this, so presentation re-arms at run start rather than at run end.
  pi.on?.("agent_start", () => {
    generation.pendingOrdinaryWakeRow = false;
  });
  // The settle boundary: a row drained inline by a busy run, or discarded when
  // a run is aborted, produces no further agent_start, so this is what keeps
  // the latch from outliving the run that consumed or dropped the row.
  pi.on?.("agent_settled", () => {
    generation.pendingOrdinaryWakeRow = false;
  });

  pi.registerCommand?.("fm-watch-arm-pi", {
    description: "Arm firstmate watcher supervision through the Pi extension instead of foreground bash.",
    handler: async (_args, ctx) => {
      const result = activateOwnedWatch(generation);
      ctx.ui.notify(result.message, result.ok ? "info" : "warning");
    },
  });

  pi.registerTool?.({
    name: "fm_watch_arm_pi",
    label: "Arm firstmate watcher",
    description: "Start the first required Pi watcher cycle, or repair one only after a notification says the cycle is missing, failed, or unhealthy. Do not call after ordinary work or ordinary notifications; the Pi extension re-arms automatically. Never run bin/fm-watch-arm.sh through bash.",
    promptSnippet: "Start the first required Pi watcher cycle or repair a cycle reported missing, failed, or unhealthy; ordinary re-arming is automatic.",
    promptGuidelines: [
      "Call fm_watch_arm_pi only for the first required cycle or after a notification says the cycle is missing, failed, or unhealthy. Do not call it after ordinary work, turn completion, or ordinary signal, stale, check, or heartbeat handling because the Pi extension owns re-arming. Never run bin/fm-watch-arm.sh through bash.",
    ],
    parameters: Type.Object({}),
    renderShell: "self",
    renderCall: (_args, theme, context) => {
      if (calmHides("assistant-tool-call")) return new Container();
      if (calmPresentation.stockExportRendering) {
        return new Text(theme.fg("toolTitle", theme.bold("fm_watch_arm_pi")), 0, 0);
      }
      const state = context.state as WatchToolShellState;
      state.call = new Text(theme.fg("toolTitle", theme.bold("fm_watch_arm_pi")), 0, 0);
      return refreshWatchToolShell(state, theme, context);
    },
    renderResult: (result, _options, theme, context) => {
      if (calmHides("tool-result")) return new Container();
      const output = result.content
        .filter((item) => item.type === "text")
        .map((item) => item.text)
        .join("\n");
      if (calmPresentation.stockExportRendering) {
        return new Text(theme.fg("toolOutput", output), 0, 0);
      }
      const state = context.state as WatchToolShellState;
      state.result = output
        ? new Text(theme.fg("toolOutput", output), 0, 0)
        : new Container();
      refreshWatchToolShell(state, theme, context);
      return new Container();
    },
    execute: async () => {
      const result = activateOwnedWatch(generation);
      return {
        content: [{ type: "text", text: result.message }],
        details: result,
      };
    },
  });

  markLoaded();
}
