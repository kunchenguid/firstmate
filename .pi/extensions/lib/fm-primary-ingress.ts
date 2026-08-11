// Shared current-Pi ingress and direct-Assistant egress coordinator.
//
// One module instance is shared by the Feishu bridge, watcher bridge, and
// turn-end guard.  When an exact Feishu binding is live, every text producer
// enters the same durable sequence and only one item may be awaiting Pi user
// message acceptance.  Without an active pairing/binding this owner is inert
// and existing internal producers retain their direct current-session path.
import { spawn, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type {
  ExtensionAPI,
  ExtensionContext,
  InputEvent,
  MessageEndEvent,
  MessageStartEvent,
  TurnEndEvent,
} from "@earendil-works/pi-coding-agent";
import {
  ackIngress,
  bindPendingDecisionToOutbound,
  claimLiveSession,
  claimNextIngress,
  claimPendingDecisionForOutbound,
  enqueueLocalIngress,
  findInboundByDeliveryRef,
  readActiveBinding,
  readPairing,
  readTransportHealth,
  repairInboundLedgers,
  reconcileIngressFromSession,
  registerAssistantOutbound,
  releaseIngressClaim,
  releaseLiveSession,
  type BindingRecord,
  type InboundEvent,
  type IngressClaim,
} from "../../../bin/fm-feishu-state.mjs";

export type FirstmateIngressSource = "feishu" | "tui" | "internal";
export type FirstmateDelivery = "steer" | "followUp";

export interface ParsedIngressMarker {
  source: FirstmateIngressSource;
  deliveryRef: string;
  bindingGeneration: number;
}

export interface SessionIdentity {
  sessionId: string;
  sessionFile: string;
  sessionCwd: string;
  headerId: string;
  headerCwd: string;
}

interface Provenance extends ParsedIngressMarker {
  replyTo: string | null;
  decisionRef: string | null;
  decisionKey: string | null;
}

interface ActiveRuntime {
  token: string;
  ownerToken: string;
  pi: ExtensionAPI;
  ctx: ExtensionContext;
  binding: BindingRecord;
  identity: SessionIdentity;
  active: boolean;
  inFlight: IngressClaim | null;
  waitingForTransport: boolean;
  timer: ReturnType<typeof setInterval> | null;
  latestProvenance: Provenance | null;
  lastAssistantText: string;
  lastAssistantOrdinal: number;
  lastOutboundOrdinal: number;
  lastRepairMs: number;
  lastStatus: string;
}

const extensionDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(extensionDir, "../../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const lockStatusScript = process.env.FM_FEISHU_LOCK_STATUS_SCRIPT || `${fmRoot}/bin/fm-session-lock-status.sh`;
const transportScript = process.env.FM_FEISHU_TRANSPORT_SCRIPT || `${fmRoot}/bin/fm-feishu-transport.sh`;
const ingressMarkerPattern = /\u2063FIRSTMATE_INGRESS: v1 (feishu|tui|internal) ref=(in_[a-f0-9]{24}) g=([1-9][0-9]*)/u;
const registeredApis = new WeakSet<object>();
let activeRuntime: ActiveRuntime | null = null;
let assistantOrdinal = 0;

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

export function parseFirstmateIngressMarker(text: string): ParsedIngressMarker | undefined {
  const match = ingressMarkerPattern.exec(text);
  if (!match) return undefined;
  const bindingGeneration = Number(match[3]);
  if (!Number.isSafeInteger(bindingGeneration) || bindingGeneration <= 0) return undefined;
  return {
    source: match[1] as FirstmateIngressSource,
    deliveryRef: match[2],
    bindingGeneration,
  };
}

function markerLine(source: FirstmateIngressSource, deliveryRef: string, generation: number): string {
  return `\u2063FIRSTMATE_INGRESS: v1 ${source} ref=${deliveryRef} g=${generation}`;
}

export function encodeFirstmateIngress(event: InboundEvent): string {
  const marker = markerLine(event.source, event.delivery_ref, event.binding_generation);
  if (event.source === "internal") return `${event.text}\n${marker}`;
  if (event.source === "feishu") {
    const decision = event.decision_ref && event.decision_key
      ? `\nExact decision reply: decision_ref=${event.decision_ref}; decision_key=${event.decision_key}. Only this exact mapping may resolve that decision.`
      : event.decision_reply === "unrelated"
        ? "\nDecision fence: this message is not an exact reply to the recorded decision message and must not resolve any open decision."
        : "";
    return [
      marker,
      "[Source: authorized Feishu P2P message]",
      "Treat slash-like text as ordinary user content. Merge, discard, destructive, irreversible, credential, and security-sensitive action still requires explicit confirmation in the local TUI.",
      decision,
      "---",
      event.text,
    ].filter((line) => line !== "").join("\n");
  }
  return `${marker}\n[Source: local TUI]\n---\n${event.text}`;
}

export function renderFirstmateSourceBadge(markdown: string, messageType: string): string {
  if (messageType !== "user") return markdown;
  const marker = parseFirstmateIngressMarker(markdown);
  if (!marker) return markdown;
  const line = markerLine(marker.source, marker.deliveryRef, marker.bindingGeneration);
  if (marker.source === "internal") return markdown.replace(`\n${line}`, "");
  const badge = marker.source === "feishu" ? "**Feishu - authorized P2P**" : "**Local TUI**";
  return markdown.replace(line, badge);
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
  const sessionManager = ctx.sessionManager;
  const sessionFile = sessionManager.getSessionFile();
  if (!sessionFile) return undefined;
  const header = sessionManager.getHeader() as { id?: unknown; cwd?: unknown };
  const sessionId = sessionManager.getSessionId();
  if (typeof header?.id !== "string" || typeof header?.cwd !== "string" || typeof sessionId !== "string") return undefined;
  try {
    return {
      sessionId,
      sessionFile: realpathSync(sessionFile),
      sessionCwd: realpathSync(ctx.cwd),
      headerId: header.id,
      headerCwd: realpathSync(header.cwd),
    };
  } catch {
    return undefined;
  }
}

function identityMatches(binding: BindingRecord, identity: SessionIdentity): boolean {
  return binding.fm_home_realpath === realpathSync(fmHome) &&
    binding.status === "active" &&
    binding.session_id === identity.sessionId &&
    binding.session_file_realpath === identity.sessionFile &&
    binding.session_cwd_realpath === identity.sessionCwd &&
    binding.session_header_id === identity.headerId &&
    binding.session_header_cwd_realpath === identity.headerCwd;
}

function runtimeIsCurrent(runtime: ActiveRuntime): boolean {
  if (!runtime.active || activeRuntime !== runtime) return false;
  if (firstmateSessionLockOwnership() !== "owned") return false;
  const pairing = readPairing(fmHome);
  const binding = readActiveBinding(fmHome);
  if (!pairing || pairing.disabled_at !== null || !binding) return false;
  if (pairing.fm_home_realpath !== realpathSync(fmHome) || pairing.home_id !== binding.home_id) return false;
  if (!Array.isArray(pairing.allowed_chats) || pairing.allowed_chats.length !== 1 || pairing.allowed_chats[0] !== binding.chat_id) return false;
  if (!Array.isArray(pairing.allowed_users) || pairing.allowed_users.length !== 1) return false;
  if (binding.binding_id !== runtime.binding.binding_id || binding.generation !== runtime.binding.generation) return false;
  return identityMatches(binding, runtime.identity);
}

function provenanceForMarker(marker: ParsedIngressMarker): Provenance {
  const event = findInboundByDeliveryRef(fmHome, marker.deliveryRef);
  return {
    ...marker,
    replyTo: event?.source === "feishu" ? event.message_id : null,
    decisionRef: event?.decision_ref ?? null,
    decisionKey: event?.decision_key ?? null,
  };
}

function sessionMarkers(ctx: ExtensionContext, identity: SessionIdentity): Array<ParsedIngressMarker & { sessionId: string; sessionEntryId: string }> {
  const markers: Array<ParsedIngressMarker & { sessionId: string; sessionEntryId: string }> = [];
  for (const entry of ctx.sessionManager.getEntries()) {
    if (entry.type !== "message" || entry.message.role !== "user") continue;
    const marker = parseFirstmateIngressMarker(messageText(entry.message));
    if (!marker) continue;
    markers.push({ ...marker, sessionId: identity.sessionId, sessionEntryId: entry.id });
  }
  return markers;
}

function entryIdForMessage(ctx: ExtensionContext, text: string): string | undefined {
  const entries = ctx.sessionManager.getEntries();
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = entries[index];
    if (entry?.type === "message" && entry.message.role === "user" && messageText(entry.message) === text) return entry.id;
  }
  return undefined;
}

function updateStatus(runtime: ActiveRuntime): void {
  let transport = "stopped";
  try {
    transport = String(readTransportHealth(fmHome)?.phase ?? "stopped");
  } catch {
    transport = "unreadable";
  }
  const value = `Feishu: bound g${runtime.binding.generation}; transport ${transport}`;
  if (value === runtime.lastStatus) return;
  runtime.lastStatus = value;
  runtime.ctx.ui.setStatus("fm-feishu", value);
}

function stopRuntime(runtime: ActiveRuntime): void {
  runtime.active = false;
  if (runtime.timer) clearInterval(runtime.timer);
  runtime.timer = null;
  runtime.ctx.ui.setStatus("fm-feishu", undefined);
  releaseLiveSession(fmHome, runtime.binding.binding_id, runtime.ownerToken);
  if (activeRuntime === runtime) activeRuntime = null;
}

function startTransport(): void {
  if (process.env.FM_FEISHU_DISABLE_AUTOSTART === "1" || !existsSync(transportScript)) return;
  const child = spawn(transportScript, ["start"], {
    cwd: fmRoot,
    env: { ...process.env, FM_HOME: fmHome, FM_ROOT_OVERRIDE: fmRoot },
    detached: false,
    stdio: "ignore",
  });
  child.unref();
}

function transportAllowsFeishuDispatch(): boolean {
  try {
    const health = readTransportHealth(fmHome);
    return health?.healthy === true && health.phase === "healthy";
  } catch {
    return false;
  }
}

async function pump(runtime: ActiveRuntime): Promise<void> {
  if (!runtimeIsCurrent(runtime)) {
    stopRuntime(runtime);
    return;
  }
  updateStatus(runtime);
  if (Date.now() - runtime.lastRepairMs >= 60000) {
    repairInboundLedgers(fmHome);
    runtime.lastRepairMs = Date.now();
  }
  if (runtime.inFlight) return;
  if (runtime.waitingForTransport) {
    if (!transportAllowsFeishuDispatch()) return;
    runtime.waitingForTransport = false;
  }
  const claim = claimNextIngress(fmHome, {
    sessionId: runtime.identity.sessionId,
    bindingId: runtime.binding.binding_id,
    bindingGeneration: runtime.binding.generation,
  });
  if (!claim) return;
  if (claim.event.source === "feishu" && !transportAllowsFeishuDispatch()) {
    releaseIngressClaim(fmHome, claim.event.delivery_ref, "waiting for startup/reconnect history reconciliation");
    runtime.waitingForTransport = true;
    return;
  }
  runtime.inFlight = claim;
  const encoded = encodeFirstmateIngress(claim.event);
  const content: Parameters<ExtensionAPI["sendUserMessage"]>[0] = claim.event.images?.length
    ? [{ type: "text", text: encoded }, ...claim.event.images]
    : encoded;
  const desired: FirstmateDelivery = claim.event.source === "feishu"
    ? "followUp"
    : claim.event.desired_delivery ?? "followUp";
  try {
    if (runtime.ctx.isIdle()) runtime.pi.sendUserMessage(content);
    else runtime.pi.sendUserMessage(content, { deliverAs: desired });
  } catch {
    runtime.inFlight = null;
    releaseIngressClaim(fmHome, claim.event.delivery_ref, "current Pi rejected the queued ingress");
  }
}

function schedulePump(runtime: ActiveRuntime): void {
  setImmediate(() => {
    void pump(runtime).catch((error) => {
      runtime.ctx.ui.notify(`Feishu ingress stopped safely: ${String(error)}`, "error");
      stopRuntime(runtime);
    });
  });
}

function activate(pi: ExtensionAPI, ctx: ExtensionContext, token: string): ActiveRuntime | undefined {
  if (activeRuntime) stopRuntime(activeRuntime);
  const pairing = readPairing(fmHome);
  const binding = readActiveBinding(fmHome);
  if (!pairing || pairing.disabled_at !== null || !binding || binding.status !== "active") return undefined;
  if (ctx.mode !== "tui" || !ctx.isProjectTrusted() || firstmateSessionLockOwnership() !== "owned") {
    ctx.ui.setStatus("fm-feishu", "Feishu: suspended - current Pi is not the trusted local owner");
    return undefined;
  }
  const identity = currentFirstmateSessionIdentity(ctx);
  if (!identity || !identityMatches(binding, identity)) {
    ctx.ui.setStatus("fm-feishu", "Feishu: suspended - binding belongs to another Pi session; rebind locally to move it");
    return undefined;
  }
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
    inFlight: null,
    waitingForTransport: false,
    timer: null,
    latestProvenance: null,
    lastAssistantText: "",
    lastAssistantOrdinal: 0,
    lastOutboundOrdinal: 0,
    lastRepairMs: Date.now(),
    lastStatus: "",
  };
  activeRuntime = runtime;
  repairInboundLedgers(fmHome);
  reconcileIngressFromSession(fmHome, sessionMarkers(ctx, identity).map((marker) => ({
    deliveryRef: marker.deliveryRef,
    bindingGeneration: marker.bindingGeneration,
    sessionId: marker.sessionId,
    sessionEntryId: marker.sessionEntryId,
  })), {
    sessionId: identity.sessionId,
    bindingGeneration: binding.generation,
  });
  runtime.timer = setInterval(() => schedulePump(runtime), 250);
  runtime.timer.unref();
  startTransport();
  schedulePump(runtime);
  updateStatus(runtime);
  return runtime;
}

