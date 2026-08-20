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
  freshUntilMs: number;
  refreshFailure?: QuotaFailureReason | null;
};

export type QuotaFailureReason = "missing" | "failed" | "timeout" | "overflow" | "cancelled";

export type QuotaView =
  | FreshQuotaView
  | { kind: "refreshing"; provider: string }
  | { kind: "unsupported"; provider: string }
  | { kind: "unavailable"; provider: string; label: string | null }
  | { kind: "failure"; provider: string; reason: QuotaFailureReason }
  | { kind: "unverified"; provider: string }
  | { kind: "stale"; provider: string; label: string | null }
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
  if (typeof value !== "string") return null;
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) ? timestamp : null;
}

function exactEnum<T extends string>(value: unknown, allowed: readonly T[]): T | null {
  if (typeof value !== "string" || !allowed.includes(value as T)) return null;
  return value as T;
}

function exactText(value: unknown, maximum = 200): string | null {
  if (typeof value !== "string" || value.length === 0 || value.length > maximum) return null;
  return cleanText(value, maximum) === value ? value : null;
}

const QUOTA_WINDOW_KINDS = ["session", "weekly", "monthly", "model", "credits", "unknown"] as const;
const QUOTA_CREDIT_UNITS = ["usd", "credits"] as const;
const QUOTA_PROVIDER_SOURCES = ["oauth", "cli-rpc", "api", "web", "cache", "unavailable"] as const;
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
  options: { projection?: QuotaAxiProjection } = {},
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

function validOptionalTextArray(value: unknown): boolean {
  return value === undefined || validTextArray(value);
}

function validPace(value: unknown): boolean {
  if (value === undefined) return true;
  if (!isRecord(value) || !exactEnum(value.status, QUOTA_PACE_STATUSES)) return false;
  if (value.reason !== undefined && !exactEnum(value.reason, QUOTA_PACE_REASONS)) return false;
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
  if (value.cycleBasis !== undefined && !exactEnum(value.cycleBasis, QUOTA_CYCLE_BASES)) return false;
  return validOptionalNumber(value.cycleSeconds, (number) => number > 0);
}

function parseWindow(value: unknown): QuotaWindowView | null {
  if (!isRecord(value)) return null;
  const id = exactText(value.id);
  const label = cleanText(value.label);
  const kind = exactEnum(value.kind, QUOTA_WINDOW_KINDS);
  if (!id || !label || !kind) return null;
  if (!validOptionalNumber(value.percentUsed, (number) => number >= 0 && number <= 100)) return null;
  if (!validOptionalNumber(value.percentRemaining, (number) => number >= 0 && number <= 100)) return null;
  if (!validOptionalTimestamp(value.startsAt) || !validOptionalTimestamp(value.resetsAt)) return null;
  if (!validOptionalNumber(value.windowSeconds, (number) => number > 0)) return null;
  if (!validOptionalNumber(value.spentUsd, (number) => number >= 0)) return null;
  if (!validOptionalNumber(value.limitUsd, (number) => number >= 0)) return null;
  if (!validPace(value.pace)) return null;

  const percentRemaining = value.percentRemaining === undefined
    ? null
    : finiteNumber(value.percentRemaining);
  const resetsAtMs = value.resetsAt === undefined ? null : parseTimestamp(value.resetsAt);
  const resetText = value.resetText === undefined ? null : cleanText(value.resetText);
  if (value.resetText !== undefined && resetText === null) return null;

  return { id, label, kind, percentRemaining, resetsAtMs, resetText };
}

function parseCredits(value: unknown): QuotaCreditsView | null | undefined {
  if (value === undefined) return undefined;
  if (!isRecord(value)) return null;

  let remaining: number | null = null;
  if (value.remaining !== undefined) {
    remaining = finiteNumber(value.remaining);
    if (remaining === null || remaining < 0) return null;
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
    if (!source || !status) return null;
    if (entry.error !== undefined && typeof entry.error !== "string") return null;
    if (entry.credentialPresent !== undefined && typeof entry.credentialPresent !== "boolean") return null;
    attempts.push({ source, status });
  }
  return attempts;
}

function validEffectivePace(value: unknown): boolean {
  if (value === undefined) return true;
  if (!isRecord(value) || !exactEnum(value.status, QUOTA_EFFECTIVE_PACE_STATUSES)) return false;
  if (!validOptionalTextArray(value.aheadWindowIds)) return false;
  if (!validOptionalTextArray(value.behindWindowIds)) return false;
  if (!validOptionalTextArray(value.onPaceWindowIds)) return false;
  if (!validOptionalTextArray(value.unknownWindowIds)) return false;
  if (!validOptionalNumber(value.worstReservePercentPoints)) return false;
  return value.worstReserveWindowId === undefined || exactText(value.worstReserveWindowId) !== null;
}

