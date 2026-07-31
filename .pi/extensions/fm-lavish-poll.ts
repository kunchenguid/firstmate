// Completion-aware Lavish feedback relay for Pi-family Firstmate primary sessions.
//
// The extension owns only Lavish poll subprocesses. Fleet watcher continuity and
// turn-end enforcement remain with their existing extensions.
import { spawn, spawnSync, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import {
  chmodSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, extname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionUIContext } from "@earendil-works/pi-coding-agent";
import { StringEnum } from "@earendil-works/pi-ai";
import { Type } from "typebox";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || resolve(fmHome, "state");
const marker = resolve(state, ".pi-lavish-extension-loaded");
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;
const lavishExecutable = process.env.FM_LAVISH_AXI_BIN || "lavish-axi";
const relayRoot = resolve(state, ".pi-lavish-relay");
const STATUS_KEY = "firstmate-lavish-relay";
const CUSTOM_MESSAGE_TYPE = "firstmate-lavish-feedback";
const CAPTURE_BYTES_PER_STREAM = 512 * 1024;
const MESSAGE_OUTPUT_BYTES = 18 * 1024;
const MESSAGE_OUTPUT_LINES = 240;
const AGENT_REPLY_BYTES = 8 * 1024;
const STOP_GRACE_MS = 1000;

type RelayAction = "start" | "status" | "stop";
type RelayKind = "feedback" | "terminal" | "fatal";

type RelayGeneration = {
  id: number;
  sessionId: string;
  active: boolean;
  ui: ExtensionUIContext;
  directory: string | null;
  polls: Map<string, RelayPoll>;
  artifactAliases: Map<string, string>;
  exitHandler: (() => void) | null;
};

type RelayPoll = {
  artifact: string;
  child: ChildProcessWithoutNullStreams;
  generation: RelayGeneration;
  stdout: BoundedBytes;
  stderr: BoundedBytes;
  settled: boolean;
  suppressDelivery: boolean;
  failedStart: boolean;
  recordPath: string | null;
  diagnosticPath: string | null;
  resolveClosed: () => void;
  closed: Promise<void>;
};

type RelayResult = {
  ok: boolean;
  action: RelayAction;
  message: string;
  artifact?: string;
  active?: number;
};

type LockOwnership = "owned" | "missing" | "other";

type NormalizedArtifact = {
  artifact: string;
  inputPath: string;
};

class BoundedBytes {
  totalBytes = 0;
  private readonly half = Math.floor(CAPTURE_BYTES_PER_STREAM / 2);
  private head = Buffer.alloc(0);
  private tail = Buffer.alloc(0);

  append(chunk: Buffer): void {
    this.totalBytes += chunk.length;
    let offset = 0;
    if (this.head.length < this.half) {
      const take = Math.min(this.half - this.head.length, chunk.length);
      this.head = Buffer.concat([this.head, chunk.subarray(0, take)]);
      offset = take;
    }
    if (offset < chunk.length) {
      this.tail = Buffer.concat([this.tail, chunk.subarray(offset)]);
      if (this.tail.length > this.half) this.tail = this.tail.subarray(this.tail.length - this.half);
    }
  }

  get truncated(): boolean {
    return this.totalBytes > this.head.length + this.tail.length;
  }

  text(): string {
    const joiner = this.truncated ? Buffer.from("\n[... private capture truncated ...]\n") : Buffer.alloc(0);
    return Buffer.concat([this.head, joiner, this.tail]).toString("utf8");
  }
}

let nextGenerationId = 0;
let activeGeneration: RelayGeneration | null = null;

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
    lockPid = readFileSync(resolve(state, ".lock"), "utf8").trim();
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

function ownsOrCanInitializeHome(): boolean {
  return lockOwnership() !== "other";
}

function markLoaded(): void {
  if (!ownsOrCanInitializeHome()) return;
  mkdirSync(state, { recursive: true, mode: 0o700 });
  writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`, { mode: 0o600 });
}

function byteLength(value: string): number {
  return Buffer.byteLength(value, "utf8");
}

function boundedText(value: string): { text: string; truncated: boolean } {
  let lines = value.replaceAll("\r\n", "\n").split("\n");
  let truncated = false;
  if (lines.length > MESSAGE_OUTPUT_LINES) {
    const head = lines.slice(0, 80);
    const tail = lines.slice(-(MESSAGE_OUTPUT_LINES - 81));
    lines = [...head, `[... ${lines.length - head.length - tail.length} output lines omitted ...]`, ...tail];
    truncated = true;
  }
  let text = lines.join("\n").trim();
  if (byteLength(text) > MESSAGE_OUTPUT_BYTES) {
    const bytes = Buffer.from(text, "utf8");
    const half = Math.floor((MESSAGE_OUTPUT_BYTES - 80) / 2);
    text = `${bytes.subarray(0, half).toString("utf8")}\n[... output bytes omitted ...]\n${bytes.subarray(bytes.length - half).toString("utf8")}`;
    truncated = true;
  }
  return { text, truncated };
}

function sanitizeLavishOutput(stdout: string, stderr: string): string {
  const sanitized: string[] = [];
  let skippingDomSnapshot = false;
  for (const line of stdout.replaceAll("\r\n", "\n").split("\n")) {
    if (/^dom_snapshot:/.test(line)) {
      sanitized.push("dom_snapshot: [omitted by the Pi relay; inspect the private diagnostic only when needed]");
      skippingDomSnapshot = true;
      continue;
    }
    if (skippingDomSnapshot) {
      if (/^[A-Za-z_][A-Za-z0-9_-]*(?:\[[^\]]*\])?(?:\{[^}]*\})?:/.test(line)) {
        skippingDomSnapshot = false;
      } else {
        continue;
      }
    }
    sanitized.push(line);
  }
  const usefulStderr = stderr
    .replaceAll("\r\n", "\n")
    .split("\n")
    .filter((line) =>
      line &&
      !line.startsWith("[lavish-axi] Long-polling for user feedback") &&
      !line.startsWith("[lavish-axi] Still waiting for user feedback"),
    );
  if (usefulStderr.length > 0) sanitized.push("stderr:", ...usefulStderr.map((line) => `  ${line}`));
  return sanitized.join("\n").trim();
}

function classifyResult(
  stdout: string,
  code: number | null,
  signal: NodeJS.Signals | null,
  failedStart: boolean,
): { kind: RelayKind; terminal: boolean } {
  const terminal = /(?:^|\n)\s*session_ended:\s*true\s*(?:\n|$)/.test(stdout) ||
    /(?:^|\n)\s*status:\s*ended\s*(?:\n|$)/.test(stdout);
  if (terminal && code === 0 && !signal) return { kind: "terminal", terminal: true };
  const feedback = /(?:^|\n)\s*status:\s*feedback\s*(?:\n|$)/.test(stdout);
  const artifactFailure = /(?:^|\n)artifact_failures(?:[:[])/.test(stdout);
  if (feedback && code === 0 && !signal && !failedStart && !artifactFailure) {
    return { kind: "feedback", terminal: false };
  }
  return { kind: "fatal", terminal };
}

function normalizeArtifact(cwd: string, value: string, mustExist: boolean): NormalizedArtifact {
  const stripped = value.startsWith("@") ? value.slice(1) : value;
  if (!stripped || stripped.includes("\0") || byteLength(stripped) > 4096) {
    throw new Error("artifact must be a non-empty bounded HTML file path");
  }
  const absolute = resolve(cwd, stripped);
  let canonical = absolute;
  try {
    canonical = realpathSync(absolute);
  } catch (error) {
    if (mustExist) throw error;
  }
  if (![".html", ".htm"].includes(extname(canonical).toLowerCase())) {
    throw new Error("artifact must end in .html or .htm");
  }
  if (mustExist && !statSync(canonical).isFile()) throw new Error("artifact must be a regular file");
  return { artifact: canonical, inputPath: absolute };
}

function artifactKey(artifact: string): string {
  return createHash("sha256").update(artifact).digest("hex");
}

function ensureGenerationDirectory(generation: RelayGeneration): string {
  if (generation.directory) return generation.directory;
  const safeSessionId = generation.sessionId.replaceAll(/[^A-Za-z0-9_.-]/g, "_").slice(0, 80) || "ephemeral";
  generation.directory = resolve(relayRoot, `${safeSessionId}.${generation.id}.${randomUUID()}`);
  mkdirSync(generation.directory, { recursive: true, mode: 0o700 });
  chmodSync(generation.directory, 0o700);
  return generation.directory;
}

function pruneGenerationDirectory(generation: RelayGeneration): void {
  const directory = generation.directory;
  if (!directory) return;
  try {
    if (readdirSync(directory).length === 0) {
      rmSync(directory, { recursive: true, force: true });
      generation.directory = null;
    }
  } catch {
  }
}

function removeArtifactRecords(generation: RelayGeneration, artifact: string): void {
  if (!generation.directory) return;
  const key = artifactKey(artifact);
  rmSync(resolve(generation.directory, `${key}.result.json`), { force: true });
  rmSync(resolve(generation.directory, `${key}.diagnostic.txt`), { force: true });
  removeArtifactAliases(generation, artifact);
  pruneGenerationDirectory(generation);
}

function removeArtifactAliases(generation: RelayGeneration, artifact: string): void {
  for (const [inputPath, canonical] of generation.artifactAliases) {
    if (inputPath === artifact || canonical === artifact) generation.artifactAliases.delete(inputPath);
  }
}

function resolveArtifactLookup(generation: RelayGeneration, artifact: string): string {
  return generation.polls.has(artifact) ? artifact : generation.artifactAliases.get(artifact) ?? artifact;
}

function removePrivateFiles(poll: RelayPoll): void {
  for (const path of [poll.recordPath, poll.diagnosticPath]) {
    if (path) rmSync(path, { force: true });
  }
  poll.recordPath = null;
  poll.diagnosticPath = null;
  pruneGenerationDirectory(poll.generation);
}

function writePrivateResult(
  poll: RelayPoll,
  kind: RelayKind,
  output: string,
  code: number | null,
  signal: NodeJS.Signals | null,
  saveDiagnostic: boolean,
): void {
  if (poll.failedStart) return;
  const directory = ensureGenerationDirectory(poll.generation);
  const key = artifactKey(poll.artifact);
  poll.recordPath = resolve(directory, `${key}.result.json`);
  if (saveDiagnostic) {
    poll.diagnosticPath = resolve(directory, `${key}.diagnostic.txt`);
    const diagnostic = [
      `artifact=${poll.artifact}`,
      `kind=${kind}`,
      `exit_code=${code ?? ""}`,
      `signal=${signal ?? ""}`,
      `stdout_total_bytes=${poll.stdout.totalBytes}`,
      `stderr_total_bytes=${poll.stderr.totalBytes}`,
      "",
      "--- stdout (bounded private capture) ---",
      poll.stdout.text(),
      "",
      "--- stderr (bounded private capture) ---",
      poll.stderr.text(),
      "",
    ].join("\n");
    writeFileSync(poll.diagnosticPath, diagnostic, { mode: 0o600 });
  }
  const record = {
    schema: "firstmate.pi-lavish-relay.v1",
    session_id: poll.generation.sessionId,
    generation: poll.generation.id,
    artifact: poll.artifact,
    kind,
    exit_code: code,
    signal,
    output,
    diagnostic: poll.diagnosticPath,
    captured_at: new Date().toISOString(),
  };
  writeFileSync(poll.recordPath, `${JSON.stringify(record, null, 2)}\n`, { mode: 0o600 });
}

function updateStatus(generation: RelayGeneration): void {
  if (!generation.active || generation.polls.size === 0) {
    generation.ui.setStatus(STATUS_KEY, undefined);
    return;
  }
  const suffix = generation.polls.size === 1 ? "poll" : "polls";
  generation.ui.setStatus(STATUS_KEY, `Lavish: ${generation.polls.size} waiting ${suffix}`);
}

function removeExitHandlerIfIdle(generation: RelayGeneration): void {
  if (generation.polls.size > 0 || !generation.exitHandler) return;
  process.off("exit", generation.exitHandler);
  generation.exitHandler = null;
}

function cleanupPoll(poll: RelayPoll, removeRecords: boolean): void {
  if (poll.generation.polls.get(poll.artifact) === poll) {
    poll.generation.polls.delete(poll.artifact);
  }
  poll.child.stdout.removeAllListeners();
  poll.child.stderr.removeAllListeners();
  poll.child.removeAllListeners();
  if (removeRecords) {
    removePrivateFiles(poll);
    removeArtifactAliases(poll.generation, poll.artifact);
  }
  updateStatus(poll.generation);
  removeExitHandlerIfIdle(poll.generation);
}

function relayIsCurrent(poll: RelayPoll): boolean {
  return activeGeneration === poll.generation && poll.generation.active && !poll.suppressDelivery && ownsOrCanInitializeHome();
}

function deliveryMessage(
  poll: RelayPoll,
  kind: RelayKind,
  output: string,
  code: number | null,
  signal: NodeJS.Signals | null,
  outputTruncated: boolean,
): string {
  const result = kind === "feedback"
    ? "Lavish feedback is ready. Apply it, then start the relay again with agent_reply to continue the same review."
    : kind === "terminal"
      ? "The Lavish review ended. Do not poll or reopen it unless the reviewer explicitly asks."
      : "The Lavish poll failed or returned a fatal artifact result. Resolve the reported failure before deciding whether to poll again.";
  const pointer = poll.diagnosticPath
    ? `\nPrivate bounded diagnostic: ${poll.diagnosticPath}`
    : "";
  const truncation = outputTruncated
    ? poll.diagnosticPath
      ? "\nThe injected output was bounded; use the private diagnostic only if the visible result is insufficient."
      : "\nThe injected output was bounded and the terminal review cleanup retained no private diagnostic."
    : "";
  return [
    `LAVISH_RELAY_RESULT v1 kind=${kind}`,
    `artifact: ${poll.artifact}`,
    `exit: code=${code ?? "null"} signal=${signal ?? "none"}`,
    result,
    "Pi relay rule: any Lavish next_step below that says to run a foreground poll means call fm_lavish_poll with action=start instead.",
    pointer,
    truncation,
    "",
    output || "(no command output)",
  ].join("\n").replace(/\n{3,}/g, "\n\n");
}

function finishPoll(
  pi: ExtensionAPI,
  poll: RelayPoll,
  code: number | null,
  signal: NodeJS.Signals | null,
  startError?: Error,
): void {
  if (poll.settled) return;
  poll.settled = true;
  poll.resolveClosed();
  if (startError) poll.stderr.append(Buffer.from(`${startError.name}: ${startError.message}\n`));
  if (poll.suppressDelivery || !relayIsCurrent(poll)) {
    cleanupPoll(poll, true);
    return;
  }

  const rawStdout = poll.stdout.text();
  const rawStderr = poll.stderr.text();
  const classification = classifyResult(rawStdout, code, signal, poll.failedStart);
  const bounded = boundedText(sanitizeLavishOutput(rawStdout, rawStderr));
  const saveDiagnostic = !poll.failedStart && !classification.terminal && (
    classification.kind === "fatal" ||
    bounded.truncated ||
    poll.stdout.truncated ||
    poll.stderr.truncated
  );
  writePrivateResult(poll, classification.kind, bounded.text, code, signal, saveDiagnostic);
  const content = deliveryMessage(
    poll,
    classification.kind,
    bounded.text,
    code,
    signal,
    bounded.truncated || poll.stdout.truncated || poll.stderr.truncated,
  );
  try {
    pi.sendMessage(
      {
        customType: CUSTOM_MESSAGE_TYPE,
        content,
        display: true,
        details: {
          kind: classification.kind,
          artifact: poll.artifact,
          recordPath: poll.recordPath,
          diagnosticPath: poll.diagnosticPath,
        },
      },
      { triggerTurn: true, deliverAs: "followUp" },
    );
    cleanupPoll(poll, classification.terminal || poll.failedStart);
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    poll.generation.ui.setStatus(STATUS_KEY, `Lavish delivery failed: ${reason.slice(0, 120)}`);
    cleanupPoll(poll, classification.terminal || poll.failedStart);
  }
}

function installExitHandler(generation: RelayGeneration): void {
  if (generation.exitHandler) return;
  generation.exitHandler = () => {
    for (const poll of generation.polls.values()) {
      poll.suppressDelivery = true;
      poll.child.kill("SIGTERM");
    }
    if (generation.directory) rmSync(generation.directory, { recursive: true, force: true });
    generation.directory = null;
  };
  process.once("exit", generation.exitHandler);
}

function startPoll(
  pi: ExtensionAPI,
  generation: RelayGeneration,
  artifact: string,
  inputPath: string,
  agentReply: string | undefined,
): RelayResult {
  if (!generation.active || activeGeneration !== generation) {
    return { ok: false, action: "start", message: "Lavish relay unavailable: this Pi session generation is no longer active." };
  }
  if (!ownsOrCanInitializeHome()) {
    return { ok: false, action: "start", message: "Lavish relay unavailable: another live Firstmate session owns this home." };
  }
  if (generation.polls.has(artifact)) {
    return {
      ok: false,
      action: "start",
      artifact,
      active: generation.polls.size,
      message: `Lavish relay unchanged: a poll is already waiting for ${artifact}.`,
    };
  }
  if (agentReply !== undefined && byteLength(agentReply) > AGENT_REPLY_BYTES) {
    return { ok: false, action: "start", artifact, message: `Lavish relay refused agent_reply larger than ${AGENT_REPLY_BYTES} bytes.` };
  }

  removeArtifactRecords(generation, artifact);
  const args = ["poll", artifact];
  if (agentReply !== undefined && agentReply.length > 0) args.push("--agent-reply", agentReply);
  let child: ChildProcessWithoutNullStreams;
  try {
    child = spawn(lavishExecutable, args, {
      cwd: dirname(artifact),
      env: { ...process.env, LAVISH_AXI_NO_OPEN: "1" },
      stdio: ["pipe", "pipe", "pipe"],
      shell: false,
      detached: false,
    });
    child.stdin.end();
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    return { ok: false, action: "start", artifact, message: `Lavish relay failed to start: ${reason}` };
  }

  let resolveClosed: () => void = () => {};
  const closed = new Promise<void>((resolvePromise) => {
    resolveClosed = resolvePromise;
  });
  const poll: RelayPoll = {
    artifact,
    child,
    generation,
    stdout: new BoundedBytes(),
    stderr: new BoundedBytes(),
    settled: false,
    suppressDelivery: false,
    failedStart: child.pid === undefined,
    recordPath: null,
    diagnosticPath: null,
    resolveClosed,
    closed,
  };
  generation.polls.set(artifact, poll);
  generation.artifactAliases.set(inputPath, artifact);
  generation.artifactAliases.set(artifact, artifact);
  installExitHandler(generation);
  child.stdout.on("data", (chunk: Buffer) => poll.stdout.append(chunk));
  child.stderr.on("data", (chunk: Buffer) => poll.stderr.append(chunk));
  child.once("error", (error: Error) => {
    poll.failedStart = poll.failedStart || child.pid === undefined;
    finishPoll(pi, poll, null, null, error);
  });
  child.once("close", (code: number | null, signal: NodeJS.Signals | null) => {
    finishPoll(pi, poll, code, signal);
  });
  updateStatus(generation);
  return {
    ok: true,
    action: "start",
    artifact,
    active: generation.polls.size,
    message: `Lavish relay started for ${artifact}; the Pi conversation remains available while feedback waits.`,
  };
}

async function waitForClose(poll: RelayPoll, timeoutMs: number): Promise<boolean> {
  let timer: ReturnType<typeof setTimeout> | null = null;
  const timedOut = new Promise<false>((resolveTimeout) => {
    timer = setTimeout(() => resolveTimeout(false), timeoutMs);
    timer.unref();
  });
  const closed = poll.closed.then(() => true);
  const result = await Promise.race([closed, timedOut]);
  if (timer) clearTimeout(timer);
  return result;
}

async function stopPoll(poll: RelayPoll): Promise<void> {
  if (poll.settled) {
    cleanupPoll(poll, true);
    return;
  }
  poll.suppressDelivery = true;
  poll.child.kill("SIGTERM");
  if (!(await waitForClose(poll, STOP_GRACE_MS))) {
    poll.child.kill("SIGKILL");
    await waitForClose(poll, STOP_GRACE_MS);
  }
  if (!poll.settled) {
    poll.settled = true;
    poll.resolveClosed();
    cleanupPoll(poll, true);
  }
}

async function stopGeneration(generation: RelayGeneration): Promise<void> {
  generation.active = false;
  await Promise.all([...generation.polls.values()].map((poll) => stopPoll(poll)));
  generation.ui.setStatus(STATUS_KEY, undefined);
  if (generation.exitHandler) process.off("exit", generation.exitHandler);
  generation.exitHandler = null;
  if (generation.directory) rmSync(generation.directory, { recursive: true, force: true });
  generation.directory = null;
}

function statusResult(generation: RelayGeneration, artifact?: string): RelayResult {
  if (artifact) {
    const waiting = generation.polls.has(artifact);
    return {
      ok: true,
      action: "status",
      artifact,
      active: generation.polls.size,
      message: waiting
        ? `Lavish relay waiting for ${artifact}.`
        : `Lavish relay has no active poll for ${artifact}.`,
    };
  }
  const paths = [...generation.polls.keys()].slice(0, 5);
  return {
    ok: true,
    action: "status",
    active: generation.polls.size,
    message: generation.polls.size === 0
      ? "Lavish relay idle: no active polls."
      : `Lavish relay waiting on ${generation.polls.size} artifact(s): ${paths.join(", ")}${generation.polls.size > paths.length ? ", ..." : ""}`,
  };
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", (_event, ctx) => {
    const generation: RelayGeneration = {
      id: ++nextGenerationId,
      sessionId: ctx.sessionManager.getSessionId(),
      active: true,
      ui: ctx.ui,
      directory: null,
      polls: new Map(),
      artifactAliases: new Map(),
      exitHandler: null,
    };
    activeGeneration = generation;
    markLoaded();
    ctx.ui.setStatus(STATUS_KEY, undefined);
  });

  pi.on("session_shutdown", async (_event, ctx) => {
    const generation = activeGeneration;
    if (!generation) {
      ctx.ui.setStatus(STATUS_KEY, undefined);
      return;
    }
    activeGeneration = null;
    await stopGeneration(generation);
    ctx.ui.setStatus(STATUS_KEY, undefined);
  });

  pi.registerTool({
    name: "fm_lavish_poll",
    label: "Lavish feedback relay",
    description: "Start, inspect, or stop a completion-aware lavish-axi poll owned by the current Pi session. Start returns immediately; feedback arrives later as one typed firstmate-lavish-feedback message. Use this instead of foreground bash polling in Pi-family Firstmate primary sessions.",
    promptSnippet: "Start, inspect, or stop completion-aware Lavish feedback polling without blocking the Pi conversation",
    promptGuidelines: [
      "Use fm_lavish_poll with action=start for every Lavish feedback wait in a Pi-family Firstmate primary session; never run `lavish-axi poll` through foreground bash, shell backgrounding, or a detached terminal.",
      "After Lavish feedback, apply the requested changes and call fm_lavish_poll again with action=start, the same artifact, and agent_reply when continuing the review; do not re-arm after a terminal review result.",
      "Use fm_lavish_poll with action=status to inspect relay ownership and action=stop before abandoning a review wait; fleet watcher supervision remains separate.",
    ],
    parameters: Type.Object({
      action: StringEnum(["start", "status", "stop"] as const),
      artifact: Type.Optional(Type.String({ description: "HTML artifact path. Required for start; optional for status and stop." })),
      agent_reply: Type.Optional(Type.String({ description: "Optional reply shown in Lavish before the next wait." })),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const generation = activeGeneration;
      if (!generation || !generation.active) {
        const unavailable: RelayResult = {
          ok: false,
          action: params.action,
          message: "Lavish relay unavailable: no active Pi session generation.",
        };
        return { content: [{ type: "text", text: unavailable.message }], details: unavailable };
      }

      let artifact: string | undefined;
      let inputPath: string | undefined;
      if (params.artifact !== undefined) {
        try {
          const normalized = normalizeArtifact(ctx.cwd, params.artifact, params.action === "start");
          artifact = resolveArtifactLookup(generation, normalized.artifact);
          inputPath = normalized.inputPath;
        } catch (error) {
          const reason = error instanceof Error ? error.message : String(error);
          const invalid: RelayResult = {
            ok: false,
            action: params.action,
            message: `Lavish relay refused artifact path: ${reason}`,
          };
          return { content: [{ type: "text", text: invalid.message }], details: invalid };
        }
      }

      let result: RelayResult;
      if (params.action === "start") {
        if (!artifact) {
          result = { ok: false, action: "start", message: "Lavish relay start requires artifact." };
        } else {
          result = startPoll(pi, generation, artifact, inputPath ?? artifact, params.agent_reply);
        }
      } else if (params.action === "status") {
        result = statusResult(generation, artifact);
      } else if (artifact) {
        const poll = generation.polls.get(artifact);
        if (!poll) {
          result = { ok: true, action: "stop", artifact, active: generation.polls.size, message: `Lavish relay already stopped for ${artifact}.` };
          removeArtifactRecords(generation, artifact);
        } else {
          await stopPoll(poll);
          result = { ok: true, action: "stop", artifact, active: generation.polls.size, message: `Lavish relay stopped for ${artifact}.` };
        }
      } else {
        const count = generation.polls.size;
        await Promise.all([...generation.polls.values()].map((poll) => stopPoll(poll)));
        if (generation.directory) rmSync(generation.directory, { recursive: true, force: true });
        generation.directory = null;
        result = { ok: true, action: "stop", active: 0, message: count === 0 ? "Lavish relay already idle." : `Lavish relay stopped ${count} active poll(s).` };
      }
      return { content: [{ type: "text", text: result.message }], details: result };
    },
  });
}
