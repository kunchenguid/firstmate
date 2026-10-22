// Single in-session heartbeat clock; optional full maintenance is default-off.
// Automatic maintenance replaces periodic stow; manual/precompact retain stow.
//
// This extension decides only when one stable run_id may be offered to the
// lock-owning main Pi session. bin/fm-stow-run.sh owns durable run state and the
// existing internal stow skill remains the only owner of memory semantics.
import { spawnSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { existsSync, lstatSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { ContinuationReadbackOffer } from "./lib/fm-task-continuation.ts";
import {
  classifyFirstmateOperationalText,
  encodeFirstmateOperationalInput,
  FIRSTMATE_OWNED_FOLLOWUP_DRAINED_EVENT,
  FIRSTMATE_OWNED_FOLLOWUP_START_EVENT,
  FIRSTMATE_SESSION_START_SETTLED_EVENT,
} from "./lib/fm-operational-input.ts";

type PeriodicConfig = {
  version: 1;
  enabled: boolean;
  interval_seconds: number;
  min_interval_seconds: number;
  enabledAtMs: number;
};

type IdleReminderConfig = {
  version: 1;
  enabled: boolean;
  interval_seconds: number;
  enabledAtMs: number;
};

type IdleReminderRun = {
  id: string;
  answered: boolean;
  inventoryFingerprint: string;
};

type RunState = {
  version: 1;
  revision: number;
  last_success_at: string | null;
  next_due_at: string | null;
  active: null | {
    run_id: string;
    reasons: string[];
    session_id: string;
    session_file: string;
    generation: string | null;
    phase: "requested" | "running" | "partial" | "blocked";
    attempts: number;
    escalation_id?: string | null;
    escalation_generation?: string | null;
    escalation_delivered_at?: string | null;
    cutoff_entry_id: string;
    branch_fingerprint: string;
  };
  outcome?: string;
};

type CoordinatorGeneration = {
  token: string;
  sessionId: string;
  sessionFile: string;
  live: boolean;
  timer: ReturnType<typeof setInterval> | null;
  due: boolean;
  dispatching: boolean;
  lastOfferAt: number;
  submittedEscalations: Set<string>;
  reminderChecking: boolean;
  reminderPendingId: string | null;
  reminderLastHandledAt: number;
  reminderLastHandledEntryId: string | null;
  reminderLastInventoryFingerprint: string | null;
  reminderRetryAfter: number;
  reminderRun: IdleReminderRun | null;
};

const extensionFile = fileURLToPath(import.meta.url);
const root = resolve(dirname(extensionFile), "../..");
const fmHome = resolve(process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root);
const fmRoot = resolve(process.env.FM_ROOT_OVERRIDE || root);
const configFile = `${fmHome}/config/periodic-stow.json`;
const reminderConfigFile = `${fmHome}/config/idle-reminder.json`;
const stateFile = `${fmHome}/state/stow/state.json`;
const runScript = `${fmRoot}/bin/fm-stow-run.sh`;
const lockStatusScript = `${fmRoot}/bin/fm-session-lock-status.sh`;
const bearingsScript = `${fmRoot}/bin/fm-bearings-snapshot.sh`;
const tickMs = positiveInteger(process.env.FM_PERIODIC_STOW_TICK_MS, 60_000);
const reminderMessageType = "fm-idle-reminder-request";
const reminderReceiptType = "fm-idle-reminder-delivered";
const reminderEmptyType = "fm-idle-reminder-empty";
const reminderUnchangedType = "fm-idle-reminder-unchanged";
const reminderFailedType = "fm-idle-reminder-failed";
let activeGeneration: CoordinatorGeneration | null = null;
let activeTools = 0;
let blockingPrompt = false;
let compacting = false;
let ownedFollowups = 0;
let lastConfigurationError = "";
let lastReminderConfigurationError = "";
let lastDispatchError = "";

function positiveInteger(value: string | undefined, fallback: number): number {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}

function readConfig(): { config?: PeriodicConfig; error?: string } {
  if (!existsSync(configFile)) return {};
  try {
    const info = lstatSync(configFile);
    if (info.isSymbolicLink() || !info.isFile()) return { error: "config/periodic-stow.json must be a regular non-symlink file" };
    const raw: unknown = JSON.parse(readFileSync(configFile, "utf8"));
    if (!raw || typeof raw !== "object") return { error: "periodic stow config must be a JSON object" };
    const value = raw as Record<string, unknown>;
    const keys = Object.keys(value).sort().join(",");
    if (keys !== "enabled,interval_seconds,min_interval_seconds,version") {
      return { error: "periodic stow config has unknown or missing fields" };
    }
    if (value.version !== 1 || typeof value.enabled !== "boolean") {
      return { error: "periodic stow config version or enabled value is invalid" };
    }
    const interval = value.interval_seconds;
    const minimum = value.min_interval_seconds;
    if (!Number.isSafeInteger(interval) || !Number.isSafeInteger(minimum) ||
        Number(interval) < 3600 || Number(minimum) < 3600 || Number(interval) < Number(minimum)) {
      return { error: "periodic stow intervals must be safe integers >=3600 with interval >= minimum" };
    }
    return {
      config: {
        version: 1,
        enabled: value.enabled,
        interval_seconds: Number(interval),
        min_interval_seconds: Number(minimum),
        enabledAtMs: info.mtimeMs,
      },
    };
  } catch (error) {
    return { error: `cannot read periodic stow config: ${String(error)}` };
  }
}

function readReminderConfig(): { config?: IdleReminderConfig; error?: string } {
  if (!existsSync(reminderConfigFile)) return {};
  try {
    const info = lstatSync(reminderConfigFile);
    if (info.isSymbolicLink() || !info.isFile()) return { error: "config/idle-reminder.json must be a regular non-symlink file" };
    const raw: unknown = JSON.parse(readFileSync(reminderConfigFile, "utf8"));
    if (!raw || typeof raw !== "object") return { error: "idle reminder config must be a JSON object" };
    const value = raw as Record<string, unknown>;
    if (Object.keys(value).sort().join(",") !== "enabled,interval_seconds,version") {
      return { error: "idle reminder config has unknown or missing fields" };
    }
    if (value.version !== 1 || typeof value.enabled !== "boolean" ||
        !Number.isSafeInteger(value.interval_seconds) || Number(value.interval_seconds) < 1800) {
      return { error: "idle reminder config requires version 1, a boolean enabled value, and interval_seconds >=1800" };
    }
    return { config: { version: 1, enabled: value.enabled,
      interval_seconds: Number(value.interval_seconds), enabledAtMs: info.mtimeMs } };
  } catch (error) {
    return { error: `cannot read idle reminder config: ${String(error)}` };
  }
}

function notifyConfiguration(ctx: ExtensionContext, error: string): void {
  if (!error || error === lastConfigurationError) return;
  lastConfigurationError = error;
  if (ctx.hasUI) ctx.ui.notify(`Periodic stow disabled: ${error}`, "error");
}

function notifyReminderConfiguration(ctx: ExtensionContext, error: string): void {
  if (!error || error === lastReminderConfigurationError) return;
  lastReminderConfigurationError = error;
  if (ctx.hasUI) ctx.ui.notify(`Idle reminder disabled: ${error}`, "error");
}

function callRun(args: string[]): RunState & Record<string, unknown> {
  const result = spawnSync(runScript, args, {
    encoding: "utf8",
    env: { ...process.env, FM_HOME: fmHome },
    maxBuffer: 1024 * 1024,
  });
  const line = (result.stdout || "").trim().split("\n").at(-1) || "";
  let parsed: RunState & Record<string, unknown>;
  try {
    parsed = JSON.parse(line) as RunState & Record<string, unknown>;
  } catch {
    throw new Error(`fm-stow-run returned unreadable output (exit ${String(result.status)})`);
  }
  if (result.status !== 0) throw new Error(String(parsed.message || parsed.outcome || "fm-stow-run refused"));
  return parsed;
}

function sessionIdentity(ctx: ExtensionContext, targetEntry?: string): { id: string; file: string; entry: string; fingerprint: string } | null {
  const id = String(ctx.sessionManager.getSessionId() || "");
  const file = ctx.sessionManager.getSessionFile();
  const entry = targetEntry || ctx.sessionManager.getLeafId();
  if (!id || !file || !entry) return null;
  try {
    const info = lstatSync(file);
    if (!info.isFile() || info.isSymbolicLink()) return null;
    const branch = ctx.sessionManager.getBranch(entry);
    if (branch.length === 0 || branch.at(-1)?.id !== entry) return null;
    const fingerprint = createHash("sha256").update(branch.map((item) => item.id).join("\n")).digest("hex");
    return { id, file: resolve(file), entry, fingerprint };
  } catch {
    return null;
  }
}

function isMainEligible(): boolean {
  const actor = process.env.FM_SUPERVISION_ACTOR;
  return !process.env.FM_TASK_ID && !process.env.FIRSTMATE_OP && (!actor || actor === "main");
}

function isDue(config: PeriodicConfig, state: RunState | null, now = Date.now()): boolean {
  if (state?.active) return true;
  const lastSuccess = state?.last_success_at ? Date.parse(state.last_success_at) : Number.NaN;
  const minimumDue = Number.isFinite(lastSuccess)
    ? lastSuccess + config.min_interval_seconds * 1000
    : Number.NEGATIVE_INFINITY;
  if (state?.next_due_at) {
    const due = Date.parse(state.next_due_at);
    return Number.isFinite(due) && now >= Math.max(due, minimumDue);
  }
  return now >= Math.max(config.enabledAtMs + config.interval_seconds * 1000, minimumDue);
}

function localAutomaticConflict(): string | null {
  if (existsSync(`${fmHome}/config/stow-pass-horizon`)) return "pass-horizon requires a manual stow before automatic full passes";
  const learnings = `${fmHome}/data/learnings.md`;
  if (!existsSync(learnings)) return null;
  try {
    const text = readFileSync(learnings, "utf8");
    if (/<!--g-->/.test(text)) return "legacy grace entries require a manual stow";
    const material = text.split("\n").filter((line) => /^\s*[-*]\s+/.test(line));
    if (material.some((line) => !/<!--(?:[ap]:\d{4}-\d{2}-\d{2}(?:\/\d+)?|P|g)-->\s*$/.test(line))) {
      return "unmigrated legacy learnings require a manual stow";
    }
  } catch (error) {
    return `cannot preflight learnings: ${String(error)}`;
  }
  return null;
}

function safeBoundary(ctx: ExtensionContext): boolean {
  if (ctx.hasPendingMessages() || activeTools > 0 || blockingPrompt || compacting || ownedFollowups > 0) return false;
  try {
    return ctx.ui.getEditorText().trim() === "";
  } catch {
    return false;
  }
}

function safeSettled(ctx: ExtensionContext): boolean {
  return ctx.isIdle() && safeBoundary(ctx);
}

function entryTime(value: unknown): number {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string") {
    const parsed = Date.parse(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return 0;
}

function assistantText(message: unknown): string {
  if (!message || typeof message !== "object" || (message as { role?: unknown }).role !== "assistant") return "";
  const content = (message as { content?: unknown }).content;
  if (!Array.isArray(content)) return "";
  return content.map((part) => part && typeof part === "object" &&
    (part as { type?: unknown }).type === "text" ? String((part as { text?: unknown }).text || "") : "").join("").trim();
}

function messageText(message: unknown): string {
  if (!message || typeof message !== "object") return "";
  const content = (message as { content?: unknown }).content;
  if (typeof content === "string") return content.trim();
  if (!Array.isArray(content)) return "";
  return content.map((part) => part && typeof part === "object" &&
    (part as { type?: unknown }).type === "text" ? String((part as { text?: unknown }).text || "") : "").join("").trim();
}

function genuineUserMessage(message: unknown): boolean {
  const content = (message as { content?: unknown } | undefined)?.content;
  if (Array.isArray(content) && content.some((part) => part && typeof part === "object" &&
      (part as { type?: unknown }).type === "image")) return true;
  const text = messageText(message);
  return Boolean(text) && classifyFirstmateOperationalText(text) === undefined;
}

function reminderActivityIdentity(entry: Record<string, unknown>): string | null {
  if (entry.type === "custom_message") {
    if (entry.customType === "fm-branch-merge" && entry.display === true) {
      return `branch-note:${createHash("sha256").update(String(entry.content || "")).digest("hex")}`;
    }
    if (entry.customType === "firstmate-feishu-inbound") {
      const details = entry.details as { deliveryRef?: unknown } | undefined;
      return typeof details?.deliveryRef === "string" ? `feishu:${details.deliveryRef}` : null;
    }
    if (entry.customType === "fm-short-agent-error") {
      return `short-error:${createHash("sha256").update(String(entry.content || "")).digest("hex")}`;
    }
    return null;
  }
  if (entry.type !== "custom" || entry.customType !== "fm-branch-visible-outcome") return null;
  const data = entry.data as { seq?: unknown; task?: unknown; verdict?: unknown;
    taskGeneration?: unknown; evidenceKey?: unknown } | undefined;
  if (typeof data?.taskGeneration === "string" && typeof data.evidenceKey === "string") {
    return `branch-outcome:${String(data.task || "")}:${data.taskGeneration}:${data.evidenceKey}:${String(data.verdict || "")}`;
  }
  return typeof data?.seq === "number" && Number.isSafeInteger(data.seq)
    ? `branch-outcome-seq:${String(data.seq)}`
    : null;
}

function reminderActivitySince(ctx: ExtensionContext, entryId: string | null): boolean {
  if (!entryId) return false;
  const branch = ctx.sessionManager.getBranch() as unknown as Array<Record<string, unknown>>;
  const anchor = branch.findIndex((entry) => entry.id === entryId);
  if (anchor < 0) return true;
  const covered = new Set(branch.slice(0, anchor + 1).map(reminderActivityIdentity)
    .filter((identity): identity is string => identity !== null));
  return branch.slice(anchor + 1).some((entry) => {
    if (entry.type === "message") {
      const message = entry.message as { role?: unknown } | undefined;
      if (message?.role !== "user") return false;
      return genuineUserMessage(message);
    }
    const identity = reminderActivityIdentity(entry);
    if (!identity || covered.has(identity)) return false;
    covered.add(identity);
    return true;
  });
}

function latestBranchEntryId(ctx: ExtensionContext, customType: string): string | null {
  const entry = [...ctx.sessionManager.getBranch()].reverse().find((candidate) =>
    candidate.type === "custom" && candidate.customType === customType);
  return entry?.id ?? null;
}

function recordReminderCheck(
  pi: ExtensionAPI,
  ctx: ExtensionContext,
  generation: CoordinatorGeneration,
  customType: typeof reminderEmptyType | typeof reminderUnchangedType,
  inventoryFingerprint: string,
): void {
  const handledAt = Date.now();
  pi.appendEntry(customType, { version: 1, handled_at: new Date(handledAt).toISOString(),
    inventory_fingerprint: inventoryFingerprint, session_id: generation.sessionId,
    session_file: generation.sessionFile });
  generation.reminderLastHandledAt = handledAt;
  generation.reminderLastHandledEntryId = latestBranchEntryId(ctx, customType);
  generation.reminderLastInventoryFingerprint = inventoryFingerprint;
}

function restoreReminderState(pi: ExtensionAPI, ctx: ExtensionContext, generation: CoordinatorGeneration): void {
  let pending: { id: string; at: number; inventoryFingerprint: string | null } | null = null;
  let recovered: { id: string; at: number; inventoryFingerprint: string | null } | null = null;
  for (const entry of ctx.sessionManager.getBranch() as unknown as Array<Record<string, unknown>>) {
    if (entry.type === "custom_message" && entry.customType === reminderMessageType) {
      const details = entry.details as { version?: unknown; reminder_id?: unknown;
        inventory_fingerprint?: unknown } | undefined;
      if (details?.version === 1 && typeof details.reminder_id === "string") {
        pending = { id: details.reminder_id, at: entryTime(entry.timestamp),
          inventoryFingerprint: typeof details.inventory_fingerprint === "string"
            ? details.inventory_fingerprint
            : reminderRequestInventoryFingerprint(entry.content) };
        recovered = null;
      }
      continue;
    }
    if (entry.type === "custom" && (entry.customType === reminderReceiptType ||
        entry.customType === reminderEmptyType || entry.customType === reminderUnchangedType)) {
      const data = entry.data as { version?: unknown; reminder_id?: unknown; handled_at?: unknown;
        inventory_fingerprint?: unknown } | undefined;
      const handledAt = entryTime(data?.handled_at);
      if (data?.version === 1 && handledAt > 0) {
        const inventoryFingerprint = typeof data.inventory_fingerprint === "string"
          ? data.inventory_fingerprint
          : pending && data.reminder_id === pending.id
            ? pending.inventoryFingerprint
            : null;
        if (handledAt >= generation.reminderLastHandledAt) {
          generation.reminderLastHandledAt = handledAt;
          generation.reminderLastHandledEntryId = typeof entry.id === "string" ? entry.id : null;
          generation.reminderLastInventoryFingerprint = inventoryFingerprint;
        }
        if (pending && (entry.customType === reminderEmptyType || entry.customType === reminderUnchangedType ||
            data?.reminder_id === pending.id)) {
          pending = null;
          recovered = null;
        }
      }
      continue;
    }
    if (entry.type === "custom" && entry.customType === reminderFailedType) {
      const data = entry.data as { reminder_id?: unknown; failed_at?: unknown } | undefined;
      if ((pending && data?.reminder_id === pending.id) || data?.reminder_id === recovered?.id) {
        pending = null;
        recovered = null;
        const failedAt = entryTime(data?.failed_at);
        if (failedAt > 0) generation.reminderRetryAfter = Math.max(
          generation.reminderRetryAfter, failedAt + reminderRetryDelay());
      }
      continue;
    }
    if (pending && entry.type === "message") {
      const message = entry.message as { stopReason?: unknown } | undefined;
      if (assistantText(message) && message?.stopReason !== "error" && message?.stopReason !== "aborted") {
        recovered = { id: pending.id, at: entryTime(entry.timestamp) || entryTime((message as { timestamp?: unknown }).timestamp),
          inventoryFingerprint: pending.inventoryFingerprint };
        if (message?.stopReason === "toolUse") recovered = null;
      }
    }
  }
  if (recovered && recovered.at > generation.reminderLastHandledAt) {
    generation.reminderLastHandledAt = recovered.at;
    pi.appendEntry(reminderReceiptType, { version: 1, reminder_id: recovered.id,
      handled_at: new Date(recovered.at).toISOString(), session_id: generation.sessionId,
      session_file: generation.sessionFile, ...(recovered.inventoryFingerprint
        ? { inventory_fingerprint: recovered.inventoryFingerprint }
        : {}) });
    generation.reminderLastInventoryFingerprint = recovered.inventoryFingerprint;
    generation.reminderLastHandledEntryId = latestBranchEntryId(ctx, reminderReceiptType);
    pending = null;
  }
  // A hot reload retains Pi's queued follow-up and can continue observing it.
  // A cold restart has no live queue ownership, so release an orphaned request
  // and retry only on a later clock boundary.
  if (pending && !ctx.hasPendingMessages()) {
    const failedAt = Date.now();
    generation.reminderRetryAfter = failedAt + reminderRetryDelay();
    pi.appendEntry(reminderFailedType, { version: 1, reminder_id: pending.id,
      failed_at: new Date(failedAt).toISOString(), reason: "cold-restart-orphan",
      session_id: generation.sessionId, session_file: generation.sessionFile });
    pending = null;
  }
  generation.reminderPendingId = pending?.id ?? null;
}

function reminderRetryDelay(): number {
  return Math.max(1000, Math.min(tickMs, 60_000));
}

function reminderLockOwned(): boolean {
  const result = spawnSync(lockStatusScript, [], {
    encoding: "utf8", env: { ...process.env, FM_HOME: fmHome, FM_ROOT_OVERRIDE: fmRoot }, timeout: 3000,
  });
  return result.status === 0 && result.stdout.trim() === "owned";
}

function reminderDue(config: IdleReminderConfig, generation: CoordinatorGeneration, now = Date.now()): boolean {
  const anchor = Math.max(config.enabledAtMs, generation.reminderLastHandledAt);
  return now >= anchor + config.interval_seconds * 1000;
}

function reminderHasInventory(snapshot: unknown): snapshot is Record<string, unknown> {
  if (!snapshot || typeof snapshot !== "object" || (snapshot as { schema?: unknown }).schema !== "fm-bearings.v1") return false;
  const value = snapshot as { in_flight?: unknown; decisions_open?: unknown; gates?: unknown };
  return [value.in_flight, value.decisions_open, value.gates]
    .some((items) => Array.isArray(items) && items.length > 0);
}

function reminderInventory(snapshot: Record<string, unknown>): Record<string, unknown> {
  return {
    schema: snapshot.schema,
    generated: snapshot.generated,
    in_flight: Array.isArray(snapshot.in_flight) ? snapshot.in_flight : [],
    gates: Array.isArray(snapshot.gates) ? snapshot.gates : [],
    decisions_open: Array.isArray(snapshot.decisions_open) ? snapshot.decisions_open : [],
  };
}

function reminderInventoryFingerprint(snapshot: Record<string, unknown>): string {
  const inventory = reminderInventory(snapshot);
  return createHash("sha256").update(JSON.stringify({
    schema: inventory.schema,
    in_flight: (inventory.in_flight as Array<Record<string, unknown>>).map((row) => ({
      id: row.id, kind: row.kind, state: row.state, repo: row.repo,
    })),
    gates: (inventory.gates as Array<Record<string, unknown>>).map((row) => ({
      id: row.id, blocked_by: row.blocked_by, owner: row.owner, filed: row.filed,
    })),
    decisions_open: (inventory.decisions_open as Array<Record<string, unknown>>).map((row) => ({
      id: row.id, key: row.key, verb: row.verb, owner: row.owner,
      summary: materialDecisionSummary(row.summary),
    })),
  })).digest("hex");
}

function materialDecisionSummary(value: unknown): unknown {
  if (typeof value !== "string") return value;
  return value.replace(/:\s+held \d+d:\s+/gu, ": ").replace(/^held \d+d$/u, "held");
}

function reminderRequestInventoryFingerprint(content: unknown): string | null {
  if (typeof content !== "string") return null;
  const marker = "\nCanonical snapshot:\n";
  const markerAt = content.lastIndexOf(marker);
  if (markerAt < 0) return null;
  try {
    const snapshot = JSON.parse(content.slice(markerAt + marker.length).trim()) as unknown;
    if (!snapshot || typeof snapshot !== "object" || (snapshot as { schema?: unknown }).schema !== "fm-bearings.v1") {
      return null;
    }
    return reminderInventoryFingerprint(snapshot as Record<string, unknown>);
  } catch {
    return null;
  }
}

function reminderPrompt(snapshot: Record<string, unknown>, reminderId: string): string {
  return encodeFirstmateOperationalInput("watcher", [
    "FIRSTMATE IDLE REMINDER",
    `reminder_id=${reminderId}`,
    "This is a scheduled operational follow-up at a safely idle MAIN-session boundary, not user input or implementation authority.",
    "Use only the canonical snapshot below. It already excludes completed and archived work; do not inspect historical reports or create another inventory.",
    "Write one concise Simplified Chinese reminder addressed to captain. If a time is useful, show it in UTC+8.",
    "First list unfinished outcomes with the real blocker or next action. Then list only genuine unanswered decisions requiring user judgment, with their options and one concise recommendation.",
    "Do not expose task ids or internal status labels. Do not repeat standing local-Dorado routing or already-authorized ordinary permission declarations.",
    "Do not answer, release, close, or mutate any decision or task. Do not run stow or maintenance.",
    "If any row lacks its real blocker, next action, or decision options, use bin/fm-bearings-snapshot.sh --task with that row's internal id before replying.",
    "Canonical snapshot:",
    JSON.stringify(snapshot),
  ].join("\n"));
}

async function checkIdleReminder(pi: ExtensionAPI, ctx: ExtensionContext): Promise<boolean> {
  const generation = activeGeneration;
  if (!generation?.live || !isMainEligible()) return false;
  const configured = readReminderConfig();
  if (configured.error) {
    notifyReminderConfiguration(ctx, configured.error);
    return false;
  }
  const config = configured.config;
  if (!config?.enabled) return false;
  if (generation.reminderChecking || generation.reminderPendingId) return true;
  if (Date.now() < generation.reminderRetryAfter || !reminderDue(config, generation) ||
      !safeSettled(ctx) || !reminderLockOwned()) return false;
  lastReminderConfigurationError = "";
  generation.reminderChecking = true;
  try {
    const result = await pi.exec("bash", [bearingsScript, "--json", "--all-in-flight", "--all-decisions", "--all-queued"], {
      cwd: fmRoot, timeout: 30_000,
    });
    if (activeGeneration !== generation || !generation.live || !safeSettled(ctx) || !reminderLockOwned()) return false;
    if (result.code !== 0) throw new Error(result.stderr.trim() || "canonical reminder inventory failed");
    const snapshot = JSON.parse(result.stdout) as unknown;
    if (!snapshot || typeof snapshot !== "object" || (snapshot as { schema?: unknown }).schema !== "fm-bearings.v1") {
      throw new Error("canonical reminder inventory returned the wrong schema");
    }
    const inventoryFingerprint = reminderInventoryFingerprint(snapshot as Record<string, unknown>);
    if (!reminderHasInventory(snapshot)) {
      recordReminderCheck(pi, ctx, generation, reminderEmptyType, inventoryFingerprint);
      return false;
    }
    if (generation.reminderLastInventoryFingerprint === inventoryFingerprint &&
        !reminderActivitySince(ctx, generation.reminderLastHandledEntryId)) {
      recordReminderCheck(pi, ctx, generation, reminderUnchangedType, inventoryFingerprint);
      return false;
    }
    const reminderId = randomUUID();
    generation.reminderPendingId = reminderId;
    pi.sendMessage({ customType: reminderMessageType, display: false,
      content: reminderPrompt(reminderInventory(snapshot), reminderId),
      details: { version: 1, reminder_id: reminderId, session_id: generation.sessionId,
        session_file: generation.sessionFile, requested_at: new Date(Date.now()).toISOString(),
        inventory_fingerprint: inventoryFingerprint } },
    { triggerTurn: true, deliverAs: "followUp" });
    lastDispatchError = "";
    return true;
  } catch (error) {
    generation.reminderPendingId = null;
    generation.reminderRetryAfter = Date.now() + reminderRetryDelay();
    const detail = String(error);
    if (ctx.hasUI && detail !== lastDispatchError) ctx.ui.notify(`Idle reminder waiting: ${detail}`, "warning");
    lastDispatchError = detail;
    return false;
  } finally {
    generation.reminderChecking = false;
  }
}

function request(kind: "heartbeat" | "manual" | "precompact", ctx: ExtensionContext): RunState | null {
  const generation = activeGeneration;
  const identity = sessionIdentity(ctx);
  if (!generation?.live || !identity || generation.sessionId !== identity.id || generation.sessionFile !== identity.file) return null;
  return callRun([
    "request", "--reason", kind, "--session-id", identity.id, "--session-file", identity.file,
    "--target-entry-id", identity.entry, "--branch-fingerprint", identity.fingerprint,
  ]);
}

function promptFor(run: RunState["active"], generation: CoordinatorGeneration): string {
  const action = run?.phase === "partial" || run?.phase === "running" ? "recover" : "begin";
  const heartbeat = run?.reasons.includes("heartbeat");
  return [
    heartbeat ? "FIRSTMATE HEARTBEAT CHECKLIST" : "FIRSTMATE COORDINATED STOW REQUEST",
    `run_id=${run?.run_id}`,
    `generation=${generation.token}`,
    `session_id=${generation.sessionId}`,
    `cutoff_entry_id=${run?.cutoff_entry_id}`,
    `branch_fingerprint=${run?.branch_fingerprint}`,
    `coordinator_action=${action}`,
    "This is an operational follow-up, not user input and not completion evidence.",
    "User work has priority. If background validation or a write-critical step is currently running, call fm-stow-run.sh defer with this run_id and stop this pass.",
    "For an automatic full pass, preflight every registered home before beginning; an unreachable home or one without a safe receiver is unresolved and must defer the run, never fall back to raw commands.",
    `Otherwise call fm-stow-run.sh ${action} with the current revision plus the session_id, cutoff_entry_id, and branch_fingerprint above, load the internal stow skill, and execute ${heartbeat ? "its knowledge curation semantics plus the three duties below" : "its complete semantics"} for the fixed cutoff.`,
    "Before every mutation record a prepared step with original and target hashes; read back the effect and record verified. Reuse the original plan and correlations on recovery.",
    ...(heartbeat ? [
      "Account for all three duties in this one durable run: archival, continuation, knowledge. Do not invent work from idle time.",
      "Archival: compare recorded goals with acceptance evidence, retain reports and unresolved decisions, and use only existing guarded backlog-close/teardown owners for confirmed landed work. A refusal retains the work and unfinished duty; never force, discard or delete source to complete a heartbeat.",
      "Continuation: use the canonical per-task business and progress record; route authorized next actions to named executors through the existing lease/handoff/inbox owners and verify receipt/start. Preserve uncertain effects for readback, genuine blockers with their release trigger, and explicit stops. Healthy work stays running.",
      "Knowledge: load the stow skill for its curation duty only, preserving privacy, pinned preferences, inspect-then-update, provenance and recoverable archives. Its manual/precompact semantics remain unchanged; task archival is the separate guarded duty above.",
      "Supervisor coordinates and judges; authorized executors perform effects. Escalate only actual authority/acceptance decisions. Continue the same run_id after partial work; record each duty as complete or unchanged with evidence_ref and sha256 in receipt.heartbeat. A blocked duty cannot finish succeeded/skipped.",
      "Keep unchanged passes silent. Delivery, plans, reported completion and heartbeat text are never proof that an operation happened.",
    ] : []),
    "Finish only with a version=1 receipt proving local steps, budget, and every required cascade outcome. Sending this message or ending an agent turn is not completion.",
  ].join("\n");
}

function escalationRecorded(ctx: ExtensionContext, id: string): boolean {
  return ctx.sessionManager.getBranch().some((entry) => entry.type === "custom_message" &&
    entry.customType === "fm-heartbeat-escalation" &&
    (entry.details as { escalation_id?: unknown })?.escalation_id === id);
}

function dispatch(pi: ExtensionAPI, ctx: ExtensionContext): void {
  const generation = activeGeneration;
  if (!generation?.live || generation.dispatching || !safeSettled(ctx)) return;
  generation.dispatching = true;
  try {
    const state = callRun(["status"]);
    const active = state.active;
    if (!active || (active.phase !== "requested" && active.phase !== "partial" &&
        !(active.phase === "running" && active.reasons.includes("heartbeat")))) return;
    if (active.session_id !== generation.sessionId || active.session_file !== generation.sessionFile) return;
    const cutoff = sessionIdentity(ctx, active.cutoff_entry_id);
    if (!cutoff || cutoff.fingerprint !== active.branch_fingerprint) return;
    if (active.attempts > 0 && Date.now() - generation.lastOfferAt < tickMs) return;
    const offered = callRun([
      "deliver", "--run-id", active.run_id, "--generation", generation.token,
      "--expected-revision", String(state.revision),
    ]);
    if (offered.outcome === "escalated") return;
    if (offered.outcome === "escalate") {
      const escalationId = String(offered.escalation_id || "");
      if (!escalationId) throw new Error("heartbeat escalation reservation is missing");
      if (escalationRecorded(ctx, escalationId)) {
        callRun(["delivery", "--run-id", active.run_id, "--generation", generation.token,
          "--operation-id", escalationId, "--expected-revision", String(offered.revision)]);
        generation.submittedEscalations.add(escalationId);
        return;
      }
      if (generation.submittedEscalations.has(escalationId)) return;
      if (!safeSettled(ctx)) return;
      pi.sendMessage({ customType: "fm-heartbeat-escalation", display: true,
        content: encodeFirstmateOperationalInput("watcher",
          `Initial heartbeat offers are exhausted; the same run remains unfinished.\n${promptFor(active, generation)}`),
        details: { version: 1, run_id: active.run_id, generation: generation.token,
          attempt: active.attempts, escalation_id: escalationId } },
      { triggerTurn: true, deliverAs: "followUp" });
      generation.submittedEscalations.add(escalationId);
      generation.lastOfferAt = Date.now();
      lastDispatchError = "";
      return;
    }
    pi.sendMessage({
      customType: active.reasons.includes("heartbeat") ? "fm-heartbeat-request" : "fm-stow-request",
      content: active.reasons.includes("heartbeat")
        ? encodeFirstmateOperationalInput("watcher", promptFor(active, generation))
        : promptFor(active, generation),
      display: !active.reasons.includes("heartbeat"),
      details: { version: 1, run_id: active.run_id, generation: generation.token, attempt: offered.attempts },
    }, { triggerTurn: true, deliverAs: "followUp" });
    generation.lastOfferAt = Date.now();
    lastDispatchError = "";
  } catch (error) {
    const detail = String(error);
    if (ctx.hasUI && detail !== lastDispatchError) ctx.ui.notify(`Heartbeat waiting: ${detail}`, "warning");
    lastDispatchError = detail;
  } finally {
    generation.dispatching = false;
  }
}

function checkDue(pi: ExtensionAPI, ctx: ExtensionContext): void {
  const generation = activeGeneration;
  if (!generation?.live || !isMainEligible()) return;
  const configured = readConfig();
  if (configured.error) {
    notifyConfiguration(ctx, configured.error);
    return;
  }
  const config = configured.config;
  if (!config?.enabled) {
    try { callRun(["disable"]); } catch { /* an absent/unowned state stays untouched */ }
    generation.due = false;
    return;
  }
  lastConfigurationError = "";
  const conflict = localAutomaticConflict();
  if (conflict) {
    notifyConfiguration(ctx, conflict);
    return;
  }
  let state: RunState | null = null;
  if (existsSync(stateFile)) {
    try {
      state = callRun(["status"]);
    } catch (error) {
      notifyConfiguration(ctx, `coordinator state is unavailable: ${String(error)}`);
      return;
    }
  }
  if (state?.last_success_at) {
    const lastSuccess = Date.parse(state.last_success_at);
    if (!Number.isFinite(lastSuccess) || lastSuccess > Date.now() + 1000) {
      notifyConfiguration(ctx, "coordinator clock moved behind the last successful run");
      return;
    }
  }
  if (state?.next_due_at && !Number.isFinite(Date.parse(state.next_due_at))) {
    notifyConfiguration(ctx, "coordinator next-due clock is invalid");
    return;
  }
  generation.due = isDue(config, state);
  if (!generation.due) return;
  if (!state?.active) {
    try { request("heartbeat", ctx); } catch (error) { notifyConfiguration(ctx, String(error)); return; }
  }
  dispatch(pi, ctx);
}

function runIdleBoundary(pi: ExtensionAPI, ctx: ExtensionContext, generation: CoordinatorGeneration): void {
  if (activeGeneration !== generation || !generation.live) return;
  checkDue(pi, ctx);
  dispatch(pi, ctx);
  pi.events.emit("firstmate:heartbeat-tick", {});
  queueMicrotask(() => {
    if (activeGeneration !== generation || !generation.live) return;
    void checkIdleReminder(pi, ctx);
  });
}

function activate(pi: ExtensionAPI, ctx: ExtensionContext): void {
  const identity = sessionIdentity(ctx);
  if (!identity || !isMainEligible()) return;
  if (activeGeneration?.timer) clearInterval(activeGeneration.timer);
  if (activeGeneration) activeGeneration.live = false;
  activeTools = 0;
  blockingPrompt = false;
  compacting = false;
  ownedFollowups = 0;
  const generation: CoordinatorGeneration = {
    token: randomUUID(), sessionId: identity.id, sessionFile: identity.file,
    live: true, timer: null, due: false, dispatching: false, lastOfferAt: 0,
    submittedEscalations: new Set(),
    reminderChecking: false, reminderPendingId: null, reminderLastHandledAt: 0,
    reminderLastHandledEntryId: null, reminderLastInventoryFingerprint: null,
    reminderRetryAfter: 0, reminderRun: null,
  };
  activeGeneration = generation;
  restoreReminderState(pi, ctx, generation);
  generation.timer = setInterval(() => {
    runIdleBoundary(pi, ctx, generation);
  }, tickMs);
  runIdleBoundary(pi, ctx, generation);
}

export default function periodicStow(pi: ExtensionAPI): void {
  pi.events.on(FIRSTMATE_OWNED_FOLLOWUP_START_EVENT, () => { ownedFollowups += 1; });
  pi.events.on(FIRSTMATE_OWNED_FOLLOWUP_DRAINED_EVENT, (value: unknown) => {
    ownedFollowups = Math.max(0, ownedFollowups - 1);
    if (ownedFollowups > 0) return;
    const ctx = (value as { ctx?: ExtensionContext } | undefined)?.ctx;
    const generation = activeGeneration;
    if (ctx && generation?.live) void checkIdleReminder(pi, ctx);
  });
  pi.events.on("firstmate:continuation-readback", (value: unknown) => {
    const offer = value as ContinuationReadbackOffer;
    if (!offer?.ctx || typeof offer.accept !== "function" || !isMainEligible()) return;
    // A cold session may have had no persisted leaf at session_start. The first
    // real settle boundary can activate the same clock before releasing its run.
    if (!activeGeneration?.live) activate(pi, offer.ctx);
    const generation = activeGeneration;
    const identity = sessionIdentity(offer.ctx);
    if (!generation?.live || !identity || generation.sessionId !== identity.id || generation.sessionFile !== identity.file) return;
    offer.accept({
      generation: generation.token, sessionId: identity.id, sessionFile: identity.file,
      recheckMs: tickMs * 2,
      current: () => activeGeneration === generation && generation.live,
      canNotify: () => safeSettled(offer.ctx),
      // The current logical run is still active at before-settle. All other
      // UI/input/tool/compaction protections apply at its final submission.
      canContinue: () => safeBoundary(offer.ctx),
    });
  });
  pi.on("session_start", (_event, ctx) => activate(pi, ctx));
  pi.events.on(FIRSTMATE_SESSION_START_SETTLED_EVENT, () => {
    // The ordinary session_start activation already owns the context. Its next
    // tick rechecks lock-backed eligibility after the startup digest settles.
  });
  pi.on("session_shutdown", () => {
    if (!activeGeneration) return;
    activeGeneration.live = false;
    if (activeGeneration.timer) clearInterval(activeGeneration.timer);
    activeGeneration.timer = null;
    ownedFollowups = 0;
  });
  pi.on("tool_execution_start", () => { activeTools += 1; });
  pi.on("tool_execution_end", () => { activeTools = Math.max(0, activeTools - 1); });
  pi.on("ui_prompt_start", () => { blockingPrompt = true; });
  pi.on("ui_prompt_end", () => { blockingPrompt = false; });
  pi.on("session_before_compact", (_event, ctx) => {
    compacting = true;
    try {
      request("precompact", ctx);
    } catch (error) {
      if (ctx.hasUI) ctx.ui.notify(`Periodic stow could not preserve the pre-compaction recovery pointer: ${String(error)}`, "error");
    }
  });
  pi.on("session_compact", () => { compacting = false; });
  pi.on("before_agent_start", (event) => {
    if (event.messageType !== "custom" || event.message.customType !== reminderMessageType) return;
    const details = event.message.details as { version?: unknown; reminder_id?: unknown;
      inventory_fingerprint?: unknown } | undefined;
    const generation = activeGeneration;
    if (!generation?.live || details?.version !== 1 || details.reminder_id !== generation.reminderPendingId ||
        typeof details.inventory_fingerprint !== "string") return;
    generation.reminderRun = { id: String(details.reminder_id), answered: false,
      inventoryFingerprint: details.inventory_fingerprint };
  });
  pi.on("message_end", (event) => {
    const run = activeGeneration?.reminderRun;
    if (!run || (event.message as { role?: unknown }).role !== "assistant") return;
    const message = event.message as { stopReason?: unknown };
    run.answered = Boolean(assistantText(event.message)) && message.stopReason !== "error" &&
      message.stopReason !== "aborted" && message.stopReason !== "toolUse";
  });
  pi.on("agent_settled", (event, ctx) => {
    compacting = false;
    if (!activeGeneration?.live) {
      activate(pi, ctx);
      return;
    }
    const generation = activeGeneration;
    const run = generation.reminderRun;
    if (run) {
      if (!event.aborted && run.answered) {
        const handledAt = Date.now();
        pi.appendEntry(reminderReceiptType, { version: 1, reminder_id: run.id,
          handled_at: new Date(handledAt).toISOString(), session_id: generation.sessionId,
          session_file: generation.sessionFile, inventory_fingerprint: run.inventoryFingerprint });
        generation.reminderLastHandledAt = handledAt;
        generation.reminderLastHandledEntryId = latestBranchEntryId(ctx, reminderReceiptType);
        generation.reminderLastInventoryFingerprint = run.inventoryFingerprint;
      } else {
        pi.appendEntry(reminderFailedType, { version: 1, reminder_id: run.id,
          failed_at: new Date(Date.now()).toISOString(), session_id: generation.sessionId,
          session_file: generation.sessionFile });
        generation.reminderRetryAfter = Date.now() + reminderRetryDelay();
      }
      generation.reminderPendingId = null;
      generation.reminderRun = null;
    }
    runIdleBoundary(pi, ctx, generation);
  });
}
