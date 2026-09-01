// Firstmate supervision branch for Pi (docs/pi-supervision-branch.md).
//
// A persistent second AgentSession - the supervision BRANCH - inside the same
// pi process as the captain's MAIN session. The watcher extension offers each
// actionable wake here (lib/fm-branch-dispatch.ts); the branch handles it with
// real tools and reports through the fm_branch_report custom tool, which
// writes the durable outcome store FIRST (bin/fm-branch-outcome.sh) and then
// merges an append-only note to main's tail. Main's captain/assistant dialog
// is mirrored into the branch as read-only fm-main-mirror context from Pi's
// before_agent_start prompt and at main's turn_end. Pi-only by construction: this
// file lives in .pi/extensions, so no
// other harness ever loads it. Supervision is default-on for every task once
// this Pi session owns the fleet lock: no captain grant file is required.
// Away mode (or a broken branch) keeps today's wake-to-main behavior
// untouched regardless.
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
// Failure direction: every path that cannot reach a working branch falls back
// to delivering the wake to MAIN exactly as before the branch existed - a
// broken branch degrades to today's behavior, never to a lost wake. The wake
// queue itself stays durable until the handler runs the drain's
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
  SessionManager,
  ToolExecutionComponent,
  type AgentSession,
  type ExtensionAPI,
  type ExtensionCommandContext,
  type ToolDefinition,
} from "@earendil-works/pi-coding-agent";
import { Box, Container, fuzzyFilter, Input, SelectList, Text } from "@earendil-works/pi-tui";
import { Type } from "typebox";
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
  encodeFirstmateOperationalInput,
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
// Carried inside the captain note's own text because that text is the only
// part of a custom message Pi gives the model (see mergeIntoMain).
//
// The note still needs to identify itself so main cannot mistake an incoming
// outcome for its own earlier answer and silently lose the outcome. Event
// ownership forbids a second fleet operation, while the captain-facing verdict
// requires a visible response and leaves its wording to main.
const CAPTAIN_OUTCOME_INSTRUCTION =
  "This is a supervision outcome delivered automatically by the supervision branch. " +
  "It was not typed by the captain. " +
  "The fleet event is already handled: do not re-drain, re-run, or acknowledge it. " +
  "This outcome is captain-facing: give the captain a visible response now. " +
  "Use your judgment over the wording and how to incorporate it, not whether to surface it. " +
  "An outcome that directly answers an explicit captain request is captain-facing, regardless of whether it is healthy, routine, measured, actionable, or requires a decision.";
type MirrorItem = { tag: "captain" | "main"; text: string };
type MirrorCursor = { file: string; index: number };
type Verdict = "routine" | "captain";
type LockOwnership = "owned" | "other" | "missing";

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

let ownedLockPid = "";

// Same ownership read as the watcher extension's lockOwnership(): the lock
// names the harness pid, and this process owns it when that pid appears in
// its own ancestry.
function lockOwnership(): LockOwnership {
  ownedLockPid = "";
  let lockPid = "";
  try {
    lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
  } catch {
    return "missing";
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "other";
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) {
      ownedLockPid = lockPid;
      return "owned";
    }
    pid = parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return pidAlive(lockPid) ? "other" : "missing";
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
  getEntries(): Array<{ type: string }>;
};

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
};

