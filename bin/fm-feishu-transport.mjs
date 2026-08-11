#!/usr/bin/env node
// Dedicated no-Agent Feishu transport.
//
// The transport executes lark-cli with argv arrays only.  It never starts Pi,
// imports an Agent SDK, writes a Pi session, evaluates message text, or invokes
// a shell.  It waits for lark-cli's documented ready marker, keeps stderr drop
// diagnostics, reconciles overlapping history before live dispatch becomes
// eligible, and delivers the durable direct-Assistant outbox with stable
// idempotency keys and receipts.
import { spawn } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  claimNextOutbound,
  claimTransportOwner,
  clearStagedTransportEvents,
  failOutboundAttempt,
  publicStatusSummary,
  publishFeishuInbound,
  readActiveBinding,
  readPairing,
  readStagedTransportEvents,
  readTransportHealth,
  readTransportOwner,
  receiptOutbound,
  recordTransportDiagnostic,
  releaseTransportOwner,
  repairOutboundState,
  stageTransportEvents,
  statusSummary,
  writeTransportHealth,
} from "./fm-feishu-state.mjs";

const MODULE_FILE = fileURLToPath(import.meta.url);
const ROOT = resolve(dirname(MODULE_FILE), "..");
const HOME = realpathSync(process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || ROOT);
const LARK_CLI = process.env.FM_FEISHU_LARK_CLI || "lark-cli";
const READY_MARKER = "[event] ready event_key=im.message.receive_v1";
const MAX_BUFFERED_EVENTS = positiveInteger(process.env.FM_FEISHU_MAX_BUFFERED_EVENTS, 1000);
const READY_TIMEOUT_MS = positiveInteger(process.env.FM_FEISHU_READY_TIMEOUT_MS, 15000);
const COMMAND_TIMEOUT_MS = positiveInteger(process.env.FM_FEISHU_COMMAND_TIMEOUT_MS, 30000);
const HISTORY_OVERLAP_MS = positiveInteger(process.env.FM_FEISHU_HISTORY_OVERLAP_MS, 5 * 60 * 1000);
const OUTBOX_POLL_MS = positiveInteger(process.env.FM_FEISHU_OUTBOX_POLL_MS, 500);
const MAX_COMMAND_BYTES = 8 * 1024 * 1024;
const MAX_CONSUMER_LINE_BYTES = positiveInteger(process.env.FM_FEISHU_MAX_CONSUMER_LINE_BYTES, 256 * 1024);
const MAX_LIVE_BUFFER_BYTES = positiveInteger(process.env.FM_FEISHU_MAX_LIVE_BUFFER_BYTES, 8 * 1024 * 1024);
let stopping = false;
let consumer = null;
let outboundDrainTask = null;

function positiveInteger(value, fallback) {
  const number = Number(value);
  return Number.isSafeInteger(number) && number > 0 ? number : fallback;
}

function sleep(ms) {
  return new Promise((resolvePromise) => setTimeout(resolvePromise, ms));
}

function safeError(error) {
  if (error && typeof error === "object" && "code" in error) return `process-${String(error.code)}`;
  return "process-error";
}

function activeConfiguration() {
  const pairing = readPairing(HOME);
  const binding = readActiveBinding(HOME);
  if (!pairing || pairing.disabled_at !== null) throw new Error("Feishu pairing is absent or disabled");
  if (!binding || binding.status !== "active") throw new Error("Feishu binding is absent or disabled");
  if (pairing.fm_home_realpath !== HOME || binding.fm_home_realpath !== HOME || pairing.home_id !== binding.home_id) {
    throw new Error("Feishu pairing or binding belongs to another canonical home");
  }
  if (pairing.allowed_chats.length !== 1 || pairing.allowed_users.length !== 1 || binding.chat_id !== pairing.allowed_chats[0]) {
    throw new Error("Feishu MVP requires exactly one allowlisted user and one bound P2P chat");
  }
  return { pairing, binding };
}

function firstString(object, paths) {
  for (const path of paths) {
    let value = object;
    for (const key of path) value = value && typeof value === "object" ? value[key] : undefined;
    if (typeof value === "string" && value.length > 0) return value;
  }
  return undefined;
}

