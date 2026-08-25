// Firstmate supervision branch for Pi (docs/pi-supervision-branch.md).
//
// A persistent second AgentSession - the supervision BRANCH - inside the same
// pi process as the captain's MAIN session. The watcher extension offers each
// actionable wake here (lib/fm-branch-dispatch.ts). In ordinary mode the
// branch handles it with the existing read/bash/report tools and merges an
// append-only outcome note. With a complete opt-in Pi autonomy config, the
// same second-session slot instead loads one read-only structured decision
// tool and routes every operation back to main (docs/pi-autonomous-development.md).
// Main's captain/assistant dialog
// is mirrored into the branch as read-only fm-main-mirror context at main's
// turn_end. Pi-only by construction: this file lives in .pi/extensions, so no
// other harness ever loads it. Supervision is default-on for every task once
// this Pi session owns the fleet lock: no captain grant file is required.
// Away mode (or a broken branch) keeps today's wake-to-main behavior
// untouched regardless.
//
// Prefix stability: each mode has one byte-stable prompt owner
// (bin/fm-branch-prompt.sh or bin/fm-autonomy-prompt.sh), one fixed tool set
// in a fixed order, a separate persistent session, and one shared per-home
// prompt_cache_key. Main keeps Pi's default per-session key.
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
// In ordinary mode, the captain-decided actor identity remains
// CONFUSED-AGENT-GRADE through deterministic spawnHook env injection and the
// readonly-variable shell prelude owned by bin/fm-lease-lib.sh. Opt-in autonomy
// mode creates no bash tool and has no actor-impersonation surface.
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  createAgentSession,
  createBashToolDefinition,
  DefaultResourceLoader,
  getAgentDir,
  ModelRuntime,
  SessionManager,
  type AgentSession,
  type ExtensionAPI,
  type ToolDefinition,
} from "@earendil-works/pi-coding-agent";
import { StringEnum } from "@earendil-works/pi-ai";
import { Box, Container, Text } from "@earendil-works/pi-tui";
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
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.ts";
import {
  AUTONOMY_SCHEMA,
  DECISION_SCHEMA,
  AutonomyError,
  AutonomyOrchestrator,
  DurableJournal,
  LinearGraphqlClient,
  ShellFirstmateAdapter,
  createDecision,
  decisionContractFingerprint,
  loadAutonomyConfiguration,
  setAutonomyKillSwitch,
  stableId,
  validateDecision,
  validateWorkClaim,
  type AutonomyConfig,
  type ConfigResolution,
  type DecisionClassifier,
  type DeliveryAdapter,
  type DeliveryMode,
  type DispatchProfile,
  type FirstmateAdapter,
  type LinearAdapter,
  type LoopEvent,
  type MainTranscriptCommit,
  type PendingBatch,
  type SupervisionDecision,
  type UsageObservation,
  type WorkClaim,
} from "./lib/fm-autonomy.ts";

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
const autonomySessionsDir = join(state, "autonomy-session");
const autonomySessionPointer = join(state, ".autonomy-session");
const autonomySessionBinding = join(state, ".autonomy-session-binding");
const mirrorCursorFile = join(state, ".branch-mirror-cursor");
const autonomyMirrorCursorFile = join(state, ".autonomy-mirror-cursor");
const promptScript = join(fmRoot, "bin", "fm-branch-prompt.sh");
const autonomyPromptScript = join(fmRoot, "bin", "fm-autonomy-prompt.sh");
const autonomyConfigFile = join(config, "pi-autonomy.json");
const autonomyStateDir = join(state, "autonomy");
const autonomyJournalFile = join(autonomyStateDir, "journal.jsonl");
const autonomyKillSwitch = join(autonomyStateDir, "KILL");
const outcomeScript = join(fmRoot, "bin", "fm-branch-outcome.sh");
const leaseScript = join(fmRoot, "bin", "fm-lease.sh");
const wakeGrantScript = join(fmRoot, "bin", "fm-wake-grant.sh");
const loadedMarker = join(state, ".pi-branch-extension-loaded");

// Each mode keeps its tool set stable and ordered for the complete persisted
// session. Ordinary bash is the actor-injecting override; autonomy has only
// the terminating structured decision tool.
const BRANCH_TOOL_NAMES = ["read", "bash", "fm_branch_report"] as const;
const AUTONOMY_TOOL_NAMES = ["fm_supervision_decide"] as const;

// One shared prompt_cache_key per home and mode, derived only from the home
// path so each survives restarts without letting the two prefixes collide.
const branchCacheKey = `fm-branch-${createHash("sha256").update(fmHome).digest("hex").slice(0, 24)}`;
const autonomyCacheKey = `fm-autonomy-${createHash("sha256").update(fmHome).digest("hex").slice(0, 24)}`;

const MIRROR_MESSAGE_CAP = 4000;
const MERGE_NOTE_BOAT = "⛵";
type MirrorItem = {
  tag: "captain" | "main";
  text: string;
  commit: MainTranscriptCommit;
};
type MirrorCursor = { file: string; index: number };
type Verdict = "routine" | "captain";
type LockOwnership = "owned" | "other" | "missing";
type ModelCostReference = {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
  tiers?: Array<ModelCostReference & { inputTokensAbove: number }>;
};
type MainModelReference = { provider: string; id: string; cost: ModelCostReference };

function modelRatesAt(cost: ModelCostReference, inputTokens: number): ModelCostReference {
  let rates = cost;
  for (const tier of [...(cost.tiers ?? [])].sort((left, right) => left.inputTokensAbove - right.inputTokensAbove)) {
    if (inputTokens > tier.inputTokensAbove) rates = tier;
  }
  return rates;
}

function uncachedBatchCost(cost: ModelCostReference, inputTokens: number, outputTokens: number): number {
  const rates = modelRatesAt(cost, inputTokens);
  return (rates.input * inputTokens + rates.output * outputTokens) / 1_000_000;
}

function containsCredential(value: unknown, credential: string): boolean {
  if (!credential) return false;
  if (typeof value === "string") return value.includes(credential);
  if (Array.isArray(value)) return value.some((item) => containsCredential(item, credential));
  if (value && typeof value === "object") return Object.values(value as Record<string, unknown>).some((item) => containsCredential(item, credential));
  return false;
}

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
// branch its own supervision traffic back. Current injections start with the
// U+2063 operational prefix; the plain legacy form starts with FIRSTMATE.
function isOperationalUserText(text: string): boolean {
  return text.startsWith("⁣") || /^FIRSTMATE[ _]/.test(text);
}

function capMirrorText(text: string): string {
  if (text.length <= MIRROR_MESSAGE_CAP) return text;
  return `${text.slice(0, MIRROR_MESSAGE_CAP)}\n[mirror truncated at ${MIRROR_MESSAGE_CAP} characters]`;
}

function readMirrorCursor(cursorFile: string): MirrorCursor {
  try {
    const parsed = JSON.parse(readFileSync(cursorFile, "utf8")) as Partial<MirrorCursor>;
    if (typeof parsed.file === "string" && typeof parsed.index === "number" && parsed.index >= 0) {
      return { file: parsed.file, index: Math.floor(parsed.index) };
    }
  } catch {
    // Absent or torn cursor: re-mirror the current main session from its
    // start. Idempotent context, so over-mirroring is safe; dropping is not.
  }
  return { file: "", index: 0 };
}

function writeMirrorCursor(cursorFile: string, cursor: MirrorCursor): void {
  mkdirSync(state, { recursive: true });
  writeFileSync(cursorFile, `${JSON.stringify(cursor)}\n`);
}

type ReadonlyEntries = {
  getSessionFile(): string | undefined;
  getSessionId?(): string;
  getEntries(): Array<{ type: string; id?: string; timestamp?: string }>;
};

// Volatile mirror-collection state. Instance-scoped and cleared at the
// session replacement boundary, so a replacement extension instance
// reconstructs EXCLUSIVELY from the durable cursor: dialog collected but not
// yet delivered re-mirrors rather than dropping (the durable cursor advances
// only in flushMirror after delivery).
type MirrorCollectionState = {
  collectAnchor: MirrorCursor | null;
  pendingCursor: MirrorCursor | null;
};

