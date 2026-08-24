#!/usr/bin/env node
// Dedicated no-Agent Feishu transport.
//
// The transport uses the official Feishu Node SDK for one long-connection
// event client, the SDK's resource API for authorized inbound image
// downloads, and the SDK's message APIs for durable outbound delivery.
// It never starts Pi, imports an Agent SDK, writes a Pi session, evaluates
// message text, opens a webhook, or invokes an operator command.
// FM_FEISHU_RECOVERY_TIMEOUT_MS sets the one-episode reconnect deadline in
// positive integer milliseconds; the default is 300000.
import { spawn, spawnSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  assertManualRebindSafe,
  claimNextOutbound,
  claimTransportOwner,
  cleanupFeishuMedia,
  completeFeishuMediaDownload,
  configuredSessionMatches,
  convergeConfiguredSession,
  disablePairing,
  failFeishuMediaDownload,
  failOutboundAttempt,
  publicStatusSummary,
  pendingFeishuMedia,
  publishFeishuInbound,
  readActiveBinding,
  readPairing,
  readTransportOwner,
  receiptOutbound,
  recordTransportDiagnostic,
  releaseTransportOwner,
  repairOutboundState,
  retireStaleTransportOwner,
  statusSummary,
  transportHealthAllowsDispatch,
  writeTransportHealth,
} from "./fm-feishu-state.mjs";
import { disableFeishuConfig, readFeishuConfig } from "./fm-feishu-config.mjs";

const MODULE_FILE = fileURLToPath(import.meta.url);
const ROOT = resolve(dirname(MODULE_FILE), "..");
const HOME = realpathSync(process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || ROOT);
const OFFICIAL_SDK = "@larksuiteoapi/node-sdk";
const SDK_MODULE = process.env.FM_FEISHU_SDK_MODULE || OFFICIAL_SDK;
const READY_TIMEOUT_MS = positiveInteger(process.env.FM_FEISHU_READY_TIMEOUT_MS, 30000);
const RECOVERY_TIMEOUT_MS = positiveInteger(process.env.FM_FEISHU_RECOVERY_TIMEOUT_MS, 5 * 60 * 1000);
const COMMAND_TIMEOUT_MS = positiveInteger(process.env.FM_FEISHU_COMMAND_TIMEOUT_MS, 30000);
const OUTBOX_POLL_MS = positiveInteger(process.env.FM_FEISHU_OUTBOX_POLL_MS, 500);
const BINDING_POLL_MS = positiveInteger(process.env.FM_FEISHU_BINDING_POLL_MS, 1000);
const ONCE_SETTLE_MS = positiveInteger(process.env.FM_FEISHU_ONCE_SETTLE_MS, 50);
const SILENT = process.env.FM_FEISHU_SILENT === "1";
const LOCK_STATUS_SCRIPT = process.env.FM_FEISHU_LOCK_STATUS_SCRIPT || resolve(ROOT, "bin/fm-session-lock-status.sh");
let stopping = false;
let sdkClient = null;
let wsClient = null;
let outboundDrainTask = null;
let mediaDrainTask = null;

function positiveInteger(value, fallback) {
  const number = Number(value);
  return Number.isSafeInteger(number) && number > 0 ? number : fallback;
}

function sleep(ms) {
  return new Promise((resolvePromise) => setTimeout(resolvePromise, ms));
}

function deferred() {
  let resolvePromise;
  let rejectPromise;
  const promise = new Promise((resolve, reject) => {
    resolvePromise = resolve;
    rejectPromise = reject;
  });
  return { promise, resolve: resolvePromise, reject: rejectPromise };
}

function appFingerprint(appId) {
  return `sha256:${createHash("sha256").update(appId).digest("hex")}`;
}

function transportError(kind) {
  if (!/^[a-z0-9-]{1,80}$/.test(kind)) throw new Error("invalid transport error kind");
  const error = new Error(kind);
  error.transportErrorKind = kind;
  return error;
}

function activeConfiguration() {
  const pairing = readPairing(HOME);
  const binding = readActiveBinding(HOME);
  if (!pairing || pairing.disabled_at !== null) throw transportError("pairing-inactive");
  if (!binding || binding.status !== "active") throw transportError("binding-inactive");
  if (pairing.fm_home_realpath !== HOME || binding.fm_home_realpath !== HOME || pairing.home_id !== binding.home_id) {
    throw transportError("binding-home-mismatch");
  }
  if (pairing.allowed_chats.length !== 1 || pairing.allowed_users.length !== 1 || binding.chat_id !== pairing.allowed_chats[0]) {
    throw transportError("binding-identity-mismatch");
  }
  return { pairing, binding };
}

function directAppCredentials(pairing) {
  const appId = String(process.env.FM_FEISHU_APP_ID || "");
  const appSecret = String(process.env.FM_FEISHU_APP_SECRET || "");
  if (!/^cli_[A-Za-z0-9_-]{8,128}$/.test(appId) || !/^[A-Za-z0-9._~+/=-]{8,4096}$/.test(appSecret)) {
    throw transportError("sdk-credentials-unavailable");
  }
  if (appFingerprint(appId) !== pairing.app_id_fingerprint) throw transportError("sdk-app-fingerprint-mismatch");
  return { appId, appSecret };
}

