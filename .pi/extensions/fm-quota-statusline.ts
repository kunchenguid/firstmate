// Firstmate Pi extension: a compact, always-visible custom footer that shows
// the repository path + git branch, live context usage, the active model and
// thinking level, and every verified Codex quota window from `quota-axi`.
//
// Replaces Pi's stock footer only while this extension is active; the
// `/statusline` command toggles it, `/statusline refresh` refreshes Codex
// quota data, and `/statusline off` (or toggling off) restores the stock
// footer. The footer reads live Pi session state on every render, so
// context, branch, model, and thinking level update as their underlying Pi
// state changes.
//
// Quota data is fetched through a bounded `quota-axi --provider codex --json`
// subprocess with a timeout, parsed defensively (see
// ./lib/fm-quota-statusline-data.ts). On a transient failure the last known
// good windows are retained and marked stale; if no good data has ever been
// seen the footer shows a concise unavailable marker. No credentials or raw
// errors are exposed in the footer.
//
// Refresh triggers: session start, model/thinking-level change, the
// `/statusline refresh` command, and a bounded periodic timer (5 minutes). The
// timer is cleared and in-flight results are invalidated on session shutdown.
//
// Rendering is owned by ./lib/fm-quota-statusline-render.ts and is ANSI
// visible-width safe and narrow-terminal aware.

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { TUI, Theme } from "@earendil-works/pi-tui";
import type { ReadonlyFooterDataProvider } from "@earendil-works/pi-coding-agent";
import {
	extractWindows,
	getProviderQuotaStatus,
	parseQuotaJson,
	type QuotaFetchStatus,
	type QuotaWindow,
} from "./lib/fm-quota-statusline-data.ts";
import { renderFooter, type RenderInput } from "./lib/fm-quota-statusline-render.ts";

const QUOTA_PROVIDER = "codex";
const REFRESH_TIMEOUT_MS = 15_000;
const PERIODIC_REFRESH_MS = 5 * 60 * 1000;

interface FooterComponent {
	dispose?(): void;
	invalidate(): void;
	render(width: number): string[];
}

function shortenPath(path: string, home: string | undefined): string {
	if (!home || home === "/") {
		return path;
	}
	if (path === home) {
		return "~";
	}
	if (path.startsWith(home + "/")) {
		return "~" + path.slice(home.length);
	}
	return path;
}

