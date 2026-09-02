import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext, SessionEntry, SessionMessageEntry } from "@earendil-works/pi-coding-agent";
import {
  classifyFirstmateCurrentOperationalText,
  encodeFirstmateOperationalInput,
} from "./lib/fm-operational-input.ts";

let guardFollowupActive = false;

// Turn-settle input and reply recovery (docs/watcher-continuity.md
// "Turn-settle input and reply recovery" is the authoritative contract). Pi's own AgentSession.prompt()
// has no atomic check-and-set between reading isStreaming and committing to
// a new run (agent-session.js), so two prompt() calls that both observe
// "idle" - a captain message and a watcher wake delivered through
// pi.sendUserMessage - can both fall through to a concurrent run against the
// same session. That race is a Pi SDK gap firstmate cannot close from
// extension code without a full submission-serializing mutex of its own
// (rejected as disproportionate risk for a rare race). Detecting and
// recovering from its visible symptom - a turn that settles without ever
// producing a synthesized reply to the last conversational message - closes
// the actual acceptance criteria (no lost captain input, no silent hang)
// without needing to prevent the race itself.
let orphanedReplyFollowupActive = false;
let orphanedReplyAttempts = 0;
const ORPHANED_REPLY_ATTEMPT_LIMIT = 3;
let orphanedReplyExhaustedNotified = false;

// Roles that actually carry a reply expectation. Every other message role Pi
// can append (bashExecution for an inline `!cmd`, extension-injected custom
// messages, branch and compaction summaries) is bookkeeping and must not be
// mistaken for an unanswered turn.
const CONVERSATIONAL_MESSAGE_ROLES = new Set(["user", "assistant", "toolResult"]);

// Logical agent runs currently in flight. Pi emits `before_agent_start` only
// on prompt()'s not-streaming branch, never when a message is queued into an
// already-active run through steer or followUp, so this counts independent
// runs and not ordinary mid-turn continuations. It matters because the losing
// side of the reproduced race still reaches _runAgentPrompt, has its inner
// agent.prompt() reject at once with "Agent is already processing a prompt.",
// and its finally block emits `agent_settled` while the winning turn is still
// streaming. That settle is not terminal, and `_isAgentRunActive`/`isIdle()`
// cannot be used to recognise it because the race corrupts that same flag.
// A settle that still leaves a run in flight is therefore left unevaluated;
// the eventual settle that drains the counter is judged normally.
let inFlightAgentRuns = 0;

// Pi's extension runner awaits handlers only within a single emit, so two
// settles can be inside this handler at once across its awaited guard child
// process. One judgement runs at a time, which keeps the latch snapshot and
// the attempt budget from being read and written by two overlapping
// judgements of the same state. Both latches are still consumed ahead of the
// claim, so a settle the claim drops can never leave one behind to swallow a
// later, genuinely unanswered episode.
let settleEvaluationActive = false;

// Captain-owned input recorded from prompt()'s `input` event, which fires
// before the isStreaming check and therefore also for the prompt() call that
// goes on to lose the race. That loser never appends anything: pi-agent-core's
// Agent.prototype.prompt throws "Agent is already processing a prompt." ahead
// of normalizePromptInput, so the captain's message is gone from the
// transcript entirely and no tail inspection can see it.
// Tracking is deliberately narrow. Only genuine captain sources are recorded
// (never "extension", which is how watcher wakes and this file's own
// follow-ups submit), and text that Pi expands after the event - a leading "/"
// for a skill command, prompt template or extension command - is skipped,
// because the appended message would then no longer contain the recorded text
// and an ordinary command would look lost. Inline "!" bash is skipped for the
// same reason. Plain captain prose, which is what the reported episodes lost,
// is appended verbatim and matches exactly.
// A defined streamingBehavior is skipped too. Pi sets it only when the message
// is queued into an already-active run, which is its own correct path and not
// what the idle-vs-idle race loses - and a queued message is appended only
// when the run consumes it, so Escape (which clears the queue back into the
// editor) legitimately leaves it absent. Resubmitting that would replay an
// instruction the captain withdrew.
// A recording is only judged once its own prompt() call reached
// `before_agent_start`, which is the boundary that separates a call that
// committed to a run from one that died earlier: prompt() still throws for an
// unselected model or failed auth well before that hook, appending nothing
// while the captain sees an error and simply resends. Judging such a phantom
// would replay an instruction that already ran under the resend. The hook's
// own event carries the prompt it is starting, and expansion is a no-op for a
// tracked recording, so a recording is committed only by a start that quotes
// it back verbatim - an unrelated run's start leaves it alone. A new
// recording drops any uncommitted predecessor, and a recording still
// uncommitted when a settle arrives is dropped unjudged, because a call that
// was going to commit reaches the hook well before any settle.
// A recording is also superseded the moment the captain submits the same text
// again. Losing the race is not silent for the captain: the loser's rejection
// escapes prompt() into the interactive loop, which prints it as a chat error,
// so the captain may simply resend. Recovering the earlier recording as well
// would execute one instruction twice, and the resend carries it anyway.
// Equivalence here is exact text, the only signal the events carry - a
// reworded resend is not recognised as the same instruction.
// That supersession only reaches a resend the captain submits before a settle
// picked the recording up. The chat error is theirs to react to at any moment,
// so the resend can just as well arrive after recovery already went out, while
// the recovered copy is still being carried out - and the recording it would
// have superseded is gone by then. Recovery therefore keeps the text it just
// resubmitted, and a captain submission of exactly that text is not delivered
// to the model a second time at all: it is answered to the captain directly
// instead. Delivering it - even behind a note asking for a single execution -
// would put a second executable copy of that instruction in front of the
// model, and prose cannot enforce idempotence, so a destructive instruction
// could run twice. The instruction is not lost by that: the identical text is
// already in the conversation verbatim and is being carried out, which is
// exactly what the captain resent it to make happen.
// Suppressing it silently would be the lost input this whole mechanism exists
// to prevent, so the captain is told in the chat why the resend was not
// needed, through the one channel the model never reads.
// The window closes on the settle that ends the recovery turn: once an answer
// to the recovered instruction exists, an identical submission after it is a
// deliberate repeat and must reach the model untouched.
const DUPLICATE_RECOVERED_INPUT_NOTICE =
  "Resend not sent again: this exact instruction was lost by Pi at turn start, automatic recovery already delivered it, and it is " +
  "being carried out right now. Sending it a second time could execute it twice, so it was answered here instead. Wait for the " +
  "running answer, or reword the instruction to submit it as a new one.";