function environmentAppCredentials() {
  const appId = String(process.env.FM_FEISHU_APP_ID || "");
  const appSecret = String(process.env.FM_FEISHU_APP_SECRET || "");
  if (!/^cli_[A-Za-z0-9_-]{8,128}$/.test(appId) || !/^[A-Za-z0-9._~+/=-]{8,4096}$/.test(appSecret)) {
    throw new Error("direct SDK app credentials are unavailable or malformed");
  }
  return { appId, appSecret };
}

function loadConfiguredCredentials(config) {
  process.env.FM_FEISHU_APP_ID = config.appId;
  process.env.FM_FEISHU_APP_SECRET = config.appSecret;
  process.env.FM_FEISHU_P2P_CHAT_ID = config.p2pChatId;
  process.env.FM_FEISHU_CONFIG_IDENTITY = config.fileIdentity;
}

function loadConfiguredCredentialsIfNeeded() {
  const config = readFeishuConfig(HOME);
  if (config.status === "enabled") loadConfiguredCredentials(config);
  return config;
}

function silentSdkLogger() {
  return {
    error() {},
    warn() {},
    info() {},
    debug() {},
    trace() {},
  };
}

async function loadSdk() {
  if (SDK_MODULE !== OFFICIAL_SDK && process.env.FM_FEISHU_SDK_TEST_MODE !== "1") {
    throw new Error("alternate Feishu SDK modules are test-only");
  }
  let imported;
  try {
    const specifier = SDK_MODULE.startsWith("/") ? pathToFileURL(SDK_MODULE).href : SDK_MODULE;
    imported = await import(specifier);
  } catch {
    throw new Error("official Feishu Node SDK is unavailable");
  }
  const sdk = imported.default && typeof imported.default === "object" ? imported.default : imported;
  if (typeof sdk.Client !== "function" || typeof sdk.WSClient !== "function" || typeof sdk.EventDispatcher !== "function") {
    throw new Error("official Feishu Node SDK surface is unavailable");
  }
  return sdk;
}

function assertOwnerAndBinding(binding, ownerFence) {
  const current = activeConfiguration();
  const owner = readTransportOwner(HOME);
  if (current.binding.binding_id !== binding.binding_id || current.binding.generation !== binding.generation) {
    throw transportError("binding-generation-changed");
  }
  if (!owner || owner.pid !== ownerFence.ownerPid || owner.nonce !== ownerFence.ownerNonce || owner.process_start_token !== ownerFence.ownerProcessStartToken) {
    throw transportError("transport-owner-changed");
  }
  directAppCredentials(current.pairing);
  return current;
}

async function verifyP2pChat(client, binding) {
  let result;
  try {
    result = await client.im.v1.chat.get({ path: { chat_id: binding.chat_id } }, { timeout: COMMAND_TIMEOUT_MS });
  } catch (error) {
    throw transportError(sdkErrorType(error, "chat-identity-unavailable"));
  }
  if (!result || result.code !== 0 || !result.data || result.data.chat_mode !== "p2p") throw transportError("configured-chat-is-not-p2p");
  return { chatId: binding.chat_id, chatMode: "p2p" };
}

function normalizeSdkEvent(data, expectedAppId) {
  if (!data || typeof data !== "object" || Array.isArray(data)) throw new Error("invalid SDK event envelope");
  if (data.app_id !== undefined && data.app_id !== expectedAppId) throw new Error("SDK event app identity mismatch");
  if (data.event_id !== undefined && (typeof data.event_id !== "string" || Buffer.byteLength(data.event_id, "utf8") > 512)) {
    throw new Error("invalid SDK event identity");
  }
  const sender = data.sender && typeof data.sender === "object" ? data.sender : {};
  const senderId = sender.sender_id && typeof sender.sender_id === "object" ? sender.sender_id.open_id : undefined;
  const message = data.message && typeof data.message === "object" ? data.message : {};
  let parsed;
  if (typeof message.content === "string") {
    try { parsed = JSON.parse(message.content); } catch {}
  }
  let content = "";
  if (message.message_type === "text" && parsed && typeof parsed === "object" && !Array.isArray(parsed) && typeof parsed.text === "string") {
    content = parsed.text;
  } else if (message.message_type === "image" && parsed && typeof parsed === "object" && !Array.isArray(parsed) && typeof parsed.image_key === "string") {
    content = [{ type: "image", resource_key: parsed.image_key }];
  } else if (message.message_type === "post") {
    try {
      content = normalizeSdkPostContent(parsed);
    } catch {
      content = "";
    }
  }
  return {
    type: "im.message.receive_v1",
    event_id: data.event_id,
    message_id: message.message_id,
    sender_id: senderId,
    sender_type: sender.sender_type,
    chat_id: message.chat_id,
    chat_type: message.chat_type,
    message_type: message.message_type,
    content,
    content_size_bytes: typeof message.content === "string" ? Buffer.byteLength(message.content, "utf8") : null,
    reply_to: message.parent_id ?? null,
    root_id: message.root_id ?? null,
    thread_id: message.thread_id ?? null,
    create_time: message.create_time,
    update_time: message.update_time ?? null,
  };
}