function collectMainDialog(sessionManager: ReadonlyEntries, collection: MirrorCollectionState): MirrorItem[] {
  const file = sessionManager.getSessionFile() ?? "";
  const entries = sessionManager.getEntries();
  const anchor = collection.collectAnchor ?? readMirrorCursor();
  const start = anchor.file === file ? Math.min(anchor.index, entries.length) : 0;
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
  let branch: AgentSession | null = null;
  let branchBroken = "";
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
  const pendingMirror: MirrorItem[] = [];
  const mirrorCollection: MirrorCollectionState = {
    collectAnchor: null,
    pendingCursor: null,
    stagedCaptain: null,
  };
  let currentMainSession: ReadonlyEntries | null = null;
  // One revision for BOTH selections: a model or effort change invalidates an
  // in-flight branch build exactly the same way.
  let branchSelectionRevision = 0;
  // Main's own current model, tracked from the contexts Pi already hands this
  // extension plus its model_select event, because createBranch runs at wake
  // time with no context of its own. It is what "follow main" applies.
  let mainModel: { provider: string; id: string } | null = null;

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

  function rememberMainModel(ctx?: { model?: { provider: string; id: string } }): void {
    if (ctx?.model) mainModel = { provider: ctx.model.provider, id: ctx.model.id };
  }

  // Resolves one model against the isolated branch runtime using only the
  // credentials that runtime already holds - the branch runs in the same home
  // and same user as main, so stored credentials keep their own semantics
  // (OAuth stays OAuth, an API key stays an API key) and nothing is ever
  // installed, converted, derived, or overwritten here.
  async function resolveBranchModel(provider: string, modelId: string): Promise<BranchModelResolution> {
    const label = `${provider}/${modelId}`;
    const modelRuntime = await ModelRuntime.create();
    const model = modelRuntime.getModel(provider, modelId) as BranchModel | undefined;
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

  function generationOwnsLock(expectedGeneration: number): boolean {
    return !shuttingDown && expectedGeneration === generation && lockOwnership() === "owned";
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
  function releaseBranchLeases(expectedGeneration: number): boolean {
    if (!generationOwnsLock(expectedGeneration)) return false;
    try {
      const result = spawnSync("bash", [leaseScript, "release-actor", "--actor", "branch"], {
        cwd: fmRoot,
        encoding: "utf8",
        env: { ...scriptEnv, FM_SUPERVISION_ACTOR: "branch" },
      });
      return result.status === 0;
    } catch {
      return false;
    }
  }

  // Lazy, per-action ownership evaluation (see the header). Returns true only
  // when this session owns the fleet lock right now; the first true evaluation
  // of a generation also writes the diagnostic marker and clears stray branch
  // leases from a prior generation.
  function actingAsOwner(expectedGeneration = generation): boolean {
    if (!generationOwnsLock(expectedGeneration)) return false;
    if (activatedGeneration !== expectedGeneration) {
      if (!releaseBranchLeases(expectedGeneration)) return false;
      if (!generationOwnsLock(expectedGeneration)) return false;
      if (!activateEligibleRowsOwner(state, wakeGrantScript, process.pid, String(expectedGeneration))) return false;
      if (!generationOwnsLock(expectedGeneration)) {
        deactivateEligibleRowsOwner(state, wakeGrantScript, process.pid, String(expectedGeneration));
        return false;
      }
      markLoaded();
      activatedGeneration = expectedGeneration;
    }
    return generationOwnsLock(expectedGeneration);
  }

  function runOutcomeScript(args: string[]): { ok: boolean; stdout: string; detail: string } {
    try {
      const result = spawnSync("bash", [outcomeScript, ...args], {
        cwd: fmRoot,
        encoding: "utf8",
        env: scriptEnv,
      });
      if (result.status === 0) return { ok: true, stdout: (result.stdout || "").trim(), detail: "" };
      return {
        ok: false,
        stdout: "",
        detail: `fm-branch-outcome.sh exited ${result.status ?? "none"}: ${(result.stderr || "").trim()}`,
      };
    } catch (error) {
      return { ok: false, stdout: "", detail: error instanceof Error ? error.message : String(error) };
    }
  }

  // Append-only merge into main. The store row is already durable when this
  // runs; the note is a cache of it at main's tail. Delivery modes per the
  // design: routine+idle appends now with no turn, routine+busy appends after
  // the captain's next prompt, captain-relevant triggers exactly one turn
  // (queued as a follow-up while main is busy) - that follow-up turn is
  // itself the captain-visible outcome, so the captain-facing note is
  // delivered silently (display: false) rather than printed or rendered a
  // second time; routine notes stay rendered except an explicitly silent
  // no-change heartbeat. The read cursor advances once the note is handed to
  // Pi; a crash inside Pi's
  // own delivery window leaves the outcome durable in the store, where
  // main's fm_branch_outcomes tool still reads it on demand.
  //
  // Pi keeps only `content` when it converts a custom message for the model:
  // customType, display, and details never reach the provider. A captain note
  // therefore has to carry its own identity inside `content`, or main receives
  // an unattributed user message written in main's own captain-facing voice
  // and cannot tell an incoming outcome from its own earlier answer. When that
  // happens main can lose the outcome while deciding how to handle it. The
  // typed operational envelope is what makes the note self-describing; it stays
  // invisible to the captain because the note is never rendered. The
  // instruction preserves the event-ownership boundary while requiring the
  // captain-facing response and leaving its wording to main.
  //
  // Encoding shells out, so it can fail on a broken checkout. This file's
  // failure direction applies: an outcome that cannot be typed is still
  // delivered, carrying the same instruction as plain text, because an
  // untyped outcome main can still read beats an outcome the captain never
  // sees.
  function captainOutcomeInput(task: string, summary: string): string {
    const body = `${CAPTAIN_OUTCOME_INSTRUCTION}\n\n${task}: ${summary}`;
    try {
      return encodeFirstmateOperationalInput("branch-outcome", body);
    } catch {
      return body;
    }
  }

  function mergeIntoMain(
    expectedGeneration: number,
    seq: string,
    task: string,
    verdict: Verdict,
    summary: string,
    silent: boolean,
  ): boolean {
    if (!actingAsOwner(expectedGeneration)) return false;
    if (verdict === "captain") {
      const message = {
        customType: "fm-branch-merge",
        content: captainOutcomeInput(task, summary),
        display: false,
      };
      pi.sendMessage(message, { triggerTurn: true, deliverAs: "followUp" });
    } else {
      const message = { customType: "fm-branch-merge", content: `${MERGE_NOTE_BOAT} ${task}: ${summary}`, display: !(task === "fleet" && silent) };
      if (mainStreaming) {
        pi.sendMessage(message, { deliverAs: "nextTurn" });
      } else {
        pi.sendMessage(message, {});
      }
    }
    if (/^[0-9]+$/.test(seq)) {
      if (!actingAsOwner(expectedGeneration)) return false;
      return runOutcomeScript(["mark-read", "--through", seq]).ok;
    }
    return true;
  }

  function createReportTool(toolGeneration: number): ToolDefinition {
    return {
      name: "fm_branch_report",
      label: "Report supervision outcome",
      description:
        "Record the outcome of one handled fleet event: write it durably to the outcome store, then merge an append-only note into the captain-facing main conversation. verdict captain surfaces it to the captain in one turn; routine notes render unless silent marks a no-change heartbeat.",
      parameters: Type.Object({
        task: Type.String({ description: "The task id the event belongs to (or 'fleet' for fleet-wide events)" }),
        verdict: Type.Union([Type.Literal("routine"), Type.Literal("captain")], {
          description:
            "Use captain unconditionally for an outcome that directly answers an explicit captain request, regardless of whether it is healthy, routine, measured, actionable, or requires a decision. Also use captain for work ready for review, captain-only decisions, blockers or failures after recovery is exhausted, needed credentials, and destructive, irreversible, or security-sensitive actions; use routine otherwise.",
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
        const appendArgs = ["append", "--task", task, "--verdict", verdict, "--summary", summary, "--silent", String(silent)];
        if (wake) appendArgs.push("--wake", wake);
        if (!actingAsOwner(toolGeneration)) {
          return {
            content: [{ type: "text", text: "report refused: supervision session was replaced or lost lock ownership" }],
            details: undefined,
            isError: true,
          };
        }
        const appended = runOutcomeScript(appendArgs);
        if (!appended.ok) {
          return {
            content: [{ type: "text", text: `outcome store append failed (nothing merged): ${appended.detail}` }],
            details: undefined,
            isError: true,
          };
        }
        if (!mergeIntoMain(toolGeneration, appended.stdout, task, verdict, summary, silent)) {
          return {
            content: [{ type: "text", text: `recorded seq ${appended.stdout}, but merge refused after supervision replacement or lock loss` }],
            details: undefined,
            isError: true,
          };
        }
        return {
          content: [{ type: "text", text: `recorded seq ${appended.stdout} and merged [${verdict}] into main` }],
          details: undefined,
        };
      },
    };
  }

  async function createBranch(branchGeneration: number): Promise<AgentSession> {
    // Resolved first, before any session file or prompt work: a model pin Pi
    // cannot honor must fail before this build leaves anything behind. Every
    // branch build goes through here - first wake of a cold start, and the
    // reopen after /new, /resume, /fork, or reload - so resolving the model
    // and the effort here is what makes the captain's current choices
    // authoritative on all of them.
    const pinned = await branchModelSelection();
    const effort = branchEffortSelection(pinned?.model);
    const prompt = spawnSync("bash", [promptScript], {
      cwd: fmRoot,
      encoding: "utf8",
      env: scriptEnv,
      maxBuffer: 4 * 1024 * 1024,
    });
    if (prompt.status !== 0 || !prompt.stdout || prompt.stdout.length < 1024) {
      throw new Error(
        `fm-branch-prompt.sh did not produce a usable branch prompt (status=${prompt.status ?? "none"}): ${(prompt.stderr || "").trim()}`,
      );
    }
    if (!actingAsOwner(branchGeneration)) throw new Error("supervision session was replaced or lost lock ownership");
    mkdirSync(sessionsDir, { recursive: true });
    let sessionManager: SessionManager | null = null;
    try {
      const recorded = readFileSync(sessionPointer, "utf8").trim();
      if (recorded && existsSync(recorded)) {
        sessionManager = SessionManager.open(recorded, sessionsDir);
      }
    } catch {
      sessionManager = null;
    }
    if (!sessionManager) {
      sessionManager = SessionManager.create(fmRoot, sessionsDir);
    }
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
    if (!actingAsOwner(branchGeneration)) throw new Error("supervision session was replaced or lost lock ownership");
    const leaseHolderPid = ownedLockPid;
    const bashTool = createBashToolDefinition(fmRoot, {
      spawnHook: (context) => {
        if (!actingAsOwner(branchGeneration)) {
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
      customTools: [bashTool as unknown as ToolDefinition, createReportTool(branchGeneration)],
      ...(pinned ? { model: pinned.model, modelRuntime: pinned.modelRuntime } : {}),
      ...(effort === undefined ? {} : { thinkingLevel: effort }),
    });
    if (!actingAsOwner(branchGeneration)) {
      try {
        created.session.dispose();
      } catch {}
      throw new Error("supervision session was replaced or lost lock ownership");
    }
    try {
      writeFileSync(sessionPointer, `${sessionManager.getSessionFile()}\n`);
    } catch {
      // Pointer write failure only costs cross-restart session reuse.
    }
    return created.session;
  }

  async function ensureBranch(expectedGeneration: number): Promise<AgentSession> {
    if (!actingAsOwner(expectedGeneration)) throw new Error("supervision session was replaced or lost lock ownership");
    if (branch) return branch;
    if (branchBroken) throw new Error(branchBroken);
    while (true) {
      const buildRevision = branchSelectionRevision;
      try {
        const created = await createBranch(expectedGeneration);
        if (buildRevision !== branchSelectionRevision) {
          try {
            created.dispose();
          } catch {}
          continue;
        }
        if (!actingAsOwner(expectedGeneration)) {
          try {
            created.dispose();
          } catch {}
          throw new Error("supervision session was replaced or lost lock ownership");
        }
        branch = created;
        return created;
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
    if (!actingAsOwner(expectedGeneration)) throw new Error("supervision session no longer owns the fleet lock");
    while (pendingMirror.length > 0) {
      const item = pendingMirror[0];
      if (!actingAsOwner(expectedGeneration)) throw new Error("supervision session no longer owns the fleet lock");
      await session.sendCustomMessage(
        { customType: "fm-main-mirror", content: `[${item.tag}] ${item.text}`, display: false },
        {},
      );
      if (!actingAsOwner(expectedGeneration)) throw new Error("supervision session was replaced during mirror delivery");
      pendingMirror.shift();
    }
    if (mirrorCollection.pendingCursor) {
      if (!actingAsOwner(expectedGeneration)) throw new Error("supervision session no longer owns the fleet lock");
      writeMirrorCursor(mirrorCollection.pendingCursor);
      mirrorCollection.pendingCursor = null;
    }
  }

  async function fallbackToMain(message: string, detail: string): Promise<void> {
    const body = `FIRSTMATE WATCHER WAKE: ${message}\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. (Supervision branch unavailable, falling back to main: ${detail})`;
    let content = body;
    try {
      // Marked operational like every watcher injection, so the wake is never
      // mistaken for captain input (away-mode return semantics, mirror filter).
      content = encodeFirstmateOperationalInput("watcher", body);
    } catch {
      // An encoding failure must not lose the wake; deliver it unmarked.
    }
    await pi.sendUserMessage(content, { deliverAs: "followUp" });
  }

  function enqueueWake(message: string, acceptedGeneration: number): void {
    branchChain = branchChain
      .then(async () => {
        if (shuttingDown || acceptedGeneration !== generation) {
          throw new Error("supervision session was replaced before handling the accepted wake");
        }
        if (!actingAsOwner(acceptedGeneration)) throw new Error("supervision session no longer owns the fleet lock");
        const session = await ensureBranch(acceptedGeneration);
        await flushMirror(session, acceptedGeneration);
        if (!actingAsOwner(acceptedGeneration)) throw new Error("supervision session no longer owns the fleet lock");
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
        const grant = writeEligibleRowsSnapshot(
          state,
          scope.eligibleSeqs,
          wakeGrantScript,
          String(acceptedGeneration),
        );
        if (grant === "main-owned") throw new Error("the wake rows are already claimed by main");
        if (grant !== "published") throw new Error("could not record the branch's eligible row snapshot");
        // A row can still arrive between this re-check and the model starting
        // the drain; that residual is accepted by the confused-agent-grade boundary.
        await session.prompt(
          `FIRSTMATE SUPERVISION WAKE: ${message}\n\nHandle this per your operating procedure and finish with fm_branch_report.`,
        );
        if (!releaseEligibleRowsSnapshot(state, wakeGrantScript, String(acceptedGeneration))) {
          throw new Error("could not release the branch's settled wake-row grant");
        }
      })
      .catch(async (error: unknown) => {
        releaseEligibleRowsSnapshot(state, wakeGrantScript, String(acceptedGeneration));
        try {
          await fallbackToMain(message, error instanceof Error ? error.message : String(error));
        } catch {}
      });
  }

  // A model or effort change applies to the next branch turn without waiting
  // for /new: the live session is dropped synchronously so nothing enqueued
  // afterwards can capture it, then disposed in dispatch order behind work
  // already queued. The branch CONVERSATION is persistent
  // (state/.branch-session), so the next wake reopens the same conversation
  // under the new selection. Clearing the broken latch is what lets a
  // corrected pin recover in place.
  function releaseBranchForSelectionChange(): void {
    branchBroken = "";
    const stale = branch;
    branch = null;
    if (!stale) return;
    branchChain = branchChain
      .then(() => {
        stale.dispose();
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
    const flushSession = branch;
    branchChain = branchChain
      .then(async () => {
        if (!actingAsOwner(flushGeneration)) return;
        await flushMirror(flushSession, flushGeneration);
      })
      .catch(() => {
        // Mirror items stay queued in pendingMirror on failure; the next wake
        // or flush retries them in order.
      });
  }

  pi.events?.on?.(FM_BRANCH_DISPATCH_EVENT, (data) => {
    const offer = data as BranchDispatchOffer;
    if (!offer || typeof offer.accept !== "function") return;
    // Check eligibility before ownership activation so an out-of-scope wake
    // gets neither branch routing nor branch-owned state/lease cleanup side
    // effects.
    if (!offerEligible(offer)) return;
    if (!actingAsOwner()) return; // cold start pre-lock, secondary session, or shutdown
    if (afkActive()) return; // the away daemon owns supervision while afk
    if (branchBroken) return; // fail back to today's wake-to-main path
    if (!collectCurrentMainDialog()) return;
    offer.accept();
    enqueueWake(offer.message, generation);
  });

  pi.on?.("before_agent_start", (event, ctx) => {
    rememberMainModel(ctx);
    currentMainSession = ctx?.sessionManager ?? null;
    if (!actingAsOwner() || !currentMainSession || !collectCurrentMainDialog()) return;

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
  });
  pi.on?.("agent_end", () => {
    mainStreaming = false;
  });
  pi.on?.("agent_settled", () => {
    mainStreaming = false;
  });

  // before_agent_start stages Pi's authoritative in-flight prompt before
  // SessionManager persists it. The dispatch handler then collects any newly
  // persisted dialog immediately before accepting a wake, so all context joins
  // the serialized chain before that wake's branch prompt. turn_end remains
  // the idle-path mirror flush. The durable cursor advances only in
  // flushMirror after the complete pending batch reaches the branch.
  pi.on?.("turn_end", (_event, ctx) => {
    rememberMainModel(ctx);
    currentMainSession = ctx.sessionManager;
    if (!actingAsOwner() || !collectCurrentMainDialog()) return;
    enqueueMirrorFlush();
  });

  // Pi emits session_shutdown for ordinary same-process replacements (/new,
  // /resume, /fork, reload) as well as terminal quit, exactly as the watcher
  // extension documents. Shutdown quiesces this generation, clears the
  // volatile mirror state so the replacement reconstructs from the durable
  // cursor, and releases the branch session; a replacement session_start
  // re-arms, and the next wake reopens the persistent branch from its
  // recorded pointer. Terminal quit simply never fires another session_start.
  pi.on?.("session_start", (_event, ctx) => {
    rememberMainModel(ctx);
    currentMainSession = ctx?.sessionManager ?? null;
    shuttingDown = false;
    branchBroken = "";
    generation += 1;
    actingAsOwner(generation);
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

  pi.on?.("session_shutdown", () => {
    deactivateEligibleRowsOwner(state, wakeGrantScript, process.pid, String(generation));
    shuttingDown = true;
    generation += 1;
    pendingMirror.length = 0;
    currentMainSession = null;
    mirrorCollection.collectAnchor = null;
    mirrorCollection.pendingCursor = null;
    mirrorCollection.stagedCaptain = null;
    if (branch) {
      try {
        branch.dispose();
      } catch {
        // Already gone.
      }
      branch = null;
    }
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
      const listed = runOutcomeScript(["list", "--recent", recent]);
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

  // Pi only calls this renderer for a message with display: true, which
  // mergeIntoMain sets for every routine note except an explicitly silent
  // fleet heartbeat; captain-facing notes are never printed or rendered here.
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