function larkEnvironment(profile) {
  return {
    ...process.env,
    LARKSUITE_CLI_PROFILE: profile,
    LARKSUITE_CLI_NO_UPDATE_NOTIFIER: "1",
    LARKSUITE_CLI_NO_SKILLS_NOTIFIER: "1",
  };
}

async function verifyBotIdentity(pairing) {
  const result = await runArgv(LARK_CLI, ["whoami", "--as", "bot"], { profile: pairing.app_profile });
  if (result.spawnError || result.timedOut || result.overflow || result.code !== 0) throw new Error("bot-identity-unavailable");
  const envelope = parseJsonEnvelope(result.stdout);
  if (envelope.ok !== true) throw new Error("bot-identity-envelope-not-ok");
  const data = envelope.data && typeof envelope.data === "object" ? envelope.data : envelope;
  const fromEither = (paths) => firstString(data, paths) ?? firstString(envelope, paths);
  const profile = fromEither([["profile"], ["app_profile"], ["appProfile"], ["identity", "profile"]]);
  const botOpenId = fromEither([["open_id"], ["openId"], ["bot_open_id"], ["bot", "open_id"], ["bot", "openId"], ["identity", "openId"], ["identities", "bot", "openId"]]);
  const appId = fromEither([["app_id"], ["appId"], ["app", "id"], ["identity", "appId"]]);
  if (profile !== pairing.app_profile || botOpenId !== pairing.bot_open_id) throw new Error("bot-identity-mismatch");
  if (pairing.app_id_fingerprint) {
    if (!appId) throw new Error("bot-app-id-unavailable");
    const fingerprint = `sha256:${createHash("sha256").update(appId).digest("hex")}`;
    if (fingerprint !== pairing.app_id_fingerprint) throw new Error("bot-app-fingerprint-mismatch");
  }
}

function parseJsonEnvelope(stdout) {
  let value;
  try {
    value = JSON.parse(stdout);
  } catch {
    throw new Error("malformed-json-envelope");
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("invalid-json-envelope");
  return value;
}

function runArgv(executable, args, { input, timeoutMs = COMMAND_TIMEOUT_MS, profile } = {}) {
  return new Promise((resolvePromise) => {
    let stdout = "";
    let stderr = "";
    let overflow = false;
    let timedOut = false;
    let spawnError = null;
    const child = spawn(executable, args, {
      cwd: ROOT,
      env: larkEnvironment(profile),
      stdio: ["pipe", "pipe", "pipe"],
    });
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGTERM");
    }, timeoutMs);
    timer.unref();
    child.stdout.on("data", (chunk) => {
      if (Buffer.byteLength(stdout, "utf8") + chunk.length > MAX_COMMAND_BYTES) {
        overflow = true;
        child.kill("SIGTERM");
        return;
      }
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      if (Buffer.byteLength(stderr, "utf8") + chunk.length > MAX_COMMAND_BYTES) {
        overflow = true;
        child.kill("SIGTERM");
        return;
      }
      stderr += chunk.toString();
    });
    child.on("error", (error) => { spawnError = error; });
    child.on("close", (code, signal) => {
      clearTimeout(timer);
      resolvePromise({ code: code ?? -1, signal, stdout, stderr, overflow, timedOut, spawnError });
    });
    if (input === undefined) child.stdin.end();
    else child.stdin.end(input);
  });
}

async function verifyP2pChat(pairing, binding) {
  const result = await runArgv(LARK_CLI, ["im", "chats", "get", "--chat-id", binding.chat_id, "--as", "bot", "--format", "json"], { profile: pairing.app_profile });
  if (result.spawnError || result.timedOut || result.overflow || result.code !== 0) throw new Error("chat-identity-unavailable");
  const envelope = parseJsonEnvelope(result.stdout);
  if (envelope.ok !== true) throw new Error("chat-identity-envelope-not-ok");
  const data = envelope.data && typeof envelope.data === "object" ? envelope.data : envelope;
  if (data.chat_mode !== "p2p" || (data.chat_status !== undefined && data.chat_status !== "normal") || (data.chat_id !== undefined && data.chat_id !== binding.chat_id)) throw new Error("configured-chat-is-not-p2p");
  return { chatId: binding.chat_id, chatMode: "p2p" };
}