function validRunway(value: unknown): boolean {
  if (value === undefined) return true;
  if (!isRecord(value) || !exactEnum(value.status, QUOTA_RUNWAY_STATUSES)) return false;
  if (!validOptionalNumber(value.usableRunwaySeconds, (number) => number >= 0)) return false;
  if (!validOptionalTimestamp(value.projectedExhaustedAt)) return false;
  if (value.limitingWindowId !== undefined && exactText(value.limitingWindowId) === null) return false;
  if (
    value.projectionConfidence !== undefined &&
    !exactEnum(value.projectionConfidence, QUOTA_PROJECTION_CONFIDENCES)
  ) return false;
  if (value.projectionBasis !== undefined && value.projectionBasis !== "cycle_average") return false;
  return validOptionalTextArray(value.unmeasurableWindowIds);
}

function validSelection(value: unknown): boolean {
  if (value === undefined) return true;
  if (!isRecord(value) || !exactEnum(value.status, QUOTA_SELECTION_STATUSES)) return false;
  if (!validOptionalNumber(value.spendPriority, (number) => number >= -100 && number <= 100)) return false;
  return validOptionalTextArray(value.unmeasurableWindowIds);
}

function validEffectiveAvailability(value: unknown): boolean {
  if (!isRecord(value)) return false;
  if (exactText(value.scope) === null || !exactEnum(value.status, QUOTA_AVAILABILITY_STATUSES)) return false;
  if (!validOptionalNumber(value.effectivePercentRemaining, (number) => number >= 0 && number <= 100)) return false;
  if (!validTextArray(value.boundedBy) || !validOptionalTextArray(value.limitingWindowIds)) return false;
  return validEffectivePace(value.pace) && validRunway(value.runway) && validSelection(value.selection);
}

function validQuotaSemantics(value: unknown, requireDescription: boolean): boolean {
  if (value === undefined) return true;
  if (!isRecord(value) || !exactEnum(value.status, QUOTA_SEMANTICS_STATUSES)) return false;
  if (requireDescription && typeof value.description !== "string") return false;
  if (value.description !== undefined && typeof value.description !== "string") return false;
  if (
    !Array.isArray(value.effectiveAvailability) ||
    !value.effectiveAvailability.every(validEffectiveAvailability)
  ) return false;
  return validOptionalTextArray(value.unresolvedWindowIds);
}

function validProviderState(value: unknown, requireSourcesTried: boolean): boolean {
  if (!isRecord(value)) return false;
  if (!exactEnum(value.status, QUOTA_PROVIDER_STATUSES) || typeof value.stale !== "boolean") return false;
  if (!validOptionalTimestamp(value.refreshedAt)) return false;
  for (const field of ["error", "retryAfter", "remedyCommand"] as const) {
    if (value[field] !== undefined && typeof value[field] !== "string") return false;
  }
  if (value.authStatus !== undefined && !exactEnum(value.authStatus, QUOTA_AUTH_STATUSES)) return false;
  if (value.reason !== undefined && !exactEnum(value.reason, QUOTA_STATE_REASONS)) return false;
  if (!validOptionalTextArray(value.untrustedWindowIds)) return false;
  if (requireSourcesTried && !validTextArray(value.sourcesTried)) return false;
  return validOptionalTextArray(value.sourcesTried);
}

