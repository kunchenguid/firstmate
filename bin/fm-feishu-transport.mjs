#!/usr/bin/env node
// Dedicated no-Agent Feishu transport.
//
// The transport uses the official Feishu Node SDK for one long-connection
// event client and the SDK's message APIs for durable outbound delivery.
// It never starts Pi, imports an Agent SDK, writes a Pi session, evaluates
// message text, opens a webhook, or invokes an operator command.
import { spawn } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  claimNextOutbound,
  claimTransportOwner,
  failOutboundAttempt,
  publicStatusSummary,
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

const MODULE_FILE = fileURLToPath(import.meta.url);
const ROOT = resolve(dirname(MODULE_FILE), "..");
const HOME = realpathSync(process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || ROOT);
const OFFICIAL_SDK = "@larksuiteoapi/node-sdk";
const SDK_MODULE = process.env.FM_FEISHU_SDK_MODULE || OFFICIAL_SDK;
const READY_TIMEOUT_MS = positiveInteger(process.env.FM_FEISHU_READY_TIMEOUT_MS, 30000);
const COMMAND_TIMEOUT_MS = positiveInteger(process.env.FM_FEISHU_COMMAND_TIMEOUT_MS, 30000);
const OUTBOX_POLL_MS = positiveInteger(process.env.FM_FEISHU_OUTBOX_POLL_MS, 500);
const BINDING_POLL_MS = positiveInteger(process.env.FM_FEISHU_BINDING_POLL_MS, 1000);
const ONCE_SETTLE_MS = positiveInteger(process.env.FM_FEISHU_ONCE_SETTLE_MS, 50);
let stopping = false;
let sdkClient = null;
let wsClient = null;
let outboundDrainTask = null;

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

function directAppCredentials(pairing) {
  const appId = String(process.env.FM_FEISHU_APP_ID || "");
  const appSecret = String(process.env.FM_FEISHU_APP_SECRET || "");
  if (!/^cli_[A-Za-z0-9_-]{8,128}$/.test(appId) || !/^[A-Za-z0-9._~+/=-]{8,4096}$/.test(appSecret)) {
    throw new Error("direct SDK app credentials are unavailable or malformed");
  }
  if (appFingerprint(appId) !== pairing.app_id_fingerprint) throw new Error("direct SDK app fingerprint does not match the local pairing");
  return { appId, appSecret };
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
    throw new Error("binding generation changed");
  }
  if (!owner || owner.pid !== ownerFence.ownerPid || owner.nonce !== ownerFence.ownerNonce || owner.process_start_token !== ownerFence.ownerProcessStartToken) {
    throw new Error("transport owner changed");
  }
  directAppCredentials(current.pairing);
  return current;
}

async function verifyP2pChat(client, binding) {
  let result;
  try {
    result = await client.im.v1.chat.get({ path: { chat_id: binding.chat_id } }, { timeout: COMMAND_TIMEOUT_MS });
  } catch (error) {
    throw new Error(sdkErrorType(error, "chat-identity-unavailable"));
  }
  if (!result || result.code !== 0 || !result.data || result.data.chat_mode !== "p2p") throw new Error("configured-chat-is-not-p2p");
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
  let content = "";
  if (message.message_type === "text" && typeof message.content === "string") {
    try {
      const parsed = JSON.parse(message.content);
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed) && typeof parsed.text === "string") content = parsed.text;
    } catch {}
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
    reply_to: message.parent_id ?? null,
    root_id: message.root_id ?? null,
    thread_id: message.thread_id ?? null,
    create_time: message.create_time,
    update_time: message.update_time ?? null,
  };
}