function normalizeHistoryMessage(message, verifiedChat) {
  const sender = message?.sender && typeof message.sender === "object" ? message.sender : {};
  const senderId = message?.sender_id ?? sender.id ?? sender.open_id ?? sender.sender_id;
  let senderType = message?.sender_type ?? sender.type ?? sender.sender_type;
  if (senderType === "app" || senderType === "bot") senderType = "bot";
  else if (senderType === "user") senderType = "user";
  return {
    type: "im.message.receive_v1",
    event_id: `history:${message?.message_id ?? "unknown"}`,
    message_id: message?.message_id,
    sender_id: senderId,
    sender_type: senderType,
    chat_id: message?.chat_id ?? verifiedChat.chatId,
    chat_type: message?.chat_type ?? verifiedChat.chatMode,
    message_type: message?.msg_type ?? message?.message_type,
    content: message?.content,
    reply_to: message?.reply_to ?? message?.parent_id ?? null,
    root_id: message?.root_id ?? null,
    thread_id: message?.thread_id ?? null,
    create_time: message?.create_time ?? "0",
    update_time: message?.update_time ?? null,
    deleted: message?.deleted === true,
  };
}

async function readOverlappingHistory(binding, verifiedChat, sinceMs, profile) {
  const start = new Date(Math.max(0, sinceMs - HISTORY_OVERLAP_MS)).toISOString();
  const args = [
    "im", "+chat-messages-list",
    "--as", "bot",
    "--chat-id", binding.chat_id,
    "--start", start,
    "--order", "asc",
    "--page-all",
    "--page-limit", "10",
    "--no-reactions",
    "--format", "json",
  ];
  const result = await runArgv(LARK_CLI, args, { profile });
  if (result.spawnError || result.timedOut || result.overflow || result.code !== 0) {
    recordTransportDiagnostic(HOME, "history-failure", result.spawnError ? safeError(result.spawnError) : `exit=${result.code} timeout=${result.timedOut} overflow=${result.overflow}`);
    throw new Error("history-reconcile-failed");
  }
  const envelope = parseJsonEnvelope(result.stdout);
  if (Object.hasOwn(envelope, "ok") && envelope.ok !== true) throw new Error("history-envelope-not-ok");
  const data = envelope.data && typeof envelope.data === "object" ? envelope.data : envelope;
  const pagination = envelope.meta?.pagination;
  if (data.has_more === true || pagination?.complete === false || (typeof pagination?.next_token === "string" && pagination.next_token.length > 0)) {
    recordTransportDiagnostic(HOME, "history-incomplete", "history pagination remained incomplete at the configured page bound");
    throw new Error("history-reconcile-incomplete");
  }
  const messages = Array.isArray(data.messages) ? data.messages : [];
  const normalized = messages.map((message) => normalizeHistoryMessage(message, verifiedChat)).filter((message) => !message.deleted);
  let previousTime = -1;
  for (const message of normalized) {
    const time = Number(message.create_time);
    if (!Number.isSafeInteger(time) || time < 0 || time < previousTime) {
      recordTransportDiagnostic(HOME, "history-out-of-order", "history response was not a complete ascending sequence");
      throw new Error("history-reconcile-out-of-order");
    }
    previousTime = time;
  }
  return normalized;
}

function publishEvents(events, transport) {
  const ordered = [...events].sort((a, b) => {
    const time = Number(a.create_time ?? 0) - Number(b.create_time ?? 0);
    if (time !== 0) return time;
    return String(a.message_id ?? "").localeCompare(String(b.message_id ?? ""));
  });
  for (const event of ordered) publishFeishuInbound(HOME, event, { transport });
}

function parseDropDiagnostic(line) {
  return /\b(?:drop(?:ped)?|backpressure|buffer overflow|queue overflow)\b/i.test(line);
}

