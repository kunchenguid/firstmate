// Transport-neutral active-session adoption core for Firstmate's Pi bridge.

export const BRIDGE_PROTOCOL_VERSION = 1 as const;
export const BRIDGE_CUSTOM_TYPE = "firstmate.external.turn.v1";
export const BRIDGE_INPUT_CHANNEL = "firstmate:active-session-bridge:input";
export const BRIDGE_OUTPUT_CHANNEL = "firstmate:active-session-bridge:output";
export const SUPPORTED_PI_VERSION = "0.80.10";

export type ExternalTurnKind = "message" | "reply" | "correction";

export type SessionBind = {
  type: "session.bind";
  protocolVersion: typeof BRIDGE_PROTOCOL_VERSION;
  requestId: string;
  routeId: string;
  sessionEpoch: number;
  expectedSessionId?: string;
};

export type TurnOffer = {
  type: "turn.offer";
  protocolVersion: typeof BRIDGE_PROTOCOL_VERSION;
  requestId: string;
  externalId: string;
  payloadSha256: string;
  routeId: string;
  sessionEpoch: number;
  kind: ExternalTurnKind;
  sourceLabel: string;
  text: string;
  authenticatedCorrection?: boolean;
  supersedesExternalId?: string;
};

export type TurnReconcile = {
  type: "turn.reconcile";
  protocolVersion: typeof BRIDGE_PROTOCOL_VERSION;
  requestId: string;
  externalId: string;
  payloadSha256: string;
  routeId: string;
  sessionEpoch: number;
};

export type BridgeInput = SessionBind | TurnOffer | TurnReconcile;

export type BridgeResultStatus =
  | "ACCEPTED"
  | "DUPLICATE"
  | "NOT_FOUND"
  | "AMBIGUOUS"
  | "STALE_EPOCH"
  | "BUSY"
  | "UNAVAILABLE";

export type BridgeResult = {
  type: "turn.result";
  requestId: string;
  externalId?: string;
  payloadSha256?: string;
  status: BridgeResultStatus;
  reasonCode?: string;
  piEntryId?: string;
  sessionId?: string;
  sessionEpoch?: number;
  routeId?: string;
  deliverAs?: "followUp" | "steer";
};

export type SessionState = {
  type: "session.state";
  state: "READY" | "UNAVAILABLE";
  reasonCode?: string;
  piVersion: string;
  sessionId?: string;
  sessionEpoch?: number;
  routeId?: string;
};

export type BridgeOutput = BridgeResult | SessionState;

export type SessionEntryLike = {
  type: string;
  id: string;
  customType?: string;
  details?: unknown;
};

export type CustomMessageLike = {
  role: string;
  customType?: string;
  content?: unknown;
  details?: unknown;
};

export type SessionAccess = {
  getEntries(): readonly SessionEntryLike[];
  isPersisted?(): boolean;
  isIdle(): boolean;
  sendMessage(
    message: {
      customType: string;
      content: Array<{ type: "text"; text: string }>;
      display: boolean;
      details: ExternalTurnMarker;
    },
    options: { triggerTurn: true; deliverAs: "followUp" | "steer" },
  ): void;
};

export type ExternalTurnMarker = {
  schema_version: typeof BRIDGE_PROTOCOL_VERSION;
  request_id: string;
  external_id: string;
  payload_sha256: string;
  route_id: string;
  session_epoch: number;
};

type ActiveSession = {
  generation: number;
  sessionId: string;
  access: SessionAccess;
  persisted: boolean;
  routeId?: string;
  sessionEpoch?: number;
};

type PendingAdoption = {
  generation: number;
  requestId: string;
  externalId: string;
  payloadSha256: string;
  routeId: string;
  sessionEpoch: number;
  deliverAs: "followUp" | "steer";
};

type MarkerScan =
  | { status: "NOT_FOUND" }
  | { status: "DUPLICATE"; piEntryId: string }
  | { status: "AMBIGUOUS"; reasonCode: string };

type Scheduler = (callback: () => void) => void;
type MarkerIdentity = Pick<
  TurnOffer | TurnReconcile,
  "requestId" | "externalId" | "payloadSha256" | "routeId" | "sessionEpoch"
>;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function markerFrom(value: unknown): ExternalTurnMarker | undefined {
  if (!isRecord(value)) return undefined;
  if (value.schema_version !== BRIDGE_PROTOCOL_VERSION) return undefined;
  if (typeof value.request_id !== "string") return undefined;
  if (typeof value.external_id !== "string") return undefined;
  if (typeof value.payload_sha256 !== "string") return undefined;
  if (typeof value.route_id !== "string") return undefined;
  if (!Number.isSafeInteger(value.session_epoch) || Number(value.session_epoch) < 1) return undefined;
  return {
    schema_version: BRIDGE_PROTOCOL_VERSION,
    request_id: value.request_id,
    external_id: value.external_id,
    payload_sha256: value.payload_sha256,
    route_id: value.route_id,
    session_epoch: Number(value.session_epoch),
  };
}

