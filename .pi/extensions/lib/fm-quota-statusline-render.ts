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
//   line 2: <ctx%> / <tokens>   <quota windows>   <model> <thinking>
//
// A stale quota cache keeps its last-good windows but prefixes the segment
// so the captain can see the data may be behind. An unavailable quota shows a
// concise marker and never fabricates a window or percentage.
//
// Narrow terminals: segments are dropped by priority (reset countdowns first,
// then quota windows, then thinking, then repo path collapses to basename)
// before any line is truncated to the available width.

import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import type {
	QuotaFetchStatus,
	QuotaWindow,
} from "./fm-quota-statusline-data.ts";
import { formatResetCountdown } from "./fm-quota-statusline-data.ts";

/** Live session values the renderer needs from Pi. */
export interface RenderInput {
	/** Repository path for the first line (already shortened, e.g. ~/dev/proj). */
	repoPath: string;
	/** Bare repo path with no shortening, used when width forces a basename. */
	repoBasename: string;
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

function renderQuotaSegment(input: RenderInput): string {
	if (input.quotaStatus === "unavailable" || input.windows.length === 0) {
		return input.quotaStatus === "unavailable" ? "quota: n/a" : "";
	}
	const parts = input.windows
		.map((window) => renderWindowSegment(window, input.now))
		.filter((segment) => segment.length > 0);
	if (parts.length === 0) {
		return "";
	}
	const prefix = input.quotaStatus === "stale" ? "quota~ " : "quota ";
	return prefix + parts.join("   ");
}

function renderModelSegment(input: RenderInput): string {
	const model = input.modelId ?? "no-model";
	const thinking = input.thinkingLevel && input.thinkingLevel !== "off"
		? ` ${input.thinkingLevel}`
		: "";
	return `${model}${thinking}`;
}

/**
 * Render the statusline footer for the given input and terminal width.
 *
 * Returns one or two lines. When width is too small for two readable lines,
 * the second line is dropped entirely; the first line is then truncated to
 * the width so the footer never overflows the terminal.
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
	const repoForLine1 = safeWidth < 48 ? input.repoBasename : input.repoPath;
	const branchSuffix = input.branch ? ` (${input.branch})` : "";
	const line1 = theme.fg("dim", `${repoForLine1}${branchSuffix}`);

	const context = renderContextSegment(input);
	const quota = renderQuotaSegment(input);
	const model = renderModelSegment(input);

	let line2Parts: string[] = [];
	if (safeWidth >= 40) {
		line2Parts.push(context);
	}
	if (safeWidth >= 60 && quota.length > 0) {
		line2Parts.push(quota);
	}
	if (safeWidth >= 50) {
		line2Parts.push(model);
	}
	let line2 = line2Parts.length > 0 ? line2Parts.join(SEP) : "";
	if (line2.length > 0 && visibleWidth(line2) > safeWidth) {
		// Drop the model segment first, then quota, to keep the most
		// decision-relevant context number visible.
		const trimmed = [...line2Parts];
		while (
			trimmed.length > 1 &&
			visibleWidth(trimmed.join(SEP)) > safeWidth
		) {
			trimmed.splice(trimmed.length - 1, 1);
		}
		line2 = trimmed.join(SEP);
	}

	if (line2.length === 0) {
		return [truncateToWidth(line1, safeWidth)];
	}
	const line1Clamped = truncateToWidth(line1, safeWidth);
	const line2Clamped = truncateToWidth(line2, safeWidth);
	return [line1Clamped, line2Clamped];
}
