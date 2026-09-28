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
import { encodeFirstmateOperationalInput, FIRSTMATE_SESSION_START_SETTLED_EVENT } from "./lib/fm-operational-input.ts";

type PeriodicConfig = {
  version: 1;
  enabled: boolean;
  interval_seconds: number;
  min_interval_seconds: number;
  enabledAtMs: number;
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
};

const extensionFile = fileURLToPath(import.meta.url);
const root = resolve(dirname(extensionFile), "../..");
const fmHome = resolve(process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root);
const fmRoot = resolve(process.env.FM_ROOT_OVERRIDE || root);
const configFile = `${fmHome}/config/periodic-stow.json`;
const stateFile = `${fmHome}/state/stow/state.json`;
const runScript = `${fmRoot}/bin/fm-stow-run.sh`;
const tickMs = positiveInteger(process.env.FM_PERIODIC_STOW_TICK_MS, 60_000);
let activeGeneration: CoordinatorGeneration | null = null;
let activeTools = 0;
let blockingPrompt = false;
let compacting = false;
let lastConfigurationError = "";
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

function notifyConfiguration(ctx: ExtensionContext, error: string): void {
  if (!error || error === lastConfigurationError) return;
  lastConfigurationError = error;
  if (ctx.hasUI) ctx.ui.notify(`Periodic stow disabled: ${error}`, "error");
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
  if (ctx.hasPendingMessages() || activeTools > 0 || blockingPrompt || compacting) return false;
  try {
    return ctx.ui.getEditorText().trim() === "";
  } catch {
    return false;
  }
}

function safeSettled(ctx: ExtensionContext): boolean {
  return ctx.isIdle() && safeBoundary(ctx);
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
      "Continuation: use canonical lifecycle observations; route authorized next actions to named executors through the existing lease/handoff/inbox owners and verify receipt/start. Preserve uncertain effects for readback, genuine blockers with their release trigger, and explicit stops. Healthy work stays running.",
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

function activate(pi: ExtensionAPI, ctx: ExtensionContext): void {
  const identity = sessionIdentity(ctx);
  if (!identity || !isMainEligible()) return;
  if (activeGeneration?.timer) clearInterval(activeGeneration.timer);
  if (activeGeneration) activeGeneration.live = false;
  activeTools = 0;
  blockingPrompt = false;
  compacting = false;
  const generation: CoordinatorGeneration = {
    token: randomUUID(), sessionId: identity.id, sessionFile: identity.file,
    live: true, timer: null, due: false, dispatching: false, lastOfferAt: 0,
    submittedEscalations: new Set(),
  };
  activeGeneration = generation;
  generation.timer = setInterval(() => {
    // Offer maintenance first; the continuation receiver rechecks idle/input
    // after its asynchronous readback, so it cannot overtake user input.
    checkDue(pi, ctx);
    pi.events.emit("firstmate:heartbeat-tick", {});
  }, tickMs);
  checkDue(pi, ctx);
}

export default function periodicStow(pi: ExtensionAPI): void {
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
  pi.registerCommand("stow", {
    description: "Queue a coordinated manual stow in this main session",
    handler: async (_args, ctx) => {
      try {
        request("manual", ctx);
        setTimeout(() => dispatch(pi, ctx), 0);
      } catch (error) {
        if (ctx.hasUI) ctx.ui.notify(`Could not queue stow: ${String(error)}`, "error");
      }
    },
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
  pi.on("agent_settled", (_event, ctx) => {
    compacting = false;
    if (!activeGeneration?.live) {
      activate(pi, ctx);
      return;
    }
    checkDue(pi, ctx);
    dispatch(pi, ctx);
  });
}