function validOpaqueId(value: unknown, maxLength = 256): value is string {
  return typeof value === "string"
    && value.length > 0
    && value.length <= maxLength
    && !/[\u0000-\u001f\u007f]/.test(value);
}

function validHash(value: unknown): value is string {
  return typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
}

function validEpoch(value: unknown): value is number {
  return Number.isSafeInteger(value) && Number(value) >= 1;
}

function resultFor(
  input: MarkerIdentity,
  status: BridgeResultStatus,
  sessionId: string | undefined,
  extra: Partial<BridgeResult> = {},
): BridgeResult {
  return {
    type: "turn.result",
    requestId: input.requestId,
    externalId: input.externalId,
    payloadSha256: input.payloadSha256,
    status,
    sessionId,
    sessionEpoch: input.sessionEpoch,
    routeId: input.routeId,
    ...extra,
  };
}

export function scanPersistedMarker(
  entries: readonly SessionEntryLike[],
  externalId: string,
  payloadSha256: string,
  routeId: string,
): MarkerScan {
  const malformedMatches: SessionEntryLike[] = [];
  const matches = entries.flatMap((entry) => {
    if (entry.type !== "custom_message" || entry.customType !== BRIDGE_CUSTOM_TYPE) return [];
    if (isRecord(entry.details)
      && entry.details.external_id === externalId
      && markerFrom(entry.details) === undefined) {
      malformedMatches.push(entry);
      return [];
    }
    const marker = markerFrom(entry.details);
    return marker?.external_id === externalId ? [{ entry, marker }] : [];
  });

  if (malformedMatches.length > 0) return { status: "AMBIGUOUS", reasonCode: "INVALID_MARKER" };
  if (matches.length === 0) return { status: "NOT_FOUND" };
  if (matches.length > 1) return { status: "AMBIGUOUS", reasonCode: "MULTIPLE_MARKERS" };

  const match = matches[0];
  if (match.marker.payload_sha256 !== payloadSha256) {
    return { status: "AMBIGUOUS", reasonCode: "MISMATCHED_HASH" };
  }
  if (match.marker.route_id !== routeId) {
    return { status: "AMBIGUOUS", reasonCode: "MISMATCHED_ROUTE" };
  }
  return { status: "DUPLICATE", piEntryId: match.entry.id };
}

export class ActiveSessionBridge {
  private active?: ActiveSession;
  private pending?: PendingAdoption;
  private activeExternalId?: string;
  private generation = 0;
  private readonly emit: (output: BridgeOutput) => void;
  private readonly schedule: Scheduler;
  private readonly piVersion: string;

  constructor(options: {
    piVersion: string;
    emit: (output: BridgeOutput) => void;
    schedule?: Scheduler;
  }) {
    this.piVersion = options.piVersion;
    this.emit = options.emit;
    this.schedule = options.schedule ?? ((callback) => setImmediate(callback));
  }

  start(sessionId: string, access: SessionAccess): void {
    this.generation += 1;
    this.pending = undefined;
    this.activeExternalId = undefined;
    const persisted = access.isPersisted?.() ?? true;
    this.active = { generation: this.generation, sessionId, access, persisted };

    if (this.piVersion !== SUPPORTED_PI_VERSION) {
      this.emit({
        type: "session.state",
        state: "UNAVAILABLE",
        reasonCode: "UNSUPPORTED_PI_VERSION",
        piVersion: this.piVersion,
        sessionId,
      });
      return;
    }
    if (!persisted) {
      this.emit({
        type: "session.state",
        state: "UNAVAILABLE",
        reasonCode: "SESSION_NOT_PERSISTED",
        piVersion: this.piVersion,
        sessionId,
      });
      return;
    }

    this.emit({
      type: "session.state",
      state: "UNAVAILABLE",
      reasonCode: "ROUTE_BINDING_REQUIRED",
      piVersion: this.piVersion,
      sessionId,
    });
  }

  shutdown(reasonCode = "SESSION_SHUTDOWN"): void {
    const active = this.active;
    const pending = this.pending;
    this.generation += 1;
    this.active = undefined;
    this.pending = undefined;
    this.activeExternalId = undefined;

    if (pending) {
      this.emit(resultFor(
        pending,
        "UNAVAILABLE",
        active?.sessionId,
        { reasonCode: "SESSION_SHUTDOWN_BEFORE_PERSISTENCE", deliverAs: pending.deliverAs },
      ));
    }
    this.emit({
      type: "session.state",
      state: "UNAVAILABLE",
      reasonCode,
      piVersion: this.piVersion,
      sessionId: active?.sessionId,
      sessionEpoch: active?.sessionEpoch,
      routeId: active?.routeId,
    });
  }