function onInput(event: InputEvent, ctx: ExtensionContext, token: string): { action: "continue" | "handled" } {
  const runtime = activeRuntime;
  if (!runtime || runtime.token !== token || !runtimeIsCurrent(runtime)) return { action: "continue" };
  if (event.source === "extension") return { action: "continue" };
  if (event.source !== "interactive") return { action: "continue" };
  enqueueLocalIngress(fmHome, {
    source: "tui",
    text: event.text,
    images: event.images,
    desiredDelivery: event.streamingBehavior ?? "steer",
    sessionId: runtime.identity.sessionId,
    bindingId: runtime.binding.binding_id,
    bindingGeneration: runtime.binding.generation,
  });
  schedulePump(runtime);
  return { action: "handled" };
}

function onUserStart(event: MessageStartEvent, token: string): void {
  if (event.message.role !== "user") return;
  const runtime = activeRuntime;
  if (!runtime || runtime.token !== token || !runtimeIsCurrent(runtime)) return;
  const marker = parseFirstmateIngressMarker(messageText(event.message));
  if (!marker || marker.bindingGeneration !== runtime.binding.generation) return;
  runtime.latestProvenance = provenanceForMarker(marker);
  runtime.lastAssistantText = "";
  if (runtime.inFlight?.event.delivery_ref === marker.deliveryRef) {
    runtime.inFlight = null;
    schedulePump(runtime);
  }
}

