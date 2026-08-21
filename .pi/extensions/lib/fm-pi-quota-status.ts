import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";

export const DEFAULT_QUOTA_FRESHNESS_MS = 6 * 60 * 1000;

export type QuotaWindowKind = "session" | "weekly" | "monthly" | "model" | "credits" | "unknown";

export type QuotaWindowView = {
  id: string;
  label: string;
  kind: QuotaWindowKind;
  percentRemaining: number | null;
  resetsAtMs: number | null;
  resetText: string | null;
};

export type QuotaCreditsView = {
  remaining: number | null;
  unlimited: boolean | null;
  unit: "usd" | "credits" | null;
};

export type FreshQuotaView = {
  kind: "fresh";
  provider: string;
  label: string;
  plan: string | null;
  windows: QuotaWindowView[];
  credits: QuotaCreditsView | null;
  generatedAtMs: number;
  freshnessTimestampMs: number;
  reportFreshUntilMs: number;
  freshUntilMs: number;
  publicationWindows?: QuotaWindowView[];
  refreshFailure?: QuotaRefreshIssue | null;
};

export type QuotaFailureReason = "missing" | "failed" | "timeout" | "overflow" | "cancelled";
export type QuotaRefreshIssue =
  | QuotaFailureReason
  | "malformed"
  | "unverified"
  | "auth-timeout"
  | "auth-cancelled"
  | "auth-overflow"
  | "auth-unavailable";

export type QuotaUnsupportedReason =
  | "provider"
  | "no-model"
  | "auth-inspection"
  | "non-subscription-auth"
  | "auth-timeout"
  | "auth-cancelled"
  | "auth-overflow"
  | "auth-unavailable"
  | "provider-override"
  | "custom-endpoint"
  | "account-correlation"
  | "credential-monitoring";

export type QuotaView =
  | FreshQuotaView
  | { kind: "refreshing"; provider: string }
  | { kind: "unsupported"; provider: string; reason: QuotaUnsupportedReason }
  | { kind: "unavailable"; provider: string; label: string | null }
  | { kind: "failure"; provider: string; reason: QuotaFailureReason }
  | { kind: "unverified"; provider: string }
  | { kind: "stale"; provider: string; label: string | null; recoverable?: FreshQuotaView }
  | { kind: "malformed"; provider: string };

export type QuotaAxiProjection = "default" | "full";

export type ParsedQuotaAxiReport = {
  generatedAtMs: number;
  schemaVersion: number;
  projection: QuotaAxiProjection;
  providers: unknown[];
};

const PI_PROVIDER_TO_QUOTA_PROVIDER: Readonly<Record<string, string>> = {
  anthropic: "claude",
  "github-copilot": "copilot",
  "kimi-coding": "kimi",
  "openai-codex": "codex",
  xai: "grok",
};