  handle(input: unknown): void {
    if (!isRecord(input) || typeof input.type !== "string") return;
    if (input.type === "session.bind") {
      this.bind(input as unknown as SessionBind);
      return;
    }
    if (input.type === "turn.offer") {
      this.offer(input as unknown as TurnOffer);
      return;
    }
    if (input.type === "turn.reconcile") {
      this.reconcile(input as unknown as TurnReconcile);
    }
  }

  onMessageEnd(message: CustomMessageLike): void {
    const active = this.active;
    const pending = this.pending;
    if (!active || !pending) return;
    if (message.role !== "custom" || message.customType !== BRIDGE_CUSTOM_TYPE) return;
    const marker = markerFrom(message.details);
    if (!marker || marker.request_id !== pending.requestId) return;
    if (marker.external_id !== pending.externalId || marker.payload_sha256 !== pending.payloadSha256) return;

    this.activeExternalId = pending.externalId;
    const generation = pending.generation;
    this.schedule(() => this.verifyAfterMessageEnd(generation));
  }

  onAgentSettled(): void {
    this.activeExternalId = undefined;
  }

  private bind(input: SessionBind): void {
    const active = this.active;
    if (!active || !active.persisted || this.piVersion !== SUPPORTED_PI_VERSION) {
      this.emit({
        type: "turn.result",
        requestId: validOpaqueId(input.requestId) ? input.requestId : "invalid",
        status: "UNAVAILABLE",
        reasonCode: "SESSION_UNAVAILABLE",
      });
      return;
    }
    if (input.protocolVersion !== BRIDGE_PROTOCOL_VERSION
      || !validOpaqueId(input.requestId)
      || !validOpaqueId(input.routeId)
      || !validEpoch(input.sessionEpoch)) {
      this.emit({
        type: "turn.result",
        requestId: validOpaqueId(input.requestId) ? input.requestId : "invalid",
        status: "UNAVAILABLE",
        reasonCode: "INVALID_BINDING",
        sessionId: active.sessionId,
      });
      return;
    }
    if (input.expectedSessionId && input.expectedSessionId !== active.sessionId) {
      this.emit({
        type: "turn.result",
        requestId: input.requestId,
        status: "UNAVAILABLE",
        reasonCode: "SESSION_ID_MISMATCH",
        sessionId: active.sessionId,
      });
      return;
    }
    if (active.routeId
      && (active.routeId !== input.routeId || active.sessionEpoch !== input.sessionEpoch)) {
      this.emit({
        type: "turn.result",
        requestId: input.requestId,
        status: "UNAVAILABLE",
        reasonCode: "COMPETING_ROUTE_BINDING",
        sessionId: active.sessionId,
        sessionEpoch: active.sessionEpoch,
        routeId: active.routeId,
      });
      return;
    }

    active.routeId = input.routeId;
    active.sessionEpoch = input.sessionEpoch;
    this.emit({
      type: "session.state",
      state: "READY",
      piVersion: this.piVersion,
      sessionId: active.sessionId,
      sessionEpoch: input.sessionEpoch,
      routeId: input.routeId,
    });
  }

  private validateTurn(input: TurnOffer | TurnReconcile): BridgeResult | undefined {
    const active = this.active;
    if (!active
      || !active.persisted
      || this.piVersion !== SUPPORTED_PI_VERSION
      || !active.routeId
      || !active.sessionEpoch) {
      return resultFor(input, "UNAVAILABLE", active?.sessionId, { reasonCode: "SESSION_UNAVAILABLE" });
    }
    if (input.protocolVersion !== BRIDGE_PROTOCOL_VERSION
      || !validOpaqueId(input.requestId)
      || !validOpaqueId(input.externalId)
      || !validHash(input.payloadSha256)
      || !validOpaqueId(input.routeId)
      || !validEpoch(input.sessionEpoch)) {
      return resultFor(input, "UNAVAILABLE", active.sessionId, { reasonCode: "INVALID_REQUEST" });
    }
    if (input.routeId !== active.routeId) {
      return resultFor(input, "UNAVAILABLE", active.sessionId, { reasonCode: "ROUTE_MISMATCH" });
    }
    if (input.sessionEpoch !== active.sessionEpoch) {
      return resultFor(input, "STALE_EPOCH", active.sessionId, { reasonCode: "SESSION_EPOCH_MISMATCH" });
    }
    return undefined;
  }