function postLocaleBody(parsed) {
  if (Array.isArray(parsed.content)) return parsed;
  const keys = Object.keys(parsed).sort();
  const ordered = keys.includes("zh_cn") ? ["zh_cn", ...keys.filter((key) => key !== "zh_cn")] : keys;
  for (const key of ordered) {
    const value = parsed[key];
    if (value && typeof value === "object" && !Array.isArray(value) && Array.isArray(value.content)) return value;
  }
  return null;
}

function normalizeSdkPostContent(parsed) {
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return [];
  const body = postLocaleBody(parsed);
  if (!body) return [];
  const parts = [];
  const appendText = (text) => {
    if (typeof text !== "string") throw new Error("unsupported Feishu post element");
    const previous = parts.at(-1);
    if (previous?.type === "text") previous.text += text;
    else parts.push({ type: "text", text });
  };
  if (typeof body.title === "string" && body.title.length > 0) appendText(`${body.title}\n`);
  for (let paragraphIndex = 0; paragraphIndex < body.content.length; paragraphIndex += 1) {
    const paragraph = body.content[paragraphIndex];
    if (!Array.isArray(paragraph)) throw new Error("unsupported Feishu post structure");
    if (paragraphIndex > 0) appendText("\n");
    for (const element of paragraph) {
      if (!element || typeof element !== "object" || Array.isArray(element)) throw new Error("unsupported Feishu post element");
      if (element.tag === "text") appendText(element.text);
      else if (element.tag === "img" && typeof element.image_key === "string") parts.push({ type: "image", resource_key: element.image_key });
      else parts.push({ type: "unsupported", media_type: typeof element.tag === "string" ? element.tag : "unknown" });
    }
  }
  return parts;
}

function sdkErrorType(error, fallback = "sdk-error") {
  if (typeof error?.transportErrorKind === "string" && /^[a-z0-9-]{1,80}$/.test(error.transportErrorKind)) {
    return error.transportErrorKind;
  }
  const status = Number(error?.response?.status);
  const code = Number(error?.response?.data?.code ?? error?.code);
  if (Number.isSafeInteger(status) && status >= 100 && status <= 599) return `sdk-http-${status}`;
  if (Number.isSafeInteger(code) && code >= 0) return `sdk-code-${code}`;
  const structuralCode = typeof error?.code === "string" ? error.code.toUpperCase() : "";
  const structuralKinds = {
    ECONNRESET: "sdk-connection-reset",
    ECONNREFUSED: "sdk-connection-refused",
    ETIMEDOUT: "sdk-connection-timeout",
    EPIPE: "sdk-connection-closed",
    ENOTFOUND: "sdk-dns-unavailable",
    EAI_AGAIN: "sdk-dns-unavailable",
    ERR_NETWORK: "sdk-network-error",
    UND_ERR_CONNECT_TIMEOUT: "sdk-connection-timeout",
  };
  if (structuralKinds[structuralCode]) return structuralKinds[structuralCode];
  if (error?.request && !error?.response) return "sdk-network-no-response";
  return fallback;
}

function retryAfterMilliseconds(error) {
  const headers = error?.response?.headers;
  const raw = headers && typeof headers === "object" ? headers["retry-after"] ?? headers["Retry-After"] : undefined;
  const seconds = Number(raw);
  if (Number.isFinite(seconds) && seconds >= 0 && seconds <= Number.MAX_SAFE_INTEGER / 1000) return Math.ceil(seconds * 1000);
  if (typeof raw === "string") {
    const date = Date.parse(raw);
    if (Number.isFinite(date) && date >= Date.now()) return Math.min(Number.MAX_SAFE_INTEGER, Math.ceil(date - Date.now()));
  }
  return undefined;
}

function sdkFailureIsAmbiguous(error) {
  return Boolean(error?.request) && !error?.response;
}

function sdkFailureIsAuthentication(error) {
  const status = Number(error?.response?.status);
  return status === 401 || status === 403;
}

function sdkConnectionFailureIsTerminal(error) {
  return sdkFailureIsAuthentication(error);
}

function headerValue(headers, name) {
  if (!headers || typeof headers !== "object") return "";
  const value = headers[name] ?? headers[name.toLowerCase()] ?? headers[name.toUpperCase()];
  const text = Array.isArray(value) ? value[0] : value;
  return typeof text === "string" ? text.split(";", 1)[0].trim().toLowerCase() : "";
}