function validProviderFields(
  value: Record<string, unknown>,
  schemaVersion: number,
  projection: QuotaAxiProjection,
): boolean {
  const requireFullFields = schemaVersion === 3 || projection === "full";
  if (value.label !== undefined && cleanText(value.label) === null) return false;
  if (value.source !== undefined && !exactEnum(value.source, QUOTA_PROVIDER_SOURCES)) return false;
  if (requireFullFields && (cleanText(value.label) === null || !exactEnum(value.source, QUOTA_PROVIDER_SOURCES))) {
    return false;
  }
  if (value.plan !== undefined && cleanText(value.plan, 48) === null) return false;
  if (!validProviderState(value.state, requireFullFields)) return false;
  if (!Array.isArray(value.windows) || !value.windows.every((window) => parseWindow(window) !== null)) return false;
  if (!validQuotaSemantics(value.quotaSemantics, requireFullFields)) return false;
  if (parseCredits(value.credits) === null) return false;
  if (parseAccount(value.account) === null || parseAttempts(value.attempts) === null) return false;
  return true;
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
  if (!provider) return { kind: "unsupported", provider: cleanText(piProvider, 48) ?? "unknown" };

  const nowMs = options.nowMs ?? Date.now();
  const requestedFreshnessMs = options.freshnessMs ?? DEFAULT_QUOTA_FRESHNESS_MS;
  const freshnessMs = Number.isFinite(requestedFreshnessMs) && requestedFreshnessMs > 0
    ? requestedFreshnessMs
    : DEFAULT_QUOTA_FRESHNESS_MS;
  let freshUntilMs = report.generatedAtMs + freshnessMs;
  if (
    report.generatedAtMs > nowMs + 60_000 ||
    nowMs >= freshUntilMs
  ) {
    return { kind: "stale", provider, label: null };
  }

  const rawProvider = report.providers.find(
    (entry) => isRecord(entry) && entry.provider === provider,
  );
  if (!rawProvider || !isRecord(rawProvider)) {
    return { kind: "unavailable", provider, label: null };
  }

  const fullProjection = report.projection === "full";
  if (!validProviderFields(rawProvider, report.schemaVersion, report.projection)) return malformed(provider);
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
    freshUntilMs = Math.min(freshUntilMs, refreshedAtMs + freshnessMs);
    if (refreshedAtMs > nowMs + 60_000 || nowMs >= freshUntilMs) {
      return { kind: "stale", provider, label };
    }
  }

  if (!Array.isArray(rawProvider.windows)) return malformed(provider);
  const windows: QuotaWindowView[] = [];
  for (const rawWindow of rawProvider.windows) {
    const window = parseWindow(rawWindow);
    if (!window) return malformed(provider);
    windows.push(window);
  }
  for (const window of windows) {
    if (window.resetsAtMs === null) continue;
    freshUntilMs = Math.min(freshUntilMs, window.resetsAtMs);
  }
  if (nowMs >= freshUntilMs) return { kind: "stale", provider, label };

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
  if (
    options.expectedSuccessfulSource !== undefined &&
    !attempts?.some((attempt) => (
      attempt.source === options.expectedSuccessfulSource && attempt.status === "success"
    ))
  ) {
    return { kind: "unverified", provider };
  }

  return {
    kind: "fresh",
    provider,
    label,
    plan,
    windows,
    credits: credits ?? null,
    generatedAtMs: report.generatedAtMs,
    freshUntilMs,
  };
}

function compactNumber(value: number): string {
  if (Number.isInteger(value)) return String(value);
  return value.toFixed(1).replace(/\.0$/, "");
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
    return `credits ${compactNumber(credits.remaining)}${unit}`;
  }
  return credits.unlimited === false ? "credits unavailable" : "credits unknown";
}

const FAILURE_TEXT: Readonly<Record<QuotaFailureReason, { long: string; compact: string }>> = {
  missing: { long: "quota-axi missing", compact: "missing" },
  failed: { long: "quota-axi failed", compact: "failed" },
  timeout: { long: "quota-axi timed out", compact: "timeout" },
  overflow: { long: "quota-axi output too large", compact: "overflow" },
  cancelled: { long: "quota refresh cancelled", compact: "cancelled" },
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
  refreshFailure?: QuotaFailureReason | null,
): string {
  const count = `${windows} window${windows === 1 ? "" : "s"}`;
  const failure = refreshFailure ? FAILURE_TEXT[refreshFailure].compact : null;
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
  const safeWidth = Math.max(0, Math.floor(width));
  if (safeWidth === 0) return "";

  if (view.kind === "refreshing") {
    return truncateToWidth("Quota: refreshing", safeWidth, "…");
  }
  if (view.kind === "unsupported") {
    return truncateToWidth(`Quota: unavailable for ${view.provider}`, safeWidth, "…");
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
    return truncateToWidth("Quota: unavailable (account unverified)", safeWidth, "…");
  }
  if (view.kind === "stale") {
    const label = view.label ? ` ${view.label}` : "";
    return truncateToWidth(`Quota${label}: stale`, safeWidth, "…");
  }
  if (view.kind === "malformed") {
    return truncateToWidth("Quota: unavailable (malformed data)", safeWidth, "…");
  }

  const heading = view.plan ? `Quota ${view.label} (plan ${view.plan})` : `Quota ${view.label}`;
  const windowParts = view.windows.map((window) => {
    const remaining = window.percentRemaining === null
      ? "remaining unknown"
      : `${compactNumber(window.percentRemaining)}% left`;
    return `${window.label} ${remaining} ${formatReset(window, nowMs).replace(/^resets /, "reset ")}`;
  });
  const fullParts = [heading, ...(windowParts.length > 0 ? windowParts : ["no quota windows"])];
  if (view.credits) fullParts.push(formatCredits(view.credits));
  if (view.refreshFailure) {
    fullParts.push(`refresh unavailable (${FAILURE_TEXT[view.refreshFailure].long})`);
  }
  const full = fullParts.join(" | ");
  if (visibleWidth(full) <= safeWidth) return full;
  return fitExplicitNarrow(view.label, view.windows.length, safeWidth, view.refreshFailure);
}