  private scan(input: MarkerIdentity): MarkerScan {
    const active = this.active;
    if (!active) return { status: "NOT_FOUND" };
    return scanPersistedMarker(
      active.access.getEntries(),
      input.externalId,
      input.payloadSha256,
      input.routeId,
    );
  }

  private emitScan(input: TurnOffer | TurnReconcile, scan: MarkerScan): boolean {
    const active = this.active;
    if (scan.status === "NOT_FOUND") return false;
    if (scan.status === "DUPLICATE") {
      this.emit(resultFor(input, "DUPLICATE", active?.sessionId, { piEntryId: scan.piEntryId }));
      return true;
    }
    this.emit(resultFor(input, "AMBIGUOUS", active?.sessionId, { reasonCode: scan.reasonCode }));
    return true;
  }

  private reconcile(input: TurnReconcile): void {
    const invalid = this.validateTurn(input);
    if (invalid) {
      this.emit(invalid);
      return;
    }
    const scan = this.scan(input);
    if (this.emitScan(input, scan)) return;
    this.emit(resultFor(input, "NOT_FOUND", this.active?.sessionId));
  }

  private offer(input: TurnOffer): void {
    const invalid = this.validateTurn(input);
    if (invalid) {
      this.emit(invalid);
      return;
    }
    if (!["message", "reply", "correction"].includes(input.kind)
      || !validOpaqueId(input.sourceLabel, 48)
      || typeof input.text !== "string"
      || input.text.length === 0
      || Buffer.byteLength(input.text, "utf8") > 65536) {
      this.emit(resultFor(input, "UNAVAILABLE", this.active?.sessionId, { reasonCode: "INVALID_OFFER" }));
      return;
    }

    const scan = this.scan(input);
    if (this.emitScan(input, scan)) return;
    if (this.pending) {
      this.emit(resultFor(input, "BUSY", this.active?.sessionId, { reasonCode: "ADOPTION_IN_FLIGHT" }));
      return;
    }

    const active = this.active;
    if (!active || !active.routeId || !active.sessionEpoch) {
      this.emit(resultFor(input, "UNAVAILABLE", active?.sessionId, { reasonCode: "SESSION_UNAVAILABLE" }));
      return;
    }

    const busy = !active.access.isIdle();
    let deliverAs: "followUp" | "steer" = "followUp";
    if (busy && input.kind === "correction") {
      const correctionBound = input.authenticatedCorrection === true
        && validOpaqueId(input.supersedesExternalId)
        && input.supersedesExternalId === this.activeExternalId;
      if (!correctionBound) {
        this.emit(resultFor(input, "BUSY", active.sessionId, { reasonCode: "CORRECTION_NOT_BOUND" }));
        return;
      }
      deliverAs = "steer";
    }

    const marker: ExternalTurnMarker = {
      schema_version: BRIDGE_PROTOCOL_VERSION,
      request_id: input.requestId,
      external_id: input.externalId,
      payload_sha256: input.payloadSha256,
      route_id: input.routeId,
      session_epoch: input.sessionEpoch,
    };
    this.pending = {
      generation: active.generation,
      requestId: input.requestId,
      externalId: input.externalId,
      payloadSha256: input.payloadSha256,
      routeId: input.routeId,
      sessionEpoch: input.sessionEpoch,
      deliverAs,
    };

    try {
      active.access.sendMessage(
        {
          customType: BRIDGE_CUSTOM_TYPE,
          content: [{
            type: "text",
            text: `Authorized ${input.sourceLabel} message.\nReply through the Firstmate conversation lane.\n\n${input.text}`,
          }],
          display: true,
          details: marker,
        },
        { triggerTurn: true, deliverAs },
      );
    } catch {
      this.pending = undefined;
      this.emit(resultFor(input, "UNAVAILABLE", active.sessionId, {
        reasonCode: "SEND_REJECTED",
        deliverAs,
      }));
    }
  }

  private verifyAfterMessageEnd(generation: number): void {
    const active = this.active;
    const pending = this.pending;
    if (!active || !pending || active.generation !== generation || pending.generation !== generation) return;

    const scan = this.scan(pending);
    this.pending = undefined;
    if (scan.status === "DUPLICATE") {
      this.emit(resultFor(pending, "ACCEPTED", active.sessionId, {
        piEntryId: scan.piEntryId,
        deliverAs: pending.deliverAs,
      }));
      return;
    }
    if (scan.status === "AMBIGUOUS") {
      this.emit(resultFor(pending, "AMBIGUOUS", active.sessionId, {
        reasonCode: scan.reasonCode,
        deliverAs: pending.deliverAs,
      }));
      return;
    }
    this.emit(resultFor(pending, "UNAVAILABLE", active.sessionId, {
      reasonCode: "POST_EVENT_PERSISTENCE_MISSING",
      deliverAs: pending.deliverAs,
    }));
  }
}