async function onUserEnd(event: MessageEndEvent, ctx: ExtensionContext, token: string): Promise<void> {
  if (event.message.role !== "user") return;
  const runtime = activeRuntime;
  if (!runtime || runtime.token !== token || !runtimeIsCurrent(runtime)) return;
  const text = messageText(event.message);
  const marker = parseFirstmateIngressMarker(text);
  if (!marker || marker.bindingGeneration !== runtime.binding.generation) return;
  const entryId = entryIdForMessage(ctx, text);
  if (!entryId) return;
  ackIngress(fmHome, marker.deliveryRef, {
    sessionId: runtime.identity.sessionId,
    sessionEntryId: entryId,
    bindingGeneration: marker.bindingGeneration,
  });
}

function onTurnEnd(event: TurnEndEvent, token: string): void {
  const runtime = activeRuntime;
  if (!runtime || runtime.token !== token || !runtimeIsCurrent(runtime) || event.message.role !== "assistant") return;
  runtime.lastAssistantText = messageText(event.message);
  runtime.lastAssistantOrdinal = ++assistantOrdinal;
}

function onAgentSettled(ctx: ExtensionContext, token: string): void {
  const runtime = activeRuntime;
  if (!runtime || runtime.token !== token || !runtimeIsCurrent(runtime)) return;
  if (!runtime.latestProvenance || runtime.lastAssistantOrdinal <= runtime.lastOutboundOrdinal) return;
  runtime.lastOutboundOrdinal = runtime.lastAssistantOrdinal;
  const decision = claimPendingDecisionForOutbound(fmHome, runtime.identity.sessionId, runtime.binding.generation);
  const result = registerAssistantOutbound(fmHome, {
    text: runtime.lastAssistantText,
    source: runtime.latestProvenance.source,
    sourceRef: runtime.latestProvenance.deliveryRef,
    sessionId: runtime.identity.sessionId,
    bindingGeneration: runtime.binding.generation,
    replyTo: runtime.latestProvenance.source === "feishu" ? runtime.latestProvenance.replyTo : null,
    decisionRef: decision?.record.decision_ref ?? null,
    decisionKey: decision?.record.decision_key ?? null,
  });
  if ((result.status === "registered" || result.status === "duplicate") && result.eventId) {
    bindPendingDecisionToOutbound(fmHome, decision, result.eventId);
  }
  if (["secret-refused", "chunk-refused", "resource-refused"].includes(result.status) && result.alert?.created) {
    const message = result.status === "secret-refused"
      ? "Feishu send refused: the entire final response matched a fixed credential pattern and stayed private."
      : result.status === "chunk-refused"
        ? "Feishu send refused: deterministic chunking could not preserve a complete URL within the platform limit."
        : "Feishu send refused: the final response exceeded the local output or free-space safety threshold and stayed private.";
    ctx.ui.notify(message, "error");
    runtime.pi.appendEntry("fm-feishu-local-alert", {
      kind: result.status,
      message,
      alertId: result.alert.id,
      createdAt: new Date().toISOString(),
    });
  }
}