function imageMime(bytes) {
  if (bytes.length >= 8 && bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) return "image/png";
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return "image/jpeg";
  if (bytes.length >= 6 && (bytes.subarray(0, 6).toString("ascii") === "GIF87a" || bytes.subarray(0, 6).toString("ascii") === "GIF89a")) return "image/gif";
  if (bytes.length >= 12 && bytes.subarray(0, 4).toString("ascii") === "RIFF" && bytes.subarray(8, 12).toString("ascii") === "WEBP") return "image/webp";
  return "";
}

async function boundedResourceBytes(response, maxBytes) {
  if (!response || typeof response.getReadableStream !== "function") throw new Error("sdk-media-response-malformed");
  const stream = response.getReadableStream();
  if (!stream || typeof stream[Symbol.asyncIterator] !== "function") throw new Error("sdk-media-stream-malformed");
  const chunks = [];
  let length = 0;
  for await (const chunk of stream) {
    const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    length += bytes.length;
    if (length > maxBytes) {
      stream.destroy?.();
      throw new Error("media-object-overlength");
    }
    chunks.push(bytes);
  }
  if (length === 0) throw new Error("media-empty-response");
  return Buffer.concat(chunks, length);
}

async function downloadOneMedia(client, claim, binding, ownerFence) {
  assertOwnerAndBinding(binding, ownerFence);
  const maxBytes = positiveInteger(process.env.FM_FEISHU_MAX_INBOUND_MEDIA_BYTES, 10 * 1024 * 1024);
  let response;
  try {
    response = await client.im.v1.messageResource.get({
      params: { type: claim.resource_type },
      path: { message_id: claim.message_id, file_key: claim.resource_key },
    }, { timeout: COMMAND_TIMEOUT_MS });
    const responseMimeType = headerValue(response.headers, "content-type");
    const bytes = await boundedResourceBytes(response, maxBytes);
    const actualMimeType = imageMime(bytes);
    if (!actualMimeType) throw new Error("media-signature-unsupported");
    completeFeishuMediaDownload(HOME, claim, bytes, {
      declaredResourceType: claim.resource_type,
      responseMimeType,
      actualMimeType,
    }, {
      ownerNonce: ownerFence.ownerNonce,
      bindingId: binding.binding_id,
      bindingGeneration: binding.generation,
      sessionId: binding.session_id,
    }, { maxMediaBytes: maxBytes });
    assertOwnerAndBinding(binding, ownerFence);
  } catch (error) {
    const kind = error?.message === "Feishu media content type mismatch"
      ? "media-content-type-mismatch"
      : error?.message === "Feishu media message exceeded its byte limit"
        ? "media-message-overlength"
      : typeof error?.message === "string" && /^media-[a-z0-9-]+$/.test(error.message)
        ? error.message
        : sdkErrorType(error, "media-download-failed");
    const terminal = new Set(["media-object-overlength", "media-message-overlength", "media-empty-response", "media-signature-unsupported", "media-content-type-mismatch"]).has(kind) || /^sdk-http-4(?!29)/.test(kind);
    failFeishuMediaDownload(HOME, claim, kind, { ownerNonce: ownerFence.ownerNonce }, { terminal, retryAfterMs: retryAfterMilliseconds(error) });
    recordTransportDiagnostic(HOME, "inbound-media-failure", kind);
    if (sdkFailureIsAuthentication(error)) throw transportError("inbound-media-sdk-authentication-failed");
  }
}

async function drainInboundMedia(client, binding, ownerFence) {
  if (!transportHealthAllowsDispatch(HOME, binding)) return;
  cleanupFeishuMedia(HOME);
  const claims = pendingFeishuMedia(HOME, {
    ownerNonce: ownerFence.ownerNonce,
    bindingId: binding.binding_id,
    bindingGeneration: binding.generation,
    sessionId: binding.session_id,
  });
  for (const claim of claims) await downloadOneMedia(client, claim, binding, ownerFence);
}

function drainInboundMediaSingleFlight(client, binding, ownerFence) {
  if (mediaDrainTask) return mediaDrainTask;
  mediaDrainTask = drainInboundMedia(client, binding, ownerFence).finally(() => { mediaDrainTask = null; });
  return mediaDrainTask;
}

function renderMarkdownPost(markdown) {
  return JSON.stringify({
    zh_cn: {
      title: "",
      content: [[{ tag: "md", text: markdown }]],
    },
  });
}