function parseStructuredError(stderr) {
  const lines = stderr.trim().split(/\r?\n/).reverse();
  for (const line of lines) {
    try {
      const value = JSON.parse(line);
      if (value?.ok === false && value.error && typeof value.error === "object") return value.error;
    } catch {}
  }
  return undefined;
}

function retryAfterMilliseconds(error) {
  const seconds = Number(error?.retry_after_seconds);
  if (Number.isFinite(seconds) && seconds >= 0 && seconds <= Number.MAX_SAFE_INTEGER / 1000) return Math.ceil(seconds * 1000);
  const milliseconds = Number(error?.retry_after_ms ?? error?.retryAfterMs);
  if (Number.isSafeInteger(milliseconds) && milliseconds >= 0) return milliseconds;
  return undefined;
}

async function sendOneOutbound(profile) {
  const claim = claimNextOutbound(HOME);
  if (!claim) return false;
  const args = claim.outbox.reply_to_message_id
    ? ["im", "+messages-reply", "--message-id", claim.outbox.reply_to_message_id]
    : ["im", "+messages-send", "--chat-id", claim.outbox.destination_chat_id];
  args.push("--text", claim.chunk.chunk, "--idempotency-key", claim.chunk.idempotency_key, "--as", "bot", "--format", "json");
  const result = await runArgv(LARK_CLI, args, { profile });
  if (result.spawnError || result.timedOut || result.overflow) {
    failOutboundAttempt(HOME, claim, safeError(result.spawnError) || "ambiguous-process-result", { ambiguous: true });
    return true;
  }
  if (result.code !== 0) {
    const error = parseStructuredError(result.stderr);
    const retryAfter = retryAfterMilliseconds(error);
    const type = typeof error?.type === "string" ? error.type : "lark-cli-error";
    const subtype = typeof error?.subtype === "string" ? error.subtype : "unknown";
    recordTransportDiagnostic(HOME, "outbound-failure", `${type}:${subtype}`);
    failOutboundAttempt(HOME, claim, `${type}:${subtype}`, {
      ambiguous: false,
      retryAfterMs: retryAfter,
    });
    if (type === "authorization" || type === "authentication") {
      writeTransportHealth(HOME, { phase: "degraded", healthy: false, lastErrorType: `${type}:${subtype}` });
    }
    return true;
  }
  let envelope;
  try {
    envelope = parseJsonEnvelope(result.stdout);
  } catch {
    failOutboundAttempt(HOME, claim, "ambiguous-success-malformed-envelope", { ambiguous: true });
    return true;
  }
  if (envelope.ok !== true) {
    failOutboundAttempt(HOME, claim, "ambiguous-success-envelope-not-ok", { ambiguous: true });
    return true;
  }
  const data = envelope.data && typeof envelope.data === "object" ? envelope.data : envelope;
  const messageId = data.message_id;
  const chatId = data.chat_id ?? claim.outbox.destination_chat_id;
  try {
    receiptOutbound(HOME, claim, { messageId, chatId });
  } catch {
    failOutboundAttempt(HOME, claim, "ambiguous-success-invalid-receipt", { ambiguous: true });
  }
  return true;
}

async function drainOutbound(profile) {
  for (let count = 0; count < 100 && !stopping; count += 1) {
    if (!(await sendOneOutbound(profile))) break;
  }
}

function drainOutboundSingleFlight(profile) {
  if (outboundDrainTask) return outboundDrainTask;
  outboundDrainTask = drainOutbound(profile).finally(() => { outboundDrainTask = null; });
  return outboundDrainTask;
}

