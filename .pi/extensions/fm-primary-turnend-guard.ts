import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  classifyFirstmateCurrentOperationalText,
  encodeFirstmateOperationalInput,
} from "./lib/fm-operational-input.ts";

let guardFollowupActive = false;

type LockOwnership = "owned" | "missing" | "other";
type CompactRefreshState = {
  version: 1;
  raw: string;
  observedBytes: number;
  hardTruncated: boolean;
  reserveTokens: number;
  keepRecentTokens: number;
};
type CompactRefreshBudget = {
  contextWindow: number;
  reserveTokens: number;
  baseTokens: number;
  safetyTokens: number;
  availableTokens: number;
  deliveredTokens: number;
  omitted: boolean;
};

const compactRefreshStateType = "firstmate-post-compact-refresh";
let compactSettings: { reserveTokens: number; keepRecentTokens: number } | undefined;
let compactRefresh: CompactRefreshState | undefined;
let compactRefreshNotice = "";

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
// separate session_compact event fires after a compaction. "new" is Pi's /clear
// while reload, resume, and fork all keep prior context.
const sessionstartDeliveryBytes = 512 * 1024;
const compactRefreshSafetyTokens = 2048;

type SessionStartContext = {
  sessionManager?: {
    getHeader?: () => { timestamp?: unknown } | null | undefined;
    getSessionId?: () => unknown;
    getBranch?: () => unknown[];
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
  | { kind: "ready"; raw: string; observedBytes: number; hardTruncated: boolean }
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
        observedBytes,
        hardTruncated: truncated,
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

async function claimSessionstartResult(
  generation: SessionstartGeneration,
  ctx?: SessionStartContext,
): Promise<SessionstartResult | undefined> {
  const result = await generation.result;
  if (!sessionstartGenerationIsLive(generation) || generation.delivered) return undefined;
  const currentSessionId = ctx ? sessionIdFromContext(ctx) : "";
  if (generation.sessionId && currentSessionId && generation.sessionId !== currentSessionId) {
    return undefined;
  }
  generation.delivered = true;
  return result;
}

async function claimSessionstartMessage(
  generation: SessionstartGeneration,
  ctx?: SessionStartContext,
): Promise<SessionstartMessage | undefined> {
  const result = await claimSessionstartResult(generation, ctx);
  if (!result) return undefined;
  return sessionstartMessage(generation, result);
}

function utf8Bytes(value: string): number {
  return Buffer.byteLength(value, "utf8");
}

function serializedBytes(value: unknown): number {
  try {
    return utf8Bytes(JSON.stringify(value));
  } catch {
    return 0;
  }
}

function sliceUtf8Prefix(value: string, maxBytes: number): string {
  if (maxBytes <= 0) return "";
  if (utf8Bytes(value) <= maxBytes) return value;
  let bytes = 0;
  let end = 0;
  for (const codePoint of value) {
    const codePointBytes = utf8Bytes(codePoint);
    if (bytes + codePointBytes > maxBytes) break;
    bytes += codePointBytes;
    end += codePoint.length;
  }
  return value.slice(0, end);
}

function activeToolTokens(pi: ExtensionAPI): number {
  try {
    const active = new Set(pi.getActiveTools());
    const tools = pi.getAllTools()
      .filter((tool) => active.has(tool.name))
      .map((tool) => ({
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters,
        promptGuidelines: tool.promptGuidelines,
      }));
    return serializedBytes(tools);
  } catch {
    return 0;
  }
}

function restoreCompactRefresh(ctx: SessionStartContext): void {
  compactRefresh = undefined;
  compactRefreshNotice = "";
  const branch = ctx.sessionManager?.getBranch?.();
  if (!Array.isArray(branch)) return;
  let latestCompactionIndex = -1;
  for (let i = branch.length - 1; i >= 0; i -= 1) {
    const entry = branch[i] as { type?: unknown };
    if (entry?.type === "compaction") {
      latestCompactionIndex = i;
      break;
    }
  }
  if (latestCompactionIndex < 0) return;
  for (let i = branch.length - 1; i > latestCompactionIndex; i -= 1) {
    const entry = branch[i] as { type?: unknown; customType?: unknown; data?: unknown };
    if (entry?.type !== "custom" || entry.customType !== compactRefreshStateType) continue;
    const data = entry.data as Partial<CompactRefreshState> | undefined;
    if (
      data?.version === 1 && typeof data.raw === "string" &&
      Number.isFinite(data.observedBytes) && typeof data.hardTruncated === "boolean" &&
      Number.isFinite(data.reserveTokens) && Number.isFinite(data.keepRecentTokens)
    ) {
      compactRefresh = data as CompactRefreshState;
    }
    return;
  }
  compactRefresh = {
    version: 1,
    raw: "",
    observedBytes: 0,
    hardTruncated: false,
    reserveTokens: 16384,
    keepRecentTokens: 20000,
  };
}

function compactRefreshContent(
  refresh: CompactRefreshState,
  availableTokens: number,
): { content: string; deliveredTokens: number; omitted: boolean } | undefined {
  if (availableTokens <= 0) return undefined;
  const sourceIndex =
    `Read ${root}/AGENTS.md completely before acting on omitted instructions. ` +
    `Inspect only the needed durable sources named in the retained index under ${fmHome}/data and ${fmHome}/state; do not infer omitted state.`;
  const minimalBody = `POST-COMPACTION REFRESH OMITTED FOR CONTEXT SAFETY. ${sourceIndex}`;
  let minimalContent: string;
  try {
    minimalContent = encodeFirstmateOperationalInput("session-start", minimalBody);
  } catch {
    return undefined;
  }
  const minimalTokens = utf8Bytes(minimalContent);
  if (minimalTokens > availableTokens) return undefined;

  let fullContent: string;
  try {
    fullContent = encodeFirstmateOperationalInput("session-start", refresh.raw || minimalBody);
  } catch {
    return undefined;
  }
  // Sizing needs an UPPER bound on token count so we never claim to fit more
  // than we do; UTF-8 byte length is a valid upper bound because every token
  // encodes at least one byte.
  const fullTokens = utf8Bytes(fullContent);
  if (!refresh.hardTruncated && refresh.raw && fullTokens <= availableTokens) {
    return { content: fullContent, deliveredTokens: fullTokens, omitted: false };
  }

  const marker =
    `\n\nPI POST-COMPACTION REFRESH TRUNCATED FOR CONTEXT SAFETY - the refresh contained ` +
    `${refresh.raw.length} available characters from ${refresh.observedBytes} observed output bytes. ` +
    `${sourceIndex}`;
  const wrapperBytes = utf8Bytes(encodeFirstmateOperationalInput("session-start", "x")) - 1;
  const fixedBytes = wrapperBytes + utf8Bytes(marker);
  const retained = sliceUtf8Prefix(refresh.raw, Math.max(0, availableTokens - fixedBytes));
  const content = encodeFirstmateOperationalInput("session-start", `${retained}${marker}`);
  const deliveredTokens = utf8Bytes(content);
  if (deliveredTokens > availableTokens) {
    return { content: minimalContent, deliveredTokens: minimalTokens, omitted: true };
  }
  return { content, deliveredTokens, omitted: true };
}

function compactRefreshBudget(
  pi: ExtensionAPI,
  refresh: CompactRefreshState,
  eventMessages: unknown[],
  ctx: {
    model?: { contextWindow?: number };
    getContextUsage?: () => { tokens: number | null; contextWindow: number } | undefined;
    getSystemPrompt?: () => string;
  },
): Omit<CompactRefreshBudget, "deliveredTokens" | "omitted"> | undefined {
  const usage = ctx.getContextUsage?.();
  const contextWindow = usage?.contextWindow || ctx.model?.contextWindow || 0;
  if (!Number.isFinite(contextWindow) || contextWindow <= 0) return undefined;
  const reserveTokens = Math.max(0, Math.min(contextWindow, refresh.reserveTokens));
  const desiredSafetyTokens = Math.max(compactRefreshSafetyTokens, Math.ceil(contextWindow * 0.05));
  // event.messages is rebuilt from persisted session entries on every context
  // event, and the refresh this function injects is deliberately ephemeral
  // (never persisted - see the session_compact handler), so eventMessages
  // never contains a prior turn's injected refresh to double-count. That
  // makes a plain UTF-8 byte sum of the real messages a safe, uncontaminated
  // upper bound on base context - unlike ctx.getContextUsage().tokens, which
  // is the provider's billed total for the prior turn and DOES include
  // whatever refresh was injected into that turn's request. Netting a prior
  // refresh's cost back out of that billed total would need a sound LOWER
  // bound on its token count, but no fixed bytes-per-token divisor is safe
  // across tokenizers - a single token can encode arbitrarily many bytes. So
  // base context is estimated from the clean message list instead of trying
  // to un-contaminate the authoritative total.
  const messageTokens = serializedBytes(eventMessages);
  const systemTokens = utf8Bytes(String(ctx.getSystemPrompt?.() ?? ""));
  const baseTokens = messageTokens + systemTokens + activeToolTokens(pi);
  const headroomTokens = Math.max(0, Math.floor(contextWindow - reserveTokens - baseTokens));
  // Preserve the normal safety margin without letting that margin itself crowd
  // out the concise current-instruction pointer it exists to protect.
  const safetyTokens = Math.min(desiredSafetyTokens, Math.max(0, headroomTokens - 256));
  const availableTokens = Math.max(0, headroomTokens - safetyTokens);
  return { contextWindow, reserveTokens, baseTokens, safetyTokens, availableTokens };
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
    restoreCompactRefresh(ctx);
    const reason = String((event as { reason?: unknown }).reason ?? "");
    const source = reason === "startup"
      ? startupRebuildSource(ctx) ?? "startup"
      : { new: "clear", resume: "resume", fork: "fork" }[reason];
    markLoaded();
    if (!source) return;
    registerSessionstartExitListener();
    sessionstartGeneration = createSessionstartGeneration(
      source as SessionstartSource,
      sessionIdFromContext(ctx),
    );
  });

  pi.on?.("before_agent_start", async (_event, ctx) => {
    const generation = sessionstartGeneration;
    if (!generation) return;
    const message = await claimSessionstartMessage(generation, ctx);
    return message ? { message } : undefined;
  });

  pi.on?.("session_before_compact", (event) => {
    // keepRecentTokens is captured and persisted (see CompactRefreshState) but
    // deliberately not folded into compactRefreshBudget: retained messages
    // already appear in the rebuilt event.messages that the single base-context
    // estimate sums, so adding it would double-count retained context and
    // shrink the refresh with no safety benefit.
    compactSettings = {
      reserveTokens: event.preparation.settings.reserveTokens,
      keepRecentTokens: event.preparation.settings.keepRecentTokens,
    };
  });

  // Pi's compaction equivalent shares startup's generation ownership and
  // cancellation - a stale or superseded compaction cannot deliver - but never
  // delivers through before_agent_start or an optionless sendMessage. A
  // persistent full custom message would refill the context Pi just reduced
  // and would itself enter a later summarization span, so the bounded result
  // becomes durable extension state instead; the context hook below injects it
  // ephemerally within the selected model's live budget on every later
  // provider request.
  pi.on?.("session_compact", async (_event, ctx) => {
    const reserveTokens = compactSettings?.reserveTokens ?? 16384;
    const keepRecentTokens = compactSettings?.keepRecentTokens ?? 20000;
    compactSettings = undefined;
    registerSessionstartExitListener();
    const generation = createSessionstartGeneration("compact", sessionIdFromContext(ctx));
    sessionstartGeneration = generation;
    const result = await claimSessionstartResult(generation, ctx);
    if (!result) return;
    const raw = result.kind === "ready" ? result.raw : "";
    compactRefresh = {
      version: 1,
      raw,
      observedBytes: result.kind === "ready" ? result.observedBytes : 0,
      hardTruncated: result.kind === "ready" ? result.hardTruncated : false,
      reserveTokens,
      keepRecentTokens,
    };
    compactRefreshNotice = "";
    try {
      pi.appendEntry(compactRefreshStateType, compactRefresh);
    } catch {
      generation.delivered = false;
    }
    if (!raw && ctx.hasUI) {
      ctx.ui.notify(
        `Firstmate could not rebuild its post-compaction digest; read ${root}/AGENTS.md before continuing.`,
        "warning",
      );
    }
  });

  pi.on?.("session_shutdown", async () => {
    const generation = sessionstartGeneration;
    try {
      if (generation) await stopSessionstartGeneration(generation);
    } finally {
      if (sessionstartGeneration === generation) sessionstartGeneration = null;
      removeSessionstartExitListener();
      compactSettings = undefined;
      compactRefresh = undefined;
      compactRefreshNotice = "";
    }
  });

  pi.on("context", (event, ctx) => {
    if (!compactRefresh) return;
    const budget = compactRefreshBudget(pi, compactRefresh, event.messages, ctx);
    if (!budget) return;
    const bounded = compactRefreshContent(compactRefresh, budget.availableTokens);
    if (!bounded) {
      // Freshness degradation must never be silent. The notice key carries the
      // measured figures, not just the kind, so a budget that keeps shrinking
      // re-reports each distinct degradation instead of being deduped away
      // after the first one.
      const notice = `none:${budget.availableTokens}`;
      if (ctx.hasUI && compactRefreshNotice !== notice) {
        compactRefreshNotice = notice;
        ctx.ui.notify(
          `Firstmate SUPPRESSED its entire post-compaction refresh: only ${budget.availableTokens} safe bytes remained ` +
            `(base context conservatively over-reserved at ${budget.baseTokens} bytes, reserve ${budget.reserveTokens}, ` +
            `safety ${budget.safetyTokens}, window ${budget.contextWindow}). Current Firstmate operating instructions are ` +
            `NOT in model context; read ${root}/AGENTS.md before continuing.`,
          "warning",
        );
      }
      return;
    }
    if (bounded.omitted) {
      const notice = `bounded:${bounded.deliveredTokens}/${budget.availableTokens}`;
      if (ctx.hasUI && compactRefreshNotice !== notice) {
        compactRefreshNotice = notice;
        ctx.ui.notify(
          `Firstmate TRUNCATED its post-compaction refresh to ${bounded.deliveredTokens} of ${budget.availableTokens} safe bytes ` +
            `(base context conservatively over-reserved at ${budget.baseTokens} bytes, window ${budget.contextWindow}). ` +
            `Omitted instructions remain readable at ${root}/AGENTS.md and the durable sources named in the retained index.`,
          "warning",
        );
      }
    }
    const refreshMessage = {
      role: "custom" as const,
      customType: "firstmate-sessionstart-nudge",
      content: bounded.content,
      display: false,
      details: {
        kind: "session-start",
        source: "compact",
        ephemeral: true,
        budget: { ...budget, deliveredTokens: bounded.deliveredTokens, omitted: bounded.omitted },
      },
      timestamp: Date.now(),
    };
    return { messages: [...event.messages, refreshMessage] };
  });

  pi.on("model_select", () => {
    compactRefreshNotice = "";
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

  pi.on("agent_settled", async () => {
    if (guardFollowupActive) {
      guardFollowupActive = false;
      return;
    }

    const result = await runGuard();
    if (result.code !== 2) return;

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
  });

  markLoaded();
}