async function sendOneOutbound(client, binding, ownerFence) {
  if (!transportHealthAllowsDispatch(HOME, binding)) return false;
  assertOwnerAndBinding(binding, ownerFence);
  const claim = claimNextOutbound(HOME);
  if (!claim) return false;
  const payload = {
    data: {
      receive_id: claim.outbox.destination_chat_id,
      content: renderMarkdownPost(claim.chunk.chunk),
      msg_type: "post",
      uuid: claim.chunk.idempotency_key,
    },
    params: { receive_id_type: "chat_id" },
  };
  let response;
  try {
    response = await client.im.v1.message.create(payload, { timeout: COMMAND_TIMEOUT_MS });
  } catch (error) {
    const errorType = sdkErrorType(error);
    failOutboundAttempt(HOME, claim, errorType, {
      ambiguous: sdkFailureIsAmbiguous(error),
      retryAfterMs: retryAfterMilliseconds(error),
    });
    recordTransportDiagnostic(HOME, "outbound-failure", errorType);
    if (sdkFailureIsAuthentication(error)) throw transportError("outbound-sdk-authentication-failed");
    return true;
  }
  if (!response || response.code !== 0) {
    const code = Number(response?.code);
    const errorType = Number.isSafeInteger(code) ? `sdk-code-${code}` : "sdk-response-malformed";
    failOutboundAttempt(HOME, claim, errorType, { ambiguous: !Number.isSafeInteger(code) });
    recordTransportDiagnostic(HOME, "outbound-failure", errorType);
    return true;
  }
  const messageId = response.data?.message_id;
  const chatId = response.data?.chat_id;
  try {
    receiptOutbound(HOME, claim, { messageId, chatId });
  } catch {
    failOutboundAttempt(HOME, claim, "sdk-success-invalid-receipt", { ambiguous: true });
  }
  return true;
}

async function drainOutbound(client, binding, ownerFence) {
  for (let count = 0; count < 100 && !stopping; count += 1) {
    if (!(await sendOneOutbound(client, binding, ownerFence))) break;
  }
}

function drainOutboundSingleFlight(client, binding, ownerFence) {
  if (outboundDrainTask) return outboundDrainTask;
  outboundDrainTask = drainOutbound(client, binding, ownerFence).finally(() => { outboundDrainTask = null; });
  return outboundDrainTask;
}

