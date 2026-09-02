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
import { lstatSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
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

type WakeTicket = {
  seq: number;
  kind: "signal" | "stale" | "check" | "heartbeat";
  keyHex: string;
  scope: "task" | "global";
  task: string;
  spawn: string;
};

type CloseClassification = {
  kind: "actionable" | "failure";
  message: string;
  tickets: WakeTicket[];
};

type PendingClose = {
  classification: CloseClassification;
  predecessorArmPid: string;
};

type WakeQueueRow = {
  seq: number;
  kind: WakeTicket["kind"];
  key: string;
  payload: string;
};

type DeliveryRevalidation = {
  status: "deliver" | "obsolete" | "unknown";
  message: string;
  identities: string[];
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
  pendingCloses: PendingClose[];
  deliveryClaims: Set<string>;
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
const establishedArmChildren = new WeakSet<ChildProcess>();
const expectedArmRetirements = new WeakSet<ChildProcess>();

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

function wakeTickets(output: string): WakeTicket[] {
  const tickets: WakeTicket[] = [];
  const seen = new Set<string>();
  for (const line of output.split(/\r?\n/)) {
    const match = /^firstmate-wake-ticket: v1 seq=([1-9][0-9]*) kind=(signal|stale|check|heartbeat) key=([0-9a-f]+) scope=(task|global) task=(-|[A-Za-z0-9._-]+) spawn=(-|[A-Za-z0-9._-]+)$/.exec(line);
    if (!match) continue;
    const seq = Number(match[1]);
    if (!Number.isSafeInteger(seq)) continue;
    if (match[5] !== "-" && (match[5].startsWith(".") || match[5].length > 64)) continue;
    if (match[6] !== "-" && match[6].startsWith(".")) continue;
    const identity = `${seq}:${match[2]}:${match[3]}`;
    if (seen.has(identity)) continue;
    seen.add(identity);
    tickets.push({
      seq,
      kind: match[2] as WakeTicket["kind"],
      keyHex: match[3],
      scope: match[4] as WakeTicket["scope"],
      task: match[5],
      spawn: match[6],
    });
  }
  return tickets;
}

function classifyClose(stdout: string, stderr: string, code: number | null, signal: NodeJS.Signals | null): CloseClassification {
  const combined = `${stdout}\n${stderr}`.trim();
  const tickets = wakeTickets(combined);
  const reason = actionableLine(combined);
  if (reason) return { kind: "actionable", message: reason, tickets };
  const healthy = combined.split(/\r?\n/).find((line) => /^watcher: healthy\b/.test(line));
  if (healthy) {
    return {
      kind: "failure",
      message: `watcher: FAILED - Pi extension arm child found an external healthy watcher instead of owning wake delivery\n${healthy}`,
      tickets: [],
    };
  }
  const failed = combined.split(/\r?\n/).find((line) => /^watcher: FAILED/.test(line));
  if (failed) return { kind: "failure", message: failed, tickets: [] };
  if (signal) {
    return {
      kind: "failure",
      message: `watcher: FAILED - Pi extension arm child ended from ${signal}${combined ? `\n${combined}` : ""}`,
      tickets: [],
    };
  }
  if (code && code !== 0) {
    return {
      kind: "failure",
      message: `watcher: FAILED - fm-watch-arm.sh exited ${code}${combined ? `\n${combined}` : ""}`,
      tickets: [],
    };
  }
  return {
    kind: "failure",
    message: "watcher: FAILED - Pi extension arm cycle ended without an actionable reason",
    tickets: [],
  };
}

type StateFileRead =
  | { status: "ok"; content: string }
  | { status: "absent" }
  | { status: "invalid" };

function readRegularStateFile(path: string): StateFileRead {
  try {
    const info = lstatSync(path);
    if (!info.isFile() || info.isSymbolicLink()) return { status: "invalid" };
    return { status: "ok", content: readFileSync(path, "utf8") };
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return { status: "absent" };
    return { status: "invalid" };
  }
}

function statePathExists(path: string): boolean {
  try {
    lstatSync(path);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code !== "ENOENT";
  }
}

function parseWakeQueue(content: string): WakeQueueRow[] | null {
  const rows: WakeQueueRow[] = [];
  const seen = new Set<number>();
  for (const line of content.split(/\r?\n/)) {
    if (!line) continue;
    const fields = line.split("\t");
    if (fields.length < 5 || !/^[0-9]+$/.test(fields[1])) return null;
    const seq = Number(fields[1]);
    const kind = fields[2];
    if (!Number.isSafeInteger(seq) || seen.has(seq) || !/^(signal|stale|check|heartbeat)$/.test(kind)) return null;
    seen.add(seq);
    rows.push({
      seq,
      kind: kind as WakeQueueRow["kind"],
      key: fields[3],
      payload: fields.slice(4).join("\t"),
    });
  }
  return rows;
}

function readSequenceReceipt(path: string): Set<number> | null {
  const file = readRegularStateFile(path);
  if (file.status === "absent") return new Set<number>();
  if (file.status !== "ok") return null;
  const claimed = new Set<number>();
  for (const line of file.content.split(/\r?\n/)) {
    if (!line) continue;
    if (!/^[0-9]+$/.test(line)) return null;
    const seq = Number(line);
    if (!Number.isSafeInteger(seq) || claimed.has(seq)) return null;
    claimed.add(seq);
  }
  return claimed;
}

function metadataValues(content: string, key: string): string[] {
  return content
    .split(/\r?\n/)
    .filter((line) => line.startsWith(`${key}=`))
    .map((line) => line.slice(key.length + 1));
}

function taskTicketStatus(ticket: WakeTicket, row: WakeQueueRow): "current" | "obsolete" | "unknown" {
  if (ticket.scope === "global") return "current";
  // Status and turn-end rows may carry the only durable decision, failure, or
  // terminal result left after cleanup. Their exact queue identity still
  // coalesces and invalidates a handled row, but metadata disappearance never
  // makes their unseen content obsolete.
  if (ticket.kind === "signal") {
    if (ticket.task === "-") return "unknown";
    return row.key === `${ticket.task}.status` || row.key === `${ticket.task}.turn-ended`
      ? "current"
      : "unknown";
  }
  if (ticket.task === "-") return "unknown";
  const meta = readRegularStateFile(`${state}/${ticket.task}.meta`);
  if (meta.status === "absent") return "obsolete";
  if (meta.status !== "ok") return "unknown";

  const spawnValues = metadataValues(meta.content, "spawn_gen");
  if (ticket.spawn === "-") {
    return "unknown";
  } else if (ticket.spawn === "legacy") {
    if (spawnValues.length === 1 && /^[A-Za-z0-9._-]+$/.test(spawnValues[0])) return "obsolete";
    if (spawnValues.length !== 0) return "unknown";
  } else {
    if (spawnValues.length === 0) return "obsolete";
    if (spawnValues.length !== 1 || !/^[A-Za-z0-9._-]+$/.test(spawnValues[0])) return "unknown";
    if (spawnValues[0] !== ticket.spawn) return "obsolete";
  }

  if (ticket.kind === "stale") {
    const windows = metadataValues(meta.content, "window");
    const terminals = metadataValues(meta.content, "terminal");
    const targets = [...windows.slice(-1), ...terminals.slice(-1)].filter(Boolean);
    if (targets.length === 0) return "unknown";
    return targets.includes(row.key) ? "current" : "obsolete";
  }
  return "current";
}

function wakeDedupeIdentity(row: WakeQueueRow): string {
  return row.kind === "heartbeat" ? "heartbeat" : `${row.kind}\u0000${row.key}`;
}

function ticketIdentity(ticket: WakeTicket): string {
  return `${ticket.seq}:${ticket.kind}:${ticket.keyHex}`;
}

function revalidateWakeDelivery(
  owner: SessionGeneration,
  message: string,
  tickets: readonly WakeTicket[],
): DeliveryRevalidation {
  if (tickets.length === 0) return { status: "deliver", message, identities: [] };
  const identities = tickets.map(ticketIdentity);
  if (statePathExists(`${state}/.wake-queue.lock`)) {
    return { status: "unknown", message, identities };
  }
  const queueFile = readRegularStateFile(`${state}/.wake-queue`);
  if (queueFile.status !== "ok") return { status: "unknown", message, identities };
  const rows = parseWakeQueue(queueFile.content);
  const mainPresented = readSequenceReceipt(`${state}/.main-presented-rows`);
  const branchPresented = readSequenceReceipt(`${state}/.branch-presented-rows`);
  if (!rows || !mainPresented || !branchPresented || statePathExists(`${state}/.wake-queue.lock`)) {
    return { status: "unknown", message, identities };
  }
  const presented = new Set([...mainPresented, ...branchPresented]);
  const bySequence = new Map(rows.map((row) => [row.seq, row]));
  const newest = new Map<string, number>();
  for (const row of rows) {
    const key = wakeDedupeIdentity(row);
    newest.set(key, Math.max(newest.get(key) ?? 0, row.seq));
  }

  const current: Array<{ ticket: WakeTicket; row: WakeQueueRow }> = [];
  let uncertain = false;
  for (const ticket of tickets) {
    const identity = ticketIdentity(ticket);
    if (owner.deliveryClaims.has(identity)) continue;
    const row = bySequence.get(ticket.seq);
    if (!row) continue;
    if (row.kind !== ticket.kind || Buffer.from(row.key, "utf8").toString("hex") !== ticket.keyHex) {
      uncertain = true;
      continue;
    }
    if (presented.has(ticket.seq)) continue;
    if ((newest.get(wakeDedupeIdentity(row)) ?? row.seq) > row.seq) continue;
    const taskStatus = taskTicketStatus(ticket, row);
    if (taskStatus === "unknown") {
      uncertain = true;
      continue;
    }
    if (taskStatus === "current") current.push({ ticket, row });
  }
  if (uncertain) return { status: "unknown", message, identities };
  if (current.length === 0) return { status: "obsolete", message: "", identities: [] };

  const latest = current.reduce((left, right) => left.row.seq > right.row.seq ? left : right);
  const allCurrent = current.length === tickets.length;
  const currentMessage = allCurrent
    ? message
    : latest.row.kind === "signal"
      ? "signal: current task event is waiting"
      : latest.row.payload || message;
  return {
    status: "deliver",
    message: currentMessage,
    identities: current.map(({ ticket }) => ticketIdentity(ticket)),
  };
}

async function revalidateWakeDeliveryAfterQueueMutation(
  owner: SessionGeneration,
  message: string,
  tickets: readonly WakeTicket[],
): Promise<DeliveryRevalidation> {
  let delivery = revalidateWakeDelivery(owner, message, tickets);
  for (let attempt = 0; attempt < 25; attempt += 1) {
    if (delivery.status !== "unknown") return delivery;
    if (!statePathExists(`${state}/.wake-queue.lock`)) {
      return revalidateWakeDelivery(owner, message, tickets);
    }
    await new Promise<void>((resolveWait) => {
      const timer = setTimeout(resolveWait, 20);
      timer.unref();
    });
    if (!generationIsLive(owner)) return { status: "obsolete", message: "", identities: [] };
    delivery = revalidateWakeDelivery(owner, message, tickets);
  }
  return delivery;
}

function createGeneration(): SessionGeneration {
  return {
    id: ++nextGenerationId,
    stopping: false,
    child: null,
    retryTimer: null,
    retryFailures: 0,
    restoring: false,
    pendingCloses: [],
    deliveryClaims: new Set<string>(),
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
  generation.pendingCloses = [];
  generation.deliveryClaims.clear();
  if (generation.child) generation.child.kill("SIGTERM");
  generation.child = null;
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
  ): Promise<void> {
    if (!generationIsLive(owner)) return;
    const content = encodeFirstmateOperationalInput(
      "watcher",
      `FIRSTMATE WATCHER WAKE: ${message}\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.`,
    );
    await pi.sendUserMessage(content, { deliverAs: "followUp" });
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

  function offerWakeToBranch(message: string): boolean {
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
    return offer.accepted;
  }

  async function deliverActionableWake(
    owner: SessionGeneration,
    message: string,
    tickets: readonly WakeTicket[],
    restorationFailure: string,
    recovery?: { generation: string; watcherPid: string },
  ): Promise<void> {
    if (!generationIsLive(owner)) return;

    // Successor establishment can take seconds. Re-read the exact durable rows
    // only now, immediately before Pi queues a follow-up: a row already printed
    // by either actor, acknowledged, superseded by a newer same-key row, cleaned
    // up, moved to a replacement endpoint, or bound to another spawn generation
    // no longer describes work the captain should see. Read or format uncertainty
    // stays in the safe direction and delivers; only positive obsolescence suppresses.
    const delivery = await revalidateWakeDeliveryAfterQueueMutation(owner, message, tickets);
    if (!generationIsLive(owner)) return;
    const eventMessage = delivery.status === "obsolete" ? "" : delivery.message;
    if (!eventMessage && !restorationFailure) return;
    const finalMessage = [eventMessage, restorationFailure].filter(Boolean).join("\n\n");

    for (const identity of delivery.identities) owner.deliveryClaims.add(identity);
    try {
      if (recovery) {
        const confirmed = confirmHandlingDeliveryWithRetry(owner, recovery);
        if (!confirmed.ok) {
          const watcherPid = recovery.watcherPid;
          if (!pidAlive(watcherPid)) {
            await retireArm(owner.child);
          }
          await sendWake(owner, [eventMessage, restorationFailure, confirmed.detail].filter(Boolean).join("\n\n"));
          return;
        }
      }
      if (!restorationFailure && eventMessage && offerWakeToBranch(eventMessage)) return;
      await sendWake(owner, finalMessage);
    } catch (error) {
      for (const identity of delivery.identities) owner.deliveryClaims.delete(identity);
      throw error;
    }
  }

  function surfaceFailure(owner: SessionGeneration, message: string): void {
    void sendWake(owner, message).catch(() => {
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
    if (!armChild || armChild.exitCode !== null || armChild.signalCode !== null) return true;
    const closed = armClose.get(armChild);
    if (!closed) return false;
    expectedArmRetirements.add(armChild);
    armChild.kill("SIGTERM");
    return new Promise((resolveRetired) => {
      const timer = setTimeout(() => {
        // A child that ignored retirement remains supervision-relevant when it
        // eventually closes; do not leave its late actionable result muted.
        expectedArmRetirements.delete(armChild);
        resolveRetired(false);
      }, armRetireTimeoutMs);
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
      processClassifiedCloses(owner);
    }, retryDelay(owner.retryFailures));
    timer.unref();
    owner.retryTimer = timer;
  }

  function processClassifiedCloses(owner: SessionGeneration): void {
    if (!generationIsLive(owner) || owner.restoring || owner.pendingCloses.length === 0) return;
    owner.restoring = true;
    void (async () => {
      try {
        while (generationIsLive(owner) && owner.pendingCloses.length > 0) {
          const pending = owner.pendingCloses[0];
          if (!pending) break;
          if (pending.classification.kind === "failure") {
            if (owner.child && establishedArmChildren.has(owner.child)) {
              owner.pendingCloses.shift();
              surfaceFailure(owner, pending.classification.message);
              continue;
            }
            // A replacement is still determining whether it is healthy. Keep
            // the failure queued: scheduleRetry deliberately leaves that child
            // alone, so removing its notification here would lose it forever.
            if (owner.child) break;
            owner.pendingCloses.shift();
            scheduleRetry(owner, pending.classification.message, pending.predecessorArmPid);
            break;
          }
          owner.pendingCloses.shift();
          owner.retryFailures = 0;
          const restoration = await restoreAfterActionableClose(owner, pending.predecessorArmPid);
          if (!generationIsLive(owner)) return;
          void deliverActionableWake(
            owner,
            pending.classification.message,
            pending.classification.tickets,
            restoration.failure,
            restoration.recovery,
          ).catch((error) => {
            const detail = error instanceof Error ? error.message : String(error);
            surfaceFailure(owner, `watcher: FAILED - Pi extension could not deliver an actionable wake\n${detail}`);
          });
        }
      } catch (error) {
        const detail = error instanceof Error ? error.message : String(error);
        surfaceFailure(owner, `watcher: FAILED - Pi extension could not deliver an actionable wake\n${detail}`);
      } finally {
        if (generationIsLive(owner)) {
          owner.restoring = false;
          const waitingForSuccessor = owner.pendingCloses[0]?.classification.kind === "failure"
            && !!owner.child
            && !establishedArmChildren.has(owner.child);
          if (!owner.retryTimer && !waitingForSuccessor) processClassifiedCloses(owner);
        }
      }
    })();
  }

  function enqueueClassifiedClose(owner: SessionGeneration, close: PendingClose): void {
    if (!generationIsLive(owner)) return;
    owner.pendingCloses.push(close);
    processClassifiedCloses(owner);
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
      FM_PI_WATCH_DELIVERY: "1",
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
      const combined = `${stdout}\n${stderr}`;
      const recovery = combined.match(/^watcher: started pid=([0-9]+).* recovery-generation=([A-Za-z0-9._-]+)$/m);
      if (recovery) armRecovery.set(armChild, { watcherPid: recovery[1], generation: recovery[2] });
      if (/^watcher: (?:started|attached)\b/m.test(combined)) {
        establishedArmChildren.add(armChild);
        settleReadiness(true);
        processClassifiedCloses(owner);
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
      if (expectedArmRetirements.delete(armChild)) return;
      if (!generationIsLive(owner)) return;
      enqueueClassifiedClose(owner, {
        classification: classifyClose(stdout, stderr, code, signal),
        predecessorArmPid: String(armChild.pid ?? ""),
      });
    });
    armChild.on("error", (error: Error) => {
      if (settled) return;
      settled = true;
      resolveClosed();
      settleReadiness(false);
      releaseChild();
      if (expectedArmRetirements.delete(armChild)) return;
      if (!generationIsLive(owner)) return;
      enqueueClassifiedClose(owner, {
        classification: {
          kind: "failure",
          message: `watcher: FAILED - Pi extension arm child ${id} failed: ${error.message}`,
          tickets: [],
        },
        predecessorArmPid: String(armChild.pid ?? ""),
      });
    });
    return {
      ok: true,
      message: `watcher: started Pi extension arm child ${id}; future ordinary re-arms are automatic; ${repairOnlyHint}`,
    };
  }

  pi.on?.("session_start", () => {
    if (generation.stopping) generation = createGeneration();
    activateGeneration(generation);
    markLoaded();
  });
  pi.on?.("session_shutdown", () => {
    stopGeneration(generation);
  });

  pi.registerCommand?.("fm-watch-arm-pi", {
    description: "Arm firstmate watcher supervision through the Pi extension instead of foreground bash.",
    handler: async (_args, ctx) => {
      const result = startArm(generation);
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
      const result = startArm(generation);
      return {
        content: [{ type: "text", text: result.message }],
        details: result,
      };
    },
  });

  markLoaded();
}
