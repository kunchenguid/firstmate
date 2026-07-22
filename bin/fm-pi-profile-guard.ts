import {
	SettingsManager,
	type ExtensionAPI,
	type ExtensionContext,
} from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
	const expectedModel = process.env.FM_PI_DELEGATED_MODEL;
	const expectedContext = Number(process.env.FM_PI_DELEGATED_CONTEXT_WINDOW);
	const expectedAgentDir = process.env.FM_PI_DELEGATED_AGENT_DIR;
	const expectedReserve = Number(process.env.FM_PI_DELEGATED_RESERVE_TOKENS);
	const expectedKeepRecent = Number(process.env.FM_PI_DELEGATED_KEEP_RECENT_TOKENS);
	let rejected = false;

	const compactionIsValid = (ctx: ExtensionContext) => {
		if (!expectedAgentDir || !Number.isSafeInteger(expectedReserve) || !Number.isSafeInteger(expectedKeepRecent)) {
			return false;
		}
		try {
			const settings = SettingsManager.create(ctx.cwd, expectedAgentDir, { projectTrusted: false }).getCompactionSettings();
			return settings.enabled && settings.reserveTokens === expectedReserve && settings.keepRecentTokens === expectedKeepRecent;
		} catch {
			return false;
		}
	};

	const enforceCompaction = (ctx: ExtensionContext) => {
		if (compactionIsValid(ctx)) return true;
		if (!rejected) {
			ctx.ui.notify("Delegated Pi profile rejected changed compaction settings.", "error");
			rejected = true;
		}
		ctx.shutdown();
		return false;
	};

	pi.on("session_start", async (_event, ctx) => {
		enforceCompaction(ctx);
	});

	pi.on("input", async (_event, ctx) => {
		if (!enforceCompaction(ctx)) return { action: "handled" };
		return { action: "continue" };
	});

	pi.on("before_agent_start", async (_event, ctx) => {
		enforceCompaction(ctx);
	});

	pi.on("session_before_compact", async (_event, ctx) => {
		if (!enforceCompaction(ctx)) return { cancel: true };
		return {};
	});

	pi.on("model_select", async (event, ctx) => {
		const selected = `${event.model.provider}/${event.model.id}`;
		if (selected !== expectedModel || event.model.contextWindow !== expectedContext) {
			ctx.ui.notify(`Delegated Pi profile rejected model change to ${selected}.`, "error");
			ctx.shutdown();
		}
	});

	pi.on("thinking_level_select", async (event, ctx) => {
		if (event.level !== "medium") {
			ctx.ui.notify(`Delegated Pi profile rejected thinking level ${event.level}.`, "error");
			ctx.shutdown();
		}
	});
}
