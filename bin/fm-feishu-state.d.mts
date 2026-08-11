export const PAIRING_SCHEMA: string;
export const BINDING_SCHEMA: string;
export const INBOUND_SCHEMA: string;
export const INBOUND_LEDGER_SCHEMA: string;
export const OUTBOUND_SCHEMA: string;
export const OUTBOUND_LEDGER_SCHEMA: string;
export const OUTBOUND_RECEIPT_SCHEMA: string;
export const OUTBOUND_INTENT_SCHEMA: string;
export const TRANSPORT_HEALTH_SCHEMA: string;
export const DECISION_SCHEMA: string;
export const DEFAULT_MAX_INBOUND_BYTES: number;
export const DEFAULT_MAX_OUTBOUND_CHUNK_BYTES: number;
export const DEFAULT_MAX_PENDING_OUTBOUND: number;
export const IDEMPOTENCY_WINDOW_MS: number;

export interface PairingRecord {
  schema: string;
  home_id: string;
  fm_home_realpath: string;
  app_id_fingerprint: string;
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
  source: "feishu";
  message_id: string;
  message_type: "text";
  text: string;
  reply_to: string | null;
  ingress_seq: number;
  binding_id: string;
  binding_generation: number;
  target_session_id: string;
  delivery_ref: string;
  decision_ref: string | null;
  decision_key: string | null;
  decision_reply: "exact" | "unrelated" | "none";
}

export interface InboundLedger {
  schema: string;
  source: "feishu";
  message_id: string;
  ingress_seq: number;
  state: "pending" | "offered" | "delivered" | "superseded";
  attempt: number;
  offered_at?: string | null;
  target_session_id: string;
  binding_id: string;
  binding_generation: number;
  delivery_ref: string;
}

export interface InboundCandidate {
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
  inboundEventIds: string;
  inboundPending: string;
  inboundPendingCount: string;
  inboundDeliveryMap: string;
  inboundPublications: string;
  outbox: string;
  outboundLedger: string;
  outboundReceipts: string;
  outboundMessageMap: string;
  outboundPending: string;
  outboundRegistrationIntents: string;
  pendingDecisions: string;
  pendingDecisionOpen: string;
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
  appIdFingerprint: string;
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
  bindingFence?: { bindingId: string; bindingGeneration: number; sessionId: string; chatId: string };
}): { status: string; reason?: string; ingressSeq?: number; deliveryRef?: string; messageIdHash?: string };
export function repairInboundLedgers(home: string): number;
export function pendingFeishuIngress(home: string, fence: {
  sessionId: string;
  bindingId: string;
  bindingGeneration: number;
}): InboundCandidate[];
export function offerFeishuIngress(home: string, deliveryRef: string, fence: {
  sessionId: string;
  bindingId: string;
  bindingGeneration: number;
}): InboundCandidate | undefined;
export function releaseFeishuIngressOffer(home: string, deliveryRef: string, error: unknown): boolean;
export function reconcileFeishuIngress(home: string, markers: Array<{
  sessionId: string;
  bindingGeneration: number;
  deliveryRef: string;
}>, fence: {
  sessionId: string;
  bindingGeneration: number;
}, resetUnobservedOffers?: boolean): number;
export function findInboundByDeliveryRef(home: string, deliveryRef: string): InboundEvent | undefined;
export function claimLiveSession(home: string, binding: BindingRecord, session: {
  sessionId: string;
  sessionFile: string;
  sessionCwd: string;
}, ownerToken: string): { ok: boolean; reason?: string; record?: Record<string, unknown> };
export function releaseLiveSession(home: string, bindingId: string, ownerToken: string): boolean;
export function ingressCounts(home: string): { pending: number; queued: number; delivered: number; other: number };
export function assistantSecretPattern(text: string): string | null;
export function deterministicChunks(text: string, maxBytes?: number): string[];
export function registerAssistantOutbound(home: string, input: {
  text: string;
  source: "feishu";
  sourceRef: string;
  sessionId: string;
  bindingGeneration: number;
  replyTo?: string | null;
  decisionRef?: string | null;
  decisionKey?: string | null;
  maxChunkBytes?: number;
  maxOutboundBytes?: number;
  maxPendingOutbound?: number;
  registrationIntentId?: string;
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
    source: "feishu";
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
export interface OutboundRegistrationIntent {
  schema: string;
  intent_id: string;
  source: "feishu";
  source_ref: string;
  session_id: string;
  binding_id: string;
  binding_generation: number;
  reply_to_message_id: string | null;
  decision_captured: boolean;
  decision_ref: string | null;
  decision_key: string | null;
  text: string;
  text_hash: string;
  created_at: string;
}
export interface OutboundRegistrationIntentCandidate {
  name: string;
  record: OutboundRegistrationIntent;
}
export function persistAssistantOutboundIntent(home: string, input: {
  text: string;
  source: "feishu";
  sourceRef: string;
  sessionId: string;
  bindingGeneration: number;
  replyTo?: string | null;
  maxOutboundBytes?: number;
  maxPendingOutbound?: number;
}): OutboundRegistrationIntent |
  { status: "resource-refused"; reason: "queue-limit" | "resource-limit"; alert: { id: string; created: boolean } } |
  { status: "secret-refused"; pattern: string; alert: { id: string; created: boolean } };
export function readAssistantOutboundIntents(home: string, fence: {
  sessionId: string;
  bindingId: string;
  bindingGeneration: number;
}): OutboundRegistrationIntentCandidate[];
export function bindAssistantOutboundIntentDecision(home: string, candidate: OutboundRegistrationIntentCandidate, decision: PendingDecisionCandidate | undefined): OutboundRegistrationIntentCandidate;
export function completeAssistantOutboundIntent(home: string, candidate: OutboundRegistrationIntentCandidate): boolean;
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
  record: { decision_ref: string; decision_key: string; source: "feishu"; source_ref: string };
}
export function registerPendingDecision(home: string, input: {
  decisionRef: string;
  decisionKey: string;
  sourceRef: string;
  sessionId: string;
  maxPendingOutbound?: number;
}): Record<string, unknown>;
export function findPendingDecisionForOutbound(home: string, decisionRef: string, decisionKey: string, sessionId: string, bindingGeneration: number, source: "feishu", sourceRef: string): PendingDecisionCandidate;
export function claimPendingDecisionForOutbound(home: string, sessionId: string, bindingGeneration: number, source: "feishu", sourceRef: string): PendingDecisionCandidate | undefined;
export function bindPendingDecisionToOutbound(home: string, candidate: PendingDecisionCandidate | undefined, eventId: string): void;
export function finishPendingDecisionForOutbound(home: string, candidate: PendingDecisionCandidate | undefined, outcome: string): void;
export function claimTransportOwner(home: string, owner: {
  nonce: string;
  moduleFile: string;
  processStartToken: string;
}): { ok: boolean; owner: Record<string, unknown> };
export function readTransportOwner(home: string): Record<string, unknown> | undefined;
export function retireStaleTransportOwner(home: string, expected: Record<string, unknown>): boolean;
export function releaseTransportOwner(home: string, nonce: string): boolean;
export function recordTransportDiagnostic(home: string, kind: string, line: string): string;
export function writeTransportHealth(home: string, patch: Record<string, unknown>): Record<string, unknown>;
export function readTransportHealth(home: string): Record<string, unknown> | undefined;
export function transportHealthAllowsDispatch(home: string, binding: BindingRecord): boolean;
export function statusSummary(home: string): Record<string, unknown>;
export function publicStatusSummary(home: string): Record<string, unknown>;