async function runTransport({ once = false, daemon = false } = {}) {
  const initial = activeConfiguration();
  const credentials = directAppCredentials(initial.pairing);
  const nonce = randomBytes(24).toString("hex");
  const processStartToken = readProcessStartToken(process.pid);
  if (!processStartToken) throw new Error("transport process incarnation cannot be verified on this host");
  process.title = transportProcessTitle(nonce, HOME);
  const owner = claimTransportOwner(HOME, {
    nonce,
    moduleFile: realpathSync(MODULE_FILE),
    processStartToken,
    configFileIdentity: process.env.FM_FEISHU_CONFIG_IDENTITY || undefined,
  });
  if (!owner.ok) throw new Error("another Feishu transport already owns this home");
  const ownerFence = {
    ownerPid: process.pid,
    ownerNonce: nonce,
    ownerProcessStartToken: processStartToken,
  };
  const healthFence = {
    ...ownerFence,
    bindingId: initial.binding.binding_id,
    bindingGeneration: initial.binding.generation,
  };
  const ready = deferred();
  const fatal = deferred();
  const fatalFailure = () => fatal.promise.then((error) => { throw error; });
  const stopped = deferred();
  let terminalError = null;
  let readySettled = false;
  let fatalSettled = false;
  let reconnects = 0;
  let bindingTimer = null;
  let senderTimer = null;
  let keepAliveTimer = null;
  let readyTimer = null;
  let recoveryTimer = null;
  let recoveryErrorType = null;
  let connectionEpoch = 0;
  let verificationRequestedEpoch = null;
  let verificationTask = null;

  const clearConnectionTimers = () => {
    if (readyTimer) clearTimeout(readyTimer);
    if (recoveryTimer) clearTimeout(recoveryTimer);
    readyTimer = null;
    recoveryTimer = null;
  };
  const stop = () => {
    if (stopping) return;
    stopping = true;
    clearConnectionTimers();
    try { wsClient?.close(); } catch {}
    stopped.resolve();
  };
  const fail = (error, fallback = "sdk-long-connection-failed") => {
    if (fatalSettled) return;
    fatalSettled = true;
    terminalError = sdkErrorType(error, fallback);
    try { writeTransportHealth(HOME, { ...healthFence, phase: "degraded", healthy: false, reconnects, lastErrorType: terminalError }); } catch {}
    fatal.resolve(new Error(terminalError));
    stop();
  };
  const beginRecovery = (errorType) => {
    if (stopping || fatalSettled) return;
    connectionEpoch += 1;
    verificationRequestedEpoch = null;
    recoveryErrorType = errorType || recoveryErrorType || "sdk-connection-lost";
    if (readyTimer) {
      clearTimeout(readyTimer);
      readyTimer = null;
    }
    try {
      writeTransportHealth(HOME, {
        ...healthFence,
        phase: "reconnecting",
        healthy: false,
        reconnects,
        lastErrorType: recoveryErrorType,
      });
    } catch (error) {
      fail(error, "transport-health-write-failed");
      return;
    }
    if (!recoveryTimer) {
      recoveryTimer = setTimeout(() => fail(transportError("sdk-recovery-timeout")), RECOVERY_TIMEOUT_MS);
    }
  };
  const handleConnectionError = (error) => {
    if (stopping || fatalSettled) return;
    const errorType = sdkErrorType(error, "sdk-long-connection-error");
    try { recordTransportDiagnostic(HOME, "sdk-connection-error", errorType); } catch (diagnosticError) {
      fail(diagnosticError, "transport-diagnostic-write-failed");
      return;
    }
    if (sdkConnectionFailureIsTerminal(error)) {
      fail(transportError(errorType));
      return;
    }
    beginRecovery(errorType);
  };
  const verifyConnectedIdentity = () => {
    verificationRequestedEpoch = connectionEpoch;
    if (verificationTask) return verificationTask;
    verificationTask = (async () => {
      while (verificationRequestedEpoch !== null && !stopping && !fatalSettled) {
        const verificationEpoch = verificationRequestedEpoch;
        verificationRequestedEpoch = null;
        const current = assertOwnerAndBinding(initial.binding, ownerFence);
        await verifyP2pChat(sdkClient, current.binding);
        if (verificationEpoch !== connectionEpoch || stopping || fatalSettled) continue;
        assertOwnerAndBinding(initial.binding, ownerFence);
        clearConnectionTimers();
        recoveryErrorType = null;
        writeTransportHealth(HOME, {
          ...healthFence,
          phase: "healthy",
          healthy: true,
          reconnects,
          lastConnectedAt: new Date().toISOString(),
          lastIdentityVerifiedAt: new Date().toISOString(),
          lastErrorType: null,
        });
        if (!readySettled) {
          readySettled = true;
          ready.resolve();
        }
        await drainInboundMediaSingleFlight(sdkClient, initial.binding, ownerFence);
        await drainOutboundSingleFlight(sdkClient, initial.binding, ownerFence);
      }
    })().catch((error) => fail(error, "connection-identity-verification-failed")).finally(() => {
      verificationTask = null;
      if (verificationRequestedEpoch !== null && !stopping && !fatalSettled) void verifyConnectedIdentity();
    });
    return verificationTask;
  };

  process.once("SIGTERM", stop);
  process.once("SIGINT", stop);
  if (!daemon && !once) {
    process.stdin.resume();
    process.stdin.once("end", stop);
  }

  try {
    repairOutboundState(HOME);
    writeTransportHealth(HOME, { ...healthFence, phase: "starting", healthy: false, reconnects, lastErrorType: null });
    const sdk = await loadSdk();
    const sdkOptions = {
      appId: credentials.appId,
      appSecret: credentials.appSecret,
      domain: sdk.Domain?.Feishu,
      logger: silentSdkLogger(),
      loggerLevel: sdk.LoggerLevel?.error,
      source: "firstmate-feishu",
    };
    sdkClient = new sdk.Client(sdkOptions);
    await verifyP2pChat(sdkClient, initial.binding);
    assertOwnerAndBinding(initial.binding, ownerFence);
    const eventDispatcher = new sdk.EventDispatcher({}).register({
      "im.message.receive_v1": async (data) => {
        try {
          if (stopping) throw new Error("transport is stopping");
          const current = assertOwnerAndBinding(initial.binding, ownerFence);
          const normalized = normalizeSdkEvent(data, credentials.appId);
          publishFeishuInbound(HOME, normalized, {
            transport: "feishu-sdk-long-connection",
            bindingFence: {
              bindingId: current.binding.binding_id,
              bindingGeneration: current.binding.generation,
              sessionId: current.binding.session_id,
              chatId: current.binding.chat_id,
            },
          });
          assertOwnerAndBinding(initial.binding, ownerFence);
          await drainInboundMediaSingleFlight(sdkClient, initial.binding, ownerFence);
        } catch (error) {
          try { recordTransportDiagnostic(HOME, "sdk-event-refused", sdkErrorType(error, "sdk-event-handoff-failed")); } catch {}
          fail(error, "sdk-event-handoff-failed");
          throw error;
        }
      },
    });
    wsClient = new sdk.WSClient({
      ...sdkOptions,
      autoReconnect: true,
      handshakeTimeoutMs: READY_TIMEOUT_MS,
      wsConfig: { pingTimeout: Math.max(1, Math.ceil(READY_TIMEOUT_MS / 1000)) },
      onReady: () => { void verifyConnectedIdentity(); },
      onError: handleConnectionError,
      onReconnecting: () => {
        reconnects += 1;
        beginRecovery(recoveryErrorType || "sdk-connection-lost");
      },
      onReconnected: () => { void verifyConnectedIdentity(); },
    });
    bindingTimer = setInterval(() => {
      try { assertOwnerAndBinding(initial.binding, ownerFence); }
      catch (error) { fail(error, "binding-or-owner-fence-changed"); }
    }, BINDING_POLL_MS);
    bindingTimer.unref();
    writeTransportHealth(HOME, { ...healthFence, phase: "connecting", healthy: false, reconnects, lastErrorType: null });
    readyTimer = setTimeout(() => fail(transportError("sdk-ready-timeout")), READY_TIMEOUT_MS);
    await wsClient.start({ eventDispatcher });
    await Promise.race([ready.promise, fatalFailure(), stopped.promise]);
    if (fatalSettled) throw transportError(terminalError);
    if (stopping) return;
    senderTimer = setInterval(() => {
      void drainInboundMediaSingleFlight(sdkClient, initial.binding, ownerFence).catch(fail);
      void drainOutboundSingleFlight(sdkClient, initial.binding, ownerFence).catch(fail);
    }, OUTBOX_POLL_MS);
    senderTimer.unref();
    if (daemon) keepAliveTimer = setInterval(() => {}, 60000);
    if (once) {
      await sleep(ONCE_SETTLE_MS);
      await drainOutboundSingleFlight(sdkClient, initial.binding, ownerFence);
      stop();
    }
    await Promise.race([stopped.promise, fatalFailure()]);
    if (fatalSettled) throw transportError(terminalError);
  } catch (error) {
    if (!terminalError) terminalError = sdkErrorType(error, "sdk-long-connection-failed");
    throw transportError(terminalError);
  } finally {
    if (bindingTimer) clearInterval(bindingTimer);
    if (senderTimer) clearInterval(senderTimer);
    if (keepAliveTimer) clearInterval(keepAliveTimer);
    clearConnectionTimers();
    try { wsClient?.close(); } catch {}
    try {
      writeTransportHealth(HOME, {
        ...healthFence,
        phase: terminalError ? "degraded" : "stopped",
        healthy: false,
        reconnects,
        lastErrorType: terminalError,
      });
    } finally {
      releaseTransportOwner(HOME, nonce);
    }
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
  return command.length === 1 && command[0] === transportProcessTitle(owner.nonce, HOME) && Boolean(startToken) && startToken === owner.process_start_token;
}

function ownerPidIsAlive(owner) {
  const pid = Number(owner?.pid);
  if (!Number.isSafeInteger(pid) || pid <= 1) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function currentOwnerMatchesConfiguration(owner) {
  const identity = String(process.env.FM_FEISHU_CONFIG_IDENTITY || "");
  return !identity || owner?.config_file_identity === identity;
}

async function probeConfiguration() {
  const credentials = environmentAppCredentials();
  const chatId = String(process.env.FM_FEISHU_P2P_CHAT_ID || "");
  if (!/^oc_[A-Za-z0-9_-]{4,128}$/.test(chatId)) throw new Error("configured P2P chat identity is unavailable or malformed");
  const sdk = await loadSdk();
  const client = new sdk.Client({
    appId: credentials.appId,
    appSecret: credentials.appSecret,
    domain: sdk.Domain?.Feishu,
    logger: silentSdkLogger(),
    loggerLevel: sdk.LoggerLevel?.error,
    source: "firstmate-feishu",
  });
  await verifyP2pChat(client, { chat_id: chatId });
}

function lockIsOwned() {
  const result = spawnSync(LOCK_STATUS_SCRIPT, [], {
    encoding: "utf8",
    env: { ...process.env, FM_HOME: HOME, FM_ROOT_OVERRIDE: ROOT },
    timeout: 3000,
  });
  return result.status === 0 && result.stdout.trim() === "owned";
}

function configuredSessionFromStdin() {
  let value;
  try {
    value = JSON.parse(readFileSync(0, "utf8"));
  } catch {
    throw new Error("current persisted Pi session identity is malformed");
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("current persisted Pi session identity is unavailable");
  return value;
}

function configuredIdentity(config) {
  return {
    appIdFingerprint: appFingerprint(config.appId),
    allowedUser: config.captainOpenId,
    allowedChat: config.p2pChatId,
  };
}

function assertConfigUnchanged(expected) {
  const current = readFeishuConfig(HOME);
  if (current.status !== "enabled" || current.fileIdentity !== expected.fileIdentity) {
    throw new Error("local Feishu configuration changed during activation");
  }
}

function currentTransportMatches(config, binding) {
  const owner = readTransportOwner(HOME);
  return Boolean(
    owner &&
    owner.config_file_identity === config.fileIdentity &&
    transportHealthAllowsDispatch(HOME, binding),
  );
}

async function reconcileConfiguredLifecycle({ manualRebind = false } = {}) {
  const session = configuredSessionFromStdin();
  let config;
  try {
    config = readFeishuConfig(HOME);
  } catch (error) {
    await stopOwned({ replacement: true });
    throw error;
  }
  if (config.status === "absent") return;
  if (!lockIsOwned()) throw new Error("current Pi does not own the verified Firstmate session lock");
  if (config.status === "disabled") {
    const pairing = readPairing(HOME);
    const owner = readTransportOwner(HOME);
    if (!pairing && !owner) return;
    await stopOwned({ replacement: true });
    if (pairing) disablePairing(HOME);
    return;
  }
  if (manualRebind) assertManualRebindSafe(HOME);
  loadConfiguredCredentials(config);
  const desired = configuredIdentity(config);
  const stateMatches = configuredSessionMatches(HOME, desired, session);
  const binding = stateMatches ? readActiveBinding(HOME) : undefined;
  const transportMatches = binding ? currentTransportMatches(config, binding) : false;
  if (!stateMatches || !transportMatches) {
    try {
      await probeConfiguration();
      assertConfigUnchanged(config);
    } catch (error) {
      await stopOwned({ replacement: true });
      throw error;
    }
  }
  if (manualRebind) assertManualRebindSafe(HOME);
  if (!stateMatches || !transportMatches) await stopOwned({ replacement: true });
  if (manualRebind) assertManualRebindSafe(HOME);
  assertConfigUnchanged(config);
  if (!stateMatches) convergeConfiguredSession(HOME, desired, session, { requireEmptyDeliveryState: manualRebind });
  assertConfigUnchanged(config);
  await startDetached();
}

async function disableConfiguredLifecycle() {
  const config = readFeishuConfig(HOME);
  if (config.status === "absent") return false;
  if (!lockIsOwned()) throw new Error("current Pi does not own the verified Firstmate session lock");
  await stopOwned({ replacement: true });
  disableFeishuConfig(HOME);
  disablePairing(HOME);
  return true;
}

async function startDetached() {
  const { pairing } = activeConfiguration();
  directAppCredentials(pairing);
  const existing = readTransportOwner(HOME);
  if (existing && ownerLooksLive(existing) && currentOwnerMatchesConfiguration(existing)) {
    if (!SILENT) process.stdout.write("feishu transport already running\n");
    return;
  }
  if (existing && ownerLooksLive(existing)) throw new Error("a verified Feishu transport for another configuration is still running");
  if (existing && !retireStaleTransportOwner(HOME, existing)) throw new Error("stale Feishu transport ownership changed during retirement");
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
      if (!SILENT) process.stdout.write("feishu transport started\n");
      return;
    }
    if (child.exitCode !== null) break;
  }
  throw new Error("Feishu transport did not publish a live owner record");
}

async function stopOwned({ replacement = false } = {}) {
  const owner = readTransportOwner(HOME);
  if (!owner) {
    if (replacement) return;
    writeTransportHealth(HOME, { phase: "stopped", healthy: false, lastErrorType: null });
    if (!SILENT) process.stdout.write("feishu transport already stopped\n");
    return;
  }
  if (!ownerLooksLive(owner)) {
    if (replacement && ownerPidIsAlive(owner)) throw new Error("the prior Feishu transport owner is live but cannot be verified for safe replacement");
    if (!retireStaleTransportOwner(HOME, owner)) throw new Error("stale Feishu transport ownership changed during retirement");
    writeTransportHealth(HOME, { phase: "stopped", healthy: false, lastErrorType: "stale-owner" });
    if (!SILENT) process.stdout.write("feishu transport owner was stale; no process was signalled\n");
    return;
  }
  process.kill(Number(owner.pid), "SIGTERM");
  for (let attempt = 0; attempt < 100; attempt += 1) {
    await sleep(50);
    try { process.kill(Number(owner.pid), 0); }
    catch {
      if (!SILENT) process.stdout.write("feishu transport stopped\n");
      return;
    }
  }
  throw new Error("Feishu transport did not stop after SIGTERM; it was not force-killed");
}

function usage() {
  return "usage: fm-feishu-transport.sh reconcile|manual-rebind|disable-config|config-check|probe|start|stop|restart|status|run [--once]";
}

async function main(argv) {
  const command = argv.shift();
  if (command === "config-check") {
    const config = readFeishuConfig(HOME);
    process.stdout.write(`${JSON.stringify({ status: config.status })}\n`);
    return;
  }
  if (command === "probe") {
    const config = loadConfiguredCredentialsIfNeeded();
    if (config.status !== "enabled") return;
    return probeConfiguration();
  }
  if (command === "reconcile") return reconcileConfiguredLifecycle();
  if (command === "manual-rebind") return reconcileConfiguredLifecycle({ manualRebind: true });
  if (command === "disable-config") return disableConfiguredLifecycle();
  if (command === "start") {
    const config = loadConfiguredCredentialsIfNeeded();
    if (config.status !== "enabled") return;
    return startDetached();
  }
  if (command === "stop") return stopOwned();
  if (command === "restart") {
    const config = loadConfiguredCredentialsIfNeeded();
    if (config.status !== "enabled") return;
    await stopOwned();
    return startDetached();
  }
  if (command === "status") {
    const full = argv.includes("--full") ? statusSummary(HOME) : publicStatusSummary(HOME);
    process.stdout.write(`${JSON.stringify(full)}\n`);
    return;
  }
  if (command === "run") {
    const config = loadConfiguredCredentialsIfNeeded();
    if (config.status !== "enabled") return;
    return runTransport({ once: argv.includes("--once"), daemon: argv.includes("--daemon") });
  }
  throw new Error(usage());
}

main(process.argv.slice(2)).catch((error) => {
  const kind = error?.code === "FM_FEISHU_CONFIG_INVALID"
    ? error.message
    : sdkErrorType(error, "operation-failed");
  process.stderr.write(`fm-feishu-transport: ${kind}\n`);
  process.exitCode = 2;
});