function startConsumer(binding, verifiedChat, profile, reconnects) {
  return new Promise((resolvePromise) => {
    const child = spawn(LARK_CLI, ["event", "consume", "im.message.receive_v1", "--as", "bot"], {
      cwd: ROOT,
      env: larkEnvironment(profile),
      stdio: ["pipe", "pipe", "pipe"],
    });
    consumer = child;
    let ready = false;
    let reconciled = false;
    let closed = false;
    let drop = false;
    let overflow = false;
    let stdoutBuffer = "";
    let stderrBuffer = "";
    let liveBuffer = [];
    let liveBufferBytes = 0;
    let senderTimer = null;
    let reconcileTask = null;
    let reconcileError = null;
    const bindingTimer = setInterval(() => {
      try {
        const current = readActiveBinding(HOME);
        if (!current || current.status !== "active" || current.binding_id !== binding.binding_id || current.generation !== binding.generation) {
          recordTransportDiagnostic(HOME, "binding-changed", "binding generation changed; consumer stopping for controlled restart");
          child.stdin.end();
        }
      } catch {
        child.stdin.end();
      }
    }, 1000);
    bindingTimer.unref();
    const readyTimer = setTimeout(() => {
      if (!ready) {
        recordTransportDiagnostic(HOME, "ready-timeout", `ready marker absent after ${READY_TIMEOUT_MS}ms`);
        child.stdin.end();
        child.kill("SIGTERM");
      }
    }, READY_TIMEOUT_MS);
    readyTimer.unref();

    const finish = (result) => {
      if (closed) return;
      if (stdoutBuffer.trim()) {
        if (Buffer.byteLength(stdoutBuffer, "utf8") > MAX_CONSUMER_LINE_BYTES) requestReconcileRestart("overflow", "final event line exceeded the byte limit");
        else {
          try { acceptEvent(JSON.parse(stdoutBuffer)); }
          catch { recordTransportDiagnostic(HOME, "invalid-ndjson", "malformed final event line"); }
        }
        stdoutBuffer = "";
      }
      if (stderrBuffer.trim()) {
        if (Buffer.byteLength(stderrBuffer, "utf8") > MAX_CONSUMER_LINE_BYTES) requestReconcileRestart("overflow", "final diagnostic line exceeded the byte limit");
        else if (parseDropDiagnostic(stderrBuffer)) requestReconcileRestart("drop", stderrBuffer.trim());
      }
      stderrBuffer = "";
      closed = true;
      clearTimeout(readyTimer);
      clearInterval(bindingTimer);
      if (senderTimer) clearInterval(senderTimer);
      if (consumer === child) consumer = null;
      void Promise.resolve(reconcileTask).catch(() => {}).then(() => {
        if (!reconciled && liveBuffer.length > 0) {
          try { stageBuffered(); }
          catch (error) { recordTransportDiagnostic(HOME, "staging-failure", safeError(error)); }
        }
        resolvePromise({ ...result, drop, overflow, buffered: liveBuffer, reconcileError });
      });
    };

    const stageBuffered = () => {
      if (liveBuffer.length === 0) return;
      stageTransportEvents(HOME, liveBuffer, { maxEvents: MAX_BUFFERED_EVENTS * 10, maxBytes: MAX_LIVE_BUFFER_BYTES * 10 });
      liveBuffer = [];
      liveBufferBytes = 0;
    };

    const requestReconcileRestart = (kind, line) => {
      if (drop || overflow) return;
      if (kind === "drop") drop = true;
      else overflow = true;
      let stageFailure = null;
      try { stageBuffered(); }
      catch (error) { stageFailure = safeError(error); }
      recordTransportDiagnostic(HOME, kind === "drop" ? "drop" : "buffer-overflow", line);
      if (stageFailure) recordTransportDiagnostic(HOME, "staging-failure", stageFailure);
      writeTransportHealth(HOME, {
        phase: "degraded",
        healthy: false,
        reconnects,
        dropDiagnostics: Number(readTransportHealth(HOME)?.drop_diagnostics ?? 0) + 1,
        lastErrorType: stageFailure ? "staging-failure" : kind,
      });
      child.stdin.end();
    };

    const acceptEvent = (value) => {
      if (drop || overflow) return;
      if (!value || typeof value !== "object" || Array.isArray(value)) {
        recordTransportDiagnostic(HOME, "invalid-event", "non-object NDJSON event");
        return;
      }
      const eventBytes = Buffer.byteLength(JSON.stringify(value), "utf8");
      if (eventBytes > MAX_LIVE_BUFFER_BYTES) {
        requestReconcileRestart("overflow", `single event exceeded byte limit ${MAX_LIVE_BUFFER_BYTES}`);
        return;
      }
      if (reconciled) {
        publishFeishuInbound(HOME, value, { transport: "lark-websocket" });
        return;
      }
      if (liveBuffer.length >= MAX_BUFFERED_EVENTS || liveBufferBytes + eventBytes > MAX_LIVE_BUFFER_BYTES) {
        liveBuffer.push(value);
        liveBufferBytes += eventBytes;
        requestReconcileRestart("overflow", "buffer limit reached; events staged before ordered history reconciliation");
        return;
      }
      liveBuffer.push(value);
      liveBufferBytes += eventBytes;
    };

    child.stdout.on("data", (chunk) => {
      stdoutBuffer += chunk.toString();
      for (;;) {
        const index = stdoutBuffer.indexOf("\n");
        if (index < 0) break;
        const line = stdoutBuffer.slice(0, index);
        stdoutBuffer = stdoutBuffer.slice(index + 1);
        if (!line.trim()) continue;
        if (Buffer.byteLength(line, "utf8") > MAX_CONSUMER_LINE_BYTES) {
          requestReconcileRestart("overflow", `event line exceeded byte limit ${MAX_CONSUMER_LINE_BYTES}`);
          continue;
        }
        try { acceptEvent(JSON.parse(line)); }
        catch { recordTransportDiagnostic(HOME, "invalid-ndjson", "malformed event line"); }
      }
      if (Buffer.byteLength(stdoutBuffer, "utf8") > MAX_CONSUMER_LINE_BYTES) {
        stdoutBuffer = "";
        requestReconcileRestart("overflow", `unterminated event line exceeded byte limit ${MAX_CONSUMER_LINE_BYTES}`);
      }
    });

    child.stderr.on("data", (chunk) => {
      stderrBuffer += chunk.toString();
      for (;;) {
        const index = stderrBuffer.indexOf("\n");
        if (index < 0) break;
        const line = stderrBuffer.slice(0, index);
        stderrBuffer = stderrBuffer.slice(index + 1);
        if (Buffer.byteLength(line, "utf8") > MAX_CONSUMER_LINE_BYTES) {
          requestReconcileRestart("overflow", `diagnostic line exceeded byte limit ${MAX_CONSUMER_LINE_BYTES}`);
          continue;
        }
        if (line === READY_MARKER) {
          ready = true;
          clearTimeout(readyTimer);
          writeTransportHealth(HOME, {
            phase: "reconciling",
            healthy: false,
            reconnects,
            lastReadyAt: new Date().toISOString(),
            lastErrorType: null,
          });
          reconcileTask = (async () => {
            try {
              const previous = readTransportHealth(HOME);
              const sinceMs = previous?.last_reconcile_at ? Date.parse(String(previous.last_reconcile_at)) : Date.now() - HISTORY_OVERLAP_MS;
              const history = await readOverlappingHistory(binding, verifiedChat, Number.isFinite(sinceMs) ? sinceMs : Date.now() - HISTORY_OVERLAP_MS, profile);
              if (drop || overflow) throw new Error("live-buffer-integrity-lost-before-history-reconcile");
              const staged = readStagedTransportEvents(HOME);
              publishEvents([...history, ...staged.map((record) => record.event), ...liveBuffer], "lark-history-overlap");
              clearStagedTransportEvents(HOME, staged);
              liveBuffer = [];
              liveBufferBytes = 0;
              reconciled = true;
              writeTransportHealth(HOME, {
                phase: "healthy",
                healthy: true,
                reconnects,
                lastReadyAt: new Date().toISOString(),
                lastReconcileAt: new Date().toISOString(),
                lastErrorType: null,
              });
              await drainOutboundSingleFlight(profile);
              if (!closed) {
                senderTimer = setInterval(() => { void drainOutboundSingleFlight(profile); }, OUTBOX_POLL_MS);
                senderTimer.unref();
              }
            } catch (error) {
              reconcileError = String(error);
              recordTransportDiagnostic(HOME, "reconcile-failure", reconcileError);
              try { stageBuffered(); }
              catch (stageError) { recordTransportDiagnostic(HOME, "staging-failure", safeError(stageError)); }
              writeTransportHealth(HOME, { phase: "degraded", healthy: false, reconnects, lastErrorType: reconcileError });
              child.stdin.end();
            }
          })();
          continue;
        }
        if (parseDropDiagnostic(line)) requestReconcileRestart("drop", line);
        else if (/^\[event\] exited\b/.test(line)) recordTransportDiagnostic(HOME, "event-exit", line);
        else if (line.trim().startsWith("{")) {
          const error = parseStructuredError(line);
          recordTransportDiagnostic(HOME, "event-error", error ? `${error.type ?? "unknown"}:${error.subtype ?? "unknown"}` : "structured error");
        }
      }
      if (Buffer.byteLength(stderrBuffer, "utf8") > MAX_CONSUMER_LINE_BYTES) {
        stderrBuffer = "";
        requestReconcileRestart("overflow", `unterminated diagnostic line exceeded byte limit ${MAX_CONSUMER_LINE_BYTES}`);
      }
    });

    child.on("error", (error) => finish({ code: -1, signal: null, error: safeError(error), ready, reconciled }));
    child.on("close", (code, signal) => finish({ code: code ?? -1, signal, error: null, ready, reconciled }));
    if (stopping) child.stdin.end();
  });
}

