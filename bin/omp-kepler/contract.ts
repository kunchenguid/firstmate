import { createHash, randomUUID, verify } from "node:crypto";
import type { Model } from "@oh-my-pi/pi-ai";

export interface Capsule {
  version: 1; task: string; role: "crew" | "scout"; backend: "orca";
  issue: "ATX-2170"; scope: "command-center-pilot";
  cockpit: "kepler"; launchSurface: "manual-terminal"; supervisor: "firstmate";
  keplerTaskId: string | null; keplerWorktreeId: string | null;
  authority: string; ownerAction: string; gates: Record<string, boolean>;
  worktree: string; head: string; brief: string; issuedAt: number; deadline: number;
  credit: {included: boolean; overage: number; validUntil: number};
  fallback: false; tools: string[]; model: Model;
  runtime: {bun: string; bunVersion: string; bunSha256: string; sdkVersion: string; nodeModules: string; nodeModulesSha256: string};
  sourceHashes: Record<string, string>; credentialFile: string;
}
export function canonical(value: unknown): string {
  if (typeof value === "number") {
    if (!Number.isFinite(value) || Math.abs(value) > Number.MAX_SAFE_INTEGER) throw Error("finite_safe_number_required");
    if (value === 0) return "0";
    const bytes = new DataView(new ArrayBuffer(8)); bytes.setFloat64(0, Math.abs(value));
    const bits = bytes.getBigUint64(0), exponent = Number((bits >> 52n) & 2047n);
    let numerator = (bits & ((1n << 52n) - 1n)) + (exponent ? 1n << 52n : 0n);
    let power = (exponent ? exponent - 1023 : -1022) - 52;
    while (power < 0 && numerator % 2n === 0n) { numerator /= 2n; power++; }
    const sign = value < 0 ? "-" : "";
    if (power >= 0) return sign + (numerator << BigInt(power)).toString();
    const places = -power, digits = (numerator * 5n ** BigInt(places)).toString().padStart(places + 1, "0");
    return sign + `${digits.slice(0, -places)}.${digits.slice(-places)}`.replace(/0+$/, "").replace(/\.$/, "");
  }
  if (typeof value === "string") {
    for (let i = 0; i < value.length; i++) {
      const unit = value.charCodeAt(i);
      if (unit >= 0xd800 && unit <= 0xdbff) {
        const next = value.charCodeAt(++i);
        if (!(next >= 0xdc00 && next <= 0xdfff)) throw Error("valid_unicode_required");
      } else if (unit >= 0xdc00 && unit <= 0xdfff) throw Error("valid_unicode_required");
    }
    return JSON.stringify(value);
  }
  if (value === null || typeof value === "boolean") return JSON.stringify(value);
  if (typeof value !== "object") throw Error("supported_json_value_required");
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (![Object.prototype, null].includes(Object.getPrototypeOf(value))) throw Error("supported_json_value_required");
  return `{${Object.keys(value).filter(k => (value as Record<string, unknown>)[k] !== undefined).sort().map(k => `${canonical(k)}:${canonical((value as Record<string, unknown>)[k])}`).join(",")}}`;
}
export const digest = (value: unknown): string => createHash("sha256").update(canonical(value)).digest("hex");
export function validateGate(c: Capsule, now = Date.now() / 1000): void {
  if (c.version !== 1 || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$/.test(c.task) || c.backend !== "orca" || !["crew", "scout"].includes(c.role)) throw Error("worker_contract_required");
  if (c.issue !== "ATX-2170" || c.scope !== "command-center-pilot" || !c.task.startsWith("ATX-2170")) throw Error("named_pilot_scope_required");
  if (c.cockpit !== "kepler" || c.launchSurface !== "manual-terminal" || c.supervisor !== "firstmate" ||
      !["string", "object"].includes(typeof c.keplerTaskId) || !["string", "object"].includes(typeof c.keplerWorktreeId) ||
      (typeof c.keplerTaskId === "object" && c.keplerTaskId !== null) || (typeof c.keplerWorktreeId === "object" && c.keplerWorktreeId !== null)) throw Error("kepler_launch_binding_required");
  if (c.authority !== "owner-approved-activation" || c.ownerAction !== "ATX-1758-approved") throw Error("implementation_only_ATX1758_OWNER_ACTION_PENDING");
  if (canonical(c.gates) !== canonical({provider: true, installation: false, login: false, merge: false, production: false})) throw Error("distinct_owner_gates_required");
  if (!(Number.isInteger(c.deadline) && Number.isInteger(c.issuedAt) && now < c.deadline && c.deadline <= now + 900 && c.deadline - c.issuedAt <= 900 && c.issuedAt <= now)) throw Error("bounded_deadline_required");
  if (!c.credit?.included || c.credit.overage !== 0 || c.credit.validUntil < c.deadline) throw Error("fresh_zero_overage_credit_required");
  const names = c.role === "scout" ? ["read", "grep"] : ["read", "grep", "write", "edit"];
  if (canonical(c.tools) !== canonical(names) || c.fallback !== false) throw Error("exact_tools_zero_fallback_required");
  if (!c.brief?.trim() || c.brief.length > 65536) throw Error("approved_brief_required");
  for (const key of ["provider", "id", "api", "baseUrl"] as const) {
    const value = c.model?.[key];
    if (typeof value !== "string" || !value || /[*?\n]/.test(value)) throw Error("explicit_model_required");
  }
  if (!c.model.baseUrl.startsWith("https://")) throw Error("exact_endpoint_required");
  if (["auto", "default", "main", "crew", "scout", "fast", "heavy"].some(alias => [c.model.provider, c.model.id].includes(alias))) throw Error("model_alias_refused");
  const endpoint = new URL(c.model.baseUrl);
  if (endpoint.username || endpoint.password || endpoint.search || endpoint.hash || c.model.headers || c.model.requestModelId || c.model.transport) throw Error("unaliased_credential_free_endpoint_required");
}