let recoveredCaptainInputText: string | null = null;

// Captain-facing only: ctx.ui.notify appends a line to the chat scrollback and
// never enters the model's context. Best effort - a headless or RPC context
// may carry no UI at all, and the suppression is the safety property, not the
// notice.
function notifyDuplicateOfRecoveredInput(ctx: unknown): void {
  const notify = (ctx as { ui?: { notify?: unknown } } | undefined)?.ui?.notify;
  if (typeof notify !== "function") return;
  try {
    notify.call((ctx as { ui: unknown }).ui, DUPLICATE_RECOVERED_INPUT_NOTICE, "warning");
  } catch {
  }
}

type UserMessageContent = Parameters<ExtensionAPI["sendUserMessage"]>[0];
type UserMessagePart = Exclude<UserMessageContent, string>[number];
type PendingCaptainInput = {
  text: string;
  images: UserMessagePart[];
  afterEntryId: string | null;
  committed: boolean;
};
const CAPTAIN_INPUT_SOURCES = new Set(["interactive", "rpc"]);
const PENDING_CAPTAIN_INPUT_LIMIT = 20;
let pendingCaptainInputs: PendingCaptainInput[] = [];

type LockOwnership = "owned" | "missing" | "other";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const marker = `${state}/.pi-turnend-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;

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
  if (!existsSync(state) || lockOwnership() === "other") return;
  writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
}

// Pi's session_start reasons are startup | reload | new | resume | fork, and a
// separate session_compact event fires after a compaction. "new" is Pi's /new
// while reload, resume, and fork all keep prior context.
const sessionstartDeliveryBytes = 512 * 1024;

type SessionStartContext = {
  sessionManager?: {
    getHeader?: () => { timestamp?: unknown } | null | undefined;
    getSessionId?: () => unknown;
  };
};

function restoredSessionEvidence(ctx: SessionStartContext): boolean {
  try {
    const timestamp = ctx.sessionManager?.getHeader?.()?.timestamp;
    const createdAt = typeof timestamp === "string" ? Date.parse(timestamp) : Number.NaN;
    return Number.isFinite(createdAt) && createdAt < performance.timeOrigin;
  } catch {
    return false;
  }
}

function startupRebuildSource(ctx: SessionStartContext): "resume" | "fork" | undefined {
  const args = process.argv.slice(2);
  const restored = restoredSessionEvidence(ctx);
  for (const arg of args) {
    if (arg === "--fork" || arg.startsWith("--fork=")) return "fork";
    if (
      restored && (
        arg === "-c" || arg === "--continue" ||
        arg === "-r" || arg === "--resume" ||
        arg === "--session" || arg.startsWith("--session=") ||
        arg === "--session-id" || arg.startsWith("--session-id=")
      )
    ) return "resume";
  }
  return undefined;
}
const sessionstartTruncatedMarker =
  "\n\nPI SESSION-START DELIVERY TRUNCATED - the digest exceeded 512 KiB. " +
  "Treat omitted context as unread and inspect the named files directly before acting on it.";
const sessionstartManualFallback =
  "Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.";
const sessionstartIneligibleExit = 3;
const sessionstartRetireTimeoutMs = 1000;

// One active generation owns native startup from child launch through context
// claim. Replacement activates first, serially retires every predecessor, and
// lets only the matching session id claim one persistent provider prerequisite.
type SessionstartSource = "startup" | "clear" | "resume" | "fork" | "compact";
type SessionstartResult =
  | { kind: "ready"; raw: string }
  | { kind: "empty" | "failed" | "ineligible" | "cancelled" };
type SessionstartMessage = {
  customType: "firstmate-sessionstart-nudge";
  content: string;
  display: false;
  details: { kind: "session-start" };
};
type SessionstartGeneration = {
  id: number;
  sessionId: string;
  source: SessionstartSource;
  stopping: boolean;
  delivered: boolean;
  child: ChildProcess | null;
  processGroupId: number | null;
  childClosed: boolean;
  childClose: Promise<void> | null;
  stopPromise: Promise<void> | null;
  result: Promise<SessionstartResult>;
};

let nextSessionstartGenerationId = 0;
let activeSessionstartGeneration: SessionstartGeneration | null = null;

function sessionIdFromContext(ctx: SessionStartContext): string {
  try {
    return String(ctx.sessionManager?.getSessionId?.() ?? "");
  } catch {
    return "";
  }
}

function sessionstartGenerationIsLive(generation: SessionstartGeneration): boolean {
  return activeSessionstartGeneration === generation && !generation.stopping;
}

function signalSessionstartChild(child: ChildProcess, signal: NodeJS.Signals): void {
  const pid = child.pid;
  if (!pid) return;
  if (process.platform === "win32") {
    const args = ["/pid", String(pid), "/t"];
    if (signal === "SIGKILL") args.push("/f");
    spawnSync("taskkill", args, { stdio: "ignore" });
    return;
  }
  try {
    process.kill(-pid, signal);
  } catch {
    try {
      child.kill(signal);
    } catch {
    }
  }
}

function sessionstartProcessGroupAlive(processGroupId: number): boolean {
  try {
    process.kill(-processGroupId, 0);
    return true;
  } catch {
    return false;
  }
}

function waitForSessionstartProcessGroupExit(
  processGroupId: number,
  timeoutMs: number,
): Promise<void> {
  return new Promise((resolveWait) => {
    const startedAt = Date.now();
    const poll = (): void => {
      if (!sessionstartProcessGroupAlive(processGroupId) || Date.now() - startedAt >= timeoutMs) {
        resolveWait();
        return;
      }
      setTimeout(poll, 10);
    };
    poll();
  });
}

function waitForSessionstartClose(generation: SessionstartGeneration, timeoutMs: number): Promise<void> {
  if (generation.childClosed || !generation.childClose) return Promise.resolve();
  return new Promise((resolveWait) => {
    const timer = setTimeout(resolveWait, timeoutMs);
    void generation.childClose?.then(() => {
      clearTimeout(timer);
      resolveWait();
    });
  });
}

function stopSessionstartGeneration(generation: SessionstartGeneration): Promise<void> {
  if (generation.stopPromise) return generation.stopPromise;
  generation.stopping = true;
  generation.stopPromise = (async () => {
    const child = generation.child;
    if (process.platform === "win32") {
      if (!child || generation.childClosed) {
        await generation.result;
        return;
      }
      signalSessionstartChild(child, "SIGTERM");
      await waitForSessionstartClose(generation, sessionstartRetireTimeoutMs);
      if (!generation.childClosed) {
        signalSessionstartChild(child, "SIGKILL");
        await waitForSessionstartClose(generation, sessionstartRetireTimeoutMs);
      }
      return;
    }
    const processGroupId = generation.processGroupId;
    if (!child || !processGroupId) {
      await generation.result;
      return;
    }
    try {
      process.kill(-processGroupId, "SIGTERM");
    } catch {
    }
    await waitForSessionstartProcessGroupExit(processGroupId, sessionstartRetireTimeoutMs);
    if (sessionstartProcessGroupAlive(processGroupId)) {
      try {
        process.kill(-processGroupId, "SIGKILL");
      } catch {
      }
      await waitForSessionstartProcessGroupExit(processGroupId, sessionstartRetireTimeoutMs);
    }
  })();
  return generation.stopPromise;
}

function runSessionstartHook(generation: SessionstartGeneration): Promise<SessionstartResult> {
  return new Promise((resolveResult) => {
    let settled = false;
    let closeChild: () => void = () => {};
    const settle = (result: SessionstartResult): void => {
      if (settled) return;
      settled = true;
      resolveResult(result);
    };
    const supervised = process.platform !== "win32";
    const runner = `${root}/bin/fm-sessionstart-run.sh`;
    let child: ChildProcess;
    try {
      child = spawn(
        supervised ? "node" : runner,
        supervised
          ? [
              `${extensionDir}/lib/fm-sessionstart-supervisor.mjs`,
              runner,
              "--source",
              generation.source,
              "--pi-prerequisite",
            ]
          : ["--source", generation.source, "--pi-prerequisite"],
        {
          detached: supervised,
          stdio: supervised
            ? ["ignore", "pipe", "ignore", "ipc"]
            : ["ignore", "pipe", "ignore"],
        },
      );
    } catch {
      settle(generation.stopping ? { kind: "cancelled" } : { kind: "failed" });
      return;
    }
    generation.child = child;
    generation.processGroupId = child.pid ?? null;
    generation.childClose = new Promise<void>((resolveClose) => {
      closeChild = resolveClose;
    });
    const chunks: Buffer[] = [];
    let observedBytes = 0;
    let retainedBytes = 0;
    let truncated = false;
    let pendingCompletion: { code: number | null; bytes: number } | null = null;
    const unrefSupervisor = (): void => {
      if (!supervised) return;
      child.unref();
      child.channel?.unref?.();
      const stdout = child.stdout as (NodeJS.ReadableStream & { unref?: () => void }) | null;
      stdout?.unref?.();
    };
    const markClosed = (): void => {
      if (generation.childClosed) return;
      generation.childClosed = true;
      if (generation.child === child) generation.child = null;
      generation.processGroupId = null;
      closeChild();
    };
    const complete = (code: number | null): void => {
      unrefSupervisor();
      if (generation.stopping) {
        settle({ kind: "cancelled" });
        return;
      }
      if (code === sessionstartIneligibleExit) {
        settle({ kind: "ineligible" });
        return;
      }
      if (code !== 0) {
        settle({ kind: "failed" });
        return;
      }
      const raw = Buffer.concat(chunks).toString("utf8").trim();
      if (!raw) {
        settle({ kind: "empty" });
        return;
      }
      settle({
        kind: "ready",
        raw: truncated ? `${raw}${sessionstartTruncatedMarker}` : raw,
      });
    };
    const completePending = (): void => {
      if (!pendingCompletion || observedBytes < pendingCompletion.bytes) return;
      complete(pendingCompletion.code);
      pendingCompletion = null;
    };
    child.stdout?.on("data", (chunk: Buffer) => {
      observedBytes += chunk.length;
      if (retainedBytes >= sessionstartDeliveryBytes) {
        truncated = true;
        completePending();
        return;
      }
      const remaining = sessionstartDeliveryBytes - retainedBytes;
      const retained = chunk.length <= remaining ? chunk : chunk.subarray(0, remaining);
      chunks.push(retained);
      retainedBytes += retained.length;
      if (retained.length !== chunk.length) truncated = true;
      completePending();
    });
    if (supervised) {
      child.on("message", (message: unknown) => {
        const result = message as { type?: unknown; code?: unknown; bytes?: unknown };
        if (result.type !== "result" ||
            (typeof result.code !== "number" && result.code !== null) ||
            typeof result.bytes !== "number") return;
        pendingCompletion = { code: result.code, bytes: result.bytes };
        completePending();
      });
    }
    child.on("error", () => {
      markClosed();
      settle(generation.stopping ? { kind: "cancelled" } : { kind: "failed" });
    });
    child.on("close", (code) => {
      markClosed();
      if (supervised) {
        settle(generation.stopping ? { kind: "cancelled" } : { kind: "failed" });
        return;
      }
      complete(code);
    });
  });
}

function createSessionstartGeneration(
  source: SessionstartSource,
  sessionId: string,
): SessionstartGeneration {
  const previous = activeSessionstartGeneration;
  const generation: SessionstartGeneration = {
    id: ++nextSessionstartGenerationId,
    sessionId,
    source,
    stopping: false,
    delivered: false,
    child: null,
    processGroupId: null,
    childClosed: false,
    childClose: null,
    stopPromise: null,
    result: Promise.resolve({ kind: "cancelled" }),
  };
  activeSessionstartGeneration = generation;
  generation.result = (async (): Promise<SessionstartResult> => {
    if (previous) await stopSessionstartGeneration(previous);
    if (!sessionstartGenerationIsLive(generation)) return { kind: "cancelled" };
    return runSessionstartHook(generation);
  })();
  return generation;
}

function sessionstartMessage(
  generation: SessionstartGeneration,
  result: SessionstartResult,
): SessionstartMessage | undefined {
  let raw = result.kind === "ready" ? result.raw : "";
  if (!raw && result.kind === "failed") {
    raw = sessionstartManualFallback;
  } else if (!raw && ["startup", "clear", "compact"].includes(generation.source) &&
      result.kind === "empty") {
    raw = sessionstartManualFallback;
  }
  if (!raw) return undefined;
  try {
    // The wrapper already returns an encoded nudge on a context-preserving
    // open, so only an unencoded digest or fallback needs the marker added.
    const content = classifyFirstmateCurrentOperationalText(raw)
      ? raw
      : encodeFirstmateOperationalInput("session-start", raw);
    return {
      customType: "firstmate-sessionstart-nudge",
      content,
      display: false,
      details: { kind: "session-start" },
    };
  } catch {
    return undefined;
  }
}

async function claimSessionstartMessage(
  generation: SessionstartGeneration,
  ctx?: SessionStartContext,
): Promise<SessionstartMessage | undefined> {
  const result = await generation.result;
  if (!sessionstartGenerationIsLive(generation) || generation.delivered) return undefined;
  const currentSessionId = ctx ? sessionIdFromContext(ctx) : "";
  if (generation.sessionId && currentSessionId && generation.sessionId !== currentSessionId) {
    return undefined;
  }
  generation.delivered = true;
  return sessionstartMessage(generation, result);
}

function isSessionMessageEntry(entry: SessionEntry): entry is SessionMessageEntry {
  return entry.type === "message";
}

function messagePlainText(message: unknown): string {
  const content = (message as { content?: unknown } | undefined)?.content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  const parts: string[] = [];
  for (const part of content) {
    const candidate = part as { type?: unknown; text?: unknown };
    if (candidate?.type === "text" && typeof candidate.text === "string") parts.push(candidate.text);
  }
  return parts.join("\n");
}

function messageHasVisibleText(message: unknown): boolean {
  return messagePlainText(message).trim().length > 0;
}

function messageHasUnresolvedToolCall(message: unknown): boolean {
  const content = (message as { content?: unknown } | undefined)?.content;
  if (!Array.isArray(content)) return false;
  return content.some((part) => (part as { type?: unknown } | undefined)?.type === "toolCall");
}

function captainInputWorthTracking(
  source: string,
  text: string,
  streamingBehavior: unknown,
): boolean {
  if (!CAPTAIN_INPUT_SOURCES.has(source)) return false;
  if (streamingBehavior !== undefined) return false;
  const trimmed = text.trim();
  if (!trimmed) return false;
  return !trimmed.startsWith("/") && !trimmed.startsWith("!");
}

function sessionEntries(ctx: ExtensionContext): SessionEntry[] | undefined {
  try {
    return ctx.sessionManager.getEntries();
  } catch {
    return undefined;
  }
}

function lastEntryId(ctx: ExtensionContext): string | null {
  const entries = sessionEntries(ctx);
  if (!entries || entries.length === 0) return null;
  return entries[entries.length - 1]?.id ?? null;
}

// Compared exactly, not by containment: a tracked recording never starts with
// "/", so Pi's skill-command and prompt-template expansion both return the
// text unchanged and the appended message carries it verbatim. Containment
// would let a longer later message ("weiter mit dem PR") silently absorb a
// genuinely lost short one ("weiter").
// An unknown anchor (a compaction rewrote it away) scans from the start, so a
// message that is present is still found and never reported lost.
function captainInputReachedTranscript(
  entries: SessionEntry[],
  pending: PendingCaptainInput,
  claimed: Set<string>,
): string | undefined {
  const anchorIndex = pending.afterEntryId === null
    ? -1
    : entries.findIndex((entry) => entry.id === pending.afterEntryId);
  for (let i = anchorIndex + 1; i < entries.length; i += 1) {
    const entry = entries[i];
    if (!isSessionMessageEntry(entry) || claimed.has(entry.id)) continue;
    const role = (entry.message as { role?: unknown } | undefined)?.role;
    if (role !== "user") continue;
    if (messagePlainText(entry.message).trim() !== pending.text.trim()) continue;
    return entry.id;
  }
  return undefined;
}

// Resolves every pending captain input that did reach the transcript and
// returns the first one that did not, already removed from the pending list so
// a later settle can never resubmit it twice.
function takeLostCaptainInput(ctx: ExtensionContext): PendingCaptainInput | undefined {
  if (pendingCaptainInputs.length === 0) return undefined;
  const entries = sessionEntries(ctx);
  if (!entries) return undefined;
  const claimed = new Set<string>();
  const stillPending: PendingCaptainInput[] = [];
  let lost: PendingCaptainInput | undefined;
  for (const pending of pendingCaptainInputs) {
    if (lost || !pending.committed) {
      stillPending.push(pending);
      continue;
    }
    const entryId = captainInputReachedTranscript(entries, pending, claimed);
    if (entryId) {
      claimed.add(entryId);
      continue;
    }
    lost = pending;
  }
  pendingCaptainInputs = stillPending;
  return lost;
}

// Detects the reproduced race's visible signature: the settled turn's last
// conversational message-type entry is not an assistant reply that both
// carries genuine text and leaves no tool call unresolved. That covers a
// dangling tool call with no follow-up reply - including the common shape
// where the same assistant message holds a short text preamble plus the
// unresolved call - and a user or watcher-wake message that never received
// any answer at all.
// Entries that carry no reply expectation of their own are skipped rather
// than counted as unanswered: non-message entries such as the session-start
// digest, and message entries whose role is not conversational (Pi flushes
// its inline `!cmd` bashExecution messages into the session right before
// agent_settled, and extensions can inject custom messages the same way).
// An assistant message with stopReason "aborted" is a deliberate captain
// stop and counts as healthy, so a turn the captain cancelled is never
// auto-restarted; "error" still earns its one recovery nudge, because
// nothing confirms the captain saw it and no human decided to stop there.
function lastConversationalTurnUnanswered(ctx: ExtensionContext): boolean {
  let entries: SessionEntry[];
  try {
    entries = ctx.sessionManager.getEntries();
  } catch {
    return false;
  }
  for (let i = entries.length - 1; i >= 0; i -= 1) {
    const entry = entries[i];
    if (!isSessionMessageEntry(entry)) continue;
    const message = entry.message as { role?: unknown; stopReason?: unknown } | undefined;
    const role = message?.role;
    if (typeof role !== "string" || !CONVERSATIONAL_MESSAGE_ROLES.has(role)) continue;
    if (role !== "assistant") return true;
    if (message?.stopReason === "aborted") return false;
    return !messageHasVisibleText(entry.message) || messageHasUnresolvedToolCall(entry.message);
  }
  return false;
}

function runGuard(): Promise<{ code: number; stderr: string }> {
  return new Promise((resolveResult) => {
    const child = spawn(`${root}/bin/fm-turnend-guard.sh`, {
      stdio: ["pipe", "ignore", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolveResult({ code: 0, stderr: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stderr }));
    child.stdin.end('{"stop_hook_active":false}');
  });
}

// PreToolUse seatbelts (bin/fm-arm-pretool-check.sh, docs/arm-pretool-check.md;
// bin/fm-cd-pretool-check.sh, docs/cd-guard.md). Both piggyback on this same
// extension file rather than separate ones so no extra Pi -e flag is needed at
// launch - the primary already loads this file for the turn-end guard, and
// pi.on("tool_call", ...) can block (verified 2026-07-09 against pi 0.80.5:
// returning {block: true} prevents the bash command from running). Each owner
// script owns its own decision and is inert outside the real primary checkout.
function runChecker(script: string, command: string): Promise<{ code: number; stderr: string }> {
  return new Promise((resolveResult) => {
    const child = spawn(`${root}/bin/${script}`, ["--command", command], {
      stdio: ["ignore", "ignore", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolveResult({ code: 0, stderr: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stderr }));
  });
}

function runPretoolCheck(command: string): Promise<{ code: number; stderr: string }> {
  return runChecker("fm-arm-pretool-check.sh", command);
}

function runCdCheck(command: string): Promise<{ code: number; stderr: string }> {
  return runChecker("fm-cd-pretool-check.sh", command);
}

export default function (pi: ExtensionAPI) {
  let sessionstartGeneration: SessionstartGeneration | null = null;
  let sessionstartExitListenerRegistered = false;
  const cleanupSessionstartOnProcessExit = (): void => {
    const generation = sessionstartGeneration;
    if (!generation) return;
    if (process.platform === "win32") {
      if (generation.child) signalSessionstartChild(generation.child, "SIGKILL");
      return;
    }
    const processGroupId = generation.processGroupId;
    if (!processGroupId) {
      if (generation.child) signalSessionstartChild(generation.child, "SIGKILL");
      return;
    }
    try {
      process.kill(-processGroupId, "SIGKILL");
    } catch {
    }
  };
  const registerSessionstartExitListener = (): void => {
    if (sessionstartExitListenerRegistered) return;
    process.once("exit", cleanupSessionstartOnProcessExit);
    sessionstartExitListenerRegistered = true;
  };
  const removeSessionstartExitListener = (): void => {
    if (!sessionstartExitListenerRegistered) return;
    process.removeListener("exit", cleanupSessionstartOnProcessExit);
    sessionstartExitListenerRegistered = false;
  };
  registerSessionstartExitListener();

  pi.on?.("session_start", (event, ctx) => {
    const reason = String((event as { reason?: unknown }).reason ?? "");
    const source = reason === "startup"
      ? startupRebuildSource(ctx) ?? "startup"
      : { new: "clear", resume: "resume", fork: "fork" }[reason];
    markLoaded();
    inFlightAgentRuns = 0;
    pendingCaptainInputs = [];
    recoveredCaptainInputText = null;
    orphanedReplyAttempts = 0;
    orphanedReplyExhaustedNotified = false;
    if (!source) return;
    registerSessionstartExitListener();
    sessionstartGeneration = createSessionstartGeneration(
      source as SessionstartSource,
      sessionIdFromContext(ctx),
    );
  });

  pi.on?.("before_agent_start", async (event, ctx) => {
    inFlightAgentRuns += 1;
    const startedPrompt = String((event as { prompt?: unknown }).prompt ?? "").trim();
    for (let i = pendingCaptainInputs.length - 1; i >= 0; i -= 1) {
      const pending = pendingCaptainInputs[i];
      if (pending.committed || pending.text.trim() !== startedPrompt) continue;
      pendingCaptainInputs[i] = { ...pending, committed: true };
      break;
    }
    const generation = sessionstartGeneration;
    if (!generation) return;
    const message = await claimSessionstartMessage(generation, ctx);
    return message ? { message } : undefined;
  });

  // Pi's compaction equivalent. Manual compaction is idle and auto-compaction
  // may retry without another before_agent_start, so the event keeps its
  // existing delivery path while sharing generation ownership and cancellation.
  pi.on?.("session_compact", async (_event, ctx) => {
    registerSessionstartExitListener();
    const generation = createSessionstartGeneration("compact", sessionIdFromContext(ctx));
    sessionstartGeneration = generation;
    const message = await claimSessionstartMessage(generation, ctx);
    if (!message || !sessionstartGenerationIsLive(generation)) return;
    try {
      pi.sendMessage(message);
    } catch {
      generation.delivered = false;
    }
  });

  pi.on?.("session_shutdown", async () => {
    const generation = sessionstartGeneration;
    try {
      if (generation) await stopSessionstartGeneration(generation);
    } finally {
      if (sessionstartGeneration === generation) sessionstartGeneration = null;
      removeSessionstartExitListener();
    }
  });

  pi.on("tool_call", async (event) => {
    if (event.type !== "tool_call" || event.toolName !== "bash") return {};
    const command = String((event.input as { command?: unknown })?.command ?? "");
    if (!command) return {};
    const cdResult = await runCdCheck(command);
    if (cdResult.code === 2) {
      return { block: true, reason: cdResult.stderr.trim() || "denied by the cd-guard PreToolUse seatbelt" };
    }
    const result = await runPretoolCheck(command);
    if (result.code !== 2) return {};
    return { block: true, reason: result.stderr.trim() || "denied by the watcher-arm PreToolUse seatbelt" };
  });

  pi.on?.("input", (event, ctx) => {
    const source = String((event as { source?: unknown }).source ?? "");
    const text = String((event as { text?: unknown }).text ?? "");
    const streamingBehavior = (event as { streamingBehavior?: unknown }).streamingBehavior;
    const trimmed = text.trim();
    // Judged for every captain submission, not only a tracked one: the resend
    // that races an in-flight recovery is typically queued into that very
    // turn, which sets streamingBehavior and takes it out of tracking.
    const duplicatesRecovery = CAPTAIN_INPUT_SOURCES.has(source) &&
      recoveredCaptainInputText !== null &&
      trimmed === recoveredCaptainInputText;
    if (duplicatesRecovery) {
      // Never delivered, so never appended either: tracking it would let the
      // settle judge it lost and resubmit the very copy just suppressed.
      notifyDuplicateOfRecoveredInput(ctx);
      return { action: "handled" } as const;
    }
    if (!captainInputWorthTracking(source, text, streamingBehavior)) return undefined;
    const images = (event as { images?: unknown }).images;
    pendingCaptainInputs = pendingCaptainInputs.filter(
      (pending) => pending.committed && pending.text.trim() !== trimmed,
    );
    // Recorded exactly as it will be appended, so the transcript comparison
    // and the before_agent_start commit still match it.
    pendingCaptainInputs.push({
      text,
      images: Array.isArray(images) ? (images as UserMessagePart[]) : [],
      afterEntryId: lastEntryId(ctx),
      committed: false,
    });
    if (pendingCaptainInputs.length > PENDING_CAPTAIN_INPUT_LIMIT) {
      pendingCaptainInputs = pendingCaptainInputs.slice(-PENDING_CAPTAIN_INPUT_LIMIT);
    }
    return undefined;
  });

  pi.on("agent_settled", async (_event, ctx) => {
    inFlightAgentRuns = inFlightAgentRuns > 0 ? inFlightAgentRuns - 1 : 0;
    pendingCaptainInputs = pendingCaptainInputs.filter((pending) => pending.committed);
    if (inFlightAgentRuns > 0) return;

    if (guardFollowupActive) {
      guardFollowupActive = false;
      return;
    }

    // Consumed on every settle before any branching, so the reply latch can
    // never outlive the settle it was meant to absorb - not even when that
    // settle is instead claimed by the supervision guard below and a later,
    // genuinely unanswered episode would otherwise be swallowed by it.
    const replyFollowupSettle = orphanedReplyFollowupActive;
    orphanedReplyFollowupActive = false;

    if (settleEvaluationActive) return;
    settleEvaluationActive = true;
    // The duplicate-resend window belongs to the recovery turn, and this is
    // the settle that ends it: from here on an identical captain submission
    // is a deliberate repeat and is delivered untouched. Unlike the latches
    // above it is closed after the claim rather than before, because it
    // suppresses nothing - a settle dropped here is concurrent with the very
    // evaluation that may still be opening the window, and closing it from
    // there would reopen the double execution it exists to prevent.
    recoveredCaptainInputText = null;
    try {
      await evaluateSettle(ctx, replyFollowupSettle);
    } finally {
      settleEvaluationActive = false;
    }
  });

  async function evaluateSettle(ctx: ExtensionContext, replyFollowupSettle: boolean): Promise<void> {
    const result = await runGuard();
    if (result.code === 2) {
      guardFollowupActive = true;
      try {
        const content = encodeFirstmateOperationalInput(
          "turn-end-guard",
          "TURN WOULD END BLIND - supervision is off. " +
            "The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n" +
            result.stderr,
        );
        await pi.sendUserMessage(content, { deliverAs: "followUp" });
      } catch {
        guardFollowupActive = false;
      }
      return;
    }

    // runGuard() spawns and awaits a child process, and Pi clears its own
    // run flag before emitting this settle, so a fresh prompt can open a new
    // logical run during that await. Judging the transcript afterwards would
    // read that new run's mid-flight tail.
    if (inFlightAgentRuns > 0) return;

    // Only one follow-up ever fires per settle: the supervision guard above
    // takes priority, and the checks below run only once it is clean.
    if (replyFollowupSettle) return;

    const lostCaptainInput = takeLostCaptainInput(ctx);
    if (lostCaptainInput) {
      const content = encodeFirstmateOperationalInput(
        "turn-end-guard",
        "CAPTAIN INPUT WAS LOST - the message quoted below was submitted by the captain and acknowledged in the interface, but it never " +
          "reached the conversation at all, so no answer to it exists yet. This happens when a watcher wake and a captain message start a " +
          "turn at the same moment and Pi drops one of them before it is recorded. Treat the quoted text as the captain's own message, " +
          "arriving now, and answer it directly. Do not repeat any answer you already gave earlier in this conversation.\n\n" +
          lostCaptainInput.text,
      );
      const payload: UserMessageContent = lostCaptainInput.images.length === 0
        ? content
        : [{ type: "text", text: content }, ...lostCaptainInput.images];
      // Opened before the delivery await, because the captain can resend
      // during it, and closed again if the delivery never happened.
      recoveredCaptainInputText = lostCaptainInput.text.trim();
      try {
        await pi.sendUserMessage(payload, { deliverAs: "followUp" });
      } catch (error) {
        recoveredCaptainInputText = null;
        throw error;
      }
      return;
    }

    if (!lastConversationalTurnUnanswered(ctx)) {
      orphanedReplyAttempts = 0;
      orphanedReplyExhaustedNotified = false;
      return;
    }

    if (orphanedReplyAttempts >= ORPHANED_REPLY_ATTEMPT_LIMIT) {
      if (orphanedReplyExhaustedNotified) return;
      orphanedReplyExhaustedNotified = true;
      try {
        const content = encodeFirstmateOperationalInput(
          "turn-end-guard",
          `TURN ENDED WITHOUT A REPLY - automatic recovery gave up after ${ORPHANED_REPLY_ATTEMPT_LIMIT} attempts. ` +
            "The last message in this conversation still has no visible assistant answer. " +
            "Check the transcript directly and answer the pending message by hand; do not repeat this recovery attempt automatically again for it.",
        );
        await pi.sendUserMessage(content, { deliverAs: "followUp" });
      } catch {
        orphanedReplyExhaustedNotified = false;
      }
      return;
    }

    orphanedReplyAttempts += 1;
    orphanedReplyFollowupActive = true;
    try {
      const content = encodeFirstmateOperationalInput(
        "turn-end-guard",
        "TURN ENDED WITHOUT A REPLY - the last message in this conversation (a captain message or a delivered watcher wake) has no visible " +
          "assistant answer, and the turn already settled with nothing queued to continue it. This can happen when a watcher wake landed while " +
          "another prompt was starting, racing Pi's own turn-start handling. Check the conversation history now: if a tool call is unresolved, " +
          "finish it, then answer the pending message directly. Do not repeat any answer you already gave earlier in this conversation.",
      );
      await pi.sendUserMessage(content, { deliverAs: "followUp" });
    } catch {
      orphanedReplyFollowupActive = false;
    }
  }

  markLoaded();
}