async function runTransport({ once = false, daemon = false, maxCycles = 0 } = {}) {
  const { pairing, binding } = activeConfiguration();
  let verifiedChat;
  try {
    await verifyBotIdentity(pairing);
    verifiedChat = await verifyP2pChat(pairing, binding);
  } catch (error) {
    writeTransportHealth(HOME, {
      phase: "degraded",
      healthy: false,
      ownerPid: null,
      ownerNonce: null,
      ownerProcessStartToken: null,
      bindingId: null,
      bindingGeneration: null,
      lastErrorType: String(error),
    });
    throw error;
  }
  const nonce = randomBytes(24).toString("hex");
  const processStartToken = readProcessStartToken(process.pid);
  if (!processStartToken) throw new Error("transport process incarnation cannot be verified on this host");
  process.title = transportProcessTitle(nonce, HOME);
  const owner = claimTransportOwner(HOME, { nonce, moduleFile: realpathSync(MODULE_FILE), processStartToken });
  if (!owner.ok) throw new Error("another Feishu transport already owns this home");
  const healthFence = {
    ownerPid: process.pid,
    ownerNonce: nonce,
    ownerProcessStartToken: processStartToken,
    bindingId: binding.binding_id,
    bindingGeneration: binding.generation,
  };
  repairOutboundState(HOME);
  const stop = () => {
    stopping = true;
    if (consumer?.stdin && !consumer.stdin.destroyed) consumer.stdin.end();
  };
  process.once("SIGTERM", stop);
  process.once("SIGINT", stop);
  if (!daemon && !once && maxCycles === 0) {
    process.stdin.resume();
    process.stdin.once("end", stop);
  }
  let reconnects = 0;
  let cycles = 0;
  let delay = 250;
  try {
    writeTransportHealth(HOME, { ...healthFence, phase: "starting", healthy: false, reconnects });
    while (!stopping) {
      const current = activeConfiguration();
      if (current.binding.binding_id !== binding.binding_id || current.binding.generation !== binding.generation) {
        throw new Error("binding generation changed; restart transport under the new binding");
      }
      const result = await startConsumer(binding, verifiedChat, pairing.app_profile, reconnects);
      cycles += 1;
      if (result.reconcileError && once) throw new Error(result.reconcileError);
      if (stopping) break;
      writeTransportHealth(HOME, {
        phase: "degraded",
        healthy: false,
        ownerPid: process.pid,
        reconnects,
        lastErrorType: result.error ?? `consumer-exit-${result.code}`,
      });
      if (once || (maxCycles > 0 && cycles >= maxCycles)) break;
      reconnects += 1;
      await sleep(delay);
      delay = Math.min(10000, delay * 2);
    }
  } finally {
    writeTransportHealth(HOME, { ...healthFence, phase: "stopped", healthy: false, reconnects, lastErrorType: null });
    releaseTransportOwner(HOME, nonce);
  }
}

