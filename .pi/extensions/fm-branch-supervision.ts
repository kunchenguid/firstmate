// Firstmate supervision branch for Pi (docs/pi-supervision-branch.md).
//
// A persistent second AgentSession - the supervision BRANCH - inside the same
// pi process as the captain's MAIN session. The watcher extension offers each
// actionable wake here (lib/fm-branch-dispatch.ts); the branch handles it with
// real tools and reports through the fm_branch_report custom tool, which
// writes the durable outcome store FIRST (bin/fm-branch-outcome.sh) and then
// merges an append-only note to main's tail. Main's captain/assistant dialog
// is mirrored into the branch as read-only fm-main-mirror context at main's
// turn_end. Pi-only by construction: this file lives in .pi/extensions, so no
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
// Threat model (captain-decided): the branch's actor identity is
// CONFUSED-AGENT-GRADE - deterministic spawnHook env injection plus a
// readonly-variable shell prelude so an accidental override fails loudly
// inside the branch's own shell. bin/fm-lease-lib.sh documents the grade and
// its deliberate limits.
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
  SessionManager,
  type AgentSession,
  type ExtensionAPI,
  type ToolDefinition,
} from "@earendil-works/pi-coding-agent";
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

// Same tool set in the same order on every request (part of the cached
// prefix). "bash" resolves to the customTools override below, which injects
// the branch actor identity deterministically into every shell command.
const BRANCH_TOOL_NAMES = ["read", "bash", "fm_branch_report"] as const;

// One shared prompt_cache_key per home for ALL branch sessions, derived only
// from the home path so it survives restarts; main keeps its own session key.
const branchCacheKey = `fm-branch-${createHash("sha256").update(fmHome).digest("hex").slice(0, 24)}`;

const MIRROR_MESSAGE_CAP = 4000;
const MERGE_NOTE_BOAT = "⛵";
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
};

function collectMainDialog(sessionManager: ReadonlyEntries, collection: MirrorCollectionState): MirrorItem[] {
  const file = sessionManager.getSessionFile() ?? "";
  const entries = sessionManager.getEntries();
  const anchor = collection.collectAnchor ?? readMirrorCursor();
  const start = anchor.file === file ? Math.min(anchor.index, entries.length) : 0;
  const items: MirrorItem[] = [];
  for (const entry of entries.slice(start)) {
    if (entry.type !== "message") continue;
    const message = (entry as { message?: { role?: string; content?: unknown } }).message;
    if (!message) continue;
    if (message.role !== "user" && message.role !== "assistant") continue;
    const text = textOfContent(message.content).trim();
    if (!text) continue;
    if (message.role === "user" && isOperationalUserText(text)) continue;
    items.push({ tag: message.role === "user" ? "captain" : "main", text: capMirrorText(text) });
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
  const mirrorCollection: MirrorCollectionState = { collectAnchor: null, pendingCursor: null };

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
        return {
          content: [{ type: "text", text: `recorded seq ${appended.stdout} and merged [${verdict}] into main` }],
          details: undefined,
        };
      },
    };
  }

  async function createBranch(branchGeneration: number): Promise<AgentSession> {
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
    offer.accept();
    enqueueWake(offer.message, generation);
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

  // Mirror at main's turn_end: collect the new captain/assistant dialog into
  // the volatile queue, then deliver it through the serialized chain so it
  // lands before any later wake. The durable cursor advances only in
  // flushMirror after the complete pending batch reaches the branch.
  pi.on?.("turn_end", (_event, ctx) => {
    if (!actingAsOwner()) return;
    try {
      pendingMirror.push(...collectMainDialog(ctx.sessionManager, mirrorCollection));
    } catch {
      return;
    }
    enqueueMirrorFlush();
  });

  // Pi emits session_shutdown for ordinary same-process replacements (/new,
  // /resume, /fork, reload) as well as terminal quit, exactly as the watcher
  // extension documents. Shutdown quiesces this generation, clears the
  // volatile mirror state so the replacement reconstructs from the durable
  // cursor, and releases the branch session; a replacement session_start
  // re-arms, and the next wake reopens the persistent branch from its
  // recorded pointer. Terminal quit simply never fires another session_start.
  pi.on?.("session_start", () => {
    shuttingDown = false;
    branchBroken = "";
    generation += 1;
    actingAsOwner(generation);
  });

  pi.on?.("session_shutdown", () => {
    deactivateEligibleRowsOwner(state, wakeGrantScript, process.pid, String(generation));
    shuttingDown = true;
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