export default function (pi: ExtensionAPI) {
	let enabled = false;
	let latestCtx: ExtensionContext | undefined;
	let windows: QuotaWindow[] = [];
	let quotaStatus: QuotaFetchStatus = "unavailable";
	let refreshInFlight = false;
	let pendingRefreshCtx: ExtensionContext | undefined;
	let lifecycleGeneration = 0;
	let periodicTimer: ReturnType<typeof setTimeout> | undefined;
	let footerRef: { invalidate(): void } | undefined;

	const refreshQuota = async (ctx: ExtensionContext): Promise<void> => {
		if (refreshInFlight) {
			pendingRefreshCtx = ctx;
			return;
		}
		refreshInFlight = true;
		const refreshGeneration = lifecycleGeneration;
		try {
			const result = await pi.exec(
				"quota-axi",
				["--provider", QUOTA_PROVIDER, "--json"],
				{ timeout: REFRESH_TIMEOUT_MS, cwd: ctx.cwd },
			);
			if (refreshGeneration !== lifecycleGeneration) {
				return;
			}
			if (result.killed || result.code !== 0) {
				markStaleOrUnavailable();
				return;
			}
			const parsed = parseQuotaJson(result.stdout);
			if (!parsed) {
				markStaleOrUnavailable();
				return;
			}
			windows = extractWindows(parsed, QUOTA_PROVIDER);
			quotaStatus = getProviderQuotaStatus(parsed, QUOTA_PROVIDER);
		} catch {
			if (refreshGeneration === lifecycleGeneration) {
				markStaleOrUnavailable();
			}
		} finally {
			refreshInFlight = false;
			if (refreshGeneration === lifecycleGeneration) {
				footerRef?.invalidate();
			}
			const queuedCtx = pendingRefreshCtx;
			pendingRefreshCtx = undefined;
			if (queuedCtx) {
				void refreshQuota(queuedCtx);
			}
		}
	};

	const markStaleOrUnavailable = (): void => {
		if (windows.length > 0) {
			quotaStatus = "stale";
		} else {
			quotaStatus = "unavailable";
		}
	};

	const buildRenderInput = (
		ctx: ExtensionContext,
		footerData: ReadonlyFooterDataProvider,
	): RenderInput => {
		const usage = ctx.getContextUsage();
		const thinking =
			ctx.thinkingLevel ?? pi.getThinkingLevel() ?? null;
		return {
			repoPath: shortenPath(ctx.cwd, process.env.HOME),
			branch: footerData.getGitBranch(),
			contextPercent: usage?.percent ?? null,
			contextTokens: usage?.tokens ?? null,
			modelId: ctx.model?.id ?? null,
			thinkingLevel: thinking,
			windows,
			quotaStatus,
			now: Date.now(),
		};
	};

	const installFooter = (ctx: ExtensionContext): void => {
		ctx.ui.setFooter(
			(tui: TUI, theme: Theme, footerData: ReadonlyFooterDataProvider) => {
				const unsub = footerData.onBranchChange(() => tui.requestRender());
				const component: FooterComponent = {
					dispose: () => {
						unsub();
					},
					invalidate() {
						tui.requestRender();
					},
					render(width: number): string[] {
						if (!latestCtx) {
							return [theme.fg("dim", "statusline initializing")];
						}
						return renderFooter(
							buildRenderInput(latestCtx, footerData),
							theme,
							width,
						);
					},
				};
				footerRef = component;
				return component;
			},
		);
	};

	const restoreStockFooter = (ctx: ExtensionContext): void => {
		enabled = false;
		footerRef = undefined;
		clearPeriodicTimer();
		ctx.ui.setFooter(undefined);
	};

	const enableCustomFooter = (ctx: ExtensionContext): void => {
		enabled = true;
		latestCtx = ctx;
		installFooter(ctx);
		void refreshQuota(ctx);
	};

	const ensurePeriodicTimer = (ctx: ExtensionContext): void => {
		if (periodicTimer) {
			return;
		}
		periodicTimer = setInterval(() => {
			if (enabled) {
				void refreshQuota(ctx);
			}
		}, PERIODIC_REFRESH_MS);
		// Node's setInterval is unbounded only if not cleared; clear it on
		// shutdown (see session_shutdown handler) so no timer outlives the
		// session.
	};

	const clearPeriodicTimer = (): void => {
		if (periodicTimer) {
			clearInterval(periodicTimer);
			periodicTimer = undefined;
		}
	};

	pi.registerCommand("statusline", {
		description:
			"Toggle the Firstmate quota statusline footer; 'refresh' refreshes Codex data, 'off' restores the stock footer",
		handler: async (args, ctx) => {
			latestCtx = ctx;
			const sub = args.trim().toLowerCase();
			if (sub === "off" || sub === "restore" || sub === "stock") {
				restoreStockFooter(ctx);
				ctx.ui.notify("Stock footer restored", "info");
				return;
			}
			if (sub === "refresh") {
				void refreshQuota(ctx);
				ctx.ui.notify("Refreshing Codex quota data", "info");
				return;
			}
			if (sub === "on") {
				if (!enabled) {
					enableCustomFooter(ctx);
					ensurePeriodicTimer(ctx);
					ctx.ui.notify("Statusline footer enabled", "info");
				}
				return;
			}
			if (sub === "") {
				if (enabled) {
					restoreStockFooter(ctx);
					ctx.ui.notify("Stock footer restored", "info");
				} else {
					enableCustomFooter(ctx);
					ensurePeriodicTimer(ctx);
					ctx.ui.notify("Statusline footer enabled", "info");
				}
				return;
			}
			ctx.ui.notify(
				"Usage: /statusline [on|off|refresh]",
				"warning",
			);
		},
	});

	pi.on("session_start", (_event, ctx) => {
		latestCtx = ctx;
		if (enabled) {
			installFooter(ctx);
			void refreshQuota(ctx);
			ensurePeriodicTimer(ctx);
		}
	});

	pi.on("model_select", (_event, ctx) => {
		latestCtx = ctx;
		if (enabled) {
			void refreshQuota(ctx);
			footerRef?.invalidate();
		}
	});

	pi.on("thinking_level_select", (_event, ctx) => {
		latestCtx = ctx;
		if (enabled) {
			void refreshQuota(ctx);
			footerRef?.invalidate();
		}
	});

	pi.on("turn_end", (_event, ctx) => {
		latestCtx = ctx;
		if (enabled) {
			footerRef?.invalidate();
		}
	});

	pi.on("session_shutdown", () => {
		lifecycleGeneration += 1;
		pendingRefreshCtx = undefined;
		clearPeriodicTimer();
		footerRef = undefined;
	});
}
