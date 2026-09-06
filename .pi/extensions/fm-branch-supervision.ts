// Firstmate supervision branch for Pi (docs/pi-supervision-branch.md).
//
// A second AgentSession - the supervision BRANCH - inside the same pi process
// as the captain's MAIN session, living for exactly one main session: every
// main session start (cold start, /new, /resume, /fork, reload) opens a NEW
// branch conversation, so the branch reasons from today's generated prompt and
// the current main dialog instead of an older thread's accumulated memory. The
// durable outcome store, not that conversation, is what carries unacknowledged
// captain-facing outcomes across the boundary. The watcher extension offers each
// actionable wake here (lib/fm-branch-dispatch.ts); the branch handles it with
// real tools and reports through the fm_branch_report custom tool, which
// writes the durable outcome store FIRST (bin/fm-branch-outcome.sh), then
// persists a sequence-keyed visible record in main's transcript, and for a
// captain-facing outcome opens one sequence-keyed processing turn on main
// that stays open until main acknowledges that sequence (see
// presentUnprocessedOutcomes).
// Main's captain/assistant dialog is mirrored into the branch as read-only
// fm-main-mirror context from Pi's
// before_agent_start prompt and at main's turn_end. Pi-only by construction: this
// file lives in .pi/extensions, so no
// other harness ever loads it. Supervision is default-on for every task once
// this Pi session owns the fleet lock: no captain grant file is required.
// Away mode (or a broken branch between its bounded recovery probes) keeps
// today's wake-to-main behavior untouched regardless.
//
// Prefix stability (the cache contract, owner: bin/fm-branch-prompt.sh
// header): the branch's system prompt is the generator's byte-stable output,
// the tool set is BRANCH_TOOL_NAMES in that fixed order on every spawn, and
// one shared per-home prompt_cache_key is set for branch requests in a
// before_provider_request hook - main keeps Pi's default per-session key.
// Wakes, mirrored dialog, and merge notes are all appends at a tail.
//
// Session-lock ownership: every branch side-effect boundary re-evaluates the
// current extension generation and lock ownership LAZILY, the same way the
// watcher extension evaluates ownership at arm time. A cold
// Pi start acquires the lock only when the session runs fm-session-start.sh,
// so latching ownership once at session_start would leave the branch inert
// for the whole process; and a secondary read-only Pi session that never owns
// the lock must never write markers, clean leases, or accept wakes.
//
// Failure direction: every accepted path that cannot reach a working branch
// rejects its settlement to the watcher, which retains delivery ownership and
// routes the wake to MAIN through its consumption-acknowledged path. A broken
// branch declines later offers, so they take that same watcher path directly.
// The wake queue itself stays durable until the handler runs the drain's
// acknowledgement, so a branch that dies mid-handling re-presents its rows at
// the next drain exactly as a mid-handling main crash always has.
//
// Model and effort selection: supervision is an easier job than main, so the
// captain can pin a cheaper model AND a shallower reasoning effort for the
// branch alone with /supervision-model, which picks from Pi's own catalog and
// Pi's own supported-thinking-level list and persists each choice as one line
// under this home's config/. docs/configuration.md owns those files'
// operator-facing schema. The two pins are independent: either, both, or
// neither may be set. An absent pin makes the branch follow main's own
// current model or effort, applied explicitly on every build so a reopened
// branch cannot restore what an earlier pin left in its session.
//
// Threat model (captain-decided): the branch's actor identity is
// CONFUSED-AGENT-GRADE - deterministic spawnHook env injection plus a
// readonly-variable shell prelude so an accidental override fails loudly
// inside the branch's own shell. bin/fm-lease-lib.sh documents the grade and
// its deliberate limits.
import { spawnSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
// Pi exposes pi-ai to extensions as a first-class module in both its Node
// and compiled-binary loaders, the same standing as pi-tui and typebox
// below, and aliases this root specifier to its compat entrypoint.
import { clampThinkingLevel, getSupportedThinkingLevels } from "@earendil-works/pi-ai";
import {
  createAgentSession,
  createBashToolDefinition,
  DefaultResourceLoader,
  DynamicBorder,
  getAgentDir,
  keyHint,
  ModelRuntime,
  type ModelRegistry,
  SessionManager,
  ToolExecutionComponent,
  type AgentSession,
  type ExtensionAPI,
  type ExtensionCommandContext,
  type ToolDefinition,
} from "@earendil-works/pi-coding-agent";
import { Box, Container, fuzzyFilter, Input, SelectList, Text } from "@earendil-works/pi-tui";
import { Type } from "typebox";
import { runCommandAsync } from "./lib/fm-async-exec.ts";
import {
  type CalmPresentationState,
  calmTranscriptClassIsVisible,
  FIRSTMATE_CALM_PRESENTATION_EVENT,
} from "./lib/fm-calm-visibility.ts";
import {
  activateEligibleRowsOwner,
  deactivateEligibleRowsOwner,
  FM_BRANCH_DISPATCH_EVENT,
  releaseEligibleRowsSnapshot,
  scopeForUnreadWake,
  writeEligibleRowsSnapshot,
  type BranchDispatchOffer,
} from "./lib/fm-branch-dispatch.ts";
import {
  BRANCH_PICKER_MAX_VISIBLE,
  buildBranchModelItems,
  filterBranchPickerItems,
  FOLLOW_MAIN_VALUE,
  type BranchPickerItem,
} from "./lib/fm-branch-model-picker.ts";
import {
  classifyFirstmateOperationalText,
  encodeFirstmateOperationalInputWith,
} from "./lib/fm-operational-input.ts";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const afkFlag = join(state, ".afk");
const sessionsDir = join(state, "branch-session");
const sessionPointer = join(state, ".branch-session");
const mirrorCursorFile = join(state, ".branch-mirror-cursor");
const promptScript = join(fmRoot, "bin", "fm-branch-prompt.sh");
const outcomeScript = join(fmRoot, "bin", "fm-branch-outcome.sh");
const leaseScript = join(fmRoot, "bin", "fm-lease.sh");
const wakeGrantScript = join(fmRoot, "bin", "fm-wake-grant.sh");
const loadedMarker = join(state, ".pi-branch-extension-loaded");
const modelPinFile = join(config, "supervision-branch-model");
const effortPinFile = join(config, "supervision-branch-effort");

// Same tool set in the same order on every request (part of the cached
// prefix). "bash" resolves to the customTools override below, which injects
// the branch actor identity deterministically into every shell command.
const BRANCH_TOOL_NAMES = ["read", "bash", "fm_branch_report"] as const;

// One shared prompt_cache_key per home for ALL branch sessions, derived only
// from the home path so it survives restarts; main keeps its own session key.
const branchCacheKey = `fm-branch-${createHash("sha256").update(fmHome).digest("hex").slice(0, 24)}`;

const MIRROR_MESSAGE_CAP = 4000;
const MERGE_NOTE_BOAT = "⛵";
const VISIBLE_OUTCOME_ANCHOR = "⚓";
const VISIBLE_OUTCOME_ENTRY_TYPE = "fm-branch-visible-outcome";
// The processing half of the captain-outcome contract. The visible entry
// above is the DISPLAY: crash-safe and exact-once. This hidden, typed request
// is the PROCESSING: it opens the one turn in which main acts on the outcome,
// and only main's explicit sequence-bound acknowledgement (fm_branch_processed)
// closes it. An unrelated or empty answer leaves the sequence open, so it is
// presented again at the end of the next main run and at session start. Pi
// gives the model only a custom message's `content`, so the request carries
// its own identity through the typed operational envelope.
const PROCESSING_MESSAGE_TYPE = "fm-branch-process";
// Triggered re-presentations per unprocessed sequence set before the request
// stops opening turns of its own and instead rides the captain's next prompt
// (deliverAs nextTurn). Bounded so an answer that repeatedly ignores the
// request cannot become an unbounded loop of empty turns.
const PROCESSING_TRIGGERED_ATTEMPTS = 2;
// One provider failure rejects immediately to watcher-owned fallback but leaves
// room for a transient outage to recover on the next wake. A second consecutive
// provider failure latches the branch off. While latched, main keeps every wake
// except one branch recovery probe after each exponentially backed-off cooldown.
const PROVIDER_ERROR_LATCH_THRESHOLD = 2;
const PROVIDER_REPROBE_BASE_MS = 5 * 60 * 1000;
const PROVIDER_REPROBE_MAX_MS = 60 * 60 * 1000;
const PROCESSING_INSTRUCTION =
  "This is a supervision processing request delivered automatically by the supervision branch. " +
  "It was not typed by the captain. " +
  "The outcomes below are already stored durably and already shown to the captain as anchor entries in this transcript; each fleet event is already handled, so do not re-drain, re-run, or acknowledge the wake. " +
  "Process each outcome now as firstmate: give the captain a visible response where one is due, answer or escalate a decision, act on a blocker or failure, or record that no further action is needed. " +
  "When every outcome below is processed, call fm_branch_processed with through={N} exactly once. " +
  "Until that call the outcomes stay open and are presented again; an answer that does not make that call never counts as processing.";
type MirrorItem = { tag: "captain" | "main"; text: string };
type MirrorCursor = { file: string; index: number };
type Verdict = "routine" | "captain";
type LockOwnership = "owned" | "other" | "missing";
type OutcomeRow = {
  seq: number;
  task: string;
  verdict: Verdict;
  summary: string;
  silent: boolean;
};
type VisibleOutcomeRecord = OutcomeRow & { version: 1 };
type ProviderRecovery = {
  cooldownMs: number;
  retryNotBefore: number;
  probeInFlight: boolean;
};

const scriptEnv = {
  ...process.env,
  FM_HOME: fmHome,
  FM_ROOT_OVERRIDE: fmRoot,
  FM_STATE_OVERRIDE: state,
  FM_CONFIG_OVERRIDE: config,
};

function offerEligible(offer: BranchDispatchOffer): boolean {
  return offer.eligible === true;
}

function afkActive(): boolean {
  return existsSync(afkFlag);
}

// Pi persists provider failures as ordinary assistant messages and resolves
// AgentSession.prompt(), so promise rejection alone cannot detect them. Read
// only the final assistant entry appended by this prompt: unlike the rebuilt
// in-memory message context, SessionManager entries remain append-only across
// prompt-preflight compaction.
function settledPromptProviderError(sessionManager: SessionManager, entryOffset: number): string | null {
  const entries = sessionManager.getEntries();
  for (let index = entries.length - 1; index >= entryOffset; index -= 1) {
    const entry = entries[index];
    if (entry.type !== "message") continue;
    const message = (entry as { message?: { role?: string; stopReason?: string; errorMessage?: string } }).message;
    if (message?.role !== "assistant") continue;
    if (message.stopReason !== "error") return null;
    return message.errorMessage?.trim() || "assistant settled with stopReason error";
  }
  return null;
}

// One model the runtime can hand back, without importing a model type
// directly, and Pi's own reasoning-effort vocabulary taken from the API
// surface Pi already hands this extension.
type BranchModel = NonNullable<ReturnType<ModelRuntime["getModel"]>>;
type BranchEffort = ReturnType<NonNullable<ExtensionAPI["getThinkingLevel"]>>;
type PinnedBranchModel = { model: BranchModel; modelRuntime: ModelRuntime };
type BranchModelResolution = { ok: true; selection: PinnedBranchModel } | { ok: false; reason: string };

// Pi owns the effort vocabulary. The picker's options and every clamp still
// come from Pi's own getSupportedThinkingLevels/clampThinkingLevel, so this
// array exists for exactly one job the type system cannot do at runtime:
// rejecting a hand-edited pin token Pi would not recognize at all. The
// assertion below fails the tracked strict typecheck against the INSTALLED Pi
// package (tests/fm-pi-primary-types.test.sh) the moment Pi adds or removes a
// level, in either direction, so the list cannot drift into a stale Firstmate
// catalog.
const BRANCH_EFFORT_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh", "max"] as const;
type DeclaredBranchEffort = (typeof BRANCH_EFFORT_LEVELS)[number];
const piOwnsTheEffortVocabulary: [DeclaredBranchEffort] extends [BranchEffort]
  ? [BranchEffort] extends [DeclaredBranchEffort]
    ? true
    : never
  : never = true;
void piOwnsTheEffortVocabulary;

// The supervision-branch model pin, owned operator-side by
// docs/configuration.md: one "<provider>/<model-id>" line under this home's
// config/. An absent, unreadable, or unparseable file means no pin, and the
// branch then follows main's own model. Only the FIRST "/" separates the two
// halves, so a provider-qualified model id such as
// openrouter/anthropic/claude survives.
function readModelPin(): { provider: string; modelId: string } | null {
  let stored: string;
  try {
    stored = readFileSync(modelPinFile, "utf8");
  } catch {
    return null;
  }
  const line = (stored.split("\n")[0] ?? "").trim();
  const separator = line.indexOf("/");
  if (separator <= 0 || separator >= line.length - 1) return null;
  return { provider: line.slice(0, separator), modelId: line.slice(separator + 1) };
}

// The supervision-branch effort pin, owned operator-side by the same
// docs/configuration.md section: one Pi thinking-level line under this home's
// config/, independent of the model pin. An absent, unreadable, or
// unrecognized file means no pin, and the branch then follows main's own
// effort.
function readEffortPin(): BranchEffort | null {
  let stored: string;
  try {
    stored = readFileSync(effortPinFile, "utf8");
  } catch {
    return null;
  }
  const line = (stored.split("\n")[0] ?? "").trim();
  return (BRANCH_EFFORT_LEVELS as readonly string[]).includes(line) ? (line as BranchEffort) : null;
}

// Replaces a pin atomically so a failed write leaves the current choice
// intact rather than claiming persistence (the config/calm precedent).
function writePinFile(pinFile: string, selection: string): void {
  mkdirSync(dirname(pinFile), { recursive: true });
  const temporaryPath = `${pinFile}.${process.pid}.${randomUUID()}.tmp`;
  try {
    writeFileSync(temporaryPath, `${selection}\n`, { encoding: "utf8", flag: "wx", mode: 0o600 });
    renameSync(temporaryPath, pinFile);
  } finally {
    rmSync(temporaryPath, { force: true });
  }
}

function clearPinFile(pinFile: string): void {
  rmSync(pinFile, { force: true });
}

function modelLabel(model: { provider: string; id: string }): string {
  return `${model.provider}/${model.id}`;
}

async function parentPid(pid: string): Promise<string> {
  const result = await runCommandAsync("ps", ["-o", "ppid=", "-p", pid]);
  if (result.status !== 0) return "";
  return result.stdout.trim();
}

function parentPidSync(pid: string): string {
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

let ownedLockPid = "";

// Same ownership read as the watcher extension's lockOwnership(): the lock
// names the harness pid, and this process owns it when that pid appears in
// its own ancestry.
//
// The ancestry is walked in full at every boundary that asks, never cached:
// process ancestry is not immutable (a parent exiting reparents its child,
// and pid identity is reused), and this answer is an ownership AUTHORITY
// rather than a hint, so a stale chain would misattribute ownership. Moving
// delivery off Pi's render thread does not trade that away - it awaits each
// `ps` instead of shortening the walk.
//
// The lock file's own answer and the verdict after the walk are shared by the
// awaited and synchronous forms below, so the only difference between them
// stays the wait.
const LOCK_ANCESTRY_DEPTH = 8;

function readLockPid(): { lockPid: string; verdict: LockOwnership | null } {
  ownedLockPid = "";
  let lockPid = "";
  try {
    lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
  } catch {
    return { lockPid: "", verdict: "missing" };
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return { lockPid, verdict: "other" };
  return { lockPid, verdict: null };
}

function ownershipVerdict(lockPid: string, ancestryMatched: boolean): LockOwnership {
  if (ancestryMatched) {
    ownedLockPid = lockPid;
    return "owned";
  }
  return pidAlive(lockPid) ? "other" : "missing";
}

async function lockOwnership(): Promise<LockOwnership> {
  const { lockPid, verdict } = readLockPid();
  if (verdict) return verdict;
  let pid = String(process.pid);
  for (let i = 0; i < LOCK_ANCESTRY_DEPTH; i += 1) {
    if (pid === lockPid) {
      const current = readLockPid();
      if (current.verdict || current.lockPid !== lockPid) return current.verdict ?? "other";
      return ownershipVerdict(lockPid, true);
    }
    pid = await parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return ownershipVerdict(lockPid, false);
}

// Pi types its bash spawn hook as a synchronous function
// (BashSpawnHook: (context) => context), so the guard on the BRANCH's own
// shell commands cannot await. It keeps the synchronous walk unchanged rather
// than caching the authority: what blocks there is one branch shell command
// about to spawn a shell anyway, never an arriving outcome.
function lockOwnershipSync(): LockOwnership {
  const { lockPid, verdict } = readLockPid();
  if (verdict) return verdict;
  let pid = String(process.pid);
  for (let i = 0; i < LOCK_ANCESTRY_DEPTH; i += 1) {
    if (pid === lockPid) return ownershipVerdict(lockPid, true);
    pid = parentPidSync(pid);
    if (!pid || pid === "1") break;
  }
  return ownershipVerdict(lockPid, false);
}

function textOfContent(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((part) => {
        const p = part as { type?: string; text?: string };
        return p && p.type === "text" && typeof p.text === "string" ? p.text : "";
      })
      .filter((piece) => piece.length > 0)
      .join("\n");
  }
  return "";
}

// Operational injections (watcher wakes, away-supervisor escalations, launch
// briefs) are fleet machinery, not captain dialog; the report's volume
// analysis counts them apart from dialog, and mirroring them would feed the
// branch its own supervision traffic back.
function isOperationalUserText(text: string): boolean {
  return classifyFirstmateOperationalText(text) !== undefined;
}

function capMirrorText(text: string): string {
  if (text.length <= MIRROR_MESSAGE_CAP) return text;
  const headLength = Math.ceil(MIRROR_MESSAGE_CAP / 2);
  const tailLength = MIRROR_MESSAGE_CAP - headLength;
  const omitted = text.length - MIRROR_MESSAGE_CAP;
  return `${text.slice(0, headLength)}\n[mirror truncated: ${omitted} characters omitted]\n${text.slice(-tailLength)}`;
}

function readMirrorCursor(): MirrorCursor {
  try {
    const parsed = JSON.parse(readFileSync(mirrorCursorFile, "utf8")) as Partial<MirrorCursor>;
    if (typeof parsed.file === "string" && typeof parsed.index === "number" && parsed.index >= 0) {
      return { file: parsed.file, index: Math.floor(parsed.index) };
    }
  } catch {
    // Absent or torn cursor: re-mirror the current main session from its
    // start. Idempotent context, so over-mirroring is safe; dropping is not.
  }
  return { file: "", index: 0 };
}

function writeMirrorCursor(cursor: MirrorCursor): void {
  mkdirSync(state, { recursive: true });
  writeFileSync(mirrorCursorFile, `${JSON.stringify(cursor)}\n`);
}

type ReadonlyEntries = {
  getSessionFile(): string | undefined;
  getEntries(): Array<{ type: string; customType?: string; data?: unknown }>;
};

function parseOutcomeRow(value: unknown): OutcomeRow | null {
  if (!value || typeof value !== "object") return null;
  const row = value as Record<string, unknown>;
  if (typeof row.seq !== "number" || !Number.isSafeInteger(row.seq) || row.seq < 1) return null;
  if (typeof row.task !== "string" || !row.task) return null;
  if (row.verdict !== "routine" && row.verdict !== "captain") return null;
  if (typeof row.summary !== "string" || !row.summary) return null;
  if (row.silent !== undefined && typeof row.silent !== "boolean") return null;
  const silent = row.silent === true;
  if (silent && (row.task !== "fleet" || row.verdict !== "routine")) return null;
  return { seq: row.seq, task: row.task, verdict: row.verdict, summary: row.summary, silent };
}

function parseVisibleOutcomeRecord(value: unknown): VisibleOutcomeRecord | null {
  if (!value || typeof value !== "object" || (value as { version?: unknown }).version !== 1) return null;
  const row = parseOutcomeRow(value);
  return row ? { version: 1, ...row } : null;
}

function sameOutcome(left: OutcomeRow, right: OutcomeRow): boolean {
  return left.seq === right.seq &&
    left.task === right.task &&
    left.verdict === right.verdict &&
    left.summary === right.summary &&
    left.silent === right.silent;
}

// Volatile mirror-collection state. Instance-scoped and cleared at the
// session replacement boundary, so a replacement extension instance
// reconstructs EXCLUSIVELY from the durable cursor: dialog collected but not
// yet delivered re-mirrors rather than dropping (the durable cursor advances
// only in flushMirror after delivery).
type MirrorCollectionState = {
  collectAnchor: MirrorCursor | null;
  pendingCursor: MirrorCursor | null;
  // Pi emits before_agent_start before it appends that turn's user message to
  // SessionManager. The prompt is mirrored from the event immediately, then
  // this marker suppresses the same persisted entry when turn_end collects it.
  stagedCaptain: { file: string; index: number; text: string } | null;
  // Set at every main session start, where the branch conversation is
  // replaced too (createBranch). The durable cursor records what the PREVIOUS
  // branch conversation already received, so the first collection of a new
  // main session ignores it and re-anchors to the current main session's
  // start; otherwise a /resume or reload, which keeps main's own session file,
  // would leave the fresh branch blind to dialog main itself still has. The
  // reset is bounded by the current main session and costs only re-delivered
  // read-only context, which is idempotent.
  reanchor: boolean;
};

function collectMainDialog(sessionManager: ReadonlyEntries, collection: MirrorCollectionState): MirrorItem[] {
  const file = sessionManager.getSessionFile() ?? "";
  const entries = sessionManager.getEntries();
  const anchor = collection.collectAnchor ?? readMirrorCursor();
  const start = collection.reanchor || anchor.file !== file ? 0 : Math.min(anchor.index, entries.length);
  collection.reanchor = false;
  let currentCaptainIndex = -1;
  for (let index = entries.length - 1; index >= start; index -= 1) {
    const entry = entries[index];
    if (entry.type !== "message") continue;
    const message = (entry as { message?: { role?: string; content?: unknown } }).message;
    if (message?.role !== "user") continue;
    const text = textOfContent(message.content).trim();
    if (!text || isOperationalUserText(text)) continue;
    currentCaptainIndex = index;
    break;
  }
  const items: MirrorItem[] = [];
  for (let index = start; index < entries.length; index += 1) {
    const entry = entries[index];
    if (entry.type !== "message") continue;
    const message = (entry as { message?: { role?: string; content?: unknown } }).message;
    if (!message) continue;
    if (message.role !== "user" && message.role !== "assistant") continue;
    const text = textOfContent(message.content).trim();
    if (!text) continue;
    if (message.role === "user" && isOperationalUserText(text)) continue;
    const staged = collection.stagedCaptain;
    if (
      message.role === "user" &&
      staged?.file === file &&
      staged.index === index &&
      staged.text === text
    ) {
      collection.stagedCaptain = null;
      continue;
    }
    items.push({
      tag: message.role === "user" ? "captain" : "main",
      text: index === currentCaptainIndex ? text : capMirrorText(text),
    });
  }
  collection.collectAnchor = { file, index: entries.length };
  collection.pendingCursor = collection.collectAnchor;
  return items;
}

export default function (pi: ExtensionAPI) {
  type BranchSession = {
    session: AgentSession;
    sessionManager: SessionManager;
    generation: number;
    selectionRevision: number;
  };
  let branch: BranchSession | null = null;
  let branchBroken = "";
  let consecutiveProviderErrors = 0;
  let providerRecovery: ProviderRecovery | null = null;
  // A revision advances only after fm_branch_report has appended successfully,
  // so a prompt can prove that it created a durable outcome after claiming its
  // wake rows without relying on provider text or incidental session shape.
  let durableReportRevision = 0;
  // The task set the wake being handled right now may be reported on, fixed
  // deterministically from the eligible rows before a signal or stale prompt
  // opens and cleared when it settles: exactly the tasks those rows resolve
  // to. fm_branch_report refuses every other task id during such a prompt,
  // `fleet` included, so a report typed from memory about a task the wake
  // never named is never stored or delivered. Null outside a wake prompt and
  // during a heartbeat review, which is not scoped by task.
  let wakeTaskScope: { rows: string[]; tasks: Set<string> } | null = null;
  let mainStreaming = false;
  let shuttingDown = false;
  // Bumps at every session replacement so a stale chain continuation from the
  // prior generation cannot act into the new one.
  let generation = 0;
  // One-time per-generation activation work (marker write + stray branch
  // lease cleanup); ownership itself is re-read lazily at every boundary.
  let activatedGeneration = -1;
  // Serializes branch work: mirror appends and wake turns run strictly in
  // dispatch order, one at a time (the branch runs drain -> handle -> ack
  // serially by design).
  let branchChain: Promise<void> = Promise.resolve();
  // Serializes DELIVERY work. The store scripts and the ownership walk are
  // awaited rather than synchronous now (lib/fm-async-exec.ts), which means a
  // second outcome, a turn boundary, or main's acknowledgement can reach this
  // extension while an earlier one is still between two of its own steps.
  // Every such unit runs to completion here before the next one starts, so
  // the guarantees the single thread used to provide for free - one delivery
  // at a time, the durable append before anything visible, the read cursor
  // advanced before the next reader sees the row, one activation per
  // generation - are properties of this queue instead.
  //
  // A queued unit must never await another queued unit: each one is a bounded
  // store/ownership sequence, and the branch prompt it may lead to is
  // scheduled on branchChain rather than held here.
  let deliveryChain: Promise<void> = Promise.resolve();

  function enqueueDelivery<T>(unit: () => Promise<T>): Promise<T> {
    const queued = deliveryChain.then(unit);
    deliveryChain = queued.then(
      () => {},
      () => {},
    );
    return queued;
  }
  const pendingMirror: MirrorItem[] = [];
  const mirrorCollection: MirrorCollectionState = {
    collectAnchor: null,
    pendingCursor: null,
    stagedCaptain: null,
    // The first branch conversation of a process is new (see
    // branchSessionGeneration), so its first collection re-anchors too, even
    // if this instance never sees a session_start of its own.
    reanchor: true,
  };
  let currentMainSession: ReadonlyEntries | null = null;
  // Volatile view of the open processing request: the sequences it presented,
  // how many turns it has opened for that set, whether a
  // presentation is still pending its run boundary, and whether a copy is
  // queued for the captain's next prompt. The durable truth is the store's
  // processed marker; this only paces re-presentation and resets with the
  // session generation.
  type ProcessingState = { sequences: string; through: number; triggered: number; pending: boolean; nextTurnQueued: boolean };
  let processing: ProcessingState | null = null;
  let processedInitializedGeneration = -1;
  // One revision for BOTH selections: a model or effort change invalidates an
  // in-flight branch build exactly the same way.
  let branchSelectionRevision = 0;
  // The branch CONVERSATION is scoped to one main session. This records which
  // session generation the current branch conversation belongs to, and only a
  // record from the CURRENT generation is ever reopened, so every main session
  // start - cold start, /new, /resume, /fork, reload - starts the branch on a
  // new conversation instead of dragging an older thread's memory into today's
  // supervision rules. The starting -1 makes a process's first build new even
  // if this instance never sees a session_start. Within one main session the
  // record is what a model or effort change reopens.
  let branchSessionGeneration = -1;
  let branchSessionFile = "";
  // Main's own current model, tracked from the contexts Pi already hands this
  // extension plus its model_select event, because createBranch runs at wake
  // time with no context of its own. It is what "follow main" applies.
  let mainModel: { provider: string; id: string } | null = null;
  // Main's own model registry, captured from the contexts Pi hands this
  // extension the same way mainModel is. It is the ONLY read path to
  // providers an extension registered at runtime (pi-devin-auth's "devin"),
  // which the branch's isolated ModelRuntime cannot see on its own.
  let mainModelRegistry: ModelRegistry | null = null;

  // Main's own current effort needs no such tracking: Pi answers it directly
  // on demand, including at wake time. It throws only when the extension
  // runtime is unbound or the captured API is stale, which is never a reason
  // to refuse a wake.
  function mainEffort(): BranchEffort | undefined {
    try {
      return pi.getThinkingLevel?.();
    } catch {
      return undefined;
    }
  }

  function rememberMainModel(ctx?: { model?: { provider: string; id: string }; modelRegistry?: ModelRegistry }): void {
    if (ctx?.model) mainModel = { provider: ctx.model.provider, id: ctx.model.id };
    if (ctx?.modelRegistry) mainModelRegistry = ctx.modelRegistry;
  }

  function deliverBranchHealthNote(text: string): void {
    const message = { customType: "fm-branch-merge", content: `${MERGE_NOTE_BOAT} ${text}`, display: true };
    if (mainStreaming) pi.sendMessage(message, { deliverAs: "nextTurn" });
    else pi.sendMessage(message, {});
  }

  function recordSettledProviderError(detail: string): void {
    consecutiveProviderErrors += 1;
    if (consecutiveProviderErrors < PROVIDER_ERROR_LATCH_THRESHOLD && !providerRecovery) return;
    const previousCooldownMs = providerRecovery?.cooldownMs;
    const firstLatch = previousCooldownMs === undefined;
    const cooldownMs = firstLatch
      ? PROVIDER_REPROBE_BASE_MS
      : Math.min(PROVIDER_REPROBE_MAX_MS, previousCooldownMs * 2);
    branchBroken = detail;
    providerRecovery = {
      cooldownMs,
      retryNotBefore: Date.now() + cooldownMs,
      probeInFlight: false,
    };
    if (firstLatch) {
      deliverBranchHealthNote("Supervision branch paused after repeated provider errors; main will handle wakes while it cools down.");
    }
  }

  function recordDurableBranchReport(reportGeneration: number, reportSelectionRevision: number): void {
    if (reportGeneration !== generation || reportSelectionRevision !== branchSelectionRevision) return;
    consecutiveProviderErrors = 0;
    if (!providerRecovery) return;
    branchBroken = "";
    providerRecovery = null;
    deliverBranchHealthNote("Supervision branch recovered after a successful cooldown probe.");
  }

  function finishProviderProbe(probeGeneration: number, probeSelectionRevision: number): void {
    if (probeGeneration !== generation || probeSelectionRevision !== branchSelectionRevision || !providerRecovery) return;
    providerRecovery.probeInFlight = false;
    if (branchBroken && providerRecovery.retryNotBefore <= Date.now()) {
      providerRecovery.retryNotBefore = Date.now() + providerRecovery.cooldownMs;
    }
  }

  // Resolves one model against the isolated branch runtime using only the
  // credentials that runtime already holds - the branch runs in the same home
  // and same user as main, so stored credentials keep their own semantics
  // (OAuth stays OAuth, an API key stays an API key) and nothing is ever
  // installed, converted, derived, or overwritten here.
  // A provider that exists only because an extension registered it into
  // main's runtime (pi-devin-auth's "devin", whose streamSimple is the custom
  // gRPC path no static catalog can express) is invisible to an isolated
  // branch runtime until its registration is copied across. The config object
  // carries that streamSimple and oauth wiring by reference, so copying it
  // reuses the provider's own registration rather than reimplementing its
  // wire protocol; the copy is never persisted and stays scoped to this one
  // runtime. One registration that fails to compose must not blind the rest,
  // so each copy is isolated.
  function copyExtensionProviders(modelRuntime: ModelRuntime): void {
    if (!mainModelRegistry) return;
    let providerIds: readonly string[];
    try {
      providerIds = mainModelRegistry.getRegisteredProviderIds();
    } catch {
      return;
    }
    for (const providerId of providerIds) {
      try {
        const config = mainModelRegistry.getRegisteredProviderConfig(providerId);
        if (config) modelRuntime.registerProvider(providerId, config);
      } catch {
        // A registration that fails to compose in the isolated runtime leaves
        // that provider unavailable, exactly as if it were never copied.
      }
    }
  }

  async function resolveBranchModel(provider: string, modelId: string): Promise<BranchModelResolution> {
    const label = `${provider}/${modelId}`;
    const modelRuntime = await ModelRuntime.create();
    let model = modelRuntime.getModel(provider, modelId) as BranchModel | undefined;
    if (!model) {
      copyExtensionProviders(modelRuntime);
      model = modelRuntime.getModel(provider, modelId) as BranchModel | undefined;
      if (model) {
        // A just-registered provider's auth check has not run yet; resolve it
        // now so the hasConfiguredAuth verdict below is real rather than the
        // provisional entry registration leaves behind.
        try {
          await modelRuntime.refresh({ providers: [provider], allowNetwork: false });
        } catch {
          // A failed availability refresh is answered by hasConfiguredAuth.
        }
      }
    }
    if (!model) return { ok: false, reason: `${label} is unavailable to the isolated branch runtime` };
    if (!modelRuntime.hasConfiguredAuth(provider)) {
      return { ok: false, reason: `${label} has no configured credentials in the isolated branch runtime` };
    }
    return { ok: true, selection: { model, modelRuntime } };
  }

  async function preparePinnedBranchModel(pin: { provider: string; modelId: string }): Promise<PinnedBranchModel> {
    const resolved = await resolveBranchModel(pin.provider, pin.modelId);
    if (!resolved.ok) {
      throw new Error(`supervision model pin ${resolved.reason} (config/supervision-branch-model)`);
    }
    return resolved.selection;
  }

  // The pin file's CURRENT state decides the model on every branch build,
  // create and reopen alike, and it overrides Pi's restore of whatever model
  // a reopened branch session recorded. With a pin, that model. With no pin,
  // main's own model is applied EXPLICITLY - otherwise clearing the pin would
  // report that the branch follows main while the reopened session quietly
  // restored the model an earlier pin left behind. Only when main's model is
  // genuinely unknown, or the isolated runtime cannot run it, does the build
  // fall back to passing no override at all, which is the pre-feature
  // behavior; an unpinned branch is never refused over model choice alone.
  async function branchModelSelection(): Promise<PinnedBranchModel | undefined> {
    const pin = readModelPin();
    if (pin) return preparePinnedBranchModel(pin);
    if (!mainModel) return undefined;
    try {
      const resolved = await resolveBranchModel(mainModel.provider, mainModel.id);
      return resolved.ok ? resolved.selection : undefined;
    } catch {
      return undefined;
    }
  }

  async function effectiveBranchModel(selected: BranchModel | undefined): Promise<BranchModel | undefined> {
    if (selected) return selected;
    try {
      const recorded = readFileSync(sessionPointer, "utf8").trim();
      if (!recorded || !existsSync(recorded)) return undefined;
      const context = SessionManager.open(recorded, sessionsDir).buildSessionContext();
      if (context.messages.length === 0 || !context.model) return undefined;
      const resolved = await resolveBranchModel(context.model.provider, context.model.modelId);
      return resolved.ok ? resolved.selection.model : undefined;
    } catch {
      return undefined;
    }
  }

  // The effort pin file's CURRENT state decides the branch's reasoning effort
  // on every branch build, create and reopen alike, on exactly the model-pin
  // contract above and for exactly the same reason: a reopened branch session
  // records the effort it last ran under, so an unpinned branch must apply
  // main's own effort EXPLICITLY or clearing a pin would silently restore the
  // level that pin left behind. Pi owns the clamp, so a level the branch's
  // model does not support becomes that model's nearest supported level
  // rather than a refusal - the branch is never refused over effort. Only
  // when main's own effort is unknowable too does the build fall back to
  // passing no effort override at all, which is the behavior from before this
  // file existed.
  function branchEffortSelection(model: BranchModel | undefined): BranchEffort | undefined {
    const chosen = readEffortPin() ?? mainEffort();
    if (chosen === undefined) return undefined;
    return model ? (clampThinkingLevel(model, chosen) as BranchEffort) : chosen;
  }

  async function generationOwnsLock(expectedGeneration: number): Promise<boolean> {
    if (shuttingDown || expectedGeneration !== generation) return false;
    const ownership = await lockOwnership();
    return !shuttingDown && expectedGeneration === generation && ownership === "owned";
  }

  // The synchronous counterpart, for the two places Pi's own API is
  // synchronous: the bash spawn hook and the wake-offer handshake. It reads
  // the same uncached authority and performs no activation side effect of its
  // own, so it can gate a decision that cannot wait without granting one.
  function generationOwnsLockSync(expectedGeneration: number): boolean {
    if (shuttingDown || expectedGeneration !== generation) return false;
    return lockOwnershipSync() === "owned";
  }

  function markLoaded(): void {
    try {
      mkdirSync(state, { recursive: true });
      writeFileSync(loadedMarker, `${process.pid}\n`);
    } catch {
      // Diagnostic marker only; never block activation on it.
    }
  }

  // A replaced branch conversation must not leave its per-task leases behind
  // (the session-lock holder pid is still alive, so the sweep alone would
  // keep them). One bulk release per generation, at activation.
  async function releaseBranchLeases(expectedGeneration: number): Promise<boolean> {
    if (!(await generationOwnsLock(expectedGeneration))) return false;
    const result = await runCommandAsync("bash", [leaseScript, "release-actor", "--actor", "branch"], {
      cwd: fmRoot,
      env: { ...scriptEnv, FM_SUPERVISION_ACTOR: "branch" },
    });
    return result.status === 0;
  }

  // Lazy, per-action ownership evaluation (see the header). Returns true only
  // when this session owns the fleet lock right now; the first true evaluation
  // of a generation also writes the diagnostic marker and clears stray branch
  // leases from a prior generation.
  async function actingAsOwner(expectedGeneration = generation): Promise<boolean> {
    if (!(await generationOwnsLock(expectedGeneration))) return false;
    if (activatedGeneration !== expectedGeneration) {
      if (!(await releaseBranchLeases(expectedGeneration))) return false;
      if (!(await generationOwnsLock(expectedGeneration))) return false;
      if (!(await activateEligibleRowsOwner(state, wakeGrantScript, process.pid, String(expectedGeneration)))) {
        return false;
      }
      if (!(await generationOwnsLock(expectedGeneration))) {
        await deactivateEligibleRowsOwner(state, wakeGrantScript, process.pid, String(expectedGeneration));
        return false;
      }
      markLoaded();
      activatedGeneration = expectedGeneration;
    }
    return generationOwnsLock(expectedGeneration);
  }

  async function runOutcomeScript(args: string[]): Promise<{ ok: boolean; stdout: string; detail: string }> {
    const result = await runCommandAsync("bash", [outcomeScript, ...args], {
      cwd: fmRoot,
      env: scriptEnv,
    });
    if (result.status === 0) return { ok: true, stdout: (result.stdout || "").trim(), detail: "" };
    return {
      ok: false,
      stdout: "",
      detail: `fm-branch-outcome.sh exited ${result.status ?? "none"}: ${(result.stderr || "").trim()}`,
    };
  }

  // A captain outcome is delivered by a durable, rendered session entry, not
  // by asking main's model to acknowledge a hidden custom message. The store
  // sequence is the idempotency key: a reload after appendEntry but before
  // mark-read finds the same record and advances the cursor without appending
  // a duplicate. A conflicting record for one sequence fails closed.
  function ensureVisibleCaptainOutcome(row: OutcomeRow): boolean {
    if (!currentMainSession || row.verdict !== "captain") return false;
    let matching = false;
    for (const entry of currentMainSession.getEntries()) {
      if (entry.type !== "custom" || entry.customType !== VISIBLE_OUTCOME_ENTRY_TYPE) continue;
      const entrySeq = entry.data && typeof entry.data === "object"
        ? (entry.data as { seq?: unknown }).seq
        : undefined;
      if (entrySeq !== row.seq) continue;
      const recorded = parseVisibleOutcomeRecord(entry.data);
      if (!recorded || !sameOutcome(recorded, row)) return false;
      matching = true;
    }
    if (matching) return true;
    const record: VisibleOutcomeRecord = { version: 1, ...row };
    try {
      pi.appendEntry(VISIBLE_OUTCOME_ENTRY_TYPE, record);
    } catch {
      return false;
    }
    return currentMainSession.getEntries().some((entry) => {
      if (entry.type !== "custom" || entry.customType !== VISIBLE_OUTCOME_ENTRY_TYPE) return false;
      const recorded = parseVisibleOutcomeRecord(entry.data);
      return recorded !== null && sameOutcome(recorded, row);
    });
  }

  function deliverRoutineOutcome(row: OutcomeRow): void {
    const message = {
      customType: "fm-branch-merge",
      content: `${MERGE_NOTE_BOAT} ${row.task}: ${row.summary}`,
      display: !(row.task === "fleet" && row.silent),
    };
    if (mainStreaming) pi.sendMessage(message, { deliverAs: "nextTurn" });
    else pi.sendMessage(message, {});
  }

  // Captain rows that are read (their visible entry exists) but not yet
  // acknowledged as processed by main, in sequence order. null means the store
  // could not be read safely, never "nothing".
  async function readUnprocessedOutcomes(expectedGeneration: number): Promise<OutcomeRow[] | null> {
    if (!(await generationOwnsLock(expectedGeneration))) return null;
    const listed = await runOutcomeScript(["unprocessed"]);
    if (!listed.ok) return null;
    const rows: OutcomeRow[] = [];
    for (const line of listed.stdout.split("\n")) {
      if (!line) continue;
      let row: OutcomeRow | null = null;
      try {
        row = parseOutcomeRow(JSON.parse(line));
      } catch {
        row = null;
      }
      if (!row || row.verdict !== "captain") return null;
      rows.push(row);
    }
    return rows;
  }

  // Encoding shells out, so it can fail on a broken checkout. This file's
  // failure direction applies: a request that cannot be typed is still
  // delivered as plain text, because an untyped request main can still act on
  // beats an outcome that is never processed.
  async function processingRequestInput(rows: OutcomeRow[]): Promise<string> {
    const through = rows[rows.length - 1].seq;
    const listed = rows.map((row) => `[seq ${row.seq}] ${row.task}: ${row.summary}`).join("\n");
    const body = `${PROCESSING_INSTRUCTION.replace("{N}", String(through))}\n\n${listed}`;
    try {
      return await encodeFirstmateOperationalInputWith(runCommandAsync, "branch-outcome", body);
    } catch {
      return body;
    }
  }

  // Present every unprocessed captain outcome to main as ONE sequence-keyed
  // processing request. The first PROCESSING_TRIGGERED_ATTEMPTS presentations
  // of a given sequence set open a turn of their own (queued as a follow-up
  // while main is busy); after that the request rides the captain's next
  // prompt instead, once per run, and a session replacement starts the
  // triggered budget over. Nothing here advances the processed marker: only
  // fm_branch_processed does, keyed to the sequence main acknowledges.
  async function presentUnprocessedOutcomes(expectedGeneration: number): Promise<boolean> {
    const rows = await readUnprocessedOutcomes(expectedGeneration);
    if (rows === null) return false;
    if (rows.length === 0) {
      processing = null;
      return true;
    }
    const through = rows[rows.length - 1].seq;
    const sequences = rows.map((row) => row.seq).join(",");
    if (processing?.pending) return true;
    // Encoding the request body shells out, so it is done before the volatile
    // processing state is touched: the queue keeps another delivery out, but
    // main's own agent_start still runs during that await and clears
    // nextTurnQueued, and a decision recorded before the await could be acted
    // on after it.
    const content = await processingRequestInput(rows);
    if (!(await generationOwnsLock(expectedGeneration))) return false;
    if (processing?.pending) return true;
    if (!processing || processing.sequences !== sequences) {
      processing = { sequences, through, triggered: 0, pending: false, nextTurnQueued: false };
    }
    // A presentation already sent is consumed by the run it joins or opens;
    // until that run settles, sending a widened or identical copy would hand
    // overlapping requests to the same run.
    const message = { customType: PROCESSING_MESSAGE_TYPE, content, display: false };
    if (processing.triggered < PROCESSING_TRIGGERED_ATTEMPTS) {
      processing.triggered += 1;
      processing.pending = true;
      pi.sendMessage(message, { triggerTurn: true, deliverAs: "followUp" });
    } else if (!processing.nextTurnQueued) {
      processing.nextTurnQueued = true;
      processing.pending = true;
      pi.sendMessage(message, { deliverAs: "nextTurn" });
    }
    return true;
  }

  // Reconcile in sequence order so the cursor can never cross a captain row
  // whose visible entry is absent. This is also the reload/crash recovery
  // path and runs before new branch work is accepted. With `present`, every
  // captain row that is now read but still unprocessed is handed to main as
  // one processing request; callers that run inside a main turn (turn_end)
  // leave presentation to the run boundary (agent_settled) instead, so one
  // multi-tool run never receives duplicate requests.
  async function reconcileUnreadOutcomes(expectedGeneration: number, present = true): Promise<boolean> {
    if (!(await generationOwnsLock(expectedGeneration))) return false;
    // One-time migration per generation: a home whose outcomes were all
    // delivered before the processed marker existed treats them as processed
    // rather than re-presenting its whole history. Runs before any new row
    // can be read below, so nothing delivered from here on is ever skipped.
    if (processedInitializedGeneration !== expectedGeneration) {
      if (!(await runOutcomeScript(["processed-init"])).ok) return false;
      processedInitializedGeneration = expectedGeneration;
    }
    const unread = await runOutcomeScript(["unread"]);
    if (!unread.ok) return false;
    if (unread.stdout) {
      if (!currentMainSession) return false;
      for (const line of unread.stdout.split("\n")) {
        let row: OutcomeRow | null = null;
        try {
          row = parseOutcomeRow(JSON.parse(line));
        } catch {
          row = null;
        }
        if (!row) return false;
        // The last cancellation point of this row: everything from here to
        // its mark-read is synchronous delivery plus the awaited script that
        // records it, with no second ownership test in between. That is
        // deliberate. Delivering and then declining to advance the cursor
        // because the session was replaced mid-write would leave the row
        // unread and deliver it a second time; the cursor records that the
        // row WAS delivered, which stays true across a replacement.
        if (!(await generationOwnsLock(expectedGeneration))) return false;
        // KNOWN PRE-EXISTING LIMITATION, unchanged by moving this work off Pi's
        // render thread and tracked as
        // fm-pi-routine-delivery-idempotency-followup-r1: if the mark-read
        // below fails after a ROUTINE note was already delivered, the row stays
        // unread and the next reconciliation sends that note a second time,
        // because a routine note is a plain message with no sequence-keyed
        // record to recognize. A captain row cannot duplicate that way -
        // ensureVisibleCaptainOutcome finds its own earlier entry by store
        // sequence. Closing the routine gap needs a durable, idempotent
        // representation for routine delivery, which changes the delivery
        // contract rather than this ordering, so it is deliberately not done
        // here.
        if (row.verdict === "captain") {
          if (!ensureVisibleCaptainOutcome(row)) return false;
        } else {
          deliverRoutineOutcome(row);
        }
        if (!(await runOutcomeScript(["mark-read", "--through", String(row.seq)])).ok) return false;
      }
    }
    if (!present) return true;
    return presentUnprocessedOutcomes(expectedGeneration);
  }

  function wakeScopeRefusal(task: string): string {
    if (!wakeTaskScope || wakeTaskScope.tasks.has(task)) return "";
    const named = [...wakeTaskScope.tasks].sort().join(", ");
    const rows = wakeTaskScope.rows.join(", ");
    return `report refused: the wake being handled (row ${rows}) names ${named}, not ${task}; report only that task, never fleet or a task from memory`;
  }

  function createReportTool(toolGeneration: number): ToolDefinition {
    return {
      name: "fm_branch_report",
      label: "Report supervision outcome",
      description:
        "Record the outcome of one handled fleet event: write it durably to the outcome store, then merge it into the captain-facing main conversation. verdict captain persists an exact visible entry and opens one sequence-keyed processing turn on main that stays open until main acknowledges it; routine notes render unless silent marks a no-change heartbeat.",
      parameters: Type.Object({
        task: Type.String({ description: "The task id the event belongs to (or 'fleet' for fleet-wide events)" }),
        verdict: Type.Union([Type.Literal("routine"), Type.Literal("captain")], {
          description:
            "Use captain or routine exactly as the \"Verdict: routine or captain\" section of your system prompt decides; that section is the one owner of the rule.",
        }),
        summary: Type.String({
          description:
            "One or two sentences in captain outcome language; include the full https:// PR URL when a PR is involved",
        }),
        wake: Type.Optional(Type.String({ description: "The wake reason line this outcome answers" })),
        silent: Type.Optional(Type.Boolean({
          description: "True only when a fleet-wide heartbeat review found literally nothing worth reporting; omit or use false whenever any action was taken or any routine result is worth a note",
        })),
      }),
      execute: async (_toolCallId, params) => {
        const task = String((params as { task: unknown }).task || "").trim();
        const verdictRaw = String((params as { verdict: unknown }).verdict || "");
        const summary = String((params as { summary: unknown }).summary || "").trim();
        const wake = String((params as { wake?: unknown }).wake ?? "").trim();
        const silent = (params as { silent?: unknown }).silent === true;
        if (!task || !summary || (verdictRaw !== "routine" && verdictRaw !== "captain") || (silent && (task !== "fleet" || verdictRaw !== "routine"))) {
          return {
            content: [{ type: "text", text: "invalid report: task, verdict (routine|captain), and summary are required" }],
            details: undefined,
            isError: true,
          };
        }
        const verdict = verdictRaw as Verdict;
        const scopeRefusal = wakeScopeRefusal(task);
        if (scopeRefusal) {
          return { content: [{ type: "text", text: scopeRefusal }], details: undefined, isError: true };
        }
        const appendArgs = ["append", "--task", task, "--verdict", verdict, "--summary", summary, "--silent", String(silent)];
        if (wake) appendArgs.push("--wake", wake);
        // Ownership, the durable append, and the delivery it authorizes are
        // ONE unit of the delivery queue: store-before-visible-delivery and
        // this report's place in sequence order are exactly what another
        // outcome or turn boundary arriving mid-append must not break into.
        return enqueueDelivery(async () => {
          if (!(await actingAsOwner(toolGeneration))) {
            return {
              content: [{ type: "text", text: "report refused: supervision session was replaced or lost lock ownership" }],
              details: undefined,
              isError: true,
            };
          }
          const appended = await runOutcomeScript(appendArgs);
          if (!appended.ok) {
            return {
              content: [{ type: "text", text: `outcome store append failed (nothing merged): ${appended.detail}` }],
              details: undefined,
              isError: true,
            };
          }
          durableReportRevision += 1;
          const seq = Number(appended.stdout);
          if (!Number.isSafeInteger(seq) || seq < 1 || !(await reconcileUnreadOutcomes(toolGeneration))) {
            return {
              content: [{ type: "text", text: `recorded seq ${appended.stdout}, but visible delivery or cursor advancement failed` }],
              details: undefined,
              isError: true,
            };
          }
          return {
            content: [{ type: "text", text: `recorded seq ${appended.stdout} and delivered [${verdict}] into main` }],
            details: undefined,
          };
        });
      },
    };
  }

  async function createBranch(
    branchGeneration: number,
    selectionRevision: number,
  ): Promise<{ session: AgentSession; sessionManager: SessionManager }> {
    // Resolved first, before any session file or prompt work: a model pin Pi
    // cannot honor must fail before this build leaves anything behind. Every
    // branch build goes through here - the new conversation each main session
    // start opens, and the reopen after a model or effort change inside one
    // session - so resolving the model and the effort here is what makes the
    // captain's current choices authoritative on all of them.
    const pinned = await branchModelSelection();
    const effort = branchEffortSelection(pinned?.model);
    const prompt = await runCommandAsync("bash", [promptScript], {
      cwd: fmRoot,
      env: scriptEnv,
      maxBuffer: 4 * 1024 * 1024,
    });
    if (prompt.status !== 0 || !prompt.stdout || prompt.stdout.length < 1024) {
      throw new Error(
        `fm-branch-prompt.sh did not produce a usable branch prompt (status=${prompt.status ?? "none"}): ${(prompt.stderr || "").trim()}`,
      );
    }
    if (!(await actingAsOwner(branchGeneration))) throw new Error("supervision session was replaced or lost lock ownership");
    mkdirSync(sessionsDir, { recursive: true });
    let sessionManager: SessionManager | null = null;
    // Only this main session's own branch conversation is continued. The
    // recorded pointer is never reopened across a session start, so a rebuild
    // for a model or effort change keeps today's thread while a session start
    // always opens a new one (branchSessionGeneration).
    if (branchSessionGeneration === branchGeneration && branchSessionFile) {
      try {
        if (existsSync(branchSessionFile)) sessionManager = SessionManager.open(branchSessionFile, sessionsDir);
      } catch {
        sessionManager = null;
      }
    }
    if (!sessionManager) {
      sessionManager = SessionManager.create(fmRoot, sessionsDir);
    }
    branchSessionGeneration = branchGeneration;
    branchSessionFile = sessionManager.getSessionFile() ?? "";
    // The branch loads no project resources at all: extensions off (so it can
    // never spawn its own branch), skills/context files off (they vary per
    // home and would destabilize the byte-stable prefix). Its whole standing
    // context is the generator's prompt.
    const loader = new DefaultResourceLoader({
      cwd: fmRoot,
      agentDir: getAgentDir(),
      noExtensions: true,
      noSkills: true,
      noPromptTemplates: true,
      noThemes: true,
      noContextFiles: true,
      systemPrompt: prompt.stdout,
      extensionFactories: [
        {
          name: "fm-branch-cache-key",
          factory: (branchPi: ExtensionAPI) => {
            branchPi.on("before_provider_request", (event) => {
              const payload = event.payload;
              // Only providers whose request already carries Pi's default
              // per-session prompt_cache_key get the shared per-home override;
              // any other provider payload passes through untouched.
              if (payload && typeof payload === "object" && "prompt_cache_key" in payload) {
                return { ...(payload as Record<string, unknown>), prompt_cache_key: branchCacheKey };
              }
            });
          },
        },
      ],
    });
    await loader.reload();
    if (!(await actingAsOwner(branchGeneration))) throw new Error("supervision session was replaced or lost lock ownership");
    const leaseHolderPid = ownedLockPid;
    const bashTool = createBashToolDefinition(fmRoot, {
      spawnHook: (context) => {
        // Activation has always already happened by the time the branch can
        // run a shell command, so an unactivated generation is refused here
        // rather than quietly granted.
        if (activatedGeneration !== branchGeneration || !generationOwnsLockSync(branchGeneration)) {
          throw new Error("bash refused: supervision session was replaced or lost lock ownership");
        }
        return {
          ...context,
          // Loud accidental-override guard (captain-decided): the actor
          // variables are readonly inside the branch's own shell, so an
          // accidental in-shell reassignment fails loudly instead of silently
          // impersonating main. Confused-agent-grade by design; the threat
          // model lives in bin/fm-lease-lib.sh.
          command: `readonly FM_SUPERVISION_ACTOR FM_LEASE_HOLDER_PID
(
${context.command}
)`,
          env: {
            ...context.env,
            ...scriptEnv,
            FM_SUPERVISION_ACTOR: "branch",
            FM_LEASE_HOLDER_PID: leaseHolderPid,
          },
        };
      },
    });
    const created = await createAgentSession({
      cwd: fmRoot,
      sessionManager,
      resourceLoader: loader,
      tools: [...BRANCH_TOOL_NAMES],
      customTools: [
        bashTool as unknown as ToolDefinition,
        createReportTool(branchGeneration),
      ],
      ...(pinned ? { model: pinned.model, modelRuntime: pinned.modelRuntime } : {}),
      ...(effort === undefined ? {} : { thinkingLevel: effort }),
    });
    if (!(await actingAsOwner(branchGeneration))) {
      try {
        created.session.dispose();
      } catch {}
      throw new Error("supervision session was replaced or lost lock ownership");
    }
    try {
      writeFileSync(sessionPointer, `${sessionManager.getSessionFile()}\n`);
    } catch {
      // The pointer is a durable record of the branch's current conversation
      // for operators and for the effort picker's last-resort model lookup;
      // reopening reads the in-memory record above, so a failed write costs
      // neither the live session nor its replacement.
    }
    return { session: created.session, sessionManager };
  }

  async function ensureBranch(expectedGeneration: number, recoveryProbe = false): Promise<BranchSession> {
    if (!(await actingAsOwner(expectedGeneration))) throw new Error("supervision session was replaced or lost lock ownership");
    if (branchBroken && !(recoveryProbe && providerRecovery?.probeInFlight)) throw new Error(branchBroken);
    if (branch) return branch;
    while (true) {
      const buildRevision = branchSelectionRevision;
      try {
        const created = await createBranch(expectedGeneration, buildRevision);
        if (buildRevision !== branchSelectionRevision) {
          try {
            created.session.dispose();
          } catch {}
          continue;
        }
        if (!(await actingAsOwner(expectedGeneration))) {
          try {
            created.session.dispose();
          } catch {}
          throw new Error("supervision session was replaced or lost lock ownership");
        }
        branch = {
          ...created,
          generation: expectedGeneration,
          selectionRevision: buildRevision,
        };
        return branch;
      } catch (error) {
        if (buildRevision !== branchSelectionRevision) continue;
        if (expectedGeneration === generation && !shuttingDown) {
          branchBroken = error instanceof Error ? error.message : String(error);
        }
        throw error;
      }
    }
  }

  async function flushMirror(session: AgentSession, expectedGeneration: number): Promise<void> {
    if (!(await actingAsOwner(expectedGeneration))) throw new Error("supervision session no longer owns the fleet lock");
    while (pendingMirror.length > 0) {
      const item = pendingMirror[0];
      if (!(await actingAsOwner(expectedGeneration))) throw new Error("supervision session no longer owns the fleet lock");
      await session.sendCustomMessage(
        { customType: "fm-main-mirror", content: `[${item.tag}] ${item.text}`, display: false },
        {},
      );
      if (!(await actingAsOwner(expectedGeneration))) throw new Error("supervision session was replaced during mirror delivery");
      pendingMirror.shift();
    }
    if (mirrorCollection.pendingCursor) {
      if (!(await actingAsOwner(expectedGeneration))) throw new Error("supervision session no longer owns the fleet lock");
      writeMirrorCursor(mirrorCollection.pendingCursor);
      mirrorCollection.pendingCursor = null;
    }
  }

  function enqueueWake(message: string, acceptedGeneration: number, recoveryProbe = false): Promise<void> {
    const acceptedSelectionRevision = branchSelectionRevision;
    const delivery = branchChain
      .then(async () => {
        if (shuttingDown || acceptedGeneration !== generation) {
          throw new Error("supervision session was replaced before handling the accepted wake");
        }
        // The ownership and reconcile checks the dispatch handler could not
        // make synchronously (see the accept contract above). Both must pass
        // before this wake reaches a branch, exactly as they did when they
        // ran ahead of accept().
        if (!(await enqueueDelivery(() => actingAsOwner(acceptedGeneration)))) {
          throw new Error("supervision session no longer owns the fleet lock");
        }
        if (!(await enqueueDelivery(() => reconcileUnreadOutcomes(acceptedGeneration)))) {
          if (acceptedGeneration === generation) {
            branchBroken = "could not reconcile unread supervision outcomes into main";
          }
          throw new Error("could not reconcile unread supervision outcomes into main");
        }
        const branchForWake = await ensureBranch(acceptedGeneration, recoveryProbe);
        const { session, sessionManager } = branchForWake;
        await flushMirror(session, acceptedGeneration);
        if (!(await actingAsOwner(acceptedGeneration))) throw new Error("supervision session no longer owns the fleet lock");
        const heartbeat = /^heartbeat($|:)/.test(message);
        const scope = scopeForUnreadWake(state, heartbeat);
        // A newly-arrived main-owned (check-kind) row never bounces this
        // whole recheck back to main - scopeForUnreadWake excludes it from
        // eligibleSeqs rather than vetoing the scan, in a heartbeat review as
        // in every other, so it stays queued for main while whatever else is
        // eligible right now still reaches the branch. A genuinely empty
        // queue, or a queue that simply has nothing (or nothing further)
        // eligible for the branch right now, is an ordinary quiet no-op - not
        // a fault, so it is never reported back to main. Only a scan
        // scopeForUnreadWake itself marks corrupted (the queue or its
        // metadata could not be read safely, or an unresolvable task-local
        // row) still falls back to main.
        if (scope.status === "empty" || (!scope.corrupted && scope.eligibleSeqs.length === 0)) return;
        if (scope.corrupted) {
          throw new Error("the unread wake queue could not be read safely");
        }
        const grant = await writeEligibleRowsSnapshot(
          state,
          scope.eligibleSeqs,
          wakeGrantScript,
          String(acceptedGeneration),
        );
        if (grant === "main-owned") throw new Error("the wake rows are already claimed by main");
        if (grant !== "published") throw new Error("could not record the branch's eligible row snapshot");
        // A row can still arrive between this re-check and the model starting
        // the drain; that residual is accepted by the confused-agent-grade boundary.
        const reportRevisionBeforePrompt = durableReportRevision;
        const entryOffset = sessionManager.getEntries().length;
        wakeTaskScope = heartbeat ? null : { rows: [...scope.eligibleSeqs], tasks: new Set(scope.eligibleTasks) };
        try {
          await session.prompt(
            `FIRSTMATE SUPERVISION WAKE: ${message}\n\nHandle this per your operating procedure and finish with fm_branch_report.`,
          );
        } finally {
          wakeTaskScope = null;
        }
        const providerError = settledPromptProviderError(sessionManager, entryOffset);
        if (providerError) {
          const detail = `supervision branch provider failed after construction: ${providerError}`;
          if (
            branchForWake.generation === generation &&
            branchForWake.selectionRevision === branchSelectionRevision
          ) {
            recordSettledProviderError(detail);
          }
          throw new Error(detail);
        }
        if (durableReportRevision <= reportRevisionBeforePrompt) {
          throw new Error("supervision branch prompt settled but produced no durable outcome for its claimed wake rows");
        }
        recordDurableBranchReport(branchForWake.generation, branchForWake.selectionRevision);
        if (!(await releaseEligibleRowsSnapshot(state, wakeGrantScript, String(acceptedGeneration)))) {
          throw new Error("could not release the branch's settled wake-row grant");
        }
      })
      .catch(async (error: unknown) => {
        await releaseEligibleRowsSnapshot(state, wakeGrantScript, String(acceptedGeneration));
        throw error;
      })
      .finally(() => {
        if (recoveryProbe) finishProviderProbe(acceptedGeneration, acceptedSelectionRevision);
      });
    branchChain = delivery.catch(() => {});
    return delivery;
  }

  // A model or effort change applies to the next branch turn without waiting
  // for /new: the live session is dropped synchronously so nothing enqueued
  // afterwards can capture it, then disposed in dispatch order behind work
  // already queued. The branch conversation lasts for this main session, so
  // the next wake reopens the same conversation under the new selection.
  // Clearing the broken latch is what lets a corrected pin recover in place.
  function releaseBranchForSelectionChange(): void {
    branchBroken = "";
    consecutiveProviderErrors = 0;
    providerRecovery = null;
    const stale = branch;
    branch = null;
    if (!stale) return;
    branchChain = branchChain
      .then(() => {
        stale.session.dispose();
      })
      .catch(() => {
        // Already gone, or disposed by a session replacement first.
      });
  }

  function collectCurrentMainDialog(): boolean {
    if (!currentMainSession) return true;
    try {
      pendingMirror.push(...collectMainDialog(currentMainSession, mirrorCollection));
      return true;
    } catch {
      return false;
    }
  }

  function enqueueMirrorFlush(): void {
    if (!branch || pendingMirror.length === 0) return;
    const flushGeneration = generation;
    const flushSession = branch.session;
    branchChain = branchChain
      .then(async () => {
        if (!(await actingAsOwner(flushGeneration))) return;
        await flushMirror(flushSession, flushGeneration);
      })
      .catch(() => {
        // Mirror items stay queued in pendingMirror on failure; the next wake
        // or flush retries them in order.
      });
  }

  // accept() must be called SYNCHRONOUSLY: the watcher reads offer.accepted
  // the moment emit returns (lib/fm-branch-dispatch.ts owns that handshake).
  // Ownership is therefore still read synchronously here, because a session
  // that does not own the fleet lock must never ACCEPT a wake (see this
  // file's header) - accepting and then rejecting would reach main by the
  // same fallback, but it is not the same promise. What moves into the
  // settlement is only the work that cannot be made cheap: the activation
  // side effects and the unread reconcile, both of which now run as the
  // settlement's first steps and reject to the watcher's main path if they
  // fail, exactly as a refused offer would.
  pi.events?.on?.(FM_BRANCH_DISPATCH_EVENT, (data) => {
    const offer = data as BranchDispatchOffer;
    if (!offer || typeof offer.accept !== "function") return;
    // Check eligibility before the ownership read so an out-of-scope wake
    // gets neither branch routing nor branch-owned state/lease cleanup side
    // effects.
    if (!offerEligible(offer)) return;
    if (!generationOwnsLockSync(generation)) return; // cold start pre-lock, secondary session, or shutdown
    if (afkActive()) return; // the away daemon owns supervision while afk
    const recoveryProbe = Boolean(
      branchBroken &&
      providerRecovery &&
      !providerRecovery.probeInFlight &&
      Date.now() >= providerRecovery.retryNotBefore
    );
    if (branchBroken && !recoveryProbe) return; // main owns every wake inside the cooldown window
    if (!collectCurrentMainDialog()) return;
    if (recoveryProbe && providerRecovery) providerRecovery.probeInFlight = true;
    offer.accept(enqueueWake(offer.message, generation, recoveryProbe));
  });

  // Pi awaits every extension event handler, so an awaited ownership read
  // here delays only Pi's own next step - it never stops the TUI the way the
  // synchronous read it replaces did. The generation is captured before that
  // await so a session replaced while it runs cannot be staged into.
  pi.on?.("before_agent_start", async (event, ctx) => {
    rememberMainModel(ctx);
    currentMainSession = ctx?.sessionManager ?? null;
    const promptGeneration = generation;
    if (!(await enqueueDelivery(() => actingAsOwner(promptGeneration)))) return;
    if (promptGeneration !== generation || !currentMainSession || !collectCurrentMainDialog()) return;

    // This event is Pi's authoritative complete current prompt. At this point
    // SessionManager still contains only the preceding dialog, so relying on
    // getEntries() here loses the captain request that the next wake may answer.
    // Stage it verbatim and remember the future persisted index for turn_end's
    // duplicate suppression. Operational extension injections are not dialog.
    const prompt = event.prompt.trim();
    if (!prompt || isOperationalUserText(prompt)) return;
    const file = currentMainSession.getSessionFile() ?? "";
    const index = mirrorCollection.collectAnchor?.index ?? currentMainSession.getEntries().length;
    pendingMirror.push({ tag: "captain", text: prompt });
    mirrorCollection.stagedCaptain = { file, index, text: prompt };
  });

  pi.on?.("agent_start", () => {
    mainStreaming = true;
    // Pi delivers a queued nextTurn copy with the prompt that starts this run,
    // so a fresh copy may be queued again once this run settles unacknowledged.
    if (processing) processing.nextTurnQueued = false;
  });
  pi.on?.("agent_end", () => {
    mainStreaming = false;
  });
  // The run boundary is where an ignored processing request is detected: every
  // presentation sent before this point has been consumed by the run that just
  // settled (a follow-up joins the running turn, a triggered send opens its
  // own), so any sequence still unprocessed here was answered by something
  // other than its acknowledgement - an unrelated reply, an empty reply, or a
  // reply that only paraphrased it - and is presented again.
  pi.on?.("agent_settled", async () => {
    mainStreaming = false;
    if (processing) processing.pending = false;
    const settledGeneration = generation;
    await enqueueDelivery(async () => {
      if (!(await actingAsOwner(settledGeneration))) return;
      await presentUnprocessedOutcomes(settledGeneration);
    });
  });

  // before_agent_start stages Pi's authoritative in-flight prompt before
  // SessionManager persists it. The dispatch handler then collects any newly
  // persisted dialog immediately before accepting a wake, so all context joins
  // the serialized chain before that wake's branch prompt. turn_end remains
  // the idle-path mirror flush. The durable cursor advances only in
  // flushMirror after the complete pending batch reaches the branch.
  pi.on?.("turn_end", async (_event, ctx) => {
    rememberMainModel(ctx);
    currentMainSession = ctx.sessionManager;
    const turnGeneration = generation;
    const reconciled = await enqueueDelivery(async () => {
      if (!(await actingAsOwner(turnGeneration))) return "not-owner";
      return (await reconcileUnreadOutcomes(turnGeneration, false)) ? "reconciled" : "failed";
    });
    // A verdict about a generation that has since been replaced says nothing
    // about the new one, so it neither breaks the branch nor flushes a mirror.
    if (turnGeneration !== generation) return;
    if (reconciled === "not-owner") return;
    if (reconciled === "failed") {
      branchBroken = "could not reconcile unread supervision outcomes into main";
      return;
    }
    if (!collectCurrentMainDialog()) return;
    enqueueMirrorFlush();
  });

  // Pi emits session_shutdown for ordinary same-process replacements (/new,
  // /resume, /fork, reload) as well as terminal quit, exactly as the watcher
  // extension documents. Shutdown quiesces this generation, clears the
  // volatile mirror state, and releases the branch session; a replacement
  // session_start re-arms. Terminal quit simply never fires another
  // session_start.
  //
  // Bumping the generation here is also what makes the branch conversation
  // NEW for this main session: the recorded branch session belongs to the
  // previous generation, so the next wake builds a new one rather than
  // reopening a thread whose accumulated memory would compete with today's
  // supervision prompt. The mirror re-anchors with it, so the fresh branch
  // receives the dialog of the main session it is supervising from that
  // session's start.
  pi.on?.("session_start", async (_event, ctx) => {
    rememberMainModel(ctx);
    currentMainSession = ctx?.sessionManager ?? null;
    // Every field this new generation depends on is set before the first
    // await, so anything already queued for the previous generation is
    // cancelled by its own recheck rather than racing this one.
    shuttingDown = false;
    branchBroken = "";
    consecutiveProviderErrors = 0;
    providerRecovery = null;
    generation += 1;
    mirrorCollection.collectAnchor = null;
    mirrorCollection.pendingCursor = null;
    mirrorCollection.stagedCaptain = null;
    mirrorCollection.reanchor = true;
    const startedGeneration = generation;
    const failed = await enqueueDelivery(
      async () =>
        (await actingAsOwner(startedGeneration)) && !(await reconcileUnreadOutcomes(startedGeneration)),
    );
    if (failed && startedGeneration === generation) {
      branchBroken = "could not reconcile unread supervision outcomes into main";
    }
  });

  // Pi emits this for /model, Ctrl+P cycling, and session restore, so it is
  // the authoritative signal that "follow main" now means a different model.
  // A model change often follows a quota failure, so an unpinned supervision
  // branch follows live rather than retaining a model that may no longer work.
  pi.on?.("model_select", (event) => {
    const selected = (event as { model?: { provider: string; id: string } }).model;
    if (!selected) return;
    const changed = !mainModel || mainModel.provider !== selected.provider || mainModel.id !== selected.id;
    mainModel = { provider: selected.provider, id: selected.id };
    if (!changed || readModelPin()) return;
    branchSelectionRevision += 1;
    releaseBranchForSelectionChange();
  });

  // Pi emits this only when main's effort actually changes, so an unpinned
  // supervision branch follows main's effort live for the same reason it
  // follows main's model: the captain's current setting, not the level the
  // branch conversation happens to have recorded, is what supervision should
  // run at. A pin stays authoritative and is left alone.
  pi.on?.("thinking_level_select", (event) => {
    const level = (event as { level?: BranchEffort }).level;
    if (!level || readEffortPin()) return;
    branchSelectionRevision += 1;
    releaseBranchForSelectionChange();
  });

  pi.on?.("session_shutdown", async () => {
    // Quiesce first, then release the grant for the generation that is
    // closing: setting shuttingDown before the await is what stops anything
    // new from being accepted while the release runs.
    const closingGeneration = generation;
    shuttingDown = true;
    generation += 1;
    processing = null;
    pendingMirror.length = 0;
    currentMainSession = null;
    mirrorCollection.collectAnchor = null;
    mirrorCollection.pendingCursor = null;
    mirrorCollection.stagedCaptain = null;
    if (branch) {
      try {
        branch.session.dispose();
      } catch {
        // Already gone.
      }
      branch = null;
    }
    await deactivateEligibleRowsOwner(state, wakeGrantScript, process.pid, String(closingGeneration));
  });

  // Pi keeps /model and its own thinking selector for the captain's own
  // conversation and exposes no hook an extension can use to open either
  // picker, so this is the smallest supported equivalent: Pi's own catalog
  // intersected with the isolated branch runtime, then Pi's own supported
  // thinking levels for the model just chosen, with no parallel Firstmate
  // model or effort list. The model step shows that catalog through the same
  // bounded, searchable SelectList primitive Pi's own /model dialog scrolls
  // (pickBranchModel below); the effort step's menu is a handful of levels
  // and stays on Pi's generic selector dialog. The effort step follows the
  // model step because the model decides which levels exist.
  pi.registerCommand?.("supervision-model", {
    description: "Pick the model and reasoning effort Firstmate's Pi supervision branch uses, or follow main's.",
    handler: async (_args, ctx) => {
      rememberMainModel(ctx);
      const pin = readModelPin();
      const current = pin ? `${pin.provider}/${pin.modelId}` : "follows main";
      const followMain = `Follow main${ctx.model ? ` (${modelLabel(ctx.model)})` : ""}`;
      let available: string[];
      try {
        const modelRuntime = await ModelRuntime.create();
        copyExtensionProviders(modelRuntime);
        available = ctx.modelRegistry
          .getAvailable()
          .filter((model) => modelRuntime.getModel(model.provider, model.id) && modelRuntime.hasConfiguredAuth(model.provider))
          .map(modelLabel);
      } catch (error) {
        ctx.ui.notify(
          `Could not read the supervision branch models: ${error instanceof Error ? error.message : String(error)}`,
          "error",
        );
        return;
      }
      const picked = await pickBranchModel(
        ctx,
        `Supervision branch model (now: ${current})`,
        buildBranchModelItems(followMain, available, pin ? `${pin.provider}/${pin.modelId}` : null),
      );
      if (picked === undefined) return; // cancelled: the current choice stands
      // Whatever the model step resolves is also the model the effort step
      // builds its menu from, so it is captured here rather than resolved a
      // second time through another isolated runtime.
      let branchModel: BranchModel | undefined;
      try {
        if (picked === FOLLOW_MAIN_VALUE) {
          clearPinFile(modelPinFile);
        } else {
          const separator = picked.indexOf("/");
          if (separator <= 0 || separator >= picked.length - 1) throw new Error(`invalid model selection: ${picked}`);
          branchModel = (
            await preparePinnedBranchModel({ provider: picked.slice(0, separator), modelId: picked.slice(separator + 1) })
          ).model;
          writePinFile(modelPinFile, picked);
        }
      } catch (error) {
        ctx.ui.notify(
          `Could not apply or save the supervision branch model: ${error instanceof Error ? error.message : String(error)}`,
          "error",
        );
        return;
      }
      // The model choice is persisted; report it exactly, then run the effort
      // step on the model the branch will actually use.
      let modelReport: { message: string; warning: boolean };
      if (picked !== FOLLOW_MAIN_VALUE) {
        modelReport = { message: `Supervision branch model: ${picked}.`, warning: false };
      } else {
        // Clearing the pin only follows main if main's model can actually be
        // applied to the branch; say what will really happen rather than
        // reporting a state that did not take effect.
        try {
          const following = mainModel ? await resolveBranchModel(mainModel.provider, mainModel.id) : null;
          if (following?.ok) branchModel = following.selection.model;
          modelReport = following?.ok
            ? {
                message: `Supervision branch follows main's model (${modelLabel(following.selection.model)}).`,
                warning: false,
              }
            : {
                message: `Supervision branch pin cleared, but main's model could not be applied (${following ? following.reason : "main's model is not known yet"}); the branch keeps the model its own session recorded until that conversation is replaced.`,
                warning: true,
              };
        } catch (error) {
          modelReport = {
            message: `Supervision branch pin cleared, but main's model could not be applied (${error instanceof Error ? error.message : String(error)}); the branch keeps the model its own session recorded until that conversation is replaced.`,
            warning: true,
          };
        }
      }

      // The model choice is already persisted, so a failing effort step must
      // never swallow it: the branch still rebinds and the captain still
      // hears what took effect and what did not.
      let effortReport: { message: string; warning: boolean };
      try {
        effortReport = await pickBranchEffort(ctx, branchModel);
      } catch (error) {
        effortReport = {
          message: `The effort step failed (${error instanceof Error ? error.message : String(error)}); the branch keeps its current effort choice.`,
          warning: true,
        };
      }
      branchSelectionRevision += 1;
      releaseBranchForSelectionChange();
      ctx.ui.notify(
        `${modelReport.message} ${effortReport.message}`,
        modelReport.warning || effortReport.warning ? "warning" : "info",
      );
    },
  });

  // Step one of /supervision-model's dialog. Pi's generic extension selector
  // renders every option at once with no search box, so a real eligible
  // catalog ran off the top of the terminal; this shows the same rows through
  // Pi's own SelectList - the bounded, scrolling primitive behind Pi's /model
  // picker - with Pi's own Input and fuzzy filter above it for search.
  // Pi's ModelSelectorComponent is deliberately NOT reused: its own selection
  // handler writes the captain's default model through Pi's settings manager,
  // which would move main's conversation as a side effect of pinning the
  // branch, and it has no room for the "follow main" row or for Firstmate's
  // branch-runtime eligibility filter. Ordering and filtering live in
  // lib/fm-branch-model-picker.ts; everything here is Pi's own rendering.
  // Returns the chosen item's value, or undefined when the captain cancels.
  // Non-TUI modes have no custom component surface, so they keep Pi's generic
  // selector: overflow is a terminal-rendering problem those modes do not have.
  async function pickBranchModel(
    ctx: ExtensionCommandContext,
    title: string,
    items: BranchPickerItem[],
  ): Promise<string | undefined> {
    if (ctx.mode !== "tui" || typeof ctx.ui.custom !== "function") {
      const picked = await ctx.ui.select(
        title,
        items.map((item) => item.label),
      );
      if (picked === undefined) return undefined;
      return items.find((item) => item.label === picked)?.value;
    }
    const picked = await ctx.ui.custom<string | null>((tui, theme, keybindings, done) => {
      const accent = (text: string) => theme.fg("accent", text);
      const muted = (text: string) => theme.fg("muted", text);
      const container = new Container();
      container.addChild(new DynamicBorder(accent));
      container.addChild(new Text(accent(theme.bold(title)), 1, 0));
      const search = new Input();
      search.focused = true;
      container.addChild(search);
      const listContainer = new Container();
      container.addChild(listContainer);
      container.addChild(new Text(muted("type to search - up/down navigate - enter select - esc cancel"), 1, 0));
      container.addChild(new DynamicBorder(accent));

      // SelectList takes its rows at construction, so a new query builds a new
      // list into the same container rather than mutating the old one.
      let list = buildList("");
      function buildList(query: string): SelectList {
        const rebuilt = new SelectList(filterBranchPickerItems(items, query, fuzzyFilter), BRANCH_PICKER_MAX_VISIBLE, {
          selectedPrefix: accent,
          selectedText: accent,
          description: muted,
          scrollInfo: muted,
          noMatch: muted,
        });
        rebuilt.onSelect = (item) => done(item.value);
        rebuilt.onCancel = () => done(null);
        listContainer.clear();
        listContainer.addChild(rebuilt);
        return rebuilt;
      }

      const navigationKeys = ["tui.select.up", "tui.select.down", "tui.select.confirm", "tui.select.cancel"] as const;
      return {
        render: (width: number) => container.render(width),
        invalidate: () => container.invalidate(),
        handleInput: (data: string) => {
          if (navigationKeys.some((key) => keybindings.matches(data, key))) {
            list.handleInput(data);
          } else {
            search.handleInput(data);
            list = buildList(search.getValue());
          }
          tui.requestRender();
        },
      };
    });
    return picked === null ? undefined : picked;
  }

  // Step two of /supervision-model, shown after the model pick and driven by
  // Pi's own supported-level list for the model the branch will now use, so
  // the menu is the one Pi's own thinking selector would show and keeps no
  // parallel Firstmate picker catalog. Cancelling leaves the current effort
  // choice standing; the model pick already made is still applied.
  async function pickBranchEffort(
    ctx: { ui: { select: (title: string, options: string[]) => Promise<string | undefined> } },
    selectedModel: BranchModel | undefined,
  ): Promise<{ message: string; warning: boolean }> {
    const branchModel = await effectiveBranchModel(selectedModel);
    const currentPin = readEffortPin();
    const current = currentPin ?? "follows main";
    const main = mainEffort();
    const followMainEffort = `Follow main${main ? ` (${main})` : ""}`;
    const levels = branchModel ? getSupportedThinkingLevels(branchModel) : [];
    const picked = await ctx.ui.select(`Supervision branch effort (now: ${current})`, [followMainEffort, ...levels]);
    if (picked === undefined) {
      return { message: describeBranchEffort(currentPin, branchModel), warning: branchModel === undefined };
    }
    try {
      if (picked === followMainEffort) {
        clearPinFile(effortPinFile);
      } else if ((BRANCH_EFFORT_LEVELS as readonly string[]).includes(picked)) {
        writePinFile(effortPinFile, picked);
      } else {
        throw new Error(`invalid effort selection: ${picked}`);
      }
    } catch (error) {
      return {
        message: `The effort choice could not be saved (${error instanceof Error ? error.message : String(error)}). ${describeBranchEffort(currentPin, branchModel)}`,
        warning: true,
      };
    }
    return {
      message: describeBranchEffort(readEffortPin(), branchModel),
      warning: branchModel === undefined,
    };
  }

  // Reports the effort the branch will actually run at, never the raw choice:
  // Pi clamps a level the branch's model does not support, and an unpinned
  // branch follows main's own effort only when Pi can tell us what that is.
  function describeBranchEffort(pin: BranchEffort | null, branchModel: BranchModel | undefined): string {
    if (!branchModel) {
      return "The effort level the branch will run at cannot be determined because its effective model could not be resolved.";
    }
    const chosen = pin ?? mainEffort();
    if (chosen === undefined) {
      return "Effort follows main, whose own effort is not known yet, so the branch keeps the effort its own session recorded until that conversation is replaced.";
    }
    const applied = clampThinkingLevel(branchModel, chosen) as BranchEffort;
    if (pin === null) return `Effort follows main (${applied}).`;
    return applied === pin ? `Effort: ${pin}.` : `Effort: ${pin}, which this model runs at ${applied}.`;
  }

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

  const outcomesToolAnsiPattern = new RegExp(
    "(?:\\u001B\\][\\s\\S]*?(?:\\u0007|\\u001B\\u005C|\\u009C))|[\\u001B\\u009B][[\\]\\()#;?]*(?:\\d{1,4}(?:[;:]\\d{0,4})*)?[\\dA-PR-TZcf-nq-uy=><~]",
    "g",
  );
  const normalizeOutcomesToolOutput = (value: string): string => {
    const withoutAnsi = value.includes("\u001B") || value.includes("\u009B")
      ? value.replace(outcomesToolAnsiPattern, "")
      : value;
    return Array.from(withoutAnsi)
      .filter((char) => {
        const code = char.codePointAt(0);
        if (code === undefined) return false;
        if (code === 0x09 || code === 0x0a || code === 0x0d) return true;
        if (code <= 0x1f) return false;
        return code < 0xfff9 || code > 0xfffb;
      })
      .join("")
      .replace(/\r/g, "");
  };

  let stockOutcomesPreviewLines: number | null | undefined;
  const getStockOutcomesPreviewLines = (): number | undefined => {
    if (stockOutcomesPreviewLines !== undefined) return stockOutcomesPreviewLines ?? undefined;
    const probeTokens = Array.from(
      { length: 64 },
      (_, index) => `FM_OUTCOMES_PREVIEW_PROBE_${String(index).padStart(2, "0")}`,
    );
    try {
      const probeDefinition: ToolDefinition = {
        name: "fm_outcomes_preview_probe",
        label: "Preview probe",
        description: "Preview probe",
        parameters: Type.Object({}),
        execute: async () => ({ content: [], details: undefined }),
      };
      const probe = new ToolExecutionComponent(
        probeDefinition.name,
        "fm-outcomes-preview-probe",
        {},
        { showImages: false },
        probeDefinition,
        { requestRender() {} } as ConstructorParameters<typeof ToolExecutionComponent>[5],
        root,
      );
      probe.updateResult({
        content: [{ type: "text", text: probeTokens.join("\n") }],
        isError: false,
      });
      const rendered = probe.render(4096).join("\n");
      const visibleLines = probeTokens.filter((token) => rendered.includes(token)).length;
      stockOutcomesPreviewLines = visibleLines > 0 && visibleLines < probeTokens.length ? visibleLines : null;
    } catch {
      stockOutcomesPreviewLines = null;
    }
    return stockOutcomesPreviewLines ?? undefined;
  };

  type OutcomesToolShellState = {
    shell?: Box;
    call?: Text;
    result?: Text | Container;
  };
  const refreshOutcomesToolShell = (
    shellState: OutcomesToolShellState,
    theme: Parameters<NonNullable<ToolDefinition["renderCall"]>>[1],
    context: Parameters<NonNullable<ToolDefinition["renderCall"]>>[2],
  ): Box => {
    const background = context.isPartial
      ? (text: string) => theme.bg("toolPendingBg", text)
      : context.isError
        ? (text: string) => theme.bg("toolErrorBg", text)
        : (text: string) => theme.bg("toolSuccessBg", text);
    const shell = shellState.shell ?? new Box(1, 1, background);
    shellState.shell = shell;
    shell.setBgFn(background);
    shell.clear();
    if (shellState.call) shell.addChild(shellState.call);
    if (shellState.result) shell.addChild(shellState.result);
    return shell;
  };

  pi.registerTool?.({
    name: "fm_branch_outcomes",
    label: "Read supervision branch outcomes",
    description:
      "Read the durable outcome store of the supervision branch: what fleet events it handled, each verdict, and each summary. Use when the captain asks what happened in the fleet.",
    promptSnippet: "Read what the supervision branch handled (durable outcome store).",
    parameters: Type.Object({
      recent: Type.Optional(Type.Number({ description: "How many most-recent outcomes to read (default 20)" })),
    }),
    renderShell: "self",
    renderCall: (_args, theme, context) => {
      if (calmPresentation.stockExportRendering) throw new Error("Use Pi stock export rendering");
      if (calmHides("assistant-tool-call")) return new Container();
      const shellState = context.state as OutcomesToolShellState;
      shellState.call = new Text(theme.fg("toolTitle", theme.bold("fm_branch_outcomes")), 0, 0);
      return refreshOutcomesToolShell(shellState, theme, context);
    },
    renderResult: (result, options, theme, context) => {
      if (calmPresentation.stockExportRendering) throw new Error("Use Pi stock export rendering");
      if (calmHides("tool-result")) return new Container();
      const output = result.content
        .filter((item) => item.type === "text")
        .map((item) => normalizeOutcomesToolOutput(item.text))
        .join("\n");
      const shellState = context.state as OutcomesToolShellState;
      // Keep each line's ANSI scope independent, matching Pi's stock fallback.
      // Pi 0.84.4 no longer supplies an implicit reset at multiline boundaries.
      const lines = output.split("\n");
      const previewLines = getStockOutcomesPreviewLines();
      const displayLines = options.expanded || previewLines === undefined ? lines : lines.slice(0, previewLines);
      const remaining = lines.length - displayLines.length;
      let renderedOutput = displayLines.map((line) => theme.fg("toolOutput", line)).join("\n");
      if (remaining > 0) {
        renderedOutput += `${theme.fg("muted", `\n... (${remaining} more lines,`)} ${keyHint("app.tools.expand", "to expand")}${theme.fg("muted", ")")}`;
      }
      shellState.result = output ? new Text(renderedOutput, 0, 0) : new Container();
      refreshOutcomesToolShell(shellState, theme, context);
      return new Container();
    },
    execute: async (_toolCallId, params) => {
      const recentRaw = (params as { recent?: unknown }).recent;
      const recent = typeof recentRaw === "number" && recentRaw >= 1 ? String(Math.floor(recentRaw)) : "20";
      const listed = await enqueueDelivery(() => runOutcomeScript(["list", "--recent", recent]));
      if (!listed.ok) {
        return {
          content: [{ type: "text", text: `could not read the outcome store: ${listed.detail}` }],
          details: undefined,
          isError: true,
        };
      }
      return {
        content: [{ type: "text", text: listed.stdout || "(no branch outcomes recorded)" }],
        details: undefined,
      };
    },
  });

  // Main's only way to close a captain outcome. The acknowledgement is keyed
  // to the sequence main names, validated by the store (never past the read
  // cursor, never backwards), and refused outside lock ownership, so neither a
  // paraphrase, an empty reply, nor a stale generation can mark an outcome
  // processed.
  pi.registerTool?.({
    name: "fm_branch_processed",
    label: "Acknowledge processed supervision outcomes",
    description:
      "Acknowledge that every captain-facing supervision outcome up to a sequence number has been processed by this conversation. Call it exactly once after handling a supervision processing request, with through set to the highest sequence that request listed; an outcome that is not acknowledged is presented again.",
    promptSnippet: "Acknowledge processed captain-facing supervision outcomes by sequence.",
    parameters: Type.Object({
      through: Type.Number({ description: "The highest outcome sequence number this conversation has processed" }),
    }),
    renderShell: "self",
    renderCall: (_args, theme, context) => {
      if (calmPresentation.stockExportRendering) throw new Error("Use Pi stock export rendering");
      if (calmHides("assistant-tool-call")) return new Container();
      const shellState = context.state as OutcomesToolShellState;
      shellState.call = new Text(theme.fg("toolTitle", theme.bold("fm_branch_processed")), 0, 0);
      return refreshOutcomesToolShell(shellState, theme, context);
    },
    renderResult: (result, _options, theme, context) => {
      if (calmPresentation.stockExportRendering) throw new Error("Use Pi stock export rendering");
      if (calmHides("tool-result")) return new Container();
      const output = result.content
        .filter((item) => item.type === "text")
        .map((item) => normalizeOutcomesToolOutput(item.text))
        .join("\n");
      const shellState = context.state as OutcomesToolShellState;
      shellState.result = output ? new Text(theme.fg("toolOutput", output), 0, 0) : new Container();
      refreshOutcomesToolShell(shellState, theme, context);
      return new Container();
    },
    execute: async (_toolCallId, params) => {
      const raw = (params as { through?: unknown }).through;
      const through = typeof raw === "number" && Number.isSafeInteger(raw) && raw >= 1 ? raw : null;
      if (through === null) {
        return {
          content: [{ type: "text", text: "acknowledgement refused: through must be a positive outcome sequence number" }],
          details: undefined,
          isError: true,
        };
      }
      // One queued unit, for the same reason the report tool is one: the
      // acknowledgement must not be interleaved with a delivery that is still
      // advancing the read cursor it is measured against.
      const acknowledgedGeneration = generation;
      return enqueueDelivery(async () => {
        if (!(await actingAsOwner(acknowledgedGeneration))) {
          return {
            content: [{ type: "text", text: "acknowledgement refused: this session does not own the fleet lock" }],
            details: undefined,
            isError: true,
          };
        }
        if (!processing || through > processing.through) {
          return {
            content: [{ type: "text", text: `acknowledgement refused: seq ${through} was not listed in the active processing request` }],
            details: undefined,
            isError: true,
          };
        }
        const marked = await runOutcomeScript(["mark-processed", "--through", String(through)]);
        if (!marked.ok) {
          return {
            content: [{ type: "text", text: `acknowledgement refused: ${marked.detail}` }],
            details: undefined,
            isError: true,
          };
        }
        const remaining = await readUnprocessedOutcomes(acknowledgedGeneration);
        if (remaining !== null && remaining.length === 0) processing = null;
        const open = remaining === null
          ? "the remaining outcomes could not be read"
          : remaining.length === 0
            ? "no captain outcome remains unprocessed"
            : `${remaining.length} newer captain outcome(s) remain unprocessed (seq ${remaining.map((row) => row.seq).join(", ")}) and will be presented again`;
        return {
          content: [{ type: "text", text: `processed through seq ${through}; ${open}` }],
          details: undefined,
        };
      });
    },
  });

  // Captain outcomes are transcript entries rather than model messages. Their
  // payload is the durable store row plus a schema version, and the renderer
  // displays the exact stored summary without asking a model to paraphrase or
  // acknowledge it.
  pi.registerEntryRenderer?.(VISIBLE_OUTCOME_ENTRY_TYPE, (entry, _options, theme) => {
    const record = parseVisibleOutcomeRecord(entry.data);
    if (!record || record.verdict !== "captain") return undefined;
    return new Text(
      `${theme.fg("customMessageText", VISIBLE_OUTCOME_ANCHOR)}${theme.fg("dim", ` [seq ${record.seq}] ${record.task}: ${record.summary}`)}`,
      1,
      0,
    );
  });

  // Pi only calls this renderer for a message with display: true, which every
  // routine note uses except an explicitly silent fleet heartbeat.
  pi.registerMessageRenderer?.("fm-branch-merge", (message, _options, theme) => {
    const note = textOfContent(message.content);
    const hasGlyph = note.startsWith(MERGE_NOTE_BOAT);
    const rest = hasGlyph ? note.slice(MERGE_NOTE_BOAT.length) : note;
    const outputPad = 1;
    return new Text(
      `${hasGlyph ? theme.fg("customMessageText", MERGE_NOTE_BOAT) : ""}${theme.fg("dim", rest)}`,
      outputPad,
      0,
    );
  });
}
