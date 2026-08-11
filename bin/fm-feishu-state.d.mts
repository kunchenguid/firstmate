export const PAIRING_SCHEMA: string;
export const BINDING_SCHEMA: string;
export const INBOUND_SCHEMA: string;
export const INBOUND_LEDGER_SCHEMA: string;
export const INBOUND_ACK_SCHEMA: string;
export const OUTBOUND_SCHEMA: string;
export const OUTBOUND_LEDGER_SCHEMA: string;
export const OUTBOUND_RECEIPT_SCHEMA: string;
export const TRANSPORT_HEALTH_SCHEMA: string;
export const DECISION_SCHEMA: string;
export const DEFAULT_MAX_INBOUND_BYTES: number;
export const DEFAULT_MAX_OUTBOUND_CHUNK_BYTES: number;
export const IDEMPOTENCY_WINDOW_MS: number;

export interface PairingRecord {
  schema: string;
  home_id: string;
  fm_home_realpath: string;
  app_profile: string;
  app_id_fingerprint: string | null;
  bot_open_id: string;
  allowed_users: string[];
  allowed_chats: string[];
  chat_policy: "p2p-only";
  inbound_types: string[];
  created_at: string;
  updated_at: string;
  disabled_at: string | null;
}

export interface BindingRecord {
  schema: string;
  binding_id: string;
  home_id: string;
  fm_home_realpath: string;
  chat_id: string;
  thread_policy: "reply-correlation-only";
  session_id: string;
  session_file_realpath: string;
  session_cwd_realpath: string;
  session_header_id: string;
  session_header_cwd_realpath: string;
  generation: number;
  status: "active" | "disabled";
  bound_by: "local-tui";
  bound_at: string;
  previous_binding_id: string | null;
}

export interface InboundEvent {
  schema: string;
  source: "feishu" | "tui" | "internal";
  message_id: string;
  message_type: string;
  text: string;
  images?: Array<{ type: "image"; data: string; mimeType: string }>;
  reply_to: string | null;
  ingress_seq: number;
  binding_id: string;
  binding_generation: number;
  target_session_id: string;
  delivery_ref: string;
  decision_ref: string | null;
  decision_key: string | null;
  decision_reply?: "exact" | "unrelated" | "none";
  desired_delivery?: "steer" | "followUp";
}

export interface InboundLedger {
  schema: string;
  source: "feishu" | "tui" | "internal";
  message_id: string;
  ingress_seq: number;
  state: string;
  attempt: number;
  target_session_id: string;
  binding_id: string;
  binding_generation: number;
  delivery_ref: string;
}

export interface IngressClaim {
  event: InboundEvent;
  ledger: InboundLedger;
  filename: string;
}

export interface StatePaths {
  home: string;
  dataRoot: string;
  pairing: string;
  bindings: string;
  activeBinding: string;
  stateRoot: string;
  inbox: string;
  inboundLedger: string;
  inboundAcks: string;
  outbox: string;
  outboundLedger: string;
  outboundReceipts: string;
  outboundMessageMap: string;
  pendingDecisions: string;
  attemptsIn: string;
  attemptsOut: string;
  quarantine: string;
  alerts: string;
  transport: string;
  health: string;
  owner: string;
  liveSession: string;
  sequence: string;
}