const QUOTA_PROVIDER_LABELS: Readonly<Record<string, string>> = {
  claude: "Claude",
  codex: "Codex",
  copilot: "GitHub Copilot",
  grok: "Grok",
  kimi: "Kimi",
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function finiteNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function cleanText(value: unknown, maximum = 120): string | null {
  if (typeof value !== "string") return null;
  const cleaned = value
    .replace(/\u001b\[[0-?]*[ -/]*[@-~]/g, "")
    .replace(/[\u0000-\u001f\u007f-\u009f]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  if (!cleaned) return null;
  return cleaned.slice(0, maximum);
}

function parseTimestamp(value: unknown): number | null {
  if (
    typeof value !== "string" ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(value)
  ) return null;
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) && new Date(timestamp).toISOString() === value
    ? timestamp
    : null;
}

function exactEnum<T extends string>(value: unknown, allowed: readonly T[]): T | null {
  if (typeof value !== "string" || !allowed.includes(value as T)) return null;
  return value as T;
}

function exactText(value: unknown): string | null {
  if (typeof value !== "string" || value.length === 0) return null;
  return cleanText(value, value.length) === value ? value : null;
}

const QUOTA_WINDOW_KINDS = ["session", "weekly", "monthly", "model", "credits", "unknown"] as const;
const QUOTA_CREDIT_UNITS = ["usd", "credits"] as const;
const QUOTA_PROVIDER_SOURCES = ["oauth", "cli-rpc", "api", "web", "cache", "unavailable"] as const;
const QUOTA_FRESH_PROVIDER_SOURCES = ["oauth", "cli-rpc", "api", "web"] as const;
const QUOTA_PROVIDER_STATUSES = ["fresh", "stale", "unavailable", "auth_required", "rate_limited", "error"] as const;
const QUOTA_AUTH_STATUSES = ["usable", "expired_refreshable", "unusable"] as const;
const QUOTA_STATE_REASONS = ["keychain_access_required", "credentials_expired"] as const;
const QUOTA_IDENTITY_STATUSES = ["verified", "unverified"] as const;
const QUOTA_ATTEMPT_STATUSES = ["success", "failed", "skipped"] as const;
const QUOTA_PACE_STATUSES = ["ahead", "on_pace", "behind", "unknown"] as const;
const QUOTA_PACE_REASONS = [
  "stale",
  "missing_usage",
  "missing_cycle",
  "invalid_cycle",
  "future_cycle_start",
  "expired_reset",
  "unsupported_period",
] as const;
const QUOTA_PROJECTION_CONFIDENCES = ["early", "established"] as const;
const QUOTA_CYCLE_BASES = ["starts_at_resets_at", "window_seconds"] as const;
const QUOTA_SEMANTICS_STATUSES = ["known", "partial", "unknown"] as const;
const QUOTA_AVAILABILITY_STATUSES = ["known", "unknown"] as const;
const QUOTA_EFFECTIVE_PACE_STATUSES = ["ahead", "on_pace", "behind", "mixed", "unknown"] as const;
const QUOTA_RUNWAY_STATUSES = ["exhausted_now", "projected_exhaustion", "through_reset", "unknown"] as const;
const QUOTA_SELECTION_STATUSES = ["known", "unknown"] as const;

export function quotaProviderForPiProvider(piProvider: string): string | null {
  return PI_PROVIDER_TO_QUOTA_PROVIDER[piProvider] ?? null;
}

export function parseQuotaAxiJson(
  raw: string,
  options: { projection?: QuotaAxiProjection; expectedProvider?: string } = {},
): ParsedQuotaAxiReport | null {
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    return null;
  }
  if (
    !isRecord(value) ||
    !Array.isArray(value.providers) ||
    (value.help !== undefined && (
      !Array.isArray(value.help) ||
      value.help.some((entry) => typeof entry !== "string")
    ))
  ) return null;
  const generatedAtMs = parseTimestamp(value.generatedAt);
  const schemaVersion = finiteNumber(value.schemaVersion);
  if (
    generatedAtMs === null ||
    schemaVersion === null ||
    !Number.isInteger(schemaVersion) ||
    (schemaVersion !== 3 && schemaVersion !== 5)
  ) {
    return null;
  }
  if (options.expectedProvider !== undefined && (
    value.providers.length !== 1 ||
    !isRecord(value.providers[0]) ||
    value.providers[0].provider !== options.expectedProvider
  )) return null;
  return {
    generatedAtMs,
    schemaVersion,
    projection: options.projection ?? "default",
    providers: value.providers,
  };
}

function malformed(provider: string): QuotaView {
  return { kind: "malformed", provider };
}

function isFreshAt(generatedAtMs: number, freshUntilMs: number, nowMs: number): boolean {
  return generatedAtMs <= nowMs + 60_000 && nowMs < freshUntilMs;
}

export function revalidateFreshQuotaView(view: FreshQuotaView, nowMs = Date.now()): QuotaView {
  if (!isFreshAt(view.freshnessTimestampMs, view.reportFreshUntilMs, nowMs)) {
    return { kind: "stale", provider: view.provider, label: view.label };
  }
  if (view.publicationWindows === undefined && nowMs < view.freshUntilMs) return view;

  const publicationWindows = view.publicationWindows ?? view.windows;
  let freshUntilMs = view.reportFreshUntilMs;
  const windows = publicationWindows.filter((window) => {
    if (window.resetsAtMs === null) return true;
    if (window.resetsAtMs <= nowMs) return false;
    freshUntilMs = Math.min(freshUntilMs, window.resetsAtMs);
    return true;
  });
  return {
    ...view,
    windows,
    freshUntilMs,
    publicationWindows: windows.length === publicationWindows.length
      ? undefined
      : publicationWindows,
  };
}

export function quotaPublicationFreshView(view: FreshQuotaView): FreshQuotaView {
  if (view.publicationWindows === undefined) return view;
  let freshUntilMs = view.reportFreshUntilMs;
  for (const window of view.publicationWindows) {
    if (window.resetsAtMs !== null) freshUntilMs = Math.min(freshUntilMs, window.resetsAtMs);
  }
  return {
    ...view,
    windows: view.publicationWindows,
    freshUntilMs,
    publicationWindows: undefined,
  };
}

function validOptionalNumber(
  value: unknown,
  predicate: (number: number) => boolean = () => true,
): boolean {
  if (value === undefined) return true;
  const parsed = finiteNumber(value);
  return parsed !== null && predicate(parsed);
}

function validOptionalTimestamp(value: unknown): boolean {
  return value === undefined || parseTimestamp(value) !== null;
}

function validTextArray(value: unknown): boolean {
  return Array.isArray(value) && value.every((entry) => exactText(entry) !== null);
}

function validNonemptyTextArray(value: unknown): value is string[] {
  return Array.isArray(value) &&
    value.length > 0 &&
    value.every((entry) => exactText(entry) !== null) &&
    new Set(value).size === value.length;
}

function validOptionalTextArray(value: unknown): boolean {
  return value === undefined || validTextArray(value);
}

function roundedPace(value: number): number {
  return Number(value.toFixed(4));
}

function equalPaceNumber(value: unknown, expected: number): boolean {
  const parsed = finiteNumber(value);
  return parsed !== null && Math.abs(parsed - expected) <= 0.0001;
}

function validKnownPaceAudit(
  pace: Record<string, unknown>,
  window: Record<string, unknown>,
  generatedAtMs: number,
  status: Exclude<(typeof QUOTA_PACE_STATUSES)[number], "unknown">,
  schemaVersion: number,
): boolean {
  const percentRemaining = finiteNumber(window.percentRemaining);
  if (percentRemaining === null) return false;
  const percentUsed = window.percentUsed === undefined
    ? 100 - percentRemaining
    : finiteNumber(window.percentUsed);
  if (percentUsed === null) return false;
  const resetsAtMs = parseTimestamp(window.resetsAt);
  if (resetsAtMs === null || resetsAtMs <= generatedAtMs) return false;

  let cycleBasis: (typeof QUOTA_CYCLE_BASES)[number];
  let cycleSeconds: number;
  let startsAtMs: number;
  if (window.startsAt !== undefined) {
    const parsedStartsAtMs = parseTimestamp(window.startsAt);
    if (
      parsedStartsAtMs === null ||
      parsedStartsAtMs > generatedAtMs ||
      parsedStartsAtMs >= resetsAtMs
    ) return false;
    cycleBasis = "starts_at_resets_at";
    startsAtMs = parsedStartsAtMs;
    cycleSeconds = (resetsAtMs - startsAtMs) / 1000;
  } else {
    const parsedWindowSeconds = finiteNumber(window.windowSeconds);
    if (parsedWindowSeconds === null || parsedWindowSeconds <= 0) return false;
    cycleBasis = "window_seconds";
    cycleSeconds = parsedWindowSeconds;
    startsAtMs = resetsAtMs - cycleSeconds * 1000;
    if (!Number.isFinite(startsAtMs) || startsAtMs > generatedAtMs) return false;
  }

  const remainingMs = resetsAtMs - generatedAtMs;
  const elapsedMs = generatedAtMs - startsAtMs;
  const timeRemainingPercent = 100 * remainingMs / (cycleSeconds * 1000);
  const elapsedPercent = 100 * elapsedMs / (cycleSeconds * 1000);
  const reservePercentPoints = percentRemaining - timeRemainingPercent;
  const expectedStatus = Math.abs(reservePercentPoints) <= 1
    ? "on_pace"
    : reservePercentPoints < 0
      ? "ahead"
      : "behind";
  if (
    status !== expectedStatus ||
    pace.cycleBasis !== cycleBasis ||
    !equalPaceNumber(pace.cycleSeconds, cycleSeconds) ||
    !equalPaceNumber(pace.timeRemainingPercent, roundedPace(timeRemainingPercent)) ||
    !equalPaceNumber(pace.elapsedPercent, roundedPace(elapsedPercent)) ||
    !equalPaceNumber(pace.reservePercentPoints, roundedPace(reservePercentPoints))
  ) return false;

  if (elapsedPercent > 0) {
    if (!equalPaceNumber(pace.burnMultiple, roundedPace(percentUsed / elapsedPercent))) return false;
  } else if (pace.burnMultiple !== undefined) {
    return false;
  }

  const projectedExhaustedAtMs = percentUsed > 0 && elapsedMs > 0
    ? generatedAtMs + percentRemaining / (percentUsed / elapsedMs)
    : Number.NaN;
  if (Number.isFinite(projectedExhaustedAtMs) && !Number.isNaN(new Date(projectedExhaustedAtMs).getTime())) {
    const parsedProjectionMs = parseTimestamp(pace.projectedExhaustedAt);
    const expectedConfidence = elapsedPercent < 10 ? "early" : "established";
    return parsedProjectionMs !== null &&
      Math.abs(parsedProjectionMs - projectedExhaustedAtMs) <= 1 &&
      pace.projectionConfidence === expectedConfidence &&
      (schemaVersion === 3
        ? pace.projectionBasis === "cycle_average"
        : pace.projectionBasis === undefined);
  }
  return pace.projectedExhaustedAt === undefined &&
    pace.projectionConfidence === undefined &&
    pace.projectionBasis === undefined;
}

function expectedUnknownPaceReason(
  window: Record<string, unknown>,
  generatedAtMs: number,
  providerIsStale: boolean,
): (typeof QUOTA_PACE_REASONS)[number] | null {
  if (providerIsStale) return "stale";
  const percentRemaining = finiteNumber(window.percentRemaining);
  const percentUsed = window.percentUsed === undefined
    ? percentRemaining === null ? null : 100 - percentRemaining
    : finiteNumber(window.percentUsed);
  if (percentRemaining === null || percentUsed === null) return "missing_usage";

  const resetsAtMs = parseTimestamp(window.resetsAt);
  if (resetsAtMs === null) return "missing_cycle";
  if (resetsAtMs <= generatedAtMs) return "expired_reset";
  if (window.startsAt !== undefined) {
    const startsAtMs = parseTimestamp(window.startsAt);
    if (startsAtMs === null || startsAtMs >= resetsAtMs) return "invalid_cycle";
    return startsAtMs > generatedAtMs ? "future_cycle_start" : null;
  }
  const windowSeconds = finiteNumber(window.windowSeconds);
  if (windowSeconds === null) return "missing_cycle";
  if (windowSeconds <= 0 || !Number.isFinite(windowSeconds * 1000)) return "invalid_cycle";
  const impliedStartsAtMs = resetsAtMs - windowSeconds * 1000;
  if (!Number.isFinite(impliedStartsAtMs) || Number.isNaN(new Date(impliedStartsAtMs).getTime())) {
    return "invalid_cycle";
  }
  return impliedStartsAtMs > generatedAtMs ? "future_cycle_start" : null;
}

function validPace(
  value: unknown,
  window: Record<string, unknown>,
  generatedAtMs: number,
  requireAuditFields: boolean,
  schemaVersion: number,
  providerIsStale: boolean,
): boolean {
  if (value === undefined) return schemaVersion !== 5 && !requireAuditFields;
  if (!isRecord(value)) return false;
  const status = exactEnum(value.status, QUOTA_PACE_STATUSES);
  const reason = value.reason === undefined ? null : exactEnum(value.reason, QUOTA_PACE_REASONS);
  if (!status || (value.reason !== undefined && !reason)) return false;
  if (!validOptionalNumber(value.timeRemainingPercent)) return false;
  if (!validOptionalNumber(value.elapsedPercent)) return false;
  if (!validOptionalNumber(value.reservePercentPoints)) return false;
  if (!validOptionalNumber(value.burnMultiple, (number) => number >= 0)) return false;
  if (!validOptionalTimestamp(value.projectedExhaustedAt)) return false;
  if (
    value.projectionConfidence !== undefined &&
    !exactEnum(value.projectionConfidence, QUOTA_PROJECTION_CONFIDENCES)
  ) return false;
  if (value.projectionBasis !== undefined && value.projectionBasis !== "cycle_average") return false;
  if (schemaVersion === 5 && value.projectionBasis !== undefined) return false;
  if (value.cycleBasis !== undefined && !exactEnum(value.cycleBasis, QUOTA_CYCLE_BASES)) return false;
  if (!validOptionalNumber(value.cycleSeconds, (number) => number > 0)) return false;

  const hasProjection = value.projectedExhaustedAt !== undefined;
  if (hasProjection !== (value.projectionConfidence !== undefined)) return false;
  if ((value.cycleBasis !== undefined) !== (value.cycleSeconds !== undefined)) return false;
  if (status === "unknown") {
    return reason === expectedUnknownPaceReason(window, generatedAtMs, providerIsStale) && [
      value.timeRemainingPercent,
      value.elapsedPercent,
      value.reservePercentPoints,
      value.burnMultiple,
      value.projectedExhaustedAt,
      value.projectionConfidence,
      value.projectionBasis,
      value.cycleBasis,
      value.cycleSeconds,
    ].every((field) => field === undefined);
  }
  if (value.reason !== undefined) return false;
  return !requireAuditFields || validKnownPaceAudit(
    value,
    window,
    generatedAtMs,
    status,
    schemaVersion,
  );
}

function parseWindow(
  value: unknown,
  generatedAtMs: number,
  requirePaceAudit: boolean,
  schemaVersion: number,
  providerIsStale: boolean,
): QuotaWindowView | null {
  if (!isRecord(value)) return null;
  const id = exactText(value.id);
  const label = cleanText(value.label);
  const kind = exactEnum(value.kind, QUOTA_WINDOW_KINDS);
  if (!id || !label || !kind) return null;
  if (!validOptionalNumber(value.percentUsed, (number) => number >= 0 && number <= 100)) return null;
  if (!validOptionalNumber(value.percentRemaining, (number) => number >= 0 && number <= 100)) return null;
  const percentUsed = value.percentUsed === undefined ? null : finiteNumber(value.percentUsed);
  const parsedPercentRemaining = value.percentRemaining === undefined
    ? null
    : finiteNumber(value.percentRemaining);
  if (
    percentUsed !== null &&
    parsedPercentRemaining !== null &&
    Math.abs(percentUsed + parsedPercentRemaining - 100) > Number.EPSILON * 400
  ) return null;
  if (!validOptionalTimestamp(value.startsAt) || !validOptionalTimestamp(value.resetsAt)) return null;
  if (!validOptionalNumber(value.windowSeconds, (number) => number > 0)) return null;
  if (!validOptionalNumber(value.spentUsd, (number) => number >= 0)) return null;
  if (!validOptionalNumber(value.limitUsd, (number) => number >= 0)) return null;
  if (!validPace(
    value.pace,
    value,
    generatedAtMs,
    requirePaceAudit,
    schemaVersion,
    providerIsStale,
  )) return null;

  const percentRemaining = value.percentRemaining === undefined
    ? null
    : finiteNumber(value.percentRemaining);
  const resetsAtMs = value.resetsAt === undefined ? null : parseTimestamp(value.resetsAt);
  const resetText = value.resetText === undefined ? null : cleanText(value.resetText);
  if (value.resetText !== undefined && resetText === null) return null;

  return { id, label, kind, percentRemaining, resetsAtMs, resetText };
}

function readableWindowDuration(windowSeconds: number): string {
  const hours = windowSeconds / 3600;
  return `${Number.isInteger(hours) ? hours : Number(hours.toFixed(2))}h`;
}

function matchesCodexWindowIdentity(
  window: Record<string, unknown>,
  actualId: string,
  expectedId: string,
  label: string,
  kind: QuotaWindowKind,
): boolean {
  return actualId === expectedId && window.label === label && window.kind === kind;
}

function matchesCodexModelWindowIdentity(
  window: Record<string, unknown>,
  id: string,
  suffix: string,
  labelSuffix: string,
): boolean {
  return id.startsWith("model:") &&
    id.endsWith(`:${suffix}`) &&
    id.length > `model::${suffix}`.length &&
    typeof window.label === "string" &&
    window.label.endsWith(` ${labelSuffix}`) &&
    window.label.length > labelSuffix.length + 1 &&
    window.kind === "model";
}

function codexWindowBaseIdentity(window: Record<string, unknown>): string | null {
  const rawId = exactText(window.id);
  if (rawId === null) return null;
  const id = rawId.replace(/_(?:[2-9]|[1-9]\d+)$/, "");
  const windowSeconds = window.windowSeconds === undefined
    ? null
    : finiteNumber(window.windowSeconds);
  if (window.windowSeconds !== undefined && (windowSeconds === null || windowSeconds <= 0)) return null;

  if (windowSeconds === null) {
    if (matchesCodexWindowIdentity(window, id, "five_hour", "session", "session")) return id;
    if (matchesCodexWindowIdentity(window, id, "weekly", "week", "weekly")) return id;
    if (
      matchesCodexWindowIdentity(
        window,
        id,
        "code_review_five_hour",
        "code review session",
        "session",
      ) ||
      matchesCodexWindowIdentity(
        window,
        id,
        "code_review_weekly",
        "code review week",
        "weekly",
      ) ||
      matchesCodexModelWindowIdentity(window, id, "5h", "session") ||
      matchesCodexModelWindowIdentity(window, id, "7d", "week")
    ) return id;
    return null;
  }

  if (windowSeconds === 18_000) {
    if (
      matchesCodexWindowIdentity(window, id, "five_hour", "session", "session") ||
      matchesCodexWindowIdentity(
        window,
        id,
        "code_review_five_hour",
        "code review session",
        "session",
      ) ||
      matchesCodexModelWindowIdentity(window, id, "5h", "session")
    ) return id;
    return null;
  }

  if (windowSeconds === 604_800) {
    if (
      matchesCodexWindowIdentity(window, id, "weekly", "week", "weekly") ||
      matchesCodexWindowIdentity(
        window,
        id,
        "code_review_weekly",
        "code review week",
        "weekly",
      ) ||
      matchesCodexModelWindowIdentity(window, id, "7d", "week")
    ) return id;
    return null;
  }

  const duration = readableWindowDuration(windowSeconds);
  if (
    matchesCodexWindowIdentity(window, id, `window:${duration}`, `${duration} window`, "unknown") ||
    matchesCodexWindowIdentity(
      window,
      id,
      `code_review_window:${duration}`,
      `${duration} window`,
      "unknown",
    ) ||
    matchesCodexModelWindowIdentity(window, id, `window:${duration}`, `${duration} window`)
  ) return id;
  return null;
}

function validCodexWindowIdentities(windows: Record<string, unknown>[]): boolean {
  const counts = new Map<string, number>();
  for (const window of windows) {
    const baseId = codexWindowBaseIdentity(window);
    if (baseId === null) return false;
    const count = (counts.get(baseId) ?? 0) + 1;
    counts.set(baseId, count);
    if (window.id !== (count === 1 ? baseId : `${baseId}_${count}`)) return false;
  }
  return true;
}

function parseCredits(value: unknown): QuotaCreditsView | null | undefined {
  if (value === undefined) return undefined;
  if (!isRecord(value)) return null;

  let remaining: number | null = null;
  if (value.remaining !== undefined) {
    remaining = finiteNumber(value.remaining);
    if (remaining === null) return null;
  }
  let unlimited: boolean | null = null;
  if (value.unlimited !== undefined) {
    if (typeof value.unlimited !== "boolean") return null;
    unlimited = value.unlimited;
  }
  const unit = value.unit === undefined ? null : exactEnum(value.unit, QUOTA_CREDIT_UNITS);
  if (value.unit !== undefined && unit === null) return null;
  return { remaining, unlimited, unit };
}

type ParsedAccount = {
  accountId: string | null;
  accountIdMalformed: boolean;
  identityStatus: "verified" | "unverified" | null;
};

type ParsedAttempt = {
  source: string;
  status: "success" | "failed" | "skipped";
  error: string | null;
  credentialPresent: boolean | null;
};

function parseAccount(value: unknown): ParsedAccount | null | undefined {
  if (value === undefined) return undefined;
  if (!isRecord(value)) return null;
  if (value.email !== undefined && typeof value.email !== "string") return null;
  if (value.organization !== undefined && typeof value.organization !== "string") return null;
  if (value.accountId !== undefined && typeof value.accountId !== "string") return null;
  const accountId = value.accountId === undefined ? null : exactText(value.accountId);
  const accountIdMalformed = value.accountId !== undefined && accountId === null;
  const identityStatus = value.identityStatus === undefined
    ? null
    : exactEnum(value.identityStatus, QUOTA_IDENTITY_STATUSES);
  if (value.identityStatus !== undefined && identityStatus === null) return null;
  return { accountId, accountIdMalformed, identityStatus };
}

function parseAttempts(value: unknown): ParsedAttempt[] | null | undefined {
  if (value === undefined) return undefined;
  if (!Array.isArray(value)) return null;
  const attempts: ParsedAttempt[] = [];
  for (const entry of value) {
    if (!isRecord(entry)) return null;
    const source = exactText(entry.source);
    const status = exactEnum(entry.status, QUOTA_ATTEMPT_STATUSES);
    const error = entry.error === undefined ? null : exactText(entry.error);
    const credentialPresent = entry.credentialPresent === undefined
      ? null
      : typeof entry.credentialPresent === "boolean" ? entry.credentialPresent : null;
    if (
      !source ||
      !status ||
      (entry.error !== undefined && error === null) ||
      (entry.credentialPresent !== undefined && credentialPresent === null) ||
      (status === "success" && error !== null)
    ) return null;
    attempts.push({ source, status, error, credentialPresent });
  }
  return attempts;
}

function exactStringArray(value: unknown, expected: string[]): boolean {
  return Array.isArray(value) &&
    value.length === expected.length &&
    value.every((entry, index) => entry === expected[index]);
}

function validFreshAttemptSource(
  provider: string,
  source: string,
  attempts: ParsedAttempt[],
): boolean {
  const successes = attempts.filter((attempt) => attempt.status === "success");
  if (provider === "claude" && source === "oauth") {
    const primary = successes.filter((attempt) => (
      attempt.source === "oauth-file" || attempt.source === "keychain"
    ));
    return primary.length === 1 && successes.every((attempt) => (
      attempt.source === primary[0]?.source || attempt.source === "oauth-profile"
    ));
  }
  if (provider === "kimi" && source === "api") {
    return successes.length === 1 && (
      successes[0]?.source === "pi:kimi-coding" ||
      successes[0]?.source === "kimi-code-cli"
    );
  }
  if (provider === "codex") {
    return (source === "oauth" || source === "cli-rpc") &&
      successes.length === 1 && successes[0]?.source === source;
  }
  return successes.length === 1 && successes[0]?.source === source;
}

function validCodexAttemptGrammar(
  source: string | null,
  status: string | null,
  attempts: ParsedAttempt[],
): boolean {
  const oauth = attempts[0];
  if (
    !oauth ||
    oauth.source !== "oauth" ||
    oauth.credentialPresent !== null ||
    (oauth.status === "success" && oauth.error !== null) ||
    (oauth.status === "failed" && oauth.error === null) ||
    (oauth.status === "skipped" && ![
      "credentials_missing",
      "credentials_expired",
      "credentials_invalid",
    ].includes(oauth.error ?? ""))
  ) return false;
  if (oauth.status === "success") {
    return attempts.length === 1 && status === "fresh" && source === "oauth";
  }

  const cli = attempts[1];
  if (
    attempts.length !== 2 ||
    !cli ||
    cli.source !== "cli-rpc" ||
    cli.credentialPresent !== null ||
    cli.status === "skipped" ||
    (cli.status === "success" ? cli.error !== null : cli.error === null)
  ) return false;
  return cli.status === "success"
    ? status === "fresh" && source === "cli-rpc"
    : status !== "fresh";
}

function validAttemptProvenance(
  provider: string,
  source: string | null,
  status: string | null,
  sourcesTried: unknown,
  attempts: ParsedAttempt[] | undefined,
  requireFullFields: boolean,
): boolean {
  if (attempts === undefined) return !requireFullFields;
  const attemptedSources = attempts.map((attempt) => attempt.source);
  const expectedSources = status === "stale"
    ? [...new Set([...attemptedSources, "cache"])]
    : attemptedSources;
  if (
    !exactStringArray(sourcesTried, expectedSources) ||
    (provider === "codex" && !validCodexAttemptGrammar(source, status, attempts))
  ) return false;
  if (status === "fresh") {
    return source !== null && validFreshAttemptSource(provider, source, attempts);
  }
  return attempts.every((attempt) => attempt.status !== "success");
}

function exactTextArray(value: unknown, expected: string[]): boolean {
  return expected.length === 0
    ? value === undefined
    : Array.isArray(value) &&
      value.length === expected.length &&
      value.every((entry, index) => entry === expected[index]);
}

function expectedEffectivePace(
  boundedBy: string[],
  rawWindowsById: ReadonlyMap<string, Record<string, unknown>>,
): {
  status: (typeof QUOTA_EFFECTIVE_PACE_STATUSES)[number];
  aheadWindowIds: string[];
  behindWindowIds: string[];
  onPaceWindowIds: string[];
  unknownWindowIds: string[];
  worstReservePercentPoints: number | null;
  worstReserveWindowId: string | null;
} {
  const aheadWindowIds: string[] = [];
  const behindWindowIds: string[] = [];
  const onPaceWindowIds: string[] = [];
  const unknownWindowIds: string[] = [];
  let worstReservePercentPoints: number | null = null;
  let worstReserveWindowId: string | null = null;
  for (const id of boundedBy) {
    const pace = rawWindowsById.get(id)?.pace;
    const paceRecord = isRecord(pace) ? pace : null;
    if (paceRecord?.status === "ahead") aheadWindowIds.push(id);
    else if (paceRecord?.status === "behind") behindWindowIds.push(id);
    else if (paceRecord?.status === "on_pace") onPaceWindowIds.push(id);
    else unknownWindowIds.push(id);
    const reserve = finiteNumber(paceRecord?.reservePercentPoints);
    if (reserve !== null && (worstReservePercentPoints === null || reserve < worstReservePercentPoints)) {
      worstReservePercentPoints = reserve;
      worstReserveWindowId = id;
    }
  }
  const knownCount = aheadWindowIds.length + behindWindowIds.length + onPaceWindowIds.length;
  const status = knownCount === 0
    ? "unknown"
    : aheadWindowIds.length > 0 && behindWindowIds.length > 0
      ? "mixed"
      : aheadWindowIds.length > 0
        ? "ahead"
        : behindWindowIds.length > 0
          ? "behind"
          : "on_pace";
  return {
    status,
    aheadWindowIds,
    behindWindowIds,
    onPaceWindowIds,
    unknownWindowIds,
    worstReservePercentPoints,
    worstReserveWindowId,
  };
}

function validEffectivePace(
  value: unknown,
  requireAuditFields: boolean,
  requireDerivedFields: boolean,
  boundedBy: string[],
  boundedBySet: ReadonlySet<string>,
  rawWindowsById: ReadonlyMap<string, Record<string, unknown>>,
): boolean {
  if (value === undefined) return !requireDerivedFields;
  if (!isRecord(value)) return false;
  const status = exactEnum(value.status, QUOTA_EFFECTIVE_PACE_STATUSES);
  if (!status) return false;
  const listFields = [
    "aheadWindowIds",
    "behindWindowIds",
    "onPaceWindowIds",
    "unknownWindowIds",
  ] as const;
  const seen = new Set<string>();
  for (const field of listFields) {
    const entries = value[field];
    if (entries === undefined) continue;
    if (!validNonemptyTextArray(entries)) return false;
    for (const entry of entries) {
      if (seen.has(entry) || !boundedBySet.has(entry)) return false;
      seen.add(entry);
    }
  }
  if (!validOptionalNumber(value.worstReservePercentPoints)) return false;
  const worstId = value.worstReserveWindowId === undefined
    ? null
    : exactText(value.worstReserveWindowId);
  if (value.worstReserveWindowId !== undefined && worstId === null) return false;
  if (worstId !== null && !boundedBySet.has(worstId)) return false;
  if ((value.worstReservePercentPoints !== undefined) !== (worstId !== null)) return false;

  if (requireAuditFields && seen.size !== boundedBy.length) return false;
  let structurallyValid: boolean;
  if (status === "unknown") {
    structurallyValid = value.aheadWindowIds === undefined &&
      value.behindWindowIds === undefined &&
      value.onPaceWindowIds === undefined &&
      value.worstReservePercentPoints === undefined &&
      validNonemptyTextArray(value.unknownWindowIds);
  } else {
    if (value.worstReservePercentPoints === undefined) return false;
    if (requireAuditFields && worstId !== null && !seen.has(worstId)) return false;
    if (status === "ahead") {
      structurallyValid = validNonemptyTextArray(value.aheadWindowIds) &&
        value.behindWindowIds === undefined;
    } else if (status === "behind") {
      structurallyValid = value.aheadWindowIds === undefined &&
        (!requireAuditFields || validNonemptyTextArray(value.behindWindowIds));
    } else if (status === "on_pace") {
      structurallyValid = value.aheadWindowIds === undefined &&
        value.behindWindowIds === undefined &&
        (!requireAuditFields || validNonemptyTextArray(value.onPaceWindowIds));
    } else {
      structurallyValid = validNonemptyTextArray(value.aheadWindowIds) &&
        (!requireAuditFields || validNonemptyTextArray(value.behindWindowIds));
    }
  }
  if (!structurallyValid || !requireAuditFields) return structurallyValid;

  const expected = expectedEffectivePace(boundedBy, rawWindowsById);
  return status === expected.status &&
    exactTextArray(value.aheadWindowIds, expected.aheadWindowIds) &&
    exactTextArray(value.behindWindowIds, expected.behindWindowIds) &&
    exactTextArray(value.onPaceWindowIds, expected.onPaceWindowIds) &&
    exactTextArray(value.unknownWindowIds, expected.unknownWindowIds) &&
    (expected.worstReservePercentPoints === null
      ? value.worstReservePercentPoints === undefined && value.worstReserveWindowId === undefined
      : value.worstReservePercentPoints === expected.worstReservePercentPoints &&
        value.worstReserveWindowId === expected.worstReserveWindowId);
}

function expectedEffectiveRunway(
  boundedBy: string[],
  rawWindowsById: ReadonlyMap<string, Record<string, unknown>>,
  generatedAtMs: number,
  schemaVersion: number,
): Record<string, unknown> {
  const windows = boundedBy.map((id) => rawWindowsById.get(id) as Record<string, unknown>);
  const exhausted = windows.find((window) => finiteNumber(window.percentRemaining) === 0);
  if (exhausted) {
    return {
      status: "exhausted_now",
      usableRunwaySeconds: 0,
      projectedExhaustedAt: new Date(generatedAtMs).toISOString(),
      limitingWindowId: exhausted.id,
    };
  }

  const unmeasurableWindowIds: string[] = [];
  const projections: Array<{
    window: Record<string, unknown>;
    exhaustedAtMs: number;
    confidence: "early" | "established";
  }> = [];
  let lowestConfidence: "early" | "established" = "established";
  for (const window of windows) {
    const id = window.id as string;
    const remaining = finiteNumber(window.percentRemaining);
    const pace = isRecord(window.pace) ? window.pace : null;
    const resetsAtMs = parseTimestamp(window.resetsAt);
    const explicitPercentUsed = finiteNumber(window.percentUsed);
    const zeroUse = remaining === 100 && (explicitPercentUsed === null || explicitPercentUsed === 0);
    if (window.resetsAt === undefined) {
      if (!zeroUse) unmeasurableWindowIds.push(id);
      continue;
    }
    if (
      remaining === null ||
      !pace ||
      pace.status === "unknown" ||
      resetsAtMs === null ||
      resetsAtMs <= generatedAtMs
    ) {
      unmeasurableWindowIds.push(id);
      continue;
    }
    if (zeroUse) {
      if ((finiteNumber(pace.elapsedPercent) ?? 0) < 10) lowestConfidence = "early";
      continue;
    }
    const exhaustedAtMs = parseTimestamp(pace.projectedExhaustedAt);
    const confidence = exactEnum(pace.projectionConfidence, QUOTA_PROJECTION_CONFIDENCES);
    if (exhaustedAtMs === null || exhaustedAtMs <= generatedAtMs || confidence === null) {
      unmeasurableWindowIds.push(id);
      continue;
    }
    if (confidence === "early") lowestConfidence = "early";
    if (exhaustedAtMs < resetsAtMs) projections.push({ window, exhaustedAtMs, confidence });
  }
  if (unmeasurableWindowIds.length > 0) {
    return { status: "unknown", unmeasurableWindowIds };
  }
  if (projections.length === 0) {
    return {
      status: "through_reset",
      projectionConfidence: lowestConfidence,
      ...(schemaVersion === 3 ? { projectionBasis: "cycle_average" } : {}),
    };
  }
  const limiting = projections.reduce((earliest, candidate) => (
    candidate.exhaustedAtMs < earliest.exhaustedAtMs ? candidate : earliest
  ));
  return {
    status: "projected_exhaustion",
    usableRunwaySeconds: Math.max(0, Math.round((limiting.exhaustedAtMs - generatedAtMs) / 1000)),
    projectedExhaustedAt: new Date(limiting.exhaustedAtMs).toISOString(),
    limitingWindowId: limiting.window.id,
    projectionConfidence: limiting.confidence,
    ...(schemaVersion === 3 ? { projectionBasis: "cycle_average" } : {}),
  };
}

function matchesExpectedRunway(
  value: Record<string, unknown>,
  expected: Record<string, unknown>,
): boolean {
  for (const field of [
    "status",
    "usableRunwaySeconds",
    "projectedExhaustedAt",
    "limitingWindowId",
    "projectionBasis",
  ] as const) {
    if (value[field] !== expected[field]) return false;
  }
  if (value.projectionConfidence !== expected.projectionConfidence) return false;
  const expectedBlockers = expected.unmeasurableWindowIds;
  return Array.isArray(expectedBlockers)
    ? exactTextArray(value.unmeasurableWindowIds, expectedBlockers as string[])
    : value.unmeasurableWindowIds === undefined;
}

function validRunway(
  value: unknown,
  boundedBy: string[],
  boundedBySet: ReadonlySet<string>,
  allowedBlockers: ReadonlySet<string>,
  unresolvedWindowIds: string[],
  windowsById: ReadonlyMap<string, QuotaWindowView>,
  rawWindowsById: ReadonlyMap<string, Record<string, unknown>>,
  generatedAtMs: number,
  schemaVersion: number,
  requireAuditFields: boolean,
  requireDerivedFields: boolean,
): boolean {
  if (value === undefined) return !requireDerivedFields;
  if (!isRecord(value)) return false;
  const status = exactEnum(value.status, QUOTA_RUNWAY_STATUSES);
  if (!status) return false;
  if (!validOptionalNumber(value.usableRunwaySeconds, (number) => number >= 0)) return false;
  if (!validOptionalTimestamp(value.projectedExhaustedAt)) return false;
  const limitingWindowId = value.limitingWindowId === undefined
    ? null
    : exactText(value.limitingWindowId);
  if (value.limitingWindowId !== undefined && limitingWindowId === null) return false;
  if (limitingWindowId !== null && !boundedBySet.has(limitingWindowId)) return false;
  const projectionConfidence = value.projectionConfidence === undefined
    ? null
    : exactEnum(value.projectionConfidence, QUOTA_PROJECTION_CONFIDENCES);
  if (value.projectionConfidence !== undefined && projectionConfidence === null) return false;
  if (value.projectionBasis !== undefined && value.projectionBasis !== "cycle_average") return false;
  if (
    value.unmeasurableWindowIds !== undefined &&
    !validNonemptyTextArray(value.unmeasurableWindowIds)
  ) return false;
  if (
    Array.isArray(value.unmeasurableWindowIds) &&
    value.unmeasurableWindowIds.some((id) => !allowedBlockers.has(id))
  ) return false;
  if (requireAuditFields) {
    const expected = unresolvedWindowIds.length > 0
      ? {
          status: "unknown",
          unmeasurableWindowIds: [...boundedBy, ...unresolvedWindowIds],
        }
      : expectedEffectiveRunway(boundedBy, rawWindowsById, generatedAtMs, schemaVersion);
    return matchesExpectedRunway(value, expected);
  }

  if (status === "unknown") {
    return value.usableRunwaySeconds === undefined &&
      value.projectedExhaustedAt === undefined &&
      value.limitingWindowId === undefined &&
      value.projectionConfidence === undefined &&
      value.projectionBasis === undefined &&
      validNonemptyTextArray(value.unmeasurableWindowIds);
  }
  if (value.unmeasurableWindowIds !== undefined) return false;
  const exhaustedWindowIds = boundedBy.filter(
    (id) => windowsById.get(id)?.percentRemaining === 0,
  );
  if (status === "exhausted_now") {
    return value.usableRunwaySeconds === 0 &&
      parseTimestamp(value.projectedExhaustedAt) === generatedAtMs &&
      limitingWindowId === exhaustedWindowIds[0] &&
      value.projectionConfidence === undefined &&
      value.projectionBasis === undefined;
  }
  if (exhaustedWindowIds.length > 0) return false;
  if (status === "projected_exhaustion") {
    const projectedExhaustedAtMs = parseTimestamp(value.projectedExhaustedAt);
    const usableRunwaySeconds = finiteNumber(value.usableRunwaySeconds);
    const limitingWindow = limitingWindowId === null ? undefined : windowsById.get(limitingWindowId);
    const limitingPercentRemaining = limitingWindow?.percentRemaining ?? null;
    return usableRunwaySeconds !== null &&
      projectedExhaustedAtMs !== null &&
      projectedExhaustedAtMs > generatedAtMs &&
      limitingPercentRemaining !== null &&
      limitingPercentRemaining > 0 &&
      limitingWindow?.resetsAtMs !== null &&
      limitingWindow?.resetsAtMs !== undefined &&
      projectedExhaustedAtMs < limitingWindow.resetsAtMs &&
      Math.abs((projectedExhaustedAtMs - generatedAtMs) / 1000 - usableRunwaySeconds) <= 0.5 &&
      projectionConfidence !== null &&
      (schemaVersion === 3
        ? value.projectionBasis === "cycle_average"
        : value.projectionBasis === undefined);
  }
  if (
    value.usableRunwaySeconds !== undefined ||
    value.projectedExhaustedAt !== undefined ||
    value.limitingWindowId !== undefined
  ) return false;
  return (schemaVersion === 5 || projectionConfidence !== null) && (schemaVersion === 3
    ? value.projectionBasis === "cycle_average"
    : value.projectionBasis === undefined);
}

function expectedEffectiveSelection(
  boundedBy: string[],
  rawWindowsById: ReadonlyMap<string, Record<string, unknown>>,
): { spendPriority: number | null; unmeasurableWindowIds: string[] } {
  const unmeasurableWindowIds: string[] = [];
  let weightedGapSum = 0;
  let cycleSecondsSum = 0;
  for (const id of boundedBy) {
    const window = rawWindowsById.get(id);
    const pace = isRecord(window?.pace) ? window.pace : null;
    const percentRemaining = finiteNumber(window?.percentRemaining);
    const timeRemainingPercent = finiteNumber(pace?.timeRemainingPercent);
    const cycleSeconds = finiteNumber(pace?.cycleSeconds);
    if (
      !pace ||
      pace.status === "unknown" ||
      percentRemaining === null ||
      timeRemainingPercent === null ||
      timeRemainingPercent < 0.01 ||
      cycleSeconds === null ||
      cycleSeconds <= 0
    ) {
      unmeasurableWindowIds.push(id);
      continue;
    }

    let burnMultiple = finiteNumber(pace.burnMultiple);
    if (burnMultiple === null) {
      const elapsedPercent = finiteNumber(pace.elapsedPercent);
      const explicitPercentUsed = finiteNumber(window?.percentUsed);
      const percentUsed = explicitPercentUsed ?? 100 - percentRemaining;
      if (elapsedPercent === null || elapsedPercent > 0 || percentUsed !== 0) {
        unmeasurableWindowIds.push(id);
        continue;
      }
      burnMultiple = 0;
    }
    const gap = percentRemaining / timeRemainingPercent - burnMultiple;
    if (!Number.isFinite(gap)) {
      unmeasurableWindowIds.push(id);
      continue;
    }
    weightedGapSum += gap * cycleSeconds;
    cycleSecondsSum += cycleSeconds;
  }
  if (unmeasurableWindowIds.length > 0) {
    return { spendPriority: null, unmeasurableWindowIds };
  }
  const priority = weightedGapSum / cycleSecondsSum;
  if (cycleSecondsSum <= 0 || !Number.isFinite(priority)) {
    return { spendPriority: null, unmeasurableWindowIds: [...boundedBy] };
  }
  return {
    spendPriority: roundedPace(Math.min(100, Math.max(-100, priority))),
    unmeasurableWindowIds,
  };
}

function validSelection(
  value: unknown,
  allowedBlockers: ReadonlySet<string>,
  forcedUnknownBlockers: string[] | null,
  boundedBy: string[],
  rawWindowsById: ReadonlyMap<string, Record<string, unknown>>,
  schemaVersion: number,
  requireAuditFields: boolean,
): boolean {
  if (value === undefined) return schemaVersion !== 5;
  if (schemaVersion !== 5 || !isRecord(value)) return false;
  const status = exactEnum(value.status, QUOTA_SELECTION_STATUSES);
  if (!status) return false;
  if (!validOptionalNumber(value.spendPriority, (number) => number >= -100 && number <= 100)) return false;
  if (
    value.unmeasurableWindowIds !== undefined &&
    !validNonemptyTextArray(value.unmeasurableWindowIds)
  ) return false;
  if (
    Array.isArray(value.unmeasurableWindowIds) &&
    value.unmeasurableWindowIds.some((id) => !allowedBlockers.has(id))
  ) return false;

  if (requireAuditFields) {
    const expected = forcedUnknownBlockers === null
      ? expectedEffectiveSelection(boundedBy, rawWindowsById)
      : { spendPriority: null, unmeasurableWindowIds: forcedUnknownBlockers };
    if (expected.spendPriority === null) {
      return status === "unknown" &&
        value.spendPriority === undefined &&
        exactTextArray(value.unmeasurableWindowIds, expected.unmeasurableWindowIds);
    }
    return status === "known" &&
      value.spendPriority === expected.spendPriority &&
      value.unmeasurableWindowIds === undefined;
  }

  if (status === "known") {
    return value.spendPriority !== undefined && value.unmeasurableWindowIds === undefined;
  }
  return value.spendPriority === undefined && validNonemptyTextArray(value.unmeasurableWindowIds);
}

function validEffectiveAvailability(
  value: unknown,
  requireAuditFields: boolean,
  requireDerivedFields: boolean,
  provider: string,
  providerIsStale: boolean,
  unresolvedWindowIds: string[],
  windowsById: ReadonlyMap<string, QuotaWindowView>,
  rawWindowsById: ReadonlyMap<string, Record<string, unknown>>,
  generatedAtMs: number,
  schemaVersion: number,
): boolean {
  if (!isRecord(value)) return false;
  const status = exactEnum(value.status, QUOTA_AVAILABILITY_STATUSES);
  if (exactText(value.scope) === null || !status) return false;
  if (!validOptionalNumber(value.effectivePercentRemaining, (number) => number >= 0 && number <= 100)) return false;
  if (!validNonemptyTextArray(value.boundedBy)) return false;
  const boundedBy = value.boundedBy;
  const boundedBySet = new Set(boundedBy);
  if (boundedBy.some((id) => !windowsById.has(id))) return false;
  if (
    value.limitingWindowIds !== undefined &&
    !validNonemptyTextArray(value.limitingWindowIds)
  ) return false;
  if (
    Array.isArray(value.limitingWindowIds) &&
    value.limitingWindowIds.some((id) => !boundedBySet.has(id))
  ) return false;
  const percentages = boundedBy.map((id) => windowsById.get(id)?.percentRemaining ?? null);
  const forcedUnknown = provider === "kimi" && unresolvedWindowIds.length > 0;
  const expectedStatus = providerIsStale ||
    forcedUnknown ||
    percentages.some((percentage) => percentage === null)
    ? "unknown"
    : "known";
  if (status !== expectedStatus) return false;
  if (status === "known") {
    if (
      value.effectivePercentRemaining === undefined ||
      !validNonemptyTextArray(value.limitingWindowIds)
    ) return false;
    const effectivePercentRemaining = Math.min(...percentages as number[]);
    const limitingWindowIds = boundedBy.filter(
      (id) => windowsById.get(id)?.percentRemaining === effectivePercentRemaining,
    );
    if (
      value.effectivePercentRemaining !== effectivePercentRemaining ||
      value.limitingWindowIds.length !== limitingWindowIds.length ||
      value.limitingWindowIds.some((id, index) => id !== limitingWindowIds[index])
    ) return false;
  } else if (value.effectivePercentRemaining !== undefined || value.limitingWindowIds !== undefined) {
    return false;
  }
  const allowedBlockers = new Set([...boundedBy, ...unresolvedWindowIds]);
  const forcedSelectionBlockers = forcedUnknown
    ? [...boundedBy, ...unresolvedWindowIds]
    : null;
  return validEffectivePace(
    value.pace,
    requireAuditFields,
    requireDerivedFields,
    boundedBy,
    boundedBySet,
    rawWindowsById,
  ) &&
    validRunway(
      value.runway,
      boundedBy,
      boundedBySet,
      allowedBlockers,
      provider === "kimi" ? unresolvedWindowIds : [],
      windowsById,
      rawWindowsById,
      generatedAtMs,
      schemaVersion,
      requireAuditFields,
      requireDerivedFields,
    ) &&
    validSelection(
      value.selection,
      allowedBlockers,
      forcedSelectionBlockers,
      boundedBy,
      rawWindowsById,
      schemaVersion,
      requireAuditFields,
    );
}

type ExpectedEffectiveAvailability = {
  scope: string;
  boundedBySegments: string[][];
};

type ExpectedQuotaSemantics = {
  status: (typeof QUOTA_SEMANTICS_STATUSES)[number];
  unresolvedWindowIds: string[] | null;
  effectiveAvailability: ExpectedEffectiveAvailability[];
};

function quotaAvailability(
  scope: string,
  ...boundedBySegments: string[][]
): ExpectedEffectiveAvailability {
  return { scope, boundedBySegments };
}

function windowIds(windows: QuotaWindowView[]): string[] {
  return windows.map((window) => window.id);
}

function exactSegmentedTextArray(value: unknown, segments: string[][]): boolean {
  if (!Array.isArray(value)) return false;
  let index = 0;
  for (const segment of segments) {
    for (const id of segment) {
      if (value[index] !== id) return false;
      index += 1;
    }
  }
  return index === value.length;
}

function codexModelScope(id: string): string {
  return id.replace(/_\d+$/, "").replace(/:(?:5h|7d|window:[^:]+)$/, "");
}

function expectedQuotaSemantics(
  provider: string,
  windows: QuotaWindowView[],
  untrustedWindowIds: string[],
  providerIsStale: boolean,
): ExpectedQuotaSemantics | null {
  let unresolvedWindowIds: string[] = [];
  let effectiveAvailability: ExpectedEffectiveAvailability[] = [];
  let baseStatus: (typeof QUOTA_SEMANTICS_STATUSES)[number];
  let requiresUnresolvedField = false;

  if (provider === "claude") {
    const account = windows.filter((window) => ["five_hour", "seven_day"].includes(window.id));
    const accountIds = windowIds(account);
    const models = windows.filter((window) => window.kind === "model");
    unresolvedWindowIds = windows
      .filter((window) => (
        !["five_hour", "seven_day", "extra_usage"].includes(window.id) &&
        window.kind !== "model"
      ))
      .map((window) => window.id);
    if (unresolvedWindowIds.length === 0) {
      if (account.length > 0) effectiveAvailability.push(quotaAvailability("all_models", accountIds));
      for (const model of models) {
        effectiveAvailability.push(quotaAvailability(model.id, accountIds, [model.id]));
      }
    }
    baseStatus = unresolvedWindowIds.length > 0
      ? "partial"
      : effectiveAvailability.length > 0 ? "known" : "unknown";
  } else if (provider === "codex") {
    const account = windows.filter((window) => (
      /^(?:five_hour|weekly)(?:_\d+)?$/.test(window.id) || window.id.startsWith("window:")
    ));
    const accountIds = windowIds(account);
    const codeReview = windows.filter((window) => (
      window.id.startsWith("code_review_five_hour") ||
      window.id.startsWith("code_review_weekly") ||
      window.id.startsWith("code_review_window:")
    ));
    const modelWindows = windows.filter((window) => window.kind === "model");
    const recognized = new Set([...account, ...codeReview, ...modelWindows]);
    unresolvedWindowIds = windows
      .filter((window) => !recognized.has(window))
      .map((window) => window.id);
    if (unresolvedWindowIds.length === 0) {
      if (account.length > 0) effectiveAvailability.push(quotaAvailability("all_models", accountIds));
      if (codeReview.length > 0) {
        effectiveAvailability.push(quotaAvailability("code_review", windowIds(codeReview)));
      }
      const models = new Map<string, string[]>();
      for (const window of modelWindows) {
        const scope = codexModelScope(window.id);
        const scoped = models.get(scope) ?? [];
        scoped.push(window.id);
        models.set(scope, scoped);
      }
      for (const [scope, scoped] of models) {
        effectiveAvailability.push(quotaAvailability(scope, accountIds, scoped));
      }
    }
    baseStatus = unresolvedWindowIds.length > 0
      ? "partial"
      : effectiveAvailability.length > 0 ? "known" : "unknown";
  } else if (provider === "grok") {
    const shared = windows.filter((window) => window.id === "credits");
    const sharedIds = windowIds(shared);
    const products = windows.filter((window) => window.id.startsWith("product:"));
    unresolvedWindowIds = windows
      .filter((window) => window.id !== "credits" && !window.id.startsWith("product:"))
      .map((window) => window.id);
    if (unresolvedWindowIds.length === 0) {
      if (shared.length > 0) effectiveAvailability.push(quotaAvailability("all_products", sharedIds));
      for (const product of products) {
        effectiveAvailability.push(quotaAvailability(product.id, sharedIds, [product.id]));
      }
    }
    baseStatus = unresolvedWindowIds.length > 0
      ? "partial"
      : effectiveAvailability.length > 0 ? "known" : "unknown";
  } else if (provider === "kimi") {
    const recognized = windows.filter((window) => ["weekly", "five_hour"].includes(window.id));
    unresolvedWindowIds = [
      ...new Set([
        ...windows
          .filter((window) => !["weekly", "five_hour"].includes(window.id))
          .map((window) => window.id),
        ...untrustedWindowIds,
      ]),
    ];
    if (recognized.length > 0) {
      effectiveAvailability = [quotaAvailability("all_models", windowIds(recognized))];
    }
    baseStatus = unresolvedWindowIds.length > 0
      ? "partial"
      : effectiveAvailability.length > 0 ? "known" : "unknown";
  } else if (provider === "cursor") {
    const recognizedIds = ["included_usage", "auto_usage", "api_usage", "spend_limit"];
    const recognized = windows.filter((window) => recognizedIds.includes(window.id));
    unresolvedWindowIds = windows
      .filter((window) => !recognizedIds.includes(window.id))
      .map((window) => window.id);
    if (recognized.length > 0) {
      effectiveAvailability = [quotaAvailability("all_models", windowIds(recognized))];
    }
    baseStatus = unresolvedWindowIds.length > 0
      ? "partial"
      : effectiveAvailability.length > 0 ? "known" : "unknown";
  } else if (provider === "copilot") {
    unresolvedWindowIds = windows.map((window) => window.id);
    baseStatus = "unknown";
    requiresUnresolvedField = true;
  } else {
    return null;
  }

  return {
    status: providerIsStale && baseStatus !== "partial" ? "unknown" : baseStatus,
    unresolvedWindowIds: unresolvedWindowIds.length > 0 || requiresUnresolvedField
      ? unresolvedWindowIds
      : null,
    effectiveAvailability,
  };
}

function validQuotaSemantics(
  value: unknown,
  requireDescription: boolean,
  requireAuditFields: boolean,
  requireDerivedFields: boolean,
  provider: string,
  windows: QuotaWindowView[],
  rawWindows: Record<string, unknown>[],
  generatedAtMs: number,
  schemaVersion: number,
  providerIsStale: boolean,
  untrustedWindowIds: string[],
): boolean {
  if (value === undefined) return true;
  if (!isRecord(value) || !Array.isArray(value.effectiveAvailability)) return false;
  const status = exactEnum(value.status, QUOTA_SEMANTICS_STATUSES);
  if (!status) return false;
  if (requireDescription && typeof value.description !== "string") return false;
  if (value.description !== undefined && typeof value.description !== "string") return false;
  if (!validOptionalTextArray(value.unresolvedWindowIds)) return false;
  const unresolvedWindowIds = Array.isArray(value.unresolvedWindowIds)
    ? value.unresolvedWindowIds as string[]
    : [];
  const expected = expectedQuotaSemantics(
    provider,
    windows,
    untrustedWindowIds,
    providerIsStale,
  );
  if (
    expected === null ||
    status !== expected.status ||
    (expected.unresolvedWindowIds === null
      ? value.unresolvedWindowIds !== undefined
      : !Array.isArray(value.unresolvedWindowIds) ||
        value.unresolvedWindowIds.length !== expected.unresolvedWindowIds.length ||
        value.unresolvedWindowIds.some(
          (id, index) => id !== expected.unresolvedWindowIds?.[index],
        ))
  ) return false;
  const windowsById = new Map(windows.map((window) => [window.id, window]));
  const rawWindowsById = new Map(rawWindows.map((window) => [exactText(window.id) ?? "", window]));
  if (
    windowsById.size !== windows.length ||
    rawWindowsById.size !== rawWindows.length ||
    rawWindowsById.has("")
  ) return false;
  if (
    !Array.isArray(value.effectiveAvailability) ||
    value.effectiveAvailability.length !== expected.effectiveAvailability.length
  ) return false;
  const scopes = new Set<string>();
  for (const [index, entry] of value.effectiveAvailability.entries()) {
    if (!isRecord(entry)) return false;
    const scope = exactText(entry.scope);
    const expectedEntry = expected.effectiveAvailability[index];
    if (
      scope === null ||
      scopes.has(scope) ||
      expectedEntry === undefined ||
      scope !== expectedEntry.scope ||
      !exactSegmentedTextArray(entry.boundedBy, expectedEntry.boundedBySegments) ||
      !validEffectiveAvailability(
        entry,
        requireAuditFields,
        requireDerivedFields,
        provider,
        providerIsStale,
        unresolvedWindowIds,
        windowsById,
        rawWindowsById,
        generatedAtMs,
        schemaVersion,
      )
    ) return false;
    scopes.add(scope);
  }
  return true;
}

function validProviderState(value: unknown, requireFullFields: boolean): boolean {
  if (!isRecord(value)) return false;
  const status = exactEnum(value.status, QUOTA_PROVIDER_STATUSES);
  if (!status || typeof value.stale !== "boolean") return false;
  if ((status === "stale") !== value.stale) return false;
  if (!validOptionalTimestamp(value.refreshedAt)) return false;
  if (requireFullFields && status === "fresh" && value.refreshedAt === undefined) return false;
  for (const field of ["error", "retryAfter", "remedyCommand"] as const) {
    if (value[field] !== undefined && typeof value[field] !== "string") return false;
  }
  const authStatus = value.authStatus === undefined
    ? null
    : exactEnum(value.authStatus, QUOTA_AUTH_STATUSES);
  if (value.authStatus !== undefined && authStatus === null) return false;
  if (status === "fresh" && authStatus !== null && authStatus !== "usable") return false;
  if (
    status === "fresh" &&
    (value.error !== undefined || value.retryAfter !== undefined || value.remedyCommand !== undefined)
  ) return false;
  const reason = value.reason === undefined
    ? null
    : exactEnum(value.reason, QUOTA_STATE_REASONS);
  if (value.reason !== undefined && reason === null) return false;
  if (status === "fresh" && reason !== null) return false;
  if (reason === "credentials_expired" && authStatus !== "expired_refreshable") return false;
  if (!validOptionalTextArray(value.untrustedWindowIds)) return false;
  if (requireFullFields && !validTextArray(value.sourcesTried)) return false;
  return validOptionalTextArray(value.sourcesTried);
}

function validProviderFields(
  value: Record<string, unknown>,
  schemaVersion: number,
  projection: QuotaAxiProjection,
  generatedAtMs: number,
): boolean {
  const requireFullFields = schemaVersion === 3 || projection === "full";
  if (value.label !== undefined && cleanText(value.label) === null) return false;
  if (value.source !== undefined && !exactEnum(value.source, QUOTA_PROVIDER_SOURCES)) return false;
  if (requireFullFields && (cleanText(value.label) === null || !exactEnum(value.source, QUOTA_PROVIDER_SOURCES))) {
    return false;
  }
  if (value.plan !== undefined && cleanText(value.plan, 48) === null) return false;
  if (!validProviderState(value.state, requireFullFields)) return false;
  const source = value.source === undefined ? null : exactEnum(value.source, QUOTA_PROVIDER_SOURCES);
  const status = isRecord(value.state)
    ? exactEnum(value.state.status, QUOTA_PROVIDER_STATUSES)
    : null;
  if (
    source !== null &&
    status !== null &&
    (status === "fresh"
      ? !QUOTA_FRESH_PROVIDER_SOURCES.includes(source as (typeof QUOTA_FRESH_PROVIDER_SOURCES)[number]) ||
        (value.provider === "codex" && source !== "oauth" && source !== "cli-rpc")
      : status === "stale"
        ? source !== "cache"
        : source !== "unavailable")
  ) return false;
  if (!Array.isArray(value.windows)) return false;
  const providerIsStale = isRecord(value.state) && value.state.stale === true;
  const parsedWindows = value.windows.map((window) => (
    parseWindow(window, generatedAtMs, requireFullFields, schemaVersion, providerIsStale)
  ));
  if (parsedWindows.some((window) => window === null)) return false;
  if (new Set(parsedWindows.map((window) => window?.id)).size !== parsedWindows.length) return false;
  const rawWindows = value.windows.filter(isRecord);
  if (
    rawWindows.length !== value.windows.length ||
    (value.provider === "codex" && !validCodexWindowIdentities(rawWindows))
  ) return false;
  if (
    value.provider === "codex" &&
    status === "fresh" &&
    requireFullFields &&
    (rawWindows.length === 0 || rawWindows.some((window) => (
      finiteNumber(window.percentUsed) === null || finiteNumber(window.percentRemaining) === null
    )))
  ) return false;
  if ((schemaVersion === 5 || projection === "full") && value.quotaSemantics === undefined) return false;
  const untrustedWindowIds = isRecord(value.state) && Array.isArray(value.state.untrustedWindowIds)
    ? value.state.untrustedWindowIds as string[]
    : [];
  const parsedWindowIds = new Set((parsedWindows as QuotaWindowView[]).map((window) => window.id));
  const provider = exactText(value.provider) ?? "";
  if (
    untrustedWindowIds.some((id) => parsedWindowIds.has(id)) ||
    (provider !== "kimi" && untrustedWindowIds.length > 0)
  ) return false;
  if (!validQuotaSemantics(
    value.quotaSemantics,
    requireFullFields,
    requireFullFields && !providerIsStale,
    schemaVersion === 5 || projection === "full",
    provider,
    parsedWindows as QuotaWindowView[],
    rawWindows,
    generatedAtMs,
    schemaVersion,
    providerIsStale,
    untrustedWindowIds,
  )) return false;
  if (parseCredits(value.credits) === null) return false;
  const account = parseAccount(value.account);
  const attempts = parseAttempts(value.attempts);
  if (account === null || attempts === null) return false;
  if (!validAttemptProvenance(
    exactText(value.provider) ?? "",
    source,
    status,
    isRecord(value.state) ? value.state.sourcesTried : undefined,
    attempts,
    requireFullFields,
  )) return false;
  return true;
}

export function quotaFailureReasonFromReport(
  report: ParsedQuotaAxiReport,
  piProvider: string,
): Extract<QuotaFailureReason, "failed" | "timeout"> | null {
  const provider = quotaProviderForPiProvider(piProvider);
  if (!provider || report.providers.length !== 1) return null;
  const rawProvider = report.providers[0];
  if (
    !isRecord(rawProvider) ||
    rawProvider.provider !== provider ||
    !validProviderFields(
      rawProvider,
      report.schemaVersion,
      report.projection,
      report.generatedAtMs,
    ) ||
    !isRecord(rawProvider.state)
  ) return null;
  const status = exactEnum(rawProvider.state.status, QUOTA_PROVIDER_STATUSES);
  if (!status || status === "fresh") return null;
  const error = exactText(rawProvider.state.error);
  if (
    (provider === "kimi" && (error === "request_timeout" || error === "provider_timeout")) ||
    (provider === "codex" && error === "Codex quota request timed out")
  ) return "timeout";
  return "failed";
}

export function selectActiveProviderQuota(
  report: ParsedQuotaAxiReport,
  piProvider: string,
  options: {
    nowMs?: number;
    freshnessMs?: number;
    expectedAccountId?: string | null;
    expectedSuccessfulSource?: string;
  } = {},
): QuotaView {
  const provider = quotaProviderForPiProvider(piProvider);
  if (!provider) {
    return { kind: "unsupported", provider: cleanText(piProvider, 48) ?? "unknown", reason: "provider" };
  }

  const nowMs = options.nowMs ?? Date.now();
  const requestedFreshnessMs = options.freshnessMs ?? DEFAULT_QUOTA_FRESHNESS_MS;
  const freshnessMs = Number.isFinite(requestedFreshnessMs) && requestedFreshnessMs > 0
    ? requestedFreshnessMs
    : DEFAULT_QUOTA_FRESHNESS_MS;
  let freshnessTimestampMs = report.generatedAtMs;
  let reportFreshUntilMs = report.generatedAtMs + freshnessMs;
  if (nowMs >= reportFreshUntilMs) {
    return { kind: "stale", provider, label: null };
  }

  const providerMatches = report.providers.filter(
    (entry) => isRecord(entry) && entry.provider === provider,
  );
  if (providerMatches.length > 1) return malformed(provider);
  const rawProvider = providerMatches[0];
  if (!rawProvider || !isRecord(rawProvider)) {
    return { kind: "unavailable", provider, label: null };
  }

  const fullProjection = report.projection === "full";
  if (!validProviderFields(
    rawProvider,
    report.schemaVersion,
    report.projection,
    report.generatedAtMs,
  )) return malformed(provider);
  const label = rawProvider.label === undefined && report.schemaVersion === 5 && !fullProjection
    ? QUOTA_PROVIDER_LABELS[provider] ?? null
    : cleanText(rawProvider.label);
  const source = rawProvider.source === undefined && report.schemaVersion === 5 && !fullProjection
    ? null
    : exactEnum(rawProvider.source, QUOTA_PROVIDER_SOURCES);
  if (
    !label ||
    ((report.schemaVersion === 3 || fullProjection) && !source) ||
    (rawProvider.source !== undefined && !source) ||
    !isRecord(rawProvider.state)
  ) return malformed(provider);
  const status = exactEnum(rawProvider.state.status, QUOTA_PROVIDER_STATUSES);
  const sourcesTried = rawProvider.state.sourcesTried;
  if (
    typeof rawProvider.state.stale !== "boolean" ||
    !status ||
    ((report.schemaVersion === 3 || fullProjection) && !Array.isArray(sourcesTried)) ||
    (sourcesTried !== undefined && (
      !Array.isArray(sourcesTried) ||
      sourcesTried.some((entry) => exactText(entry) === null)
    ))
  ) return malformed(provider);
  if (rawProvider.state.stale || status === "stale") {
    return { kind: "stale", provider, label };
  }
  if (status !== "fresh") {
    return { kind: "unavailable", provider, label };
  }

  if (rawProvider.state.refreshedAt !== undefined) {
    const refreshedAtMs = parseTimestamp(rawProvider.state.refreshedAt);
    if (refreshedAtMs === null) return malformed(provider);
    freshnessTimestampMs = Math.max(freshnessTimestampMs, refreshedAtMs);
    reportFreshUntilMs = Math.min(reportFreshUntilMs, refreshedAtMs + freshnessMs);
  }

  if (!Array.isArray(rawProvider.windows)) return malformed(provider);
  const windows: QuotaWindowView[] = [];
  let freshUntilMs = reportFreshUntilMs;
  for (const rawWindow of rawProvider.windows) {
    const window = parseWindow(
      rawWindow,
      report.generatedAtMs,
      report.schemaVersion === 3 || fullProjection,
      report.schemaVersion,
      rawProvider.state.stale === true,
    );
    if (!window) return malformed(provider);
    windows.push(window);
    if (window.resetsAtMs !== null) {
      freshUntilMs = Math.min(freshUntilMs, window.resetsAtMs);
    }
  }

  const plan = rawProvider.plan === undefined ? null : cleanText(rawProvider.plan, 48);
  if (rawProvider.plan !== undefined && plan === null) return malformed(provider);
  const credits = parseCredits(rawProvider.credits);
  if (credits === null) return malformed(provider);
  const account = parseAccount(rawProvider.account);
  const attempts = parseAttempts(rawProvider.attempts);
  if (account === null || attempts === null) return malformed(provider);

  if (account?.identityStatus === "unverified") return { kind: "unverified", provider };
  if (account?.accountIdMalformed) {
    return options.expectedAccountId !== undefined
      ? { kind: "unverified", provider }
      : malformed(provider);
  }
  if (options.expectedAccountId === null) return { kind: "unverified", provider };
  if (
    options.expectedAccountId !== undefined &&
    account?.accountId !== options.expectedAccountId
  ) {
    return { kind: "unverified", provider };
  }
  if (options.expectedSuccessfulSource !== undefined) {
    if (!attempts?.some((attempt) => (
      attempt.source === options.expectedSuccessfulSource && attempt.status === "success"
    ))) {
      return { kind: "unverified", provider };
    }
    if (options.expectedAccountId === undefined) return { kind: "unverified", provider };
  }

  const freshView: FreshQuotaView = {
    kind: "fresh",
    provider,
    label,
    plan,
    windows,
    credits: credits ?? null,
    generatedAtMs: report.generatedAtMs,
    freshnessTimestampMs,
    reportFreshUntilMs,
    freshUntilMs,
  };
  const selected = revalidateFreshQuotaView(freshView, nowMs);
  if (
    selected.kind === "stale" &&
    nowMs < freshnessTimestampMs - 60_000 &&
    nowMs < reportFreshUntilMs
  ) return { ...selected, recoverable: freshView };
  if (selected.kind === "fresh" && selected.windows !== freshView.windows) {
    return { ...selected, publicationWindows: freshView.windows };
  }
  return selected;
}

function compactNumber(value: number): string {
  if (Number.isInteger(value)) return String(value);
  return value.toFixed(1).replace(/\.0$/, "");
}

function compactPositiveNumber(value: number): string {
  const compact = compactNumber(value);
  return value > 0 && Number(compact) === 0 ? "<0.1" : compact;
}

function compactSignedNumber(value: number): string {
  const compact = compactNumber(value);
  if (value > 0 && Number(compact) === 0) return "<0.1";
  if (value < 0 && Number(compact) === 0) return "-<0.1";
  return compact;
}

function compactPercentage(value: number): string {
  const compact = compactPositiveNumber(value);
  return value < 100 && Number(compact) === 100 ? ">99.9" : compact;
}

function formatReset(window: QuotaWindowView, nowMs: number): string {
  if (window.resetsAtMs !== null) {
    const deltaMs = window.resetsAtMs - nowMs;
    if (deltaMs <= 0) return "reset due";
    const minutes = Math.max(1, Math.ceil(deltaMs / 60_000));
    if (minutes < 60) return `resets ${minutes}m`;
    const hours = Math.floor(minutes / 60);
    const remainingMinutes = minutes % 60;
    if (hours < 24) return `resets ${hours}h${remainingMinutes ? `${remainingMinutes}m` : ""}`;
    const days = Math.floor(hours / 24);
    const remainingHours = hours % 24;
    return `resets ${days}d${remainingHours ? `${remainingHours}h` : ""}`;
  }
  if (window.resetText) return `resets ${window.resetText}`;
  return "reset unknown";
}

function formatCredits(credits: QuotaCreditsView): string {
  if (credits.unlimited === true) return "credits unlimited";
  if (credits.remaining !== null) {
    const unit = credits.unit && credits.unit !== "credits" ? ` ${credits.unit}` : "";
    return `credits ${compactSignedNumber(credits.remaining)}${unit}`;
  }
  return credits.unlimited === false ? "credits unavailable" : "credits unknown";
}

const UNSUPPORTED_TEXT: Readonly<Record<QuotaUnsupportedReason, { detail: string; compact: string }>> = {
  provider: { detail: "", compact: "Quota: unsupported" },
  "no-model": { detail: "no model", compact: "Quota: no model" },
  "auth-inspection": { detail: "auth inspection unavailable", compact: "Quota: auth unknown" },
  "non-subscription-auth": { detail: "non-subscription auth", compact: "Quota: unsupported auth" },
  "auth-timeout": { detail: "auth timed out", compact: "Quota: auth timeout" },
  "auth-cancelled": { detail: "auth cancelled", compact: "Quota: auth cancelled" },
  "auth-overflow": { detail: "auth data too large", compact: "Quota: auth too large" },
  "auth-unavailable": { detail: "auth unavailable", compact: "Quota: auth unavailable" },
  "provider-override": { detail: "provider override", compact: "Quota: provider override" },
  "custom-endpoint": { detail: "custom endpoint", compact: "Quota: custom endpoint" },
  "account-correlation": { detail: "account correlation unavailable", compact: "Quota: account unknown" },
  "credential-monitoring": {
    detail: "credential monitoring unavailable",
    compact: "Quota: monitor failed",
  },
};

const FAILURE_TEXT: Readonly<Record<QuotaFailureReason, { long: string; compact: string }>> = {
  missing: { long: "quota-axi missing", compact: "missing" },
  failed: { long: "quota-axi failed", compact: "failed" },
  timeout: { long: "quota-axi timed out", compact: "timeout" },
  overflow: { long: "quota-axi output too large", compact: "overflow" },
  cancelled: { long: "quota refresh cancelled", compact: "cancelled" },
};

const REFRESH_ISSUE_TEXT: Readonly<Record<QuotaRefreshIssue, { long: string; compact: string }>> = {
  ...FAILURE_TEXT,
  malformed: { long: "malformed data", compact: "malformed" },
  unverified: { long: "account unverified", compact: "unverified" },
  "auth-timeout": { long: "auth timed out", compact: "auth timeout" },
  "auth-cancelled": { long: "auth cancelled", compact: "auth cancelled" },
  "auth-overflow": { long: "auth data too large", compact: "auth too large" },
  "auth-unavailable": { long: "auth unavailable", compact: "auth unavailable" },
};

function firstFitting(candidates: string[], width: number): string {
  for (const candidate of candidates) {
    if (visibleWidth(candidate) <= width) return candidate;
  }
  return truncateToWidth(candidates[candidates.length - 1] ?? "", Math.max(0, width), "…");
}

function fitExplicitNarrow(
  label: string,
  windows: number,
  width: number,
  refreshFailure?: QuotaRefreshIssue | null,
): string {
  const count = `${windows} window${windows === 1 ? "" : "s"}`;
  const failure = refreshFailure ? REFRESH_ISSUE_TEXT[refreshFailure].compact : null;
  const candidates = failure
    ? [
        `Quota ${label}: narrow - ${count} cached; refresh ${failure}`,
        `Quota: narrow - ${count} cached; ${failure}`,
        `Quota: narrow (${windows}w; ${failure})`,
        `Quota: narrow; ${failure}`,
      ]
    : [
        `Quota ${label}: narrow - ${count}; widen for details`,
        `Quota: narrow - ${count}; widen`,
        `Quota: narrow (${windows}w)`,
        "Quota: narrow",
      ];
  return firstFitting(candidates, width);
}

export function formatQuotaStatus(view: QuotaView, width: number, nowMs = Date.now()): string {
  const safeWidth = Number.isFinite(width) ? Math.max(0, Math.floor(width)) : 0;
  if (safeWidth === 0) return "";

  if (view.kind === "refreshing") {
    return truncateToWidth("Quota: refreshing", safeWidth, "…");
  }
  if (view.kind === "unsupported") {
    const reason = UNSUPPORTED_TEXT[view.reason];
    const provider = cleanText(view.provider, 48) ?? "unknown";
    const long = view.reason === "no-model"
      ? "Quota: unavailable (no model)"
      : `Quota: unavailable for ${provider}${reason.detail ? ` (${reason.detail})` : ""}`;
    return firstFitting([long, reason.compact], safeWidth);
  }
  if (view.kind === "unavailable") {
    const label = view.label ? ` ${view.label}` : "";
    return truncateToWidth(`Quota${label}: unavailable`, safeWidth, "…");
  }
  if (view.kind === "failure") {
    const reason = FAILURE_TEXT[view.reason];
    return firstFitting([
      `Quota: unavailable (${reason.long})`,
      `Quota: ${reason.compact}`,
    ], safeWidth);
  }
  if (view.kind === "unverified") {
    return firstFitting([
      "Quota: unavailable (account unverified)",
      "Quota: account unknown",
    ], safeWidth);
  }
  if (view.kind === "stale") {
    const label = view.label ? ` ${view.label}` : "";
    return truncateToWidth(`Quota${label}: stale`, safeWidth, "…");
  }
  if (view.kind === "malformed") {
    return truncateToWidth("Quota: unavailable (malformed data)", safeWidth, "…");
  }

  const narrow = () => fitExplicitNarrow(
    view.label,
    view.windows.length,
    safeWidth,
    view.refreshFailure,
  );
  let full = view.plan ? `Quota ${view.label} (plan ${view.plan})` : `Quota ${view.label}`;
  let fullWidth = visibleWidth(full);
  const append = (part: string): boolean => {
    const partWidth = visibleWidth(part);
    if (fullWidth + 3 + partWidth > safeWidth) return false;
    full += ` | ${part}`;
    fullWidth += 3 + partWidth;
    return true;
  };
  if (fullWidth > safeWidth) return narrow();

  if (view.windows.length === 0) {
    if (!append("no quota windows")) return narrow();
  } else {
    for (const window of view.windows) {
      const remaining = window.percentRemaining === null
        ? "remaining unknown"
        : `${compactPercentage(window.percentRemaining)}% left`;
      const part = `${window.label} ${remaining} ${formatReset(window, nowMs).replace(/^resets /, "reset ")}`;
      if (!append(part)) return narrow();
    }
  }
  if (view.credits && !append(formatCredits(view.credits))) return narrow();
  if (
    view.refreshFailure &&
    !append(`refresh unavailable (${REFRESH_ISSUE_TEXT[view.refreshFailure].long})`)
  ) return narrow();
  return full;
}

type FormattedQuotaCacheEntry = {
  formatted: string;
  computedAtMs: number;
  validUntilMs: number;
};

export function nextQuotaStatusTransitionMs(view: QuotaView, nowMs: number): number {
  if (view.kind !== "fresh" || !Number.isFinite(nowMs)) return Number.POSITIVE_INFINITY;
  let nextTransitionMs = Number.POSITIVE_INFINITY;
  for (const window of view.windows) {
    if (window.resetsAtMs === null || window.resetsAtMs <= nowMs) continue;
    const minutes = Math.max(1, Math.ceil((window.resetsAtMs - nowMs) / 60_000));
    const transitionMs = window.resetsAtMs - (minutes - 1) * 60_000;
    nextTransitionMs = Math.min(nextTransitionMs, transitionMs);
  }
  return nextTransitionMs;
}

export function createQuotaStatusFormatter(maxEntriesPerView = 8) {
  const entryLimit = Number.isFinite(maxEntriesPerView)
    ? Math.max(1, Math.floor(maxEntriesPerView))
    : 8;
  const cache = new WeakMap<QuotaView, Map<number, FormattedQuotaCacheEntry>>();
  return (view: QuotaView, width: number, nowMs = Date.now()): string => {
    const safeWidth = Number.isFinite(width) ? Math.max(0, Math.floor(width)) : 0;
    let entries = cache.get(view);
    const cached = entries?.get(safeWidth);
    if (
      cached !== undefined &&
      nowMs >= cached.computedAtMs &&
      nowMs < cached.validUntilMs
    ) return cached.formatted;
    const formatted = formatQuotaStatus(view, safeWidth, nowMs);
    if (!entries) {
      entries = new Map();
      cache.set(view, entries);
    }
    if (!entries.has(safeWidth) && entries.size >= entryLimit) {
      const oldest = entries.keys().next().value;
      if (oldest !== undefined) entries.delete(oldest);
    }
    entries.delete(safeWidth);
    entries.set(safeWidth, {
      formatted,
      computedAtMs: nowMs,
      validUntilMs: nextQuotaStatusTransitionMs(view, nowMs),
    });
    return formatted;
  };
}
