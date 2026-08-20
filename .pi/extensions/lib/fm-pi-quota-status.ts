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
};

export type QuotaView =
  | FreshQuotaView
  | { kind: "refreshing"; provider: string }
  | { kind: "unsupported"; provider: string }
  | { kind: "unavailable"; provider: string; label: string | null }
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
const QUOTA_IDENTITY_STATUSES = ["verified", "unverified"] as const;
const QUOTA_ATTEMPT_STATUSES = ["success", "failed", "skipped"] as const;

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
  if (!isRecord(value) || !Array.isArray(value.providers)) return null;
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

function parseWindow(value: unknown): QuotaWindowView | null {
  if (!isRecord(value)) return null;
  const id = cleanText(value.id);
  const label = cleanText(value.label);
  const kind = exactEnum(value.kind, QUOTA_WINDOW_KINDS);
  if (!id || !label || !kind) return null;

  let percentRemaining: number | null = null;
  if (value.percentRemaining !== undefined) {
    percentRemaining = finiteNumber(value.percentRemaining);
    if (percentRemaining === null || percentRemaining < 0 || percentRemaining > 100) return null;
  }

  let resetsAtMs: number | null = null;
  if (value.resetsAt !== undefined) {
    resetsAtMs = parseTimestamp(value.resetsAt);
    if (resetsAtMs === null) return null;
  }
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
    (report.schemaVersion === 3 && !Array.isArray(sourcesTried)) ||
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

function fitExplicitNarrow(label: string, windows: number, width: number): string {
  const count = `${windows} window${windows === 1 ? "" : "s"}`;
  const candidates = [
    `Quota ${label}: narrow - ${count}; widen for details`,
    `Quota: narrow - ${count}; widen`,
    `Quota: narrow (${windows}w)`,
    "Quota: narrow",
  ];
  for (const candidate of candidates) {
    if (visibleWidth(candidate) <= width) return candidate;
  }
  return truncateToWidth("Quota: narrow", Math.max(0, width), "…");
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
  const full = fullParts.join(" | ");
  if (visibleWidth(full) <= safeWidth) return full;
  return fitExplicitNarrow(view.label, view.windows.length, safeWidth);
}
