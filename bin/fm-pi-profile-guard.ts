import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
	const expectedModel = process.env.FM_PI_DELEGATED_MODEL;
	const expectedContext = Number(process.env.FM_PI_DELEGATED_CONTEXT_WINDOW);

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
