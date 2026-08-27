// Firstmate primary watcher bridge for Pi.
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, SessionEntry } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

type ArmResult = {
  ok: boolean;
  message: string;
};

type DirectExchangeEvent = {
  version: 1;
  event: "submitted" | "admitted" | "delivered" | "answered";
  exchangeId: string;
  at: number;
  inputText?: string;
  imageCount?: number;
  inputContent?: unknown;
  delivery?: "immediate" | "steer" | "followUp";
  content?: unknown;
  runKey?: string;
};

type DirectExchangeState = {
  exchangeId: string;
  submittedAt: number;
  inputText: string;
  imageCount: number;
  inputContent?: unknown;
  delivery: "immediate" | "steer" | "followUp";
  admittedAt?: number;
  deliveredAt?: number;
  deliveredContent?: unknown;
  deliveredRecordIndex?: number;
  deliveredRunKey?: string;
  answeredAt?: number;
  answerContent?: unknown;
};

type LockOwnership = "owned" | "missing" | "other";

const directExchangeEntryType = "firstmate-direct-exchange";
const directInputObservationEntryType = "firstmate-direct-input-observation";
const continuityMessageType = "firstmate-direct-exchange-continuity";

function cloneJson(value: unknown): unknown {
  try {
    return JSON.parse(JSON.stringify(value));
  } catch {
    return String(value);
  }
}

function textContent(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((part): part is { type: "text"; text: string } => {
      if (!part || typeof part !== "object") return false;
      const candidate = part as { type?: unknown; text?: unknown };
      return candidate.type === "text" && typeof candidate.text === "string";
    })
    .map((part) => part.text)
    .join("\n");
}

function parseDirectExchangeEvent(entry: SessionEntry): DirectExchangeEvent | undefined {
  if (entry.type !== "custom" || entry.customType !== directExchangeEntryType) return undefined;
  const data = entry.data;
  if (!data || typeof data !== "object") return undefined;
  const candidate = data as Partial<DirectExchangeEvent>;
  if (
    candidate.version !== 1 ||
    !["submitted", "admitted", "delivered", "answered"].includes(candidate.event ?? "") ||
    typeof candidate.exchangeId !== "string" ||
    !candidate.exchangeId ||
    typeof candidate.at !== "number"
  ) {
    return undefined;
  }
  return candidate as DirectExchangeEvent;
}

function foldDirectExchanges(entries: SessionEntry[]): DirectExchangeState[] {
  const ordered: DirectExchangeState[] = [];
  const byId = new Map<string, DirectExchangeState>();
  entries.forEach((entry, index) => {
    const event = parseDirectExchangeEvent(entry);
    if (!event) return;
    if (event.event === "submitted") {
      if (byId.has(event.exchangeId) || typeof event.inputText !== "string") return;
      const state: DirectExchangeState = {
        exchangeId: event.exchangeId,
        submittedAt: event.at,
        inputText: event.inputText,
        imageCount: event.imageCount ?? 0,
        delivery: event.delivery ?? "immediate",
      };
      if (event.inputContent !== undefined) state.inputContent = event.inputContent;
      byId.set(event.exchangeId, state);
      ordered.push(state);
      return;
    }
    const state = byId.get(event.exchangeId);
    if (!state) return;
    if (event.event === "admitted") {
      state.admittedAt = event.at;
    } else if (event.event === "delivered") {
      state.admittedAt ??= event.at;
      state.deliveredAt = event.at;
      state.deliveredContent = event.content;
      state.deliveredRecordIndex = index;
      state.deliveredRunKey = event.runKey;
    } else if (event.event === "answered") {
      state.answeredAt = event.at;
      state.answerContent = event.content;
    }
  });
  return ordered;
}

function contentPresent(messages: Array<{ role: string; content?: unknown }>, role: string, content: unknown): boolean {
  const expected = JSON.stringify(content);
  return messages.some((message) => message.role === role && JSON.stringify(message.content) === expected);
}

