// Pure quota-axi JSON parsing and window extraction for the
// fm-quota-statusline Pi extension.
//
// This module has no Pi or terminal dependencies: it only normalizes the
// `quota-axi --provider <p> --json` schema (schemaVersion 3 observed) into a
// stable shape the renderer consumes. Defensive parsing keeps a malformed or
// partial document from crashing the footer: a structurally unusable document
// resolves to null so the caller can fall back to an unavailable state.
//
// quota-axi's own --help and current JSON output are the authoritative schema
// sources; this module never invents fields and exposes only what the JSON
// actually supplies, so a future window kind or reset timestamp appears
// automatically without a parser change.

/** A single quota window exactly as quota-axi reports it. */
export interface QuotaWindow {
	id: string;
	label: string;
	kind?: string;
	percentUsed?: number;
	percentRemaining?: number;
	resetsAt?: string;
	windowSeconds?: number;
}

/** One provider entry from quota-axi JSON. */
export interface QuotaProvider {
	provider: string;
	label?: string;
	windows: QuotaWindow[];
}

/** Normalized quota-axi document. */
export interface QuotaState {
	generatedAt?: string;
	schemaVersion?: number;
	providers: QuotaProvider[];
}

/** Freshness of the cached quota data shown to the captain. */
export type QuotaFetchStatus = "fresh" | "stale" | "unavailable";

function asNumber(value: unknown): number | undefined {
	if (typeof value === "number" && Number.isFinite(value)) {
		return value;
	}
	return undefined;
}

function asString(value: unknown): string | undefined {
	return typeof value === "string" && value.length > 0 ? value : undefined;
}

function parseWindow(raw: unknown): QuotaWindow | null {
	if (!raw || typeof raw !== "object") {
		return null;
	}
	const w = raw as Record<string, unknown>;
	const id = asString(w.id);
	const label = asString(w.label) ?? id;
	if (!id) {
		// An id-less window is not a quota window we can label, so drop it
		// rather than render an unlabeled percentage.
		return null;
	}
	return {
		id,
		label,
		kind: asString(w.kind),
		percentUsed: asNumber(w.percentUsed),
		percentRemaining: asNumber(w.percentRemaining),
		resetsAt: asString(w.resetsAt),
		windowSeconds: asNumber(w.windowSeconds),
	};
}

function parseProvider(raw: unknown): QuotaProvider | null {
	if (!raw || typeof raw !== "object") {
		return null;
	}
	const p = raw as Record<string, unknown>;
	const provider = asString(p.provider);
	if (!provider) {
		return null;
	}
	const windows: QuotaWindow[] = [];
	const rawWindows = Array.isArray(p.windows) ? p.windows : [];
	for (const rawWindow of rawWindows) {
		const window = parseWindow(rawWindow);
		if (window) {
			windows.push(window);
		}
	}
	return {
		provider,
		label: asString(p.label),
		windows,
	};
}

/**
 * Parse a raw quota-axi JSON string into a normalized QuotaState.
 *
 * Returns null when the document is not a JSON object or has no usable
 * providers array, so the renderer can show an unavailable state instead of
 * crashing on a transiently malformed response.
 */
export function parseQuotaJson(input: string): QuotaState | null {
	let parsed: unknown;
	try {
		parsed = JSON.parse(input);
	} catch {
		return null;
	}
	if (!parsed || typeof parsed !== "object") {
		return null;
	}
	const doc = parsed as Record<string, unknown>;
	const rawProviders = Array.isArray(doc.providers) ? doc.providers : [];
	if (rawProviders.length === 0) {
		return null;
	}
	const providers: QuotaProvider[] = [];
	for (const rawProvider of rawProviders) {
		const provider = parseProvider(rawProvider);
		if (provider) {
			providers.push(provider);
		}
	}
	if (providers.length === 0) {
		return null;
	}
	return {
		generatedAt: asString(doc.generatedAt),
		schemaVersion: asNumber(doc.schemaVersion),
		providers,
	};
}

/**
 * Extract the display windows for a named provider from a parsed state.
 *
 * Only windows with a real percentage (used or remaining) are returned: a
 * window without any percentage carries no information the footer can render,
 * so it is dropped rather than shown as a fabricated value.
 */
export function extractWindows(
	state: QuotaState | null,
	provider: string,
): QuotaWindow[] {
	if (!state) {
		return [];
	}
	const match = state.providers.find(
		(entry) => entry.provider === provider,
	);
	if (!match) {
		return [];
	}
	return match.windows.filter(
		(window) =>
			window.percentRemaining !== undefined ||
			window.percentUsed !== undefined,
	);
}

/**
 * Compact humanized countdown from `now` to an ISO reset timestamp.
 *
 * Returns undefined when the timestamp is missing or already in the past, so
 * the renderer omits reset information the quota data does not actually
 * supply.
 */
export function formatResetCountdown(
	resetsAt: string | undefined,
	now: number,
): string | undefined {
	if (!resetsAt) {
		return undefined;
	}
	const target = Date.parse(resetsAt);
	if (!Number.isFinite(target)) {
		return undefined;
	}
	const seconds = Math.round((target - now) / 1000);
	if (seconds <= 0) {
		return undefined;
	}
	const days = Math.floor(seconds / 86400);
	const hours = Math.floor((seconds % 86400) / 3600);
	const minutes = Math.floor((seconds % 3600) / 60);
	if (days >= 1) {
		return `${days}d`;
	}
	if (hours >= 1) {
		return `${hours}h`;
	}
	return `${minutes}m`;
}
