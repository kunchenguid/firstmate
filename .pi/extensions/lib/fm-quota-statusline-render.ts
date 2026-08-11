// Pure footer rendering for the fm-quota-statusline Pi extension.
//
// This module owns only the visible-width-safe composition of the footer
// lines. It takes already-normalized inputs (parsed by
// ./fm-quota-statusline-data.ts) plus the live Pi session values, and returns
// the rendered string lines. It has no timers, no subprocesses, and no Pi
// lifecycle coupling, so the focused tests can drive it directly through a
// thin node harness without booting the TUI.
//
// Layout (matches the captain's compact example):
//   line 1: <repoPath> (<branch>)
//   following lines: <ctx%> / <tokens>   <quota windows>   <model> <thinking>
//
// A stale quota cache keeps its last-good windows but prefixes the segment
// so the captain can see the data may be behind. An unavailable quota shows a
// concise marker and never fabricates a window or percentage.
//
// Narrow terminals use continuation lines so every field remains present
// without exceeding the available width.

import { visibleWidth } from "@earendil-works/pi-tui";
import type {
	QuotaFetchStatus,
	QuotaWindow,
} from "./fm-quota-statusline-data.ts";
import { formatResetCountdown } from "./fm-quota-statusline-data.ts";

/** Live session values the renderer needs from Pi. */
export interface RenderInput {
	/** Repository path for the first line (already shortened, e.g. ~/dev/proj). */
	repoPath: string;
	/** Current git branch, or null for detached/no repo. */
	branch: string | null;
	/** Context usage percent (0-100), or null when Pi has no estimate yet. */
	contextPercent: number | null;
	/** Context tokens used, or null. */
	contextTokens: number | null;
	/** Active model id, or null. */
	modelId: string | null;
	/** Effective thinking level, or null. */
	thinkingLevel: string | null;
	/** Verified quota windows to render. */
	windows: QuotaWindow[];
	/** Freshness of the windows (fresh / stale / unavailable). */
	quotaStatus: QuotaFetchStatus;
	/** Epoch milliseconds, used for reset countdowns. */
	now: number;
}

/**
 * Minimal theme surface the renderer needs.
 *
 * The real Pi Theme satisfies this; the indirection keeps the renderer
 * testable with a plain stub that does not depend on the full Theme type.
 */
export interface RenderTheme {
	fg: (color: string, text: string) => string;
}

const SEP = "   ";

function formatTokens(tokens: number | null): string {
	if (tokens === null || tokens <= 0) {
		return "?";
	}
	if (tokens < 1000) {
		return `${tokens}`;
	}
	if (tokens < 1_000_000) {
		return `${(tokens / 1000).toFixed(1)}k`;
	}
	return `${(tokens / 1_000_000).toFixed(1)}M`;
}

function renderContextSegment(input: RenderInput): string {
	if (input.contextPercent === null && input.contextTokens === null) {
		return "ctx: —";
	}
	const percent =
		input.contextPercent !== null ? `${input.contextPercent.toFixed(1)}%` : "?";
	return `ctx ${percent} / ${formatTokens(input.contextTokens)}`;
}

function renderWindowSegment(window: QuotaWindow, now: number): string {
	const remaining = window.percentRemaining;
	const used = window.percentUsed;
	let pct: string;
	if (remaining !== undefined) {
		pct = `${Math.round(remaining)}%`;
	} else if (used !== undefined) {
		pct = `${Math.round(100 - used)}%`;
	} else {
		return "";
	}
	const reset = formatResetCountdown(window.resetsAt, now);
	const label = window.label || window.id;
	return reset ? `${label}: ${pct} (${reset})` : `${label}: ${pct}`;
}

function renderQuotaSegments(input: RenderInput): string[] {
	if (input.quotaStatus === "unavailable" || input.windows.length === 0) {
		return input.quotaStatus === "unavailable" ? ["quota: n/a"] : [];
	}
	const parts = input.windows
		.map((window) => renderWindowSegment(window, input.now))
		.filter((segment) => segment.length > 0);
	const prefix = input.quotaStatus === "stale" ? "quota~ " : "quota ";
	return parts.map((part) => prefix + part);
}

function renderModelSegment(input: RenderInput): string {
	const model = input.modelId ?? "no-model";
	const thinking = input.thinkingLevel && input.thinkingLevel !== "off"
		? ` ${input.thinkingLevel}`
		: "";
	return `${model}${thinking}`;
}

function wrapToWidth(text: string, width: number): string[] {
	const lines: string[] = [];
	let current = "";
	for (const character of text) {
		if (current.length > 0 && visibleWidth(current + character) > width) {
			lines.push(current);
			current = "";
		}
		if (visibleWidth(character) <= width) {
			current += character;
		}
	}
	if (current.length > 0 || lines.length === 0) {
		lines.push(current);
	}
	return lines;
}

function packSegments(segments: string[], width: number): string[] {
	const lines: string[] = [];
	let current = "";
	for (const segment of segments) {
		const combined = current.length > 0 ? current + SEP + segment : segment;
		if (visibleWidth(combined) <= width) {
			current = combined;
			continue;
		}
		if (current.length > 0) {
			lines.push(current);
			current = "";
		}
		const wrapped = wrapToWidth(segment, width);
		lines.push(...wrapped.slice(0, -1));
		current = wrapped.at(-1) ?? "";
	}
	if (current.length > 0) {
		lines.push(current);
	}
	return lines;
}

/**
 * Render the statusline footer for the given input and terminal width.
 *
 * Returns width-safe lines, adding continuation lines when the available
 * width cannot contain every field.
 */
export function renderFooter(
	input: RenderInput,
	theme: RenderTheme,
	width: number,
): string[] {
	const safeWidth = Number.isFinite(width) ? Math.max(0, Math.floor(width)) : 0;
	if (safeWidth === 0) {
		return [""];
	}
	const branchSuffix = input.branch ? ` (${input.branch})` : "";
	const repoLines = wrapToWidth(`${input.repoPath}${branchSuffix}`, safeWidth)
		.map((line) => theme.fg("dim", line));

	const context = renderContextSegment(input);
	const model = renderModelSegment(input);
	const detailLines = packSegments(
		[context, ...renderQuotaSegments(input), model],
		safeWidth,
	);
	return [...repoLines, ...detailLines];
}