function renderDirectExchangeContinuity(
  entries: SessionEntry[],
  messages: Array<{ role: string; content?: unknown }>,
): string | undefined {
  const exchanges = foldDirectExchanges(entries);
  const sections: string[] = [];
  const latestAnswered = [...exchanges].reverse().find((exchange) => exchange.answerContent !== undefined);
  if (
    latestAnswered &&
    (!contentPresent(messages, "user", latestAnswered.deliveredContent) ||
      !contentPresent(messages, "assistant", latestAnswered.answerContent))
  ) {
    sections.push(
      [
        `Exchange ${latestAnswered.exchangeId}: ANSWERED`,
        `Human input, exact JSON: ${JSON.stringify(latestAnswered.deliveredContent)}`,
        `Assistant answer, exact JSON: ${JSON.stringify(latestAnswered.answerContent)}`,
      ].join("\n"),
    );
  }
  for (const exchange of exchanges) {
    if (exchange.answerContent !== undefined) continue;
    if (exchange.deliveredContent !== undefined) {
      sections.push(
        [
          `Exchange ${exchange.exchangeId}: OPEN_REPLY_OBLIGATION`,
          `Human input, exact JSON: ${JSON.stringify(exchange.deliveredContent)}`,
          "No completed assistant answer was observed before compaction.",
        ].join("\n"),
      );
    }
  }
  if (sections.length === 0) return undefined;
  return [
    "FIRSTMATE DIRECT EXCHANGE CONTINUITY",
    "This is extension-generated context metadata, not human-authored input.",
    "Watcher and turn-end supervision prompts are custom messages, not captain-authored requests.",
    ...sections,
  ].join("\n\n");
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

let child: any = null;
let seq = 0;

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

function firstLockLine(text: string): string {
  return text.split(/\r?\n/, 1)[0].trim();
}

function lockOwnership(): LockOwnership {
  let lockPid = "";
  try {
    lockPid = firstLockLine(readFileSync(`${state}/.lock`, "utf8"));
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

function sessionOwnsLock(): boolean {
  return lockOwnership() === "owned";
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

function failureLine(stdout: string, stderr: string, code: number | null): string {
  const combined = `${stdout}\n${stderr}`.trim();
  const healthy = combined.split(/\r?\n/).find((line) => /^watcher: healthy\b/.test(line));
  if (healthy) return `watcher: FAILED - Pi extension arm child found an external healthy watcher instead of owning wake delivery\n${healthy}`;
  const failed = combined.split(/\r?\n/).find((line) => /^watcher: FAILED/.test(line));
  if (failed) return failed;
  if (code && code !== 0) return `watcher: FAILED - fm-watch-arm.sh exited ${code}${combined ? `\n${combined}` : ""}`;
  return "";
}

export default function (pi: ExtensionAPI) {
  let exchangeSequence = 0;
  let agentRunSequence = 0;
  let activeAgentRunKey: string | undefined;
  let replyCohort = new Set<string>();
  let agentStartAwaitingHumanDelivery = false;

  function appendDirectExchange(event: DirectExchangeEvent): void {
    pi.appendEntry(directExchangeEntryType, event);
  }

  function stopArm(): void {
    if (child) child.kill("SIGTERM");
    child = null;
  }

  const cleanupOnProcessExit = () => {
    stopArm();
  };
  process.once("exit", cleanupOnProcessExit);

  function sendWake(message: string): void {
    pi.sendMessage(
      {
        customType: "firstmate-watcher-wake",
        content: `FIRSTMATE WATCHER WAKE: ${message}\n\nRun bin/fm-wake-drain.sh first, handle the queued wake, then resume Pi supervision.`,
        display: true,
        details: { version: 1, source: "firstmate-extension", kind: "watcher-wake" },
      },
      { deliverAs: "followUp", triggerTurn: true },
    );
  }

  function startArm(): ArmResult {
    if (!sessionOwnsLock()) return { ok: false, message: "watcher: read-only - session lock is held by another firstmate session" };
    markLoaded();
    if (child) return { ok: true, message: "watcher: healthy - Pi extension already has an arm child" };
    const id = ++seq;
    const env = {
      ...process.env,
      FM_HOME: fmHome,
      FM_ROOT_OVERRIDE: fmRoot,
      FM_CONFIG_OVERRIDE: config,
      FM_WATCH_ARM_SCRIPT: armScript,
    };
    child = spawn("bash", ["-lc", "config_dir=\"${FM_CONFIG_OVERRIDE:-$FM_HOME/config}\"; [ -f \"$config_dir/x-mode.env\" ] && . \"$config_dir/x-mode.env\"; exec \"$FM_WATCH_ARM_SCRIPT\" --restart"], {
      cwd: fmRoot,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString();
    });
    child.on("close", async (code: number | null) => {
      child = null;
      const reason = actionableLine(`${stdout}\n${stderr}`);
      const failure = reason ? "" : failureLine(stdout, stderr, code);
      if (!reason && !failure) return;
      try {
        sendWake(reason || failure);
      } catch {
        // Pi owns delivery errors; fail open so the extension never wedges the session.
      }
    });
    child.on("error", async (error: Error) => {
      child = null;
      try {
        sendWake(`watcher: FAILED - Pi extension arm child ${id} failed: ${error.message}`);
      } catch {
        // Fail open.
      }
    });
    return { ok: true, message: `watcher: started Pi extension arm child ${id}` };
  }

  pi.on?.("session_start", () => {
    markLoaded();
  });

  pi.on("agent_start", () => {
    activeAgentRunKey = `${process.pid}:${++agentRunSequence}`;
    agentStartAwaitingHumanDelivery = true;
  });

  function newExchangeId(at: number, content: unknown): string {
    return createHash("sha256")
      .update(`${at}\0${++exchangeSequence}\0${JSON.stringify(content)}`)
      .digest("hex")
      .slice(0, 16);
  }

  function admitExchange(exchangeId: string, at: number): void {
    appendDirectExchange({ version: 1, event: "admitted", exchangeId, at });
  }

  function createAdmittedExchange(
    content: unknown,
    delivery: "immediate" | "steer" | "followUp",
    at: number,
  ): string {
    const exchangeId = newExchangeId(at, content);
    appendDirectExchange({
      version: 1,
      event: "submitted",
      exchangeId,
      at,
      inputText: textContent(content),
      imageCount: Array.isArray(content)
        ? content.filter((part) => part && typeof part === "object" && (part as { type?: unknown }).type === "image").length
        : 0,
      inputContent: content,
      delivery,
    });
    admitExchange(exchangeId, at);
    return exchangeId;
  }

  pi.on("input", (event) => {
    if (event.source === "extension") return;
    const at = Date.now();
    const inputContent = cloneJson([{ type: "text", text: event.text }, ...(event.images ?? [])]);
    const delivery = event.streamingBehavior ?? "immediate";
    pi.appendEntry(directInputObservationEntryType, {
      version: 1,
      observationId: newExchangeId(at, inputContent),
      at,
      inputText: event.text,
      imageCount: event.images?.length ?? 0,
      inputContent,
      delivery,
    });
  });

  pi.on("message_end", (event, ctx) => {
    if (event.message.role === "user") {
      const content = cloneJson(event.message.content);
      const exchangeId = createAdmittedExchange(content, "steer", event.message.timestamp);
      appendDirectExchange({
        version: 1,
        event: "delivered",
        exchangeId,
        at: event.message.timestamp,
        content,
        runKey: activeAgentRunKey,
      });
      if (agentStartAwaitingHumanDelivery) {
        replyCohort = new Set<string>();
        agentStartAwaitingHumanDelivery = false;
      }
      replyCohort.add(exchangeId);
      return;
    }
    if (event.message.role !== "assistant" || event.message.stopReason !== "stop") return;
    const answerText = textContent(event.message.content);
    if (!answerText) return;
    const branch = ctx.sessionManager.getBranch();
    const open = foldDirectExchanges(branch).filter((exchange) => {
      if (exchange.deliveredContent === undefined || exchange.answerContent !== undefined) return false;
      if (!replyCohort.has(exchange.exchangeId)) return false;
      const deliveredIndex = exchange.deliveredRecordIndex;
      if (deliveredIndex === undefined) return false;
      return !branch.slice(deliveredIndex + 1).some((entry) => entry.type === "custom_message");
    });
    for (const exchange of open) {
      appendDirectExchange({
        version: 1,
        event: "answered",
        exchangeId: exchange.exchangeId,
        at: event.message.timestamp,
        content: cloneJson(event.message.content),
      });
    }
    if (open.length > 0) replyCohort.clear();
  });

  pi.on("context", (event, ctx) => {
    const continuity = renderDirectExchangeContinuity(
      ctx.sessionManager.getBranch(),
      event.messages,
    );
    if (!continuity) return;
    const message = {
      role: "custom" as const,
      customType: continuityMessageType,
      content: continuity,
      display: false,
      details: { version: 1, source: "firstmate-extension", kind: "direct-exchange-continuity" },
      timestamp: Date.now(),
    };
    let insertAt = 0;
    for (let i = event.messages.length - 1; i >= 0; i -= 1) {
      if (event.messages[i]?.role === "user") {
        insertAt = i;
        break;
      }
    }
    return { messages: [...event.messages.slice(0, insertAt), message, ...event.messages.slice(insertAt)] };
  });
  pi.on?.("session_shutdown", () => {
    stopArm();
    process.off("exit", cleanupOnProcessExit);
  });

  pi.registerCommand?.("fm-watch-arm-pi", {
    description: "Arm firstmate watcher supervision through the Pi extension instead of foreground bash.",
    handler: async (_args, ctx) => {
      const result = startArm();
      ctx.ui.notify(result.message, result.ok ? "info" : "warning");
    },
  });

  pi.registerTool?.({
    name: "fm_watch_arm_pi",
    label: "Arm firstmate watcher",
    description: "Arm Pi watcher supervision. Always use this tool instead of running bin/fm-watch-arm.sh through bash.",
    promptSnippet: "Arm firstmate watcher supervision through Pi without a foreground bash arm.",
    promptGuidelines: [
      "For Pi watcher supervision, call fm_watch_arm_pi instead of running bin/fm-watch-arm.sh through bash.",
    ],
    parameters: Type.Object({}),
    execute: async () => {
      const result = startArm();
      return {
        content: [{ type: "text", text: result.message }],
        details: result,
      };
    },
  });

  markLoaded();
}