function readProcessStartToken(pid) {
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
    const suffix = stat.slice(stat.lastIndexOf(")") + 2).trim().split(/\s+/);
    return /^[0-9]+$/.test(suffix[19] ?? "") ? suffix[19] : "";
  } catch {
    return "";
  }
}

function processCommandLine(pid) {
  try {
    const path = `/proc/${pid}/cmdline`;
    if (existsSync(path)) return readFileSync(path, "utf8").split("\0").filter(Boolean);
  } catch {}
  return [];
}

function transportProcessTitle(nonce, home) {
  const homeHash = createHash("sha256").update(home).digest("hex").slice(0, 16);
  return `fm-feishu-${homeHash}-${nonce}`;
}

function ownerLooksLive(owner) {
  const pid = Number(owner?.pid);
  if (!Number.isSafeInteger(pid) || pid <= 1 || owner?.home_realpath !== HOME || owner?.module_file !== realpathSync(MODULE_FILE)) return false;
  try { process.kill(pid, 0); } catch { return false; }
  const command = processCommandLine(pid);
  const startToken = readProcessStartToken(pid);
  if (command.length !== 1 || command[0] !== transportProcessTitle(owner.nonce, HOME) || !startToken || startToken !== owner.process_start_token) return false;
  return true;
}

async function startDetached() {
  activeConfiguration();
  const existing = readTransportOwner(HOME);
  if (existing && ownerLooksLive(existing)) {
    process.stdout.write("feishu transport already running\n");
    return;
  }
  const child = spawn(process.execPath, [realpathSync(MODULE_FILE), "run", "--daemon"], {
    cwd: ROOT,
    env: { ...process.env, FM_HOME: HOME, FM_ROOT_OVERRIDE: ROOT },
    detached: true,
    stdio: "ignore",
  });
  child.unref();
  for (let attempt = 0; attempt < 100; attempt += 1) {
    await sleep(50);
    const owner = readTransportOwner(HOME);
    if (owner && owner.pid === child.pid && ownerLooksLive(owner)) {
      process.stdout.write("feishu transport started\n");
      return;
    }
    if (child.exitCode !== null) break;
  }
  throw new Error("Feishu transport did not publish a live owner record");
}

