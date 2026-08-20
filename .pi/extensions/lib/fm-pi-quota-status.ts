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
  | { kind: "stale"; provider: string; label: string | null }
  | { kind: "malformed"; provider: string };

export type ParsedQuotaAxiReport = {
  generatedAtMs: number;
  schemaVersion: number;
  providers: unknown[];
};

const PI_PROVIDER_TO_QUOTA_PROVIDER: Readonly<Record<string, string>> = {
  anthropic: "claude",
  claude: "claude",
  "github-copilot": "copilot",
  copilot: "copilot",
  "kimi-coding": "kimi",
  kimi: "kimi",
  "openai-codex": "codex",
  codex: "codex",
  cursor: "cursor",
  xai: "grok",
  grok: "grok",
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

function cleanEnum<T extends string>(value: unknown, allowed: readonly T[]): T | null {
  const cleaned = cleanText(value, 48);
  if (!cleaned || !allowed.includes(cleaned as T)) return null;
  return cleaned as T;
}

const QUOTA_WINDOW_KINDS = ["session", "weekly", "monthly", "model", "credits", "unknown"] as const;
const QUOTA_CREDIT_UNITS = ["usd", "credits"] as const;
const QUOTA_PROVIDER_SOURCES = ["oauth", "cli-rpc", "api", "web", "cache", "unavailable"] as const;
const QUOTA_PROVIDER_STATUSES = ["fresh", "stale", "unavailable", "auth_required", "rate_limited", "error"] as const;

export function quotaProviderForPiProvider(piProvider: string): string | null {
  const normalized = piProvider.trim().toLowerCase();
  return PI_PROVIDER_TO_QUOTA_PROVIDER[normalized] ?? null;
}

export function parseQuotaAxiJson(raw: string): ParsedQuotaAxiReport | null {
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
  const kind = cleanEnum(value.kind, QUOTA_WINDOW_KINDS);
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
  const unit = value.unit === undefined ? null : cleanEnum(value.unit, QUOTA_CREDIT_UNITS);
  if (value.unit !== undefined && unit === null) return null;
  return { remaining, unlimited, unit };
}

export function selectActiveProviderQuota(
  report: ParsedQuotaAxiReport,
  piProvider: string,
  options: { nowMs?: number; freshnessMs?: number } = {},
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
    (entry) => isRecord(entry) && cleanText(entry.provider, 48)?.toLowerCase() === provider,
  );
  if (!rawProvider || !isRecord(rawProvider)) {
    return { kind: "unavailable", provider, label: null };
  }

  const label = cleanText(rawProvider.label);
  const source = cleanEnum(rawProvider.source, QUOTA_PROVIDER_SOURCES);
  if (!label || !source || !isRecord(rawProvider.state)) return malformed(provider);
  const status = cleanEnum(rawProvider.state.status, QUOTA_PROVIDER_STATUSES);
  const sourcesTried = rawProvider.state.sourcesTried;
  if (
    typeof rawProvider.state.stale !== "boolean" ||
    !status ||
    !Array.isArray(sourcesTried) ||
    sourcesTried.some((entry) => cleanText(entry) === null)
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

  if (!Array.isArray(rawProvider.windows) || rawProvider.windows.length === 0) {
    return { kind: "unavailable", provider, label };
  }
  const windows: QuotaWindowView[] = [];
  for (const rawWindow of rawProvider.windows) {
    const window = parseWindow(rawWindow);
    if (!window) return malformed(provider);
    windows.push(window);
  }

  const plan = rawProvider.plan === undefined ? null : cleanText(rawProvider.plan, 48);
  if (rawProvider.plan !== undefined && plan === null) return malformed(provider);
  const credits = parseCredits(rawProvider.credits);
  if (credits === null) return malformed(provider);

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
  const fullParts = [heading, ...windowParts];
  if (view.credits) fullParts.push(formatCredits(view.credits));
  const full = fullParts.join(" | ");
  if (visibleWidth(full) <= safeWidth) return full;
  return fitExplicitNarrow(view.label, view.windows.length, safeWidth);
}
