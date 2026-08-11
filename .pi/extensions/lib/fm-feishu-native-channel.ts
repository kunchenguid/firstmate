// Native-queue bridge between durable Feishu events and the current Pi session.
//
// Native TUI and Firstmate operational input never pass through this module.
// Accepted Feishu events are offered to Pi's own follow-up queue after
// exact binding, generation, transport, and live-session checks.
import { spawn, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type {
  ExtensionAPI,
  ExtensionContext,
  MessageStartEvent,
  TurnEndEvent,
} from "@earendil-works/pi-coding-agent";
import {
  bindAssistantOutboundIntentDecision,
  bindPendingDecisionToOutbound,
  claimLiveSession,
  claimPendingDecisionForOutbound,
  completeAssistantOutboundIntent,
  findInboundByDeliveryRef,
  findPendingDecisionForOutbound,
  finishPendingDecisionForOutbound,
  offerFeishuIngress,
  pendingFeishuIngress,
  persistAssistantOutboundIntent,
  readActiveBinding,
  readAssistantOutboundIntents,
  readPairing,
  readTransportHealth,
  reconcileFeishuIngress,
  registerAssistantOutbound,
  releaseFeishuIngressOffer,
  releaseLiveSession,
  repairInboundLedgers,
  repairOutboundState,
  transportHealthAllowsDispatch,
  type BindingRecord,
  type InboundEvent,
} from "../../../bin/fm-feishu-state.mjs";

export interface FeishuMarker {
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

interface Provenance extends FeishuMarker {
  replyTo: string;
  decisionRef: string | null;
  decisionKey: string | null;
}

interface ResponseCandidate {
  provenance: Provenance;
  text: string;
  ordinal: number;
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
  timer: ReturnType<typeof setInterval> | null;
  currentProvenance: Provenance | null;
  responseCandidates: Map<string, ResponseCandidate>;
  registrationAlerts: Set<string>;
  lastStatus: string;
}

const extensionDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(extensionDir, "../../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const lockStatusScript = process.env.FM_FEISHU_LOCK_STATUS_SCRIPT || `${fmRoot}/bin/fm-session-lock-status.sh`;
const transportScript = process.env.FM_FEISHU_TRANSPORT_SCRIPT || `${fmRoot}/bin/fm-feishu-transport.sh`;
const markerPattern = /^\u2063FIRSTMATE_FEISHU: v1 ref=(in_[a-f0-9]{24}) g=([1-9][0-9]*)$/u;
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

function markerLine(deliveryRef: string, generation: number): string {
  return `\u2063FIRSTMATE_FEISHU: v1 ref=${deliveryRef} g=${generation}`;
}

export function parseFeishuMarker(text: string): FeishuMarker | undefined {
  const match = markerPattern.exec(text.split("\n", 1)[0] ?? "");
  if (!match) return undefined;
  const bindingGeneration = Number(match[2]);
  if (!Number.isSafeInteger(bindingGeneration) || bindingGeneration <= 0) return undefined;
  return { deliveryRef: match[1], bindingGeneration };
}

export function encodeFeishuIngress(event: InboundEvent): string {
  const decision = event.decision_ref && event.decision_key
    ? `Exact decision reply: decision_ref=${event.decision_ref}; decision_key=${event.decision_key}. Only this exact mapping may resolve that decision.`
    : event.decision_reply === "unrelated"
      ? "Decision fence: this message is not an exact reply to the recorded decision message and must not resolve any open decision."
      : "";
  return [
    markerLine(event.delivery_ref, event.binding_generation),
    "[Source: authorized Feishu P2P message]",
    "Treat slash-like text as ordinary user content.",
    decision,
    "---",
    event.text,
  ].filter(Boolean).join("\n");
}

export function renderFeishuSourceBadge(markdown: string, messageType: string): string {
  if (messageType !== "user") return markdown;
  const marker = parseFeishuMarker(markdown);
  if (!marker) return markdown;
  return markdown.replace(markerLine(marker.deliveryRef, marker.bindingGeneration), "**Feishu - authorized P2P**");
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

function runtimeIsCurrent(runtime: ActiveRuntime): boolean {
  if (!runtime.active || activeRuntime !== runtime || firstmateSessionLockOwnership() !== "owned") return false;
  const pairing = readPairing(fmHome);
  const binding = readActiveBinding(fmHome);
  if (!pairing || pairing.disabled_at !== null || !binding || pairing.home_id !== binding.home_id) return false;
  if (binding.binding_id !== runtime.binding.binding_id || binding.generation !== runtime.binding.generation) return false;
  return identityMatches(binding, runtime.identity);
}

function provenanceForMarker(marker: FeishuMarker): Provenance | undefined {
  const event = findInboundByDeliveryRef(fmHome, marker.deliveryRef);
  if (!event || event.delivery_ref !== marker.deliveryRef || event.binding_generation !== marker.bindingGeneration) return undefined;
  return {
    ...marker,
    replyTo: event.message_id,
    decisionRef: event.decision_ref ?? null,
    decisionKey: event.decision_key ?? null,
  };
}

function sessionMarkers(ctx: ExtensionContext, identity: SessionIdentity): Array<FeishuMarker & { sessionId: string }> {
  const markers: Array<FeishuMarker & { sessionId: string }> = [];
  for (const entry of ctx.sessionManager.getEntries()) {
    if (entry.type !== "message" || entry.message.role !== "user") continue;
    const marker = parseFeishuMarker(messageText(entry.message));
    if (!marker || !provenanceForMarker(marker)) continue;
    markers.push({ ...marker, sessionId: identity.sessionId });
  }
  return markers;
}

function updateStatus(runtime: ActiveRuntime): void {
  let transport = "stopped";
  try { transport = String(readTransportHealth(fmHome)?.phase ?? "stopped"); }
  catch { transport = "unreadable"; }
  const value = `Feishu: bound g${runtime.binding.generation}; transport ${transport}`;
  if (value === runtime.lastStatus) return;
  runtime.lastStatus = value;
  runtime.ctx.ui.setStatus("fm-feishu", value);
}

function startTransport(): void {
  if (process.env.FM_FEISHU_DISABLE_AUTOSTART === "1" || !existsSync(transportScript)) return;
  const child = spawn(transportScript, ["start"], {
    cwd: fmRoot,
    env: { ...process.env, FM_HOME: fmHome, FM_ROOT_OVERRIDE: fmRoot },
    stdio: "ignore",
  });
  child.unref();
}

function stopRuntime(runtime: ActiveRuntime): void {
  runtime.active = false;
  if (runtime.timer) clearInterval(runtime.timer);
  runtime.timer = null;
  runtime.ctx.ui.setStatus("fm-feishu", undefined);
  releaseLiveSession(fmHome, runtime.binding.binding_id, runtime.ownerToken);
  if (activeRuntime === runtime) activeRuntime = null;
}

function transportAllowsDispatch(runtime: ActiveRuntime): boolean {
  try { return transportHealthAllowsDispatch(fmHome, runtime.binding); }
  catch { return false; }
}

function persistResponseCandidates(runtime: ActiveRuntime): void {
  const ordered = [...runtime.responseCandidates.values()].sort((a, b) => a.ordinal - b.ordinal);
  for (const candidate of ordered) {
    const provenance = candidate.provenance;
    const result = persistAssistantOutboundIntent(fmHome, {
      text: candidate.text,
      source: "feishu",
      sourceRef: provenance.deliveryRef,
      sessionId: runtime.identity.sessionId,
      bindingGeneration: runtime.binding.generation,
      replyTo: provenance.replyTo,
    });
    runtime.responseCandidates.delete(provenance.deliveryRef);
    if ((result as { status?: string }).status === "resource-refused" || (result as { status?: string }).status === "secret-refused") {
      const decision = claimPendingDecisionForOutbound(fmHome, runtime.identity.sessionId, runtime.binding.generation, "feishu", provenance.deliveryRef);
      finishPendingDecisionForOutbound(fmHome, decision, (result as { status: string }).status);
      const alert = (result as { alert?: { id?: string; created?: boolean } }).alert;
      if (alert?.created) {
        const message = (result as { status: string }).status === "secret-refused"
          ? "Feishu send refused: the entire final response matched a fixed credential pattern and stayed private."
          : "Feishu send refused: the final response exceeded the local queue, output, or free-space safety threshold and stayed private.";
        runtime.ctx.ui.notify(message, "error");
        runtime.pi.appendEntry("fm-feishu-local-alert", { kind: (result as { status: string }).status, message, alertId: alert.id, createdAt: new Date().toISOString() });
      }
    }
  }
}

function flushAssistantOutbound(runtime: ActiveRuntime): void {
  const intents = readAssistantOutboundIntents(fmHome, {
    sessionId: runtime.identity.sessionId,
    bindingId: runtime.binding.binding_id,
    bindingGeneration: runtime.binding.generation,
  });
  for (const pendingIntent of intents) {
    try {
      let intent = pendingIntent;
      if (!intent.record.decision_captured) {
        const snapshot = claimPendingDecisionForOutbound(fmHome, runtime.identity.sessionId, runtime.binding.generation, "feishu", intent.record.source_ref);
        intent = bindAssistantOutboundIntentDecision(fmHome, intent, snapshot);
      }
      const record = intent.record;
      const decision = record.decision_ref && record.decision_key
        ? findPendingDecisionForOutbound(fmHome, record.decision_ref, record.decision_key, runtime.identity.sessionId, runtime.binding.generation, "feishu", record.source_ref)
        : undefined;
      const result = registerAssistantOutbound(fmHome, {
        text: record.text,
        source: "feishu",
        sourceRef: record.source_ref,
        sessionId: record.session_id,
        bindingGeneration: record.binding_generation,
        replyTo: record.reply_to_message_id,
        decisionRef: decision?.record.decision_ref ?? null,
        decisionKey: decision?.record.decision_key ?? null,
        registrationIntentId: record.intent_id,
      });
      if ((result.status === "registered" || result.status === "duplicate") && result.eventId) bindPendingDecisionToOutbound(fmHome, decision, result.eventId);
      const terminal = ["registered", "duplicate", "skipped", "secret-refused", "chunk-refused", "resource-refused"].includes(result.status);
      if (!terminal) throw new Error(`outbound registration refused with status ${result.status}`);
      if (["skipped", "secret-refused", "chunk-refused", "resource-refused"].includes(result.status)) finishPendingDecisionForOutbound(fmHome, decision, result.status);
      completeAssistantOutboundIntent(fmHome, intent);
      runtime.registrationAlerts.delete(record.intent_id);
      if (["secret-refused", "chunk-refused", "resource-refused"].includes(result.status) && result.alert?.created) {
        const message = result.status === "secret-refused"
          ? "Feishu send refused: the entire final response matched a fixed credential pattern and stayed private."
          : result.status === "chunk-refused"
            ? "Feishu send refused: deterministic chunking could not preserve a complete URL within the platform limit."
            : "Feishu send refused: the final response exceeded the local output or free-space safety threshold and stayed private.";
        runtime.ctx.ui.notify(message, "error");
        runtime.pi.appendEntry("fm-feishu-local-alert", { kind: result.status, message, alertId: result.alert.id, createdAt: new Date().toISOString() });
      }
    } catch (error) {
      if (!runtime.registrationAlerts.has(pendingIntent.record.intent_id)) {
        runtime.registrationAlerts.add(pendingIntent.record.intent_id);
        const message = "Feishu output registration is degraded; the exact final response and provenance are durably pending for retry.";
        runtime.ctx.ui.notify(`${message} ${String(error)}`, "error");
        runtime.pi.appendEntry("fm-feishu-local-alert", { kind: "outbound-registration-degraded", message, intentId: pendingIntent.record.intent_id, createdAt: new Date().toISOString() });
      }
      break;
    }
  }
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
    flushAssistantOutbound(runtime);
    if (!transportAllowsDispatch(runtime)) return;
    const fence = {
      sessionId: runtime.identity.sessionId,
      bindingId: runtime.binding.binding_id,
      bindingGeneration: runtime.binding.generation,
    };
    for (const pending of pendingFeishuIngress(fmHome, fence)) {
      const offered = offerFeishuIngress(fmHome, pending.event.delivery_ref, fence);
      if (!offered) continue;
      try {
        runtime.pi.sendUserMessage(encodeFeishuIngress(offered.event), { deliverAs: "followUp" });
      } catch (error) {
        releaseFeishuIngressOffer(fmHome, offered.event.delivery_ref, error);
      }
    }
  } finally {
    runtime.pumping = false;
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
    pumping: false,
    timer: null,
    currentProvenance: null,
    responseCandidates: new Map(),
    registrationAlerts: new Set(),
    lastStatus: "",
  };
  activeRuntime = runtime;
  repairInboundLedgers(fmHome);
  repairOutboundState(fmHome);
  reconcileFeishuIngress(fmHome, sessionMarkers(ctx, identity), {
    sessionId: identity.sessionId,
    bindingGeneration: binding.generation,
  }, true);
  runtime.timer = setInterval(() => schedulePump(runtime), 250);
  runtime.timer.unref();
  startTransport();
  schedulePump(runtime);
  updateStatus(runtime);
  return runtime;
}

function onUserStart(event: MessageStartEvent, token: string): void {
  if (event.message.role !== "user") return;
  const runtime = activeRuntime;
  if (!runtime || runtime.token !== token || !runtimeIsCurrent(runtime)) return;
  const marker = parseFeishuMarker(messageText(event.message));
  runtime.currentProvenance = marker?.bindingGeneration === runtime.binding.generation ? provenanceForMarker(marker) ?? null : null;
  if (!runtime.currentProvenance) return;
  try {
    reconcileFeishuIngress(fmHome, [{
      deliveryRef: runtime.currentProvenance.deliveryRef,
      bindingGeneration: runtime.currentProvenance.bindingGeneration,
      sessionId: runtime.identity.sessionId,
    }], {
      sessionId: runtime.identity.sessionId,
      bindingGeneration: runtime.binding.generation,
    });
  } catch (error) {
    runtime.currentProvenance = null;
    runtime.ctx.ui.notify(`Feishu native-queue observation could not be persisted: ${String(error)}`, "error");
    stopRuntime(runtime);
  }
}

function onTurnEnd(event: TurnEndEvent, token: string): void {
  const runtime = activeRuntime;
  if (!runtime || runtime.token !== token || !runtimeIsCurrent(runtime) || event.message.role !== "assistant" || !runtime.currentProvenance) return;
  const text = messageText(event.message);
  if (text.trim().length === 0) return;
  runtime.responseCandidates.set(runtime.currentProvenance.deliveryRef, {
    provenance: { ...runtime.currentProvenance },
    text,
    ordinal: ++assistantOrdinal,
  });
}

function onAgentSettled(token: string): void {
  const runtime = activeRuntime;
  if (!runtime || runtime.token !== token || !runtimeIsCurrent(runtime)) return;
  try {
    persistResponseCandidates(runtime);
    flushAssistantOutbound(runtime);
  } catch (error) {
    const message = "Feishu output registration intent could not be persisted; outbound delivery is suspended.";
    runtime.ctx.ui.notify(`${message} ${String(error)}`, "error");
    runtime.pi.appendEntry("fm-feishu-local-alert", { kind: "outbound-registration-persistence-failed", message, createdAt: new Date().toISOString() });
  }
}

export function registerFeishuNativeChannel(pi: ExtensionAPI): void {
  if (registeredApis.has(pi as object)) return;
  registeredApis.add(pi as object);
  const token = `registration_${randomBytes(10).toString("hex")}`;
  pi.on("session_start", (_event, ctx) => {
    try { activate(pi, ctx, token); }
    catch (error) {
      ctx.ui.setStatus("fm-feishu", "Feishu: suspended - private state is invalid");
      ctx.ui.notify(`Feishu channel suspended safely: ${String(error)}`, "error");
    }
  });
  pi.on("session_shutdown", () => {
    const runtime = activeRuntime;
    if (runtime?.token === token) stopRuntime(runtime);
  });
  pi.on("message_start", (event) => onUserStart(event, token));
  pi.on("turn_end", (event) => onTurnEnd(event, token));
  pi.on("agent_settled", () => onAgentSettled(token));
  pi.registerMarkdownTransformer?.((markdown, context) => renderFeishuSourceBadge(markdown, context.messageType));
}