export function credentialGuard(c: Capsule, credential: string, cancelled: () => boolean, now = () => Date.now() / 1000): (model: Model) => string {
  return model => {
    if (cancelled() || now() >= c.deadline || now() >= c.credit.validUntil || !c.credit.included || c.credit.overage !== 0) throw Error("request_authority_expired");
    if (["provider", "id", "api", "baseUrl"].some(key => model[key as keyof Model] !== c.model[key as keyof Model])) throw Error("request_model_endpoint_changed");
    if (model.requestModelId || model.headers || model.transport) throw Error("request_model_alias_or_transport_changed");
    if (!credential) throw Error("custodied_credential_missing");
    return credential;
  };
}

export interface CreditReceipt {
  version: 1; kind: "verified-provider-credit"; task: string; capsuleHash: string;
  provider: string; modelId: string; accountEvidenceRef: string; usageEvidenceRef: string;
  included: true; overage: 0; observedAt: number; validUntil: number;
}
export function verifyCredit(envelope: {payload: CreditReceipt; signature: string}, c: Capsule, capsuleHash: string, key: string, now = Date.now() / 1000): void {
  const p = envelope.payload;
  if (!verify(null, Buffer.from(canonical(p)), key, Buffer.from(envelope.signature, "base64"))) throw Error("credit_signature_refused");
  if (p.version !== 1 || p.kind !== "verified-provider-credit" || p.task !== c.task || p.capsuleHash !== capsuleHash ||
      p.provider !== c.model.provider || p.modelId !== c.model.id || p.included !== true || p.overage !== 0 ||
      !p.accountEvidenceRef || !p.usageEvidenceRef || p.observedAt > now || now - p.observedAt > 60 ||
      now >= p.validUntil || p.validUntil > c.deadline) throw Error("fresh_verified_credit_required");
}

export interface MutationPreview {path: string; fingerprint: string; beforeSha256: string; afterSha256: string; argsDigest: string; bytes: number}
export interface ApprovalRequest {version: 1; task: string; capsuleHash: string; nonce: string; operation: string; arguments: unknown; preview: MutationPreview; expiresAt: number}
export interface ApprovalReceipt extends ApprovalRequest {decision: "approve" | "deny"}
export type SignedReceipt = {payload: ApprovalReceipt; signature: string};
export class ApprovalBroker {
  readonly pending = new Map<string, ApprovalRequest>();
  readonly grants = new Map<string, MutationPreview>();
  readonly used = new Set<string>();
  constructor(readonly c: Capsule, readonly capsuleHash: string, readonly key: string, readonly now = () => Date.now() / 1000) {}
  request(operation: string, preview: MutationPreview, args: unknown): ApprovalRequest {
    if (this.now() >= this.c.deadline) throw Error("approval_expired");
    if (digest(args) !== preview.argsDigest) throw Error("approval_arguments_changed");
    const request: ApprovalRequest = {version: 1, task: this.c.task, capsuleHash: this.capsuleHash,
      nonce: randomUUID(), operation, arguments: args, preview, expiresAt: Math.min(this.c.deadline, this.now() + 60)};
    this.pending.set(request.nonce, request);
    return request;
  }
  consume(envelope: SignedReceipt): boolean {
    const receipt = envelope.payload;
    const request = this.pending.get(receipt.nonce);
    if (!request || this.used.has(receipt.nonce) || this.now() >= request.expiresAt || this.now() >= this.c.deadline) throw Error("approval_stale_or_replayed");
    if (!verify(null, Buffer.from(canonical(receipt)), this.key, Buffer.from(envelope.signature, "base64"))) throw Error("approval_signature_refused");
    const {decision, ...binding} = receipt;
    if (canonical(binding) !== canonical(request) || !["approve", "deny"].includes(decision)) throw Error("approval_binding_changed");
    this.used.add(receipt.nonce);
    this.pending.delete(receipt.nonce);
    if (decision === "approve") this.grants.set(request.preview.argsDigest, request.preview);
    return decision === "approve";
  }
  take(argsDigest: string): MutationPreview {
    if (this.now() >= this.c.deadline) throw Error("approval_expired");
    const grant = this.grants.get(argsDigest);
    this.grants.delete(argsDigest);
    if (!grant) throw Error("authenticated_one_use_approval_required");
    return grant;
  }
}
