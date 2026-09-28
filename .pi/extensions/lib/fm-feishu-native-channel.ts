// Native-queue bridge between durable Feishu events and the current Pi session.
//
// Native TUI and Firstmate operational input never pass through this module.
// Accepted Feishu events are offered to Pi's own steering queue after
// exact binding, generation, transport, and live-session checks.
import { spawn, spawnSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { lstatSync, realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type {
  ExtensionAPI,
  ExtensionCommandContext,
  ExtensionContext,
  MessageStartEvent,
  TurnEndEvent,
} from "@earendil-works/pi-coding-agent";
import {
  FeishuStateLockContentionError,
  claimLiveSession,
  cleanupProcessedFeishuBodies,
  completeAssistantOutboundIntent,
  findInboundByDeliveryRef,
  findInboundDeliveryEvidence,
  liveSessionOwnsBinding,
  loadFeishuIngressContent,
  offerFeishuIngress,
  pendingFeishuIngress,
  persistAssistantOutboundIntent,
  readActiveBinding,
  readAssistantOutboundIntents,
  readPairing,
  readTransportHealth,
  readTransportOwner,
  reconcileFeishuIngress,
  recordInboundContentDigest,
  registerAssistantOutbound,
  releaseFeishuIngressOffer,
  releaseLiveSession,
  repairInboundLedgers,
  repairOutboundState,
  transportHealthAllowsDispatch,
  transportOwnerIncarnationIsLive,
  type BindingRecord,
  type InboundEvent,
} from "../../../bin/fm-feishu-state.mjs";
import { FIRSTMATE_SESSION_START_SETTLED_EVENT } from "./fm-operational-input.ts";

export interface FeishuMarker {
  deliveryRef: string;
  bindingGeneration: number;
}

export const FEISHU_INBOUND_CUSTOM_TYPE = "firstmate-feishu-inbound";
export const FEISHU_INBOUND_DETAILS_SCHEMA = "fm-feishu-pi-message.v1";

export interface FeishuInboundDetails {
  schema: typeof FEISHU_INBOUND_DETAILS_SCHEMA;
  deliveryRef: string;
  bindingGeneration: number;
}

export interface FeishuIngressMessage {
  customType: typeof FEISHU_INBOUND_CUSTOM_TYPE;
  content: string | Array<{ type: "text"; text: string } | { type: "image"; data: string; mimeType: string }>;
  display: true;
  details: FeishuInboundDetails;
}

export interface SessionIdentity {
  sessionId: string;
  sessionFile: string;
  sessionCwd: string;
  headerId: string;
  headerCwd: string;
  outboundAfterEntryId: string | null;
}

interface ActiveRuntime {
  token: string;
  ownerToken: string;
  pi: ExtensionAPI;
  ctx: ExtensionContext;
  binding: BindingRecord;
  identity: SessionIdentity;
  active: boolean;
  pumping: boolean;
  lockRetryAttempt: number;
  nextPumpAt: number;
  nextProcessedCleanupAt: number;
  lockContentionNotified: boolean;
  configFileIdentity: string;
  recoveryAttempt: number;
  recoveryNextAt: number;
  recoveryOwner: TransportOwnerFence | null;
  recoveryTask: Promise<void> | null;
  recoveryTerminalReason: string | null;
  recoveryWarningNotified: boolean;
  timer: ReturnType<typeof setInterval> | null;
  captureAfterEntryId: string | null;
  registrationAlerts: Set<string>;
  lastStatus: string;
}

interface TransportOwnerFence {
  pid: number;
  nonce: string;
  processStartToken: string;
  configFileIdentity: string;
}

interface LifecycleRecoveryResult extends TransportOwnerFence {
  status: "owner-active" | "started";
}

const extensionDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(extensionDir, "../../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const lockStatusScript = process.env.FM_FEISHU_LOCK_STATUS_SCRIPT || `${fmRoot}/bin/fm-session-lock-status.sh`;
const lifecycleScript = process.env.FM_FEISHU_LIFECYCLE_SCRIPT || `${fmRoot}/bin/fm-feishu-lifecycle.mjs`;
const configFile = `${fmHome}/config/feishu.env`;
const markerPattern = /^\u2063FIRSTMATE_FEISHU: v1 ref=(in_[a-f0-9]{24}) g=([1-9][0-9]*)$/u;
const LOCK_RETRY_BASE_MS = 250;
const LOCK_RETRY_MAX_MS = 4000;
const PROCESS_RECOVERY_TEST_MODE = process.env.FM_FEISHU_PROCESS_RECOVERY_TEST_MODE === "1";
const PUMP_INTERVAL_MS = PROCESS_RECOVERY_TEST_MODE ? positiveInteger(process.env.FM_FEISHU_PUMP_MS, 250) : 250;
const PROCESS_RECOVERY_BASE_MS = PROCESS_RECOVERY_TEST_MODE ? positiveInteger(process.env.FM_FEISHU_PROCESS_RECOVERY_BASE_MS, 1000) : 1000;
const PROCESS_RECOVERY_MAX_MS = PROCESS_RECOVERY_TEST_MODE ? positiveInteger(process.env.FM_FEISHU_PROCESS_RECOVERY_MAX_MS, 60000) : 60000;
const PROCESSED_BODY_CLEANUP_INTERVAL_MS = PROCESS_RECOVERY_TEST_MODE
  ? positiveInteger(process.env.FM_FEISHU_PROCESSED_CLEANUP_MS, 5000)
  : 5000;
export interface FeishuNativeChannelControls {
  hardBind(ctx: ExtensionCommandContext): Promise<"already-current" | "hard-bound">;
}

const registeredApis = new WeakMap<object, FeishuNativeChannelControls>();
let activeRuntime: ActiveRuntime | null = null;
let lifecycleTask: Promise<unknown> = Promise.resolve();

function positiveInteger(value: string | undefined, fallback: number): number {
  const number = Number(value);
  return Number.isSafeInteger(number) && number > 0 ? number : fallback;
}

function configPathPresent(): boolean {
  try {
    lstatSync(configFile);
    return true;
  } catch {
    return false;
  }
}

function messageText(message: unknown): string {
  const content = (message as { content?: unknown })?.content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((item): item is { type: "text"; text: string } => (
      Boolean(item) && typeof item === "object" && (item as { type?: unknown }).type === "text" && typeof (item as { text?: unknown }).text === "string"
    ))
    .map((item) => item.text)
    .join("");
}

function markerLine(deliveryRef: string, generation: number): string {
  return `\u2063FIRSTMATE_FEISHU: v1 ref=${deliveryRef} g=${generation}`;
}

export function parseFeishuMarker(text: unknown): FeishuMarker | undefined {
  if (typeof text !== "string") return undefined;
  const match = markerPattern.exec(text.split("\n", 1)[0] ?? "");
  if (!match) return undefined;
  const bindingGeneration = Number(match[2]);
  if (!Number.isSafeInteger(bindingGeneration) || bindingGeneration <= 0) return undefined;
  return { deliveryRef: match[1], bindingGeneration };
}

function feishuDetails(value: unknown): FeishuMarker | undefined {
  if (!value || typeof value !== "object") return undefined;
  const details = value as { schema?: unknown; deliveryRef?: unknown; bindingGeneration?: unknown };
  if (details.schema !== FEISHU_INBOUND_DETAILS_SCHEMA || typeof details.deliveryRef !== "string" || !/^in_[a-f0-9]{24}$/.test(details.deliveryRef)) return undefined;
  if (!Number.isSafeInteger(details.bindingGeneration) || Number(details.bindingGeneration) <= 0) return undefined;
  return { deliveryRef: details.deliveryRef, bindingGeneration: Number(details.bindingGeneration) };
}

export function parseFeishuMessage(message: unknown): FeishuMarker | undefined {
  if (!message || typeof message !== "object") return undefined;
  const candidate = message as { role?: unknown; customType?: unknown; details?: unknown };
  if (candidate.role !== "custom" || candidate.customType !== FEISHU_INBOUND_CUSTOM_TYPE) return undefined;
  return feishuDetails(candidate.details);
}

function ingressContentDigest(content: unknown): string | undefined {
  const hash = createHash("sha256");
  const field = (value: string) => {
    const bytes = Buffer.from(value, "utf8");
    hash.update(`${bytes.length}:`);
    hash.update(bytes);
  };
  if (typeof content === "string") {
    hash.update("s;");
    field(content);
    return `sha256:${hash.digest("hex")}`;
  }
  if (!Array.isArray(content) || content.length === 0) return undefined;
  hash.update(`p${content.length};`);
  for (const part of content) {
    if (!part || typeof part !== "object") return undefined;
    if (part.type === "text") {
      if (typeof part.text !== "string") return undefined;
      hash.update("t;");
      field(part.text);
    } else if (part.type === "image") {
      if (typeof part.data !== "string" || typeof part.mimeType !== "string") return undefined;
      hash.update("i;");
      field(part.mimeType);
      field(part.data);
    } else {
      return undefined;
    }
  }
  return `sha256:${hash.digest("hex")}`;
}

const verifiedClassifications = new Map<string, { marker: FeishuMarker; contentDigest: string }>();
const processedDeliveryRefs = new Set<string>();
const VERIFIED_CLASSIFICATION_LIMIT = 128;

function rememberProcessedDeliveryRef(deliveryRef: string): void {
  if (processedDeliveryRefs.size >= VERIFIED_CLASSIFICATION_LIMIT) {
    const oldest = processedDeliveryRefs.values().next().value;
    if (oldest !== undefined) processedDeliveryRefs.delete(oldest);
  }
  processedDeliveryRefs.add(deliveryRef);
}

export function classifyFeishuMessage(message: unknown): FeishuMarker | undefined {
  const marker = parseFeishuMessage(message);
  if (!marker) return undefined;
  if (processedDeliveryRefs.has(marker.deliveryRef)) return undefined;
  const contentDigest = ingressContentDigest((message as { content?: unknown }).content);
  if (!contentDigest) return undefined;
  const memoKey = `${marker.deliveryRef}:${marker.bindingGeneration}`;
  const verified = verifiedClassifications.get(memoKey);
  if (verified && verified.contentDigest === contentDigest) return verified.marker;
  const evidence = findInboundDeliveryEvidence(fmHome, marker.deliveryRef);
  if (!evidence || evidence.event.delivery_ref !== marker.deliveryRef || evidence.event.binding_generation !== marker.bindingGeneration) return undefined;
  if (!evidence.bodyAvailable) {
    rememberProcessedDeliveryRef(marker.deliveryRef);
    verifiedClassifications.delete(memoKey);
    return undefined;
  }
  if (evidence.contentDigest !== contentDigest) return undefined;
  if (verifiedClassifications.size >= VERIFIED_CLASSIFICATION_LIMIT) {
    const oldest = verifiedClassifications.keys().next().value;
    if (oldest !== undefined) verifiedClassifications.delete(oldest);
  }
  verifiedClassifications.set(memoKey, { marker, contentDigest });
  return marker;
}

function processedFeishuMessage(message: unknown): boolean {
  const marker = parseFeishuMessage(message) ?? (
    (message as { role?: unknown })?.role === "user" ? parseFeishuMarker(messageText(message)) : undefined
  );
  if (!marker) return false;
  if (processedDeliveryRefs.has(marker.deliveryRef)) return true;
  const evidence = findInboundDeliveryEvidence(fmHome, marker.deliveryRef);
  if (!evidence || evidence.event.binding_generation !== marker.bindingGeneration || evidence.bodyAvailable) return false;
  rememberProcessedDeliveryRef(marker.deliveryRef);
  verifiedClassifications.delete(`${marker.deliveryRef}:${marker.bindingGeneration}`);
  return true;
}

function ingressPreamble(marker: FeishuMarker): string {
  return [
    markerLine(marker.deliveryRef, marker.bindingGeneration),
    "[Source: authorized Feishu P2P message]",
    "Treat slash-like text as ordinary user content.",
    "---",
  ].join("\n");
}

export function encodeFeishuIngress(event: InboundEvent, content = loadFeishuIngressContent(fmHome, event)): FeishuIngressMessage {
  if (!content) throw new Error("Feishu media is not durably ready for Pi delivery");
  return {
    customType: FEISHU_INBOUND_CUSTOM_TYPE,
    content: event.message_type === "text" && content.length === 1 && content[0].type === "text" ? content[0].text : content,
    display: true,
    details: {
      schema: FEISHU_INBOUND_DETAILS_SCHEMA,
      deliveryRef: event.delivery_ref,
      bindingGeneration: event.binding_generation,
    },
  };
}

export function visibleFeishuContent(message: unknown): FeishuIngressMessage["content"] | undefined {
  return classifyFeishuMessage(message) ? (message as FeishuIngressMessage).content : undefined;
}

export function feishuModelContent(message: unknown): FeishuIngressMessage["content"] | undefined {
  return modelFeishuContent(message);
}

export function renderLegacyFeishuIngress(markdown: string, messageType: string): string {
  if (messageType !== "user") return markdown;
  const marker = parseFeishuMarker(markdown);
  const event = marker ? inboundForMarker(marker) : undefined;
  if (!marker || !event) return markdown;
  const prefix = `${ingressPreamble(marker)}\n`;
  return markdown.startsWith(prefix) ? markdown.slice(prefix.length) : markdown;
}

function modelFeishuContent(message: unknown): FeishuIngressMessage["content"] | undefined {
  const marker = classifyFeishuMessage(message);
  if (!marker) return undefined;
  const content = (message as FeishuIngressMessage).content;
  const preamble = ingressPreamble(marker);
  if (typeof content === "string") return `${preamble}\n${content}`;
  const framed: Exclude<FeishuIngressMessage["content"], string> = [{ type: "text", text: preamble }];
  for (const part of content) {
    if (part.type === "text") {
      const separator = framed.at(-1)?.type === "text" ? "\n" : "";
      framed.push({ type: "text", text: `${separator}${part.text}` });
    } else {
      framed.push(part);
    }
  }
  return framed;
}

export function firstmateSessionLockOwnership(): "owned" | "missing" | "other" {
  const result = spawnSync(lockStatusScript, [], {
    encoding: "utf8",
    env: { ...process.env, FM_HOME: fmHome, FM_ROOT_OVERRIDE: fmRoot },
    timeout: 3000,
  });
  const output = result.stdout.trim();
  if (result.status === 0 && output === "owned") return "owned";
  if (output === "missing") return "missing";
  return "other";
}

export function currentFirstmateSessionIdentity(ctx: ExtensionContext): SessionIdentity | undefined {
  const sessionFile = ctx.sessionManager.getSessionFile();
  if (!sessionFile) return undefined;
  const header = ctx.sessionManager.getHeader() as { id?: unknown; cwd?: unknown };
  const sessionId = ctx.sessionManager.getSessionId();
  if (typeof header?.id !== "string" || typeof header?.cwd !== "string" || typeof sessionId !== "string") return undefined;
  try {
    return {
      sessionId,
      sessionFile: realpathSync(sessionFile),
      sessionCwd: realpathSync(ctx.cwd),
      headerId: header.id,
      headerCwd: realpathSync(header.cwd),
      outboundAfterEntryId: (ctx.sessionManager.getEntries().at(-1)?.id as string | undefined) ?? null,
    };
  } catch {
    return undefined;
  }
}

function identityMatches(binding: BindingRecord, identity: SessionIdentity): boolean {
  return binding.status === "active" &&
    binding.session_id === identity.sessionId &&
    binding.session_file_realpath === identity.sessionFile &&
    binding.session_cwd_realpath === identity.sessionCwd &&
    binding.session_header_id === identity.headerId &&
    binding.session_header_cwd_realpath === identity.headerCwd;
}

function sameIdentity(left: SessionIdentity | undefined, right: SessionIdentity): boolean {
  return left !== undefined &&
    left.sessionId === right.sessionId &&
    left.sessionFile === right.sessionFile &&
    left.sessionCwd === right.sessionCwd &&
    left.headerId === right.headerId &&
    left.headerCwd === right.headerCwd;
}

function runtimeIsCurrent(runtime: ActiveRuntime): boolean {
  if (!runtime.active || activeRuntime !== runtime || firstmateSessionLockOwnership() !== "owned") return false;
  const pairing = readPairing(fmHome);
  const binding = readActiveBinding(fmHome);
  if (!pairing || pairing.disabled_at !== null || !binding || pairing.home_id !== binding.home_id) return false;
  if (binding.binding_id !== runtime.binding.binding_id || binding.generation !== runtime.binding.generation) return false;
  return identityMatches(binding, runtime.identity) && liveSessionOwnsBinding(fmHome, binding, runtime.identity, runtime.ownerToken);
}

function inboundForMarker(marker: FeishuMarker): InboundEvent | undefined {
  const event = findInboundByDeliveryRef(fmHome, marker.deliveryRef);
  if (!event || event.delivery_ref !== marker.deliveryRef || event.binding_generation !== marker.bindingGeneration) return undefined;
  return event;
}

function sessionMarkers(ctx: ExtensionContext, identity: SessionIdentity): Array<FeishuMarker & { sessionId: string }> {
  const markers: Array<FeishuMarker & { sessionId: string }> = [];
  for (const entry of ctx.sessionManager.getEntries()) {
    const marker = entry.type === "custom_message"
      ? (entry.customType === FEISHU_INBOUND_CUSTOM_TYPE ? feishuDetails(entry.details) : undefined)
      : entry.type === "message" && entry.message.role === "user"
        ? parseFeishuMarker(messageText(entry.message))
        : undefined;
    if (!marker || !inboundForMarker(marker)) continue;
    markers.push({ ...marker, sessionId: identity.sessionId });
  }
  return markers;
}

function updateStatus(runtime: ActiveRuntime): void {
  let transport = "stopped";
  try { transport = String(readTransportHealth(fmHome)?.phase ?? "stopped"); }
  catch { transport = "unreadable"; }
  const recovery = runtime.recoveryTerminalReason
    ? `; recovery stopped (${runtime.recoveryTerminalReason})`
    : runtime.recoveryTask || runtime.recoveryOwner || runtime.recoveryNextAt > Date.now()
      ? `; process recovery attempt ${Math.max(1, runtime.recoveryAttempt)}`
      : "";
  const value = `Feishu: bound g${runtime.binding.generation}; transport ${transport}${recovery}`;
  if (value === runtime.lastStatus) return;
  runtime.lastStatus = value;
  runtime.ctx.ui.setStatus("fm-feishu", value);
}

function transportOwnerFence(value: Record<string, unknown> | undefined): TransportOwnerFence | undefined {
  if (!value || typeof value.pid !== "number" || !Number.isSafeInteger(value.pid) || value.pid <= 1) return undefined;
  if (typeof value.nonce !== "string" || !/^[a-f0-9]{24,128}$/.test(value.nonce)) return undefined;
  if (typeof value.process_start_token !== "string" || !/^[0-9]+$/.test(value.process_start_token)) return undefined;
  if (typeof value.config_file_identity !== "string" || !/^[0-9]+:[0-9]+:[0-9.]+:[0-9]+$/.test(value.config_file_identity)) return undefined;
  return {
    pid: value.pid,
    nonce: value.nonce,
    processStartToken: value.process_start_token,
    configFileIdentity: value.config_file_identity,
  };
}

function sameTransportOwner(left: TransportOwnerFence | null | undefined, right: TransportOwnerFence | null | undefined): boolean {
  return Boolean(left && right && left.pid === right.pid && left.nonce === right.nonce && left.processStartToken === right.processStartToken && left.configFileIdentity === right.configFileIdentity);
}

function parseLifecycleRecoveryResult(output: string): LifecycleRecoveryResult {
  let value: Record<string, unknown>;
  try { value = JSON.parse(output) as Record<string, unknown>; }
  catch { throw new Error("configured recovery returned malformed status"); }
  const owner = transportOwnerFence({
    pid: value.ownerPid,
    nonce: value.ownerNonce,
    process_start_token: value.ownerProcessStartToken,
    config_file_identity: value.configFileIdentity,
  });
  if (!owner || !new Set(["owner-active", "started"]).has(String(value.status))) throw new Error("configured recovery returned invalid owner status");
  return { ...owner, status: value.status as LifecycleRecoveryResult["status"] };
}

function reconcileConfiguredLifecycle(
  payload: SessionIdentity | Record<string, unknown>,
  action: "reconcile" | "hard-bind" | "recover" = "reconcile",
): Promise<LifecycleRecoveryResult | undefined> {
  const reconcile = () => new Promise<LifecycleRecoveryResult | undefined>((resolvePromise, rejectPromise) => {
    const child = spawn(process.execPath, [lifecycleScript, action], {
      cwd: fmRoot,
      env: Object.fromEntries(Object.entries({
        ...process.env,
        FM_HOME: fmHome,
        FM_ROOT_OVERRIDE: fmRoot,
        FM_FEISHU_APP_ID: undefined,
        FM_FEISHU_APP_SECRET: undefined,
        FM_FEISHU_P2P_CHAT_ID: undefined,
        FM_FEISHU_CONFIG_IDENTITY: undefined,
      }).filter((entry): entry is [string, string] => typeof entry[1] === "string")),
      stdio: ["pipe", "pipe", "ignore"],
    });
    let output = "";
    let outputOverlength = false;
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      if (Buffer.byteLength(output, "utf8") + Buffer.byteLength(chunk, "utf8") > 4096) outputOverlength = true;
      else output += chunk;
    });
    child.once("error", rejectPromise);
    child.once("close", (code) => {
      if (code === 0) {
        try {
          if (outputOverlength) throw new Error("configured lifecycle returned overlength status");
          resolvePromise(action === "recover" ? parseLifecycleRecoveryResult(output.trim()) : undefined);
        }
        catch (error) { rejectPromise(error); }
      } else {
        rejectPromise(Object.assign(new Error("configured lifecycle refused"), { exitCode: code }));
      }
    });
    child.stdin.end(JSON.stringify(payload));
  });
  const result = lifecycleTask.then(reconcile, reconcile);
  lifecycleTask = result.catch(() => {});
  return result;
}

function stopRuntime(runtime: ActiveRuntime): void {
  runtime.active = false;
  if (runtime.timer) clearInterval(runtime.timer);
  runtime.timer = null;
  runtime.recoveryOwner = null;
  runtime.recoveryNextAt = 0;
  runtime.ctx.ui.setStatus("fm-feishu", undefined);
  releaseLiveSession(fmHome, runtime.binding.binding_id, runtime.ownerToken);
  if (activeRuntime === runtime) activeRuntime = null;
}

function transportAllowsDispatch(runtime: ActiveRuntime): boolean {
  try {
    const owner = transportOwnerFence(readTransportOwner(fmHome));
    return owner?.configFileIdentity === runtime.configFileIdentity && transportHealthAllowsDispatch(fmHome, runtime.binding);
  }
  catch { return false; }
}

function terminalProcessRecovery(runtime: ActiveRuntime, reason: string): void {
  const alreadyTerminal = runtime.recoveryTerminalReason !== null;
  runtime.recoveryTerminalReason = /^[a-z0-9-]{1,80}$/.test(reason) ? reason : "local-safety-refusal";
  runtime.recoveryNextAt = 0;
  runtime.recoveryOwner = null;
  if (!alreadyTerminal) {
    runtime.ctx.ui.notify(
      "Feishu transport process recovery stopped safely. Run bin/fm-feishu-transport.sh status and config-check locally, then inspect docs/feishu-channel.md.",
      "error",
    );
  }
  updateStatus(runtime);
}

function recoveryHealth(runtime: ActiveRuntime): Record<string, unknown> | undefined {
  const health = readTransportHealth(fmHome);
  if (!health) return undefined;
  if (health.binding_id !== runtime.binding.binding_id || health.binding_generation !== runtime.binding.generation) {
    throw new Error("transport recovery health binding mismatch");
  }
  return health;
}

function recoveredTransportIsHealthy(runtime: ActiveRuntime, expected?: TransportOwnerFence | null): boolean {
  if (!runtimeIsCurrent(runtime)) return false;
  const owner = transportOwnerFence(readTransportOwner(fmHome));
  if (!owner || owner.configFileIdentity !== runtime.configFileIdentity || (expected && !sameTransportOwner(owner, expected))) return false;
  const health = recoveryHealth(runtime);
  if (!health || health.phase !== "healthy" || health.healthy !== true || typeof health.last_identity_verified_at !== "string") return false;
  if (health.owner_pid !== owner.pid || health.owner_nonce !== owner.nonce || health.owner_process_start_token !== owner.processStartToken) return false;
  return transportHealthAllowsDispatch(fmHome, runtime.binding);
}

function resetProcessRecovery(runtime: ActiveRuntime): void {
  runtime.recoveryAttempt = 0;
  runtime.recoveryNextAt = 0;
  runtime.recoveryOwner = null;
  runtime.recoveryTerminalReason = null;
  runtime.recoveryWarningNotified = false;
}

function deferProcessRecovery(runtime: ActiveRuntime): void {
  const exponent = Math.min(runtime.recoveryAttempt, 16);
  runtime.recoveryNextAt = Date.now() + Math.min(PROCESS_RECOVERY_BASE_MS * (2 ** exponent), PROCESS_RECOVERY_MAX_MS);
  runtime.recoveryOwner = null;
  if (!runtime.recoveryWarningNotified) {
    runtime.recoveryWarningNotified = true;
    runtime.ctx.ui.notify("Feishu transport is unhealthy; durable work remains pending while bounded automatic recovery continues.", "warning");
  }
  updateStatus(runtime);
}

function beginProcessRecovery(runtime: ActiveRuntime): void {
  if (!runtime.active || runtime.recoveryTask || runtime.recoveryTerminalReason || Date.now() < runtime.recoveryNextAt) return;
  const attemptBefore = runtime.recoveryAttempt;
  runtime.recoveryAttempt += 1;
  runtime.recoveryTask = (async () => {
    const result = await reconcileConfiguredLifecycle({
      session: runtime.identity,
      bindingId: runtime.binding.binding_id,
      bindingGeneration: runtime.binding.generation,
      configFileIdentity: runtime.configFileIdentity,
      liveOwnerToken: runtime.ownerToken,
    }, "recover");
    if (!runtime.active || activeRuntime !== runtime || !result) return;
    if (result.configFileIdentity !== runtime.configFileIdentity) throw new Error("configured recovery changed identity");
    runtime.recoveryOwner = result;
    if (result.status === "owner-active") runtime.recoveryAttempt = attemptBefore;
    if (recoveredTransportIsHealthy(runtime, result)) resetProcessRecovery(runtime);
  })().catch((error: unknown) => {
    if (!runtime.active || activeRuntime !== runtime) return;
    const exitCode = Number((error as { exitCode?: unknown })?.exitCode);
    if (exitCode === 75) deferProcessRecovery(runtime);
    else terminalProcessRecovery(runtime, "lifecycle-refused");
  }).finally(() => {
    runtime.recoveryTask = null;
  });
}

function observeProcessRecovery(runtime: ActiveRuntime): void {
  if (transportAllowsDispatch(runtime)) {
    if (recoveredTransportIsHealthy(runtime, runtime.recoveryOwner)) resetProcessRecovery(runtime);
    return;
  }
  if (runtime.recoveryTerminalReason || runtime.recoveryTask) return;
  let health: Record<string, unknown> | undefined;
  try { health = recoveryHealth(runtime); }
  catch {
    terminalProcessRecovery(runtime, "state-corruption");
    return;
  }
  if (runtime.recoveryOwner) {
    let ownerRecord: Record<string, unknown> | undefined;
    let owner: TransportOwnerFence | undefined;
    try {
      ownerRecord = readTransportOwner(fmHome);
      owner = transportOwnerFence(ownerRecord);
    }
    catch {
      terminalProcessRecovery(runtime, "owner-state-corruption");
      return;
    }
    const expectedOwner = sameTransportOwner(owner, runtime.recoveryOwner);
    if (expectedOwner && transportOwnerIncarnationIsLive(ownerRecord)) return;
    if (owner && !expectedOwner) {
      terminalProcessRecovery(runtime, "ambiguous-owner-change");
      return;
    }
    if (health?.recovery_class === "terminal") {
      terminalProcessRecovery(runtime, String(health.last_error_type || "terminal-transport-failure"));
      return;
    }
    deferProcessRecovery(runtime);
    return;
  }
  if (health?.recovery_class === "terminal") {
    terminalProcessRecovery(runtime, String(health.last_error_type || "terminal-transport-failure"));
    return;
  }
  if (runtime.recoveryNextAt === 0) {
    deferProcessRecovery(runtime);
    return;
  }
  beginProcessRecovery(runtime);
}

function captureAssistantHistory(runtime: ActiveRuntime): void {
  const entries = runtime.ctx.sessionManager.getEntries();
  const cursor = runtime.captureAfterEntryId;
  const cursorIndex = cursor === null ? -1 : entries.findIndex((entry) => entry.id === cursor);
  if (cursor !== null && cursorIndex < 0) throw new Error("Assistant capture cursor is absent from the current Pi session branch");
  for (let index = cursorIndex + 1; index < entries.length; index += 1) {
    const entry = entries[index];
    if (entry.type === "message" && entry.message.role === "assistant") {
      const result = persistAssistantOutboundIntent(fmHome, {
        text: messageText(entry.message),
        assistantEntryId: entry.id,
        sessionOrder: index,
        sessionEntryTimestamp: entry.timestamp,
        sessionId: runtime.identity.sessionId,
        bindingGeneration: runtime.binding.generation,
      });
      const status = (result as { status?: string }).status;
      if (status === "resource-refused" || status === "secret-refused") {
        const alert = (result as { alert?: { id?: string; created?: boolean } }).alert;
        if (alert?.created) {
          const message = status === "secret-refused"
            ? "Feishu send refused: a finalized Assistant response matched a fixed credential pattern and stayed private."
            : "Feishu send refused: a finalized Assistant response exceeded the local queue, output, or free-space safety threshold and stayed private.";
          runtime.ctx.ui.notify(message, "error");
          runtime.pi.appendEntry("fm-feishu-local-alert", { kind: status, message, alertId: alert.id, createdAt: new Date().toISOString() });
        }
      }
    }
    runtime.captureAfterEntryId = entry.id;
  }
}

function flushAssistantOutbound(runtime: ActiveRuntime): void {
  const intents = readAssistantOutboundIntents(fmHome, {
    sessionId: runtime.identity.sessionId,
    bindingId: runtime.binding.binding_id,
    bindingGeneration: runtime.binding.generation,
  });
  for (const intent of intents) {
    try {
      const record = intent.record;
      const result = registerAssistantOutbound(fmHome, {
        text: record.text,
        assistantEntryId: record.assistant_entry_id,
        sessionOrder: record.session_order,
        sessionEntryTimestamp: record.session_entry_timestamp,
        sessionId: record.session_id,
        bindingGeneration: record.binding_generation,
        registrationIntentId: record.intent_id,
      });
      const terminal = ["registered", "duplicate", "skipped", "secret-refused", "chunk-refused", "resource-refused"].includes(result.status);
      if (!terminal) throw new Error(`outbound registration refused with status ${result.status}`);
      completeAssistantOutboundIntent(fmHome, intent);
      runtime.registrationAlerts.delete(record.intent_id);
      if (["secret-refused", "chunk-refused", "resource-refused"].includes(result.status) && result.alert?.created) {
        const message = result.status === "secret-refused"
          ? "Feishu send refused: a finalized Assistant response matched a fixed credential pattern and stayed private."
          : result.status === "chunk-refused"
            ? "Feishu send refused: deterministic chunking could not preserve a complete URL or Markdown construct within the platform limit."
            : "Feishu send refused: a finalized Assistant response exceeded the local output or free-space safety threshold and stayed private.";
        runtime.ctx.ui.notify(message, "error");
        runtime.pi.appendEntry("fm-feishu-local-alert", { kind: result.status, message, alertId: result.alert.id, createdAt: new Date().toISOString() });
      }
    } catch (error) {
      if (!runtime.registrationAlerts.has(intent.record.intent_id)) {
        runtime.registrationAlerts.add(intent.record.intent_id);
        const message = "Feishu output registration is degraded; the exact finalized Assistant response is durably pending for retry.";
        runtime.ctx.ui.notify(`${message} ${String(error)}`, "error");
        runtime.pi.appendEntry("fm-feishu-local-alert", { kind: "outbound-registration-degraded", message, intentId: intent.record.intent_id, createdAt: new Date().toISOString() });
      }
      break;
    }
  }
}

function clearLockRetry(runtime: ActiveRuntime): void {
  runtime.lockRetryAttempt = 0;
  runtime.nextPumpAt = 0;
  runtime.lockContentionNotified = false;
}

function cleanupProcessedBodiesOnSchedule(runtime: ActiveRuntime): void {
  const now = Date.now();
  if (now < runtime.nextProcessedCleanupAt) return;
  const result = cleanupProcessedFeishuBodies(fmHome, { nowMs: now });
  for (const deliveryRef of result.removedDeliveryRefs) {
    rememberProcessedDeliveryRef(deliveryRef);
    verifiedClassifications.delete(`${deliveryRef}:${runtime.binding.generation}`);
  }
  runtime.nextProcessedCleanupAt = now + PROCESSED_BODY_CLEANUP_INTERVAL_MS;
}

async function pump(runtime: ActiveRuntime): Promise<void> {
  if (runtime.pumping) return;
  runtime.pumping = true;
  try {
    if (!runtimeIsCurrent(runtime)) {
      stopRuntime(runtime);
      return;
    }
    updateStatus(runtime);
    cleanupProcessedBodiesOnSchedule(runtime);
    captureAssistantHistory(runtime);
    flushAssistantOutbound(runtime);
    observeProcessRecovery(runtime);
    if (!transportAllowsDispatch(runtime)) {
      clearLockRetry(runtime);
      return;
    }
    const fence = {
      sessionId: runtime.identity.sessionId,
      bindingId: runtime.binding.binding_id,
      bindingGeneration: runtime.binding.generation,
    };
    for (const pending of pendingFeishuIngress(fmHome, fence)) {
      const offered = offerFeishuIngress(fmHome, pending.event.delivery_ref, fence);
      if (!offered) continue;
      try {
        const message = encodeFeishuIngress(offered.event);
        const contentDigest = ingressContentDigest(message.content);
        if (!contentDigest) throw new Error("Feishu ingress content lacked exact immutable evidence");
        recordInboundContentDigest(fmHome, offered.event.delivery_ref, contentDigest);
        runtime.pi.sendMessage(message, { triggerTurn: true, deliverAs: "steer" });
      } catch (error) {
        releaseFeishuIngressOffer(fmHome, offered.event.delivery_ref, error);
      }
    }
    clearLockRetry(runtime);
  } finally {
    runtime.pumping = false;
  }
}

function schedulePump(runtime: ActiveRuntime): void {
  if (!runtime.active || Date.now() < runtime.nextPumpAt) return;
  setImmediate(() => {
    if (!runtime.active || Date.now() < runtime.nextPumpAt) return;
    void pump(runtime).catch((error) => {
      if (error instanceof FeishuStateLockContentionError && runtime.active && activeRuntime === runtime) {
        const delay = Math.min(LOCK_RETRY_BASE_MS * (2 ** Math.min(runtime.lockRetryAttempt, 4)), LOCK_RETRY_MAX_MS);
        runtime.lockRetryAttempt = Math.min(runtime.lockRetryAttempt + 1, 5);
        runtime.nextPumpAt = Date.now() + delay;
        if (!runtime.lockContentionNotified) {
          runtime.lockContentionNotified = true;
          runtime.ctx.ui.notify("Feishu ingress is delayed by transient state-lock contention; durable input remains pending and retry will continue automatically.", "warning");
        }
        return;
      }
      runtime.ctx.ui.notify(`Feishu ingress stopped safely: ${String(error)}`, "error");
      stopRuntime(runtime);
    });
  });
}

function activate(pi: ExtensionAPI, ctx: ExtensionContext, token: string): ActiveRuntime | undefined {
  if (activeRuntime) stopRuntime(activeRuntime);
  if (!configPathPresent()) return undefined;
  const pairing = readPairing(fmHome);
  const binding = readActiveBinding(fmHome);
  if (!pairing || pairing.disabled_at !== null || !binding || binding.status !== "active") return undefined;
  if (ctx.mode !== "tui" || !ctx.isProjectTrusted() || firstmateSessionLockOwnership() !== "owned") {
    ctx.ui.setStatus("fm-feishu", "Feishu: suspended - current Pi is not the trusted local owner");
    return undefined;
  }
  const identity = currentFirstmateSessionIdentity(ctx);
  if (!identity || !identityMatches(binding, identity)) {
    ctx.ui.setStatus("fm-feishu", "Feishu: suspended - binding belongs to another Pi session; hard-bind it locally to move it");
    return undefined;
  }
  const transportOwner = transportOwnerFence(readTransportOwner(fmHome));
  if (!transportOwner) throw new Error("Feishu transport configuration identity is unavailable");
  const ownerToken = `pi_${process.pid}_${randomBytes(12).toString("hex")}`;
  const live = claimLiveSession(fmHome, binding, identity, ownerToken);
  if (!live.ok) {
    ctx.ui.setStatus("fm-feishu", `Feishu: suspended - ${live.reason ?? "live binding is already owned"}`);
    return undefined;
  }
  const runtime: ActiveRuntime = {
    token,
    ownerToken,
    pi,
    ctx,
    binding,
    identity,
    active: true,
    pumping: false,
    lockRetryAttempt: 0,
    nextPumpAt: 0,
    nextProcessedCleanupAt: Date.now() + PROCESSED_BODY_CLEANUP_INTERVAL_MS,
    lockContentionNotified: false,
    configFileIdentity: transportOwner.configFileIdentity,
    recoveryAttempt: 0,
    recoveryNextAt: 0,
    recoveryOwner: null,
    recoveryTask: null,
    recoveryTerminalReason: null,
    recoveryWarningNotified: false,
    timer: null,
    captureAfterEntryId: binding.outbound_after_entry_id,
    registrationAlerts: new Set(),
    lastStatus: "",
  };
  activeRuntime = runtime;
  try {
    repairInboundLedgers(fmHome);
    repairOutboundState(fmHome);
    reconcileFeishuIngress(fmHome, sessionMarkers(ctx, identity), {
      sessionId: identity.sessionId,
      bindingGeneration: binding.generation,
    }, true);
    captureAssistantHistory(runtime);
    flushAssistantOutbound(runtime);
  } catch (error) {
    stopRuntime(runtime);
    throw error;
  }
  runtime.timer = setInterval(() => schedulePump(runtime), PUMP_INTERVAL_MS);
  runtime.timer.unref();
  schedulePump(runtime);
  updateStatus(runtime);
  return runtime;
}

function onUserStart(event: MessageStartEvent, token: string): void {
  const runtime = activeRuntime;
  if (!runtime || runtime.token !== token || !runtimeIsCurrent(runtime)) return;
  const marker = classifyFeishuMessage(event.message);
  if (!marker || marker.bindingGeneration !== runtime.binding.generation || !inboundForMarker(marker)) return;
  try {
    reconcileFeishuIngress(fmHome, [{ ...marker, sessionId: runtime.identity.sessionId }], {
      sessionId: runtime.identity.sessionId,
      bindingGeneration: runtime.binding.generation,
    });
  } catch (error) {
    runtime.ctx.ui.notify(`Feishu native-queue observation could not be persisted: ${String(error)}`, "error");
    stopRuntime(runtime);
  }
}

function onTurnEnd(event: TurnEndEvent, token: string): void {
  const runtime = activeRuntime;
  if (!runtime || runtime.token !== token || !runtimeIsCurrent(runtime) || event.message.role !== "assistant") return;
  try {
    captureAssistantHistory(runtime);
    flushAssistantOutbound(runtime);
  } catch (error) {
    const message = "Feishu Assistant mirroring could not capture stable persisted message evidence; outbound delivery is suspended.";
    runtime.ctx.ui.notify(`${message} ${String(error)}`, "error");
    runtime.pi.appendEntry("fm-feishu-local-alert", { kind: "outbound-capture-failed", message, createdAt: new Date().toISOString() });
    stopRuntime(runtime);
  }
}

export function registerFeishuNativeChannel(pi: ExtensionAPI): FeishuNativeChannelControls {
  const priorControls = registeredApis.get(pi as object);
  if (priorControls) return priorControls;
  const token = `registration_${randomBytes(10).toString("hex")}`;
  let lifecycleEpoch = 0;
  let runningEpoch = -1;
  let convergedEpoch = -1;
  let activeExpectedEpoch = -1;
  let currentContext: ExtensionContext | undefined;
  let stopListeningForSessionStart: (() => void) | undefined;
  const converge = async (ctx: ExtensionContext, epoch: number) => {
    if (epoch !== lifecycleEpoch || runningEpoch === epoch) return;
    if (convergedEpoch === epoch) {
      if (activeExpectedEpoch !== epoch) return;
      if (activeRuntime?.token === token && runtimeIsCurrent(activeRuntime)) return;
    }
    try {
      if (!configPathPresent()) {
        activate(pi, ctx, token);
        activeExpectedEpoch = -1;
        convergedEpoch = epoch;
        return;
      }
      if (ctx.mode !== "tui" || !ctx.isProjectTrusted() || firstmateSessionLockOwnership() !== "owned") {
        activate(pi, ctx, token);
        return;
      }
      const identity = currentFirstmateSessionIdentity(ctx);
      if (!identity) {
        activate(pi, ctx, token);
        return;
      }
      runningEpoch = epoch;
      await reconcileConfiguredLifecycle(identity, "hard-bind");
      if (epoch !== lifecycleEpoch) return;
      activate(pi, ctx, token);
      const pairing = readPairing(fmHome);
      const binding = readActiveBinding(fmHome);
      activeExpectedEpoch = pairing && pairing.disabled_at === null && binding && identityMatches(binding, identity) ? epoch : -1;
      convergedEpoch = epoch;
    }
    catch (error) {
      if (epoch !== lifecycleEpoch) return;
      ctx.ui.setStatus("fm-feishu", undefined);
      ctx.ui.notify("Feishu activation stopped safely. Run bin/fm-feishu-transport.sh config-check and inspect docs/feishu-channel.md.", "error");
    }
    finally {
      if (runningEpoch === epoch) runningEpoch = -1;
    }
  };
  let hardBindTask: Promise<"already-current" | "hard-bound"> | undefined;
  const controls: FeishuNativeChannelControls = {
    async hardBind(ctx) {
      if (hardBindTask) return hardBindTask;
      const run = async (): Promise<"already-current" | "hard-bound"> => {
        if (ctx.mode !== "tui" || !ctx.hasUI || !ctx.isProjectTrusted() || firstmateSessionLockOwnership() !== "owned") {
          throw new Error("Feishu hard bind requires the trusted local Pi TUI and verified session-lock ownership");
        }
        if (!configPathPresent()) throw new Error("local Feishu configuration is absent");
        const identity = currentFirstmateSessionIdentity(ctx);
        if (!identity) throw new Error("current persisted Pi session identity is unavailable");
        const epoch = lifecycleEpoch;
        const priorBinding = readActiveBinding(fmHome);
        const alreadyCurrent = Boolean(
          priorBinding &&
          identityMatches(priorBinding, identity) &&
          transportHealthAllowsDispatch(fmHome, priorBinding),
        );
        await reconcileConfiguredLifecycle(identity, "hard-bind");
        if (epoch !== lifecycleEpoch || !sameIdentity(currentFirstmateSessionIdentity(ctx), identity)) {
          throw new Error("Pi session changed while Feishu hard bind was running");
        }
        let runtime = activeRuntime;
        if (!runtime || runtime.token !== token || !runtimeIsCurrent(runtime)) runtime = activate(pi, ctx, token) ?? null;
        for (let attempt = 0; attempt < 600; attempt += 1) {
          if (epoch !== lifecycleEpoch || !sameIdentity(currentFirstmateSessionIdentity(ctx), identity)) {
            throw new Error("Pi session changed before Feishu hard bind became healthy");
          }
          const binding = readActiveBinding(fmHome);
          if (binding && identityMatches(binding, identity) && transportHealthAllowsDispatch(fmHome, binding) && runtime?.active && runtimeIsCurrent(runtime)) {
            const unchanged = alreadyCurrent &&
              binding.binding_id === priorBinding?.binding_id &&
              binding.generation === priorBinding.generation;
            return unchanged ? "already-current" : "hard-bound";
          }
          await new Promise((resolvePromise) => setTimeout(resolvePromise, 50));
        }
        throw new Error("configured Feishu binding or transport did not become current and healthy");
      };
      hardBindTask = run().finally(() => { hardBindTask = undefined; });
      return hardBindTask;
    },
  };
  registeredApis.set(pi as object, controls);
  const listenForSessionStart = () => {
    if (stopListeningForSessionStart) return;
    stopListeningForSessionStart = pi.events.on(FIRSTMATE_SESSION_START_SETTLED_EVENT, () => {
      if (currentContext) void converge(currentContext, lifecycleEpoch);
    });
  };
  listenForSessionStart();
  pi.on("session_start", async (_event, ctx) => {
    const epoch = ++lifecycleEpoch;
    currentContext = ctx;
    listenForSessionStart();
    await converge(ctx, epoch);
  });
  pi.on("agent_start", async (_event, ctx) => converge(ctx, lifecycleEpoch));
  pi.on("session_shutdown", () => {
    lifecycleEpoch += 1;
    currentContext = undefined;
    stopListeningForSessionStart?.();
    stopListeningForSessionStart = undefined;
    const runtime = activeRuntime;
    if (runtime?.token === token) stopRuntime(runtime);
  });
  pi.on("message_start", (event) => onUserStart(event, token));
  pi.on("context", (event) => ({
    messages: event.messages.flatMap((message) => {
      if (processedFeishuMessage(message)) return [];
      if (message.role !== "custom") return message;
      const content = modelFeishuContent(message);
      return content ? { ...message, content } : message;
    }),
  }));
  pi.on("turn_end", (event) => onTurnEnd(event, token));
  pi.registerMarkdownTransformer?.((markdown, context) => renderLegacyFeishuIngress(markdown, context.messageType));
  return controls;
}