function collectMainDialog(sessionManager: ReadonlyEntries, collection: MirrorCollectionState, cursorFile: string): MirrorItem[] {
  const file = sessionManager.getSessionFile() ?? "";
  const entries = sessionManager.getEntries();
  const anchor = collection.collectAnchor ?? readMirrorCursor(cursorFile);
  const start = anchor.file === file ? Math.min(anchor.index, entries.length) : 0;
  const items: MirrorItem[] = [];
  for (const entry of entries.slice(start)) {
    if (entry.type !== "message") continue;
    const message = (entry as { message?: { role?: string; content?: unknown; timestamp?: number } }).message;
    if (!message) continue;
    if (message.role !== "user" && message.role !== "assistant") continue;
    const text = textOfContent(message.content).trim();
    if (!text) continue;
    if (message.role === "user" && isOperationalUserText(text)) continue;
    const capped = capMirrorText(text);
    const entryId = typeof entry.id === "string" && entry.id ? entry.id : stableId("entry", {
      file,
      index: start + items.length,
      role: message.role,
      text: capped,
    });
    const committedAt = typeof message.timestamp === "number" && Number.isFinite(message.timestamp)
      ? new Date(message.timestamp).toISOString()
      : typeof entry.timestamp === "string" && Number.isFinite(Date.parse(entry.timestamp))
        ? entry.timestamp
        : new Date(0).toISOString();
    items.push({
      tag: message.role === "user" ? "captain" : "main",
      text: capped,
      commit: {
        id: stableId("transcript", { session: file, entryId }),
        session: file || "ephemeral-main-session",
        entryId,
        role: message.role,
        text: capped,
        committedAt,
      },
    });
  }
  collection.collectAnchor = { file, index: entries.length };
  collection.pendingCursor = collection.collectAnchor;
  return items;
}

const boundarySchema = Type.Object({
  destructive: Type.Boolean(),
  irreversible: Type.Boolean(),
  production: Type.Boolean(),
  migration: Type.Boolean(),
  release: Type.Boolean(),
  credentials: Type.Boolean(),
  securitySensitive: Type.Boolean(),
  ambiguous: Type.Boolean(),
  redValidation: Type.Boolean(),
}, { additionalProperties: false });

const boundedClaimText = Type.String({ minLength: 1, maxLength: 2000 });
const boundedClaimList = Type.Array(boundedClaimText, { maxItems: 100 });
const workClaimSchema = Type.Object({
  issueId: Type.String({ minLength: 2, maxLength: 160 }),
  issueIdentifier: Type.String({ minLength: 2, maxLength: 160 }),
  repository: Type.String({ minLength: 1, maxLength: 100 }),
  dependencies: boundedClaimList,
  predictedFiles: boundedClaimList,
  predictedGlobs: boundedClaimList,
  predictedSymbols: boundedClaimList,
  migrationOrSchema: Type.Boolean(),
  sharedExternalResources: boundedClaimList,
  semanticCoupling: boundedClaimList,
  evidence: boundedClaimList,
  validation: StringEnum(["light", "heavy"] as const),
  surface: StringEnum(["internal", "product", "mixed", "unknown"] as const),
  boundaries: boundarySchema,
}, { additionalProperties: false });