const sensitiveBash = /(?:^|[;&|]\s*)(?:[^\n;]*\/)?fm-(?:pr-merge|merge-local|teardown)\.sh\b|\b(?:gh|gh-axi)\s+pr\s+merge\b|\bglab\s+mr\s+merge\b|\bgit\s+(?:merge\b|reset\s+--hard|clean\s+-[^\n]*f|push\b[^\n]*--force|branch\s+-[dD]\b|worktree\s+(?:remove|prune)\b)|\brm\s+-[^\n]*r[^\n]*f\b|\blark-cli\b[^\n]*(?:\s--yes\b|\s(?:auth|config)\s+)|\b(?:auth|config)\s+(?:login|logout|init)\b/i;

export function feishuSensitiveToolReason(toolName: string, input: unknown, provenance: FirstmateIngressSource | undefined): string | undefined {
  if (provenance !== "feishu") return undefined;
  if (toolName !== "bash") return undefined;
  const command = String((input as { command?: unknown })?.command ?? "");
  if (!sensitiveBash.test(command)) return undefined;
  return "This request came from Feishu. Merge, discard, destructive, irreversible, credential, and security-sensitive action requires explicit confirmation in the local TUI before this command can run.";
}

export function registerFirstmateIngressCoordinator(pi: ExtensionAPI): void {
  if (registeredApis.has(pi as object)) return;
  registeredApis.add(pi as object);
  const token = `registration_${randomBytes(10).toString("hex")}`;

  pi.on("session_start", (_event, ctx) => {
    try {
      activate(pi, ctx, token);
    } catch (error) {
      ctx.ui.setStatus("fm-feishu", "Feishu: suspended - private state is invalid");
      ctx.ui.notify(`Feishu channel suspended safely: ${String(error)}`, "error");
    }
  });

  pi.on("session_shutdown", () => {
    const runtime = activeRuntime;
    if (runtime?.token === token) stopRuntime(runtime);
  });

  pi.on("input", (event, ctx) => onInput(event, ctx, token));
  pi.on("message_start", (event) => onUserStart(event, token));
  pi.on("message_end", async (event, ctx) => onUserEnd(event, ctx, token));
  pi.on("turn_end", (event) => onTurnEnd(event, token));
  pi.on("agent_settled", (_event, ctx) => onAgentSettled(ctx, token));
  pi.on("tool_call", (event) => {
    const runtime = activeRuntime;
    if (!runtime || runtime.token !== token || !runtimeIsCurrent(runtime)) return {};
    const reason = feishuSensitiveToolReason(event.toolName, event.input, runtime.latestProvenance?.source);
    return reason ? { block: true, reason, terminate: true } : {};
  });

  pi.registerMarkdownTransformer?.((markdown, context) => renderFirstmateSourceBadge(markdown, context.messageType));
}

export async function submitFirstmateInternalInput(
  pi: ExtensionAPI,
  content: string,
  desiredDelivery: FirstmateDelivery = "followUp",
): Promise<void> {
  const runtime = activeRuntime;
  if (!runtime || !runtimeIsCurrent(runtime)) {
    await pi.sendUserMessage(content, { deliverAs: desiredDelivery });
    return;
  }
  enqueueLocalIngress(fmHome, {
    source: "internal",
    text: content,
    desiredDelivery,
    sessionId: runtime.identity.sessionId,
    bindingId: runtime.binding.binding_id,
    bindingGeneration: runtime.binding.generation,
  });
  schedulePump(runtime);
}