async function stopOwned() {
  const owner = readTransportOwner(HOME);
  if (!owner) {
    process.stdout.write("feishu transport already stopped\n");
    return;
  }
  if (!ownerLooksLive(owner)) {
    writeTransportHealth(HOME, { phase: "stopped", healthy: false, lastErrorType: "stale-owner" });
    process.stdout.write("feishu transport owner was stale; no process was signalled\n");
    return;
  }
  process.kill(Number(owner.pid), "SIGTERM");
  for (let attempt = 0; attempt < 100; attempt += 1) {
    await sleep(50);
    try { process.kill(Number(owner.pid), 0); }
    catch {
      process.stdout.write("feishu transport stopped\n");
      return;
    }
  }
  throw new Error("Feishu transport did not stop after SIGTERM; it was not force-killed");
}

function usage() {
  return "usage: fm-feishu-transport.sh start|stop|restart|status|run [--once]";
}

async function main(argv) {
  const command = argv.shift();
  if (command === "start") return startDetached();
  if (command === "stop") return stopOwned();
  if (command === "restart") {
    await stopOwned();
    return startDetached();
  }
  if (command === "status") {
    const full = argv.includes("--full") ? statusSummary(HOME) : publicStatusSummary(HOME);
    process.stdout.write(`${JSON.stringify(full)}\n`);
    return;
  }
  if (command === "run") {
    const maxCyclesIndex = argv.indexOf("--max-cycles");
    const maxCycles = maxCyclesIndex >= 0 ? positiveInteger(argv[maxCyclesIndex + 1], 0) : 0;
    return runTransport({
      once: argv.includes("--once"),
      daemon: argv.includes("--daemon"),
      maxCycles,
    });
  }
  throw new Error(usage());
}

main(process.argv.slice(2)).catch((error) => {
  process.stderr.write(`fm-feishu-transport: ${error.message}\n`);
  process.exitCode = 2;
});