export function pathsForHome(home: string): StatePaths;
export function ensurePrivateLayout(home: string): StatePaths;
export function readPairing(home: string): PairingRecord | undefined;
export function readActiveBinding(home: string): BindingRecord | undefined;
export function createPairing(home: string, input: {
  appProfile?: string;
  appIdFingerprint?: string;
  botOpenId: string;
  allowedUser: string;
  allowedChat: string;
}): PairingRecord;
export function disablePairing(home: string): { changed: boolean; pairing?: PairingRecord };
export function bindSession(home: string, session: {
  sessionId: string;
  sessionFile: string;
  sessionCwd: string;
  headerId: string;
  headerCwd: string;
}, options?: { rebind?: boolean }): BindingRecord;
export function publishFeishuInbound(home: string, raw: Record<string, unknown>, options?: {
  maxInboundBytes?: number;
  maxPendingInbound?: number;
  minFreeBytes?: number;
  transport?: string;
}): { status: string; reason?: string; ingressSeq?: number; deliveryRef?: string; messageIdHash?: string };
export function enqueueLocalIngress(home: string, input: {
  source: "tui" | "internal";
  text: string;
  images?: Array<{ type: "image"; data: string; mimeType: string }>;
  desiredDelivery?: "steer" | "followUp";
  sessionId: string;
  bindingId: string;
  bindingGeneration: number;
}): { event: InboundEvent; ledger: InboundLedger };
export function reserveInteractiveIngress(home: string, input: {
  text: string;
  images?: Array<{ type: "image"; data: string; mimeType: string }>;
  desiredDelivery?: "steer" | "followUp";
  sessionId: string;
  bindingId: string;
  bindingGeneration: number;
}): { status: "blocked" } | { status: "reserved"; event: InboundEvent; ledger: InboundLedger };
export function markIngressAccepted(home: string, deliveryRef: string, fence: {
  sessionId: string;
  bindingGeneration: number;
}): boolean;
export function repairInboundLedgers(home: string): number;
export function claimNextIngress(home: string, fence: {
  sessionId: string;
  bindingId: string;
  bindingGeneration: number;
}, options?: { leaseMs?: number }): IngressClaim | undefined;
export function releaseIngressClaim(home: string, deliveryRef: string, error: unknown): boolean;
export function ackIngress(home: string, deliveryRef: string, session: {
  sessionId: string;
  sessionEntryId: string;
  bindingGeneration: number;
}): Record<string, unknown> | undefined;
export function reconcileIngressFromSession(home: string, markers: Array<{
  sessionId: string;
  sessionEntryId: string;
  bindingGeneration: number;
  deliveryRef: string;
}>, fence: {
  sessionId: string;
  bindingGeneration: number;
}): number;
export function findInboundByDeliveryRef(home: string, deliveryRef: string): InboundEvent | undefined;
export function claimLiveSession(home: string, binding: BindingRecord, session: {
  sessionId: string;
  sessionFile: string;
  sessionCwd: string;
}, ownerToken: string): { ok: boolean; reason?: string; record?: Record<string, unknown> };
export function releaseLiveSession(home: string, bindingId: string, ownerToken: string): boolean;
export function ingressCounts(home: string): { pending: number; dispatching: number; delivered: number; other: number };
export function assistantSecretPattern(text: string): string | null;
export function deterministicChunks(text: string, maxBytes?: number): string[];
export function registerAssistantOutbound(home: string, input: {
  text: string;
  source: "feishu" | "tui" | "internal";
  sourceRef: string;
  sessionId: string;
  bindingGeneration: number;
  replyTo?: string | null;
  decisionRef?: string | null;
  decisionKey?: string | null;
  maxChunkBytes?: number;
  maxOutboundBytes?: number;
}): {
  status: string;
  reason?: string;
  pattern?: string;
  eventId?: string;
  chunks?: number;
  error?: string;
  alert?: { id: string; created: boolean };
};
export interface OutboundClaim {
  filename: string;
  outbox: {
    schema: string;
    event_id: string;
    source: string;
    source_ref: string;
    session_id: string;
    binding_id: string;
    binding_generation: number;
    destination_chat_id: string;
    reply_to_message_id: string | null;
    decision_ref: string | null;
    decision_key: string | null;
    text: string;
    chunks: Array<{ index: number; count: number; chunk: string; chunk_hash: string; idempotency_key: string }>;
  };
  ledger: Record<string, unknown> & { attempt_id: string };
  chunk: { index: number; count: number; chunk: string; chunk_hash: string; idempotency_key: string };
}
export function repairOutboundState(home: string): number;
export function claimNextOutbound(home: string, options?: { nowMs?: number }): OutboundClaim | undefined;
export function failOutboundAttempt(home: string, claim: OutboundClaim, error: unknown, options?: {
  ambiguous?: boolean;
  retryAfterMs?: number;
  nowMs?: number;
}): boolean;
export function receiptOutbound(home: string, claim: OutboundClaim, receipt: {
  messageId: string;
  chatId: string;
}): boolean;
export interface PendingDecisionCandidate {
  name: string;
  record: { decision_ref: string; decision_key: string };
}
export function registerPendingDecision(home: string, input: {
  decisionRef: string;
  decisionKey: string;
  sessionId: string;
}): Record<string, unknown>;
export function claimPendingDecisionForOutbound(home: string, sessionId: string, bindingGeneration: number): PendingDecisionCandidate | undefined;
export function bindPendingDecisionToOutbound(home: string, candidate: PendingDecisionCandidate | undefined, eventId: string): void;
export function claimTransportOwner(home: string, owner: {
  nonce: string;
  moduleFile: string;
  processStartToken: string;
}): { ok: boolean; owner: Record<string, unknown> };
export function readTransportOwner(home: string): Record<string, unknown> | undefined;
export function releaseTransportOwner(home: string, nonce: string): boolean;
export function recordTransportDiagnostic(home: string, kind: string, line: string): string;
export function writeTransportHealth(home: string, patch: Record<string, unknown>): Record<string, unknown>;
export function readTransportHealth(home: string): Record<string, unknown> | undefined;
export function statusSummary(home: string): Record<string, unknown>;
export function publicStatusSummary(home: string): Record<string, unknown>;