function sdkErrorType(error, fallback = "sdk-error") {
  const status = Number(error?.response?.status);
  const code = Number(error?.response?.data?.code ?? error?.code);
  if (Number.isSafeInteger(status) && status >= 100 && status <= 599) return `sdk-http-${status}`;
  if (Number.isSafeInteger(code) && code >= 0) return `sdk-code-${code}`;
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

async function sendOneOutbound(client, binding, ownerFence) {
  if (!transportHealthAllowsDispatch(HOME, binding)) return false;
  assertOwnerAndBinding(binding, ownerFence);
  const claim = claimNextOutbound(HOME);
  if (!claim) return false;
  const content = JSON.stringify({ text: claim.chunk.chunk });
  const payload = {
    data: {
      receive_id: claim.outbox.destination_chat_id,
      content,
      msg_type: "text",
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
    if (sdkFailureIsAuthentication(error)) throw new Error("outbound SDK authentication failed");
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
  const owner = claimTransportOwner(HOME, { nonce, moduleFile: realpathSync(MODULE_FILE), processStartToken });
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
  let verificationTask = null;

  const stop = () => {
    if (stopping) return;
    stopping = true;
    try { wsClient?.close(); } catch {}
    stopped.resolve();
  };
  const fail = (error) => {
    if (fatalSettled) return;
    fatalSettled = true;
    terminalError = sdkErrorType(error, "sdk-long-connection-failed");
    try { writeTransportHealth(HOME, { ...healthFence, phase: "degraded", healthy: false, reconnects, lastErrorType: terminalError }); } catch {}
    fatal.resolve(new Error(terminalError));
    stop();
  };
  const verifyConnectedIdentity = () => {
    if (verificationTask) return verificationTask;
    verificationTask = (async () => {
      const current = assertOwnerAndBinding(initial.binding, ownerFence);
      await verifyP2pChat(sdkClient, current.binding);
      assertOwnerAndBinding(initial.binding, ownerFence);
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
      await drainOutboundSingleFlight(sdkClient, initial.binding, ownerFence);
    })().catch(fail).finally(() => { verificationTask = null; });
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
        } catch (error) {
          try { recordTransportDiagnostic(HOME, "sdk-event-refused", sdkErrorType(error, "sdk-event-handoff-failed")); } catch {}
          fail(error);
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
      onError: (error) => fail(error),
      onReconnecting: () => {
        reconnects += 1;
        try { writeTransportHealth(HOME, { ...healthFence, phase: "reconnecting", healthy: false, reconnects, lastErrorType: null }); }
        catch (error) { fail(error); }
      },
      onReconnected: () => { void verifyConnectedIdentity(); },
    });
    bindingTimer = setInterval(() => {
      try { assertOwnerAndBinding(initial.binding, ownerFence); }
      catch { stop(); }
    }, BINDING_POLL_MS);
    bindingTimer.unref();
    await wsClient.start({ eventDispatcher });
    const readyTimeout = new Promise((_, reject) => {
      const timer = setTimeout(() => reject(new Error("SDK long connection did not become ready")), READY_TIMEOUT_MS);
      timer.unref();
    });
    await Promise.race([ready.promise, fatalFailure(), readyTimeout]);
    senderTimer = setInterval(() => {
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
  } catch (error) {
    if (!terminalError) terminalError = sdkErrorType(error, "sdk-long-connection-failed");
    throw new Error(terminalError);
  } finally {
    if (bindingTimer) clearInterval(bindingTimer);
    if (senderTimer) clearInterval(senderTimer);
    if (keepAliveTimer) clearInterval(keepAliveTimer);
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

async function startDetached() {
  const { pairing } = activeConfiguration();
  directAppCredentials(pairing);
  const existing = readTransportOwner(HOME);
  if (existing && ownerLooksLive(existing)) {
    process.stdout.write("feishu transport already running\n");
    return;
  }
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
    writeTransportHealth(HOME, { phase: "stopped", healthy: false, lastErrorType: null });
    process.stdout.write("feishu transport already stopped\n");
    return;
  }
  if (!ownerLooksLive(owner)) {
    if (!retireStaleTransportOwner(HOME, owner)) throw new Error("stale Feishu transport ownership changed during retirement");
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
  if (command === "run") return runTransport({ once: argv.includes("--once"), daemon: argv.includes("--daemon") });
  throw new Error(usage());
}

main(process.argv.slice(2)).catch((error) => {
  process.stderr.write(`fm-feishu-transport: ${error.message}\n`);
  process.exitCode = 2;
});