const autonomyDecisionParameters = Type.Object({
  batchId: Type.String({ minLength: 2, maxLength: 256 }),
  action: StringEnum(["coalesce", "nextTurn", "wake"] as const),
  eventIds: Type.Array(Type.String({ minLength: 3, maxLength: 256 }), { minItems: 1, maxItems: 100 }),
  summary: Type.String({ minLength: 1, maxLength: 2000 }),
  reasonCodes: Type.Array(Type.String({ minLength: 1, maxLength: 100 }), { minItems: 1, maxItems: 100 }),
  workClaims: Type.Array(workClaimSchema, { maxItems: 100 }),
}, { additionalProperties: false });

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
  const mirrorCollection: MirrorCollectionState = { collectAnchor: null, pendingCursor: null };
  let mainSessionManager: ReadonlyEntries | null = null;
  let autonomyResolution: ConfigResolution = {
    configured: false,
    valid: false,
    active: false,
    killed: false,
    credentialPresent: false,
    diagnostics: ["config/pi-autonomy.json is absent"],
  };
  let autonomy: AutonomyOrchestrator | null = null;
  let autonomyTimer: ReturnType<typeof setInterval> | null = null;
  let autonomyTickPromise: Promise<void> | null = null;
  let autonomyProcessGeneration = "0";
  let autonomyConfigurationGeneration = 0;
  let activatingAutonomy = false;
  let pendingAutonomyActivation: {
    config: AutonomyConfig;
    sessionGeneration: number;
    configurationGeneration: number;
    mainModel?: MainModelReference;
  } | null = null;
  let pendingDecisionBatch: PendingBatch | null = null;
  let pendingDecisionResolve: ((decision: SupervisionDecision) => void) | null = null;
  let pendingDecisionReject: ((error: Error) => void) | null = null;
  let autonomyTurnIndex = 0;
  let successfulBranchReports = 0;
  const retainedLinearCredentials = new Map<string, string>();
  const knownLinearCredentialNames = new Set<string>();
  const knownLinearCredentialValues = new Set<string>();
  let unsubscribeBranchUsage: (() => void) | null = null;

  function restoreRetainedLinearCredentials(): void {
    for (const [name, value] of retainedLinearCredentials) {
      if (process.env[name] === undefined) process.env[name] = value;
    }
    retainedLinearCredentials.clear();
  }

  function safeScriptEnv(): NodeJS.ProcessEnv {
    const env: NodeJS.ProcessEnv = { ...scriptEnv };
    for (const name of knownLinearCredentialNames) delete env[name];
    for (const name of retainedLinearCredentials.keys()) delete env[name];
    return env;
  }

  function redactRuntimeCredential(text: string): string {
    let redacted = text;
    for (const credential of knownLinearCredentialValues) {
      if (credential) redacted = redacted.replaceAll(credential, "[redacted runtime credential]");
    }
    return redacted;
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
        env: { ...safeScriptEnv(), FM_SUPERVISION_ACTOR: "branch" },
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
        env: safeScriptEnv(),
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

  function autonomyRuntimeUsable(): boolean {
    return Boolean(autonomyResolution.config && autonomy && autonomyResolution.valid && autonomyResolution.credentialPresent &&
      autonomyResolution.diagnostics.every((line) => line.startsWith("state/autonomy/KILL is present")));
  }

  function autonomyMode(): boolean {
    return autonomyRuntimeUsable() && (autonomyResolution.active || autonomyResolution.killed);
  }

  function autonomyIntakeReady(): boolean {
    return autonomyRuntimeUsable() && !existsSync(autonomyKillSwitch);
  }

  function mainHasDecision(decisionId: string): boolean {
    if (!mainSessionManager) return false;
    try {
      return mainSessionManager.getEntries().some((entry) => {
        if (entry.type === "custom_message") {
          const custom = entry as unknown as { customType?: string; details?: { decisionId?: unknown } };
          return custom.customType === "fm-autonomy-decision" && custom.details?.decisionId === decisionId;
        }
        if (entry.type === "message") {
          const wrapped = entry as unknown as { message?: { role?: string; customType?: string; details?: { decisionId?: unknown } } };
          return wrapped.message?.role === "custom" && wrapped.message.customType === "fm-autonomy-decision" && wrapped.message.details?.decisionId === decisionId;
        }
        return false;
      });
    } catch {
      return false;
    }
  }

  function deliveryAdapter(expectedGeneration: number, expectedConfigurationGeneration = autonomyConfigurationGeneration): DeliveryAdapter {
    return {
      isMainIdle: () => !mainStreaming,
      sessionId: () => mainSessionManager?.getSessionId?.() ?? mainSessionManager?.getSessionFile() ?? "ephemeral-main-session",
      processGeneration: () => `${process.pid}:${expectedGeneration}:${autonomyProcessGeneration}`,
      hasDelivered: mainHasDecision,
      async deliver(decision, mode) {
        if (expectedConfigurationGeneration !== autonomyConfigurationGeneration || !actingAsOwner(expectedGeneration)) {
          return {
            accepted: false,
            evidence: "the Pi session was replaced, reconfigured, or lost fleet ownership before delivery",
            sessionId: this.sessionId(),
            processGeneration: this.processGeneration(),
          };
        }
        const content = [
          "FIRSTMATE AUTONOMY DECISION",
          decision.summary,
          "Load the linear-autonomy skill before acting.",
          "Use only the local allowlist and existing Firstmate delivery, validation, and guarded landing paths.",
          "Run bin/fm-wake-drain.sh first when a listed event is a Firstmate notification.",
          JSON.stringify({
            schema: decision.schema,
            decisionId: decision.id,
            batchId: decision.batchId,
            action: decision.action,
            eventIds: decision.eventIds,
            reasonCodes: decision.reasonCodes,
            workClaims: decision.workClaims,
          }),
        ].join("\n\n");
        const message = {
          customType: "fm-autonomy-decision",
          content,
          display: mode === "nextTurn",
          details: { decisionId: decision.id, batchId: decision.batchId, action: decision.action },
        };
        if (mode === "nextTurn") pi.sendMessage(message, { deliverAs: "nextTurn" });
        else if (mode === "steer-working") pi.sendMessage(message, { deliverAs: "steer" });
        else pi.sendMessage(message, { deliverAs: "followUp", triggerTurn: true });
        return {
          accepted: true,
          evidence: `Pi accepted ${mode} delivery for decision ${decision.id}`,
          sessionId: this.sessionId(),
          processGeneration: this.processGeneration(),
        };
      },
    };
  }

  function configureAutonomy(expectedGeneration: number, mainModel?: MainModelReference): Promise<void> | void {
    const expectedConfigurationGeneration = ++autonomyConfigurationGeneration;
    pendingAutonomyActivation = null;
    if (autonomyTimer) clearInterval(autonomyTimer);
    autonomyTimer = null;
    autonomy = null;
    const configEnvironment: NodeJS.ProcessEnv = { ...process.env };
    for (const [name, value] of retainedLinearCredentials) configEnvironment[name] = value;
    autonomyResolution = loadAutonomyConfiguration(autonomyConfigFile, autonomyKillSwitch, configEnvironment);
    autonomyProcessGeneration = `${Date.now()}:${expectedGeneration}:${expectedConfigurationGeneration}`;
    const configValue = autonomyResolution.config;
    const resolvedCredentialName = configValue?.linear.credential.env;
    if (resolvedCredentialName) {
      knownLinearCredentialNames.add(resolvedCredentialName);
      const resolvedCredential = configEnvironment[resolvedCredentialName];
      if (resolvedCredential) knownLinearCredentialValues.add(resolvedCredential);
    }
    if (!configValue || !autonomyResolution.valid || !autonomyResolution.credentialPresent) {
      restoreRetainedLinearCredentials();
      return;
    }
    const credentialName = configValue.linear.credential.env;
    const credential = configEnvironment[credentialName];
    if (credential) {
      retainedLinearCredentials.set(credentialName, credential);
      if (process.env[credentialName] === credential) delete process.env[credentialName];
    }
    if (lockOwnership() !== "owned") {
      pendingAutonomyActivation = {
        config: configValue,
        sessionGeneration: expectedGeneration,
        configurationGeneration: expectedConfigurationGeneration,
        mainModel,
      };
      return;
    }

    return finishConfigureAutonomy(configValue, expectedGeneration, expectedConfigurationGeneration, mainModel);
  }

  async function finishConfigureAutonomy(
    configValue: AutonomyConfig,
    expectedGeneration: number,
    expectedConfigurationGeneration: number,
    mainModel?: MainModelReference,
  ): Promise<void> {
    const rawFirstmate = new ShellFirstmateAdapter({
      fmRoot,
      fmHome,
      state,
      data: process.env.FM_DATA_OVERRIDE || join(fmHome, "data"),
      projects: process.env.FM_PROJECTS_OVERRIDE || join(fmHome, "projects"),
      env: safeScriptEnv(),
      redactedEnvNames: [configValue.linear.credential.env],
    });
    const localDiagnostics = rawFirstmate.doctor(configValue);
    if (localDiagnostics.length > 0) {
      autonomyResolution = {
        ...autonomyResolution,
        active: false,
        diagnostics: [...autonomyResolution.diagnostics, ...localDiagnostics],
      };
    }
    let modelDiagnostic = "";
    let selectedModelCost: ModelCostReference | undefined;
    try {
      const modelSignal = AbortSignal.timeout(Math.min(configValue.supervision.limits.maxTurnMilliseconds, 15000));
      const modelRuntime = await ModelRuntime.create({ allowModelNetwork: false, signal: modelSignal });
      const available = await modelRuntime.getAvailable(configValue.supervision.model.provider, { signal: modelSignal });
      const selected = available.find((model) => model.id === configValue.supervision.model.id);
      const resolvedModelAuth = selected ? await modelRuntime.getAuth(selected, { signal: modelSignal }) : undefined;
      const mainCatalogModel = mainModel ? modelRuntime.getModel(mainModel.provider, mainModel.id) : undefined;
      const resolvedMainAuth = mainCatalogModel ? await modelRuntime.getAuth(mainCatalogModel, { signal: modelSignal }) : undefined;
      const linearCredential = retainedLinearCredentials.get(configValue.linear.credential.env) ?? "";
      const supervisionCredentialCollision = Boolean(resolvedModelAuth && containsCredential(resolvedModelAuth, linearCredential));
      const mainCredentialCollision = Boolean(resolvedMainAuth && containsCredential(resolvedMainAuth, linearCredential));
      if (supervisionCredentialCollision || mainCredentialCollision) {
        modelDiagnostic = "configured Linear credential collides with main or supervision model provider authentication; use separate credentials and dedicated environment names";
      } else if (!selected) {
        modelDiagnostic = `configured supervision model ${configValue.supervision.model.provider}/${configValue.supervision.model.id} is unavailable or lacks Pi authentication`;
      } else if (!resolvedModelAuth) {
        modelDiagnostic = `configured supervision model ${configValue.supervision.model.provider}/${configValue.supervision.model.id} lost authentication during activation`;
      } else if (mainModel && (!mainCatalogModel || !resolvedMainAuth)) {
        modelDiagnostic = `main Pi model ${mainModel.provider}/${mainModel.id} authentication could not be independently verified without the Linear credential`;
      } else if (configValue.supervision.limits.maxPromptInputTokens + configValue.supervision.limits.maxOutputTokens > selected.contextWindow) {
        modelDiagnostic = `configured supervision input/output ceilings exceed the selected model context window (${configValue.supervision.limits.maxPromptInputTokens + configValue.supervision.limits.maxOutputTokens} > ${selected.contextWindow})`;
      } else {
        selectedModelCost = selected.cost;
        if (!mainModel) {
          modelDiagnostic = "main Pi model is unavailable, so the configured supervision model cannot be proven distinct and cheaper";
        } else {
          if (selected.provider === mainModel.provider && selected.id === mainModel.id) {
            modelDiagnostic = "configured supervision model must be distinct from the main Pi model";
          } else {
            const inputTokens = configValue.supervision.limits.maxPromptInputTokens;
            const outputTokens = configValue.supervision.limits.maxOutputTokens;
            const selectedBatchCost = uncachedBatchCost(selected.cost, inputTokens, outputTokens);
            const mainBatchCost = uncachedBatchCost(mainModel.cost, inputTokens, outputTokens);
            if (!(selectedBatchCost < mainBatchCost)) {
              modelDiagnostic = `configured supervision model is not cheaper than the main Pi model for the configured uncached batch ceiling (${selectedBatchCost.toFixed(6)} >= ${mainBatchCost.toFixed(6)} USD)`;
            }
          }
        }
      }
    } catch (error) {
      modelDiagnostic = `configured supervision model could not be checked: ${redactRuntimeCredential(error instanceof Error ? error.message : String(error))}`;
    }
    if (expectedGeneration !== generation || expectedConfigurationGeneration !== autonomyConfigurationGeneration || shuttingDown) return;
    if (modelDiagnostic) {
      autonomyResolution = {
        ...autonomyResolution,
        active: false,
        diagnostics: [...autonomyResolution.diagnostics, modelDiagnostic],
      };
    }
    if ((!autonomyResolution.active && !autonomyResolution.killed) || ((localDiagnostics.length > 0 || modelDiagnostic) && !autonomyResolution.killed)) return;
    const token = retainedLinearCredentials.get(configValue.linear.credential.env) ?? "";
    const rawLinear = token
      ? new LinearGraphqlClient({
          token,
          credentialKind: configValue.linear.credential.kind,
          limits: configValue.supervision.limits,
        })
      : undefined;
    const assertRuntimeOwner = (): void => {
      if (expectedConfigurationGeneration !== autonomyConfigurationGeneration || !actingAsOwner(expectedGeneration)) {
        throw new AutonomyError("session-replaced", "autonomy operation was replaced, reconfigured, or lost fleet ownership");
      }
    };
    const linear: LinearAdapter | undefined = rawLinear ? {
      async listEligibleIssues(config) {
        assertRuntimeOwner();
        const result = await rawLinear.listEligibleIssues(config);
        assertRuntimeOwner();
        return result;
      },
      async claimIssue(config, issue, claimId, taskId) {
        assertRuntimeOwner();
        const result = await rawLinear.claimIssue(config, issue, claimId, taskId);
        assertRuntimeOwner();
        return result;
      },
      async getIssue(config, issueId) {
        assertRuntimeOwner();
        const result = await rawLinear.getIssue(config, issueId);
        assertRuntimeOwner();
        return result;
      },
      async setProgress(config, issue, claimId, taskId, summary) {
        assertRuntimeOwner();
        const result = await rawLinear.setProgress(config, issue, claimId, taskId, summary);
        assertRuntimeOwner();
        return result;
      },
      async linkPullRequest(config, issue, claimId, taskId, prUrl) {
        assertRuntimeOwner();
        const result = await rawLinear.linkPullRequest(config, issue, claimId, taskId, prUrl);
        assertRuntimeOwner();
        return result;
      },
      async completeIssue(config, issue, claimId, taskId, prUrl) {
        assertRuntimeOwner();
        const result = await rawLinear.completeIssue(config, issue, claimId, taskId, prUrl);
        assertRuntimeOwner();
        return result;
      },
      async reconcileClaim(config, issue, claimId, taskId, phase) {
        assertRuntimeOwner();
        const result = await rawLinear.reconcileClaim(config, issue, claimId, taskId, phase);
        assertRuntimeOwner();
        return result;
      },
    } : undefined;
    const firstmate: FirstmateAdapter = {
      capacity(config) {
        assertRuntimeOwner();
        return rawFirstmate.capacity(config);
      },
      assertProjectOwnership(config, issue) {
        assertRuntimeOwner();
        rawFirstmate.assertProjectOwnership(config, issue);
      },
      assertPullRequestRepository(config, issue, prUrl) {
        assertRuntimeOwner();
        rawFirstmate.assertPullRequestRepository(config, issue, prUrl);
      },
      async dispatch(config, issue, claim, taskId, profile) {
        assertRuntimeOwner();
        const result = await rawFirstmate.dispatch(config, issue, claim, taskId, profile);
        assertRuntimeOwner();
        return result;
      },
      taskExists(taskId) {
        assertRuntimeOwner();
        return rawFirstmate.taskExists(taskId);
      },
      taskPullRequest(taskId) {
        assertRuntimeOwner();
        return rawFirstmate.taskPullRequest(taskId);
      },
      async prepareLanding(config, issue, taskId, prUrl) {
        assertRuntimeOwner();
        const result = await rawFirstmate.prepareLanding(config, issue, taskId, prUrl);
        assertRuntimeOwner();
        return result;
      },
      async mergeAndVerify(config, issue, taskId, prUrl, expectedHead) {
        assertRuntimeOwner();
        const result = await rawFirstmate.mergeAndVerify(config, issue, taskId, prUrl, expectedHead);
        assertRuntimeOwner();
        return result;
      },
      async verifyMerged(config, issue, taskId, prUrl, expectedHead) {
        assertRuntimeOwner();
        const result = await rawFirstmate.verifyMerged(config, issue, taskId, prUrl, expectedHead);
        assertRuntimeOwner();
        return result;
      },
      doctor(config) {
        return rawFirstmate.doctor(config);
      },
    };
    const classifier: DecisionClassifier = {
      async classify(batch) {
        assertRuntimeOwner();
        const decision = await classifyWithAutonomyBranch(batch, expectedGeneration);
        assertRuntimeOwner();
        return decision;
      },
    };
    if (expectedGeneration !== generation || expectedConfigurationGeneration !== autonomyConfigurationGeneration || shuttingDown) return;
    autonomy = new AutonomyOrchestrator({
      resolution: autonomyResolution,
      journal: new DurableJournal(autonomyJournalFile),
      linear,
      firstmate,
      delivery: deliveryAdapter(expectedGeneration, expectedConfigurationGeneration),
      classifier,
      classificationCostEstimator: selectedModelCost
        ? (inputTokens, outputTokens) => uncachedBatchCost(selectedModelCost, inputTokens, outputTokens) * configValue.supervision.limits.maxIterationsPerBatch
        : undefined,
      killSwitchPath: autonomyKillSwitch,
      redactedValues: [...knownLinearCredentialValues],
    });
    autonomyTimer = setInterval(() => {
      void runAutonomyTick(expectedGeneration, true);
    }, configValue.pollSeconds * 1000);
    autonomyTimer.unref();
  }

  async function activatePendingAutonomy(): Promise<boolean> {
    const pending = pendingAutonomyActivation;
    if (activatingAutonomy || !pending || pending.sessionGeneration !== generation || pending.configurationGeneration !== autonomyConfigurationGeneration || !actingAsOwner(pending.sessionGeneration)) {
      return false;
    }
    activatingAutonomy = true;
    pendingAutonomyActivation = null;
    let succeeded = true;
    try {
      await finishConfigureAutonomy(pending.config, pending.sessionGeneration, pending.configurationGeneration, pending.mainModel);
    } catch (error) {
      succeeded = false;
      autonomyResolution = {
        ...autonomyResolution,
        active: false,
        diagnostics: [...autonomyResolution.diagnostics, `deferred autonomy activation failed: ${redactRuntimeCredential(error instanceof Error ? error.message : String(error))}`],
      };
      restoreRetainedLinearCredentials();
    } finally {
      activatingAutonomy = false;
      if (shuttingDown) restoreRetainedLinearCredentials();
    }
    if (mainSessionManager && actingAsOwner(pending.sessionGeneration)) {
      try {
        pendingMirror.push(...collectMainDialog(
          mainSessionManager,
          mirrorCollection,
          autonomyMode() ? autonomyMirrorCursorFile : mirrorCursorFile,
        ).map((item) => {
          const text = redactRuntimeCredential(item.text);
          return { ...item, text, commit: { ...item.commit, text } };
        }));
      } catch {}
    }
    return succeeded;
  }

  function decisionFromTool(params: unknown): SupervisionDecision {
    if (!pendingDecisionBatch) throw new AutonomyError("decision-unexpected", "no autonomy batch is awaiting a structured decision");
    const object = params && typeof params === "object" && !Array.isArray(params)
      ? params as Record<string, unknown>
      : {};
    if (typeof object.batchId !== "string" || typeof object.summary !== "string") {
      throw new AutonomyError("decision-invalid", "batchId and summary must be strings");
    }
    if (object.action !== "coalesce" && object.action !== "nextTurn" && object.action !== "wake") {
      throw new AutonomyError("decision-invalid", "action must be coalesce, nextTurn, or wake");
    }
    if (!Array.isArray(object.eventIds) || object.eventIds.some((value) => typeof value !== "string") ||
        !Array.isArray(object.reasonCodes) || object.reasonCodes.some((value) => typeof value !== "string") ||
        !Array.isArray(object.workClaims) || object.workClaims.length > 100) {
      throw new AutonomyError("decision-invalid", "eventIds, reasonCodes, and at most 100 workClaims must be typed arrays");
    }
    const claims: WorkClaim[] = object.workClaims.map((candidate, index) => {
      const result = validateWorkClaim(candidate, `workClaims[${index}]`);
      if (!result.claim) throw new AutonomyError("decision-invalid", result.errors.join("; "));
      return result.claim;
    });
    const decision = createDecision({
      batchId: object.batchId,
      action: object.action,
      eventIds: object.eventIds,
      summary: object.summary,
      reasonCodes: object.reasonCodes,
      workClaims: claims,
    });
    return validateDecision(decision, pendingDecisionBatch);
  }

  function createAutonomyDecisionTool(toolGeneration: number): ToolDefinition {
    return {
      name: "fm_supervision_decide",
      label: "Route supervision events",
      description: "Return the one final structured routing decision for the currently offered durable event batch. This tool only records and routes attention; it performs no project, Linear, shell, dispatch, or merge action.",
      parameters: autonomyDecisionParameters,
      async execute(_toolCallId, params) {
        if (!actingAsOwner(toolGeneration)) throw new AutonomyError("decision-replaced", "supervision session was replaced or lost fleet ownership");
        const decision = decisionFromTool(params);
        const resolveDecision = pendingDecisionResolve;
        pendingDecisionResolve = null;
        pendingDecisionReject = null;
        pendingDecisionBatch = null;
        resolveDecision?.(decision);
        return {
          content: [{ type: "text", text: `accepted structured decision ${decision.id}` }],
          details: { decisionId: decision.id, action: decision.action },
          terminate: true,
        };
      },
    };
  }

  async function rotateAutonomySession(session: AgentSession, expectedGeneration: number, replayTokenBudget: number): Promise<AgentSession> {
    if (!actingAsOwner(expectedGeneration) || branch !== session) throw new AutonomyError("session-reconfigured", "autonomy session changed before bounded rotation");
    unsubscribeBranchUsage?.();
    unsubscribeBranchUsage = null;
    try {
      session.dispose();
    } catch {}
    branch = null;
    branchBroken = "";
    writeFileSync(autonomySessionPointer, "", { mode: 0o600 });
    const replacement = await ensureBranch(expectedGeneration);
    const commits = (autonomy?.journal.read() ?? [])
      .filter((record) => record.kind === "transcript")
      .map((record) => record.data as unknown as MainTranscriptCommit)
      .filter((commit) => (commit.role === "user" || commit.role === "assistant") && typeof commit.text === "string" && commit.text.length > 0);
    const replay: MainTranscriptCommit[] = [];
    let replayTokens = 0;
    for (const commit of commits.reverse()) {
      const tokens = Buffer.byteLength(commit.text, "utf8");
      if (replayTokens + tokens > replayTokenBudget) continue;
      replay.unshift(commit);
      replayTokens += tokens;
    }
    for (const commit of replay) {
      await replacement.sendCustomMessage({
        customType: "fm-main-mirror",
        content: `[${commit.role === "user" ? "captain" : "main"}] ${redactRuntimeCredential(commit.text)}`,
        display: false,
      }, {});
    }
    return replacement;
  }

  async function classifyWithAutonomyBranch(batch: PendingBatch, expectedGeneration: number): Promise<SupervisionDecision> {
    if (!autonomyMode()) throw new AutonomyError("autonomy-inactive", "Pi autonomy is not active");
    let session = await ensureBranch(expectedGeneration);
    await flushMirror(session, expectedGeneration);
    const limits = autonomyResolution.config?.supervision.limits;
    if (!limits) throw new AutonomyError("autonomy-inactive", "Pi autonomy lost its validated limits");
    let contextUsage = typeof session.getContextUsage === "function" ? session.getContextUsage() : undefined;
    let boundedInputTokens = typeof contextUsage?.tokens === "number"
      ? contextUsage.tokens + batch.estimatedInputTokens + 512
      : limits.maxPromptInputTokens;
    if (boundedInputTokens > limits.maxPromptInputTokens) {
      session = await rotateAutonomySession(session, expectedGeneration, Math.floor(limits.maxPromptInputTokens / 3));
      contextUsage = typeof session.getContextUsage === "function" ? session.getContextUsage() : undefined;
      boundedInputTokens = typeof contextUsage?.tokens === "number"
        ? contextUsage.tokens + batch.estimatedInputTokens + 512
        : limits.maxPromptInputTokens;
      if (boundedInputTokens > limits.maxPromptInputTokens) {
        throw new AutonomyError("token-ceiling", `fresh supervision context plus this batch estimates ${boundedInputTokens} input tokens above maxPromptInputTokens=${limits.maxPromptInputTokens}`);
      }
    }
    if (!autonomy) throw new AutonomyError("session-reconfigured", "Pi autonomy was reconfigured before classification");
    autonomy.assertClassificationBudget(boundedInputTokens);
    if (pendingDecisionBatch) throw new AutonomyError("decision-busy", "another autonomy batch is already awaiting a decision", true);
    pendingDecisionBatch = batch;
    autonomyTurnIndex = 0;
    const decisionPromise = new Promise<SupervisionDecision>((resolveDecision, rejectDecision) => {
      pendingDecisionResolve = resolveDecision;
      pendingDecisionReject = rejectDecision;
    });
    void decisionPromise.catch(() => {});
    const prompt = [
      `AUTONOMY BATCH ${batch.id}`,
      `Decision contract fingerprint: ${decisionContractFingerprint()}`,
      "Account for every event exactly once and finish with fm_supervision_decide.",
      JSON.stringify({ batchId: batch.id, events: batch.events }),
    ].join("\n\n");
    const limit = limits.maxTurnMilliseconds;
    let timeout: ReturnType<typeof setTimeout> | undefined;
    const timeoutPromise = new Promise<never>((_resolve, rejectTimeout) => {
      timeout = setTimeout(() => {
        const error = new AutonomyError("turn-time-ceiling", `supervision turn exceeded maxTurnMilliseconds=${limit}`);
        const rejectDecision = pendingDecisionReject;
        pendingDecisionResolve = null;
        pendingDecisionReject = null;
        pendingDecisionBatch = null;
        rejectDecision?.(error);
        void session.abort().catch(() => {});
        rejectTimeout(error);
      }, limit);
      timeout.unref();
    });
    try {
      const classification = session.prompt(prompt).then(async () => {
        if (pendingDecisionBatch?.id === batch.id) {
          throw new AutonomyError("decision-missing", "supervision model ended without one valid fm_supervision_decide call");
        }
        return decisionPromise;
      });
      return await Promise.race([classification, timeoutPromise]);
    } finally {
      if (timeout) clearTimeout(timeout);
      if (pendingDecisionBatch?.id === batch.id) {
        pendingDecisionBatch = null;
        pendingDecisionResolve = null;
        pendingDecisionReject = null;
      }
    }
  }

  async function deliverClassifierFailure(expectedGeneration: number, error: unknown): Promise<void> {
    if (!autonomy || !autonomyResolution.config) return;
    const detail = (error instanceof Error ? error.message : String(error)).replaceAll("\u0000", "").slice(0, 1000);
    const pending = autonomy.journal.pendingEvents(autonomyResolution.config.supervision.limits.maxBatchEvents);
    const pendingBatchId = stableId("batch", pending.map((event) => event.id));
    const event: LoopEvent = {
      id: stableId("classifier-error", { pendingBatchId, detail }),
      source: "pi",
      kind: "pi.supervision.error",
      occurredAt: new Date().toISOString(),
      urgency: "urgent",
      payload: { pendingBatchId, pendingEventCount: pending.length, detail },
    };
    autonomy.appendEvent(event);
    const failureBatch: PendingBatch = {
      id: stableId("batch", [event.id]),
      events: [event],
      issueCount: 0,
      estimatedInputTokens: 0,
    };
    const decision = validateDecision(createDecision({
      batchId: failureBatch.id,
      action: "wake",
      eventIds: [event.id],
      summary: `Autonomous supervision could not classify ${pending.length} pending event(s) safely: ${detail.slice(0, 500)}. Main must inspect the blocker; original events remain pending for bounded retry.`,
      reasonCodes: ["classifier-failed", "stronger-boundary"],
      workClaims: [],
    }), failureBatch);
    autonomy.journal.append("decision", decision.id, decision as unknown as never, `decision:${decision.id}`);
    await autonomy.deliverDecision(decision, deliveryAdapter(expectedGeneration));
  }

  async function runAutonomyTick(expectedGeneration: number, intake: boolean): Promise<void> {
    if (autonomyTickPromise) {
      await autonomyTickPromise;
      return;
    }
    if (!autonomy || !autonomyResolution.config) return;
    if (!actingAsOwner(expectedGeneration) || afkActive()) return;
    const orchestrator = autonomy;
    const tick = (async () => {
      try {
        const reconciliation = await orchestrator.reconcile();
        if (reconciliation.conflicts > 0) {
          const conflicts = orchestrator.journal.read()
            .filter((record) => record.kind === "claim-conflict")
            .slice(-Math.min(reconciliation.conflicts, autonomyResolution.config!.supervision.limits.maxBatchIssues))
            .map((record) => ({ issueId: record.key, recordId: record.recordId }));
          orchestrator.appendEvent({
            id: stableId("claim-conflict-event", conflicts),
            source: "linear",
            kind: "linear.claim.conflict",
            occurredAt: new Date().toISOString(),
            urgency: "urgent",
            payload: { conflicts },
          });
        }
        if (!autonomyRuntimeUsable()) return;
        const pendingDecision = await orchestrator.classifyPendingBatch();
        if (pendingDecision) {
          await orchestrator.deliverDecision(pendingDecision, deliveryAdapter(expectedGeneration));
          return;
        }
        if (intake && autonomyIntakeReady()) {
          await orchestrator.intakeLinearIssues();
          const intakeDecision = await orchestrator.classifyPendingBatch();
          if (intakeDecision) await orchestrator.deliverDecision(intakeDecision, deliveryAdapter(expectedGeneration));
        }
      } catch (error) {
        try {
          if (error instanceof AutonomyError && error.code.startsWith("linear-")) {
            const safeLinearMessage = error.message.replaceAll("\u0000", "").slice(0, 1000);
            const event: LoopEvent = {
              id: stableId("linear-error", { code: error.code, message: safeLinearMessage }),
              source: "linear",
              kind: "linear.adapter.error",
              occurredAt: new Date().toISOString(),
              urgency: "urgent",
              payload: { code: error.code, message: safeLinearMessage },
            };
            orchestrator.appendEvent(event);
            const failureBatch: PendingBatch = {
              id: stableId("batch", [event.id]),
              events: [event],
              issueCount: 0,
              estimatedInputTokens: 0,
            };
            const failureDecision = validateDecision(createDecision({
              batchId: failureBatch.id,
              action: "wake",
              eventIds: [event.id],
              summary: `Linear supervision needs main-session attention: ${safeLinearMessage.slice(0, 500)}`,
              reasonCodes: ["linear-adapter-failed"],
              workClaims: [],
            }), failureBatch);
            orchestrator.journal.append("decision", failureDecision.id, failureDecision as unknown as never, `decision:${failureDecision.id}`);
            await orchestrator.deliverDecision(failureDecision, deliveryAdapter(expectedGeneration));
          } else {
            await deliverClassifierFailure(expectedGeneration, error);
          }
        } catch {
          branchBroken = error instanceof Error ? error.message : String(error);
        }
      }
    })();
    autonomyTickPromise = tick;
    try {
      await tick;
    } finally {
      if (autonomyTickPromise === tick) autonomyTickPromise = null;
    }
  }

  function enqueueAutonomyWake(message: string, acceptedGeneration: number): void {
    branchChain = branchChain
      .then(async () => {
        if (!autonomy || !actingAsOwner(acceptedGeneration)) throw new Error("autonomy supervision lost fleet ownership");
        const heartbeat = /^heartbeat($|:)/.test(message);
        const scope = scopeForUnreadWake(state, heartbeat);
        if (scope.status === "empty" || (!scope.corrupted && scope.eligibleSeqs.length === 0)) return;
        if (scope.corrupted) throw new Error("the unread wake queue could not be classified safely");
        const event: LoopEvent = {
          id: stableId("firstmate-wake", { seqs: scope.eligibleSeqs, message }),
          source: "firstmate",
          kind: "firstmate.notification",
          occurredAt: new Date().toISOString(),
          urgency: "urgent",
          payload: { message, eligibleSeqs: scope.eligibleSeqs, projects: scope.projects, heartbeat },
        };
        autonomy.appendEvent(event);
        await runAutonomyTick(acceptedGeneration, false);
      })
      .catch(async (error: unknown) => {
        try {
          await fallbackToMain(message, error instanceof Error ? error.message : String(error));
        } catch {}
      });
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
      const message = { customType: "fm-branch-merge", content: `${task}: ${summary}`, display: false };
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
          description: "captain only for what a human must see; routine otherwise",
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
        successfulBranchReports += 1;
        return {
          content: [{ type: "text", text: `recorded seq ${appended.stdout} and merged [${verdict}] into main` }],
          details: undefined,
        };
      },
    };
  }

  async function createBranch(branchGeneration: number): Promise<AgentSession> {
    const useAutonomy = autonomyMode();
    const selectedPromptScript = useAutonomy ? autonomyPromptScript : promptScript;
    const selectedSessionsDir = useAutonomy ? autonomySessionsDir : sessionsDir;
    const selectedSessionPointer = useAutonomy ? autonomySessionPointer : sessionPointer;
    const selectedCacheKey = useAutonomy ? autonomyCacheKey : branchCacheKey;
    const prompt = spawnSync("bash", [selectedPromptScript], {
      cwd: fmRoot,
      encoding: "utf8",
      env: safeScriptEnv(),
      maxBuffer: 4 * 1024 * 1024,
    });
    if (prompt.status !== 0 || !prompt.stdout || prompt.stdout.length < 1024) {
      throw new Error(
        `${selectedPromptScript} did not produce a usable supervision prompt (status=${prompt.status ?? "none"}): ${(prompt.stderr || "").trim()}`,
      );
    }
    if (!actingAsOwner(branchGeneration)) throw new Error("supervision session was replaced or lost lock ownership");
    const expectedSessionBinding = useAutonomy && autonomyResolution.config
      ? stableId("autonomy-session", {
          contractFingerprint: decisionContractFingerprint(),
          promptSha256: createHash("sha256").update(prompt.stdout).digest("hex"),
          provider: autonomyResolution.config.supervision.model.provider,
          model: autonomyResolution.config.supervision.model.id,
          thinkingLevel: autonomyResolution.config.supervision.model.thinkingLevel,
          tools: [...AUTONOMY_TOOL_NAMES],
        })
      : "";
    mkdirSync(selectedSessionsDir, { recursive: true });
    let sessionManager: SessionManager | null = null;
    try {
      const bindingMatches = !useAutonomy || readFileSync(autonomySessionBinding, "utf8").trim() === expectedSessionBinding;
      const recorded = readFileSync(selectedSessionPointer, "utf8").trim();
      if (bindingMatches && recorded && existsSync(recorded)) {
        sessionManager = SessionManager.open(recorded, selectedSessionsDir);
      }
    } catch {
      sessionManager = null;
    }
    if (!sessionManager) sessionManager = SessionManager.create(fmRoot, selectedSessionsDir);
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
          name: useAutonomy ? "fm-autonomy-cache-key" : "fm-branch-cache-key",
          factory: (branchPi: ExtensionAPI) => {
            branchPi.on("before_provider_request", (event) => {
              const payload = event.payload;
              if (payload && typeof payload === "object" && "prompt_cache_key" in payload) {
                return { ...(payload as Record<string, unknown>), prompt_cache_key: selectedCacheKey };
              }
            });
          },
        },
      ],
    });
    await loader.reload();
    if (!actingAsOwner(branchGeneration)) throw new Error("supervision session was replaced or lost lock ownership");

    let tools: string[] = [...BRANCH_TOOL_NAMES];
    let customTools: ToolDefinition[];
    let modelOptions: Record<string, unknown> = {};
    if (useAutonomy) {
      const configValue = autonomyResolution.config;
      if (!configValue) throw new Error("Pi autonomy lost its validated configuration");
      tools = [...AUTONOMY_TOOL_NAMES];
      customTools = [createAutonomyDecisionTool(branchGeneration)];
      const modelSignal = AbortSignal.timeout(Math.min(configValue.supervision.limits.maxTurnMilliseconds, 15000));
      const modelRuntime = await ModelRuntime.create({ allowModelNetwork: false, signal: modelSignal });
      const available = await modelRuntime.getAvailable(configValue.supervision.model.provider, { signal: modelSignal });
      const selectedModel = available.find((model) => model.id === configValue.supervision.model.id);
      if (!selectedModel) {
        throw new Error(
          `configured supervision model ${configValue.supervision.model.provider}/${configValue.supervision.model.id} is unavailable or lacks Pi authentication`,
        );
      }
      const boundedModel = {
        ...selectedModel,
        maxTokens: Math.min(selectedModel.maxTokens, configValue.supervision.limits.maxOutputTokens),
      };
      modelOptions = {
        model: boundedModel,
        modelRuntime,
        thinkingLevel: configValue.supervision.model.thinkingLevel,
      };
    } else {
      const leaseHolderPid = ownedLockPid;
      const bashTool = createBashToolDefinition(fmRoot, {
        spawnHook: (context) => {
          if (!actingAsOwner(branchGeneration)) {
            throw new Error("bash refused: supervision session was replaced or lost lock ownership");
          }
          return {
            ...context,
            command: `readonly FM_SUPERVISION_ACTOR FM_LEASE_HOLDER_PID
(
${context.command}
)`,
            env: {
              ...context.env,
              ...safeScriptEnv(),
              FM_SUPERVISION_ACTOR: "branch",
              FM_LEASE_HOLDER_PID: leaseHolderPid,
            },
          };
        },
      });
      customTools = [bashTool as unknown as ToolDefinition, createReportTool(branchGeneration)];
    }
    const created = await createAgentSession({
      cwd: fmRoot,
      sessionManager,
      resourceLoader: loader,
      tools,
      customTools,
      ...modelOptions,
    });
    if ("model" in created.session && !created.session.model) {
      try {
        created.session.dispose();
      } catch {}
      throw new Error("supervision session has no available authenticated model");
    }
    if (!actingAsOwner(branchGeneration)) {
      try {
        created.session.dispose();
      } catch {}
      throw new Error("supervision session was replaced or lost lock ownership");
    }
    if (useAutonomy) {
      unsubscribeBranchUsage?.();
      unsubscribeBranchUsage = created.session.subscribe((event) => {
        if (event.type === "turn_start") {
          autonomyTurnIndex += 1;
          const ceiling = autonomyResolution.config?.supervision.limits.maxIterationsPerBatch ?? 1;
          if (autonomyTurnIndex > ceiling) {
            const rejectDecision = pendingDecisionReject;
            pendingDecisionBatch = null;
            pendingDecisionResolve = null;
            pendingDecisionReject = null;
            rejectDecision?.(new AutonomyError("iteration-ceiling", `supervision batch exceeded maxIterationsPerBatch=${ceiling}`));
            void created.session.abort().catch(() => {});
          }
        }
        if (event.type !== "message_end" || event.message.role !== "assistant" || !autonomy) return;
        const usage = event.message.usage;
        const observation: UsageObservation = {
          provider: event.message.provider,
          model: event.message.model,
          input: usage.input,
          output: usage.output,
          cacheRead: usage.cacheRead,
          cacheWrite: usage.cacheWrite,
          costUsd: usage.cost.total,
        };
        const turnId = stableId("usage", {
          provider: observation.provider,
          model: observation.model,
          timestamp: event.message.timestamp,
          input: observation.input,
          output: observation.output,
        });
        autonomy.recordUsage(observation, turnId);
      });
    }
    try {
      writeFileSync(selectedSessionPointer, `${sessionManager.getSessionFile()}\n`, { mode: 0o600 });
      if (useAutonomy) writeFileSync(autonomySessionBinding, `${expectedSessionBinding}\n`, { mode: 0o600 });
    } catch {
      // Pointer write failure costs only cross-restart session reuse.
    }
    return created.session;
  }

  async function ensureBranch(expectedGeneration: number): Promise<AgentSession> {
    if (!actingAsOwner(expectedGeneration)) throw new Error("supervision session was replaced or lost lock ownership");
    if (branch) return branch;
    if (branchBroken) throw new Error(branchBroken);
    try {
      const created = await createBranch(expectedGeneration);
      if (!actingAsOwner(expectedGeneration)) {
        try {
          created.dispose();
        } catch {}
        throw new Error("supervision session was replaced or lost lock ownership");
      }
      branch = created;
      return created;
    } catch (error) {
      if (expectedGeneration === generation && !shuttingDown) {
        branchBroken = error instanceof Error ? error.message : String(error);
      }
      throw error;
    }
  }

  async function flushMirror(session: AgentSession, expectedGeneration: number): Promise<void> {
    if (!actingAsOwner(expectedGeneration)) throw new Error("supervision session no longer owns the fleet lock");
    while (pendingMirror.length > 0) {
      const item = pendingMirror[0];
      if (!actingAsOwner(expectedGeneration)) throw new Error("supervision session no longer owns the fleet lock");
      if (autonomyMode()) autonomy?.appendMainTranscriptCommit(item.commit);
      await session.sendCustomMessage(
        { customType: "fm-main-mirror", content: `[${item.tag}] ${item.text}`, display: false },
        {},
      );
      if (!actingAsOwner(expectedGeneration)) throw new Error("supervision session was replaced during mirror delivery");
      pendingMirror.shift();
    }
    if (mirrorCollection.pendingCursor) {
      if (!actingAsOwner(expectedGeneration)) throw new Error("supervision session no longer owns the fleet lock");
      writeMirrorCursor(autonomyMode() ? autonomyMirrorCursorFile : mirrorCursorFile, mirrorCollection.pendingCursor);
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
        // whole recheck back to main any more - scopeForUnreadWake already
        // excludes it from eligibleSeqs rather than vetoing the scan, so it
        // stays queued for main while whatever else is eligible right now
        // still reaches the branch. A genuinely empty queue, or a queue that
        // simply has nothing (or nothing further) eligible for the branch
        // right now, is an ordinary quiet no-op - not a fault, so it is
        // never reported back to main. Only a scan scopeForUnreadWake itself
        // marks corrupted (the queue or its metadata could not be read
        // safely, or - for a heartbeat review - a main-owned row anywhere in
        // the unread queue, since a heartbeat needs full-fleet context)
        // still falls back to main.
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
        const reportsBeforePrompt = successfulBranchReports;
        await session.prompt(
          `FIRSTMATE SUPERVISION WAKE: ${message}\n\nHandle this per your operating procedure and finish with fm_branch_report.`,
        );
        if ("model" in session) {
          if (successfulBranchReports === reportsBeforePrompt) {
            throw new Error("supervision model ended without one successful fm_branch_report call");
          }
          const remaining = scopeForUnreadWake(state, heartbeat);
          if (remaining.corrupted || scope.eligibleSeqs.some((seq) => remaining.eligibleSeqs.includes(seq))) {
            throw new Error("supervision model reported without acknowledging every row from its granted wake");
          }
        }
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
    if (pendingAutonomyActivation) {
      void activatePendingAutonomy().catch(() => {});
      return; // main keeps this wake; a later offer may use the activated mode
    }
    offer.accept();
    if (autonomyMode()) enqueueAutonomyWake(offer.message, generation);
    else enqueueWake(offer.message, generation);
  });

  pi.on?.("model_select", async (event, ctx) => {
    if (!autonomyResolution.configured || shuttingDown) return;
    pendingDecisionReject?.(new AutonomyError("session-reconfigured", "main Pi model changed during supervision"));
    pendingDecisionBatch = null;
    pendingDecisionResolve = null;
    pendingDecisionReject = null;
    unsubscribeBranchUsage?.();
    unsubscribeBranchUsage = null;
    if (branch) {
      try {
        branch.dispose();
      } catch {}
      branch = null;
    }
    branchBroken = "";
    const configuringAutonomy = configureAutonomy(generation, event.model);
    if (configuringAutonomy) await configuringAutonomy;
    if (autonomyResolution.configured && !autonomyResolution.active && !autonomyResolution.killed) {
      ctx.ui.notify(`Pi autonomy is inert after the main model change: ${autonomyResolution.diagnostics.join("; ")}`, "warning");
    }
  });

  pi.on?.("agent_start", () => {
    mainStreaming = true;
  });
  pi.on?.("agent_end", () => {
    mainStreaming = false;
  });
  pi.on?.("agent_settled", (_event, ctx) => {
    mainStreaming = false;
    void (async () => {
      const hadPendingActivation = Boolean(pendingAutonomyActivation);
      if (hadPendingActivation) await activatePendingAutonomy();
      if (hadPendingActivation && autonomyResolution.configured && !autonomyResolution.active && !autonomyResolution.killed) {
        ctx.ui.notify(`Pi autonomy is inert: ${autonomyResolution.diagnostics.join("; ")}`, "warning");
      }
      if (autonomy && !hadPendingActivation) await runAutonomyTick(generation, true);
    })().catch(() => {});
  });

  pi.on?.("message_end", (event) => {
    if (!autonomy || event.message.role !== "custom") return;
    const message = event.message as unknown as { customType?: string; details?: { decisionId?: unknown } };
    if (message.customType === "fm-autonomy-decision" && typeof message.details?.decisionId === "string") {
      try {
        autonomy.acknowledgeDeliveredDecision(message.details.decisionId, "Pi finalized the custom message in the main session");
      } catch {}
    }
  });

  // Mirror at main's turn_end: collect the new captain/assistant dialog into
  // the volatile queue, then deliver it through the serialized chain so it
  // lands before any later wake. The durable cursor advances only in
  // flushMirror after the complete pending batch reaches the branch.
  pi.on?.("turn_end", (_event, ctx) => {
    if (!actingAsOwner()) return;
    if (pendingAutonomyActivation || activatingAutonomy) return;
    try {
      const mirrored = collectMainDialog(
        ctx.sessionManager,
        mirrorCollection,
        autonomyMode() ? autonomyMirrorCursorFile : mirrorCursorFile,
      );
      pendingMirror.push(...mirrored.map((item) => {
        const text = redactRuntimeCredential(item.text);
        return { ...item, text, commit: { ...item.commit, text } };
      }));
    } catch {
      return;
    }
    enqueueMirrorFlush();
    if (autonomy) {
      for (const decision of autonomy.journal.pendingDeliveryDecisions()) {
        if (!mainHasDecision(decision.id)) continue;
        try {
          autonomy.acknowledgeDeliveredDecision(decision.id, "main-session turn-end reconciliation found the persisted decision message");
        } catch {}
      }
    }
  });

  // Pi emits session_shutdown for ordinary same-process replacements (/new,
  // /resume, /fork, reload) as well as terminal quit, exactly as the watcher
  // extension documents. Shutdown quiesces this generation, clears the
  // volatile mirror state so the replacement reconstructs from the durable
  // cursor, and releases the branch session; a replacement session_start
  // re-arms, and the next wake reopens the persistent branch from its
  // recorded pointer. Terminal quit simply never fires another session_start.
  pi.on?.("session_start", async (_event, ctx) => {
    shuttingDown = false;
    branchBroken = "";
    generation += 1;
    if (ctx?.sessionManager) mainSessionManager = ctx.sessionManager as unknown as ReadonlyEntries;
    const configuringAutonomy = configureAutonomy(generation, ctx?.model);
    if (configuringAutonomy) await configuringAutonomy;
    actingAsOwner(generation);
    if (autonomyResolution.configured && !autonomyResolution.active && !autonomyResolution.killed && ctx?.ui) {
      ctx.ui.notify(`Pi autonomy is inert: ${autonomyResolution.diagnostics.join("; ")}`, "warning");
    }
  });

  pi.on?.("session_shutdown", () => {
    deactivateEligibleRowsOwner(state, wakeGrantScript, process.pid, String(generation));
    shuttingDown = true;
    if (autonomyTimer) clearInterval(autonomyTimer);
    autonomyTimer = null;
    unsubscribeBranchUsage?.();
    unsubscribeBranchUsage = null;
    pendingDecisionReject?.(new AutonomyError("session-replaced", "main Pi session was replaced"));
    pendingDecisionBatch = null;
    pendingDecisionResolve = null;
    pendingDecisionReject = null;
    autonomy = null;
    mainSessionManager = null;
    pendingAutonomyActivation = null;
    autonomyConfigurationGeneration += 1;
    generation += 1;
    pendingMirror.length = 0;
    mirrorCollection.collectAnchor = null;
    mirrorCollection.pendingCursor = null;
    if (branch) {
      try {
        branch.dispose();
      } catch {
        // Already gone.
      }
      branch = null;
    }
    if (!activatingAutonomy) restoreRetainedLinearCredentials();
  });

  const autonomyToolParameters = Type.Object({
    action: StringEnum(["doctor", "status", "intake", "reconcile", "dispatch", "progress", "link_pr", "land"] as const),
    decisionId: Type.Optional(Type.String({ maxLength: 256 })),
    issueId: Type.Optional(Type.String({ maxLength: 256 })),
    summary: Type.Optional(Type.String({ maxLength: 2000 })),
    prUrl: Type.Optional(Type.String({ maxLength: 1000 })),
    harness: Type.Optional(StringEnum(["claude", "codex", "opencode", "pi", "pi-signed", "grok", "kimi", "cursor", "muse"] as const)),
    model: Type.Optional(Type.String({ maxLength: 200 })),
    effort: Type.Optional(StringEnum(["low", "medium", "high", "xhigh", "max"] as const)),
    backend: Type.Optional(StringEnum(["tmux", "herdr", "zellij", "orca", "cmux"] as const)),
  }, { additionalProperties: false });

  function inactiveAutonomyStatus(): Record<string, unknown> {
    return {
      schema: AUTONOMY_SCHEMA,
      configured: autonomyResolution.configured,
      active: false,
      killed: existsSync(autonomyKillSwitch),
      diagnostics: [
        ...autonomyResolution.diagnostics,
        ...(pendingAutonomyActivation ? ["activation is waiting for this Pi session to own the Firstmate home"] : []),
      ],
      contractFingerprint: decisionContractFingerprint(),
    };
  }

  pi.registerTool?.({
    name: "fm_autonomy",
    label: "Operate allowlisted Linear autonomy",
    description: "Inspect or advance the opt-in Pi Linear autonomy loop through its durable, guarded interface. This main-session tool enforces the local allowlist, issue claim, conflict, capacity, delivery, green-current-head landing, and close-after-landing contracts. It is inert without valid local configuration and a runtime credential.",
    promptSnippet: "Inspect or advance explicitly allowlisted Linear work through Firstmate's existing guarded lifecycle.",
    promptGuidelines: [
      "Load the linear-autonomy skill before calling fm_autonomy for an autonomy decision or Linear-linked task.",
      "Use fm_autonomy action dispatch only after resolving the worker profile under Firstmate's normal dispatch policy.",
      "Use fm_autonomy action land only for a current-head passing PR; the tool refuses every unproven or red result and closes Linear only after landing is confirmed.",
    ],
    parameters: autonomyToolParameters,
    async execute(_toolCallId, params) {
      const input = params as {
        action: "doctor" | "status" | "intake" | "reconcile" | "dispatch" | "progress" | "link_pr" | "land";
        decisionId?: string;
        issueId?: string;
        summary?: string;
        prUrl?: string;
        harness?: DispatchProfile["harness"];
        model?: string;
        effort?: DispatchProfile["effort"];
        backend?: DispatchProfile["backend"];
      };
      try {
        if (input.action === "doctor" || input.action === "status") {
          const status = autonomy ? autonomy.reportStatus() : inactiveAutonomyStatus();
          return { content: [{ type: "text", text: JSON.stringify(status) }], details: status };
        }
        if (!autonomy) throw new AutonomyError("autonomy-inactive", autonomyResolution.diagnostics.join("; ") || (pendingAutonomyActivation ? "activation is waiting for this Pi session to own the Firstmate home" : "Pi autonomy is inactive"));
        if (!actingAsOwner(generation)) throw new AutonomyError("session-read-only", "this Pi session does not own the Firstmate home and cannot advance autonomy");
        if (input.action === "intake") {
          await runAutonomyTick(generation, true);
          const status = autonomy.reportStatus();
          return { content: [{ type: "text", text: JSON.stringify(status) }], details: status };
        }
        if (input.action === "reconcile") {
          const result = await autonomy.reconcile();
          return { content: [{ type: "text", text: JSON.stringify(result) }], details: result };
        }
        if (!input.issueId) throw new AutonomyError("issue-required", `${input.action} requires issueId`);
        if (input.action === "dispatch") {
          if (!input.decisionId || !input.harness) throw new AutonomyError("dispatch-required", "dispatch requires decisionId, issueId, and an explicitly resolved harness");
          const result = await autonomy.dispatchIssue(input.decisionId, input.issueId, {
            harness: input.harness,
            model: input.model,
            effort: input.effort,
            backend: input.backend,
          });
          return { content: [{ type: "text", text: JSON.stringify(result) }], details: result };
        }
        if (input.action === "progress") {
          if (!input.summary) throw new AutonomyError("summary-required", "progress requires a non-empty summary");
          await autonomy.updateProgress(input.issueId, input.summary);
          return { content: [{ type: "text", text: "Linear progress updated for the owned issue claim." }], details: { issueId: input.issueId } };
        }
        if (!input.prUrl) throw new AutonomyError("pr-required", `${input.action} requires a canonical prUrl`);
        if (input.action === "link_pr") {
          await autonomy.linkPullRequest(input.issueId, input.prUrl);
          return { content: [{ type: "text", text: `Linked ${input.prUrl} to the owned Linear issue.` }], details: { issueId: input.issueId, prUrl: input.prUrl } };
        }
        if (input.action !== "land") throw new AutonomyError("action-invalid", `unsupported autonomy action ${String(input.action)}`);
        const result = await autonomy.landAndComplete(input.issueId, input.prUrl);
        return { content: [{ type: "text", text: JSON.stringify(result) }], details: result };
      } catch (error) {
        const code = error instanceof AutonomyError ? error.code : "autonomy-error";
        const message = error instanceof Error ? error.message : String(error);
        return {
          content: [{ type: "text", text: `${code}: ${message}` }],
          details: { code },
          isError: true,
        };
      }
    },
  } as ToolDefinition);

  pi.registerCommand?.("fm-autonomy", {
    description: "Doctor, inspect, reconcile, or stop/resume new claims for opt-in Pi Linear autonomy.",
    handler: async (args, ctx) => {
      const action = args.trim() || "status";
      if (action === "kill-on" || action === "kill-off") {
        if (!actingAsOwner(generation)) {
          ctx.ui.notify("Pi autonomy kill switch cannot change because this Pi session does not own the Firstmate home.", "warning");
          return;
        }
        if (!autonomyResolution.configured) {
          ctx.ui.notify("Pi autonomy is inert: config/pi-autonomy.json is absent", "warning");
          return;
        }
        setAutonomyKillSwitch(autonomyKillSwitch, action === "kill-on");
        if (branch) {
          try {
            branch.dispose();
          } catch {}
          branch = null;
        }
        branchBroken = "";
        const configuringAutonomy = configureAutonomy(generation, ctx.model);
        if (configuringAutonomy) await configuringAutonomy;
        ctx.ui.notify(
          action === "kill-on"
            ? "Pi autonomy kill switch enabled: no new intake or claims; existing work remains durable and reconcilable."
            : "Pi autonomy kill switch removed; valid local configuration may resume new intake and claims.",
          "info",
        );
        return;
      }
      if ((action === "intake" || action === "reconcile") && !actingAsOwner(generation)) {
        ctx.ui.notify("Pi autonomy cannot advance because this Pi session does not own the Firstmate home.", "warning");
        return;
      }
      if (action === "intake" && autonomy) await runAutonomyTick(generation, true);
      else if (action === "reconcile" && autonomy) await autonomy.reconcile();
      else if (action !== "status" && action !== "doctor") {
        ctx.ui.notify("Usage: /fm-autonomy [doctor|status|intake|reconcile|kill-on|kill-off]", "warning");
        return;
      }
      const status = autonomy ? autonomy.reportStatus() : inactiveAutonomyStatus();
      ctx.ui.notify(JSON.stringify(status), status.active ? "info" : "warning");
    },
  });

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
